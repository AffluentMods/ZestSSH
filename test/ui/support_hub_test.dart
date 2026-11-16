import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/features/feedback/feedback_service.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/tickets/public_reports.dart';
import 'package:zestssh/features/tickets/ticket_models.dart';
import 'package:zestssh/features/tickets/ticket_service.dart';
import 'package:zestssh/features/tickets/ticket_token.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/providers/help_status_provider.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/help_dock.dart';
import 'package:zestssh/ui/screens/help/support_hub_compose.dart';
import 'package:zestssh/ui/screens/help/support_hub_page.dart';
import 'package:zestssh/ui/screens/help/support_hub_screen.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/report_scrub.dart';

import '../features/tickets/fake_ticket_server.dart';
import '../a11y/a11y_checks.dart';

/// The Support Hub, driven through the
/// real services and database against the in-memory server: My tickets grouped
/// by where they stand with a conversation or a new report beside them, Known
/// issues and Ideas with +1, the Help panel beside a session, and a phone.
///
/// The id the hub's +1s give for this device when nobody is signed in.
const hubDevice = 'hub-device-0123456789abcdef';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  const ctx = FeedbackContext(
    appVersion: '3.3.0',
    build: 340,
    platform: 'windows',
    osVersion: 'Windows 11 24H2',
    locale: 'en-US',
    tier: 'free',
  );

  late AppDatabase db;
  late FakeTicketServer server;
  late TicketService service;
  late SharedPreferences prefs;

  /// What the feedback route was sent, and how it answers.
  late List<Map<String, dynamic>> reports;
  late int? reportStatus;

  /// While set, a request waits for this before it gets its answer.
  Completer<void>? holdRequests;

  /// The account the public lists' +1 goes with; null is nobody signed in.
  String? bearer;

  /// The reports this device +1'd with nobody signed in, as the app keeps them.
  Set<String> guestVoted = {};

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    PackageInfo.setMockInitialValues(
      appName: 'ZestSSH',
      packageName: 'com.affluentlabs.zestssh',
      version: '3.3.0',
      buildNumber: '340',
      buildSignature: '',
    );
    db = AppDatabase.forTesting(NativeDatabase.memory());
    server = FakeTicketServer();
    holdRequests = null;
    bearer = null;
    guestVoted = {};
    service = TicketService(
      db,
      client: MockClient((req) async {
        await holdRequests?.future;
        return server.handle(req);
      }),
      baseUrl: 'https://api.test/v1',
    );
    reports = [];
    reportStatus = null;
    Redactor.instance.enabled = false;
    resetSupportHubDraft();
    NotificationCenter.debugToastsDrawn = true;
  });
  tearDown(() async {
    Redactor.instance.enabled = false;
    NotificationCenter.debugToastsDrawn = null;
    await db.close();
  });

  /// The feedback route, as far as this page goes: takes a report and makes it
  /// a ticket on the server.
  Future<http.Response> feedbackRoute(http.Request req) async {
    if (!req.url.path.endsWith('/feedback')) return server.handle(req);
    await holdRequests?.future;
    if (server.offline) throw const SocketException('offline');
    if (reportStatus != null) return http.Response('{"error":"no"}', reportStatus!, headers: {'retry-after': '300'});
    final refused = server.attachmentsRefused(req);
    if (refused != null) return refused;
    final j = (jsonDecode(req.body) as Map).cast<String, dynamic>();
    reports.add(j);
    final t = server.addReport(
      token: j['ticket_token'] as String,
      type: j['type'] as String,
      title: j['title'] as String,
      body: j['body'] as String,
    );
    return http.Response(jsonEncode({'ticket': {'id': t.id, 'number': t.number}}), 201);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// Runs [body] once a screen is up, in the screen's own zone, pumping until
  /// it is done (a database call made with runAsync while a screen watches the
  /// same database waits for ever).
  Future<T> run<T>(WidgetTester tester, Future<T> Function() body) async {
    T? out;
    Object? error;
    var done = false;
    body().then((v) {
      out = v;
      done = true;
    }, onError: (Object e) {
      error = e;
      done = true;
    });
    for (var i = 0; i < 40 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    if (error != null) throw error!;
    expect(done, isTrue, reason: 'the call finished');
    return out as T;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  Future<ProviderContainer> pumpHub(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    bool recording = false,
    ScreenshotCaptureForTest? capture,
    TicketType? compose,
    VoidCallback? onClose,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      treeDatabaseProvider.overrideWithValue(db),
      dbReadyProvider.overrideWithValue(true),
      ticketServiceProvider.overrideWithValue(service),
      publicReportsServiceProvider.overrideWithValue(PublicReportsService(
        client: MockClient((req) async {
          await holdRequests?.future;
          return server.handle(req);
        }),
        baseUrl: 'https://api.test/v1',
        bearer: () async => bearer,
        deviceId: () async => hubDevice,
        guestVotes: () async => {...guestVoted},
        rememberGuestVote: (id, on) async => on ? guestVoted.add(id) : guestVoted.remove(id),
      )),
      feedbackServiceProvider.overrideWithValue(FeedbackService(
        db,
        prefs,
        client: MockClient(feedbackRoute),
        baseUrl: 'https://api.test/v1',
        onTicket: (report, {required String id, int? number}) => service.keepReport(report, id: id, number: number),
      )),
      cloudStatusProvider.overrideWith((_) async => CloudStatus.ok),
      appVersionLabelProvider.overrideWith((_) async => '3.3.0'),
      recordingModeProvider.overrideWith((ref) => recording),
      if (compose != null) supportHubComposeProvider.overrideWith((_) => compose),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              if (!ref.watch(supportHubOpenProvider)) return const Text('sessions');
              return SupportHubPage(
                captureScreenshot: ({required bool redacted}) async => capture?.call(redacted),
                onClose: () {
                  onClose?.call();
                  ref.read(supportHubOpenProvider.notifier).state = false;
                },
              );
            },
          ),
        ),
      ),
    ));
    container.read(supportHubOpenProvider.notifier).state = true;
    await settle(tester);
    return container;
  }

  /// A support ticket that reached the server, made before any screen is up.
  Future<SupportTicketRow> seedSupport(
    WidgetTester tester, {
    String title = 'Cannot restore my purchase',
    String body = 'I paid on my phone and the PC still says Free.',
  }) async {
    late SupportTicketRow row;
    await tester.runAsync(() async {
      final res = await service.createSupport(title: title, body: body, context: ctx);
      row = (await service.ticket(res.nonce!))!;
    });
    return row;
  }

  /// A report that became a ticket, made before any screen is up.
  Future<SupportTicketRow> seedReport(
    WidgetTester tester, {
    FeedbackType type = FeedbackType.bug,
    String title = 'Split view loses focus after resize',
    String body = 'Typing goes to the left pane after dragging the divider.',
    List<String> tags = const [],
  }) async {
    late SupportTicketRow row;
    await tester.runAsync(() async {
      final report = FeedbackReport(type: type, title: title, body: body, context: ctx);
      final t = server.addReport(token: report.ticketToken, type: type.wire, title: title, body: body);
      if (tags.isNotEmpty) server.staffTags(t.id, tags);
      await service.keepReport(report, id: t.id, number: t.number);
      await service.refresh();
      row = (await service.ticket(report.nonce))!;
    });
    return row;
  }

  /// What the toasts said.
  List<String> said(ProviderContainer c) => [for (final n in c.read(notificationCenterProvider).history) n.title];

  Finder rowOf(String nonce) => find.byKey(ValueKey('hub-row-$nonce'));

  Finder inRow(String nonce, String text) =>
      find.descendant(of: rowOf(nonce), matching: find.text(text));

  Finder within(Finder of, Finder matching) => find.descendant(of: of, matching: matching);

  /// Opens the ticket's menu and picks [key] in it.
  Future<void> fromMenu(WidgetTester tester, String key) async {
    await tester.tap(find.byTooltip(l10n.ticketMenu).first);
    await settle(tester);
    await tester.tap(find.byKey(ValueKey(key)));
    await settle(tester);
  }

  group('My tickets', () {
    testWidgets('grouped as the design has them: needs your reply, waiting for support, your ideas, closed', (tester) async {
      final answered = await seedSupport(tester, title: 'Answered');
      final waitingOnSupport = await seedSupport(tester, title: 'Asked', body: 'The .json says unsupported.');
      final closed = await seedSupport(tester, title: 'Finished');
      final bug = await seedReport(tester, title: 'A bug in progress');
      final idea = await seedReport(tester, type: FeedbackType.suggestion, title: 'An idea');
      late String refused;
      await tester.runAsync(() async {
        server.staffReply(answered.serverId!, 'Can you update to 3.3.0 and try again?');
        server.staffClose(closed.serverId!);
        server.tickets[idea.serverId!]!
          ..state = 'planned'
          ..votes = 41;
        await service.refresh();
        server.offline = true;
        refused = (await service.createSupport(title: 'Refused', body: 'Text.', context: ctx)).nonce!;
        server.offline = false;
        server.failWith = 400;
        await service.retryPending();
        server.failWith = null;
      });
      final container = await pumpHub(tester, size: const Size(1440, 1400));
      server.offline = true;
      final waiting = (await run(tester, () => service.createSupport(title: 'Waiting', body: 'Text.', context: ctx))).nonce!;
      await settle(tester);

      Finder group(String name) => find.byKey(ValueKey('hub-group-$name'));
      double top(Finder f) => tester.getTopLeft(f).dy;
      expect(within(group('needsReply'), find.text(l10n.supportHubGroupNeedsReply.toUpperCase())), findsOneWidget);
      // In the mockup's order, each row under its own group.
      expect(top(group('needsReply')), lessThan(top(rowOf(answered.nonce))));
      expect(top(rowOf(answered.nonce)), lessThan(top(group('waiting'))));
      expect(top(group('waiting')), lessThan(top(rowOf(waitingOnSupport.nonce))));
      expect(top(rowOf(bug.nonce)), lessThan(top(group('ideas'))));
      expect(top(group('ideas')), lessThan(top(rowOf(idea.nonce))));
      expect(top(rowOf(idea.nonce)), lessThan(top(group('closed'))));
      expect(top(group('closed')), lessThan(top(rowOf(closed.nonce))));

      // The last words said on it, who said them, and what it is.
      expect(inRow(answered.nonce, l10n.supportHubSaidSupport('Can you update to 3.3.0 and try again?')), findsOneWidget);
      expect(within(rowOf(answered.nonce), find.byKey(const ValueKey('hub-unread'))), findsOneWidget,
          reason: 'not opened yet, so an answer not read');
      expect(inRow(waitingOnSupport.nonce, l10n.supportHubSaidYou('The .json says unsupported.')), findsOneWidget);
      expect(within(rowOf(waitingOnSupport.nonce), find.textContaining(l10n.supportHubKindHelp)), findsOneWidget);
      expect(within(rowOf(waitingOnSupport.nonce), find.textContaining(l10n.supportHubPrivate)), findsOneWidget);
      expect(within(rowOf(bug.nonce), find.textContaining(l10n.supportHubPublic)), findsOneWidget);
      expect(inRow(idea.nonce, '${l10n.supportHubStatePlanned}. ${l10n.supportHubPeopleWantThis(41)}'), findsOneWidget);
      expect(inRow(closed.nonce, l10n.ticketStatusClosed), findsOneWidget);
      expect(inRow(refused, '${l10n.ticketStatusNotSent} · ZS-1907'), findsOneWidget);
      expect(inRow(waiting, l10n.ticketStatusWaiting), findsOneWidget);
      // "Seen by support" was taken out: it is nowhere.
      expect(find.textContaining('Seen'), findsNothing);
      // The tab says how many wait on the person.
      expect(within(find.byKey(const ValueKey('hub-tab-tickets')), find.text('1')), findsOneWidget);

      container.read(supportHubTicketProvider.notifier).state = refused;
      await settle(tester);
      server.offline = false;
      await finish(tester);
    });

    testWidgets('closed ones show two, then "Show N more closed"; one closed for want of a reply says so', (tester) async {
      final quiet = await seedSupport(tester, title: 'Sync paused on my Pixel');
      final others = [for (var i = 0; i < 3; i++) await seedSupport(tester, title: 'Closed $i')];
      await tester.runAsync(() async {
        server.quietClose(quiet.serverId!);
        for (final o in others) {
          server.staffClose(o.serverId!);
        }
        await service.refresh();
      });
      await pumpHub(tester, size: const Size(1440, 1200));
      final shown = [quiet, ...others].where((t) => tester.any(rowOf(t.nonce))).length;
      expect(shown, kHubClosedShown);
      await tester.tap(find.text(l10n.supportHubShowMoreClosed(2)));
      await settle(tester);
      for (final t in [quiet, ...others]) {
        expect(rowOf(t.nonce), findsOneWidget);
      }
      expect(inRow(quiet.nonce, l10n.supportHubClosedNoReply), findsOneWidget);
      await finish(tester);
    });

    testWidgets('an answer not read has its dot until it has been on screen', (tester) async {
      final first = await seedSupport(tester, title: 'Older');
      final second = await seedSupport(tester, title: 'Newer');
      await tester.runAsync(() async {
        server.now = server.now.add(const Duration(hours: 1));
        server.staffReply(first.serverId!, 'An answer.');
        await service.refresh();
      });
      final container = await pumpHub(tester);
      container.read(supportHubTicketProvider.notifier).state = second.nonce;
      await settle(tester);
      await tester.tap(rowOf(second.nonce));
      await settle(tester);

      await run(tester, () async {
        server.now = server.now.add(const Duration(hours: 1));
        server.staffReply(first.serverId!, 'Another answer.');
        await service.refresh();
      });
      await settle(tester);
      expect(within(rowOf(first.nonce), find.byKey(const ValueKey('hub-unread'))), findsOneWidget);
      expect(within(rowOf(second.nonce), find.byKey(const ValueKey('hub-unread'))), findsNothing);
      await finish(tester);
    });

    testWidgets('the search: over subject, number and text', (tester) async {
      final answered = await seedSupport(tester, title: 'Purchase not showing', body: 'On my laptop.');
      final asked = await seedSupport(tester, title: 'Moving a vault', body: 'To a new computer.');
      final closed = await seedSupport(tester, title: 'Team invite', body: 'The email never came.');
      await tester.runAsync(() async {
        server.staffReply(answered.serverId!, 'Which store?');
        server.staffClose(closed.serverId!);
        await service.refresh();
      });
      await pumpHub(tester);
      await tester.enterText(find.byKey(const ValueKey('hub-search')), 'vault');
      await tester.pump();
      expect(rowOf(asked.nonce), findsOneWidget);
      expect(rowOf(answered.nonce), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('hub-search')), 'email never');
      await tester.pump();
      expect(rowOf(closed.nonce), findsOneWidget);
      expect(rowOf(asked.nonce), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('hub-search')), '#${answered.number}');
      await tester.pump();
      expect(rowOf(answered.nonce), findsOneWidget);
      expect(rowOf(closed.nonce), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('hub-search')), 'no such thing');
      await tester.pump();
      expect(find.text(l10n.supportHubNoMatches), findsOneWidget);
      await finish(tester);
    });

    testWidgets('/ goes to the search; Esc takes its words first, then goes back to the sessions', (tester) async {
      await seedSupport(tester);
      var closed = 0;
      await pumpHub(tester, onClose: () => closed++);
      final field = tester.widget<TextField>(find.byKey(const ValueKey('hub-search')));
      expect(field.focusNode!.hasFocus, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.pump();
      expect(field.focusNode!.hasFocus, isTrue);
      expect(field.controller!.text, isEmpty, reason: 'the key that took it there is not typed');
      await tester.enterText(find.byKey(const ValueKey('hub-search')), 'purchase');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(field.controller!.text, isEmpty);
      expect(closed, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(closed, 1);
      expect(find.text('sessions'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('with nothing sent yet it says what will show there, and the ways to start stand ready', (tester) async {
      await pumpHub(tester);
      expect(find.text(l10n.ticketsEmptyTitle), findsOneWidget);
      for (final key in ['hub-start-help', 'hub-start-bug', 'hub-start-idea']) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      await tester.tap(find.byKey(const ValueKey('hub-start-bug')));
      await settle(tester);
      expect(find.byKey(const ValueKey('hub-compose')), findsOneWidget);
      expect(find.text(l10n.supportHubWhatsWrong), findsOneWidget);
      await finish(tester);
    });

    testWidgets('New: Get help, Report a bug or Suggest an idea, each into the form', (tester) async {
      final c = await pumpHub(tester);
      for (final (key, kind, label) in [
        ('hub-new-support', TicketType.support, l10n.supportHubWhatHelp),
        ('hub-new-bug', TicketType.bug, l10n.supportHubWhatsWrong),
        ('hub-new-suggestion', TicketType.suggestion, l10n.supportHubWhatsIdea),
      ]) {
        await tester.tap(find.byKey(const ValueKey('hub-new')));
        await settle(tester);
        await tester.tap(find.byKey(ValueKey(key)));
        await settle(tester);
        expect(c.read(supportHubComposeProvider), kind);
        expect(find.text(label), findsOneWidget, reason: key);
      }
      await finish(tester);
    });

    testWidgets('where the desk cannot be reached it says so', (tester) async {
      await seedSupport(tester);
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        treeDatabaseProvider.overrideWithValue(db),
        dbReadyProvider.overrideWithValue(true),
        ticketServiceProvider.overrideWithValue(service),
        feedbackServiceProvider.overrideWithValue(
            FeedbackService(db, prefs, client: MockClient(feedbackRoute), baseUrl: 'https://api.test/v1')),
        cloudStatusProvider.overrideWith((_) async => CloudStatus.degraded),
        appVersionLabelProvider.overrideWith((_) async => '3.3.0'),
        recordingModeProvider.overrideWith((ref) => false),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: SupportHubPage(captureScreenshot: ({required bool redacted}) async => null, onClose: () {}),
          ),
        ),
      ));
      await settle(tester);
      expect(find.text(l10n.supportHubHealthDown(l10n.helpStatusDegraded)), findsOneWidget);
      await finish(tester);
    });
  });

  group('a conversation', () {
    testWidgets('the head: subject, where it stands, its kind, who sees it, its number, when; the people in it', (tester) async {
      final t = await seedSupport(tester);
      await tester.runAsync(() async {
        server.staffReply(t.serverId!, 'Which store did you buy it from?', name: 'Robin Vale');
        await service.refresh();
      });
      await pumpHub(tester);
      expect(within(find.byKey(const ValueKey('hub-status')), find.text(l10n.supportHubGroupNeedsReply)), findsOneWidget);
      expect(find.text('#${t.number}'), findsWidgets);
      expect(find.text(t.title), findsWidgets);
      expect(within(find.byKey(const ValueKey('hub-who-sees')), find.text(l10n.supportHubPrivateOnlyYou)), findsOneWidget);
      expect(find.textContaining(l10n.supportHubOpened('')), findsOneWidget);
      // Their name, their initials, the badge.
      expect(find.text('Robin Vale'), findsOneWidget);
      expect(find.text('RV'), findsOneWidget);
      expect(find.text(l10n.ticketTypeSupport), findsWidgets);
      expect(find.text('Which store did you buy it from?'), findsOneWidget);
      // No track any more: the mockup has none.
      expect(find.byKey(const ValueKey('hub-track')), findsNothing);
      await finish(tester);
    });

    testWidgets('Copy number for a private ticket, Copy link for a public one: never its id or token', (tester) async {
      final t = await seedSupport(tester);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final c = await pumpHub(tester);
      expect(find.text(l10n.supportHubCopyNumber), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('hub-copy-link')));
      await settle(tester);
      expect(copied, '#${t.number}');
      await tester.pump(const Duration(seconds: 4));

      final bug = await run(tester, () async {
        final report = FeedbackReport(type: FeedbackType.bug, title: 'Public one', body: 'B', context: ctx);
        final onServer = server.addReport(token: report.ticketToken, title: report.title, body: report.body);
        await service.keepReport(report, id: onServer.id, number: onServer.number);
        await service.refresh();
        return report.nonce;
      });
      c.read(supportHubTicketProvider.notifier).state = bug;
      await settle(tester);
      expect(find.text(l10n.supportHubCopyLink), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('hub-copy-link')));
      await settle(tester);
      expect(copied, 'https://discord.com/channels/1/2');
      await tester.pump(const Duration(seconds: 4));
      await finish(tester);
    });

    testWidgets('when support took it up, what was attached, and when it closes by itself', (tester) async {
      final t = await run(tester, () async {
        final res = await service.createPrivate(
          type: TicketType.bug,
          title: 'SFTP upload stalls on files over 2 GB',
          body: 'It sits at 60 percent.',
          context: ctx,
          diagnostics: 'ZestSSH diagnostics\nApp: ZestSSH 3.2.7 (330)\nSystem: windows Windows 11\n',
          screenshot: Uint8List.fromList(const [0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4, 5]),
        );
        return (await service.ticket(res.nonce!))!;
      });
      await tester.runAsync(() async {
        server.tickets[t.serverId!]!.pickedUpAt = server.now.add(const Duration(minutes: 30));
        server.now = server.now.add(const Duration(hours: 2));
        server.staffReply(t.serverId!, 'Big uploads stall when the server only takes small packets.', name: 'Robin');
        await service.refresh();
      });
      await pumpHub(tester);
      await settle(tester);
      expect(find.byKey(const ValueKey('hub-picked-up')), findsOneWidget);
      expect(tester.getTopLeft(find.byKey(const ValueKey('hub-picked-up'))).dy,
          lessThan(tester.getTopLeft(find.text('Big uploads stall when the server only takes small packets.')).dy),
          reason: 'said where it happened: before the answer');
      expect(find.byKey(const ValueKey('hub-attached-shot')), findsOneWidget);
      expect(find.text(l10n.supportHubDiagnosticsChip('v3.2.7, windows Windows 11')), findsOneWidget);
      expect(find.byKey(const ValueKey('hub-quiet-close')), findsOneWidget);
      expect(find.text(l10n.supportHubWaitingOnYou14), findsOneWidget);
      expect(within(find.byKey(const ValueKey('hub-who-sees')), find.text(l10n.supportHubPrivateOnlyYou)), findsOneWidget,
          reason: 'a bug report kept Private says so');

      await tester.tap(find.byKey(const ValueKey('hub-diagnostics-view')));
      await settle(tester);
      expect(find.textContaining('App: ZestSSH 3.2.7 (330)'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await finish(tester);
    });

    testWidgets('a reply: Send stays off while the box is empty, and Ctrl+Enter sends', (tester) async {
      await seedSupport(tester);
      await pumpHub(tester);
      final send = find.byKey(const ValueKey('hub-send-reply'));
      await tester.tap(send, warnIfMissed: false);
      await settle(tester);
      expect(server.calls('/messages'), isEmpty);
      await tester.tap(find.byKey(const ValueKey('hub-reply')));
      await tester.enterText(find.byKey(const ValueKey('hub-reply')), 'It was Google Play.');
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(server.calls('/messages'), hasLength(1));
      final sent = jsonDecode(server.calls('/messages').single.body) as Map;
      expect(sent['body'], 'It was Google Play.');
      expect(sent.containsKey('diagnostics'), isFalse, reason: 'nothing attached unless asked for');
      expect(sent.containsKey('screenshot'), isFalse);
      expect(find.text('It was Google Play.'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('hub-reply'))).controller!.text, isEmpty);
      await tester.enterText(find.byKey(const ValueKey('hub-reply')), 'And on a Mac.');
      await tester.pump();
      await tester.tap(send);
      await settle(tester);
      expect(server.calls('/messages'), hasLength(2));
      await finish(tester);
    });

    testWidgets('a reply can carry a fresh redacted screenshot and fresh diagnostics, the person\'s choice each', (tester) async {
      await seedSupport(tester);
      final shot = Uint8List.fromList(const [0x89, 0x50, 0x4e, 0x47, 9, 9, 9, 9]);
      final asked = <bool>[];
      await pumpHub(tester, capture: (redacted) {
        asked.add(redacted);
        return shot;
      });
      await tester.tap(find.byKey(const ValueKey('hub-reply-screenshot')));
      await settle(tester);
      expect(asked, [true], reason: 'taken redacted, and only when asked');
      expect(find.byKey(const ValueKey('hub-reply-shot')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('hub-reply-diagnostics')));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('hub-reply')), 'Same on 3.3.0.');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hub-send-reply')));
      await settle(tester);
      final sent = jsonDecode(server.calls('/messages').single.body) as Map;
      expect(sent['screenshot'], base64Encode(shot));
      expect(sent['diagnostics'], startsWith('ZestSSH diagnostics\nApp: ZestSSH 3.3.0 (340)'));
      expect(find.byKey(const ValueKey('hub-reply-shot')), findsNothing, reason: 'it went with that reply');
      expect(tester.widget<Checkbox>(find.byKey(const ValueKey('hub-reply-diagnostics'))).value, isFalse);
      await finish(tester);
    });

    testWidgets('a reply with no network waits in the conversation, marked, and can be taken back', (tester) async {
      await seedSupport(tester);
      await pumpHub(tester);
      server.offline = true;
      await tester.enterText(find.byKey(const ValueKey('hub-reply')), 'Written offline.');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hub-send-reply')));
      await settle(tester);
      expect(find.text('Written offline.'), findsOneWidget);
      expect(find.text(l10n.ticketStatusWaiting), findsWidgets);
      expect(find.text(l10n.ticketReplyQueued), findsOneWidget);
      await tester.tap(find.text(l10n.delete));
      await settle(tester);
      expect(find.text('Written offline.'), findsNothing);
      server.offline = false;
      await finish(tester);
    });

    testWidgets('a reply refused for its screenshot and diagnostics says so, and Send without them sends the words alone', (tester) async {
      await seedSupport(tester);
      final shot = Uint8List.fromList(const [0x89, 0x50, 0x4e, 0x47, 9, 9, 9, 9]);
      await pumpHub(tester, capture: (_) => shot);
      for (final (status, code, said) in [
        (413, 'attachments_full', l10n.supportAttachmentsFull),
        (429, 'attachments_hourly', l10n.supportAttachmentsHourly(60)),
        (429, 'attachments_paused', l10n.supportAttachmentsPaused),
      ]) {
        server.refuseAttachments = (status: status, code: code, retryAfter: 3600);
        await tester.tap(find.byKey(const ValueKey('hub-reply-screenshot')));
        await settle(tester);
        await tester.enterText(find.byKey(const ValueKey('hub-reply')), 'Same on 3.3.0.');
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('hub-send-reply')));
        await settle(tester);
        expect(find.text(said), findsOneWidget, reason: code);
        expect(tester.widget<TextField>(find.byKey(const ValueKey('hub-reply'))).controller!.text, 'Same on 3.3.0.',
            reason: 'the words are kept');
        await tester.tap(find.byKey(const ValueKey('ticket-send-without-attachments')));
        await settle(tester);
        final sent = jsonDecode(server.calls('/messages').last.body) as Map;
        expect(sent['body'], 'Same on 3.3.0.');
        expect(sent.containsKey('screenshot'), isFalse, reason: code);
        expect(sent.containsKey('diagnostics'), isFalse, reason: code);
        expect(find.byKey(const ValueKey('ticket-send-without-attachments')), findsNothing);
      }
      await finish(tester);
    });

    testWidgets('a reply\'s screenshot is no larger than a new report\'s', (tester) async {
      await seedSupport(tester);
      final big = Uint8List(FeedbackLimits.screenshotMaxBytes + 1)..setAll(0, const [0x89, 0x50, 0x4e, 0x47]);
      final c = await pumpHub(tester, capture: (_) => big);
      await tester.tap(find.byKey(const ValueKey('hub-reply-screenshot')));
      await settle(tester);
      expect(find.byKey(const ValueKey('hub-reply-shot')), findsNothing);
      expect(said(c), contains(l10n.recModeCopyScreenshotFailed));
      await tester.pump(const Duration(seconds: 4));
      await finish(tester);
    });

    testWidgets('"Fixed now, close it" closes it, saying why, without asking', (tester) async {
      final t = await seedSupport(tester);
      final c = await pumpHub(tester);
      await tester.tap(find.byKey(const ValueKey('hub-fixed-close')));
      await settle(tester);
      expect(server.calls('/close'), hasLength(1));
      expect(jsonDecode(server.calls('/close').single.body), {'fixed': true});
      expect(said(c), contains(l10n.supportHubClosedFixedSaid));
      expect(find.text(l10n.ticketClosedNotice), findsOneWidget);
      expect(find.byKey(const ValueKey('hub-reply')), findsNothing);
      expect(server.tickets[t.serverId!]!.closedReason, 'fixed');
      await tester.pump(const Duration(seconds: 4));
      await finish(tester);
    });

    testWidgets('closed for want of a reply: it says so, and writing opens it again', (tester) async {
      final t = await seedSupport(tester);
      await tester.runAsync(() async {
        server.staffReply(t.serverId!, 'Did 3.3.0 help?');
        server.quietClose(t.serverId!);
        await service.refresh();
      });
      await pumpHub(tester);
      expect(find.text(l10n.supportHubClosedNoReplyNotice), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('hub-reply')), 'Still paused, sorry for the wait.');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hub-send-reply')));
      await settle(tester);
      expect(server.tickets[t.serverId!]!.status, 'open');
      final row = await run(tester, () => service.ticket(t.nonce));
      expect(row!.isOpen, isTrue);
      expect(find.text(l10n.supportHubClosedNoReplyNotice), findsNothing);
      await finish(tester);
    });

    testWidgets('Close ticket, from the menu, asks first, then the box gives way to why it takes no more', (tester) async {
      final t = await seedSupport(tester);
      await pumpHub(tester);
      await fromMenu(tester, 'ticket-menu-close');
      expect(find.text(l10n.ticketCloseConfirmTitle), findsOneWidget);
      await tester.tap(find.text(l10n.cancel));
      await settle(tester);
      expect(server.calls('/close'), isEmpty);
      await fromMenu(tester, 'ticket-menu-close');
      await tester.tap(find.text(l10n.ticketClose).last);
      await settle(tester);
      expect(server.calls('/close'), hasLength(1));
      expect(find.text(l10n.ticketClosedNotice), findsOneWidget);
      expect(find.byKey(const ValueKey('hub-reply')), findsNothing);
      expect(inRow(t.nonce, l10n.ticketStatusClosed), findsOneWidget);
      await finish(tester);
    });

    testWidgets('Copy details takes the whole ticket with its facts, scrubbed; Remove from this device asks first, and the row goes', (tester) async {
      final t = await seedSupport(tester, body: 'I paid on my phone. deploy@web-01.example.com says no.');
      final other = await seedSupport(tester, title: 'Another');
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final container = await pumpHub(tester);
      container.read(supportHubTicketProvider.notifier).state = t.nonce;
      await settle(tester);
      await fromMenu(tester, 'ticket-menu-copy-details');
      expect(copied, contains(t.title));
      expect(copied, contains('I paid on my phone'));
      expect(copied, contains('App 3.3.0 (340) on windows Windows 11 24H2, en-US, free'));
      expect(copied, isNot(contains('web-01.example.com')), reason: 'where it is pasted is the person\'s to choose');
      await tester.pump(const Duration(seconds: 4));

      await fromMenu(tester, 'ticket-menu-remove');
      expect(find.text(l10n.ticketRemoveConfirmTitle), findsOneWidget);
      await tester.tap(find.text(l10n.ticketRemoveConfirm));
      await settle(tester);
      expect(rowOf(t.nonce), findsNothing);
      expect(await run(tester, () => service.ticket(t.nonce)), isNull);
      expect(find.text(other.title), findsWidgets);
      await finish(tester);
    });

    testWidgets('the details, from the menu, say what is known of it and who sees it', (tester) async {
      final t = await seedSupport(tester);
      await pumpHub(tester);
      await fromMenu(tester, 'ticket-menu-details');
      final details = find.byKey(const ValueKey('hub-details'));
      for (final (name, value) in [
        (l10n.supportHubType, l10n.ticketTypeSupport),
        (l10n.supportHubNumber, '#${t.number}'),
        (l10n.supportHubStatus, l10n.ticketAwaitingSupport),
        (l10n.supportHubApp, '3.3.0 (340)'),
        (l10n.supportHubSystem, 'Windows 11 24H2'),
        (l10n.supportHubAccount, l10n.supportHubAccountLeftOut),
      ]) {
        expect(within(details, find.text(name)), findsOneWidget, reason: name);
        expect(within(details, find.text(value)), findsOneWidget, reason: value);
      }
      expect(within(details, find.text(l10n.supportHubWhoPrivate)), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.byKey(const ValueKey('hub-details')), findsNothing);
      expect(find.byKey(const ValueKey('support-hub')), findsOneWidget, reason: 'Esc closed the box, not the hub');
      await finish(tester);
    });

    testWidgets('a public report says it is one, with its tags, and that a reply is public too', (tester) async {
      await seedReport(tester, tags: ['Confirmed', 'Desktop App']);
      await pumpHub(tester);
      expect(within(find.byKey(const ValueKey('hub-who-sees')), find.text(l10n.supportHubPublicNamesRemoved)), findsOneWidget);
      expect(find.text('Confirmed'), findsOneWidget);
      expect(find.text(l10n.ticketReplyPublicNote), findsOneWidget);
      await fromMenu(tester, 'ticket-menu-details');
      expect(find.byKey(const ValueKey('hub-view-discord')), findsOneWidget);
      expect(within(find.byKey(const ValueKey('hub-details')), find.text(l10n.supportHubAccount)), findsNothing);
      await finish(tester);
    });

    testWidgets('one that was not sent says so with its code, Copy details and Retry, which sends it', (tester) async {
      late String refused;
      await tester.runAsync(() async {
        server.offline = true;
        refused = (await service.createSupport(title: 'Refused', body: 'What I wrote.', context: ctx)).nonce!;
        server.offline = false;
        server.failWith = 400;
        await service.retryPending();
        server.failWith = null;
      });
      await pumpHub(tester);
      expect(find.text(ErrorCodes.withCode(l10n.ticketRefusedRejected, ErrorCodes.ticketRefused)), findsOneWidget);
      expect(find.text(l10n.desktopShellCopyDetails), findsOneWidget);
      expect(find.text('What I wrote.'), findsOneWidget);
      final created = server.calls('/tickets').length;
      await tester.tap(find.byKey(const ValueKey('ticket-retry')));
      await settle(tester);
      expect(server.calls('/tickets').length, created + 1);
      final row = await run(tester, () => service.ticket(refused));
      expect(row!.isSent, isTrue);
      expect(find.byKey(const ValueKey('hub-reply')), findsOneWidget);
      await finish(tester);
    });

    for (final (error, words, code) in [
      ('account', l10n.ticketRefusedAccount, ErrorCodes.ticketNeedsAccount),
      ('blocked', l10n.supportBlocked, ErrorCodes.ticketBlocked),
      ('rejected', l10n.ticketRefusedRejected, ErrorCodes.ticketRefused),
    ]) {
      testWidgets('a refusal of "$error" has its own code', (tester) async {
        await tester.runAsync(() async {
          server.offline = true;
          final r = await service.createSupport(title: 'Refused', body: 'Text.', context: ctx);
          server.offline = false;
          await db.customStatement("UPDATE support_tickets SET send_error = '$error' WHERE nonce = '${r.nonce}'");
        });
        await pumpHub(tester);
        expect(find.text(ErrorCodes.withCode(words, code)), findsOneWidget);
        expect(find.text('${l10n.ticketStatusNotSent} · ${code.code}'), findsWidgets);
        await finish(tester);
      });
    }

    testWidgets('recording mode hides what people typed, in the list and in the conversation', (tester) async {
      Redactor.instance.enabled = true;
      final t = await seedSupport(tester, title: 'Cannot reach prod-db.example.com', body: 'prod-db.example.com times out.');
      await tester.runAsync(() async {
        server.staffReply(t.serverId!, 'Is mail.example.org reachable from there?');
        await service.refresh();
      });
      await pumpHub(tester, recording: true);
      expect(find.textContaining('prod-db.example.com'), findsNothing);
      expect(find.textContaining('mail.example.org'), findsNothing);
      await finish(tester);
    });

    /// What a field draws, which is not what it holds while the screen is
    /// recorded.
    String drawnIn(WidgetTester tester, String key) => tester
        .state<EditableTextState>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(EditableText)))
        .renderEditable
        .text!
        .toPlainText();

    testWidgets('recording mode hides the reply box too: bullets, and it goes as it was typed', (tester) async {
      Redactor.instance.enabled = true;
      await seedSupport(tester);
      await pumpHub(tester, recording: true);
      await tester.tap(find.byKey(const ValueKey('hub-reply')));
      await tester.enterText(find.byKey(const ValueKey('hub-reply')), 'prod-db.example.com\ntimes out');
      await tester.pump();
      expect(drawnIn(tester, 'hub-reply'), '${'•' * 'prod-db.example.com'.length}\n${'•' * 'times out'.length}');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(jsonDecode(server.calls('/messages').single.body)['body'], 'prod-db.example.com\ntimes out');
      await finish(tester);
    });

    testWidgets('recording mode hides the form: a draft brought back and the email draw as bullets, what they hold stays, '
        'and what is sent is masked where it is shown', (tester) async {
      Redactor.instance.enabled = false;
      final c = await pumpHub(tester, compose: TicketType.support);
      await tester.enterText(find.byKey(const ValueKey('hub-title')), 'Cannot reach prod-db.example.com');
      await tester.enterText(find.byKey(const ValueKey('hub-body')), 'prod-db.example.com\ntimes out');
      await tester.enterText(find.byKey(const ValueKey('hub-email')), 'sam@example.com');
      await settle(tester);
      expect(drawnIn(tester, 'hub-title'), 'Cannot reach prod-db.example.com', reason: 'recording is off');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.text('sessions'), findsOneWidget);

      Redactor.instance.enabled = true;
      c.read(recordingModeProvider.notifier).state = true;
      c.read(supportHubOpenProvider.notifier).state = true;
      await settle(tester);
      expect(drawnIn(tester, 'hub-title'), '•' * 'Cannot reach prod-db.example.com'.length, reason: 'one for each, so the cursor stays right');
      expect(drawnIn(tester, 'hub-body'), '${'•' * 'prod-db.example.com'.length}\n${'•' * 'times out'.length}');
      expect(drawnIn(tester, 'hub-email'), '•' * 'sam@example.com'.length);
      expect(
        tester.widget<TextField>(find.descendant(of: find.byKey(const ValueKey('hub-email')), matching: find.byType(TextField))).controller!.text,
        'sam@example.com',
        reason: 'what is held and sent is what was typed',
      );
      Redactor.instance.enabled = false;
      c.read(recordingModeProvider.notifier).state = false;
      await settle(tester);
      expect(drawnIn(tester, 'hub-title'), 'Cannot reach prod-db.example.com');
      await finish(tester);
    });

    testWidgets('a report still waiting to be sent shows what was written, and Try now sends it', (tester) async {
      final report = FeedbackReport(type: FeedbackType.bug, title: 'Waiting report', body: 'Written offline.', context: ctx);
      await pumpHub(tester);
      server.offline = true;
      final feedback = FeedbackService(db, prefs, client: MockClient(feedbackRoute), baseUrl: 'https://api.test/v1');
      await run(tester, () => feedback.send(report));
      await settle(tester);
      expect(inRow(report.nonce, l10n.ticketStatusWaiting), findsOneWidget);
      await tester.tap(rowOf(report.nonce));
      await settle(tester);
      expect(find.text('Written offline.'), findsOneWidget);
      expect(find.text(l10n.ticketWaitingNotice), findsOneWidget);
      server.offline = false;
      await tester.tap(find.byKey(const ValueKey('hub-report-try')));
      await settle(tester);
      expect(reports, hasLength(1));
      expect(rowOf(report.nonce), findsOneWidget, reason: 'the same row, now a ticket');
      expect(inRow(report.nonce, l10n.ticketStatusWaiting), findsNothing);
      await finish(tester);
    });
  });

  group('narrow windows and phones', () {
    testWidgets('under 800 the list comes first, then a conversation with the way back', (tester) async {
      final t = await seedSupport(tester);
      await pumpHub(tester, size: const Size(799, 700));
      expect(rowOf(t.nonce), findsOneWidget);
      expect(find.byKey(const ValueKey('hub-reply')), findsNothing, reason: 'nothing is opened by itself: an answer would count as read');
      await tester.tap(rowOf(t.nonce));
      await settle(tester);
      expect(rowOf(t.nonce), findsNothing);
      expect(find.byKey(const ValueKey('hub-reply')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('hub-back-to-list')));
      await settle(tester);
      expect(rowOf(t.nonce), findsOneWidget);
      await finish(tester);
    });

    testWidgets('in a short window the head goes up with the conversation', (tester) async {
      final t = await seedSupport(tester);
      await tester.runAsync(() async {
        for (var i = 0; i < 6; i++) {
          server.staffReply(t.serverId!, 'Answer $i with some words in it, so that it takes room on the screen.');
        }
        await service.refresh();
      });
      await pumpHub(tester, size: const Size(1200, 460));
      final thread = find.byKey(const ValueKey('hub-thread'));
      await tester.drag(thread, const Offset(0, 2000));
      await settle(tester);
      expect(within(thread, find.byKey(const ValueKey('hub-status'))), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a phone: the tabs, New and the search over the list; a board in one column; no screenshot to offer', (tester) async {
      server.addPublic(id: 'aaaaaaaaaaa1', type: 'suggestion', title: 'Mosh support for flaky connections', votes: 42, state: 'planned');
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        treeDatabaseProvider.overrideWithValue(db),
        dbReadyProvider.overrideWithValue(true),
        ticketServiceProvider.overrideWithValue(service),
        publicReportsServiceProvider.overrideWithValue(
            PublicReportsService(client: MockClient(server.handle), baseUrl: 'https://api.test/v1')),
        feedbackServiceProvider.overrideWithValue(
            FeedbackService(db, prefs, client: MockClient(feedbackRoute), baseUrl: 'https://api.test/v1')),
        cloudStatusProvider.overrideWith((_) async => CloudStatus.ok),
        appVersionLabelProvider.overrideWith((_) async => '3.3.0'),
        recordingModeProvider.overrideWith((ref) => false),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: SupportHubScreen(tab: HubTab.ideas, onClose: () {}),
        ),
      ));
      await settle(tester);
      for (final key in ['hub-tab-tickets', 'hub-tab-known', 'hub-tab-ideas', 'hub-new', 'hub-search', 'hub-close']) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      expect(container.read(supportHubTabProvider), HubTab.ideas);
      expect(find.text('Mosh support for flaky connections'), findsOneWidget);
      expect(find.byKey(const ValueKey('hub-board-compose')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'nothing overflows at a phone\'s width');
      await tester.tap(find.byKey(const ValueKey('hub-board-compose')));
      await settle(tester);
      expect(find.byKey(const ValueKey('hub-compose')), findsOneWidget);
      expect(find.byKey(const ValueKey('hub-back-to-list')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('hub-kind-bug')));
      await settle(tester);
      expect(find.byKey(const ValueKey('hub-screenshot-add')), findsNothing, reason: 'a phone takes no picture of the app');
      expect(find.byKey(const ValueKey('hub-diagnostics')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finish(tester);
    });
  });

  group('Known issues and Ideas', () {
    void seedBoards() {
      server
        ..addPublic(id: 'aaaaaaaaaaa1', type: 'suggestion', title: 'Mosh support for flaky connections',
            body: 'Keep sessions alive on bad Wi-Fi.', state: 'planned', votes: 42, comments: 9)
        ..addPublic(id: 'aaaaaaaaaaa2', type: 'suggestion', title: 'Serial console over USB', votes: 31, comments: 6)
        ..addPublic(id: 'aaaaaaaaaaa3', type: 'suggestion', title: 'Port forwarding on the free tier', state: 'shipped',
            version: '3.3', closed: true)
        ..addPublic(id: 'bbbbbbbbbbb1', type: 'bug', title: 'SFTP: deleting big folders is slow', state: 'fixed', version: '3.3.1', votes: 23)
        ..addPublic(id: 'bbbbbbbbbbb2', type: 'bug', title: 'Sync pauses after the PC sleeps', state: 'investigating', votes: 8);
    }

    testWidgets('Ideas: the cards with their votes and state, the filters, Recently shipped and how ideas get picked', (tester) async {
      seedBoards();
      final c = await pumpHub(tester);
      await tester.tap(find.byKey(const ValueKey('hub-tab-ideas')));
      await settle(tester);
      expect(c.read(supportHubTabProvider), HubTab.ideas);
      final mosh = find.byKey(const ValueKey('hub-report-aaaaaaaaaaa1'));
      expect(within(mosh, find.text('42')), findsOneWidget);
      expect(within(mosh, find.text(l10n.supportHubStatePlanned)), findsOneWidget);
      expect(within(mosh, find.text('Keep sessions alive on bad Wi-Fi.')), findsOneWidget);
      expect(within(mosh, find.textContaining(l10n.supportHubComments(9))), findsOneWidget);
      expect(within(find.byKey(const ValueKey('hub-report-aaaaaaaaaaa2')), find.text(l10n.supportHubStateUnderReview)), findsOneWidget);
      expect(find.byKey(const ValueKey('hub-report-aaaaaaaaaaa3')), findsNothing, reason: 'shipped ones are not among the open ideas');
      expect(tester.getTopLeft(mosh).dy, lessThan(tester.getTopLeft(find.byKey(const ValueKey('hub-report-aaaaaaaaaaa2'))).dy),
          reason: 'sorted by votes');
      expect(find.text(l10n.supportHubSortedByVotes), findsOneWidget);
      // Beside them.
      expect(find.text(l10n.supportHubRecentlyShipped.toUpperCase()), findsOneWidget);
      expect(find.text('Port forwarding on the free tier'), findsOneWidget);
      expect(find.text('3.3'), findsOneWidget);
      expect(find.text(l10n.supportHubHowPickedTitle), findsOneWidget);
      expect(find.text(l10n.supportHubHowPickedBy), findsOneWidget);
      // A filter.
      await tester.tap(find.byKey(const ValueKey('hub-board-filter-planned')));
      await settle(tester);
      expect(mosh, findsOneWidget);
      expect(find.byKey(const ValueKey('hub-report-aaaaaaaaaaa2')), findsNothing);
      // The hub's search.
      await tester.tap(find.byKey(const ValueKey('hub-board-filter-top')));
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('hub-search')), 'serial');
      await tester.pump();
      expect(mosh, findsNothing);
      expect(find.byKey(const ValueKey('hub-report-aaaaaaaaaaa2')), findsOneWidget);
      // "Suggest an idea" goes to the form, in My tickets.
      await tester.tap(find.byKey(const ValueKey('hub-board-compose')));
      await settle(tester);
      expect(c.read(supportHubTabProvider), HubTab.myTickets);
      expect(c.read(supportHubComposeProvider), TicketType.suggestion);
      await finish(tester);
    });

    testWidgets('a vote: with the account, once, taken back on a second click; the lists are read with no account', (tester) async {
      seedBoards();
      server.bearers['a-bearer'] = 'a-uid';
      bearer = 'a-bearer';
      await pumpHub(tester);
      await tester.tap(find.byKey(const ValueKey('hub-tab-ideas')));
      await settle(tester);
      final lists = server.requests.where((r) => r.url.path.endsWith('/reports'));
      expect(lists, isNotEmpty);
      for (final r in lists) {
        expect(r.headers.keys.map((k) => k.toLowerCase()), isNot(contains('authorization')), reason: 'a list carries no account');
      }
      final box = find.byKey(const ValueKey('hub-vote-aaaaaaaaaaa2'));
      await tester.tap(box);
      await settle(tester);
      expect(within(box, find.text('32')), findsOneWidget);
      expect(server.publicReports[1].voters, {'a-uid'});
      await tester.tap(box);
      await settle(tester);
      expect(within(box, find.text('31')), findsOneWidget);
      expect(server.publicReports[1].voters, isEmpty);
      await finish(tester);
    });

    testWidgets('a vote with nobody signed in is this device\'s: once, taken back on a second click, nothing asked', (tester) async {
      seedBoards();
      final c = await pumpHub(tester);
      await tester.tap(find.byKey(const ValueKey('hub-tab-ideas')));
      await settle(tester);
      final box = find.byKey(const ValueKey('hub-vote-aaaaaaaaaaa2'));
      await tester.tap(box);
      await settle(tester);
      expect(within(box, find.text('32')), findsOneWidget);
      expect(server.publicReports[1].voters, {'device:$hubDevice'});
      expect(guestVoted, {'aaaaaaaaaaa2'}, reason: 'kept on the device, the server is never asked');
      expect(server.requests.where((r) => r.url.path.endsWith('/reports/votes')), isEmpty);
      expect(said(c), isEmpty, reason: 'no sign-in asked for');
      final sent = server.requests.lastWhere((r) => r.url.path.endsWith('/vote'));
      expect(sent.headers.keys.map((k) => k.toLowerCase()), isNot(contains('authorization')));
      await tester.tap(box);
      await settle(tester);
      expect(within(box, find.text('31')), findsOneWidget);
      expect(server.publicReports[1].voters, isEmpty);

      // The total counts the +1s pressed in Discord too: what the server says is what shows.
      server.publicReports[1].votes = 40;
      await tester.tap(find.byKey(const ValueKey('hub-tab-known')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('hub-tab-ideas')));
      await settle(tester);
      expect(within(box, find.text('40')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('Known issues: bugs with "Fix in" and "Investigating", Recently fixed beside; unavailable says so and retries', (tester) async {
      seedBoards();
      await pumpHub(tester);
      await tester.tap(find.byKey(const ValueKey('hub-tab-known')));
      await settle(tester);
      expect(within(find.byKey(const ValueKey('hub-report-bbbbbbbbbbb1')), find.text(l10n.supportHubStateFixIn('3.3.1'))), findsOneWidget);
      expect(within(find.byKey(const ValueKey('hub-report-bbbbbbbbbbb2')), find.text(l10n.supportHubStateInvestigating)), findsOneWidget);
      expect(find.text(l10n.supportHubRecentlyFixed.toUpperCase()), findsOneWidget);
      expect(find.text(l10n.supportHubHowFixedTitle), findsOneWidget);
      expect(find.byKey(const ValueKey('hub-report-aaaaaaaaaaa1')), findsNothing, reason: 'no idea among the bugs');

      server.failWith = 503;
      await tester.tap(find.byKey(const ValueKey('hub-board-filter-newest')));
      await settle(tester);
      expect(find.byKey(const ValueKey('hub-board-unavailable')), findsOneWidget);
      server.failWith = null;
      await tester.tap(find.text(l10n.retry));
      await settle(tester);
      expect(find.byKey(const ValueKey('hub-board-unavailable')), findsNothing);
      expect(find.byKey(const ValueKey('hub-report-bbbbbbbbbbb2')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('everyone\'s words are masked while the screen is recorded', (tester) async {
      server.addPublic(id: 'ccccccccccc1', type: 'bug', title: 'Cannot reach prod-db.example.com', body: 'prod-db.example.com times out.');
      Redactor.instance.enabled = true;
      await pumpHub(tester, recording: true);
      await tester.tap(find.byKey(const ValueKey('hub-tab-known')));
      await settle(tester);
      expect(find.byKey(const ValueKey('hub-report-ccccccccccc1')), findsOneWidget);
      expect(find.textContaining('prod-db.example.com'), findsNothing);
      await finish(tester);
    });
  });

  group('the New report', () {
    Future<void> fill(WidgetTester tester, String key, String text) async {
      await tester.enterText(find.byKey(ValueKey(key)), text);
      await tester.pump();
    }

    TextField fieldOf(WidgetTester tester, String key) {
      final found = find.byKey(ValueKey(key));
      final at = tester.widget(found);
      if (at is TextField) return at;
      return tester.widget<TextField>(find.descendant(of: found, matching: find.byType(TextField)));
    }

    /// Waits out the pause before "Might already be reported" asks.
    /// A public report shows exactly what everyone will read before it
    /// goes (found in a 3.4 security review): posted as shown.
    Future<void> postPublic(WidgetTester tester) async {
      expect(find.byKey(const ValueKey('hub-public-preview')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('hub-public-send')));
      await settle(tester);
    }

    Future<void> pause(WidgetTester tester) async {
      await tester.pump(kSimilarPause);
      await settle(tester);
    }

    testWidgets('one switch: changing one\'s mind keeps what was typed, and each kind asks its own', (tester) async {
      await pumpHub(tester, compose: TicketType.bug);
      expect(find.text(l10n.supportHubWhatsWrong), findsOneWidget);
      expect(find.text(l10n.supportHubWhatHappened), findsOneWidget);
      expect(find.text(l10n.supportHubWhoCanSee), findsOneWidget);
      expect(find.text(l10n.supportHubSendReport), findsOneWidget);
      await fill(tester, 'hub-title', 'Keys stop working');
      await fill(tester, 'hub-body', 'After an upload.');

      await tester.tap(find.byKey(const ValueKey('hub-kind-suggestion')));
      await settle(tester);
      expect(find.text(l10n.supportHubWhatsIdea), findsOneWidget);
      expect(find.text(l10n.supportHubWhyIdea), findsOneWidget);
      expect(fieldOf(tester, 'hub-title').controller!.text, 'Keys stop working');
      expect(fieldOf(tester, 'hub-body').controller!.text, 'After an upload.');

      await tester.tap(find.byKey(const ValueKey('hub-kind-support')));
      await settle(tester);
      expect(find.text(l10n.supportHubWhatHelp), findsOneWidget);
      expect(find.text(l10n.supportMessageLabel), findsOneWidget);
      expect(find.byKey(const ValueKey('hub-email')), findsOneWidget);
      expect(find.text(l10n.supportHubWhoCanSee), findsNothing, reason: 'help is private, always');
      expect(find.text(l10n.supportHubSendTicket), findsOneWidget);
      expect(fieldOf(tester, 'hub-title').controller!.text, 'Keys stop working');
      await finish(tester);
    });

    testWidgets('a public bug goes to the report route with its diagnostics and screenshot; the post is the bot\'s to make without them', (tester) async {
      final shot = Uint8List.fromList(const [0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 0]);
      final container = await pumpHub(tester, compose: TicketType.bug, capture: (_) => shot);
      await fill(tester, 'hub-title', 'Keys stop working');
      await fill(tester, 'hub-body', 'After an upload.');
      await tester.ensureVisible(find.byKey(const ValueKey('hub-screenshot-add')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hub-screenshot-add')));
      await settle(tester);
      expect(find.byKey(const ValueKey('hub-screenshot')), findsOneWidget);
      expect(find.text(l10n.supportHubNamesBlurred), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('hub-diagnostics')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hub-send')));
      await settle(tester);
      expect(reports, isEmpty, reason: 'not before the person saw what everyone will read');
      await postPublic(tester);
      expect(reports, hasLength(1));
      final sent = reports.single;
      expect(sent['type'], 'bug');
      expect(sent['title'], 'Keys stop working');
      expect(sent['body'], 'After an upload.');
      expect(sent['contact'], isNull, reason: 'names removed: none is asked for');
      expect(sent['screenshot'], base64Encode(shot));
      expect(sent['diagnostics'], startsWith('ZestSSH diagnostics'), reason: 'ticked by the person');
      expect(server.calls('/tickets'), isEmpty, reason: 'a public report is not a private ticket');
      expect(container.read(supportHubComposeProvider), isNull);
      expect(said(container), contains(l10n.feedbackSentAnon));
      await tester.pump(const Duration(seconds: 4));
      await finish(tester);
    });

    testWidgets('a bug kept Private goes to the ticket route, never the report route, with what was attached', (tester) async {
      final shot = Uint8List.fromList(const [0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 0]);
      final container = await pumpHub(tester, compose: TicketType.bug, capture: (_) => shot);
      await fill(tester, 'hub-title', 'SFTP upload stalls');
      await fill(tester, 'hub-body', 'It sits at 60 percent.');
      await tester.ensureVisible(find.byKey(const ValueKey('hub-screenshot-add')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hub-screenshot-add')));
      await settle(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('hub-visibility-private')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hub-visibility-private')));
      await tester.pump();
      expect(find.text(l10n.supportHubSendTicket), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('hub-send')));
      await settle(tester);
      expect(reports, isEmpty, reason: 'never to Discord');
      final j = jsonDecode(server.calls('/tickets').single.body) as Map;
      expect(j['type'], 'bug');
      expect(j['title'], 'SFTP upload stalls');
      expect(j['screenshot'], base64Encode(shot));
      expect(j['diagnostics'], startsWith('ZestSSH diagnostics'));
      expect(container.read(supportHubComposeProvider), isNull);
      expect(within(find.byKey(const ValueKey('hub-who-sees')), find.text(l10n.supportHubPrivateOnlyYou)), findsOneWidget);
      expect(find.byKey(const ValueKey('hub-attached-shot')), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await finish(tester);
    });

    testWidgets('diagnostics unticked go nowhere; "See exactly what\'s sent" shows the request and the diagnostics, scrubbed', (tester) async {
      AppLogger.forget();
      AppLogger.remember(LogRecord(Level.WARNING, 'SFTP write to deploy@web-01.example.com stalled', 'ZestSSH'));
      addTearDown(AppLogger.forget);
      final c = await pumpHub(tester, compose: TicketType.suggestion);
      await fill(tester, 'hub-title', 'A colour per host');
      await fill(tester, 'hub-body', 'Production stands out.');
      await tester.ensureVisible(find.byKey(const ValueKey('hub-see-sent')));
      await tester.pump();
      expect(tester.widget<Checkbox>(find.byKey(const ValueKey('hub-diagnostics'))).value, isFalse,
          reason: 'off by default for a public idea');
      await tester.tap(find.byKey(const ValueKey('hub-diagnostics')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hub-see-sent')));
      await settle(tester);
      final payload = tester.widget<SelectableText>(find.byKey(const ValueKey('hub-sent-payload'))).data!;
      expect(payload, contains('"title": "A colour per host"'));
      expect(payload, contains(TicketToken.preview));
      final diagnostics = tester.widget<SelectableText>(find.byKey(const ValueKey('hub-sent-diagnostics'))).data!;
      expect(diagnostics, contains('App: ZestSSH 3.3.0 (340)'));
      expect(diagnostics, contains('stalled'));
      expect(diagnostics, isNot(contains('web-01.example.com')), reason: 'names and addresses are replaced first');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);

      await tester.tap(find.byKey(const ValueKey('hub-diagnostics')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hub-send')));
      await settle(tester);
      await postPublic(tester);
      expect(reports.single.containsKey('diagnostics'), isFalse);
      expect(reports.single['type'], 'suggestion');
      expect(c.read(supportHubComposeProvider), isNull);
      await tester.pump(const Duration(seconds: 4));
      await finish(tester);
    });

    testWidgets('Get help opens a private ticket, and shows it', (tester) async {
      final container = await pumpHub(tester, compose: TicketType.support);
      await fill(tester, 'hub-title', 'Cannot restore my purchase');
      await fill(tester, 'hub-body', 'I paid on my phone.');
      await fill(tester, 'hub-email', 'name@example.com');
      await tester.tap(find.byKey(const ValueKey('hub-send')));
      await settle(tester);
      final j = jsonDecode(server.calls('/tickets').single.body) as Map;
      expect(j['title'], 'Cannot restore my purchase');
      expect(j.containsKey('type'), isFalse, reason: 'a support ticket as before 3.4');
      expect(j['contact'], {'kind': 'email', 'value': 'name@example.com'});
      expect(j['include_account'], isFalse);
      expect(container.read(supportHubComposeProvider), isNull);
      expect(find.byKey(const ValueKey('hub-reply')), findsOneWidget);
      expect(said(container), contains(l10n.supportSentNumbered(server.tickets.values.single.number)));
      await tester.pump(const Duration(seconds: 4));
      await finish(tester);
    });

    testWidgets('Send with something missing names it and puts the cursor there; nothing goes out', (tester) async {
      await pumpHub(tester, compose: TicketType.support);
      await tester.tap(find.byKey(const ValueKey('hub-send')));
      await settle(tester);
      expect(find.text(l10n.supportMissingSubject), findsOneWidget);
      expect(fieldOf(tester, 'hub-title').focusNode!.hasFocus, isTrue);
      await fill(tester, 'hub-title', 'A subject');
      await tester.tap(find.byKey(const ValueKey('hub-send')));
      await settle(tester);
      expect(find.text(l10n.supportMissingMessage), findsOneWidget);
      expect(fieldOf(tester, 'hub-body').focusNode!.hasFocus, isTrue);
      await fill(tester, 'hub-body', 'A message');
      await fill(tester, 'hub-email', 'not an address');
      await tester.tap(find.byKey(const ValueKey('hub-send')));
      await settle(tester);
      expect(find.text(l10n.supportEmailInvalid), findsOneWidget);
      expect(server.calls('/tickets'), isEmpty);

      await tester.tap(find.byKey(const ValueKey('hub-kind-bug')));
      await settle(tester);
      await fill(tester, 'hub-title', '');
      await tester.tap(find.byKey(const ValueKey('hub-send')));
      await settle(tester);
      expect(find.text(l10n.supportHubMissingTitle), findsOneWidget);
      await fill(tester, 'hub-title', 'Keys stop working');
      await fill(tester, 'hub-body', '');
      await tester.tap(find.byKey(const ValueKey('hub-send')));
      await settle(tester);
      expect(find.text(l10n.reportSendMissingBody), findsOneWidget);
      expect(reports, isEmpty);
      await finish(tester);
    });

    testWidgets('a refusal leaves the form as it was, says why, and offers the text', (tester) async {
      await pumpHub(tester, compose: TicketType.bug);
      await fill(tester, 'hub-title', 'Keys stop working');
      await fill(tester, 'hub-body', 'After an upload.');
      reportStatus = 429;
      await tester.tap(find.byKey(const ValueKey('hub-send')));
      await settle(tester);
      await postPublic(tester);
      expect(find.text(l10n.feedbackRateLimited(5)), findsOneWidget);
      expect(find.byKey(const ValueKey('hub-failure')), findsOneWidget);
      expect(fieldOf(tester, 'hub-body').controller!.text, 'After an upload.');
      expect(find.text(l10n.helpOpenDiscord), findsOneWidget);
      reportStatus = 403;
      await tester.tap(find.byKey(const ValueKey('hub-send')));
      await settle(tester);
      await postPublic(tester);
      expect(find.text(l10n.feedbackBlocked), findsOneWidget);
      await finish(tester);
    });

    testWidgets('with no network a report is kept and in the list; a second press cannot post it twice', (tester) async {
      final container = await pumpHub(tester, compose: TicketType.bug);
      await fill(tester, 'hub-title', 'Written offline');
      await fill(tester, 'hub-body', 'Written offline.');
      server.offline = true;
      await tester.tap(find.byKey(const ValueKey('hub-send')));
      await settle(tester);
      await postPublic(tester);
      expect(container.read(supportHubComposeProvider), isNull);
      expect(said(container), contains(l10n.feedbackFailedQueued));
      expect(find.text(l10n.ticketStatusWaiting), findsWidgets);
      await tester.pump(const Duration(seconds: 4));
      container.read(supportHubComposeProvider.notifier).state = TicketType.bug;
      await settle(tester);
      expect(fieldOf(tester, 'hub-body').controller!.text, isEmpty);
      server.offline = false;
      await finish(tester);
    });

    testWidgets('closing keeps what was typed for the next time; Cancel asks, and takes it; with nothing typed it asks nothing', (tester) async {
      final container = await pumpHub(tester, compose: TicketType.bug);
      await fill(tester, 'hub-title', 'Half a thought');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.text('sessions'), findsOneWidget);
      container.read(supportHubOpenProvider.notifier).state = true;
      await settle(tester);
      expect(fieldOf(tester, 'hub-title').controller!.text, 'Half a thought', reason: 'back where it was');

      await tester.tap(find.byKey(const ValueKey('hub-discard')));
      await settle(tester);
      expect(find.text(l10n.supportHubDiscardTitle), findsOneWidget);
      await tester.tap(find.text(l10n.cancel).last);
      await settle(tester);
      expect(fieldOf(tester, 'hub-title').controller!.text, 'Half a thought');
      await tester.tap(find.byKey(const ValueKey('hub-discard')));
      await settle(tester);
      await tester.tap(find.text(l10n.supportHubDiscard).last);
      await settle(tester);
      expect(container.read(supportHubComposeProvider), isNull);

      container.read(supportHubComposeProvider.notifier).state = TicketType.bug;
      await settle(tester);
      expect(fieldOf(tester, 'hub-title').controller!.text, isEmpty);
      await tester.tap(find.byKey(const ValueKey('hub-discard')));
      await settle(tester);
      expect(find.text(l10n.supportHubDiscardTitle), findsNothing);
      expect(container.read(supportHubComposeProvider), isNull);
      await finish(tester);
    });

    // Found in a review: press Send, then Esc: the report was
    // posted, nothing was said, and the form came back ready to send it again.
    group('closed while Send is out', () {
      Future<ProviderContainer> sendThenClose(WidgetTester tester) async {
        final c = await pumpHub(tester, compose: TicketType.bug);
        await fill(tester, 'hub-title', 'Keys stop working');
        await fill(tester, 'hub-body', 'After an upload.');
        await pause(tester);
        holdRequests = Completer<void>();
        await tester.tap(find.byKey(const ValueKey('hub-send')));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('hub-public-send')));
        await tester.pump();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(find.text('sessions'), findsOneWidget);
        return c;
      }

      testWidgets('sent: it is said, and nothing of it comes back', (tester) async {
        final c = await sendThenClose(tester);
        holdRequests!.complete();
        await settle(tester);
        expect(reports, hasLength(1));
        expect(said(c), contains(l10n.feedbackSentAnon));
        expect(c.read(supportHubComposeProvider), isNull);
        c.read(supportHubOpenProvider.notifier).state = true;
        await settle(tester);
        expect(find.byKey(const ValueKey('hub-send')), findsNothing, reason: 'not the form, ready to send it again');
        expect(rowOf(reports.single['nonce'] as String), findsOneWidget, reason: 'it is in the list');
        await tester.pump(const Duration(seconds: 6));
        await finish(tester);
      });

      testWidgets('refused: said as well, and the words wait in the form', (tester) async {
        final c = await sendThenClose(tester);
        reportStatus = 403;
        holdRequests!.complete();
        await settle(tester);
        expect(said(c), contains(l10n.feedbackBlocked));
        c.read(supportHubOpenProvider.notifier).state = true;
        await settle(tester);
        expect(fieldOf(tester, 'hub-title').controller!.text, 'Keys stop working');
        expect(find.byKey(const ValueKey('hub-send')), findsOneWidget);
        await tester.pump(const Duration(seconds: 6));
        await finish(tester);
      });

      testWidgets('opened again before the answer: it cannot be sent twice', (tester) async {
        final c = await sendThenClose(tester);
        c.read(supportHubOpenProvider.notifier).state = true;
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('hub-send')), warnIfMissed: false);
        await tester.pump();
        holdRequests!.complete();
        await settle(tester);
        expect(reports, hasLength(1), reason: 'posted once');
        expect(find.byKey(const ValueKey('hub-send')), findsNothing);
        await tester.pump(const Duration(seconds: 6));
        await finish(tester);
      });
    });

    testWidgets('a screenshot: taken redacted when asked, a retake that fails keeps it, removed it stays out; Get help offers none', (tester) async {
      final shot = Uint8List.fromList(const [0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 0]);
      final asked = <bool>[];
      Uint8List? next = shot;
      final container = await pumpHub(tester, compose: TicketType.bug, capture: (redacted) {
        asked.add(redacted);
        return next;
      });
      expect(asked, isEmpty, reason: 'nothing is taken until asked for');
      await tester.ensureVisible(find.byKey(const ValueKey('hub-screenshot-add')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hub-screenshot-add')));
      await settle(tester);
      expect(asked, [true]);
      next = null;
      await tester.ensureVisible(find.byKey(const ValueKey('hub-screenshot-retake')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hub-screenshot-retake')));
      await settle(tester);
      expect(find.byKey(const ValueKey('hub-screenshot')), findsOneWidget);
      expect(said(container), contains(l10n.recModeCopyScreenshotFailed));
      await tester.pump(const Duration(seconds: 4));
      await tester.ensureVisible(find.byKey(const ValueKey('hub-screenshot-remove')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hub-screenshot-remove')));
      await tester.pump();
      expect(find.byKey(const ValueKey('hub-screenshot')), findsNothing);
      await fill(tester, 'hub-title', 'No picture');
      await fill(tester, 'hub-body', 'No picture after all.');
      await tester.tap(find.byKey(const ValueKey('hub-send')));
      await settle(tester);
      await postPublic(tester);
      expect(reports.single['screenshot'], isNull);
      await tester.pump(const Duration(seconds: 4));

      container.read(supportHubComposeProvider.notifier).state = TicketType.support;
      await settle(tester);
      expect(find.byKey(const ValueKey('hub-screenshot-add')), findsNothing);
      await finish(tester);
    });

    testWidgets('"Might already be reported": everyone\'s listed reports like the title, with Me too; only the title\'s words are asked about', (tester) async {
      server
        ..addPublic(id: 'ddddddddddd1', type: 'bug', title: 'SFTP: deleting big folders is slow, no progress shown',
            state: 'fixed', version: '3.3.1', votes: 23)
        ..addPublic(id: 'ddddddddddd2', type: 'bug', title: 'Delete in SFTP looks frozen until it finishes',
            state: 'investigating', votes: 8)
        ..addPublic(id: 'ddddddddddd3', type: 'bug', title: 'Host key warning after changing jump host', votes: 2);
      server.bearers['a-bearer'] = 'a-uid';
      bearer = 'a-bearer';
      await pumpHub(tester, compose: TicketType.bug);
      await fill(tester, 'hub-body', 'Ten minutes for 40k files over sftp, deleting.');
      await pause(tester);
      expect(find.byKey(const ValueKey('hub-similar')), findsNothing, reason: 'the text is not searched: the title is');
      expect(server.requests.where((r) => r.url.path.endsWith('/similar')), isEmpty);

      await fill(tester, 'hub-title', 'Deleting a folder over SFTP takes forever');
      await pause(tester);
      expect(find.text(l10n.supportHubMightBeReported), findsOneWidget);
      expect(find.byKey(const ValueKey('hub-similar-ddddddddddd1')), findsOneWidget);
      expect(find.byKey(const ValueKey('hub-similar-ddddddddddd2')), findsOneWidget);
      expect(find.byKey(const ValueKey('hub-similar-ddddddddddd3')), findsNothing);
      expect(find.text(l10n.supportHubStateFixIn('3.3.1')), findsOneWidget);
      expect(find.text(l10n.supportHubPeopleHaveThis(23)), findsOneWidget);
      final asked = server.requests.where((r) => r.url.path.endsWith('/similar')).last;
      expect(asked.url.queryParameters['q'], 'Deleting a folder over SFTP takes forever');
      expect(asked.headers.keys.map((k) => k.toLowerCase()), isNot(contains('authorization')));

      await tester.tap(find.byKey(const ValueKey('hub-metoo-ddddddddddd1')));
      await settle(tester);
      expect(server.publicReports.first.voters, {'a-uid'});
      expect(find.text(l10n.supportHubPeopleHaveThis(24)), findsOneWidget);
      expect(reports, isEmpty, reason: 'Me too is not a new report');
      await finish(tester);
    });

    testWidgets('a public report: its words scrubbed as diagnostics are, shown with what was taken out marked, Edit goes back', (tester) async {
      ReportScrub.registerHosts(['prod-db-7']);
      addTearDown(ReportScrub.clearFolders);
      await pumpHub(tester, compose: TicketType.bug);
      await fill(tester, 'hub-title', 'prod-db-7 drops SFTP');
      await fill(tester, 'hub-body', 'Connecting to acme-billing.com with password hunter2 fails.');
      await tester.tap(find.byKey(const ValueKey('hub-send')));
      await settle(tester);
      expect(find.text(l10n.supportHubPublicPreviewTitle), findsOneWidget);
      expect(find.text(l10n.supportHubPublicPreviewChanged), findsOneWidget);
      final body = tester.widget<SelectableText>(find.byKey(const ValueKey('hub-public-preview-1'))).textSpan!;
      expect(body.toPlainText(), 'Connecting to <domain> with password [removed] fails.');
      final marked = <String>[];
      body.visitChildren((span) {
        if (span is TextSpan && span.style?.backgroundColor != null) marked.add(span.text!);
        return true;
      });
      expect(marked, ['<domain>', '[removed]']);
      // Edit: nothing goes, the words stay as typed.
      await tester.tap(find.byKey(const ValueKey('hub-public-edit')));
      await settle(tester);
      expect(reports, isEmpty);
      expect(fieldOf(tester, 'hub-title').controller!.text, 'prod-db-7 drops SFTP');
      await tester.tap(find.byKey(const ValueKey('hub-send')));
      await settle(tester);
      await postPublic(tester);
      expect(reports.single['title'], '<host> drops SFTP');
      expect(reports.single['body'], 'Connecting to <domain> with password [removed] fails.');
      await tester.pump(const Duration(seconds: 4));
      await finish(tester);
    });

    testWidgets('a private bug report and a support ticket are not scrubbed, and show no public preview', (tester) async {
      await pumpHub(tester, compose: TicketType.bug);
      await fill(tester, 'hub-title', 'acme-billing.com drops SFTP');
      await fill(tester, 'hub-body', 'Since this morning.');
      await tester.ensureVisible(find.byKey(const ValueKey('hub-visibility-private')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hub-visibility-private')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hub-send')));
      await settle(tester);
      expect(find.byKey(const ValueKey('hub-public-preview')), findsNothing);
      expect((jsonDecode(server.calls('/tickets').single.body) as Map)['title'], 'acme-billing.com drops SFTP');
      await tester.pump(const Duration(seconds: 4));
      await finish(tester);
    });

    testWidgets('who can see it promises only what is true', (tester) async {
      await pumpHub(tester, compose: TicketType.bug);
      expect(find.text(l10n.supportHubPublicNamesRemoved), findsOneWidget);
      expect(l10n.supportHubPublicNamesRemoved, isNot(contains('names removed')));
      expect(find.text(l10n.supportHubPublicSubBug), findsOneWidget);
      expect(l10n.supportHubPublicSubBug, contains('What you write is public'));
      await finish(tester);
    });

    testWidgets('"Include diagnostics" is off but for a Private bug report, follows the choice, and is not remembered', (tester) async {
      bool ticked() => tester.widget<Checkbox>(find.byKey(const ValueKey('hub-diagnostics'))).value!;
      final c = await pumpHub(tester, compose: TicketType.bug);
      expect(ticked(), isFalse, reason: 'a public bug report');
      await tester.ensureVisible(find.byKey(const ValueKey('hub-visibility-private')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hub-visibility-private')));
      await tester.pump();
      expect(ticked(), isTrue, reason: 'a private bug report, where it helps support');
      await tester.tap(find.byKey(const ValueKey('hub-diagnostics')));
      await tester.pump();
      expect(ticked(), isFalse);
      await tester.tap(find.byKey(const ValueKey('hub-visibility-public')));
      await tester.pump();
      expect(ticked(), isFalse);
      await tester.tap(find.byKey(const ValueKey('hub-diagnostics')));
      await tester.pump();
      expect(ticked(), isTrue);
      await tester.tap(find.byKey(const ValueKey('hub-kind-suggestion')));
      await settle(tester);
      expect(ticked(), isFalse, reason: 'an idea: the choice made for a bug is not carried');
      await tester.tap(find.byKey(const ValueKey('hub-kind-support')));
      await settle(tester);
      expect(ticked(), isFalse, reason: 'Get help');
      // Closed and opened again with words in it: the choice is not kept.
      await fill(tester, 'hub-title', 'Half a thought');
      await tester.tap(find.byKey(const ValueKey('hub-kind-bug')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('hub-diagnostics')));
      await tester.pump();
      expect(ticked(), isTrue);
      c.read(supportHubComposeProvider.notifier).state = null;
      await settle(tester);
      c.read(supportHubComposeProvider.notifier).state = TicketType.bug;
      await settle(tester);
      expect(fieldOf(tester, 'hub-title').controller!.text, 'Half a thought');
      expect(ticked(), isFalse);
      await finish(tester);
    });

    testWidgets('a private one\'s title is never sent to look for others like it', (tester) async {
      server.addPublic(id: 'ddddddddddd1', type: 'bug', title: 'Deleting a folder over SFTP is slow', votes: 3);
      await pumpHub(tester, compose: TicketType.bug);
      await tester.ensureVisible(find.byKey(const ValueKey('hub-visibility-private')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hub-visibility-private')));
      await tester.pump();
      await fill(tester, 'hub-title', 'Deleting a folder over SFTP takes forever');
      await pause(tester);
      expect(server.requests.where((r) => r.url.path.endsWith('/similar')), isEmpty);
      expect(find.byKey(const ValueKey('hub-similar')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('hub-visibility-public')));
      await pause(tester);
      expect(server.requests.where((r) => r.url.path.endsWith('/similar')), hasLength(1), reason: 'public again: looked up');
      await finish(tester);
    });

    testWidgets('a report or a ticket refused for what was attached says so, and goes without it, the words kept', (tester) async {
      final shot = Uint8List.fromList(const [0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 0]);
      await pumpHub(tester, compose: TicketType.bug, capture: (_) => shot);
      await fill(tester, 'hub-title', 'Keys stop working');
      await fill(tester, 'hub-body', 'After an upload.');
      await tester.ensureVisible(find.byKey(const ValueKey('hub-screenshot-add')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hub-screenshot-add')));
      await settle(tester);
      server.refuseAttachments = (status: 429, code: 'attachments_paused', retryAfter: 7200);
      await tester.tap(find.byKey(const ValueKey('hub-send')));
      await settle(tester);
      await postPublic(tester);
      expect(reports, isEmpty);
      expect(find.text(l10n.supportAttachmentsPaused), findsOneWidget);
      expect(fieldOf(tester, 'hub-body').controller!.text, 'After an upload.');
      await tester.ensureVisible(find.byKey(const ValueKey('hub-send-without-attachments')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hub-send-without-attachments')));
      await settle(tester);
      await postPublic(tester);
      expect(reports.single['body'], 'After an upload.');
      expect(reports.single['screenshot'], isNull);
      expect(reports.single.containsKey('diagnostics'), isFalse);
      await tester.pump(const Duration(seconds: 4));

      // A private one, by the ticket route.
      server.refuseAttachments = (status: 429, code: 'attachments_hourly', retryAfter: 3600);
      final c = await pumpHub(tester, compose: TicketType.bug, capture: (_) => shot);
      await fill(tester, 'hub-title', 'Upload stalls');
      await fill(tester, 'hub-body', 'At 60 percent.');
      await tester.ensureVisible(find.byKey(const ValueKey('hub-visibility-private')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hub-visibility-private')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hub-send')));
      await settle(tester);
      expect(find.text(l10n.supportAttachmentsHourly(60)), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('hub-send-without-attachments')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hub-send-without-attachments')));
      await settle(tester);
      final j = jsonDecode(server.calls('/tickets').last.body) as Map;
      expect(j['title'], 'Upload stalls');
      expect(j.containsKey('diagnostics'), isFalse);
      expect(c.read(supportHubComposeProvider), isNull, reason: 'sent');
      await tester.pump(const Duration(seconds: 4));
      await finish(tester);
    });

    testWidgets('Get help asks nothing of the public lists', (tester) async {
      await pumpHub(tester, compose: TicketType.support);
      await fill(tester, 'hub-title', 'Deleting a folder over SFTP takes forever');
      await pause(tester);
      expect(server.requests.where((r) => r.url.path.contains('/reports')), isEmpty);
      await finish(tester);
    });
  });

  group('the Help panel beside a session', () {
    Future<ProviderContainer> pumpPanel(WidgetTester tester) async {
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        treeDatabaseProvider.overrideWithValue(db),
        dbReadyProvider.overrideWithValue(true),
        ticketServiceProvider.overrideWithValue(service),
        publicReportsServiceProvider.overrideWithValue(
            PublicReportsService(client: MockClient(server.handle), baseUrl: 'https://api.test/v1')),
        helpDockProvider.overrideWith((_) => HelpPage.home),
        cloudStatusProvider.overrideWith((_) async => CloudStatus.ok),
        appVersionLabelProvider.overrideWith((_) async => '3.3.0'),
        recordingModeProvider.overrideWith((ref) => false),
      ]);
      addTearDown(container.dispose);
      await tester.binding.setSurfaceSize(const Size(1440, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Row(
              children: [
                const Expanded(child: SizedBox()),
                HelpDock(
                  captureScreenshot: ({required bool redacted}) async => null,
                  onCopyRedactedScreenshot: () {},
                  onOpenShortcuts: () {},
                  onAbout: () {},
                ),
              ],
            ),
          ),
        ),
      ));
      await settle(tester);
      return container;
    }

    testWidgets('a reply waiting, known issues, the ways in touch, and each opens the hub where it belongs', (tester) async {
      server
        ..addPublic(id: 'eeeeeeeeeee1', type: 'bug', title: 'SFTP: deleting big folders is slow', state: 'fixed', version: '3.3.1', votes: 23)
        ..addPublic(id: 'eeeeeeeeeee2', type: 'bug', title: 'Sync pauses after the PC sleeps', state: 'investigating', votes: 8);
      final t = await seedSupport(tester, title: 'SFTP upload stalls on files over 2 GB');
      await tester.runAsync(() async {
        server.staffReply(t.serverId!, 'Can you update?');
        await service.refresh();
      });
      final c = await pumpPanel(tester);
      expect(find.byKey(const ValueKey('help-replied')), findsOneWidget);
      expect(within(find.byKey(const ValueKey('help-replied')), find.text('SFTP upload stalls on files over 2 GB')), findsOneWidget);
      expect(find.byKey(const ValueKey('help-known-eeeeeeeeeee1')), findsOneWidget);
      expect(find.text(l10n.supportHubStateFixIn('3.3.1')), findsOneWidget);
      expect(find.text(l10n.helpNeedsYourReply(1)), findsOneWidget);
      expect(find.text(l10n.helpFaqHostKeyChanged), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('help-replied-open')));
      await settle(tester);
      expect(c.read(supportHubOpenProvider), isTrue);
      expect(c.read(helpDockProvider), isNull);
      expect(c.read(supportHubTabProvider), HubTab.myTickets);
      expect(c.read(supportHubTicketProvider), t.nonce);

      for (final (key, tab, compose) in [
        ('help-open-hub', HubTab.myTickets, TicketType.support),
        ('help-my-tickets', HubTab.myTickets, null),
        ('help-ideas', HubTab.ideas, null),
      ]) {
        c.read(supportHubOpenProvider.notifier).state = false;
        c.read(helpDockProvider.notifier).state = HelpPage.home;
        await settle(tester);
        await tester.ensureVisible(find.byKey(ValueKey(key)));
        await tester.pump();
        await tester.tap(find.byKey(ValueKey(key)));
        await settle(tester);
        expect(c.read(supportHubOpenProvider), isTrue, reason: key);
        expect(c.read(supportHubTabProvider), tab, reason: key);
        expect(c.read(supportHubComposeProvider), compose, reason: key);
      }
      c.read(supportHubOpenProvider.notifier).state = false;
      c.read(helpDockProvider.notifier).state = HelpPage.home;
      await settle(tester);
      await tester.tap(find.text(l10n.helpSeeAll));
      await settle(tester);
      expect(c.read(supportHubTabProvider), HubTab.knownIssues);
      await finish(tester);
    });

    testWidgets('Copy diagnostics puts the version, the system and the last log lines on the clipboard, scrubbed', (tester) async {
      AppLogger.forget();
      AppLogger.remember(LogRecord(Level.WARNING, 'Connection to admin@db-07.example.net refused', 'ZestSSH'));
      addTearDown(AppLogger.forget);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final c = await pumpPanel(tester);
      await tester.tap(find.byKey(const ValueKey('help-copy-diagnostics')));
      await settle(tester);
      expect(copied, startsWith('ZestSSH diagnostics\nApp: ZestSSH 3.3.0 (340)'));
      expect(copied, contains('refused'));
      expect(copied, isNot(contains('db-07.example.net')));
      expect(said(c), contains(l10n.helpDiagnosticsCopied));
      await tester.pump(const Duration(seconds: 4));
      await finish(tester);
    });
  });

  group('what the hub keeps of a ticket', () {
    test('the facts it was sent with survive the conversation being read anew and a reply', () async {
      final res = await service.createSupport(title: 'Subject', body: 'Text.', context: ctx, includeAccount: false);
      var row = (await service.ticket(res.nonce!))!;
      expect(row.cachedConversation!.sentWith!.appVersion, '3.3.0');
      expect(row.cachedConversation!.accountIncluded, isFalse);

      server.staffReply(row.serverId!, 'An answer.');
      await service.open(row.nonce);
      row = (await service.ticket(row.nonce))!;
      expect(row.cachedConversation!.messages, hasLength(1));
      expect(row.cachedConversation!.sentWith!.osVersion, 'Windows 11 24H2');

      await service.reply(row.nonce, 'Thanks.');
      row = (await service.ticket(row.nonce))!;
      expect(row.cachedConversation!.messages, hasLength(2));
      expect(row.cachedConversation!.sentWith!.build, 340);
    });

    test('the box "include my account" is remembered', () async {
      server.bearers['a-bearer'] = 'a-uid';
      final signedIn = TicketService(db, client: MockClient(server.handle), baseUrl: 'https://api.test/v1', bearer: () async => 'a-bearer');
      final res = await signedIn.createSupport(title: 'Subject', body: 'Text.', context: ctx, includeAccount: true);
      expect((await signedIn.ticket(res.nonce!))!.cachedConversation!.accountIncluded, isTrue);
    });

    test('a report keeps its facts too; an old cache without them still reads', () async {
      final report = FeedbackReport(type: FeedbackType.bug, title: 'T', body: 'B', context: ctx);
      final t = server.addReport(token: report.ticketToken, title: 'T', body: 'B');
      await service.keepReport(report, id: t.id, number: t.number);
      expect((await service.ticket(report.nonce))!.cachedConversation!.sentWith!.platform, 'windows');

      final old = TicketConversation.decode('{"body":"B","messages":[]}')!;
      expect(old.sentWith, isNull);
      expect(old.accountIncluded, isFalse);
      expect(old.body, 'B');
    });

    test('a refused ticket can be tried again; one with nothing to send cannot', () async {
      server.offline = true;
      final res = await service.createSupport(title: 'Subject', body: 'Text.', context: ctx);
      server.offline = false;
      server.failWith = 400;
      await service.retryPending();
      server.failWith = null;
      var row = (await service.ticket(res.nonce!))!;
      expect(row.isRefused, isTrue);
      expect(await service.retryRefused(row.nonce), isTrue);
      await service.retryPending();
      row = (await service.ticket(row.nonce))!;
      expect(row.isSent, isTrue);
      expect(await service.retryRefused(row.nonce), isFalse, reason: 'it has arrived');
      expect(await service.retryRefused('no-such-ticket'), isFalse);
    });
  });

  // The 4.0 accessibility pass: the hub on a computer, its
  // home and each of its forms, holds to the checks every screen of the pass
  // does: each control a screen reader can press has a name, a pointer's
  // target is 32 square, and the words read on what they are drawn on.
  testWidgets('the hub and its forms: names, targets, contrast (the 4.0 accessibility pass)', (tester) async {
    final handle = tester.ensureSemantics();
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpHub(tester);
      final failures = await a11yCheck(tester, computer: true, where: 'Support hub');
      for (final type in TicketType.values) {
        await pumpHub(tester, compose: type);
        failures.addAll(await a11yCheck(tester, computer: true, where: 'Support hub, ${type.name}'));
      }
      expect(failures, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      handle.dispose();
    }
    await finish(tester);
  });
}

typedef ScreenshotCaptureForTest = Uint8List? Function(bool redacted);
