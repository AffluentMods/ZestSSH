import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connection_tags_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/features/networks/data/network_repository.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/profile_avatar_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/theme_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/account_attention.dart' show accountSetupNeedsAttentionProvider;
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

import '../visual/shots_util.dart';
import 'a11y_checks.dart' show mouseTapTargetGuideline;
export 'a11y_checks.dart' show mouseTapTargetGuideline;

/// What the accessibility guard of the Hosts area (4.0) checks each screen
/// against, and the made-up fleet it draws them with: every name and address
/// is invented.
///
/// The themes the brief names: Ember, Graphite and Daylight.
const a11yThemes = ['default_dark', 'graphite', 'default_light'];

/// Writes each screen's semantics tree to build/a11y/(name).txt when run with
/// --dart-define=ZEST_A11Y_DUMP=true (for reading what a screen reader hears).
const _dump = bool.fromEnvironment('ZEST_A11Y_DUMP');

const fleetHosts = [
  ['web-01', '192.168.10.21', 'deploy'],
  ['web-02', '192.168.10.22', 'deploy'],
  ['mac-studio', '192.168.10.30', 'ops'],
  ['build-runner', '192.168.10.50', 'ci'],
  ['hypervisor-b', '192.168.20.12', 'root'],
  ['hypervisor-a', '192.168.20.11', 'root'],
  ['edge-router', '192.168.20.1', 'root'],
  ['log-store', '192.168.10.24', 'deploy'],
  ['db-primary', '192.168.10.31', 'deploy'],
];

/// The fleet: nine hosts, three groups, a few tags.
Future<AppDatabase> fleetDatabase() async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final now = DateTime(2026, 9, 24);
  const groups = {
    'g_web': ('Web', 0xFF4FAE78, ['c0', 'c1']),
    'g_db': ('Databases', 0xFF7AA7E0, ['c8', 'c7']),
    'g_hv': ('Hypervisors', 0xFFA879E8, ['c4', 'c5']),
  };
  var order = 0;
  for (final g in groups.entries) {
    await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(
          id: g.key,
          name: g.value.$1,
          createdAt: now,
          sortOrder: Value(order++),
          colorValue: Value(g.value.$2),
        ));
  }
  String? groupOf(String id) {
    for (final g in groups.entries) {
      if (g.value.$3.contains(id)) return g.key;
    }
    return null;
  }

  for (var i = 0; i < fleetHosts.length; i++) {
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'c$i',
          label: fleetHosts[i][0],
          host: fleetHosts[i][1],
          port: const Value(22),
          groupId: Value(groupOf('c$i')),
          monitored: Value(const {0, 1, 7, 8}.contains(i)),
          lastConnected: Value(now.subtract(Duration(hours: i * 3))),
          sortOrder: Value(i),
          createdAt: now,
          updatedAt: now,
        ));
  }
  final tags = ConnectionTagsDao(db);
  await tags.setTagsForConnection('c0', ['prod', 'nginx']);
  await tags.setTagsForConnection('c8', ['postgres', 'prod']);
  return db;
}

