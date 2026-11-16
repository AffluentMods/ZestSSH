import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/data/network_repository.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/profile_avatar_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/theme_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/server_stats_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';

import 'monitor_table_fixture.dart';

/// The demo world for the 3.0 quick wins' tests and pictures (phone and
/// tablet): every name and address is invented (the demo fleet's
/// 192.168.10.x and 192.168.20.x).
const quickWinsHosts = [
  ['web-01', '192.168.10.21'],
  ['web-02', '192.168.10.22'],
  ['mac-studio', '192.168.10.30'],
  ['hypervisor-b', '192.168.20.12'],
  ['edge-router', '192.168.20.1'],
  ['log-store', '192.168.10.24'],
  ['db-primary', '192.168.10.31'],
];

/// The phone's size and the tablet's whose Home is these tabs: a 10 inch
/// Android tablet upright, 800 wide (4.0, decision C: a large screen, 840 and
/// wider, has the computer's shell, test/visual/shell_shots_test.dart).
const quickWinsPhone = Size(430, 932);
const quickWinsTablet = Size(800, 1280);

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Juiced extends StateNotifier<bool> implements CloudSyncStatusNotifier {
  _Juiced() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// What the reachability checks say: edge-router (c4) does not answer.
class QuickWinsHealth extends ConnectionHealthNotifier {
  QuickWinsHealth() {
    final at = DateTime.now();
    state = {
      for (var i = 0; i < quickWinsHosts.length; i++)
        'c$i': HealthCheckResult(
            status: i == 4 ? ConnectionHealth.offline : ConnectionHealth.online,
            latencyMs: i == 4 ? null : 2 + i,
            checkedAt: at),
    };
  }
}

/// Two sessions to web-01 (started at 9:14 and 9:20), one to db-primary,
/// dropped (a test keeps no connection open).
class QuickWinsSessions extends ActiveSessionsNotifier {
  QuickWinsSessions(super.ref) {
    state = {
      's1': SessionState(
          status: SessionStatus.disconnected,
          connectionId: 'c0',
          connectionLabel: 'web-01',
          host: '192.168.10.21',
          lastStartedAt: DateTime(2026, 9, 24, 9, 14)),
      's2': SessionState(
          status: SessionStatus.disconnected,
          connectionId: 'c0',
          connectionLabel: 'web-01',
          host: '192.168.10.21',
          lastStartedAt: DateTime(2026, 9, 24, 9, 20)),
      's3': SessionState(
          status: SessionStatus.disconnected,
          connectionId: 'c6',
          connectionLabel: 'db-primary',
          host: '192.168.10.31',
          lastStartedAt: DateTime(2026, 9, 24, 9, 31)),
    };
  }
}

/// The Monitor fleet with log-store's disk nearly full: three hosts that
/// need attention (log-store's disk, hypervisor-a's RAM, vpn-gateway's
/// missing login) and nine that need nothing.
class QuickWinsFleet extends MonitorFleet {
  @override
  Map<String, ServerStats> get stats => {
        ...super.stats,
        'logs': ServerStats(
          cpuPercent: 6,
          ramUsedMB: 8000,
          ramTotalMB: 16000,
          diskPercent: 96,
          loadAverage: const [0.14, 0.14, 0.14],
          pingMs: 2,
          uptimeSeconds: 12 * 86400,
          collectedAt: now.subtract(const Duration(minutes: 2)),
          source: MetricSource.ssh,
        ),
      };
}

/// Hosts c0 to c6, four keys (an RSA one among them), four forwards (one
/// with no name), four snippets and two networks.
Future<AppDatabase> quickWinsDb() async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final at = DateTime(2026, 9, 24);
  for (final (id, label, user, method, type, fp, isDefault) in [
    ('k-ops', 'Ops laptop', 'deploy', 'key', 'ssh-ed25519', 'SHA256:Hq3vR1kZ8sYdWm2Tq9LpXc4FbN7GzJ5aK0eUoVtWc', true),
    ('k-nas', 'Old NAS key', 'admin', 'key', 'ssh-rsa', 'SHA256:pV8sYdWHq3vR1kZm2Tq9LXc4FbN7GzJ5aK0eUoVtQ', false),
    ('k-ci', 'Build key', 'ci', 'key', 'ssh-ed25519', 'SHA256:nC7xKjMNYpi8QHq3vR1kZ8sYdWm2Tq9LpXc4FbN7G', false),
    ('p-router', 'Router admin', 'root', 'password', null, null, false),
  ]) {
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
          id: id,
          label: label,
          username: user,
          authMethod: method,
          keyType: Value(type),
          publicKeyFingerprint: Value(fp),
          isDefault: Value(isDefault),
          createdAt: at,
        ));
  }
  for (var i = 0; i < quickWinsHosts.length; i++) {
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'c$i',
          label: quickWinsHosts[i][0],
          host: quickWinsHosts[i][1],
          identityId: Value(i == 4 ? 'p-router' : (i == 5 ? 'k-nas' : 'k-ops')),
          colorValue: Value(i == 0 ? 0xFFFF7A1A : i == 1 ? 0xFF4F9D69 : null),
          port: const Value(22),
          createdAt: at,
          updatedAt: at,
        ));
  }
  for (final (id, conn, type, bind, host, port, label, auto) in [
    ('pf-graf', 'c5', 'local', 3000, 'localhost', 3000, 'Grafana', true),
    ('pf-db', 'c6', 'local', 5433, 'localhost', 5432, 'Orders database', false),
    ('pf-socks', 'c4', 'dynamic', 1080, '', 0, 'Browsing proxy', false),
    ('pf-plain', 'c0', 'local', 8080, '192.168.10.21', 80, null, false),
  ]) {
    await db.into(db.portForwardRules).insert(PortForwardRulesCompanion.insert(
          id: id,
          connectionId: conn,
          type: type,
          bindPort: bind,
          remoteHost: host,
          remotePort: port,
          label: Value(label),
          autoStart: Value(auto),
          createdAt: at,
        ));
  }
  for (final (id, label, command, category, confirm) in [
    ('s1', 'Disk usage', 'df -h', 'diagnostics', false),
    ('s2', 'Tail the app log', 'tail -f /var/log/app.log', 'diagnostics', false),
    ('s3', 'Restart a service', 'sudo systemctl restart {{service}}', 'deploy', true),
    ('s4', 'Pull and build', 'git pull && make build', 'deploy', false),
  ]) {
    await db.into(db.snippets).insert(SnippetsCompanion.insert(
          id: id,
          label: label,
          command: command,
          category: Value(category),
          confirmBeforeRun: Value(confirm),
          createdAt: at,
          updatedAt: at,
        ));
  }
  final networks = NetworkRepository(db.networksDao);
  await networks.ensureDefaultExists();
  await networks.create(const Network(
      id: 'n-office',
      name: 'Office',
      color: GroupColor.blue,
      icon: LucideIcons.building,
      triggers: [SsidTrigger('Office-WiFi')],
      isFallback: false));
  await networks.create(const Network(
      id: 'n-cell',
      name: 'Cellular',
      color: GroupColor.green,
      icon: LucideIcons.signal,
      triggers: [CellularTrigger()],
      isFallback: false));
  return db;
}

