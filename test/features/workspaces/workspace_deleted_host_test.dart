import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart' show Space;
import 'package:zestssh/features/workspaces/state/workspaces_provider.dart';
import 'package:zestssh/features/workspaces/widgets/workspace_edit_dialog.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/saved_tab_group.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/saved_tab_groups_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/ssh_service.dart';

/// A workspace whose host was deleted, opened while a tab shows an empty
/// "Connect…" pane (seen in build 277 on Windows):
/// right-clicking the workspace in the Hosts drawer showed "Something went
/// wrong", ArgumentError "Invalid argument(s): 0", on every right click. The
/// editor it opens shows what saving now would capture, and capturing a tab
/// with an empty pane clamped that pane's active index between 0 and -1.
/// Now an empty pane is captured as an empty place, the deleted host's pane
/// says so (it opens empty, and can be removed), and the workspace launches
/// with that pane empty.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  void seed(String id, String connectionId) => state = {...state, id: _state(id, connectionId)};

  SessionState _state(String id, String connectionId) => SessionState(
        status: SessionStatus.connected,
        connectionId: connectionId,
        connectionLabel: connectionId,
        host: '$connectionId.example.com',
        port: 22,
        session: TerminalSession(
          id: id,
          connectionId: connectionId,
          terminal: Terminal(),
          shell: _Shell(),
          startedAt: DateTime(2026, 10, 22),
        ),
      );

  @override
  String? startSession(Connection connection,
      {bool allowDuplicate = false,
      String? usernameOverride,
      String? initialCommand,
      String? asAccount,
      bool unattended = false,
      Space? space}) {
    final id = 'new-${connection.id}';
    seed(id, connection.id);
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

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  final at = DateTime(2026, 10, 1);

  late AppDatabase db;
  late ProviderContainer container;
  late _Sessions sessions;

  /// The app with a saved workspace "Ops" of two panes, web-01 (still here)
  /// and a host deleted since ("old-db"), and a tab open with web-01 and an
  /// empty "Connect…" pane beside it.
  Future<void> setUpApp() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'h-web', label: 'web-01', host: 'web-01.example.com', createdAt: at, updatedAt: at));
    final group = SavedTabGroup(
      id: 'w-ops',
      name: 'Ops',
      tabs: [
        TabSnapshot(
          paneTreeOfConnIds: PaneSplit(
            axis: Axis.horizontal,
            first: PaneLeaf(id: 'l-web', sessionIds: ['h-web']),
            second: PaneLeaf(id: 'l-db', sessionIds: ['h-gone']),
          ),
        ),
      ],
      hostNames: const {'h-web': 'web-01', 'h-gone': 'old-db'},
    );
    await LocalStateStore(db).write('desktop_saved_tab_groups', jsonEncode([group.toJson()]));
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
    expect(container.read(savedTabGroupsProvider), hasLength(1));
    // The hosts there are, as the page has them.
    container.listen(connectionsWithDetailsProvider, (_, _) {});
    await container.read(connectionsWithDetailsProvider.future);
    // A tab open now: web-01 and an empty pane ("Connect…").
    sessions.seed('s-1', 'h-web');
    final tabs = container.read(workTabsProvider.notifier);
    final tabId = tabs.createTab('s-1');
    tabs.replaceTabTree(
      tabId,
      PaneSplit(
        axis: Axis.horizontal,
        first: PaneLeaf(sessionIds: ['s-1']),
        second: PaneLeaf.placeholder(),
      ),
    );
  }

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('what saving now would capture: the tab, its empty pane kept empty; no ArgumentError', () async {
    await setUpApp();
    final preview = container.read(currentLayoutPreviewProvider);
    expect(preview, isNotNull);
    expect(preview!.paneCount, 2);
    expect(preview.memberHosts.map((m) => m.resolved), [true, false]);
  });

  testWidgets('its editor opens; the deleted host\'s pane says so, and can be removed', (tester) async {
    await tester.runAsync(setUpApp);
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => WorkspaceEditDialog.show(context, workspaceId: 'w-ops'),
              child: const Text('edit'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('edit'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('old-db'), findsOneWidget);
    expect(find.byKey(const ValueKey('workspace-pane-host-deleted')), findsOneWidget);
    expect(find.text(l10n.docCheckWorkspaceHostDeleted), findsOneWidget);
    expect(find.text(l10n.workspaceReplaceDiscards), findsOneWidget, reason: 'the open tab can replace it');
    await tester.pumpWidget(const SizedBox());
  });

  test('it launches: web-01 opens, the deleted host\'s pane is an empty pane, and it is named', () async {
    await setUpApp();
    final before = container.read(workTabsProvider).tabs.length;
    final result = await container.read(savedTabGroupsProvider.notifier).launchResolving('w-ops');
    expect(result.launchedTabCount, 1);
    expect(result.unresolvedHostNames, ['old-db']);
    final tab = container.read(workTabsProvider).tabs[before];
    final leaves = tab.paneTree.allLeaves;
    expect(leaves.map((l) => l.isPlaceholder), [false, true]);
    expect(container.read(activeSessionsProvider)[leaves.first.sessionIds.single]?.connectionId, 'h-web');
  });
}
