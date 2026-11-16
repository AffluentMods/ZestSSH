import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/host_attention.dart' show monitoredHostViewsProvider;
import 'package:zestssh/features/monitoring/monitor_evaluation.dart';
import 'package:zestssh/features/monitoring/monitor_thresholds.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/profile_avatar_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/theme_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/services/account/device_approvals.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';
import 'package:zestssh/ui/screens/settings/settings_screen.dart';
import 'package:zestssh/ui/screens/settings/appearance_screen.dart';
import 'package:zestssh/ui/screens/settings/notification_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/terminal_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/sftp_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/automation_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/data_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/about_screen.dart';
import 'package:zestssh/ui/screens/settings/keyboard_row_screen.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/features/networks/pages/networks_mobile_page.dart';
import 'package:zestssh/ui/screens/triggers/triggers_screen.dart';
import 'package:zestssh/ui/screens/snippets/snippets_screen.dart';
import 'package:zestssh/ui/screens/command_history/command_history_screen.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/screens/profile/device_approval_dialogs.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

import '../helpers/fake_device_approvals_server.dart';

import 'shots_util.dart';

/// Screenshots of the phone app, drawn offscreen with the real fonts, for
/// checking the 3.0 UI without running the app against anyone's data. Off
/// unless asked for:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/phone_shots_test.dart
///
/// Pictures land in build/shots/ (phone-*.png), at twice the size of a
/// 390 x 844 phone screen.
const _shots = shotsEnabled;

/// Who the pictures are signed in as: Alex of the demo world.
const _demoAccount = UserProfile(uid: 'uid-alex', email: 'alex@example.com', displayName: 'Alex');

