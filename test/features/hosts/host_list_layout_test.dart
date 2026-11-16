import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/settings_service.dart';

/// The layout of a list of hosts: Active first on,
/// the hosts with an open session stand first and the rest under them; inside
/// each the usual groups in their usual order, a group's heading only where it
/// has a host there; among the active ones, the last used first.
void main() {
  ConnectionGroup groupOf(String id, String name, int order) =>
      ConnectionGroup(id: id, name: name, colorIndex: 0, sortOrder: order, isExpanded: true, createdAt: DateTime(2026));

  ConnectionWithDetails host(String id, ConnectionGroup? g, {DateTime? connected}) => ConnectionWithDetails(
        connection: Connection(
          id: id,
          label: id,
          host: '192.0.2.1',
          port: 22,
          groupId: g?.id,
          colorIndex: 0,
          protocol: 'ssh',
          zlibCompression: false,
          keepAliveSeconds: 0,
          envVars: '',
          forwardAgent: false,
          compatibilityMode: false,
          sortOrder: 0,
          sizeTier: 1,
          pinned: false,
          monitored: false,
          lastConnected: connected,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
        group: g,
      );

  final nodes = groupOf('g-nodes', 'Nodes', 0);
  final security = groupOf('g-sec', 'Security', 1);
  final hosts = [
    host('sec-1', security),
    host('node-1', nodes, connected: DateTime(2026, 10, 1)),
    host('node-2', nodes, connected: DateTime(2026, 10, 2)),
    host('node-3', nodes),
    host('alone', null),
  ];

  // A block as words: a record of a list compares by the list's identity.
  List<String> blocks(List<HostBlock> b) =>
      [for (final x in b) '${x.group?.id}: ${x.hosts.map((h) => h.connection.id).join(' ')}'];

  test('off: the groups in their order, those in none last, nothing set apart', () {
    final l = layOutHosts(hosts, groups: [nodes, security], activeFirst: false, open: const {'node-1'});
    expect(l.split, isFalse);
    expect(blocks(l.rest), ['g-nodes: node-1 node-2 node-3', 'g-sec: sec-1', 'null: alone']);
  });

  test('on: the open ones first, a group only where it has one there, the rest under them', () {
    final l = layOutHosts(hosts, groups: [nodes, security], activeFirst: true, open: const {'node-1', 'alone'});
    expect(l.split, isTrue);
    expect(blocks(l.active), ['g-nodes: node-1', 'null: alone']);
    expect(blocks(l.rest), ['g-nodes: node-2 node-3', 'g-sec: sec-1']);
    expect([for (final h in l.inOrder) h.connection.id], ['node-1', 'alone', 'node-2', 'node-3', 'sec-1']);
  });

  test('on, with none open: no headings to say so', () {
    final l = layOutHosts(hosts, groups: [nodes, security], activeFirst: true);
    expect(l.split, isFalse);
    expect(blocks(l.rest).first, 'g-nodes: node-1 node-2 node-3');
  });

  test('among the active ones the last used first: what was in front this run, else when last connected to', () {
    final open = {'node-1', 'node-2', 'node-3'};
    final byConnected = layOutHosts(hosts, groups: [nodes], activeFirst: true, open: open);
    expect(blocks(byConnected.active).single, 'g-nodes: node-2 node-1 node-3', reason: 'never connected last');
    final byUse = layOutHosts(hosts,
        groups: [nodes], activeFirst: true, open: open, lastUsed: {'node-3': DateTime(2026, 10, 30)});
    expect(blocks(byUse.active).single, 'g-nodes: node-3 node-2 node-1');
  });

  test("a group the database has not given yet goes by its hosts' order; a host's order in a list that is not "
      'Active first is left alone', () {
    final l = layOutHosts(hosts, groups: const [], activeFirst: false);
    expect(blocks(l.rest), ['g-sec: sec-1', 'g-nodes: node-1 node-2 node-3', 'null: alone']);
  });

  group('the switch', () {
    Future<ProviderContainer> container(Map<String, Object> stored) async {
      SharedPreferences.setMockInitialValues(stored);
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
      addTearDown(c.dispose);
      return c;
    }

    test('on by itself where something is run on the host, off everywhere else', () async {
      final c = await container({});
      for (final place in [
        HostListPlace.broadcast,
        HostListPlace.runOnHosts,
        HostListPlace.runSnippet,
        HostListPlace.workflowRun,
      ]) {
        expect(c.read(activeFirstProvider(place)), isTrue, reason: place.name);
      }
      for (final place in [
        HostListPlace.pickHost,
        HostListPlace.workflowTarget,
        HostListPlace.installKey,
        HostListPlace.thresholds,
        HostListPlace.hostsPanel,
        HostListPlace.hostsPage,
        HostListPlace.phoneHosts,
      ]) {
        expect(c.read(activeFirstProvider(place)), isFalse, reason: place.name);
      }
    });

    test('remembered per place', () async {
      final c = await container({'${kActiveFirstPrefix}broadcast': false, '${kActiveFirstPrefix}thresholds': true});
      expect(c.read(activeFirstProvider(HostListPlace.broadcast)), isFalse);
      expect(c.read(activeFirstProvider(HostListPlace.thresholds)), isTrue);
      expect(c.read(activeFirstProvider(HostListPlace.runSnippet)), isTrue);
    });

    test('Reset all settings puts them back', () {
      expect(SettingsService.isResetKey('${kActiveFirstPrefix}broadcast'), isTrue);
    });
  });

  test('which host is open: a session connected or on its way, of a host', () {
    expect(
      openHostIdsOf({
        'a': const SessionState(status: SessionStatus.connected, connectionId: 'h1'),
        'b': const SessionState(status: SessionStatus.connecting, connectionId: 'h2'),
        'c': const SessionState(status: SessionStatus.disconnected, connectionId: 'h3'),
        'd': const SessionState(status: SessionStatus.connected),
      }),
      {'h1', 'h2'},
    );
  });

  test('the session in front counts as used, under its host', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      activeSessionsProvider.overrideWith(_Sessions.new),
    ]);
    addTearDown(c.dispose);
    expect(c.read(hostUseProvider), isEmpty);
    c.read(v3ActiveSessionTabProvider.notifier).state = 's1';
    expect(c.read(hostUseProvider).keys, ['h1']);
    c.read(v3ActiveSessionTabProvider.notifier).state = null;
    expect(c.read(hostUseProvider).keys, ['h1'], reason: 'leaving for a page uses nothing');
  });
}

class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref) {
    state = {'s1': const SessionState(status: SessionStatus.connected, connectionId: 'h1')};
  }
}
