import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show sin;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart' show SftpFileAttrs;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/onboarding/data/lan_scan_service.dart';
import 'package:zestssh/features/onboarding/widgets/lan_scan_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/automation_api_key.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart' show RecordingEntry;
import 'package:zestssh/providers/monitoring_providers.dart' show monitorHistorySamplesProvider;
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/automation/scheduled_tasks_screen.dart';
import 'package:zestssh/providers/scheduled_task_providers.dart' show ScheduledTasksHere;
import 'package:zestssh/ui/screens/connection/qr_scan_screen.dart';
import 'package:zestssh/ui/screens/help/guides_screen.dart';
import 'package:zestssh/ui/screens/import/putty_import_screen.dart';
import 'package:zestssh/ui/screens/monitoring/server_detail_screen.dart';
import 'package:zestssh/ui/screens/purchase/desktop_upgrade_view.dart';
import 'package:zestssh/ui/screens/purchase/upgrade_screen.dart';
import 'package:zestssh/ui/screens/replay/session_replay_screen.dart';
import 'package:zestssh/ui/screens/security/pin_setup_screen.dart';
import 'package:zestssh/ui/screens/sftp/sftp_browser_screen.dart';
import 'package:zestssh/ui/screens/transcripts/transcript_viewer_screen.dart';
import 'package:zestssh/ui/screens/transcripts/transcripts_screen.dart';

import '../helpers/monitor_table_fixture.dart';
import 'shots_util.dart';

/// Pictures of the screens no other picture draws (found in a
/// review), so that the next review sees them too: a phone's
/// SFTP browser, the Upgrade page on a computer and on a phone, PIN setup,
/// the local network scan, the QR scan as far as a test draws it with no
/// camera, PuTTY's import, the Guides, a session's replay and its saved
/// transcripts, Scheduled tasks and a host's page in Server monitor. With
/// the real fonts, in the app's dark and light themes, and only made-up
/// hosts, people, files and networks:
///
///   flutter test --dart-define=ZEST_SHOTS=true --dart-define=ZEST_ORCHARDS=true test/visual/uncovered_screens_shots_test.dart
///
/// Pictures land in build/shots/: a computer's at 1440 by 900, a phone's
/// (phone-*) at twice the size of a 390 by 844 screen.
const _themes = ['default_dark', 'default_light'];

/// Who the pictures are signed in as: Alex of the demo world (the website's).
const _alex = UserProfile(uid: 'uid-alex', email: 'alex@example.com', displayName: 'Alex');