/// A fixed Juiced account (hosted Cloud), without RevenueCat or the backend.
class _Juiced extends StateNotifier<bool> implements CloudSyncStatusNotifier {
  _Juiced() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Squeezed as well (the Bundle), so no picture asks to upgrade.
class _Squeezed extends StateNotifier<bool> implements ProStatusNotifier {
  _Squeezed() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// web-01 open twice, nothing started (the Hosts tab's 4.0 picture).
class _TwoOnWeb01 extends ActiveSessionsNotifier {
  _TwoOnWeb01(super.ref) {
    state = {
      's1': const SessionState(status: SessionStatus.connected, connectionId: 'c0'),
      's2': const SessionState(status: SessionStatus.connected, connectionId: 'c0'),
    };
  }
}

const _hosts = [
  ['web-01', '192.168.10.21', 'deploy'],
  ['web-02', '192.168.10.22', 'deploy'],
  ['mac-studio', '192.168.10.30', 'ops'],
  ['hypervisor-b', '192.168.20.12', 'root'],
  ['edge-router', '192.168.20.1', 'root'],
  ['log-store', '192.168.10.24', 'deploy'],
  ['db-primary', '192.168.10.31', 'deploy'],
];

/// The scripts the app's fonts have no letters for (Hindi, Arabic, Chinese,
/// Japanese, Korean), from this computer's own fonts: a phone draws them
/// with its system's fonts, which a test has not, and the language list
/// showed boxes. Where a font is missing the shot goes on without it.
Future<void> _loadScriptFonts() async {
  const files = [
    'C:/Windows/Fonts/Nirmala.ttc',
    'C:/Windows/Fonts/arial.ttf',
    'C:/Windows/Fonts/msyh.ttc',
    'C:/Windows/Fonts/YuGothR.ttc',
    'C:/Windows/Fonts/malgun.ttf',
  ];
  for (final (i, path) in files.indexed) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final bytes = file.readAsBytesSync();
    final loader = FontLoader('ShotScript$i')..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load().timeout(const Duration(seconds: 30));
  }
}

Future<AppDatabase> _seeded() async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final now = DateTime(2026, 9, 24);
  for (var i = 0; i < _hosts.length; i++) {
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'c$i',
          label: _hosts[i][0],
          host: _hosts[i][1],
          colorValue: Value(i == 0 ? 0xFFFF7A1A : i == 1 ? 0xFF4F9D69 : null),
          port: const Value(22),
          createdAt: now,
          updatedAt: now,
        ));
  }
  return db;
}

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
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The phone app's home, [themeId], with the seeded hosts, [seed] adding to
  /// them and [prefsExtra] to what the app keeps.
  Future<(GlobalKey, ProviderContainer)> pumpPhone(WidgetTester tester, String themeId,
      {List<Override> extra = const [],
      Map<String, Object> prefsExtra = const {},
      Future<void> Function(AppDatabase db)? seed}) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    await tester.runAsync(_loadScriptFonts);
    // The version About shows, as a release's (the plugin has none in a test).
    PackageInfo.setMockInitialValues(
        appName: 'ZestSSH', packageName: 'com.zestssh.app', version: '3.0.0', buildNumber: '300', buildSignature: '');
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'app_theme_id': themeId, ...prefsExtra});
    final prefs = await SharedPreferences.getInstance();
    final db = await _seeded();
    if (seed != null) await tester.runAsync(() => seed(db));
    addTearDown(db.close);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = BuiltInThemes.getById(themeId);
    AppColors.applyTheme(theme.colorScheme);
    final key = GlobalKey();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      healthChecksEnabledProvider.overrideWith((ref) => false),
      // Signed in as Alex of the demo world (the website's), on Juiced:
      // a picture never shows a guest.
      currentUserProvider.overrideWith((_) => _demoAccount),
      isCloudSyncProvider.overrideWith((ref) => _Juiced()),
      isProProvider.overrideWith((ref) => _Squeezed()),
      // The demo account has no photo kept online: nothing is fetched.
      syncedAvatarUrlProvider.overrideWith((ref) => SyncedAvatarNotifier()),
      authStateProvider.overrideWith((_) => const Stream.empty()),
      appThemeIdProvider.overrideWith((ref) => themeId),
      recordingModeProvider.overrideWith((ref) => false),
      syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 9, 24, 21))),
      ...extra,
    ]);
    addTearDown(container.dispose);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
      GoRoute(path: Routes.settings, builder: (_, _) => Scaffold(appBar: AppBar(title: const Text('Settings')), body: const SettingsBody(bottomPadding: 16))),
      GoRoute(path: Routes.appearance, builder: (_, _) => const AppearanceScreen()),
      GoRoute(path: Routes.notificationSettings, builder: (_, _) => const NotificationSettingsScreen()),
      GoRoute(path: Routes.terminalSettings, builder: (_, _) => const TerminalSettingsScreen()),
      GoRoute(path: Routes.sftpSettings, builder: (_, _) => const SftpSettingsScreen()),
      GoRoute(path: Routes.automationSettings, builder: (_, _) => const AutomationSettingsScreen()),
      GoRoute(path: Routes.dataSettings, builder: (_, _) => const DataSettingsScreen()),
      GoRoute(path: Routes.about, builder: (_, _) => const AboutScreen()),
      GoRoute(path: Routes.keyboardRow, builder: (_, _) => const KeyboardRowScreen()),
      GoRoute(path: Routes.keys, builder: (_, _) => const KeysPhoneScreen()),
      GoRoute(path: Routes.profile, builder: (_, _) => const ProfileScreen()),
      GoRoute(path: '/shots/new-host', builder: (_, _) => const ConnectionEditScreen()),
      GoRoute(path: '/shots/edit-host', builder: (_, _) => const ConnectionEditScreen(connectionId: 'c0')),
      GoRoute(path: Routes.portForwards, builder: (_, _) => const PortForwardsPhoneScreen()),
      GoRoute(path: Routes.networks, builder: (_, _) => const NetworksMobileScreen()),
      GoRoute(path: Routes.triggers, builder: (_, _) => const TriggersScreen()),
      // As the app's own route draws it (lib/router/router.dart).
      GoRoute(path: Routes.snippets, builder: (_, _) => const SnippetsPhoneScreen()),
      GoRoute(path: Routes.commandHistory, builder: (_, _) => const CommandHistoryScreen()),
      GoRoute(path: '/:rest(.*)', builder: (_, state) => Scaffold(body: Text(state.uri.toString()))),
    ]);
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          // The scripts' fonts after the app's own (see _loadScriptFonts).
          theme: theme.toThemeData().copyWith(
              textTheme: theme.toThemeData().textTheme.apply(fontFamilyFallback: [for (var i = 0; i < 5; i++) 'ShotScript$i'])),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    ));
    await settle(tester);
    return (key, container);
  }

  Future<void> tearDownPhone(WidgetTester tester) async {
    plainShadows();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 7));
  }

  for (final themeId in ['graphite', 'default_light']) {
    testWidgets('phone, every tab, $themeId', (tester) async {
      final (key, _) = await pumpPhone(tester, themeId);
      await saveShot(tester, key, 'phone-start-$themeId', pixelRatio: 2);
      final bar = find.byKey(const ValueKey('phone-tab-bar'));
      for (var i = 0; i < 5; i++) {
        final tab = find.descendant(of: bar, matching: find.byKey(ValueKey('phone-tab-$i')));
        if (tab.evaluate().isEmpty) continue;
        await tester.tap(tab);
        await settle(tester);
        await saveShot(tester, key, 'phone-tab$i-$themeId', pixelRatio: 2);
      }
      await tearDownPhone(tester);
    }, skip: !_shots);

    // The Hosts tab as the 4.0 mockup draws it: the systems
    // seen on the hosts, web-01 open twice, db-primary's disk filling and
    // log-store's full; then the host's sheet from its more button, and the
    // sort's sheet (all made up).
    MonitorHostView disk(double used, MetricSeverity severity) => MonitorHostView(
          bucket: severity == MetricSeverity.critical ? MonitorBucket.critical : MonitorBucket.warning,
          metrics: [MetricEval(metric: MonitorMetric.disk, value: used, warn: 80, crit: 90, severity: severity)],
        );
    const seenSystems = {
      'os_kind_c0': 'ubuntu',
      'os_kind_c1': 'ubuntu',
      'os_kind_c2': 'macos',
      'os_kind_c3': 'debian',
      'os_kind_c4': 'openwrt',
      'os_kind_c5': 'rocky',
      'os_kind_c6': 'debian',
    };
    List<Override> openAndHealth() => [
          activeSessionsProvider.overrideWith(_TwoOnWeb01.new),
          monitoredHostViewsProvider.overrideWith((ref) => {
                'c6': disk(82, MetricSeverity.warning),
                'c5': disk(100, MetricSeverity.critical),
              }),
        ];

    testWidgets('phone Hosts, 4.0, $themeId', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final (key, _) = await pumpPhone(tester, themeId, prefsExtra: seenSystems, extra: openAndHealth());
      await settle(tester);
      await saveShot(tester, key, 'phone-hosts-$themeId', pixelRatio: 2);
      // The host's sheet, from db-primary's more button.
      await tester.tap(find.byKey(const ValueKey('phone-host-more-c6')));
      await settle(tester);
      await saveShot(tester, key, 'phone-hosts-more-$themeId', pixelRatio: 2);
      Navigator.of(tester.element(find.byKey(const ValueKey('zest-sheet')))).pop();
      await settle(tester);
      // The sort's sheet, from the first head.
      await tester.tap(find.byKey(const ValueKey('phone-hosts-sort')));
      await settle(tester);
      await saveShot(tester, key, 'phone-hosts-sort-$themeId', pixelRatio: 2);
      Navigator.of(tester.element(find.byKey(const ValueKey('phone-sort-sheet')))).pop();
      await settle(tester);
      await tearDownPhone(tester);
      debugDefaultTargetPlatformOverride = null;
    }, skip: !_shots);

    // The same hosts in groups: the chips with their counts, the sort on
    // the first group's head.
    testWidgets('phone Hosts in groups, 4.0, $themeId', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final (key, _) = await pumpPhone(
        tester,
        themeId,
        prefsExtra: seenSystems,
        extra: openAndHealth(),
        seed: (db) async {
          final now = DateTime(2026, 9, 24);
          for (final (id, name, order, color) in [
            ('g-web', 'Web', 0, 0xFF4FAE78),
            ('g-db', 'Databases', 1, 0xFF7AA7E0),
            ('g-hv', 'Hypervisors', 2, 0xFFA879E8),
          ]) {
            await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(
                  id: id,
                  name: name,
                  sortOrder: Value(order),
                  colorValue: Value(color),
                  createdAt: now,
                  updatedAt: Value(now),
                ));
          }
          for (final (host, group) in [('c0', 'g-web'), ('c1', 'g-web'), ('c6', 'g-db'), ('c3', 'g-hv')]) {
            await (db.update(db.connections)..where((t) => t.id.equals(host)))
                .write(ConnectionsCompanion(groupId: Value(group), colorValue: const Value(null)));
          }
        },
      );
      await settle(tester);
      await saveShot(tester, key, 'phone-hosts-groups-$themeId', pixelRatio: 2);
      await tearDownPhone(tester);
      debugDefaultTargetPlatformOverride = null;
    }, skip: !_shots);

    // Settings on a phone: the list of sections, then each section.
    testWidgets('phone settings, $themeId', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final (key, _) = await pumpPhone(tester, themeId);
      GoRouter.of(tester.element(find.byType(HomeScreen))).push(Routes.settings);
      await settle(tester);
      await saveShot(tester, key, 'phone-settings-root-$themeId', pixelRatio: 2);
      // The groups of 4.0: Account, App, Connections, Security and data, About.
      final rows = ['account', 'plan', 'language', 'appearance', 'keyboard', 'notifications', 'terminal', 'sftp', 'screens', 'security', 'data', 'about'];
      for (final row in rows) {
        final found = find.byKey(ValueKey('settings-$row'));
        await tester.scrollUntilVisible(found, 120, scrollable: find.byType(Scrollable).first);
        await tester.tap(found);
        await settle(tester);
        await saveShot(tester, key, 'phone-settings-$row-$themeId', pixelRatio: 2);
        final nav = GoRouter.of(tester.element(find.byType(HomeScreen, skipOffstage: false)));
        if (nav.canPop()) {
          nav.pop();
        } else {
          Navigator.of(tester.element(find.byType(Scaffold).last)).maybePop();
        }
        await settle(tester);
      }
      debugDefaultTargetPlatformOverride = null;
      await tearDownPhone(tester);
    }, skip: !_shots);

    // Settings' search, and the row of keys' own page with its keys.
    testWidgets('phone settings search and key row, $themeId', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final (key, container) = await pumpPhone(tester, themeId);
      final router = GoRouter.of(tester.element(find.byType(HomeScreen)));
      router.push(Routes.settings);
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('settings-search')), 'font');
      await settle(tester);
      await saveShot(tester, key, 'phone-settings-search-$themeId', pixelRatio: 2);
      router.pop();
      await settle(tester);
      // The two rows, as the phones and tablets guide shows the page (3.2.1).
      router.push(Routes.keyboardRow);
      await settle(tester);
      await saveShot(tester, key, 'phone-keys-row-two-rows-$themeId', pixelRatio: 2);
      router.pop();
      await settle(tester);
      await container.read(settingsUpdaterProvider).setSoftKeyboardScrollableMode(true);
      router.push(Routes.keyboardRow);
      await settle(tester);
      await saveShot(tester, key, 'phone-keys-row-$themeId', pixelRatio: 2);
      await tester.drag(find.byKey(const ValueKey('keys-row-page')), const Offset(0, -700));
      await settle(tester);
      await saveShot(tester, key, 'phone-keys-row-keys-$themeId', pixelRatio: 2);
      debugDefaultTargetPlatformOverride = null;
      await tearDownPhone(tester);
    }, skip: !_shots);

    // The pages the More tab opens.
    testWidgets('phone more pages, $themeId', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      // The protocols an Android phone offers (a test runs on a computer,
      // whose host form offers Mosh and Eternal Terminal as well).
      debugHostFormOnComputer = false;
      debugHostFormLocalShell = true;
      addTearDown(() {
        debugHostFormOnComputer = null;
        debugHostFormLocalShell = null;
      });
      final (key, _) = await pumpPhone(tester, themeId);
      final router = GoRouter.of(tester.element(find.byType(HomeScreen)));
      for (final (name, route) in [
        ('keys', Routes.keys),
        ('forwards', Routes.portForwards),
        ('networks', Routes.networks),
        ('triggers', Routes.triggers),
        ('history', Routes.commandHistory),
        ('account', Routes.profile),
        ('newhost', '/shots/new-host'),
        // Settings' Terminal page (opened from Appearance).
        ('terminal', Routes.terminalSettings),
      ]) {
        router.push(route);
        await settle(tester);
        await saveShot(tester, key, 'phone-more-$name-$themeId', pixelRatio: 2);
        router.pop();
        await settle(tester);
      }
      // Snippets, in More since 3.1, opened as a person does (the Snippets
      // guide's picture).
      await tester.tap(find.descendant(
          of: find.byKey(const ValueKey('phone-tab-bar')), matching: find.byKey(const ValueKey('phone-tab-4'))));
      await settle(tester);
      await tester.tap(find.text('Snippets').first);
      await settle(tester);
      await saveShot(tester, key, 'phone-more-snippets-$themeId', pixelRatio: 2);
      debugDefaultTargetPlatformOverride = null;
      await tearDownPhone(tester);
    }, skip: !_shots);

    // The phone's host form (4.0): a saved
    // host's, signed in to with a key; its More options open; and Test's
    // two tests.
    testWidgets('phone host form, $themeId', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      debugHostFormOnComputer = false;
      debugHostFormLocalShell = true;
      addTearDown(() {
        debugHostFormOnComputer = null;
        debugHostFormLocalShell = null;
      });
      final (key, container) = await pumpPhone(tester, themeId);
      // In the test's own zone, as the database was made (awaited in a real
      // one, its work waits on this zone and never ends).
      final db = container.read(databaseProvider);
      await db.into(db.identities).insert(IdentitiesCompanion.insert(
            id: 'k-deploy',
            label: 'deploy-key',
            username: 'deploy',
            authMethod: 'publicKey',
            keyType: const Value('ed25519'),
            createdAt: DateTime(2026, 9, 24),
          ));
      await (db.update(db.connections)..where((c) => c.id.equals('c0'))).write(const ConnectionsCompanion(
            identityId: Value('k-deploy'),
            note: Value('Behind the office VPN.'),
          ));
      final router = GoRouter.of(tester.element(find.byType(HomeScreen)));
      router.push('/shots/edit-host');
      await settle(tester);
      await saveShot(tester, key, 'phone-host-form-edit-$themeId', pixelRatio: 2);
      // A note is set: More options is open with the form.
      await tester.drag(find.byKey(const ValueKey('host-form-phone')), const Offset(0, -500));
      await settle(tester);
      await saveShot(tester, key, 'phone-host-form-more-$themeId', pixelRatio: 2);
      await tester.tap(find.byKey(const ValueKey('host-form-test')));
      await settle(tester);
      await saveShot(tester, key, 'phone-host-form-test-$themeId', pixelRatio: 2);
      debugDefaultTargetPlatformOverride = null;
      await tearDownPhone(tester);
    }, skip: !_shots);

    // Dialogs as sheets on a phone (3.0).
    testWidgets('phone sheets, $themeId', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final server = FakeApprovalServer();
      final (key, _) = await pumpPhone(tester, themeId, extra: [
        deviceApprovalsApiProvider.overrideWithValue(server.device('desktop')),
      ]);
      await tester.runAsync(() => ApprovalAsk.start(server.device('phone'), name: 'Pixel'));
      final context = tester.element(find.byType(HomeScreen));
      unawaited(showApproveNewDevice(context));
      await settle(tester);
      await saveShot(tester, key, 'phone-sheet-approve-$themeId', pixelRatio: 2);
      Navigator.of(tester.element(find.byKey(const ValueKey('zest-sheet')))).pop();
      await settle(tester);
      unawaited(ZestConfirmDialog.show(
        context,
        tone: ZestDialogTone.destructive,
        title: 'Delete “web-01”?',
        body: 'It is removed from every device you sync. Sessions open to it stay open.',
        confirmLabel: 'Delete',
      ));
      await settle(tester);
      await saveShot(tester, key, 'phone-sheet-confirm-$themeId', pixelRatio: 2);
      Navigator.of(tester.element(find.byKey(const ValueKey('zest-sheet')))).pop();
      await settle(tester);
      debugDefaultTargetPlatformOverride = null;
      await tearDownPhone(tester);
    }, skip: !_shots);
  }
}
