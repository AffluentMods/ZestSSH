import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/testing.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/features/feedback/feedback_service.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/tickets/ticket_models.dart';
import 'package:zestssh/features/tickets/ticket_service.dart';
import 'package:zestssh/features/tickets/ticket_token.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/providers/help_status_provider.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/ui/screens/desktop/widgets/help_dock.dart';
import 'package:zestssh/ui/screens/help/contact_support_screen.dart';
import 'package:zestssh/ui/screens/help/ticket_detail_screen.dart';
import 'package:zestssh/ui/screens/help/ticket_widgets.dart';
import 'package:zestssh/ui/screens/help/tickets_screen.dart';
import 'package:zestssh/ui/screens/settings/help_support_screen.dart';
import 'package:zestssh/ui/widgets/tab_focus_traversal.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/redactor.dart';

import '../features/tickets/fake_ticket_server.dart';
import '../a11y/a11y_checks.dart';

/// Tickets on screen, driven through the real
/// service and database against the in-memory server: the Help panel's My
/// tickets and Get help levels, the support form, a ticket's conversation,
/// and the same pages as phone screens.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  const ctx = FeedbackContext(
    appVersion: '3.0.0',
    build: 300,
    platform: 'windows',
    osVersion: 'Windows 11',
    locale: 'en-US',
    tier: 'free',
  );

  late AppDatabase db;
  late FakeTicketServer server;
  late TicketService service;
  late SharedPreferences prefs;

  test('the line over tickets that could not be read anew says which failure it was, with its code', () {
    addTearDown(() => currentCloudReach = null);
    expect(ticketsStaleText(l10n, const SocketException('Connection refused')),
        l10n.ticketsStaleWhy(l10n.cloudChipNotResponding, 'ZS-1101'));
    expect(ticketsStaleText(l10n, 'HTTP 503'), l10n.ticketsStaleWhy(l10n.cloudChipFault, 'ZS-1103'));
    expect(l10n.ticketsStaleWhy(l10n.cloudChipFault, 'ZS-1103'),
        'ZestSSH Cloud fault (ZS-1103). This is what was read last.');
    // An answer that is no fault of the service, nothing known of what
    // stopped it, or something on this device: the sentence there was.
    for (final other in <Object?>['HTTP 429', 'HTTP 200', 'HTTP 403', null, StateError('on this device')]) {
      expect(ticketsStaleText(l10n, other), l10n.ticketsOffline, reason: '$other');
    }
    // The device known to be offline: said as the device.
    final reach = CloudReachService(check: () async => 200);
    addTearDown(reach.dispose);
    currentCloudReach = reach;
    reach.networkChanged(up: false);
    expect(ticketsStaleText(l10n, const SocketException('Connection refused')),
        l10n.ticketsStaleWhy(l10n.cloudChipOffline, 'ZS-1102'));
    // Every language says which failure and its code, and that this is
    // what was read last, in words of its own.
    final seen = <String>{};
    for (final locale in AppLocalizations.supportedLocales) {
      final words = lookupAppLocalizations(locale).ticketsStaleWhy('WHY', 'CODE');
      expect(words, contains('WHY'), reason: '$locale');
      expect(words, contains('CODE'), reason: '$locale');
      expect(words.replaceAll('WHY', '').replaceAll('CODE', '').trim().length, greaterThan(8), reason: '$locale');
      seen.add(words);
    }
    expect(seen, hasLength(AppLocalizations.supportedLocales.length));
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    PackageInfo.setMockInitialValues(
      appName: 'ZestSSH',
      packageName: 'com.affluentlabs.zestssh',
      version: '3.0.0',
      buildNumber: '300',
      buildSignature: '',
    );
    db = AppDatabase.forTesting(NativeDatabase.memory());
    server = FakeTicketServer();
    service = TicketService(db, client: MockClient(server.handle), baseUrl: 'https://api.test/v1');
    Redactor.instance.enabled = false;
  });
  tearDown(() async {
    Redactor.instance.enabled = false;
    await db.close();
  });

  /// Lets the database's streams and the service's futures run.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// Runs [body] once a screen is up: in the screen's own zone, pumping
  /// until it is done. (A database call made with runAsync while a screen
  /// watches the same database waits for ever: the screen's query sits in
  /// front of it and only a pump can finish it.)
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

  List<Override> overrides({HelpPage? page, bool recording = false}) => [
        sharedPreferencesProvider.overrideWithValue(prefs),
        treeDatabaseProvider.overrideWithValue(db),
        dbReadyProvider.overrideWithValue(true),
        ticketServiceProvider.overrideWithValue(service),
        feedbackServiceProvider.overrideWithValue(
            FeedbackService(db, prefs, client: MockClient(server.handle), baseUrl: 'https://api.test/v1')),
        if (page != null) helpDockProvider.overrideWith((_) => page),
        cloudStatusProvider.overrideWith((_) async => CloudStatus.ok),
        appVersionLabelProvider.overrideWith((_) async => '3.0.0'),
        recordingModeProvider.overrideWith((ref) => recording),
      ];

  /// The desktop Help panel beside the rest of the window.
  Future<ProviderContainer> pumpDock(WidgetTester tester, HelpPage page, {bool recording = false}) async {
    await tester.binding.setSurfaceSize(const Size(1200, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer(overrides: overrides(page: page, recording: recording));
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        builder: (context, child) => TabMovesFocus(child: child!),
        home: Scaffold(
          body: Row(
            children: [
              const Expanded(child: SizedBox()),
              Consumer(builder: (context, ref, _) {
                if (ref.watch(helpDockProvider) == null) return const Text('help closed');
                return HelpDock(
                  captureScreenshot: ({required bool redacted}) async => null,
                  onCopyRedactedScreenshot: () {},
                  onOpenShortcuts: () {},
                  onAbout: () {},
                );
              }),
            ],
          ),
        ),
      ),
    ));
    await settle(tester);
    return container;
  }

  /// A support ticket that reached the server, made outside the screens.
  Future<SupportTicketRow> seedSupport(WidgetTester tester,
      {String title = 'Cannot restore my purchase',
      String body = 'I paid on my phone and the PC still says Free.'}) async {
    late SupportTicketRow row;
    await tester.runAsync(() async {
      final res = await service.createSupport(title: title, body: body, context: ctx);
      row = (await service.ticket(res.nonce!))!;
    });
    return row;
  }

  /// A ticket's row, read while a screen is up.
  Future<SupportTicketRow> rowOf(WidgetTester tester, String nonce) async =>
      (await run<SupportTicketRow?>(tester, () => service.ticket(nonce)))!;

  Finder field(String label) => find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == label);

  group('the Help panel', () {
    testWidgets('home has My tickets; an answer waiting is counted on it, and said above', (tester) async {
      final t = await seedSupport(tester);
      await pumpDock(tester, HelpPage.home);
      expect(find.text(l10n.ticketsTitle), findsOneWidget);
      expect(find.text(l10n.ticketsSub), findsOneWidget);
      expect(find.byKey(const ValueKey('help-replied')), findsNothing);

      server.staffReply(t.serverId!, 'Which store did you buy it from?');
      await run(tester, service.refresh);
      await settle(tester);
      // (3.4, the Help panel's design: how many wait on the
      // person, and the newest answer as a banner over the panel.)
      expect(find.text(l10n.helpNeedsYourReply(1)), findsOneWidget, reason: 'the row says why it is lit');
      expect(find.text(l10n.ticketsSub), findsNothing);
      expect(find.text('1'), findsOneWidget, reason: 'the count');
      expect(find.byKey(const ValueKey('help-replied')), findsOneWidget);
      // It sits with the other ways to get in touch, after Contact support.
      expect(tester.getTopLeft(find.text(l10n.ticketsTitle)).dy,
          greaterThan(tester.getTopLeft(find.text(l10n.helpContactSupport)).dy));
      await finish(tester);
    });

    testWidgets('Get help offers writing here first, then Discord and email', (tester) async {
      await pumpDock(tester, HelpPage.support);
      expect(find.text(l10n.helpSupportBody), findsOneWidget);
      expect(find.text(l10n.supportWrite), findsOneWidget);
      expect(find.text(l10n.supportWriteSub), findsOneWidget);
      expect(find.text(l10n.helpOpenDiscord), findsOneWidget);
      expect(tester.getTopLeft(find.text(l10n.supportWrite)).dy,
          lessThan(tester.getTopLeft(find.text(l10n.helpOpenDiscord)).dy));

      await tester.tap(find.text(l10n.supportWrite));
      await settle(tester);
      expect(find.text(l10n.supportSubjectLabel), findsOneWidget);
      expect(find.text(l10n.supportPrivateNotice), findsOneWidget);
      // Back returns to Get help, where the form was opened from.
      await tester.tap(find.bySemanticsLabel(l10n.back));
      await settle(tester);
      expect(find.text(l10n.helpSupportBody), findsOneWidget);
      await finish(tester);
    });
  });

  group('the support form', () {
    testWidgets('names what is missing, then sends and opens the ticket; nothing but the form goes', (tester) async {
      final container = await pumpDock(tester, HelpPage.contactSupport);
      // Signed out: there is no account to include, so the box is not there.
      expect(find.text(l10n.supportIncludeAccount), findsNothing);
      expect(find.text(l10n.supportPrivateNotice), findsOneWidget);
      expect(find.text(l10n.supportEmailDesc), findsOneWidget);

      await tester.tap(find.text(l10n.feedbackSend));
      await settle(tester);
      expect(find.text(l10n.supportMissingSubject), findsOneWidget);
      expect(server.requests, isEmpty);

      await tester.enterText(find.byType(TextField).at(0), 'Cannot restore my purchase');
      await tester.tap(find.text(l10n.feedbackSend));
      await settle(tester);
      expect(find.text(l10n.supportMissingSubject), findsNothing);
      expect(find.text(l10n.supportMissingMessage), findsOneWidget);

      await tester.enterText(find.byType(TextField).at(1), 'I paid on my phone and the PC still says Free.');
      await tester.enterText(find.byType(TextField).at(2), 'not an address');
      await tester.tap(find.text(l10n.feedbackSend));
      await settle(tester);
      expect(find.text(l10n.supportEmailInvalid), findsOneWidget);
      expect(server.requests, isEmpty, reason: 'nothing leaves while the form is not right');

      await tester.enterText(find.byType(TextField).at(2), 'kit@example.com');
      await tester.tap(find.text(l10n.feedbackSend));
      await settle(tester);

      // On the server: private, with what was typed and nothing of an account.
      final onServer = server.tickets.values.single;
      expect(onServer.type, 'support');
      expect(onServer.title, 'Cannot restore my purchase');
      expect(onServer.body, 'I paid on my phone and the PC still says Free.');
      expect(onServer.contact, {'kind': 'email', 'value': 'kit@example.com'});
      expect(onServer.account, isNull);
      final sent = server.calls('/tickets').single;
      expect(sent.headers.containsKey('Authorization'), isFalse);
      expect((jsonDecode(sent.body) as Map)['include_account'], isFalse);

      // The panel is on the ticket's own page.
      expect(container.read(helpDockProvider), HelpPage.ticket);
      expect(find.text('Cannot restore my purchase'), findsOneWidget);
      expect(find.text('I paid on my phone and the PC still says Free.'), findsOneWidget);
      expect(find.text(l10n.ticketPrivateLine), findsOneWidget);
      expect(find.text(l10n.ticketAwaitingSupport), findsOneWidget);
      expect(find.text('${l10n.ticketTypeSupport} #${onServer.number}'), findsOneWidget);
      // Said once, as it happens (on a computer a notice, not a snackbar).
      // With the number the server gave it: the proof it arrived.
      expect(container.read(notificationCenterProvider).history.map((n) => n.title),
          [l10n.supportSentNumbered(onServer.number)]);
      await finish(tester);
    });

    testWidgets('a message with no subject is not sent', (tester) async {
      await pumpDock(tester, HelpPage.contactSupport);
      await tester.enterText(find.byType(TextField).at(1), 'I paid on my phone and the PC still says Free.');
      await tester.tap(find.text(l10n.feedbackSend));
      await settle(tester);
      expect(find.text(l10n.supportMissingSubject), findsOneWidget);
      expect(server.requests, isEmpty);
      expect(await run<bool>(tester, service.hasWaiting), isFalse,
          reason: 'nothing is kept to send later either');
      expect(await run<bool>(tester, service.hasOpenTickets), isFalse);
      await finish(tester);
    });

    testWidgets('the preview is the request, with the key named and never shown', (tester) async {
      await pumpDock(tester, HelpPage.contactSupport);
      await tester.enterText(find.byType(TextField).at(0), 'Subject line');
      await tester.enterText(find.byType(TextField).at(1), 'Message text');
      await tester.ensureVisible(find.text(l10n.feedbackWhatIsSent));
      await tester.tap(find.text(l10n.feedbackWhatIsSent));
      await settle(tester);
      expect(find.text(l10n.supportContextNote), findsOneWidget);
      final preview = tester.widget<SelectableText>(find.byType(SelectableText).first).data!;
      final shown = jsonDecode(preview) as Map<String, dynamic>;
      expect(shown.keys.toSet(),
          {'title', 'body', 'context', 'contact', 'include_account', 'nonce', 'ticket_token'});
      expect(shown['title'], 'Subject line');
      expect(shown['body'], 'Message text');
      expect(shown['include_account'], isFalse);
      expect(shown['contact'], isNull);
      expect(shown['ticket_token'], TicketToken.preview);
      expect((shown['context'] as Map).keys.toSet(),
          {'app_version', 'build', 'platform', 'os_version', 'locale', 'tier'});
      expect((shown['context'] as Map)['app_version'], '3.0.0');
      expect((shown['context'] as Map)['build'], 300);
      await finish(tester);
    });

    testWidgets('with no network the ticket is kept, shown as waiting, and sent on "Try now"', (tester) async {
      server.offline = true;
      final container = await pumpDock(tester, HelpPage.contactSupport);
      await tester.enterText(find.byType(TextField).at(0), 'Written on a train');
      await tester.enterText(find.byType(TextField).at(1), 'No signal here.');
      await tester.tap(find.text(l10n.feedbackSend));
      await settle(tester);
      expect(container.read(notificationCenterProvider).history.map((n) => n.title), [l10n.supportQueued]);
      expect(container.read(helpDockProvider), HelpPage.ticket);
      expect(find.text(l10n.ticketWaitingNotice), findsOneWidget);
      expect(find.text(l10n.ticketStatusWaiting), findsOneWidget);
      expect(find.text(l10n.ticketReplyHint), findsNothing, reason: 'nothing to reply to yet');
      expect(server.tickets, isEmpty);

      // The list says the same.
      await tester.tap(find.bySemanticsLabel(l10n.back));
      await settle(tester);
      expect(find.text('Written on a train'), findsOneWidget);
      expect(find.text(l10n.ticketStatusWaiting), findsOneWidget);

      server.offline = false;
      await tester.tap(find.text('Written on a train'));
      await settle(tester);
      await tester.tap(find.text(l10n.ticketTryNow));
      await settle(tester);
      expect(server.tickets.values.single.title, 'Written on a train');
      expect(find.text(l10n.ticketWaitingNotice), findsNothing);
      expect(find.text(l10n.ticketAwaitingSupport), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a refusal leaves the form as it was and says why', (tester) async {
      server.failWith = 429;
      final container = await pumpDock(tester, HelpPage.contactSupport);
      await tester.enterText(find.byType(TextField).at(0), 'Fifth ticket this hour');
      await tester.enterText(find.byType(TextField).at(1), 'Still broken.');
      await tester.tap(find.text(l10n.feedbackSend));
      await settle(tester);
      expect(find.text(l10n.supportRateLimited(2)), findsOneWidget);
      expect(container.read(helpDockProvider), HelpPage.contactSupport);
      expect(find.text('Fifth ticket this hour'), findsOneWidget);
      expect(find.text('Still broken.'), findsOneWidget);
      expect(await run<SupportTicketRow?>(tester, () => db.select(db.supportTickets).getSingleOrNull()), isNull);

      // What was typed survives closing the panel and coming back.
      container.read(helpDockProvider.notifier).state = HelpPage.home;
      await settle(tester);
      container.read(helpDockProvider.notifier).state = HelpPage.contactSupport;
      await settle(tester);
      expect(find.text('Fifth ticket this hour'), findsOneWidget);
      // Clean up the draft for the tests that follow.
      await tester.enterText(find.byType(TextField).at(0), '');
      await tester.enterText(find.byType(TextField).at(1), '');
      await finish(tester);
    });
  });

  // The Help panel's forms stand on screen while it is recorded as the hub's does,
  // and drew what is typed raw (found in a review).
  group('while the screen is recorded', () {
    const typed = 'Cannot reach prod-db.example.com';
    const lines = 'prod-db.example.com\ntimes out';
    const email = 'sam@example.com';
    final dotsOfLines = '${'•' * 'prod-db.example.com'.length}\n${'•' * 'times out'.length}';

    String drawn(WidgetTester tester, Finder field) => tester
        .state<EditableTextState>(find.descendant(of: field, matching: find.byType(EditableText)))
        .renderEditable
        .text!
        .toPlainText();

    String held(WidgetTester tester, Finder field) => tester.widget<TextField>(field).controller!.text;

    testWidgets('the support form: bullets, one for each character, what it holds stays, and what is sent is masked',
        (tester) async {
      Redactor.instance.enabled = true;
      await pumpDock(tester, HelpPage.contactSupport, recording: true);
      final (subject, message) = (find.byType(TextField).at(0), find.byType(TextField).at(1));
      final address = find.byType(TextField).at(2);
      await tester.enterText(subject, typed);
      await tester.enterText(message, lines);
      await tester.enterText(address, email);
      await settle(tester);
      expect(drawn(tester, subject), '•' * typed.length);
      expect(drawn(tester, message), dotsOfLines);
      expect(drawn(tester, address), '•' * email.length);
      expect(held(tester, subject), typed);
      expect(held(tester, message), lines);
      expect(held(tester, address), email);

      await tester.ensureVisible(find.text(l10n.feedbackWhatIsSent));
      await tester.tap(find.text(l10n.feedbackWhatIsSent));
      await settle(tester);
      final preview = tester.widget<SelectableText>(find.byType(SelectableText).first).data!;
      expect(preview, contains('Cannot reach'), reason: 'it is the form');
      expect(preview, isNot(contains('prod-db')));
      await finish(tester);
    });

    testWidgets('the form with recording off draws what it holds', (tester) async {
      await pumpDock(tester, HelpPage.contactSupport);
      final subject = find.byType(TextField).at(0);
      await tester.enterText(subject, typed);
      await settle(tester);
      expect(drawn(tester, subject), typed);
      await finish(tester);
    });

    testWidgets('a report: the same', (tester) async {
      Redactor.instance.enabled = true;
      await pumpDock(tester, HelpPage.reportBug, recording: true);
      final (title, body) = (find.byType(TextField).at(0), find.byType(TextField).at(1));
      await tester.enterText(title, typed);
      await tester.enterText(body, lines);
      await settle(tester);
      expect(drawn(tester, title), '•' * typed.length);
      expect(drawn(tester, body), dotsOfLines);
      expect(held(tester, title), typed);
      expect(held(tester, body), lines);

      await tester.ensureVisible(find.text(l10n.feedbackWhatIsSent));
      await tester.tap(find.text(l10n.feedbackWhatIsSent));
      await settle(tester);
      final preview = tester.widget<SelectableText>(find.byType(SelectableText).first).data!;
      expect(preview, contains('Cannot reach'), reason: 'it is the form');
      expect(preview, isNot(contains('prod-db')));
      await finish(tester);
    });

    testWidgets('a reply: bullets, and it goes as it was typed', (tester) async {
      Redactor.instance.enabled = true;
      final t = await seedSupport(tester);
      await pumpDock(tester, HelpPage.tickets, recording: true);
      await tester.tap(find.text(t.title));
      await settle(tester);
      final reply = field(l10n.ticketReplyHint);
      await tester.enterText(reply, lines);
      await tester.pump();
      expect(drawn(tester, reply), dotsOfLines);
      await tester.tap(find.byTooltip(l10n.feedbackSend));
      await settle(tester);
      expect(server.tickets[t.serverId]!.messages.last.body, lines);
      await finish(tester);
    });
  });

  group('My tickets', () {
    testWidgets('empty: says what will show up here', (tester) async {
      await pumpDock(tester, HelpPage.tickets);
      expect(find.text(l10n.ticketsEmptyTitle), findsOneWidget);
      expect(find.text(l10n.ticketsEmptyBody), findsOneWidget);
      expect(server.requests, isEmpty, reason: 'no ticket here, nothing asked of the server');
      await tester.tap(find.text(l10n.supportWrite));
      await settle(tester);
      expect(find.text(l10n.supportSubjectLabel), findsOneWidget);
      // Back from the form returns to the list it was opened from.
      await tester.tap(find.bySemanticsLabel(l10n.back));
      await settle(tester);
      expect(find.text(l10n.ticketsEmptyTitle), findsOneWidget);
      await finish(tester);
    });

    testWidgets('lists each ticket with where it stands; opening the page asks the server', (tester) async {
      final support = await seedSupport(tester);
      late FakeTicket report;
      await tester.runAsync(() async {
        final r = FeedbackReport(type: FeedbackType.bug, title: 'Tabs overlap', body: 'x', context: ctx);
        report = server.addReport(token: r.ticketToken, title: 'Tabs overlap');
        await service.keepReport(r, id: report.id, number: report.number);
      });
      server.staffReply(support.serverId!, 'Which store?');
      server.staffTags(report.id, ['Confirmed']);
      server.staffClose(report.id);

      await pumpDock(tester, HelpPage.tickets);
      // The page asked: the answer and the tags are there without a tap.
      expect(find.text('Cannot restore my purchase'), findsOneWidget);
      expect(find.text(l10n.ticketReplyFromSupport), findsOneWidget);
      expect(find.text('Tabs overlap'), findsOneWidget);
      expect(find.text(l10n.ticketStatusClosed), findsOneWidget);
      expect(find.text('Confirmed'), findsOneWidget);
      expect(find.textContaining('#${support.number}'), findsOneWidget);
      expect(find.textContaining(l10n.reportTypeBug), findsOneWidget);
      // The one with the answer is on top.
      expect(tester.getTopLeft(find.text('Cannot restore my purchase')).dy,
          lessThan(tester.getTopLeft(find.text('Tabs overlap')).dy));
      await finish(tester);
    });

    testWidgets('with no network the list says so and shows what was read last', (tester) async {
      final t = await seedSupport(tester);
      server.staffReply(t.serverId!, 'Which store?');
      await tester.runAsync(service.refresh);
      server.offline = true;
      await pumpDock(tester, HelpPage.tickets);
      // Nothing answered: which failure it is, in a few words, with its code.
      final notResponding = l10n.ticketsStaleWhy(l10n.cloudChipNotResponding, 'ZS-1101');
      expect(find.text(notResponding), findsOneWidget);
      expect(find.text(l10n.ticketsOffline), findsNothing, reason: 'the server was not merely "not reached"');
      expect(find.text('Cannot restore my purchase'), findsOneWidget);
      expect(find.text(l10n.ticketReplyFromSupport), findsOneWidget, reason: 'the last known state');

      // Back online: Refresh clears the notice.
      server.offline = false;
      await tester.tap(find.byTooltip(l10n.refresh));
      await settle(tester);
      expect(find.text(notResponding), findsNothing);
      expect(find.text(l10n.ticketsOffline), findsNothing);

      // A fault of the service's own is said as that; an answer that is no
      // fault of its own, as it always was.
      server.failWith = 503;
      await tester.tap(find.byTooltip(l10n.refresh));
      await settle(tester);
      expect(find.text(l10n.ticketsStaleWhy(l10n.cloudChipFault, 'ZS-1103')), findsOneWidget);
      server.failWith = 429;
      await tester.tap(find.byTooltip(l10n.refresh));
      await settle(tester);
      expect(find.text(l10n.ticketsOffline), findsOneWidget);
      expect(find.text(l10n.ticketsStaleWhy(l10n.cloudChipFault, 'ZS-1103')), findsNothing);
      await finish(tester);
    });

    testWidgets('a report still waiting to be sent is listed as waiting', (tester) async {
      await tester.runAsync(() async {
        final feedback = FeedbackService(db, prefs,
            client: MockClient((_) async => throw const FormatException('offline')), baseUrl: 'https://api.test/v1');
        final res = await feedback.send(
            FeedbackReport(type: FeedbackType.suggestion, title: 'Remember tab widths', body: 'x', context: ctx));
        expect(res.outcome, FeedbackOutcome.queued);
      });
      server.offline = true;
      await pumpDock(tester, HelpPage.tickets);
      expect(find.text('Remember tab widths'), findsOneWidget);
      expect(find.text(l10n.ticketStatusWaiting), findsOneWidget);
      expect(find.text(l10n.ticketsEmptyTitle), findsNothing);
      await finish(tester);
    });

    testWidgets('recording mode hides what a subject and a message name, in the list and on the page', (tester) async {
      final t = await seedSupport(tester,
          title: 'Cannot reach db.internal.example.com',
          body: 'ssh deploy@10.50.0.24 times out, and so does log-store.');
      server.staffReply(t.serverId!, 'Is 10.50.0.24 reachable from log-store?');
      Redactor.instance
        ..clearNames()
        ..registerNames(['log-store'])
        ..registerAddresses(['10.50.0.24'])
        ..enabled = true;
      addTearDown(Redactor.instance.clearNames);
      await pumpDock(tester, HelpPage.tickets, recording: true);
      expect(find.text('Cannot reach db.internal.example.com'), findsNothing);
      expect(find.textContaining('Cannot reach'), findsOneWidget);

      await tester.tap(find.textContaining('Cannot reach'));
      await settle(tester);
      // Everything the page draws, selectable text included.
      final drawn = [
        for (final w in tester.widgetList<Text>(find.byType(Text))) w.data ?? w.textSpan?.toPlainText() ?? '',
        for (final w in tester.widgetList<SelectableText>(find.byType(SelectableText))) w.data ?? '',
      ].join(' | ');
      expect(drawn, contains('times out'), reason: 'the conversation is on the page');
      for (final secret in ['db.internal.example.com', '10.50.0.24', 'log-store', 'deploy@']) {
        expect(drawn, isNot(contains(secret)), reason: secret);
      }
      await finish(tester);
    });
  });

  group('a ticket', () {
    Future<ProviderContainer> openTicket(WidgetTester tester, SupportTicketRow t) async {
      final container = await pumpDock(tester, HelpPage.tickets);
      await tester.tap(find.text(t.title));
      await settle(tester);
      return container;
    }

    testWidgets('shows the conversation, marks the answer read, and sends a reply', (tester) async {
      final t = await seedSupport(tester);
      server.staffReply(t.serverId!, 'Which store did you buy it from?', name: 'Robin');
      final container = await openTicket(tester, t);

      expect(find.text('I paid on my phone and the PC still says Free.'), findsOneWidget);
      expect(find.text('Which store did you buy it from?'), findsOneWidget);
      expect(find.textContaining('Robin · ${l10n.ticketSupportName}'), findsOneWidget);
      expect(find.text(l10n.ticketPrivateLine), findsOneWidget);
      expect(find.text(l10n.ticketReplyPublicNote), findsNothing, reason: 'a support ticket is private');
      expect(find.text(l10n.ticketViewOnDiscord), findsNothing);
      expect((await rowOf(tester, t.nonce)).hasUnreadReply, isFalse, reason: 'it is on screen');
      expect(container.read(ticketUnreadCountProvider), 0);

      await tester.enterText(field(l10n.ticketReplyHint), 'Google Play.');
      await tester.pump();
      await tester.tap(find.byTooltip(l10n.feedbackSend));
      await settle(tester);
      expect(server.tickets[t.serverId]!.messages.last.body, 'Google Play.');
      expect(find.text('Google Play.'), findsOneWidget);
      expect(tester.widget<TextField>(field(l10n.ticketReplyHint)).controller!.text, isEmpty);
      expect(find.text(l10n.ticketAwaitingSupport), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a page that cannot be read anew says which failure it was, over what was read last',
        (tester) async {
      final t = await seedSupport(tester);
      server.staffReply(t.serverId!, 'Which store did you buy it from?', name: 'Robin');
      await tester.runAsync(() => service.open(t.nonce, seen: false));
      server.offline = true;
      await openTicket(tester, t);
      expect(find.text(l10n.ticketsStaleWhy(l10n.cloudChipNotResponding, 'ZS-1101')), findsOneWidget);
      expect(find.text(l10n.ticketsOffline), findsNothing);
      expect(find.text('Which store did you buy it from?'), findsOneWidget, reason: 'what was read last');
      await finish(tester);
    });

    testWidgets('an answer that arrives while the page is open shows up by itself', (tester) async {
      final t = await seedSupport(tester);
      await openTicket(tester, t);
      expect(find.text('All sorted now.'), findsNothing);
      server.staffReply(t.serverId!, 'All sorted now.');
      // The timed check of an open page.
      await tester.pump(const Duration(seconds: 46));
      await settle(tester);
      expect(find.text('All sorted now.'), findsOneWidget);
      expect((await rowOf(tester, t.nonce)).hasUnreadReply, isFalse);
      await finish(tester);
    });

    testWidgets('behind another window the page reads nothing: the answer stays unread and is announced', (tester) async {
      final t = await seedSupport(tester);
      await openTicket(tester, t);
      addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await settle(tester);
      expect(service.viewing, isNull, reason: 'nobody is looking at it');

      server.staffReply(t.serverId!, 'Are you still there?');
      final calls = server.requests.length;
      await tester.pump(const Duration(seconds: 100));
      await settle(tester);
      expect(server.requests.length, calls, reason: 'the page asks nothing while it is not in front');
      // The background check finds the answer and hands it over to be announced.
      final found = await run(tester, service.refresh);
      expect(found.replies.single.nonce, t.nonce);
      expect((await rowOf(tester, t.nonce)).hasUnreadReply, isTrue);
      expect(find.text('Are you still there?'), findsNothing);

      // Back in front: read at once, and marked as read.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      expect(find.text('Are you still there?'), findsOneWidget);
      expect((await rowOf(tester, t.nonce)).hasUnreadReply, isFalse);
      expect(service.viewing, t.nonce);
      await finish(tester);
    });

    testWidgets('leaving the page tells the service nobody is looking any more', (tester) async {
      final t = await seedSupport(tester);
      await openTicket(tester, t);
      expect(service.viewing, t.nonce);
      await tester.tap(find.bySemanticsLabel(l10n.back));
      await settle(tester);
      expect(service.viewing, isNull);
      await finish(tester);
    });

    testWidgets('a reply written with no network waits in the conversation, then goes', (tester) async {
      final t = await seedSupport(tester);
      await openTicket(tester, t);
      server.offline = true;
      await tester.enterText(field(l10n.ticketReplyHint), 'Written offline');
      await tester.pump();
      await tester.tap(find.byTooltip(l10n.feedbackSend));
      await settle(tester);
      expect(find.text('Written offline'), findsOneWidget);
      expect(find.text(l10n.ticketStatusWaiting), findsOneWidget);
      expect(find.text(l10n.ticketReplyQueued), findsOneWidget);
      expect(server.tickets[t.serverId]!.messages, isEmpty);

      server.offline = false;
      await run(tester, service.retryPending);
      await settle(tester);
      expect(server.tickets[t.serverId]!.messages.single.body, 'Written offline');
      expect(find.text('Written offline'), findsOneWidget, reason: 'once: as a sent message now');
      expect(find.text(l10n.ticketStatusWaiting), findsNothing);
      await finish(tester);
    });

    testWidgets('a public report says it is public, shows its tags and its forum post', (tester) async {
      late SupportTicketRow row;
      await tester.runAsync(() async {
        final r = FeedbackReport(
            type: FeedbackType.bug,
            title: 'Tabs overlap',
            body: 'The third tab is drawn under the pill bar.',
            expected: 'Tabs stay inside the strip.',
            context: ctx);
        final onServer = server.addReport(token: r.ticketToken, title: 'Tabs overlap', body: r.body);
        server.staffTags(onServer.id, ['Confirmed', 'Planned']);
        await service.keepReport(r, id: onServer.id, number: onServer.number);
        row = (await service.ticket(r.nonce))!;
      });
      await openTicket(tester, row);
      expect(find.text(l10n.ticketPublicLine), findsOneWidget);
      expect(find.text(l10n.ticketPrivateLine), findsNothing);
      expect(find.text(l10n.ticketViewOnDiscord), findsOneWidget);
      expect(find.text(l10n.ticketReplyPublicNote), findsOneWidget, reason: 'said before a reply is typed');
      expect(find.text('Confirmed'), findsOneWidget);
      expect(find.text('Planned'), findsOneWidget);
      expect(find.text('The third tab is drawn under the pill bar.'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('closed: no reply box, and a new ticket is one tap away', (tester) async {
      final t = await seedSupport(tester);
      server.staffClose(t.serverId!);
      final container = await openTicket(tester, t);
      expect(find.text(l10n.ticketClosedNotice), findsOneWidget);
      expect(field(l10n.ticketReplyHint), findsNothing);
      await tester.tap(find.text(l10n.ticketNewTicket));
      await settle(tester);
      expect(container.read(helpDockProvider), HelpPage.contactSupport);
      await finish(tester);
    });

    testWidgets('closing asks first, then closes it on the server', (tester) async {
      final t = await seedSupport(tester);
      await openTicket(tester, t);
      await tester.tap(find.byTooltip(l10n.ticketMenu));
      await settle(tester);
      await tester.tap(find.text(l10n.ticketClose));
      await settle(tester);
      expect(find.text(l10n.ticketCloseConfirmTitle), findsOneWidget);
      expect(find.text(l10n.ticketCloseConfirmBody), findsOneWidget);
      expect(server.tickets[t.serverId]!.status, 'open', reason: 'not before the answer');
      await tester.tap(find.text(l10n.cancel));
      await settle(tester);
      expect(server.tickets[t.serverId]!.status, 'open', reason: 'Cancel closes nothing');
      expect((await rowOf(tester, t.nonce)).isOpen, isTrue);
      expect(find.text(l10n.ticketClosedNotice), findsNothing);

      await tester.tap(find.byTooltip(l10n.ticketMenu));
      await settle(tester);
      await tester.tap(find.text(l10n.ticketClose));
      await settle(tester);
      await tester.tap(find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(l10n.ticketClose)));
      await settle(tester);
      expect(server.tickets[t.serverId]!.status, 'closed');
      expect(find.text(l10n.ticketClosedNotice), findsOneWidget);
      await finish(tester);
    });

    testWidgets('removing asks first, says what is lost, and returns to the list', (tester) async {
      final t = await seedSupport(tester);
      final container = await openTicket(tester, t);
      await tester.tap(find.byTooltip(l10n.ticketMenu));
      await settle(tester);
      await tester.tap(find.text(l10n.ticketRemove));
      await settle(tester);
      expect(find.text(l10n.ticketRemoveConfirmTitle), findsOneWidget);
      expect(find.text(l10n.ticketRemoveConfirmBody), findsOneWidget);
      await tester.tap(find.text(l10n.cancel));
      await settle(tester);
      expect((await rowOf(tester, t.nonce)).nonce, t.nonce, reason: 'Cancel removes nothing');

      await tester.tap(find.byTooltip(l10n.ticketMenu));
      await settle(tester);
      await tester.tap(find.text(l10n.ticketRemove));
      await settle(tester);
      await tester.tap(
          find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(l10n.ticketRemoveConfirm)));
      await settle(tester);
      expect(await run<SupportTicketRow?>(tester, () => service.ticket(t.nonce)), isNull);
      expect(container.read(helpDockProvider), HelpPage.tickets);
      expect(find.text(l10n.ticketsEmptyTitle), findsOneWidget);
      expect(server.tickets, hasLength(1), reason: 'the server keeps its copy');
      await finish(tester);
    });

    testWidgets('copying the conversation copies what was said, with who said it', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final t = await seedSupport(tester);
      server.staffReply(t.serverId!, 'Which store?', name: 'Robin');
      await openTicket(tester, t);
      await tester.tap(find.byTooltip(l10n.ticketMenu));
      await settle(tester);
      await tester.tap(find.text(l10n.ticketCopyConversation));
      await settle(tester);
      expect(copied, contains('Cannot restore my purchase'));
      expect(copied, contains('${l10n.ticketYou}:\nI paid on my phone'));
      expect(copied, contains('Robin:\nWhich store?'));
      expect(copied, isNot(contains(t.token)), reason: 'never the key');
      await finish(tester);
    });

    testWidgets('gone from the server: says so, keeps what was read', (tester) async {
      final t = await seedSupport(tester);
      await tester.runAsync(() => service.open(t.nonce));
      server.delete(t.serverId!);
      await openTicket(tester, t);
      expect(find.text(l10n.ticketGoneNotice), findsOneWidget);
      expect(find.text('I paid on my phone and the PC still says Free.'), findsOneWidget);
      expect(field(l10n.ticketReplyHint), findsNothing);
      await finish(tester);
    });
  });

  group('on a phone', () {
    Future<GoRouter> pumpPhone(WidgetTester tester, String start) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final router = GoRouter(initialLocation: start, routes: [
        GoRoute(path: Routes.help, builder: (_, _) => const HelpSupportScreen()),
        GoRoute(
          path: Routes.tickets,
          builder: (context, _) => TicketsScreen(
            onOpen: (nonce) => context.push(Routes.ticket, extra: nonce),
            onContactSupport: () => context.push(Routes.contactSupport),
          ),
        ),
        GoRoute(
          path: Routes.ticket,
          builder: (context, state) => TicketDetailScreen(
            nonce: state.extra is String ? state.extra as String : '',
            onLeave: () => context.pop(),
            onNewTicket: () => context.pushReplacement(Routes.contactSupport),
          ),
        ),
        GoRoute(
          path: Routes.contactSupport,
          builder: (context, _) =>
              ContactSupportScreen(onDone: (nonce) => context.pushReplacement(Routes.ticket, extra: nonce)),
        ),
      ]);
      await tester.pumpWidget(ProviderScope(
        overrides: overrides(),
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          routerConfig: router,
        ),
      ));
      await settle(tester);
      return router;
    }

    // Recording mode's level is a pick-one choice, so a dot as every other one,
    // not a check (found in a UI review); the row picks it.
    testWidgets("recording mode's level: a dot on each, the one in use filled, a tap on the row picks it",
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: overrides(recording: true),
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: HelpSupportScreen(),
        ),
      ));
      await settle(tester);
      final container = ProviderScope.containerOf(tester.element(find.byType(HelpSupportScreen)));
      final layout = find.byKey(const ValueKey('help-recording-layout'));
      final strict = find.byKey(const ValueKey('help-recording-strict'));
      await tester.scrollUntilVisible(strict, 200, scrollable: find.byType(Scrollable).first);
      Finder dotOf(Finder row) => find.descendant(of: row, matching: find.byWidgetPredicate((w) => w is Radio));
      expect(dotOf(layout), findsOneWidget);
      expect(dotOf(strict), findsOneWidget);
      expect(find.descendant(of: layout, matching: find.byIcon(LucideIcons.check)), findsNothing);
      expect(find.descendant(of: strict, matching: find.byIcon(LucideIcons.check)), findsNothing);
      final semantics = tester.ensureSemantics();
      expect(container.read(recordingRedactLevelProvider), RedactLevel.layout);
      expect(tester.getSemantics(dotOf(layout)), isSemantics(isChecked: true, isInMutuallyExclusiveGroup: true));
      expect(tester.getSemantics(dotOf(strict)), isSemantics(isChecked: false, isInMutuallyExclusiveGroup: true));

      await tester.tap(find.descendant(of: strict, matching: find.text(l10n.recModeLevelStrict)));
      await settle(tester);
      expect(container.read(recordingRedactLevelProvider), RedactLevel.strict);
      expect(tester.getSemantics(dotOf(strict)), isSemantics(isChecked: true, isInMutuallyExclusiveGroup: true));
      // A tap on the dot itself picks too.
      await tester.ensureVisible(layout);
      await settle(tester);
      // The dot takes no pointer of its own: the tap where it is drawn is the row's.
      await tester.tap(dotOf(layout), warnIfMissed: false);
      await settle(tester);
      expect(container.read(recordingRedactLevelProvider), RedactLevel.layout);
      semantics.dispose();
      await finish(tester);
    });

    testWidgets('Help counts an unread answer and leads to the ticket', (tester) async {
      final t = await seedSupport(tester);
      server.staffReply(t.serverId!, 'Which store?');
      await tester.runAsync(service.refresh);
      await pumpPhone(tester, Routes.help);
      expect(find.text(l10n.ticketsTitle), findsOneWidget);
      expect(find.text(l10n.ticketReplyFromSupport), findsOneWidget);
      expect(find.text('1'), findsOneWidget);

      await tester.tap(find.text(l10n.ticketsTitle));
      await settle(tester);
      expect(find.text('Cannot restore my purchase'), findsOneWidget);
      await tester.tap(find.text('Cannot restore my purchase'));
      await settle(tester);
      expect(find.text('Which store?'), findsOneWidget);
      expect(find.text('${l10n.ticketTypeSupport} #${t.number}'), findsOneWidget);
      expect(find.byTooltip(l10n.ticketMenu), findsOneWidget);
      await finish(tester);
    });

    testWidgets('Get help opens the support form; sending lands on the ticket', (tester) async {
      await pumpPhone(tester, Routes.help);
      await tester.tap(find.text(l10n.helpSupport));
      await settle(tester);
      expect(find.text(l10n.supportWrite), findsOneWidget);
      expect(find.text(l10n.helpOpenDiscord), findsOneWidget);
      await tester.tap(find.text(l10n.supportWrite));
      await settle(tester);
      expect(find.text(l10n.supportSubjectLabel), findsOneWidget);

      await tester.enterText(find.byType(TextField).at(0), 'From my phone');
      await tester.enterText(find.byType(TextField).at(1), 'Hello.');
      await tester.ensureVisible(find.text(l10n.feedbackSend));
      await tester.tap(find.text(l10n.feedbackSend));
      await settle(tester);
      expect(server.tickets.values.single.title, 'From my phone');
      expect(find.text(l10n.ticketPrivateLine), findsOneWidget);
      expect(find.text('Hello.'), findsOneWidget);
      // Back from the ticket does not return to a form that has been sent.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pageBack();
      await settle(tester);
      expect(find.text(l10n.supportSubjectLabel), findsNothing);
      await finish(tester);
    });
  });

  // The 4.0 accessibility pass: the Help panel's pages
  // (home, the forms, the tickets, the guides) hold to the checks every
  // screen of the pass does: names, 32 square targets, readable words.
  testWidgets('the Help panel, every page: names, targets, contrast (the 4.0 accessibility pass)', (tester) async {
    final handle = tester.ensureSemantics();
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final failures = <String>[];
      for (final page in [HelpPage.home, HelpPage.reportBug, HelpPage.suggest, HelpPage.contactSupport, HelpPage.tickets, HelpPage.guides]) {
        await pumpDock(tester, page);
        // (Its words' colours are the theme's, checked for every theme in
        // theme_contrast_test; this panel is drawn here without the app's theme.)
        failures.addAll(await a11yCheck(tester, computer: true, contrast: false, where: 'Help, ${page.name}'));
      }
      expect(failures, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      handle.dispose();
    }
    await finish(tester);
  });
}