/// The fleet with three forwarding rules and two networks of its own.
Future<AppDatabase> forwardsDatabase() async {
  final db = await fleetDatabase();
  final at = DateTime(2026, 10, 1);
  for (final (id, conn, type, bind, host, port, label, auto) in [
    ('pf-graf', 'c7', 'local', 3000, 'localhost', 3000, 'Grafana', true),
    ('pf-db', 'c8', 'local', 5433, 'localhost', 5432, 'Orders database', false),
    ('pf-socks', 'c6', 'dynamic', 1080, '', 0, 'Browsing proxy', false),
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
  final repo = NetworkRepository(db.networksDao);
  await repo.ensureDefaultExists();
  await repo.create(const Network(
      id: 'n-office',
      name: 'Office',
      color: GroupColor.blue,
      icon: LucideIcons.building,
      triggers: [SsidTrigger('Office-WiFi')],
      isFallback: false));
  await repo.create(const Network(
      id: 'n-cell',
      name: 'Cellular',
      color: GroupColor.green,
      icon: LucideIcons.signal,
      triggers: [CellularTrigger()],
      isFallback: false));
  return db;
}

/// A fixed Squeezed account, without RevenueCat or the backend.
class A11yPro extends StateNotifier<bool> implements ProStatusNotifier {
  A11yPro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Quiet stand-ins for the plugins these screens ask: a window that is not
/// maximized, a network that never changes.
void stubA11yPlugins() {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (call) async {
    switch (call.method) {
      case 'isMaximized':
      case 'isFullScreen':
      case 'isMinimized':
        return false;
      default:
        return null;
    }
  });
  messenger.setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
  messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
      MockStreamHandler.inline(onListen: (arguments, events) {}));
}

Future<void> a11ySettle(WidgetTester tester, {int rounds = 6}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// One screen in [themeId], at [size], with the real fonts (text is measured
/// as in the app, so a 200% text size is checked for real) and the fleet.
class A11yScreen {
  A11yScreen(this.container, this.db);
  final ProviderContainer container;
  final AppDatabase db;
}

Future<A11yScreen> pumpA11y(
  WidgetTester tester,
  Widget home, {
  String themeId = 'graphite',
  Size size = const Size(1440, 900),
  double textScale = 1,
  List<Override> overrides = const [],
  Map<String, Object> prefs = const {},
  AppDatabase? db,
  bool scaffold = true,
  GoRouter? router,
  bool touch = false,
}) async {
  // A phone's or a tablet's screens and sizes (the app reads the device's
  // kind, a computer under a test).
  debugTouchLayout = touch;
  addTearDown(() => debugTouchLayout = null);
  await tester.runAsync(loadShotFonts);
  stubA11yPlugins();
  final l10n = lookupAppLocalizations(const Locale('en'));
  L10nGlobal.update(l10n);
  SharedPreferences.setMockInitialValues({'app_theme_id': themeId, ...prefs});
  final sp = await SharedPreferences.getInstance();
  final database = db ?? (await tester.runAsync(fleetDatabase))!;
  addTearDown(() => tester.runAsync(database.close));
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final theme = BuiltInThemes.getById(themeId);
  AppColors.applyTheme(theme.colorScheme);
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(sp),
    databaseProvider.overrideWithValue(database),
    treeDatabaseProvider.overrideWithValue(database),
    healthChecksEnabledProvider.overrideWith((ref) => false),
    isProProvider.overrideWith((ref) => A11yPro(true)),
    currentUserProvider.overrideWith((_) => const UserProfile(uid: 'uid-alex', email: 'alex@example.com', displayName: 'Alex')),
    authStateProvider.overrideWith((_) => const Stream.empty()),
    syncedAvatarUrlProvider.overrideWith((ref) => SyncedAvatarNotifier()),
    appThemeIdProvider.overrideWith((ref) => themeId),
    recordingModeProvider.overrideWith((ref) => false),
    syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 9, 24, 21))),
    accountSetupNeedsAttentionProvider.overrideWith((_) async => false),
    ...overrides,
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: router != null
        ? MaterialApp.router(
            debugShowCheckedModeBanner: false,
            theme: theme.toThemeData(compact: !touch),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            routerConfig: router,
          )
        : MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme.toThemeData(compact: !touch),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: scaffold ? Scaffold(body: home) : home,
          ),
  ));
  await a11ySettle(tester);
  return A11yScreen(container, database);
}

Future<void> finishA11y(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(hours: 7));
}

/// Every failure of [guidelines] on what is on screen now, each as
/// "[name] reason". The tree is written out when asked for (see [_dump]).
Future<List<String>> a11yFailures(WidgetTester tester, String name, List<AccessibilityGuideline> guidelines) async {
  if (_dump) {
    final root = tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!;
    File('build/a11y/$name.txt')
      ..createSync(recursive: true)
      ..writeAsStringSync(root.toStringDeep(childOrder: DebugSemanticsDumpOrder.traversalOrder));
  }
  final out = <String>[];
  for (final g in guidelines) {
    final e = await g.evaluate(tester);
    if (!e.passed) out.add('[$name] ${g.description}: ${e.reason}');
  }
  return out;
}

/// The exceptions a pump left (overflows at a large text size among them).
List<String> takeAllExceptions(WidgetTester tester, String name) {
  final out = <String>[];
  Object? ex;
  while ((ex = tester.takeException()) != null) {
    out.add('[$name] ${ex.toString().split('\n').take(3).join(' ')}');
  }
  return out;
}

/// The guidelines for a computer (mouse) and for a touch screen.
const computerGuidelines = [mouseTapTargetGuideline, labeledTapTargetGuideline];
const touchGuidelines = [androidTapTargetGuideline, labeledTapTargetGuideline];

bool get onTouch => defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;
