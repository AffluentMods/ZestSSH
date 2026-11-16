import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/work_tab.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/quick_connect_v3.dart';

/// The New Tab page (3.2): Ctrl+T finds
/// open tabs by their names or their hosts' while typing, and with nothing
/// typed shows the hosts connected to last and the saved workspaces.
Connection _host(String id, String label, DateTime? last) => Connection(
      id: id,
      label: label,
      host: '192.168.10.${id.hashCode % 200}',
      port: 22,
      keepAliveSeconds: 30,
      colorIndex: 0,
      protocol: 'ssh',
      zlibCompression: false,
      envVars: '',
      forwardAgent: false,
      compatibilityMode: false,
      sortOrder: 0,
      sizeTier: 1,
      pinned: false,
      monitored: false,
      lastConnected: last,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

SessionState _session(String label) =>
    SessionState(status: SessionStatus.connected, connectionLabel: label);

void main() {
  test('open tabs are found by their own names or their hosts\' names, four at most', () {
    final tabs = [
      WorkTab(id: 't1', paneTree: PaneLeaf(sessionIds: const ['s1'])),
      WorkTab(id: 't2', customName: 'Deploy', paneTree: PaneLeaf(sessionIds: const ['s2', 's3'])),
      WorkTab(id: 't3', paneTree: PaneLeaf(sessionIds: const ['s4'])),
    ];
    final sessions = {'s1': _session('web-02'), 's2': _session('db-primary'), 's3': _session('web-03'), 's4': _session('')};
    expect([for (final t in newTabOpenTabs(tabs, sessions, 'web')) (t.id, t.title)], [('t1', 'web-02'), ('t2', 'Deploy')]);
    expect([for (final t in newTabOpenTabs(tabs, sessions, 'deploy')) t.id], ['t2']);
    expect(newTabOpenTabs(tabs, sessions, '  '), isEmpty);
  });

  test('recent hosts: the ones connected to last, newest first, never-connected ones left out', () {
    final hosts = [
      for (final h in [
        _host('a', 'web-01', DateTime(2026, 10, 20)),
        _host('b', 'db-primary', null),
        _host('c', 'nas', DateTime(2026, 10, 24)),
        _host('d', 'web-02', DateTime(2026, 10, 22)),
      ])
        ConnectionWithDetails(connection: h),
    ];
    expect([for (final h in newTabRecentHosts(hosts)) h.connection.id], ['c', 'd', 'a']);
  });
}
