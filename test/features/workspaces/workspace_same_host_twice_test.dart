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
import 'package:zestssh/features/workspaces/models/workspace_view.dart' show WorkspaceLaunchResult;
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/saved_tab_group.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/saved_tab_groups_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/ssh_service.dart';

/// A workspace whose tab has two terminal panes on the same host (a shell
/// beside htop or a log tail, both web-01) is saved as two panes of the same
/// host. The launch collected the tab's hosts into a set and started one
/// session per host, so both panes got the same session: one shell shown
/// twice, the second terminal never opened (found in a review).
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);
  var _n = 0;

  @override
  String? startSession(Connection connection,
      {bool allowDuplicate = false,
      String? usernameOverride,
      String? initialCommand,
      String? asAccount,
      bool unattended = false,
      Space? space}) {
    final id = 's-${++_n}-${connection.id}';
    state = {
      ...state,
      id: SessionState(
        status: SessionStatus.connected,
        connectionId: connection.id,
        connectionLabel: connection.label,
        host: connection.host,
        port: 22,
        session: TerminalSession(
            id: id, connectionId: connection.id, terminal: Terminal(), shell: _Shell(), startedAt: DateTime(2026, 11, 5)),
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

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  /// Launches a workspace of one tab laid out as [tree]; the leaves of the
  /// tab it opened, and the launch's result.
  Future<(List<PaneLeaf>, WorkspaceLaunchResult, ProviderContainer)> launch(PaneNode tree) async {
    final at = DateTime(2026, 10, 1);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'h-web', label: 'web-01', host: 'web-01.example.com', createdAt: at, updatedAt: at));
    final group = SavedTabGroup(
      id: 'w-ops',
      name: 'Ops',
      tabs: [TabSnapshot(paneTreeOfConnIds: tree)],
      hostNames: const {'h-web': 'web-01', 'h-gone': 'old-db'},
    );
    await LocalStateStore(db).write('desktop_saved_tab_groups', jsonEncode([group.toJson()]));
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
      activeSessionsProvider.overrideWith(_Sessions.new),
    ]);
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    container.read(savedTabGroupsProvider);
    for (var i = 0; i < 50 && container.read(savedTabGroupsProvider).isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(container.read(savedTabGroupsProvider), hasLength(1));
    final result = await container.read(savedTabGroupsProvider.notifier).launchResolving('w-ops');
    final leaves = container.read(workTabsProvider).tabs.last.paneTree.allLeaves.toList();
    return (leaves, result, container);
  }

  test('two terminal panes on one host open as two sessions', () async {
    final (leaves, result, container) = await launch(PaneSplit(
      axis: Axis.horizontal,
      first: PaneLeaf(id: 'l-shell', sessionIds: ['h-web']),
      second: PaneLeaf(id: 'l-top', sessionIds: ['h-web']),
    ));
    expect(result.launchedTabCount, 1);
    final ids = [for (final l in leaves) l.sessionIds.single];
    expect(ids.toSet(), hasLength(2), reason: 'each pane its own terminal, as when it was saved');
    expect(container.read(activeSessionsProvider), hasLength(2));
    expect(ids.map((s) => container.read(activeSessionsProvider)[s]?.connectionId), ['h-web', 'h-web']);
  });

  test('two terminals stacked in one pane on one host are two sessions too', () async {
    final (leaves, _, _) = await launch(PaneLeaf(id: 'l-both', sessionIds: ['h-web', 'h-web'], activeIndex: 1));
    expect(leaves.single.sessionIds.toSet(), hasLength(2));
    expect(leaves.single.activeIndex, 1);
  });

  test('an SFTP pane beside a terminal on its host works in that terminal\'s session, as the SFTP dock does', () async {
    final (leaves, _, container) = await launch(PaneSplit(
      axis: Axis.horizontal,
      first: PaneLeaf(id: 'l-sftp', sessionIds: ['h-web'], type: 'sftp'),
      second: PaneLeaf(id: 'l-shell', sessionIds: ['h-web']),
    ));
    expect(leaves.map((l) => l.type), ['sftp', 'terminal']);
    expect(leaves.first.sessionIds.single, leaves.last.sessionIds.single);
    expect(container.read(activeSessionsProvider), hasLength(1));
  });

  test('a deleted host in two panes is named once, and both panes stay as empty places', () async {
    final (leaves, result, _) = await launch(PaneSplit(
      axis: Axis.vertical,
      first: PaneLeaf(id: 'l-web', sessionIds: ['h-web']),
      second: PaneSplit(
        axis: Axis.horizontal,
        first: PaneLeaf(id: 'l-db1', sessionIds: ['h-gone']),
        second: PaneLeaf(id: 'l-db2', sessionIds: ['h-gone']),
      ),
    ));
    expect(result.unresolvedHostNames, ['old-db']);
    expect(leaves.map((l) => l.isPlaceholder), [false, true, true]);
  });
}
