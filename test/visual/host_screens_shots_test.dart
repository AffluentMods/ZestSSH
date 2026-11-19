import 'dart:io';

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
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/features/hosts/state/hosts_page_prefs.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/screens/desktop/widgets/inspector_panel.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';

import 'shots_util.dart';

/// Pictures of a host's own screens (4.0) at their real sizes, with the
/// app's fonts, made-up hosts only: the Hosts page's cards and list with
/// the monitor beside a host that has a screen, the host's panel, its menu,
/// the VNC or RDP choice, the Inspector, the host editor's line under
/// Protocol, and a phone's list and sheet. Off unless asked for:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/host_screens_shots_test.dart
///
/// Pictures land in build/shots/host-screens/.
const _dir = 'host-screens';

const _osKinds = {
  'os_kind_h-web': 'ubuntu',
  'os_kind_h-win': 'windows',
  'os_kind_h-gpu': 'debian',
  'os_kind_h-mac': 'macos',
  'os_kind_h-db': 'debian',
};

class _Shell extends ShellService {
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<Uint8List> get stdout => const Stream.empty();
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  void write(Uint8List data) {}
  @override
  void resize(int width, int height) {}
  @override
  bool get isConnected => true;
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  bool get exitedCleanly => false;
}

Future<AppDatabase> _seeded() async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final at = DateTime(2026, 11, 9);
  await db.into(db.identities).insert(IdentitiesCompanion.insert(
      id: 'i-ops', label: 'ops key', username: 'ops', authMethod: 'publicKey', createdAt: at));
  var order = 0;
  Future<void> add(String id, String label, String protocol, String host, int port, {String? via}) =>
      db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: label,
            host: host,
            port: Value(port),
            protocol: Value(protocol),
            connectViaId: Value(via),
            identityId: Value(protocol == 'ssh' ? 'i-ops' : null),
            sortOrder: Value(order++),
            createdAt: at,
            updatedAt: at,
          ));
  await add('h-web', 'web-01', 'ssh', '192.168.10.21', 22);
  await add('h-win', 'win-build', 'ssh', '192.168.10.40', 22);
  await add('h-gpu', 'gpu-box', 'ssh', '192.168.10.50', 22);
  await add('h-mac', 'mac-studio', 'ssh', '192.168.10.30', 22);
  await add('h-db', 'db-primary', 'ssh', '192.168.10.31', 22);
  await add('s-web', 'web-01 VNC', 'vnc', 'localhost', 5900, via: 'h-web');
  await add('s-win', 'win-build RDP', 'rdp', '192.168.10.40', 3389, via: 'h-win');
  await add('s-gpu', 'gpu-box VNC', 'vnc', 'localhost', 5900, via: 'h-gpu');
  await add('s-gpu2', 'gpu-box monitor 2', 'vnc', 'localhost', 5901, via: 'h-gpu');
  await add('s-mac', 'mac-studio VNC', 'vnc', 'localhost', 5900, via: 'h-mac');
  return db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  final graphite = BuiltInThemes.getById('graphite');

  setUpAll(() async {
    if (shotsEnabled) await loadShotFonts();
  });

  setUp(() {
    L10nGlobal.update(en);
    AppColors.applyTheme(graphite.colorScheme);
    ConnectionEditScreen.debugDesktopShell = true;
  });
  tearDown(() {
    ConnectionEditScreen.debugDesktopShell = null;
    debugHostFormOnComputer = null;
  });

  void stubPlugins() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}));
  }

  Future<void> settle(WidgetTester tester, {int rounds = 6}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> snap(WidgetTester tester, GlobalKey key, String name) =>
      saveShot(tester, key, '$_dir/$name', pixelRatio: 1.5);

  Future<void> finish(WidgetTester tester) async {
    plainShadows();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  /// [home] in the app's theme, at [size], with the made-up hosts.
  Future<(GlobalKey, ProviderContainer)> pump(WidgetTester tester, Widget Function() home,
      {Size size = const Size(1440, 900), Map<String, Object> prefsExtra = const {}}) async {
    stubPlugins();
    realShadows();
    SharedPreferences.setMockInitialValues({'app_theme_id': 'graphite', ..._osKinds, ...prefsExtra});
    final prefs = await SharedPreferences.getInstance();
    late AppDatabase db;
    await tester.runAsync(() async => db = await _seeded());
    addTearDown(db.close);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      healthChecksEnabledProvider.overrideWith((ref) => false),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: graphite.toThemeData(),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: home()),
        ),
      ),
    ));
    await settle(tester);
    return (key, c);
  }

  Finder key(String k) => find.byKey(ValueKey(k));

  testWidgets('computer: the Hosts grid, the monitor on cards with a screen; gpu-box\'s panel with two screens',
      (tester) async {
    if (!shotsEnabled) return;
    final (k, _) = await pump(tester, () => HostsHomePage(onConnectTo: (_) {}, onOpenSftp: (_) {}));
    await snap(tester, k, 'desktop-grid');
    await tester.tap(find.text('gpu-box').first);
    await settle(tester);
    await snap(tester, k, 'desktop-grid-panel-two-screens');
    // Its monitor's menu.
    await tester.tap(key('host-screen-button-h-gpu'));
    await settle(tester);
    await snap(tester, k, 'desktop-card-screens-menu');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    // A host with none: Add a screen, then the choice.
    await tester.tap(find.text('db-primary').first);
    await settle(tester);
    await snap(tester, k, 'desktop-panel-none');
    await tester.tap(key('host-screens-add-h-db'));
    await settle(tester);
    await snap(tester, k, 'add-a-screen-choice');
    await finish(tester);
  });

  testWidgets('computer: the compact grid, and the list', (tester) async {
    if (!shotsEnabled) return;
    var (k, _) = await pump(tester, () => HostsHomePage(onConnectTo: (_) {}, onOpenSftp: (_) {}),
        prefsExtra: {HostsPagePrefs.viewKey: 'compact'});
    await snap(tester, k, 'desktop-grid-compact');
    await finish(tester);
    (k, _) = await pump(tester, () => HostsHomePage(onConnectTo: (_) {}, onOpenSftp: (_) {}),
        prefsExtra: {HostsPagePrefs.viewKey: 'list'});
    await snap(tester, k, 'desktop-list');
    await finish(tester);
  });

  testWidgets("computer: web-01's menu, Open screen beside SFTP", (tester) async {
    if (!shotsEnabled) return;
    final (k, _) = await pump(tester, () => HostsHomePage(onConnectTo: (_) {}, onOpenSftp: (_) {}));
    await tester.tap(find.text('web-01').first, buttons: kSecondaryButton);
    await settle(tester);
    await snap(tester, k, 'desktop-menu');
    await finish(tester);
  });

  testWidgets("computer: a session's Inspector, Tools, with the host's screen", (tester) async {
    if (!shotsEnabled) return;
    final state = SessionState(
      status: SessionStatus.connected,
      connectionId: 'h-web',
      connectionLabel: 'web-01',
      host: '192.168.10.21',
      port: 22,
      username: 'ops',
      session: TerminalSession(
          id: 'ssh-1', connectionId: 'h-web', terminal: Terminal(), shell: _Shell(), startedAt: DateTime(2026, 11, 9)),
    );
    final (k, _) = await pump(
        tester,
        () => Align(
            alignment: Alignment.centerRight,
            child: InspectorPanel(sessionId: 'ssh-1', sessionState: state, onClose: () {})),
        size: const Size(700, 900));
    await tester.scrollUntilVisible(key('host-screen-open-s-web'), 200, scrollable: find.byType(Scrollable).last);
    await settle(tester);
    await snap(tester, k, 'inspector-tools');
    await finish(tester);
  });

  testWidgets('computer: the editor of a saved SSH host, the line under Protocol', (tester) async {
    if (!shotsEnabled) return;
    debugHostFormOnComputer = true;
    final (k, _) = await pump(
        tester, () => ConnectionEditScreen(connectionId: 'h-db', inDialog: true, onClose: () {}),
        size: const Size(900, 900));
    await snap(tester, k, 'editor-add-screen-line');
    await finish(tester);
  });

  testWidgets("phone: the Hosts list with the monitor; a host's sheet with Screen", (tester) async {
    if (!shotsEnabled) return;
    stubPlugins();
    realShadows();
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'app_theme_id': 'graphite', ..._osKinds});
    final prefs = await SharedPreferences.getInstance();
    late AppDatabase db;
    await tester.runAsync(() async => db = await _seeded());
    addTearDown(db.close);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final k = GlobalKey();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      healthChecksEnabledProvider.overrideWith((ref) => false),
      currentUserProvider.overrideWith((_) => null),
      authStateProvider.overrideWith((_) => const Stream.empty()),
      recordingModeProvider.overrideWith((ref) => false),
      syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 11, 9, 12))),
    ]);
    addTearDown(c.dispose);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
      GoRoute(path: '/:rest(.*)', builder: (_, state) => Scaffold(body: Text('route ${state.uri.path}'))),
    ]);
    await tester.pumpWidget(RepaintBoundary(
      key: k,
      child: UncontrolledProviderScope(
        container: c,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: graphite.toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          routerConfig: router,
        ),
      ),
    ));
    await settle(tester);
    await snap(tester, k, 'phone-list');
    await tester.tap(find.text('gpu-box').first, buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    await snap(tester, k, 'phone-sheet');
    await finish(tester);
  });

  tearDownAll(() {
    if (!shotsEnabled) return;
    // Where the pictures are, for a reader of the test's output.
    stdout.writeln('host screens pictures: ${Directory('build/shots/$_dir').absolute.path}');
  });
}
