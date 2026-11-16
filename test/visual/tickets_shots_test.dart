import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/help_dock.dart';
import 'package:zestssh/ui/screens/help/contact_support_screen.dart';
import 'package:zestssh/ui/screens/help/ticket_detail_screen.dart';
import 'package:zestssh/ui/screens/help/tickets_screen.dart';
import 'package:zestssh/ui/screens/settings/help_support_screen.dart';

import '../features/tickets/fake_ticket_server.dart';
import 'shots_util.dart';

/// Pictures of tickets in the app (S1), with the real fonts:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/tickets_shots_test.dart
///
/// Pictures land in build/shots/. Everything on them is made up.

final l10n = lookupAppLocalizations(const Locale('en'));

const _ctx = FeedbackContext(
  appVersion: '3.0.0',
  build: 300,
  platform: 'windows',
  osVersion: 'Windows 11',
  locale: 'en-US',
  tier: 'squeezed',
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late FakeTicketServer server;
  late TicketService service;
  late SharedPreferences prefs;

  Future<void> start(WidgetTester tester, String themeId) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    SharedPreferences.setMockInitialValues({'app_theme_id': themeId});
    prefs = await SharedPreferences.getInstance();
    PackageInfo.setMockInitialValues(
        appName: 'ZestSSH', packageName: 'com.affluentlabs.zestssh', version: '3.0.0', buildNumber: '300', buildSignature: '');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    server = FakeTicketServer()..now = DateTime.now().toUtc().subtract(const Duration(hours: 5));
    // Written five hours ago, so the conversation reads in order.
    service = TicketService(db,
        client: MockClient(server.handle),
        baseUrl: 'https://api.test/v1',
        now: () => DateTime.now().subtract(const Duration(hours: 5)));
    AppColors.applyTheme(BuiltInThemes.getById(themeId).colorScheme);
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

  /// A support ticket with an answer, a bug report with tags, a closed
  /// suggestion: what a person who has used Help for a while would see.
  Future<Map<String, String>> seed(WidgetTester tester) async {
    final nonces = <String, String>{};
    await tester.runAsync(() async {
      final a = await service.createSupport(
          title: 'Purchase not showing on my laptop',
          body: 'I bought Squeezed on my phone last week. My laptop still says Free, even after signing in with the same account.',
          context: _ctx);
      nonces['support'] = a.nonce!;
      final row = (await service.ticket(a.nonce!))!;
      server.now = DateTime.now().toUtc().subtract(const Duration(hours: 2));
      server.staffReply(row.serverId!,
          'Thanks for writing in. Which store did you buy it from, Google Play or the App Store? And is the laptop on Windows or a Mac?',
          name: 'Robin');

      final bug = FeedbackReport(
          type: FeedbackType.bug,
          title: 'Split view loses focus after resize',
          body: 'After dragging the divider, typing goes to the left pane even though I clicked the right one.',
          expected: 'Focus stays in the pane I clicked.',
          context: _ctx,
          createdAt: DateTime.now().subtract(const Duration(days: 2)));
      final onServer = server.addReport(token: bug.ticketToken, title: bug.title, body: bug.body);
      server.staffTags(onServer.id, ['Confirmed', 'Desktop App']);
      await service.keepReport(bug, id: onServer.id, number: onServer.number);
      nonces['bug'] = bug.nonce;
      server.now = DateTime.now().toUtc().subtract(const Duration(hours: 20));
      server.staffReply(onServer.id, 'Reproduced, thank you. It is the focus handoff after the drag ends. Fix is in the next build.',
          name: 'Morgan');

      final idea = FeedbackReport(
          type: FeedbackType.suggestion,
          title: 'Remember the width of each tab',
          body: 'Tabs reset to equal widths when I reopen the app.',
          context: _ctx,
          createdAt: DateTime.now().subtract(const Duration(days: 9)));
      final ideaOnServer = server.addReport(token: idea.ticketToken, type: 'suggestion', title: idea.title, body: idea.body);
      server.staffTags(ideaOnServer.id, ['Implemented']);
      server.staffClose(ideaOnServer.id);
      await service.keepReport(idea, id: ideaOnServer.id, number: ideaOnServer.number);
      nonces['idea'] = idea.nonce;
      await service.refresh();
    });
    return nonces;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<(GlobalKey, ProviderContainer)> pumpDock(WidgetTester tester, HelpPage page, String themeId) async {
    tester.view.physicalSize = const Size(900, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = BuiltInThemes.getById(themeId);
    final key = GlobalKey();
    final container = ProviderContainer(overrides: overrides(page));
    addTearDown(container.dispose);
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme.toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            backgroundColor: AppColors.v3Background,
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
      ),
    ));
    await settle(tester);
    return (key, container);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
    plainShadows();
  }

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';

    testWidgets('the Help panel levels ($tag)', (tester) async {
      // Drawn as on a computer: the theme sizes its controls by platform,
      // and tests run as Android unless told.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await start(tester, themeId);
      final nonces = await seed(tester);
      final (key, container) = await pumpDock(tester, HelpPage.home, themeId);
      await saveShot(tester, key, 'tickets_${tag}_1_help_home');

      container.read(helpDockProvider.notifier).state = HelpPage.support;
      await settle(tester);
      await saveShot(tester, key, 'tickets_${tag}_2_get_help');

      container.read(helpDockProvider.notifier).state = HelpPage.tickets;
      await settle(tester);
      await saveShot(tester, key, 'tickets_${tag}_3_my_tickets');

      container.read(helpDockTicketProvider.notifier).state = nonces['support'];
      container.read(helpDockProvider.notifier).state = HelpPage.ticket;
      await settle(tester);
      await saveShot(tester, key, 'tickets_${tag}_4_support_ticket');

      container.read(helpDockTicketProvider.notifier).state = nonces['bug'];
      await settle(tester);
      await saveShot(tester, key, 'tickets_${tag}_5_bug_report');

      container.read(helpDockTicketProvider.notifier).state = nonces['idea'];
      await settle(tester);
      await saveShot(tester, key, 'tickets_${tag}_6_closed_suggestion');

      container.read(helpDockProvider.notifier).state = HelpPage.contactSupport;
      await settle(tester);
      await tester.enterText(find.byType(TextField).at(0), 'Cannot restore my purchase');
      await tester.enterText(find.byType(TextField).at(1),
          'I reinstalled the app on a new phone and the upgrade is gone. Restore purchases says there is nothing to restore.');
      await tester.pump();
      await saveShot(tester, key, 'tickets_${tag}_7_support_form');

      await tester.ensureVisible(find.text(l10n.feedbackWhatIsSent));
      await tester.tap(find.text(l10n.feedbackWhatIsSent));
      await settle(tester);
      await tester.ensureVisible(find.byType(SelectableText).first);
      await tester.pump();
      await saveShot(tester, key, 'tickets_${tag}_8_support_form_preview');
      await tester.enterText(find.byType(TextField).at(0), '');
      await tester.enterText(find.byType(TextField).at(1), '');
      await finish(tester);
      debugDefaultTargetPlatformOverride = null;
    }, skip: !shotsEnabled);
  }

  testWidgets('empty, offline and waiting (dark)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await start(tester, 'graphite');
    final (key, container) = await pumpDock(tester, HelpPage.tickets, 'graphite');
    await saveShot(tester, key, 'tickets_dark_9_empty');

    server.offline = true;
    container.read(helpDockProvider.notifier).state = HelpPage.contactSupport;
    await settle(tester);
    await tester.enterText(find.byType(TextField).at(0), 'Written on a train');
    await tester.enterText(find.byType(TextField).at(1), 'No signal here, sending this later.');
    await tester.tap(find.text(l10n.feedbackSend));
    await settle(tester);
    await saveShot(tester, key, 'tickets_dark_10_waiting_ticket');
    await finish(tester);
    debugDefaultTargetPlatformOverride = null;
  }, skip: !shotsEnabled);

  testWidgets('on a phone (dark)', (tester) async {
    await start(tester, 'graphite');
    final nonces = await seed(tester);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    // Help is pushed from the app (its app bar or More), as here: drawn as
    // the first page, it had no way back to show.
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const Scaffold()),
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
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: ProviderScope(
        overrides: overrides(null),
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: BuiltInThemes.getById('graphite').toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          routerConfig: router,
        ),
      ),
    ));
    await settle(tester);
    router.push(Routes.help);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 500));
    await saveShot(tester, key, 'tickets_phone_1_help', pixelRatio: 2);

    await tester.tap(find.text(l10n.helpSupport));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 500));
    await saveShot(tester, key, 'tickets_phone_2_get_help_sheet', pixelRatio: 2);
    await tester.tapAt(const Offset(195, 60));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 500));

    router.push(Routes.tickets);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 500));
    await saveShot(tester, key, 'tickets_phone_3_my_tickets', pixelRatio: 2);

    router.push(Routes.ticket, extra: nonces['support']);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 500));
    await saveShot(tester, key, 'tickets_phone_4_ticket', pixelRatio: 2);

    router.push(Routes.contactSupport);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 500));
    await saveShot(tester, key, 'tickets_phone_5_form', pixelRatio: 2);
    await finish(tester);
  }, skip: !shotsEnabled);
}