/// The plugins a phone's pages ask on the way (connectivity), answered.
void mockQuickWinsChannels() {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'), (call) async => null);
}

/// Lets the database and the frames finish.
Future<void> settleQuickWins(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// [home] as the phone app's first page at [size], over [quickWinsDb]
/// (signed in as Alex of the demo world, Squeezed and Juiced).
Future<({GlobalKey key, ProviderContainer container, AppDatabase db})> pumpQuickWins(
  WidgetTester tester,
  Widget home,
  Size size, {
  List<Override> extra = const [],
}) async {
  PackageInfo.setMockInitialValues(
      appName: 'ZestSSH', packageName: 'com.zestssh.app', version: '3.0.0', buildNumber: '300', buildSignature: '');
  FlutterSecureStorage.setMockInitialValues({});
  SharedPreferences.setMockInitialValues({'app_theme_id': 'graphite'});
  final prefs = await SharedPreferences.getInstance();
  final db = (await tester.runAsync(quickWinsDb))!;
  addTearDown(db.close);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final theme = BuiltInThemes.getById('graphite');
  AppColors.applyTheme(theme.colorScheme);
  final key = GlobalKey();
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    databaseProvider.overrideWithValue(db),
    treeDatabaseProvider.overrideWithValue(db),
    healthChecksEnabledProvider.overrideWith((ref) => false),
    connectionHealthProvider.overrideWith((ref) => QuickWinsHealth()),
    currentUserProvider.overrideWith(
        (_) => const UserProfile(uid: 'uid-alex', email: 'alex@example.com', displayName: 'Alex')),
    isCloudSyncProvider.overrideWith((ref) => _Juiced()),
    isProProvider.overrideWith((ref) => _Pro()),
    syncedAvatarUrlProvider.overrideWith((ref) => SyncedAvatarNotifier()),
    authStateProvider.overrideWith((_) => const Stream.empty()),
    appThemeIdProvider.overrideWith((ref) => 'graphite'),
    recordingModeProvider.overrideWith((ref) => false),
    syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 9, 24, 21))),
    ...extra,
  ]);
  addTearDown(container.dispose);
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, _) => home),
    GoRoute(path: '/:rest(.*)', builder: (_, state) => Scaffold(body: Text(state.uri.toString()))),
  ]);
  await tester.pumpWidget(RepaintBoundary(
    key: key,
    child: UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: theme.toThemeData(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  ));
  await settleQuickWins(tester);
  return (key: key, container: container, db: db);
}

/// Unmounts what [pumpQuickWins] put up and lets its timers run out.
Future<void> unpumpQuickWins(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(hours: 7));
}
