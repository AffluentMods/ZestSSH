import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/tables/port_forward_network_overrides.dart';

/// A host's choice for each of its forwards on each network (the host
/// editor's Inherit / On / Off): it was saved and never read, so a forward
/// set Off on a network still started there, and one set On did not.
/// The forwards a session starts by itself follow it now.
void main() {
  late AppDatabase db;
  final at = DateTime.utc(2026, 10, 22);

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.connectionsDao.insertConnection(ConnectionsCompanion(
      id: const Value('h1'),
      label: const Value('web-01'),
      host: const Value('web-01.example.com'),
      port: const Value(22),
      protocol: const Value('ssh'),
      createdAt: Value(at),
      updatedAt: Value(at),
    ));
    Future<void> rule(String id, {bool autoStart = true, String? networkId}) =>
        db.portForwardRulesDao.insertRule(PortForwardRulesCompanion.insert(
          id: id,
          connectionId: 'h1',
          type: 'local',
          bindPort: 8000 + id.length,
          remoteHost: 'localhost',
          remotePort: 80,
          autoStart: Value(autoStart),
          networkId: Value(networkId),
          createdAt: at,
        ));
    await rule('always');
    await rule('byHand', autoStart: false);
    await rule('homeOnly', networkId: 'home');
  });
  tearDown(() => db.close());

  Future<Set<String>> starting(String? network) async =>
      (await db.portForwardRulesDao.getAutoStartRulesForNetwork('h1', network)).map((r) => r.id).toSet();

  Future<void> set(String rule, String network, PortForwardNetworkState state) =>
      db.portForwardRulesDao.setNetworkOverrideState(ruleId: rule, networkId: network, state: state);

  test("in a team's space, On from a teammate's record does not start a forward this device did not ask for", () async {
    final team = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    addTearDown(team.close);
    await team.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
    await team.connectionsDao.insertConnection(ConnectionsCompanion(
      id: const Value('h1'),
      label: const Value('web-01'),
      host: const Value('web-01.example.com'),
      port: const Value(22),
      protocol: const Value('ssh'),
      createdAt: Value(at),
      updatedAt: Value(at),
    ));
    Future<void> rule(String id, {required bool autoStart}) async {
      await team.portForwardRulesDao.insertRule(PortForwardRulesCompanion.insert(
        id: id,
        connectionId: 'h1',
        type: 'remote',
        bindPort: 8022,
        remoteHost: '127.0.0.1',
        remotePort: 22,
        autoStart: Value(autoStart),
        createdAt: at,
      ));
      await team.customStatement(
        'INSERT INTO port_forward_network_overrides (id, rule_id, network_id, state, created_at, updated_at) '
        "VALUES (?, ?, 'home', 'on', 0, 0)",
        ['o-$id', id],
      );
    }

    await rule('theirs', autoStart: false);
    await rule('mine', autoStart: true);
    final started = await team.portForwardRulesDao.getAutoStartRulesForNetwork('h1', 'home');
    expect(started.map((r) => r.id), ['mine']);
  });

  test('with no choice made, a forward starts as it was set to', () async {
    expect(await starting('office'), {'always'});
    expect(await starting('home'), {'always', 'homeOnly'});
    expect(await starting(null), {'always'});
  });

  test('Off on a network never starts it there; On starts it there; Inherit is as it was set', () async {
    await set('always', 'office', PortForwardNetworkState.off);
    await set('byHand', 'office', PortForwardNetworkState.on);
    await set('homeOnly', 'office', PortForwardNetworkState.on);
    expect(await starting('office'), {'byHand', 'homeOnly'});
    expect(await starting('home'), {'always', 'homeOnly'}, reason: 'another network is not changed');

    await set('always', 'office', PortForwardNetworkState.inherit);
    expect(await starting('office'), {'always', 'byHand', 'homeOnly'});
  });
}
