import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/host_screens.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/features/hosts/state/hosts_page_prefs.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart' show CrateSwitches;
import 'package:zestssh/features/orchards/spaces.dart' show OrchardSpace, Space;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart' show ConnectionProtocol;
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/screens/desktop/widgets/inspector_panel.dart';

/// A host's own screens (4.0): the screen hosts reached through an SSH host
/// are that host's, and are opened and added wherever the host is: its card
/// and row (a monitor beside it), its panel (a Screens section and a monitor
/// at its foot), its menu (Open screen beside SFTP, Add a screen in Tools),
/// and the Inspector of a session to it. Connect still opens SSH.

final _at = DateTime(2026, 10, 22);

ConnectionWithDetails _host(String id, String label,
        {String protocol = 'ssh', String host = '10.0.0.9', int port = 22, String? via}) =>
    ConnectionWithDetails(
      connection: Connection(
        id: id,
        label: label,
        host: host,
        port: port,
        protocol: protocol,
        connectViaId: via,
        createdAt: _at,
        updatedAt: _at,
        sortOrder: 0,
        colorIndex: 0,
        pinned: false,
        monitored: false,
        compatibilityMode: false,
        zlibCompression: false,
        keepAliveSeconds: 0,
        envVars: '',
        forwardAgent: false,
        sizeTier: 0,
      ),
    );

