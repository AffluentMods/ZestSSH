import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/features/feedback/feedback_service.dart';
import 'package:zestssh/features/tickets/public_reports.dart';
import 'package:zestssh/features/tickets/ticket_models.dart';
import 'package:zestssh/features/tickets/ticket_service.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/providers/help_status_provider.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/help_dock.dart';
import 'package:zestssh/ui/screens/help/support_hub_compose.dart';
import 'package:zestssh/ui/screens/help/support_hub_page.dart';
import 'package:zestssh/utils/redactor.dart';

import '../features/tickets/fake_ticket_server.dart';
import 'shots_util.dart';

/// Pictures of the Support Hub of 3.4 (as designed:
/// the Ideas board, Report a bug, a ticket's thread, the Help panel
/// beside a session), on a computer and on a phone, with the real fonts; and
/// the same pages swept over the window sizes and languages they have to fit:
///
///   flutter test --dart-define=ZEST_SHOTS=true [--dart-define=ZEST_SHOTS_DIR=<folder>] test/visual/support_hub_shots_test.dart
///
/// Pictures land in build/shots/, and in ZEST_SHOTS_DIR as well when it is
/// given. Everything on them is made up.

const _shotsDir = String.fromEnvironment('ZEST_SHOTS_DIR');

const _ctx = FeedbackContext(
  appVersion: '3.3.0',
  build: 340,
  platform: 'windows',
  osVersion: 'Windows 11 24H2',
  locale: 'en-US',
  tier: 'squeezed',
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late FakeTicketServer server;
  late TicketService service;
  late SharedPreferences prefs;
  late Uint8List png;

  Future<void> shot(WidgetTester tester, GlobalKey key, String name) async {
    await saveShot(tester, key, name);
    if (_shotsDir.isNotEmpty) {
      await tester.runAsync(() async {
        Directory(_shotsDir).createSync(recursive: true);
        File('build/shots/$name.png').copySync('$_shotsDir/$name.png');
      });
    }
  }

  Future<void> start(WidgetTester tester, String themeId) async {
    realShadows();
    await tester.runAsync(() async {
      await loadShotFonts();
      // A picture of a window, as the capture would give: a terminal.
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(const Rect.fromLTWH(0, 0, 360, 208), Paint()..color = const Color(0xFF16213A));
      canvas.drawRect(const Rect.fromLTWH(0, 0, 360, 24), Paint()..color = const Color(0xFF0A101C));
      for (var i = 0; i < 7; i++) {
        canvas.drawRect(Rect.fromLTWH(20, 44.0 + i * 20, 220.0 - i * 16, 8), Paint()..color = const Color(0xFF3A4A6A));
      }
      final image = await recorder.endRecording().toImage(360, 208);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      png = data!.buffer.asUint8List();
    });
    SharedPreferences.setMockInitialValues({'app_theme_id': themeId});
    prefs = await SharedPreferences.getInstance();
    PackageInfo.setMockInitialValues(
        appName: 'ZestSSH', packageName: 'com.affluentlabs.zestssh', version: '3.3.0', buildNumber: '340', buildSignature: '');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime.now().toUtc();
    server = FakeTicketServer()..now = now.subtract(const Duration(days: 2));
    server.bearers['a-bearer'] = 'a-uid';
    service = TicketService(db,
        client: MockClient(server.handle),
        baseUrl: 'https://api.test/v1',
        bearer: () async => 'a-bearer',
        now: () => DateTime.now().subtract(const Duration(days: 2)));
    AppColors.applyTheme(BuiltInThemes.getById(themeId).colorScheme);
    resetSupportHubDraft();

    // Everyone's ideas and known issues, as the mockups have them.
    DateTime ago(Duration d) => now.subtract(d);
    server
      ..addPublic(id: 'a00000000001', type: 'suggestion', title: 'Mosh support for flaky connections',
          body: 'Keep sessions alive on bad Wi-Fi and when your phone switches networks.', state: 'planned', votes: 42,
          comments: 9, createdAt: ago(const Duration(days: 21)))
      ..addPublic(id: 'a00000000002', type: 'suggestion', title: 'Serial console over USB',
          body: 'Talk to switches and routers from the desktop app without another tool.', votes: 31, comments: 6,
          createdAt: ago(const Duration(days: 33)))
      ..addPublic(id: 'a00000000003', type: 'suggestion', title: 'FIDO2 security keys (YubiKey) for SSH',
          body: 'Sign in with sk-ed25519 keys stored on a hardware key.', state: 'in_progress', votes: 27, comments: 12,
          createdAt: ago(const Duration(days: 14)))
      ..addPublic(id: 'a00000000004', type: 'suggestion', title: 'Run a snippet on many hosts at once',
          body: 'Pick hosts, run one snippet, see each result side by side.', votes: 18, comments: 3,
          createdAt: ago(const Duration(days: 5)))
      ..addPublic(id: 'a00000000005', type: 'suggestion', title: 'Port forwarding on the free tier', state: 'shipped',
          version: '3.3', closed: true, createdAt: ago(const Duration(days: 3)))
      ..addPublic(id: 'a00000000006', type: 'suggestion', title: 'Passkeys and two-step sign-in', state: 'shipped',
          version: '3.3', closed: true, createdAt: ago(const Duration(days: 4)))
      ..addPublic(id: 'a00000000007', type: 'suggestion', title: 'Team invites by QR code', state: 'shipped',
          version: '3.0', closed: true, createdAt: ago(const Duration(days: 40)))
      ..addPublic(id: 'a00000000008', type: 'suggestion', title: 'Import from SecureCRT', state: 'shipped',
          version: '3.2', closed: true, createdAt: ago(const Duration(days: 20)))
      ..addPublic(id: 'b00000000001', type: 'bug', title: 'SFTP: deleting big folders is slow, no progress shown',
          body: 'Deleting a folder of 40k files takes ten minutes with nothing on screen.', state: 'fixed', version: '3.3.1',
          votes: 23, comments: 4, createdAt: ago(const Duration(days: 9)))
      ..addPublic(id: 'b00000000002', type: 'bug', title: 'Delete in SFTP looks frozen until it finishes',
          body: 'The pane stops answering while a delete runs.', state: 'investigating', votes: 8, comments: 2,
          createdAt: ago(const Duration(days: 6)))
      ..addPublic(id: 'b00000000003', type: 'bug', title: 'Sync pauses after the PC sleeps',
          body: 'After the laptop wakes, sync says paused until I open Settings.', state: 'investigating', votes: 11,
          comments: 5, createdAt: ago(const Duration(days: 12)))
      ..addPublic(id: 'b00000000004', type: 'bug', title: 'Host key warning after changing jump host', state: 'fixed',
          version: '3.2.7', closed: true, votes: 6, createdAt: ago(const Duration(days: 16)));
    server.publicReports.firstWhere((r) => r.id == 'a00000000001').voters.add('a-uid');
  }

  /// My tickets as the mockups have them. Returns the thread's nonce.
  Future<String> seed(WidgetTester tester) async {
    late String thread;
    await tester.runAsync(() async {
      final base = DateTime.now().toUtc();
      // Closed: one fixed, one quiet, two older.
      for (final (title, body, days) in [
        ('Theme preview flickers on resize', 'Dragging the window edge makes it flicker.', 30),
        ('Port forward drops after an hour', 'The tunnel closes by itself.', 26),
      ]) {
        server.now = base.subtract(Duration(days: days));
        final r = await service.createPrivate(type: TicketType.bug, title: title, body: body, context: _ctx);
        server.staffClose((await service.ticket(r.nonce!))!.serverId!);
      }
      server.now = base.subtract(const Duration(days: 25));
      final pixel = await service.createSupport(
          title: 'Sync paused on my Pixel', body: 'It says paused and the button does nothing.', context: _ctx);
      final pixelId = (await service.ticket(pixel.nonce!))!.serverId!;
      server.staffReply(pixelId, 'Is battery saving on for ZestSSH?', name: 'Robin');
      server.quietClose(pixelId);
      server.now = base.subtract(const Duration(days: 16));
      final hostKey = await service.createPrivate(
          type: TicketType.bug,
          title: 'Host key warning after changing jump host',
          body: 'The warning names the old host.',
          context: _ctx);
      final hostKeyTicket = server.tickets[(await service.ticket(hostKey.nonce!))!.serverId!]!
        ..state = 'fixed'
        ..stateVersion = '3.2.7';
      server.staffClose(hostKeyTicket.id);

      // Your ideas.
      server.now = base.subtract(const Duration(days: 7));
      final idea = FeedbackReport(
          type: FeedbackType.suggestion,
          title: 'Mosh support for flaky connections',
          body: 'Keep sessions alive on bad Wi-Fi.',
          context: _ctx,
          createdAt: DateTime.now().subtract(const Duration(days: 7)));
      final ideaOnServer = server.addReport(token: idea.ticketToken, type: 'suggestion', title: idea.title, body: idea.body)
        ..state = 'planned'
        ..votes = 41;
      await service.keepReport(idea, id: ideaOnServer.id, number: ideaOnServer.number);

      // Waiting for support.
      server.now = base.subtract(const Duration(days: 1));
      await service.createSupport(
          title: "Can't import my Termius export",
          body: 'The .json from Termius 9 says "unsupported version" in the import.',
          context: _ctx);

      // Needs your reply: the thread.
      server.now = base.subtract(const Duration(days: 2));
      final upload = await service.createPrivate(
        type: TicketType.bug,
        title: 'SFTP upload stalls on files over 2 GB',
        body: 'Uploading a 2.4 GB backup to my NAS over SFTP gets to around 60% and just sits there. Smaller files are fine. '
            'Same thing on Wi-Fi and wired.',
        context: const FeedbackContext(
            appVersion: '3.2.7', build: 330, platform: 'windows', osVersion: 'Windows 11', locale: 'en-US', tier: 'squeezed'),
        diagnostics: 'ZestSSH diagnostics\nApp: ZestSSH 3.2.7 (330)\nSystem: Windows 11\nLanguage: en-US\n',
        screenshot: png,
      );
      thread = upload.nonce!;
      final uploadTicket = server.tickets[(await service.ticket(thread))!.serverId!]!
        ..pickedUpAt = base.subtract(const Duration(days: 2)).add(const Duration(minutes: 32));
      server.now = base.subtract(const Duration(hours: 2));
      server.staffReply(
          uploadTicket.id,
          'Thanks, the log helped a lot. Big uploads stall when the server only accepts small packets, and 3.3.0 changes '
          'how uploads are split up to fix exactly that. Can you update and try the same file again?',
          name: 'Robin');
      await service.refresh();
    });
    return thread;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  List<Override> overrides({bool recording = false}) => [
        sharedPreferencesProvider.overrideWithValue(prefs),
        treeDatabaseProvider.overrideWithValue(db),
        dbReadyProvider.overrideWithValue(true),
        ticketServiceProvider.overrideWithValue(service),
        publicReportsServiceProvider.overrideWithValue(PublicReportsService(
            client: MockClient(server.handle), baseUrl: 'https://api.test/v1', bearer: () async => 'a-bearer')),
        feedbackServiceProvider.overrideWithValue(
            FeedbackService(db, prefs, client: MockClient(server.handle), baseUrl: 'https://api.test/v1')),
        cloudStatusProvider.overrideWith((_) async => CloudStatus.ok),
        appVersionLabelProvider.overrideWith((_) async => '3.3.0'),
        recordingModeProvider.overrideWith((ref) => recording),
      ];

  Future<(GlobalKey, ProviderContainer)> pump(
    WidgetTester tester,
    String themeId,
    Widget Function() page, {
    Size size = const Size(1440, 900),
    Locale locale = const Locale('en'),
    double textScale = 1,
    bool dock = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = BuiltInThemes.getById(themeId);
    final key = GlobalKey();
    final container = ProviderContainer(overrides: [
      ...overrides(),
      if (dock) helpDockProvider.overrideWith((_) => HelpPage.home),
    ]);
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
          locale: locale,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(backgroundColor: AppColors.v3Background, body: page()),
        ),
      ),
    ));
    await settle(tester);
    return (key, container);
  }

  Widget hub() => SupportHubPage(captureScreenshot: ({required bool redacted}) async => png, onClose: () {});

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
    plainShadows();
    debugDefaultTargetPlatformOverride = null;
  }

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';

    testWidgets('the four mockups on a computer ($tag)', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await start(tester, themeId);
      final thread = await seed(tester);
      final (key, c) = await pump(tester, themeId, hub);

      // 1. The Ideas board.
      c.read(supportHubTabProvider.notifier).state = HubTab.ideas;
      await settle(tester);
      await shot(tester, key, 'hub34_${tag}_1_ideas_board');

      // Known issues.
      c.read(supportHubTabProvider.notifier).state = HubTab.knownIssues;
      await settle(tester);
      await shot(tester, key, 'hub34_${tag}_1b_known_issues');

      // 2. Report a bug, with what might already be reported.
      c.read(supportHubTabProvider.notifier).state = HubTab.myTickets;
      c.read(supportHubComposeProvider.notifier).state = TicketType.bug;
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('hub-title')), 'Deleting a folder over SFTP takes forever');
      await tester.pump(kSimilarPause);
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('hub-screenshot-add')));
      await settle(tester);
      await shot(tester, key, 'hub34_${tag}_2_report_a_bug');
      await tester.tap(find.byKey(const ValueKey('hub-see-sent')));
      await settle(tester);
      await shot(tester, key, 'hub34_${tag}_2b_exactly_what_is_sent');
      Navigator.of(tester.element(find.byKey(const ValueKey('hub-sent-payload')))).pop();
      await settle(tester);

      // 3. The ticket's thread.
      c.read(supportHubComposeProvider.notifier).state = null;
      c.read(supportHubTicketProvider.notifier).state = thread;
      await settle(tester);
      await shot(tester, key, 'hub34_${tag}_3_ticket_thread');

      // Get help, and the form while the screen is recorded.
      c.read(supportHubComposeProvider.notifier).state = TicketType.support;
      await settle(tester);
      await shot(tester, key, 'hub34_${tag}_3b_get_help');
      Redactor.instance.enabled = true;
      addTearDown(() => Redactor.instance.enabled = false);
      c.read(supportHubComposeProvider.notifier).state = TicketType.bug;
      c.read(recordingModeProvider.notifier).state = true;
      await settle(tester);
      await shot(tester, key, 'hub34_${tag}_3c_report_recording');
      Redactor.instance.enabled = false;
      await finish(tester);
    }, skip: !shotsEnabled);

    testWidgets('4. the Help panel beside a session ($tag)', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await start(tester, themeId);
      await seed(tester);
      final (key, _) = await pump(
        tester,
        themeId,
        () => Row(
          children: [
            Expanded(
              child: Container(
                color: const Color(0xFF0B0D10),
                padding: const EdgeInsets.all(18),
                child: const Text(
                  'deploy@web-01~\$ sudo systemctl status nginx\n'
                  '● nginx.service - A high performance web server\n'
                  '   Active: active (running) since Thu 2026-11-05 08:14:22 PST\n'
                  'deploy@web-01~\$ df -h /var\n'
                  'Filesystem   Size  Used Avail Use% Mounted on\n'
                  '/dev/sda2     98G   61G   33G  65% /var\n'
                  'deploy@web-01~\$',
                  style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13, height: 1.7, color: Color(0xFFD7DCE2)),
                ),
              ),
            ),
            HelpDock(
              captureScreenshot: ({required bool redacted}) async => png,
              onCopyRedactedScreenshot: () {},
              onOpenShortcuts: () {},
              onAbout: () {},
            ),
          ],
        ),
        dock: true,
      );
      await shot(tester, key, 'hub34_${tag}_4_help_panel');
      await finish(tester);
    }, skip: !shotsEnabled);
  }

  testWidgets('a phone: the same content in one column (dark)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await start(tester, 'graphite');
    final thread = await seed(tester);
    final (key, c) = await pump(
      tester,
      'graphite',
      () => SafeArea(child: SupportHubPage(captureScreenshot: null, onClose: () {})),
      size: const Size(390, 844),
    );
    await shot(tester, key, 'hub34_phone_1_my_tickets');
    c.read(supportHubTabProvider.notifier).state = HubTab.ideas;
    await settle(tester);
    await shot(tester, key, 'hub34_phone_2_ideas');
    c.read(supportHubTabProvider.notifier).state = HubTab.knownIssues;
    await settle(tester);
    await shot(tester, key, 'hub34_phone_3_known_issues');
    c.read(supportHubTabProvider.notifier).state = HubTab.myTickets;
    c.read(supportHubTicketProvider.notifier).state = thread;
    await settle(tester);
    await shot(tester, key, 'hub34_phone_4_thread');
    c.read(supportHubComposeProvider.notifier).state = TicketType.bug;
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('hub-title')), 'Deleting a folder over SFTP takes forever');
    await tester.pump(kSimilarPause);
    await settle(tester);
    await shot(tester, key, 'hub34_phone_5_report_a_bug');
    await finish(tester);
  }, skip: !shotsEnabled);

  group('fits with the real font', () {
    // Every language at a phone's width, the narrowest the list and the
    // conversation share, and a common laptop's; a few at the rest.
    final sizes = <(Locale, Size, double)>[
      for (final locale in AppLocalizations.supportedLocales) ...[
        (locale, const Size(390, 844), 1.0),
        (locale, const Size(800, 700), 1.0),
        (locale, const Size(1280, 800), 1.0),
      ],
      for (final code in const ['en', 'de', 'ru', 'ar', 'ja'])
        for (final width in const [1000.0, 1920.0]) (Locale(code), Size(width, 800), 1.0),
      for (final code in const ['en', 'de', 'ru']) (Locale(code), const Size(1100, 800), 1.25),
    ];
    for (final (locale, size, textScale) in sizes) {
      testWidgets('${locale.languageCode} at ${size.width.toInt()}, text at $textScale', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        await start(tester, 'graphite');
        final thread = await seed(tester);
        final (key, c) = await pump(tester, 'graphite', hub, size: size, locale: locale, textScale: textScale);
        for (final tab in HubTab.values) {
          c.read(supportHubTabProvider.notifier).state = tab;
          await settle(tester);
          expect(tester.takeException(), isNull, reason: '$tab');
        }
        if (size.width == 1280 && locale.languageCode != 'en') {
          await shot(tester, key, 'hub34_${locale.languageCode}_1280_ideas');
        }
        c.read(supportHubTabProvider.notifier).state = HubTab.myTickets;
        c.read(supportHubTicketProvider.notifier).state = thread;
        await settle(tester);
        expect(tester.takeException(), isNull, reason: 'the thread');
        for (final kind in TicketType.values) {
          c.read(supportHubComposeProvider.notifier).state = kind;
          await settle(tester);
          expect(tester.takeException(), isNull, reason: '$kind');
        }
        await finish(tester);
      }, skip: !shotsEnabled);
    }
  });
}
