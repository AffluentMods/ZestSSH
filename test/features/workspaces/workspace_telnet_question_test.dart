import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart' show Space;
import 'package:zestssh/features/workspaces/widgets/workspace_launch.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/saved_tab_group.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/saved_tab_groups_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/shell_questions.dart';

/// A Telnet host is asked about before it is connected to: what is typed
/// there, a password among it, crosses the network as it is. Two ways of
/// opening one asked nothing, since the person answered when the host was
/// first opened in that tab: a saved workspace, and the tabs of the last run
/// brought back as the app starts (found in a security review). Now
/// both ask, once for the lot; Retry does not.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  /// The host of each session started, in order.
  final started = <String>[];

  @override
  String? startSession(Connection connection,
      {bool allowDuplicate = false,
      String? usernameOverride,
      String? initialCommand,
      String? asAccount,
      bool unattended = false,
      Space? space}) {
    final id = 'new-${started.length}-${connection.id}';
    started.add(connection.id);
    state = {
      ...state,
      id: SessionState(
        status: SessionStatus.connected,
        connectionId: connection.id,
        connectionLabel: connection.label,
        host: connection.host,
        port: connection.port,
        session: TerminalSession(
          id: id,
          connectionId: connection.id,
          terminal: Terminal(),
          shell: _Shell(),
          startedAt: DateTime(2026, 11, 12),
        ),
      ),
    };
    return id;
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
  @override
  bool get isEncryptedSsh => true;
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  final at = DateTime(2026, 11, 12);

  late AppDatabase db;
  late ProviderContainer container;
  late _Sessions sessions;

  /// Two saved hosts, web-01 (SSH) and switch-01 (Telnet), and two saved
  /// workspaces: "Ops", a tab of web-01 beside switch-01 and a tab of
  /// switch-01 alone, and "Web", web-01 alone.
  Future<void> setUpApp() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    for (final (id, label, protocol) in [('h-web', 'web-01', 'ssh'), ('h-switch', 'switch-01', 'telnet')]) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id, label: label, host: '$label.example.com', protocol: Value(protocol), createdAt: at, updatedAt: at));
    }
    final groups = [
      SavedTabGroup(
        id: 'w-ops',
        name: 'Ops',
        tabs: [
          TabSnapshot(
            paneTreeOfConnIds: PaneSplit(
              axis: Axis.horizontal,
              first: PaneLeaf(id: 'l-web', sessionIds: ['h-web']),
              second: PaneLeaf(id: 'l-switch', sessionIds: ['h-switch']),
            ),
          ),
          TabSnapshot(paneTreeOfConnIds: PaneLeaf(id: 'l-alone', sessionIds: ['h-switch'])),
        ],
        hostNames: const {'h-web': 'web-01', 'h-switch': 'switch-01'},
      ),
      SavedTabGroup(
        id: 'w-web',
        name: 'Web',
        tabs: [TabSnapshot(paneTreeOfConnIds: PaneLeaf(id: 'l-only', sessionIds: ['h-web']))],
        hostNames: const {'h-web': 'web-01'},
      ),
    ];
    await LocalStateStore(db).write('desktop_saved_tab_groups', jsonEncode([for (final g in groups) g.toJson()]));
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
      activeSessionsProvider.overrideWith(_Sessions.new),
    ]);
    sessions = container.read(activeSessionsProvider.notifier) as _Sessions;
    container.read(savedTabGroupsProvider);
    for (var i = 0; i < 50 && container.read(savedTabGroupsProvider).isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(container.read(savedTabGroupsProvider), hasLength(2));
  }

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  group('a saved workspace', () {
    test('with nobody asked, its Telnet panes stay empty and the others open: none is named as gone', () async {
      await setUpApp();
      final result = await container.read(savedTabGroupsProvider.notifier).launchResolving('w-ops');
      expect(sessions.started, ['h-web']);
      expect(result.launchedTabCount, 1, reason: 'the tab of switch-01 alone is not opened');
      expect(result.unresolvedHostNames, isEmpty);
      final leaves = container.read(workTabsProvider).tabs.last.paneTree.allLeaves;
      expect(leaves.map((l) => l.isPlaceholder), [false, true], reason: 'its place is kept, to connect from');
    });

    test('the question is asked once, for its Telnet hosts, before anything opens; a no leaves them out', () async {
      await setUpApp();
      final asked = <List<String>>[];
      final startedWhenAsked = <int>[];
      final result = await container.read(savedTabGroupsProvider.notifier).launchResolving('w-ops',
          askPlaintext: (telnet) async {
        asked.add([for (final c in telnet) c.id]);
        startedWhenAsked.add(sessions.started.length);
        return false;
      });
      expect(asked, [
        ['h-switch']
      ]);
      expect(startedWhenAsked, [0]);
      expect(sessions.started, ['h-web']);
      expect(result.launchedTabCount, 1);
    });

    test('on "connect anyway" all of it opens', () async {
      await setUpApp();
      final result = await container.read(savedTabGroupsProvider.notifier).launchResolving('w-ops',
          askPlaintext: (_) async => true);
      expect(sessions.started, ['h-web', 'h-switch', 'h-switch']);
      expect(result.launchedTabCount, 2);
    });

    test('one with no Telnet host asks nothing', () async {
      await setUpApp();
      var asked = 0;
      final result = await container.read(savedTabGroupsProvider.notifier).launchResolving('w-web',
          askPlaintext: (_) async {
        asked++;
        return false;
      });
      expect(asked, 0);
      expect(sessions.started, ['h-web']);
      expect(result.launchedTabCount, 1);
    });

    Future<void> pumpOpen(WidgetTester tester) async {
      await tester.runAsync(setUpApp);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => launchWorkspaceFromSurface(context, ref, 'w-ops'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await settle(tester);
    }

    testWidgets('opened from the app: the red question names the Telnet host; Cancel opens the rest', (tester) async {
      await pumpOpen(tester);
      expect(find.text(l10n.desktopShellUnencryptedConnection), findsOneWidget);
      expect(find.textContaining(l10n.desktopShellTelnetInWorkspace('switch-01')), findsOneWidget);
      expect(sessions.started, isEmpty, reason: 'nothing opens before the answer');
      await tester.tap(find.text(l10n.cancel));
      await settle(tester);
      expect(sessions.started, ['h-web']);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('opened from the app: "Connect anyway" opens its Telnet panes too', (tester) async {
      await pumpOpen(tester);
      await tester.tap(find.text(l10n.desktopShellConnectAnyway));
      await settle(tester);
      expect(sessions.started, ['h-web', 'h-switch', 'h-switch']);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('the tabs of the last run, as the app starts', () {
    Future<Set<String>?> pumpAsk(WidgetTester tester, List<String> connIds, {String? answer}) async {
      await tester.runAsync(setUpApp);
      Set<String>? leftOut;
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => leftOut = await telnetHostsNotToReopen(context, db.connectionsDao, connIds),
              child: const Text('start'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('start'));
      await settle(tester);
      if (answer != null) {
        expect(find.text(l10n.desktopShellUnencryptedConnection), findsOneWidget);
        expect(find.textContaining(l10n.desktopShellTelnetReopenTabs('switch-01')), findsOneWidget);
        expect(leftOut, isNull, reason: 'nothing is decided before the answer');
        await tester.tap(find.text(answer));
        await settle(tester);
      }
      await tester.pumpWidget(const SizedBox());
      return leftOut;
    }

    testWidgets('a Telnet host among them is asked about by name, and Cancel leaves it out', (tester) async {
      expect(await pumpAsk(tester, ['h-web', 'h-switch', 'h-switch', 'h-gone', ''], answer: l10n.cancel), {'h-switch'});
    });

    testWidgets('on "Connect anyway" none is left out', (tester) async {
      expect(await pumpAsk(tester, ['h-web', 'h-switch'], answer: l10n.desktopShellConnectAnyway), isEmpty);
    });

    testWidgets('with no Telnet host among them nothing is asked', (tester) async {
      expect(await pumpAsk(tester, ['h-web', 'h-gone']), isEmpty);
      expect(find.text(l10n.desktopShellUnencryptedConnection), findsNothing);
    });

    test('left out, a host leaves its panes: a pane left empty goes, and a tab left empty goes', () {
      final tabs = [
        TabSnapshot(
          customName: 'both',
          colorIndex: 3,
          paneTreeOfConnIds: PaneSplit(
            id: 's-1',
            axis: Axis.horizontal,
            first: PaneLeaf(id: 'l-web', sessionIds: ['h-web']),
            second: PaneLeaf(id: 'l-switch', sessionIds: ['h-switch']),
          ),
        ),
        TabSnapshot(paneTreeOfConnIds: PaneLeaf(id: 'l-alone', sessionIds: ['h-switch'])),
        TabSnapshot(paneTreeOfConnIds: PaneLeaf(id: 'l-two', sessionIds: ['h-switch', 'h-web', 'h-db'], activeIndex: 2)),
        TabSnapshot(paneTreeOfConnIds: PaneLeaf(id: 'l-db', sessionIds: ['h-db'])),
      ];
      final back = tabsWithoutHosts(tabs, {'h-switch'}, activeTabIndex: 2);
      expect(back.tabs, hasLength(3));
      final first = back.tabs[0];
      expect((first.customName, first.colorIndex), ('both', 3));
      expect(first.paneTreeOfConnIds, isA<PaneLeaf>().having((l) => l.id, 'id', 'l-web'),
          reason: 'the split became its other side');
      final two = back.tabs[1].paneTreeOfConnIds as PaneLeaf;
      expect(two.id, 'l-two');
      expect(two.sessionIds, ['h-web', 'h-db']);
      expect(two.activeIndex, 1, reason: 'the tab shown in the pane is still the one shown');
      expect(back.tabs[2], same(tabs[3]), reason: 'a tab with none of them is as it was');
      expect(back.activeTabIndex, 1, reason: 'the active tab is still the active one');

      expect(tabsWithoutHosts(tabs, {'h-switch'}, activeTabIndex: 1).activeTabIndex, isNull,
          reason: 'the active tab is gone: the first one brought back is shown');
      final none = tabsWithoutHosts(tabs, const {}, activeTabIndex: 1);
      expect(none.tabs, same(tabs));
      expect(none.activeTabIndex, 1);
    });

    // The shell's own lines are not run here (the whole shell would have to
    // be pumped): this holds them to the two functions tested above.
    test('the shell asks before it brings any tab back, and brings back what is left', () {
      final shell = File('lib/ui/screens/desktop/desktop_shell.dart').readAsStringSync();
      final ask = shell.indexOf('await telnetHostsNotToReopen(');
      expect(ask, greaterThan(0));
      expect('telnetHostsNotToReopen('.allMatches(shell), hasLength(1));
      // Each restore is called once, after the question, with what is left.
      for (final call in ['await _restoreFromTabSnapshots(', 'await _restoreFromFlatList(']) {
        expect(call.allMatches(shell), hasLength(1), reason: call);
        expect(shell.indexOf(call), greaterThan(ask), reason: call);
      }
      expect(shell, contains('tabsWithoutHosts(snapshot.tabs, leaveOut, activeTabIndex: snapshot.activeTabIndex)'));
      expect(shell, contains('if (!leaveOut.contains(saved.connectionId)) saved'));
      // And no session of the last run starts anywhere else.
      expect('startRestoredSession('.allMatches(shell), hasLength(2));
    });
  });

  // A session is started in these files and no others. A new place fails
  // here until someone has said how a Telnet host is asked about on its way
  // there (found in a security review: the question lives in the callers).
  test('every place that starts a session is on this list', () {
    const sites = {
      // Asks once for the hosts ticked.
      'lib/features/broadcast/broadcast_to_hosts.dart': 1,
      'lib/features/hosts/connect_link.dart': 1,
      // A host's own screens: a VNC or RDP host, never Telnet.
      'lib/features/hosts/host_screens.dart': 1,
      // This device's own shell.
      'lib/features/hosts/local_terminal.dart': 1,
      'lib/features/hosts/open_many_hosts.dart': 2,
      'lib/features/hosts/open_selected_hosts.dart': 4,
      // Quick connect typed as user@host: SSH.
      'lib/features/hosts/pages/hosts_home_page.dart': 1,
      'lib/features/hosts/phone/phone_host_selection.dart': 1,
      // Joining a shared tmux session of a team's host.
      'lib/features/sharing/share_providers.dart': 1,
      'lib/features/snippets/run_snippet.dart': 1,
      // An unattended open: nobody is there to ask, so a Telnet host is refused.
      'lib/providers/automation_provider.dart': 1,
      // A workspace: launchResolving, its Telnet hosts left out unless asked.
      'lib/providers/saved_tab_groups_provider.dart': 1,
      // The notifier itself: what the callers call, and Retry; and a host's
      // files on their own, from the SFTP dock of an SSH session (4.0); and a
      // Proxmox guest's console (4.0), opened, again and duplicated: never Telnet.
      'lib/providers/terminal_providers.dart': 16,
      // The shell's own connect (asks), the two restores (asked above),
      // Retry and a duplicate of an open tab (answered when first opened).
      'lib/ui/screens/desktop/desktop_shell.dart': 5,
      // An empty pane's picker (asks).
      'lib/ui/screens/desktop/widgets/desktop_terminal_area.dart': 1,
      // A monitored host's failed units (asks, here and on a phone).
      'lib/ui/screens/desktop/widgets/monitor_table_view.dart': 1,
      // The phone's home: its own question, the demo host, this device's shell.
      'lib/ui/screens/home/home_screen.dart': 3,
      'lib/ui/screens/home/widgets/quick_connect_bar.dart': 3,
      'lib/ui/screens/monitoring/server_detail_screen.dart': 1,
      // File panes: a host picked for SFTP.
      'lib/ui/screens/sftp/sftp_dual_pane_screen.dart': 2,
      // Only where no caller connects for it (a computer's shell does, and asks).
      'lib/ui/widgets/command_palette.dart': 1,
    };
    final found = <String, int>{};
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final text = file.readAsStringSync();
      final count = 'startSession('.allMatches(text).length + 'startRestoredSession('.allMatches(text).length;
      if (count > 0) found[file.path.replaceAll(Platform.pathSeparator, '/')] = count;
    }
    expect(found, sites);
  });
}
