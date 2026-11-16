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
import 'package:zestssh/features/hosts/open_many_hosts.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/features/hosts/state/host_multi_select.dart';
import 'package:zestssh/features/hosts/state/kex_refused_hosts.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';

import 'shots_util.dart';

/// Pictures of selecting hosts and editing them together (3.4, against the
/// design mockups):
/// the page's selection bar, the editor at the
/// right, "Open 16 sessions?", and a phone's select with search and its
/// editor's sheet. Made-up hosts only:
///
///   flutter test --dart-define=ZEST_SHOTS=true --dart-define=ZEST_ORCHARDS=true test/visual/bulk_select_shots_test.dart
///
/// Pictures land in build/shots/.
class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
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

  /// A made-up fleet imported from SecureCRT: old CentOS and RHEL machines.
  Future<AppDatabase> seeded() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final at = DateTime(2026, 10, 28);
    await db.into(db.connectionGroups).insert(
        ConnectionGroupsCompanion.insert(id: 'g-crt', name: 'Imported from SecureCRT', createdAt: at));
    for (final (id, user) in [('k-root', 'root'), ('k-admin', 'admin'), ('k-ops', 'ops')]) {
      await db.into(db.identities).insert(IdentitiesCompanion.insert(
          id: id, label: '$user key', username: user, authMethod: 'publicKey', createdAt: at));
    }
    var i = 0;
    for (final kind in ['db', 'app', 'web', 'pay']) {
      for (var n = 1; n <= 4; n++) {
        i++;
        final id = 'legacy-$kind-0$n';
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: id,
              label: id,
              host: '10.20.${4 + i ~/ 4}.${10 + i}',
              groupId: const Value('g-crt'),
              identityId: Value(i % 3 == 0 ? 'k-admin' : (i % 5 == 0 ? 'k-ops' : 'k-root')),
              sortOrder: Value(i),
              createdAt: at,
              updatedAt: at,
            ));
      }
    }
    return db;
  }

  Future<(GlobalKey, ProviderContainer)> pumpDesktop(WidgetTester tester) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
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
    ]);
    addTearDown(container.dispose);
    for (final id in ['legacy-db-01', 'legacy-db-02', 'legacy-app-02']) {
      container.read(kexRefusedHostsProvider.notifier).refused(id);
    }
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
          home: Scaffold(body: HostsHomePage(onConnectTo: (_) {})),
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

  testWidgets('desktop: the selection bar, the editor, and "Open 16 sessions?"', (tester) async {
    final (key, container) = await pumpDesktop(tester);
    await tester.tap(find.byKey(const ValueKey('hosts-select')), kind: PointerDeviceKind.mouse);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('host-selection-all')), kind: PointerDeviceKind.mouse);
    await settle(tester);
    await saveShot(tester, key, 'bulk_1_selection_bar');

    await tester.tap(find.byKey(const ValueKey('bulk-edit')), kind: PointerDeviceKind.mouse);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('bulk-compat-needing')), kind: PointerDeviceKind.mouse);
    await settle(tester);
    await saveShot(tester, key, 'bulk_2_edit_panel');
    await tester.tap(find.byKey(const ValueKey('bulk-edit-close')), kind: PointerDeviceKind.mouse);
    await settle(tester);

    final hosts = (await tester.runAsync(() => container.read(connectionsWithDetailsProvider.future)))!;
    final context = tester.element(find.byType(HostsHomePage));
    // ignore: discarded_futures
    askOpenMany(context, hosts.length);
    await settle(tester);
    await saveShot(tester, key, 'bulk_3_open_many');
    expect(find.text(l10n.bulkOpenTitle(16)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('zest-dialog-secondary')));
    await settle(tester);
    container.read(hostMultiSelectProvider.notifier).exit();
    await done(tester);
  }, skip: !shotsEnabled);

  testWidgets('phone: select with search, and the editor\'s sheet', (tester) async {
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
    ]);
    addTearDown(container.dispose);
    for (final id in ['legacy-db-01', 'legacy-db-02', 'legacy-app-01']) {
      container.read(kexRefusedHostsProvider.notifier).refused(id);
    }
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
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
    await tester.longPress(find.text('legacy-app-01'));
    await settle(tester);
    container.read(connectionSearchQueryProvider.notifier).state = 'db';
    await settle(tester);
    await tester.tap(find.text('legacy-db-01'));
    await tester.tap(find.text('legacy-db-02'));
    await settle(tester);
    await saveShot(tester, key, 'bulk_4_phone_select');

    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('phone-selection-actions')), matching: find.byKey(const ValueKey('phone-tab-0'))));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('bulk-compat-switch')));
    await settle(tester);
    await saveShot(tester, key, 'bulk_5_phone_edit_sheet');
    await done(tester);
  }, skip: !shotsEnabled);
}
