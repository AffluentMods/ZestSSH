import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart' show CrateSwitches;
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/redaction_providers.dart' show redactionFleetRegistrar;
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_view.dart';
import 'package:zestssh/ui/screens/desktop/widgets/port_forward_list_view.dart';
import 'package:zestssh/ui/screens/desktop/widgets/snippets_library_view.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';
import 'package:zestssh/ui/screens/snippets/snippets_screen.dart';
import 'package:zestssh/utils/redactor.dart';

import 'shots_util.dart';

/// Pictures of selecting keys, snippets and port forwards (3.4), as the hosts
/// are selected: on a computer, Select on the page's line, a box on each row
/// and the selection's bar at the list's foot; on a phone, a long press, the
/// top bar's count and Select all shown, the tab bar as the selection's
/// actions. Dark theme (Graphite), made-up data only:
///
///   flutter test --dart-define=ZEST_SHOTS=true --dart-define=ZEST_ORCHARDS=true test/visual/select_more_shots_test.dart
///
/// Pictures land in build/shots/.
class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A made-up team with a vault this account may add to: where Move to... and
/// Copy to... take the selected items.
const _team = OrchardSummary(
  id: '0c2f8a6e-5b1d-4d3a-9f47-2a61c0e9b7d3',
  name: 'Platform team',
  role: 'owner',
  defaultCrateId: '2e4a0c8a-7d3f-4f5c-9a69-4c83e2a1d9f5',
  crates: [
    CrateSummary(
        id: '2e4a0c8a-7d3f-4f5c-9a69-4c83e2a1d9f5', name: 'Production', level: 'manage', switches: CrateSwitches.all),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'), (call) async => null);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// A made-up team's keys, snippets and port forwards.
  Future<AppDatabase> seeded() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final at = DateTime(2026, 10, 28);
    for (final (id, label, user, method, type) in const [
      ('k-ci', 'deploy-ci', 'deploy', 'publicKey', 'ssh-ed25519'),
      ('k-ops', 'ops laptop', 'ops', 'publicKey', 'ssh-ed25519'),
      ('k-backup', 'backup server', 'backup', 'publicKey', 'ecdsa-sha2-nistp256'),
      ('k-legacy', 'legacy box', 'root', 'publicKey', 'ssh-rsa'),
      ('k-grafana', 'grafana admin', 'admin', 'password', null),
      ('k-staging', 'staging root', 'root', 'password', null),
    ]) {
      await db.into(db.identities).insert(IdentitiesCompanion.insert(
          id: id, label: label, username: user, authMethod: method, keyType: Value(type), createdAt: at));
    }
    for (final (id, label, command, category) in const [
      ('s-ps', 'Running containers', 'docker ps', 'Docker'),
      ('s-logs', 'Container logs', r'docker logs ${CONTAINER:-web} --tail 50', 'Docker'),
      ('s-prune', 'Prune unused', 'docker system prune -f', 'Docker'),
      ('s-df', 'Disk usage', 'df -h', 'System'),
      ('s-free', 'Free memory', 'free -m', 'System'),
      ('s-top', 'Top processes', 'ps aux --sort=-%cpu | head', 'System'),
      ('s-ports', 'Open ports', 'ss -tulpn', 'Network'),
    ]) {
      await db.into(db.snippets).insert(SnippetsCompanion.insert(
          id: id, label: label, command: command, category: Value(category), createdAt: at, updatedAt: at));
    }
    for (final (id, label, address, key) in const [
      ('h-mon', 'monitoring', '192.168.10.60', 'k-ops'),
      ('h-web', 'web-01', '192.168.10.21', 'k-ci'),
      ('h-db', 'db-primary', '192.168.10.31', 'k-ops'),
    ]) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id, label: label, host: address, identityId: Value(key), createdAt: at, updatedAt: at));
    }
    for (final (id, host, type, port, label) in const [
      ('f-grafana', 'h-mon', 'local', 3000, 'Grafana'),
      ('f-prom', 'h-mon', 'local', 9090, 'Prometheus'),
      ('f-pg', 'h-db', 'local', 5432, 'Postgres'),
      ('f-redis', 'h-db', 'local', 6379, 'Redis'),
      ('f-socks', 'h-web', 'dynamic', 1080, 'Browsing proxy'),
    ]) {
      await db.into(db.portForwardRules).insert(PortForwardRulesCompanion.insert(
          id: id,
          connectionId: host,
          type: type,
          bindPort: port,
          remoteHost: type == 'dynamic' ? '' : 'localhost',
          remotePort: type == 'dynamic' ? 0 : port,
          label: Value(label),
          createdAt: at));
    }
    return db;
  }

  Future<(GlobalKey, ProviderContainer)> pumpDesktop(WidgetTester tester, Widget page) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'app_theme_id': 'graphite'});
    final prefs = await SharedPreferences.getInstance();
    final db = (await tester.runAsync(seeded))!;
    addTearDown(db.close);
    tester.view.physicalSize = const Size(1440, 900);
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
      isProProvider.overrideWith((ref) => _Pro()),
      syncIsActiveProvider.overrideWith((ref) async => true),
      recordingModeProvider.overrideWith((ref) => false),
      recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      redactionFleetRegistrar.overrideWith((ref) {}),
      activeForwardIdsProvider.overrideWith((ref) => {'f-grafana', 'f-pg'}),
      orchardSummariesProvider.overrideWith((ref) async => const [_team]),
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
          home: Scaffold(body: page),
        ),
      ),
    ));
    await settle(tester);
    return (key, container);
  }

  Future<(GlobalKey, ProviderContainer)> pumpPhone(WidgetTester tester, Widget home) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'app_theme_id': 'graphite'});
    final prefs = await SharedPreferences.getInstance();
    final db = (await tester.runAsync(seeded))!;
    addTearDown(db.close);
    tester.view.physicalSize = const Size(412, 900);
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
      currentUserProvider.overrideWith((_) => null),
      authStateProvider.overrideWith((_) => const Stream.empty()),
      recordingModeProvider.overrideWith((ref) => false),
      isProProvider.overrideWith((ref) => _Pro()),
      syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 28, 12))),
      activeForwardIdsProvider.overrideWith((ref) => {'f-grafana', 'f-pg'}),
      orchardSummariesProvider.overrideWith((ref) async => const [_team]),
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
          locale: const Locale('en'),
          routerConfig: router,
        ),
      ),
    ));
    await settle(tester);
    return (key, container);
  }

  Future<void> done(WidgetTester tester) async {
    plainShadows();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  Future<void> click(WidgetTester tester, Finder f) async {
    await tester.tap(f, kind: PointerDeviceKind.mouse);
    await settle(tester);
  }

  testWidgets('computer: keys selected', (tester) async {
    final (key, _) = await pumpDesktop(tester, const KeysView());
    await click(tester, find.byKey(const ValueKey('keys-select')));
    for (final id in ['k-ci', 'k-backup', 'k-legacy']) {
      await click(tester, find.byKey(ValueKey('key-row-menu-$id')));
    }
    await saveShot(tester, key, 'select_more_1_keys_desktop');
    await done(tester);
  }, skip: !shotsEnabled);

  testWidgets('computer: snippets selected, and Move to category', (tester) async {
    final (key, _) = await pumpDesktop(tester, const SnippetsLibraryView());
    await click(tester, find.byKey(const ValueKey('snippets-select')));
    for (final id in ['s-ps', 's-prune', 's-df']) {
      await click(tester, find.byKey(ValueKey('snippet-row-$id')));
    }
    await saveShot(tester, key, 'select_more_2_snippets_desktop');
    await click(tester, find.byKey(const ValueKey('bulk-category')));
    await saveShot(tester, key, 'select_more_3_snippets_category');
    await tester.tap(find.byKey(const ValueKey('zest-dialog-secondary')));
    await settle(tester);
    await done(tester);
  }, skip: !shotsEnabled);

  testWidgets('computer: port forwards selected, and Start\'s one question', (tester) async {
    final (key, _) = await pumpDesktop(tester, const PortForwardListView());
    await click(tester, find.byKey(const ValueKey('forwards-select')));
    for (final id in ['f-prom', 'f-redis', 'f-socks', 'f-grafana']) {
      await click(tester, find.byKey(ValueKey('pf-rule-$id')));
    }
    await saveShot(tester, key, 'select_more_4_forwards_desktop');
    await click(tester, find.byKey(const ValueKey('bulk-start')));
    await saveShot(tester, key, 'select_more_5_forwards_start');
    await tester.tap(find.byKey(const ValueKey('zest-dialog-secondary')));
    await settle(tester);
    await done(tester);
  }, skip: !shotsEnabled);

  testWidgets('phone: keys selected on the Manage tab', (tester) async {
    final (key, _) = await pumpPhone(tester, const HomeScreen());
    await tester.tap(find.byKey(const ValueKey('phone-tab-2')));
    await settle(tester);
    await tester.longPress(find.text('deploy-ci'));
    await settle(tester);
    await tester.tap(find.text('backup server'));
    await tester.tap(find.text('legacy box'));
    await settle(tester);
    await saveShot(tester, key, 'select_more_6_keys_phone');
    await done(tester);
  }, skip: !shotsEnabled);

  testWidgets('phone: port forwards selected on the Manage tab', (tester) async {
    final (key, _) = await pumpPhone(tester, const HomeScreen());
    await tester.tap(find.byKey(const ValueKey('phone-tab-2')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('manage-port-forwards')));
    await settle(tester);
    await tester.longPress(find.text('Prometheus'));
    await settle(tester);
    await tester.tap(find.text('Redis'));
    await settle(tester);
    await saveShot(tester, key, 'select_more_7_forwards_phone');
    await done(tester);
  }, skip: !shotsEnabled);

  testWidgets('phone: snippets selected, the search narrowing Select all shown', (tester) async {
    final (key, _) = await pumpPhone(tester, const SnippetsPhoneScreen());
    await tester.longPress(find.text('Running containers'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).first, 'disk');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('phone-selection-all')));
    await settle(tester);
    await saveShot(tester, key, 'select_more_8_snippets_phone');
    await done(tester);
  }, skip: !shotsEnabled);
}