class _Plan extends StateNotifier<bool> implements ProStatusNotifier {
  _Plan(super.owned);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Cloud extends StateNotifier<bool> implements CloudSyncStatusNotifier {
  _Cloud(super.owned);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Health checks that never run.
class _Health extends ConnectionHealthNotifier {}

/// deploy's home folder on web-01, as a phone's SFTP browser lists it.
class _DemoSftp implements SftpService {
  static final _at = DateTime(2026, 11, 12, 9, 28);

  SftpEntry _dir(String name, DateTime at) =>
      SftpEntry(name: name, path: '/home/deploy/$name', isDirectory: true, size: 4096, modifiedAt: at, permissions: 'drwxr-xr-x');
  SftpEntry _file(String name, int size, DateTime at) =>
      SftpEntry(name: name, path: '/home/deploy/$name', isDirectory: false, size: size, modifiedAt: at, permissions: '-rw-r--r--');

  late final List<SftpEntry> _entries = [
    _dir('.config', DateTime(2026, 10, 2, 14, 11)),
    _dir('app', DateTime(2026, 11, 12, 8, 41)),
    _dir('backups', DateTime(2026, 11, 11, 23, 0)),
    _dir('logs', DateTime(2026, 11, 12, 9, 30)),
    _dir('releases', DateTime(2026, 11, 8, 17, 20)),
    _file('deploy.sh', 2150, DateTime(2026, 11, 8, 17, 22)),
    _file('docker-compose.yml', 1843, _at),
    _file('nginx.conf', 3120, DateTime(2026, 11, 5, 10, 2)),
    _file('notes.md', 4710, DateTime(2026, 11, 2, 11, 5)),
    _file('shop-3.4.1.tar.gz', 48234112, DateTime(2026, 11, 12, 8, 10)),
  ];

  @override
  Future<String> getHomeDirectory() async => '/home/deploy';

  @override
  Future<List<SftpEntry>> listDirectory(String path) async => path == '/home/deploy' ? _entries : const [];

  @override
  Future<SftpFileAttrs?> statOrNull(String path) async => null;

  @override
  bool get isOpen => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in a picture');
}

/// A made-up home network: its scope is fixed, and a scan finds four SSH
/// servers at once.
class _DemoNetwork extends LanScanService {
  @override
  Future<LanScanScope?> resolveScope() async => const LanScanScope(cidr: '192.168.10.0/24', hostCount: 254);

  @override
  Future<void> scan({
    required LanScanScope scope,
    required void Function(LanScanHit hit) onHit,
    required void Function(int scanned, int total) onProgress,
  }) async {
    for (final (host, ms) in const [('192.168.10.21', 3), ('192.168.10.22', 4), ('192.168.10.30', 2), ('192.168.10.50', 7)]) {
      onHit(LanScanHit(host: host, latencyMs: ms));
    }
    onProgress(scope.hostCount, scope.hostCount);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Saved hosts of the demo world, in a database of their own.
  Future<AppDatabase> hosts(WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => tester.runAsync(db.close));
    final at = DateTime(2026, 9, 24);
    for (final (i, (label, address)) in const [
      ('web-01', '192.168.10.21'),
      ('web-02', '192.168.10.22'),
      ('db-primary', '192.168.10.31'),
      ('log-store', '192.168.10.24'),
    ].indexed) {
      await tester.runAsync(() => db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'c$i',
            label: label,
            host: address,
            port: const Value(22),
            createdAt: at,
            updatedAt: at,
          )));
    }
    return db;
  }