/// The sessions the Inspector starts, noted instead of opened.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  final started = <String>[];

  @override
  String? startSession(
    Connection connection, {
    bool allowDuplicate = false,
    String? usernameOverride,
    String? initialCommand,
    String? asAccount,
    bool unattended = false,
    Space? space,
  }) {
    started.add(connection.id);
    return 's-${connection.id}';
  }
}

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

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  group('hostScreensByHost', () {
    test("a host's screens are the screen hosts reached through it, by name; not another host's, not a jump host's "
        'hop, not through a host that carries no screen', () {
      final all = [
        _host('h1', 'web-01'),
        _host('h2', 'db-01'),
        _host('t1', 'old-box', protocol: 'telnet'),
        _host('s1', 'web-01 desktop', protocol: 'vnc', host: 'localhost', port: 5900, via: 'h1'),
        _host('s2', 'Alpha', protocol: 'rdp', host: '10.0.0.1', port: 3389, via: 'h1'),
        _host('s3', 'db console', protocol: 'vnc', host: 'localhost', port: 5901, via: 'h2'),
        _host('s4', 'telnet screen', protocol: 'vnc', host: 'localhost', port: 5900, via: 't1'),
        _host('s5', 'gone carrier', protocol: 'vnc', host: 'localhost', port: 5900, via: 'nobody'),
        _host('s6', 'direct', protocol: 'vnc', host: '10.0.0.7', port: 5900),
        _host('j1', 'behind db', via: 'h2'),
      ];
      final by = hostScreensByHost(all);
      expect([for (final s in by['h1']!) s.connection.id], ['s2', 's1']);
      expect([for (final s in by['h2']!) s.connection.id], ['s3']);
      expect(by.containsKey('t1'), isFalse);
      expect(by.containsKey('nobody'), isFalse);
      expect(by.keys.toSet(), {'h1', 'h2'});
    });
  });

  group('the Hosts page', () {
    late AppDatabase db;
    late ProviderContainer container;
    late List<String> opened;

    setUp(() => ConnectionEditScreen.debugDesktopShell = true);
    tearDown(() => ConnectionEditScreen.debugDesktopShell = null);

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 120));
      }
    }

    /// web-01 (h1) with its VNC screen, and with [two] an RDP one too; db-01
    /// (h2) with none. With [team] a team's space where new hosts go to a
    /// vault whose role only connects ([mayAdd] false) or may add.
    Future<void> pump(WidgetTester tester,
        {bool two = false, bool team = false, bool mayAdd = true, bool list = false}) async {
      opened = [];
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
      messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
          MockStreamHandler.inline(onListen: (arguments, events) {}));
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({if (list) HostsPagePrefs.viewKey: 'list'});
      final prefs = await SharedPreferences.getInstance();
      db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      Future<void> add(String id, String label, String protocol, String host, int port, {String? via, int order = 0}) =>
          db.into(db.connections).insert(ConnectionsCompanion.insert(
                id: id,
                label: label,
                host: host,
                port: Value(port),
                protocol: Value(protocol),
                connectViaId: Value(via),
                sortOrder: Value(order),
                createdAt: _at,
                updatedAt: _at,
              ));
      await add('h1', 'web-01', 'ssh', '10.0.0.1', 22, order: 1);
      await add('h2', 'db-01', 'ssh', '10.0.0.2', 22, order: 2);
      await add('s1', 'web-01 desktop', 'vnc', 'localhost', 5900, via: 'h1', order: 3);
      if (two) await add('s2', 'Alpha', 'rdp', '10.0.0.1', 3389, via: 'h1', order: 4);
      container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        treeDatabaseProvider.overrideWithValue(db),
        healthChecksEnabledProvider.overrideWith((ref) => false),
        if (team) ...[
          activeSpaceProvider.overrideWith((ref) => const OrchardSpace('team-1')),
          activeOrchardProvider.overrideWithValue(AsyncData(OrchardSummary(
            id: 'team-1',
            name: 'Platform team',
            role: 'member-role',
            defaultCrateId: mayAdd ? 'all' : 'prod',
            crates: const [
              CrateSummary(id: 'all', name: 'Legacy', level: 'manage', switches: CrateSwitches.all),
              CrateSummary(id: 'prod', name: 'Production', level: 'connect', switches: {CrateSwitches.connect}),
            ],
          ))),
          itemCratesProvider.overrideWith((ref, kind) => Stream.value(const <String, String>{})),
        ],
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: HostsHomePage(onConnectTo: (i) => opened.add(i.connection.id), onOpenSftp: (_) {}),
          ),
        ),
      ));
      await settle(tester);
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(hours: 1));
    }

    Finder key(String k) => find.byKey(ValueKey(k));

    Future<void> showPanel(WidgetTester tester, String id) async {
      await tester.tap(find.descendant(of: find.byType(HostsHomePage), matching: find.text(id == 'h1' ? 'web-01' : 'db-01')).first);
      await settle(tester);
      expect(key('host-panel-$id'), findsOneWidget);
    }

    testWidgets('the card of a host with a screen has a monitor that opens it; one without has none; Connect still '
        'opens SSH', (tester) async {
      await pump(tester);
      expect(key('host-screen-button-h1'), findsOneWidget);
      expect(key('host-screen-button-h2'), findsNothing);
      // A screen host itself carries none.
      expect(key('host-screen-button-s1'), findsNothing);
      await tester.tap(key('host-screen-button-h1'));
      await settle(tester);
      expect(opened, ['s1']);
      // Connect, in the host's panel: SSH, the host itself.
      await showPanel(tester, 'h1');
      await tester.tap(key('host-panel-primary'));
      await settle(tester);
      expect(opened.last, 'h1');
      await finish(tester);
    });

    testWidgets('a host with several screens: its monitor opens a small menu of them, each said with its kind',
        (tester) async {
      await pump(tester, two: true);
      await tester.tap(key('host-screen-button-h1'));
      await settle(tester);
      expect(key('host-screen-pick-s1'), findsOneWidget);
      expect(key('host-screen-pick-s2'), findsOneWidget);
      expect(find.text('RDP · Alpha'), findsOneWidget);
      expect(find.text('VNC · web-01 desktop'), findsOneWidget);
      await tester.tap(key('host-screen-pick-s2'));
      await settle(tester);
      expect(opened, ['s2']);
      await finish(tester);
    });

    testWidgets("the list's row has the monitor too", (tester) async {
      await pump(tester, list: true);
      expect(find.descendant(of: key('hosts-row-h1'), matching: key('host-screen-button-h1')), findsOneWidget);
      expect(key('host-screen-button-h2'), findsNothing);
      await tester.tap(key('host-screen-button-h1'));
      await settle(tester);
      expect(opened, contains('s1'));
      await finish(tester);
    });

    testWidgets('the panel: a Screens section with each screen and Open, a monitor at its foot; Add a screen on a '
        'host with none', (tester) async {
      await pump(tester);
      await showPanel(tester, 'h1');
      expect(key('host-screens-h1'), findsOneWidget);
      expect(find.text(l10n.hostScreensHead.toUpperCase()), findsOneWidget);
      expect(key('host-screen-row-s1'), findsOneWidget);
      await tester.tap(key('host-screen-open-s1'));
      await settle(tester);
      expect(opened, ['s1']);
      await tester.tap(key('host-panel-screen'));
      await settle(tester);
      expect(opened, ['s1', 's1']);
      expect(key('host-screens-add-h1'), findsOneWidget);
      // db-01 has none: said, with Add a screen; no monitor at its foot.
      await showPanel(tester, 'h2');
      expect(key('host-screens-none-h2'), findsOneWidget);
      expect(key('host-panel-screen'), findsNothing);
      expect(key('host-screens-add-h2'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('Add a screen asks VNC or RDP: VNC at localhost:5900 through the host, RDP at the host\'s own '
        'address on 3389 through it, each named after the host', (tester) async {
      await pump(tester);
      await showPanel(tester, 'h2');
      await tester.tap(key('host-screens-add-h2'));
      await settle(tester);
      expect(find.text(l10n.hostScreenAddTitle('db-01')), findsOneWidget);
      await tester.tap(key('host-screen-kind-rdp'));
      await settle(tester);
      var target = container.read(connectionEditorTargetProvider)!;
      expect(target.connectionId, isNull);
      expect(target.initialProtocol, ConnectionProtocol.rdp);
      expect(target.initialVia, 'h2');
      expect(target.initialHost, '10.0.0.2');
      expect(target.initialLabel, 'db-01 RDP');
      container.read(connectionEditorTargetProvider.notifier).state = null;
      await settle(tester);

      // From the menu's Tools, as before: VNC this time.
      await tester.tap(find.text('db-01').first, buttons: kSecondaryButton);
      await settle(tester);
      await tester.tap(key('host-menu-tools'));
      await settle(tester);
      await tester.tap(key('host-menu-add_screen'));
      await settle(tester);
      await tester.tap(key('host-screen-kind-vnc'));
      await settle(tester);
      target = container.read(connectionEditorTargetProvider)!;
      expect(target.initialProtocol, ConnectionProtocol.vnc);
      expect(target.initialVia, 'h2');
      expect(target.initialHost, isNull, reason: 'the editor puts localhost for a screen through a host');
      expect(target.initialLabel, 'db-01 VNC');
      container.read(connectionEditorTargetProvider.notifier).state = null;
      await finish(tester);
    });

    testWidgets("the host's menu: Open screen at the top beside SFTP (a submenu of them where it has several)",
        (tester) async {
      await pump(tester);
      await tester.tap(find.text('web-01').first, buttons: kSecondaryButton);
      await settle(tester);
      expect(key('host-menu-sftp'), findsOneWidget);
      expect(key('host-menu-screen'), findsOneWidget);
      await tester.tap(key('host-menu-screen'));
      await settle(tester);
      expect(opened, ['s1']);
      // db-01: none.
      await tester.tap(find.text('db-01').first, buttons: kSecondaryButton);
      await settle(tester);
      expect(key('host-menu-sftp'), findsOneWidget);
      expect(key('host-menu-screen'), findsNothing);
      await finish(tester);
    });

    testWidgets('several screens: the menu\'s Open screen is a submenu of them', (tester) async {
      await pump(tester, two: true);
      await tester.tap(find.text('web-01').first, buttons: kSecondaryButton);
      await settle(tester);
      await tester.tap(key('host-menu-screen'));
      await settle(tester);
      expect(key('host-menu-screen:s1'), findsOneWidget);
      await tester.tap(key('host-menu-screen:s2'));
      await settle(tester);
      expect(opened, ['s2']);
      await finish(tester);
    });

    testWidgets("in a team's space where this role may not add hosts: Open screen, never Add a screen", (tester) async {
      await pump(tester, team: true, mayAdd: false);
      expect(key('host-screen-button-h1'), findsOneWidget);
      await showPanel(tester, 'h1');
      expect(key('host-screen-row-s1'), findsOneWidget);
      expect(key('host-screens-add-h1'), findsNothing);
      // A host with none and none to add: no section at all.
      await showPanel(tester, 'h2');
      expect(key('host-screens-h2'), findsNothing);
      await tester.tap(find.text('web-01').first, buttons: kSecondaryButton);
      await settle(tester);
      expect(key('host-menu-screen'), findsOneWidget);
      await tester.tap(key('host-menu-tools'));
      await settle(tester);
      expect(key('host-menu-add_screen'), findsNothing);
      await finish(tester);
    });

    testWidgets("in a team's space where this role may add hosts: Add a screen is there", (tester) async {
      await pump(tester, team: true);
      await showPanel(tester, 'h2');
      expect(key('host-screens-add-h2'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a screen reader: the monitor is a button named after the screen, and the card has Open screen as '
        'an action', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      expect(
        tester.getSemantics(key('host-screen-button-h1')),
        matchesSemantics(label: l10n.hostScreenOpenNamed('web-01 desktop'), isButton: true, hasTapAction: true,
            isFocusable: true, hasFocusAction: true, hasEnabledState: true, isEnabled: true),
      );
      final card = tester.getSemantics(find.bySemanticsLabel(RegExp(r'^web-01, ')).first);
      final actions = card.getSemanticsData().customSemanticsActionIds ?? const <int>[];
      final labels = [for (final id in actions) CustomSemanticsAction.getAction(id)?.label];
      expect(labels, contains(l10n.hostScreenOpenNamed('web-01 desktop')));
      handle.dispose();
      await finish(tester);
    });

    testWidgets('the keyboard: Tab reaches the monitor, Enter opens the screen', (tester) async {
      await pump(tester);
      final focus = Focus.of(tester.element(find.descendant(of: key('host-screen-button-h1'), matching: find.byType(Icon))));
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(opened, ['s1']);
      await finish(tester);
    });
  });

  group('the Inspector of a session', () {
    Future<(ProviderContainer, _Sessions)> pumpInspector(WidgetTester tester, {required String hostId}) async {
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      for (final (id, label, protocol, host, port, via) in [
        ('h1', 'web-01', 'ssh', '10.0.0.1', 22, null),
        ('h2', 'db-01', 'ssh', '10.0.0.2', 22, null),
        ('s1', 'web-01 desktop', 'vnc', 'localhost', 5900, 'h1'),
      ]) {
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: id,
              label: label,
              host: host,
              port: Value(port),
              protocol: Value(protocol),
              connectViaId: Value(via),
              createdAt: _at,
              updatedAt: _at,
            ));
      }
      final c = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        treeDatabaseProvider.overrideWithValue(db),
        activeSessionsProvider.overrideWith(_Sessions.new),
      ]);
      addTearDown(c.dispose);
      final terminal = Terminal();
      final state = SessionState(
        status: SessionStatus.connected,
        connectionId: hostId,
        connectionLabel: hostId == 'h1' ? 'web-01' : 'db-01',
        host: '10.0.0.1',
        port: 22,
        username: 'deploy',
        session: TerminalSession(
            id: 'ssh-1', connectionId: hostId, terminal: terminal, shell: _Shell(), startedAt: _at),
      );
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Align(
              alignment: Alignment.centerRight,
              child: InspectorPanel(sessionId: 'ssh-1', sessionState: state, onClose: () {}),
            ),
          ),
        ),
      ));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      return (c, c.read(activeSessionsProvider.notifier) as _Sessions);
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(hours: 1));
    }

    testWidgets("Tools lists this host's screens; Open opens one in a tab of its own", (tester) async {
      final (c, sessions) = await pumpInspector(tester, hostId: 'h1');
      await tester.scrollUntilVisible(find.byKey(const ValueKey('host-screen-open-s1')), 200,
          scrollable: find.byType(Scrollable).last);
      expect(find.byKey(const ValueKey('host-screens-add-h1')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('host-screen-open-s1')));
      await tester.pump();
      expect(sessions.started, ['s1']);
      expect(c.read(v3ActiveSessionTabProvider), 's-s1');
      await finish(tester);
    });

    testWidgets('a host with none: said, with Add a screen', (tester) async {
      await pumpInspector(tester, hostId: 'h2');
      await tester.scrollUntilVisible(find.byKey(const ValueKey('host-screens-none-h2')), 200,
          scrollable: find.byType(Scrollable).last);
      expect(find.byKey(const ValueKey('host-screens-add-h2')), findsOneWidget);
      await finish(tester);
    });
  });
}
