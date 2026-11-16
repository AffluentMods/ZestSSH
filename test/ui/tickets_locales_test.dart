import 'package:drift/drift.dart' show driftRuntimeOptions, Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/features/feedback/feedback_service.dart';
import 'package:zestssh/features/tickets/ticket_service.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/providers/help_status_provider.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/help_dock.dart';
import 'package:zestssh/ui/screens/help/contact_support_screen.dart';
import 'package:zestssh/ui/screens/help/ticket_detail_screen.dart';
import 'package:zestssh/ui/screens/help/tickets_screen.dart';
import 'package:zestssh/ui/screens/settings/help_support_screen.dart';

import '../features/tickets/fake_ticket_server.dart';
import '../visual/shots_util.dart';

/// Every ticket screen, in every language the app ships, with the shipped
/// font (the test font draws each glyph as a square, far wider than real
/// text): nothing overflows in the 400-pixel Help panel or on a small
/// phone. A layout that does not fit throws, which fails the test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

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
  final nonces = <String, String>{};

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// One ticket in each state a screen has to draw.
  Future<void> seed(WidgetTester tester) async {
    await tester.runAsync(loadShotFonts);
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    PackageInfo.setMockInitialValues(
        appName: 'ZestSSH', packageName: 'com.affluentlabs.zestssh', version: '3.0.0', buildNumber: '300', buildSignature: '');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    server = FakeTicketServer();
    service = TicketService(db, client: MockClient(server.handle), baseUrl: 'https://api.test/v1');
    nonces.clear();
    await tester.runAsync(() async {
      // Answered, with a follow-up still waiting and one that was refused.
      final answered = await service.createSupport(
          title: 'Purchase not showing on my laptop after signing in again',
          body: 'I bought the upgrade on my phone last week and my laptop still says Free.',
          context: ctx);
      nonces['answered'] = answered.nonce!;
      final row = (await service.ticket(answered.nonce!))!;
      server.staffReply(row.serverId!, 'Which store did you buy it from, and is the laptop on Windows or a Mac?',
          name: 'Robin');
      server.offline = true;
      await service.reply(answered.nonce!, 'Google Play, and the laptop is on Windows 11.');
      await service.reply(answered.nonce!, 'I can send the receipt if that helps.');
      server.offline = false;
      final waiting = await db.select(db.ticketOutbox).get();
      await (db.update(db.ticketOutbox)..where((t) => t.nonce.equals(waiting.last.nonce)))
          .write(const TicketOutboxCompanion(error: Value('closed')));

      // A public report with tags and a forum post.
      final bug = FeedbackReport(
          type: FeedbackType.bug,
          title: 'Split view loses focus after resize',
          body: 'Typing goes to the left pane even though I clicked the right one.',
          expected: 'Focus stays in the pane I clicked.',
          context: ctx);
      final onServer = server.addReport(token: bug.ticketToken, title: bug.title, body: bug.body);
      server.staffTags(onServer.id, ['Confirmed', 'Desktop App', 'Planned']);
      await service.keepReport(bug, id: onServer.id, number: onServer.number);
      nonces['public'] = bug.nonce;

      // Closed.
      final closed = await service.createSupport(title: 'Closed one', body: 'Solved.', context: ctx);
      server.staffClose((await service.ticket(closed.nonce!))!.serverId!);
      nonces['closed'] = closed.nonce!;

      // Gone from the server.
      final gone = await service.createSupport(title: 'Old one', body: 'Long ago.', context: ctx);
      server.delete((await service.ticket(gone.nonce!))!.serverId!);
      nonces['gone'] = gone.nonce!;

      await service.refresh();

      // Written offline: waiting, and one refused for the account.
      server.offline = true;
      final waitingTicket = await service.createSupport(title: 'Written offline', body: 'Later.', context: ctx);
      nonces['waiting'] = waitingTicket.nonce!;
      final refused = await service.createSupport(title: 'Billing question', body: 'Charged twice.', context: ctx);
      nonces['refused'] = refused.nonce!;
      await (db.update(db.supportTickets)..where((t) => t.nonce.equals(refused.nonce!)))
          .write(const SupportTicketsCompanion(sendError: Value('account')));
    });
  }

  List<Override> overrides(HelpPage? page) => [
        sharedPreferencesProvider.overrideWithValue(prefs),
        treeDatabaseProvider.overrideWithValue(db),
        dbReadyProvider.overrideWithValue(true),
        ticketServiceProvider.overrideWithValue(service),
        feedbackServiceProvider.overrideWithValue(
            FeedbackService(db, prefs, client: MockClient(server.handle), baseUrl: 'https://api.test/v1')),
        if (page != null) helpDockProvider.overrideWith((_) => page),
        cloudStatusProvider.overrideWith((_) async => CloudStatus.ok),
        appVersionLabelProvider.overrideWith((_) async => '3.0.0'),
        recordingModeProvider.overrideWith((ref) => false),
      ];

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('the Help panel levels fit in ${locale.languageCode}', (tester) async {
      await seed(tester);
      final l10n = lookupAppLocalizations(locale);
      tester.view.physicalSize = const Size(900, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(overrides: overrides(HelpPage.home));
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(fontFamily: 'GeistSans'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: locale,
          home: Scaffold(
            body: Row(
              children: [
                const Expanded(child: SizedBox()),
                Consumer(builder: (context, ref, _) {
                  if (ref.watch(helpDockProvider) == null) return const SizedBox();
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

      Future<void> show(HelpPage page, {String? ticket}) async {
        if (ticket != null) container.read(helpDockTicketProvider.notifier).state = nonces[ticket];
        container.read(helpDockProvider.notifier).state = page;
        await settle(tester);
      }

      expect(find.text(l10n.ticketsTitle), findsOneWidget);
      await show(HelpPage.support);
      expect(find.text(l10n.supportWrite), findsOneWidget);
      await show(HelpPage.tickets);
      expect(find.text(l10n.ticketStatusWaiting), findsWidgets);
      for (final state in ['answered', 'public', 'closed', 'gone', 'waiting', 'refused']) {
        await show(HelpPage.ticket, ticket: state);
        expect(find.byType(TicketDetailScreen), findsOneWidget, reason: state);
        // The menu, with its three entries.
        await tester.tap(find.byTooltip(l10n.ticketMenu));
        await settle(tester);
        expect(find.text(l10n.ticketCopyConversation), findsOneWidget);
        await tester.tapAt(const Offset(40, 40));
        await settle(tester);
      }
      expect(find.text(ErrorCodes.withCode(l10n.ticketRefusedAccount, ErrorCodes.ticketNeedsAccount)), findsOneWidget);
      expect(find.text(l10n.ticketSendWithoutAccount), findsOneWidget);

      // The form, with every optional part open and a refusal showing.
      await show(HelpPage.contactSupport);
      server
        ..offline = false
        ..failWith = 429;
      await tester.enterText(find.byType(TextField).at(0), 'Subject');
      await tester.enterText(find.byType(TextField).at(1), 'Message');
      await tester.enterText(find.byType(TextField).at(2), 'not an address');
      await tester.tap(find.text(l10n.feedbackSend));
      await settle(tester);
      expect(find.text(l10n.supportEmailInvalid), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(2), '');
      await tester.tap(find.text(l10n.feedbackSend));
      await settle(tester);
      expect(find.text(l10n.supportRateLimited(2)), findsOneWidget);
      await tester.ensureVisible(find.text(l10n.feedbackWhatIsSent));
      await tester.tap(find.text(l10n.feedbackWhatIsSent));
      await settle(tester);
      expect(find.text(l10n.supportContextNote), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(0), '');
      await tester.enterText(find.byType(TextField).at(1), '');
      await finish(tester);
    });

    testWidgets('the phone screens fit in ${locale.languageCode}', (tester) async {
      await seed(tester);
      final l10n = lookupAppLocalizations(locale);
      // A small phone.
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final router = GoRouter(initialLocation: Routes.help, routes: [
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
        overrides: overrides(null),
        child: MaterialApp.router(
          theme: ThemeData(fontFamily: 'GeistSans'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: locale,
          routerConfig: router,
        ),
      ));
      await settle(tester);
      expect(find.text(l10n.ticketsTitle), findsOneWidget);

      // The Get help sheet: everything on it reachable, nothing cut off.
      await tester.tap(find.text(l10n.helpSupport));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(l10n.supportWrite), findsOneWidget);
      await tester.ensureVisible(find.text(l10n.helpOpenDiscord));
      await tester.pump();
      expect(find.text(l10n.helpOpenDiscord), findsOneWidget);
      await tester.tapAt(const Offset(180, 20));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 400));

      router.push(Routes.tickets);
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(TicketsScreen), findsOneWidget);
      for (final state in ['answered', 'public', 'closed', 'gone', 'waiting', 'refused']) {
        router.push(Routes.ticket, extra: nonces[state]);
        await settle(tester);
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(TicketDetailScreen), findsOneWidget, reason: state);
        router.pop();
        await settle(tester);
        await tester.pump(const Duration(milliseconds: 400));
      }
      router.push(Routes.contactSupport);
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(l10n.supportPrivateNotice), findsOneWidget);
      await finish(tester);
    });
  }
}