  /// [home] on a computer (1440 by 900) or a phone (390 by 844), in
  /// [themeId], with the app's fonts and theme; a phone as Android draws it.
  Future<(GlobalKey, ProviderContainer)> pumpScreen(
    WidgetTester tester,
    String themeId,
    Widget home, {
    bool phone = false,
    List<Override> extra = const [],
    Map<String, Object> prefs = const {},
    Map<String, String> secrets = const {},
    AppDatabase? db,
  }) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    debugDefaultTargetPlatformOverride = phone ? TargetPlatform.android : TargetPlatform.windows;
    FlutterSecureStorage.setMockInitialValues(secrets);
    SharedPreferences.setMockInitialValues({'app_theme_id': themeId, ...prefs});
    final preferences = await SharedPreferences.getInstance();
    final database = db ?? await hosts(tester);
    tester.view.physicalSize = phone ? const Size(390, 844) : const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = BuiltInThemes.getById(themeId);
    AppColors.applyTheme(theme.colorScheme);
    final key = GlobalKey();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      databaseProvider.overrideWithValue(database),
      treeDatabaseProvider.overrideWithValue(database),
      currentUserProvider.overrideWith((_) => _alex),
      healthChecksEnabledProvider.overrideWith((ref) => false),
      connectionHealthProvider.overrideWith((ref) => _Health()),
      recordingModeProvider.overrideWith((ref) => false),
      ...extra,
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
          locale: const Locale('en'),
          home: home,
        ),
      ),
    ));
    await settle(tester);
    return (key, container);
  }

  Future<void> shot(WidgetTester tester, GlobalKey key, String name, {bool phone = false}) =>
      saveShot(tester, key, name, pixelRatio: phone ? 2 : 1);

  Future<void> finish(WidgetTester tester) async {
    plainShadows();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
    debugDefaultTargetPlatformOverride = null;
  }

  for (final themeId in _themes) {
    testWidgets('a phone: the SFTP browser, and a file\'s actions, $themeId', (tester) async {
      final (key, _) = await pumpScreen(tester, themeId, SftpBrowserScreen(sftp: _DemoSftp(), connectionLabel: 'web-01'),
          phone: true);
      expect(find.text('docker-compose.yml'), findsOneWidget);
      await shot(tester, key, 'phone-sftp-browser-$themeId', phone: true);
      await tester.tap(find.text('docker-compose.yml'));
      await settle(tester);
      await shot(tester, key, 'phone-sftp-file-actions-$themeId', phone: true);
      await finish(tester);
    }, skip: !shotsEnabled);

    testWidgets('a computer: the Upgrade page, nothing owned, then owning Squeezed, $themeId', (tester) async {
      final (key, container) = await pumpScreen(tester, themeId, const Scaffold(body: DesktopUpgradeView()), extra: [
        isProProvider.overrideWith((ref) => _Plan(false)),
        isCloudSyncProvider.overrideWith((ref) => _Cloud(false)),
      ]);
      await tester.pump(const Duration(seconds: 2));
      await shot(tester, key, 'upgrade-computer-$themeId');
      (container.read(isProProvider.notifier) as _Plan).state = true;
      await tester.pump(const Duration(seconds: 2));
      await shot(tester, key, 'upgrade-computer-squeezed-$themeId');
      await finish(tester);
    }, skip: !shotsEnabled);

    testWidgets('a phone: the Upgrade page, nothing owned, $themeId', (tester) async {
      UpgradeScreen.debugDesktop = false;
      addTearDown(() => UpgradeScreen.debugDesktop = null);
      final (key, _) = await pumpScreen(tester, themeId, const UpgradeScreen(), phone: true, extra: [
        isProProvider.overrideWith((ref) => _Plan(false)),
        isCloudSyncProvider.overrideWith((ref) => _Cloud(false)),
        // No store in a picture: the prices the app shows without one.
        offeringsProvider.overrideWith((ref) => Completer<Never>().future),
      ]);
      await shot(tester, key, 'phone-upgrade-$themeId', phone: true);
      await finish(tester);
    }, skip: !shotsEnabled);

    testWidgets('PIN setup: a computer\'s dialog, its two steps; a phone\'s page, $themeId', (tester) async {
      late BuildContext context;
      var (key, _) = await pumpScreen(tester, themeId, Scaffold(body: Builder(builder: (c) {
        context = c;
        return const SizedBox.expand();
      })));
      // ignore: discarded_futures
      PinSetupScreen.showAdaptive(context);
      await settle(tester);
      await shot(tester, key, 'pin-setup-computer-$themeId');
      await tester.enterText(find.byType(TextField).first, '4826');
      await settle(tester);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      await shot(tester, key, 'pin-setup-computer-confirm-$themeId');
      await finish(tester);

      (key, _) = await pumpScreen(tester, themeId, const PinSetupScreen(), phone: true);
      await shot(tester, key, 'phone-pin-setup-$themeId', phone: true);
      await finish(tester);
    }, skip: !shotsEnabled);

    testWidgets('the local network scan before Start and after it, on a phone and a computer, $themeId', (tester) async {
      // As LanScanScreen draws it (lib/features/onboarding/lan_scan_screen.dart),
      // on a made-up network: the screen probes this computer's own.
      Widget screen() => Builder(builder: (context) {
            return Scaffold(
              backgroundColor: AppColors.background,
              appBar: AppBar(
                  title: Text(en.networkScanTitle), backgroundColor: Colors.transparent, elevation: 0),
              body: SafeArea(
                child: LayoutBuilder(builder: (context, constraints) {
                  final width = constraints.maxWidth < 560 ? constraints.maxWidth : 560.0;
                  return Center(
                    child: SizedBox(
                      width: width,
                      height: constraints.maxHeight,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: LanScanView(service: _DemoNetwork(), onAdded: (_, _) {}),
                      ),
                    ),
                  );
                }),
              ),
            );
          });
      for (final phone in [true, false]) {
        final (key, _) = await pumpScreen(tester, themeId, screen(), phone: phone);
        final tag = phone ? 'phone-lan-scan' : 'lan-scan-computer';
        await shot(tester, key, '$tag-$themeId', phone: phone);
        await tester.tap(find.text(en.networkScanStart).first);
        await settle(tester);
        await shot(tester, key, '$tag-found-$themeId', phone: phone);
        await finish(tester);
      }
    }, skip: !shotsEnabled);

    testWidgets('a phone: the QR scan with no camera, $themeId', (tester) async {
      // A test has no camera: the scanner's plugin answers as a phone does
      // whose camera the app may not use, and the screen draws what it
      // draws then (its frame, its hint, and why there is no picture).
      final messenger = tester.binding.defaultBinaryMessenger;
      const method = MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');
      messenger.setMockMethodCallHandler(method, (call) async => switch (call.method) {
            'state' => 2,
            'request' => false,
            _ => null,
          });
      for (final name in ['event', 'deviceOrientation']) {
        messenger.setMockStreamHandler(
            EventChannel('dev.steenbakker.mobile_scanner/scanner/$name'), MockStreamHandler.inline(onListen: (_, _) {}));
      }
      addTearDown(() {
        messenger.setMockMethodCallHandler(method, null);
        for (final name in ['event', 'deviceOrientation']) {
          messenger.setMockStreamHandler(EventChannel('dev.steenbakker.mobile_scanner/scanner/$name'), null);
        }
      });
      final (key, _) = await pumpScreen(tester, themeId, const QrScanScreen(), phone: true);
      await shot(tester, key, 'phone-qr-scan-$themeId', phone: true);
      await finish(tester);
    }, skip: !shotsEnabled);

    testWidgets("a computer: PuTTY's saved sessions to import, $themeId", (tester) async {
      final (key, _) = await pumpScreen(
        tester,
        themeId,
        const PuttyImportScreen(debugSessions: [
          ('web-01', '192.168.10.21', 22, 'deploy'),
          ('web-02', '192.168.10.22', 22, 'deploy'),
          ('db-primary', '192.168.10.31', 22, 'deploy'),
          ('edge-router', '192.168.20.1', 2222, 'admin'),
          ('build-runner', '192.168.10.50', 22, 'ci'),
        ]),
      );
      await shot(tester, key, 'putty-import-$themeId');
      await finish(tester);
    }, skip: !shotsEnabled);

    testWidgets('the Guides, and a search of them, on a phone and a computer, $themeId', (tester) async {
      for (final phone in [true, false]) {
        final (key, _) = await pumpScreen(tester, themeId, GuidesScreen(onOpen: (_) {}), phone: phone);
        final tag = phone ? 'phone-guides' : 'guides-computer';
        await shot(tester, key, '$tag-$themeId', phone: phone);
        await tester.enterText(find.byType(TextField).first, 'network');
        await settle(tester);
        await shot(tester, key, '$tag-search-$themeId', phone: phone);
        await finish(tester);
      }
    }, skip: !shotsEnabled);

    testWidgets("a session's replay, part way, $themeId", (tester) async {
      const g = '\x1b[32m', b = '\x1b[34m', r = '\x1b[31m', o = '\x1b[0m';
      const prompt = '${g}deploy@web-01$o:$b~$o\$ ';
      final entries = [
        const RecordingEntry(timestamp: Duration.zero, data: 'Welcome to Ubuntu 24.04.3 LTS (GNU/Linux 6.8.0-124-generic x86_64)\r\n\r\n'),
        const RecordingEntry(timestamp: Duration(seconds: 2), data: prompt),
        const RecordingEntry(timestamp: Duration(seconds: 5), data: 'docker compose ps\r\n'),
        const RecordingEntry(
            timestamp: Duration(seconds: 6),
            data: 'NAME      IMAGE              STATUS\r\napi-1     shop/api:3.4.1     Up 6 days\r\nweb-1     nginx:1.27-alpine  Up 6 days\r\n'),
        const RecordingEntry(timestamp: Duration(seconds: 9), data: prompt),
        const RecordingEntry(timestamp: Duration(seconds: 14), data: 'docker compose logs --tail 3 api\r\n'),
        const RecordingEntry(
            timestamp: Duration(seconds: 15),
            data: 'api-1  | listening on :8080\r\napi-1  | ${r}ERROR: upstream redis refused connection$o\r\napi-1  | retrying in 2s\r\n'),
        const RecordingEntry(timestamp: Duration(seconds: 17), data: prompt),
        const RecordingEntry(timestamp: Duration(seconds: 31), data: 'sudo systemctl restart redis\r\n'),
        const RecordingEntry(timestamp: Duration(minutes: 1, seconds: 4), data: prompt),
      ];
      final data = SessionReplayData(
          sessionId: 's0', connectionLabel: 'web-01', startedAt: DateTime(2026, 11, 12, 9, 12), entries: entries);
      // The replay's terminal asks for the system's monospace font, which a
      // test has none of: the app's own stands in for it.
      await tester.runAsync(() async {
        final loader = FontLoader('monospace')
          ..addFont(Future.value(ByteData.view(File('assets/fonts/JetBrainsMono-Regular.ttf').readAsBytesSync().buffer)));
        await loader.load();
      });
      for (final phone in [false, true]) {
        final (key, _) = await pumpScreen(tester, themeId, SessionReplayScreen(data: data), phone: phone);
        // Moved to the seventh of its ten pieces.
        final slider = find.byType(Slider);
        final box = tester.getRect(slider);
        await tester.tapAt(Offset(box.left + 24 + (box.width - 48) * 0.7, box.center.dy));
        await settle(tester);
        await shot(tester, key, '${phone ? 'phone-replay' : 'replay-computer'}-$themeId', phone: phone);
        await finish(tester);
      }
    }, skip: !shotsEnabled);

    testWidgets('the saved transcripts, and one of them read, $themeId', (tester) async {
      final folder = await tester.runAsync(() => Directory.systemTemp.createTemp('zest-shots-transcripts'));
      addTearDown(() => tester.runAsync(() => folder!.delete(recursive: true)));
      final files = {
        'web-01_2026-11-12_0912.txt':
            'Welcome to Ubuntu 24.04.3 LTS (GNU/Linux 6.8.0-124-generic x86_64)\n\ndeploy@web-01:~\$ docker compose ps\n'
                'NAME      IMAGE              STATUS\napi-1     shop/api:3.4.1     Up 6 days\nweb-1     nginx:1.27-alpine  Up 6 days\n'
                'deploy@web-01:~\$ docker compose logs --tail 3 api\napi-1  | listening on :8080\n'
                'api-1  | ERROR: upstream redis refused connection\napi-1  | retrying in 2s\ndeploy@web-01:~\$ exit\n',
        'db-primary_2026-11-11_2305.txt': 'deploy@db-primary:~\$ pg_dump shop > backups/shop-2026-11-11.dump\n',
        'log-store_2026-11-10_1740.txt': 'deploy@log-store:~\$ du -sh /var/log/*\n',
      };
      final written = [DateTime(2026, 11, 12, 9, 40), DateTime(2026, 11, 11, 23, 12), DateTime(2026, 11, 10, 17, 52)];
      for (final (i, MapEntry(key: name, value: text)) in files.entries.indexed) {
        await tester.runAsync(() async {
          final file = File('${folder!.path}${Platform.pathSeparator}$name');
          await file.writeAsString(text);
          // Saved when its session ended, as its name says.
          await file.setLastModified(written[i]);
        });
      }
      for (final phone in [false, true]) {
        final (key, _) = await pumpScreen(tester, themeId, const TranscriptsScreen(), phone: phone, extra: [
          transcriptsFolderProvider.overrideWith((ref) async => folder!),
        ]);
        await shot(tester, key, '${phone ? 'phone-transcripts' : 'transcripts-computer'}-$themeId', phone: phone);
        await finish(tester);
      }
      final (key, _) = await pumpScreen(
          tester, themeId, TranscriptViewerScreen(path: '${folder!.path}${Platform.pathSeparator}web-01_2026-11-12_0912.txt'));
      await shot(tester, key, 'transcript-viewer-$themeId');
      await finish(tester);
    }, skip: !shotsEnabled);

    testWidgets('Scheduled tasks on Android, and what a computer says of them, $themeId', (tester) async {
      final db = await hosts(tester);
      final at = DateTime(2026, 11, 1, 9);
      for (final (id, name, action, command, type, minutes, hour, day, last, result) in [
        ('t1', 'Nightly database dump', 'execute', 'pg_dump shop > backups/shop.dump', 'daily', 60, 3, null,
            DateTime(2026, 11, 12, 3), 'success'),
        ('t2', 'Restart the API if it is down', 'execute', 'docker compose up -d api', 'interval', 30, null, null,
            DateTime(2026, 11, 12, 9, 30), 'success'),
        ('t3', 'Weekly log clean-up', 'execute', 'journalctl --vacuum-time=14d', 'weekly', 60, 4, 7,
            DateTime(2026, 11, 9, 4), 'failure: Connection refused'),
      ]) {
        await tester.runAsync(() => db.into(db.scheduledTasks).insert(ScheduledTasksCompanion.insert(
              id: id,
              name: name,
              action: action,
              connectionId: id == 't1' ? 'c2' : 'c0',
              command: Value(command),
              scheduleType: type,
              intervalMinutes: Value(minutes),
              hour: Value(hour),
              minute: const Value(0),
              dayOfWeek: Value(day),
              apiKeyId: 'key-phone',
              createdAt: at,
              lastRunAt: Value(last),
              lastResult: Value(result),
            )));
      }
      final key = AutomationApiKey.fromSecret(id: 'key-phone', label: 'This phone', secret: 'zk_made_up_0000', createdAt: at);
      final secrets = {'automation_api_keys': jsonEncode([key.toJson()])};
      ScheduledTasksScreen.debugHere = ScheduledTasksHere.android;
      addTearDown(() => ScheduledTasksScreen.debugHere = null);
      var (shotKey, _) = await pumpScreen(tester, themeId, const ScheduledTasksScreen(),
          phone: true, db: db, secrets: secrets, extra: [isProProvider.overrideWith((ref) => _Plan(true))]);
      await shot(tester, shotKey, 'phone-scheduled-tasks-$themeId', phone: true);
      await finish(tester);

      // A computer's (4.0): its scheduler runs them while ZestSSH is open.
      ScheduledTasksScreen.debugHere = ScheduledTasksHere.computer;
      (shotKey, _) = await pumpScreen(tester, themeId, const ScheduledTasksScreen(), db: db, secrets: secrets,
          extra: [isProProvider.overrideWith((ref) => _Plan(true))]);
      await shot(tester, shotKey, 'scheduled-tasks-computer-$themeId');
      await finish(tester);
    }, skip: !shotsEnabled);

    testWidgets("a phone: a host's page in Server monitor, $themeId", (tester) async {
      final fleet = MonitorFleet();
      final db = await tester.runAsync(fleet.database);
      addTearDown(() => tester.runAsync(db!.close));
      final prefs = await tester.runAsync(fleet.preferences);
      final (key, _) = await pumpScreen(
        tester,
        themeId,
        const ServerDetailScreen(connectionId: 'web1', serverName: 'web-01', host: '192.168.10.21', port: 22),
        phone: true,
        db: db,
        prefs: {for (final k in prefs!.getKeys()) k: prefs.get(k)!},
        extra: [
          ...fleet.overrides(db!, prefs).skip(2),
          // A day of web-01's readings, every half hour, for its chart.
          monitorHistorySamplesProvider.overrideWith((ref, arg) async => [
                for (var i = 0; i < 48; i++)
                  MonitorSample(
                    id: i,
                    connectionId: arg.$1,
                    capturedAt: fleet.now.subtract(Duration(minutes: (47 - i) * 30)),
                    ok: true,
                    resolutionSeconds: 1800,
                    cpuPercent: 18 + 14 * sin(i / 3) + (i == 30 ? 40 : 0),
                    ramPercent: 64 + 6 * sin(i / 7),
                    diskPercent: 37 + i / 24,
                  ),
              ]),
        ],
      );
      await shot(tester, key, 'phone-server-detail-$themeId', phone: true);
      await finish(tester);
    }, skip: !shotsEnabled);
  }
}
