import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/move/item_transfer.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/services/identity_secret_store.dart';

/// Move to... and Copy to... (3.4): items between Personal and the vaults of
/// teams, re-made where they land as saving them there makes them (the
/// team's database, its vault, its outbox), with what they use asked about,
/// and each team's rules kept (add where they land, delete where they leave,
/// a key's secrets only for who may see them, a team's items out of it only
/// as an export lets them).

const _acme = '0c2f8a6e-5b1d-4d3a-9f47-2a61c0e9b7d3';
const _prod = '2e4a0c8a-7d3f-4f5c-9a69-4c83e2a1d9f5';
const _staging = '3f5b1d9b-8e4a-4a6d-8b7a-5d94f3b2eaa6';
const _ro = '4a6c2e0c-9f5b-4b7e-8c8b-6ea5a4c3fbb7';
const _globex = '5b7d3f1d-0a6c-4c8f-9d9c-7fb6b5d4acc8';
const _gx = '6c8e4a2e-1b7d-4d9a-8eaa-8ac7c6e5bdd9';

final _all = {...CrateSwitches.all};
const _readOnly = {CrateSwitches.connect, CrateSwitches.sftp, CrateSwitches.forward};
const _addOnly = {CrateSwitches.connect, CrateSwitches.reveal, CrateSwitches.add, CrateSwitches.edit};

Future<void> _seedTeam(AppDatabase db, String orchardId, String name,
    {String role = 'owner', required Map<String, Set<String>> crates, Map<String, Object?> rules = const {}}) async {
  await db.customStatement(
    'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id, can, rules) '
    'VALUES (1, ?, ?, ?, 1, ?, ?, ?)',
    [orchardId, name, role, crates.keys.first, jsonEncode(RoleCan.all.toList()..sort()), jsonEncode(rules)],
  );
  for (final e in crates.entries) {
    await db.customStatement(
      'INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, ?, ?, ?, 1)',
      [e.key, 'Vault ${e.key.substring(0, 4)}', 'manage', jsonEncode(e.value.toList()..sort())],
    );
  }
}

Future<void> _host(AppDatabase db, String id,
    {String? identity, String? via, String? snippet, String? group, String protocol = 'ssh'}) async {
  final now = DateTime(2026, 11, 1);
  await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: id,
        label: 'label-$id',
        host: '10.0.0.$id'.replaceAll(RegExp('[^0-9.]'), '1'),
        identityId: Value(identity),
        connectViaId: Value(via),
        snippetId: Value(snippet),
        groupId: Value(group),
        protocol: Value(protocol),
        createdAt: now,
        updatedAt: now,
      ));
}

Future<void> _key(AppDatabase db, String id) async {
  await db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: id,
        label: 'key-$id',
        username: 'deploy',
        authMethod: 'publicKey',
        createdAt: DateTime(2026, 11, 1),
      ));
}

Future<List<String>> _ids(AppDatabase db, String table, {String column = 'id'}) async =>
    [for (final r in await db.customSelect('SELECT "$column" AS k FROM $table ORDER BY "$column"').get()) r.read<String>('k')];

Future<int> _outbox(AppDatabase db, String kind) async =>
    (await db.customSelect('SELECT COUNT(*) AS n FROM crate_outbox WHERE kind = ?', variables: [Variable(kind)]).getSingle())
        .read<int>('n');

/// Marks [key] as a copy its vault holds (it reached the server).
Future<void> _onServer(AppDatabase db, String kind, String key, String crate) => db.customStatement(
      'INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision, edited_at) VALUES (?, ?, ?, 1, 1) '
      'ON CONFLICT(kind, item_key) DO UPDATE SET server_revision = 1',
      [kind, key, crate],
    );

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase tree;
  late AppDatabase acme;
  late AppDatabase globex;
  late ItemTransfer transfer;
  const storage = FlutterSecureStorage();
  var n = 0;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    acme = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    globex = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    await _seedTeam(acme, _acme, 'Acme', crates: {_prod: _all, _staging: _all, _ro: _readOnly});
    await _seedTeam(globex, _globex, 'Globex', crates: {_gx: _all});
    n = 0;
    transfer = ItemTransfer(
      tree: tree,
      openTeam: (id) async => id == _acme ? acme : globex,
      storage: storage,
      newId: () => 'new-${++n}',
    );
  });

  tearDown(() async {
    await tree.close();
    await acme.close();
    await globex.close();
  });

  group('hosts', () {
    test('Copy from Personal to a team: the source keeps it, the vault gets a new one, queued to be sealed', () async {
      await _host(tree, 'h1');
      final plan = await transfer.plan(
          from: const TreeSpace(), kind: 'host', keys: ['h1'], to: const SavePlace.vault(_acme, _staging), mode: TransferMode.copy);
      expect(plan.readyCount, 1);
      expect(plan.links, isEmpty);
      final result = await transfer.run(plan);
      expect(result.done, 1);
      expect(result.failed, isEmpty);
      expect(await _ids(tree, 'connections'), ['h1']);
      final copy = result.newKeys['h1']!;
      expect(await _ids(acme, 'connections'), [copy]);
      expect(await CratePlacement(acme).crateOf('host', copy), _staging);
      expect(await _outbox(acme, 'host'), 1);
    });

    test('Move from Personal to a team: it leaves Personal (with the mark that deletes it on other devices)', () async {
      await _host(tree, 'h1');
      final plan = await transfer.plan(
          from: const TreeSpace(), kind: 'host', keys: ['h1'], to: const SavePlace.vault(_acme, _prod), mode: TransferMode.move);
      final result = await transfer.run(plan);
      expect(result.done, 1);
      expect(await _ids(tree, 'connections'), isEmpty);
      expect(await _ids(tree, 'tombstones', column: 'entity_id'), contains('h1'));
      expect(await _ids(acme, 'connections'), [result.newKeys['h1']]);
    });

    test('Move from a team to Personal: the team queues its deletion', () async {
      await _host(acme, 'h1');
      await _onServer(acme, 'host', 'h1', _prod);
      final plan = await transfer.plan(
          from: const OrchardSpace(_acme), kind: 'host', keys: ['h1'], to: const SavePlace.personal(), mode: TransferMode.move);
      final result = await transfer.run(plan);
      expect(result.done, 1);
      expect(await _ids(acme, 'connections'), isEmpty);
      expect(await _outbox(acme, 'host'), 1);
      expect(await _ids(tree, 'connections'), [result.newKeys['h1']]);
    });

    test('Copy from one team to another', () async {
      await _host(acme, 'h1');
      final plan = await transfer.plan(
          from: const OrchardSpace(_acme), kind: 'host', keys: ['h1'], to: const SavePlace.vault(_globex, _gx), mode: TransferMode.copy);
      final result = await transfer.run(plan);
      expect(result.done, 1);
      expect(await _ids(acme, 'connections'), ['h1']);
      expect(await _ids(globex, 'connections'), [result.newKeys['h1']]);
      expect(await CratePlacement(globex).crateOf('host', result.newKeys['h1']!), _gx);
    });

    test("a team's shared SFTP bookmarks go with a host to another team, never into Personal", () async {
      const shared = '[{"label":"Service","path":"/opt/x/service"}]';
      await _host(acme, 'h1');
      await acme.connectionsDao.setSharedPins('h1', shared);
      final toTeam = await transfer.run(await transfer.plan(
          from: const OrchardSpace(_acme), kind: 'host', keys: ['h1'], to: const SavePlace.vault(_globex, _gx), mode: TransferMode.copy));
      expect((await globex.connectionsDao.getById(toTeam.newKeys['h1']!))!.sharedPins, shared);

      final toMe = await transfer.run(await transfer.plan(
          from: const OrchardSpace(_acme), kind: 'host', keys: ['h1'], to: const SavePlace.personal(), mode: TransferMode.copy));
      expect(toMe.done, 1);
      expect((await tree.connectionsDao.getById(toMe.newKeys['h1']!))!.sharedPins, isNull);
    });

    test('Move between the vaults of one team keeps the host and changes its vault', () async {
      await _host(acme, 'h1');
      await CratePlacement(acme).place('host', 'h1', _prod);
      final plan = await transfer.plan(
          from: const OrchardSpace(_acme), kind: 'host', keys: ['h1'], to: const SavePlace.vault(_acme, _staging), mode: TransferMode.move);
      expect(plan.sameDatabase, isTrue);
      final result = await transfer.run(plan);
      expect(result.done, 1);
      expect(await _ids(acme, 'connections'), ['h1']);
      expect(await CratePlacement(acme).crateOf('host', 'h1'), _staging);
    });

    test('Copy between the vaults of one team: a new host beside it, its key kept as it is', () async {
      await _key(acme, 'k1');
      await _host(acme, 'h1', identity: 'k1');
      final plan = await transfer.plan(
          from: const OrchardSpace(_acme), kind: 'host', keys: ['h1'], to: const SavePlace.vault(_acme, _staging), mode: TransferMode.copy);
      expect(plan.links, isEmpty);
      final result = await transfer.run(plan);
      final copy = result.newKeys['h1']!;
      expect(await _ids(acme, 'connections'), unorderedEquals(['h1', copy]));
      final row = await (acme.select(acme.connections)..where((c) => c.id.equals(copy))).getSingle();
      expect(row.identityId, 'k1');
      expect(await CratePlacement(acme).crateOf('host', copy), _staging);
    });

    test('the place it is already in is no move and no failure', () async {
      await _host(acme, 'h1');
      await CratePlacement(acme).place('host', 'h1', _prod);
      final plan = await transfer.plan(
          from: const OrchardSpace(_acme), kind: 'host', keys: ['h1'], to: const SavePlace.vault(_acme, _prod), mode: TransferMode.move);
      expect(plan.readyCount, 0);
      expect(plan.problems, isEmpty);
      final result = await transfer.run(plan);
      expect(result.failed, isEmpty);
    });

    test('carries its port forwards and tags with it', () async {
      await _host(tree, 'h1');
      await tree.connectionTagsDao.setTagsForConnection('h1', ['web']);
      await tree.into(tree.portForwardRules).insert(PortForwardRulesCompanion.insert(
          id: 'f1', connectionId: 'h1', type: 'local', bindPort: 8080, remoteHost: 'db', remotePort: 5432, createdAt: DateTime(2026)));
      final plan = await transfer.plan(
          from: const TreeSpace(), kind: 'host', keys: ['h1'], to: const SavePlace.vault(_acme, _prod), mode: TransferMode.move);
      final result = await transfer.run(plan);
      final h = result.newKeys['h1']!;
      expect(await acme.connectionTagsDao.getTagsForConnection(h), ['web']);
      final forwards = await acme.portForwardRulesDao.getByConnection(h);
      expect(forwards, hasLength(1));
      expect(await CratePlacement(acme).crateOf('forward', forwards.single.id), _prod);
      expect(await _ids(tree, 'port_forward_rules'), isEmpty);
    });

    test('a group of the same name is used where it lands, else one like it is made', () async {
      await tree.connectionGroupsDao.insertGroup(
          ConnectionGroupsCompanion.insert(id: 'g1', name: 'Prod', createdAt: DateTime(2026)));
      await tree.connectionGroupsDao.insertGroup(
          ConnectionGroupsCompanion.insert(id: 'g2', name: 'Lab', createdAt: DateTime(2026)));
      await acme.connectionGroupsDao.insertGroup(
          ConnectionGroupsCompanion.insert(id: 'ag', name: 'prod', createdAt: DateTime(2026)));
      await _host(tree, 'h1', group: 'g1');
      await _host(tree, 'h2', group: 'g2');
      final result = await transfer.run(await transfer.plan(
          from: const TreeSpace(), kind: 'host', keys: ['h1', 'h2'], to: const SavePlace.vault(_acme, _prod), mode: TransferMode.copy));
      final h1 = await (acme.select(acme.connections)..where((c) => c.id.equals(result.newKeys['h1']!))).getSingle();
      final h2 = await (acme.select(acme.connections)..where((c) => c.id.equals(result.newKeys['h2']!))).getSingle();
      expect(h1.groupId, 'ag');
      final lab = await (acme.select(acme.connectionGroups)..where((g) => g.id.equals(h2.groupId!))).getSingle();
      expect(lab.name, 'Lab');
      expect(await CratePlacement(acme).crateOf('group', lab.id), _prod);
    });
  });

  group('rights', () {
    test('a vault where this account may not add takes nothing', () async {
      await _host(tree, 'h1');
      final plan = await transfer.plan(
          from: const TreeSpace(), kind: 'host', keys: ['h1'], to: const SavePlace.vault(_acme, _ro), mode: TransferMode.copy);
      expect(plan.readyCount, 0);
      expect(plan.problems.single.reason, TransferRefusal.mayNotAdd);
      final result = await transfer.run(plan);
      expect(result.done, 0);
      expect(await _ids(acme, 'connections'), isEmpty);
      expect(await _ids(tree, 'connections'), ['h1']);
    });

    test('Move without delete where it leaves is refused; Copy is not', () async {
      await acme.customStatement('UPDATE orchard_crates SET switches = ? WHERE crate_id = ?',
          [jsonEncode(_addOnly.toList()), _staging]);
      await _host(acme, 'h1');
      await CratePlacement(acme).place('host', 'h1', _staging);
      await _onServer(acme, 'host', 'h1', _staging);
      final move = await transfer.plan(
          from: const OrchardSpace(_acme), kind: 'host', keys: ['h1'], to: const SavePlace.vault(_acme, _prod), mode: TransferMode.move);
      expect(move.problems.single.reason, TransferRefusal.mayNotRemove);
      final copy = await transfer.plan(
          from: const OrchardSpace(_acme), kind: 'host', keys: ['h1'], to: const SavePlace.vault(_acme, _prod), mode: TransferMode.copy);
      expect(copy.readyCount, 1);
    });

    test('Move from a team to Personal without delete there is refused, and nothing is written', () async {
      await acme.customStatement('UPDATE orchard_crates SET switches = ? WHERE crate_id = ?',
          [jsonEncode(_addOnly.toList()), _prod]);
      await _host(acme, 'h1');
      await _onServer(acme, 'host', 'h1', _prod);
      final plan = await transfer.plan(
          from: const OrchardSpace(_acme), kind: 'host', keys: ['h1'], to: const SavePlace.personal(), mode: TransferMode.move);
      expect(plan.problems.single.reason, TransferRefusal.mayNotRemove);
      await transfer.run(plan);
      expect(await _ids(tree, 'connections'), isEmpty);
      expect(await _ids(acme, 'connections'), ['h1']);
    });

    test('a team\'s items leave it only as its owners take them, and not where its rules say no export', () async {
      final member = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
      addTearDown(member.close);
      await _seedTeam(member, _acme, 'Acme', role: 'admin', crates: {_prod: _all});
      await _host(member, 'h1');
      final t = ItemTransfer(tree: tree, openTeam: (_) async => member, storage: storage);
      final out = await t.plan(
          from: const OrchardSpace(_acme), kind: 'host', keys: ['h1'], to: const SavePlace.personal(), mode: TransferMode.copy);
      expect(out.problems.single.reason, TransferRefusal.ownersOnly);

      await acme.customStatement('UPDATE orchard_info SET rules = ?', [jsonEncode({'no_export': true})]);
      await _host(acme, 'h2');
      final kept = await transfer.plan(
          from: const OrchardSpace(_acme), kind: 'host', keys: ['h2'], to: const SavePlace.personal(), mode: TransferMode.copy);
      expect(kept.problems.single.reason, TransferRefusal.teamKeepsItems);
    });

    test('the rules are read again as the plan runs: a sync between the plan and the run that turns on no export, '
        'takes the owner\'s role or a vault\'s add stops what may no longer go', () async {
      await _host(acme, 'h1');
      final plan = await transfer.plan(
          from: const OrchardSpace(_acme), kind: 'host', keys: ['h1'], to: const SavePlace.personal(), mode: TransferMode.copy);
      expect(plan.problems, isEmpty);
      await acme.customStatement('UPDATE orchard_info SET rules = ?', [jsonEncode({'no_export': true})]);
      final result = await transfer.run(plan);
      expect(result.done, 0);
      expect(result.failed.single.reason, TransferRefusal.teamKeepsItems);
      expect(await _ids(tree, 'connections'), isEmpty, reason: 'nothing left the team');

      await acme.customStatement('UPDATE orchard_info SET rules = ?', [jsonEncode(const {})]);
      final again = await transfer.plan(
          from: const OrchardSpace(_acme), kind: 'host', keys: ['h1'], to: const SavePlace.personal(), mode: TransferMode.copy);
      await acme.customStatement("UPDATE orchard_info SET role = 'admin'");
      expect((await transfer.run(again)).failed.single.reason, TransferRefusal.ownersOnly);

      await _host(tree, 'p1');
      final into = await transfer.plan(
          from: const TreeSpace(), kind: 'host', keys: ['p1'], to: const SavePlace.vault(_acme, _prod), mode: TransferMode.copy);
      await acme.customStatement('UPDATE orchard_crates SET switches = ? WHERE crate_id = ?',
          [jsonEncode(_readOnly.toList()..sort()), _prod]);
      expect((await transfer.run(into)).failed.single.reason, TransferRefusal.mayNotAdd);
      expect(await _ids(acme, 'connections'), ['h1'], reason: 'nothing arrived');
    });

    test('a batch with one refused item moves the rest and names the one', () async {
      await _host(tree, 'h1');
      await _host(tree, 'h2', protocol: 'localShell');
      await _host(tree, 'h3');
      final plan = await transfer.plan(
          from: const TreeSpace(), kind: 'host', keys: ['h1', 'h2', 'h3'], to: const SavePlace.vault(_acme, _prod), mode: TransferMode.move);
      final result = await transfer.run(plan);
      expect(result.done, 2);
      expect(result.failed.single.key, 'h2');
      expect(result.failed.single.reason, TransferRefusal.localShellNotInTeam);
      expect(await _ids(tree, 'connections'), ['h2']);
      expect(await _ids(acme, 'connections'), hasLength(2));
    });
  });

  test('an FTPS host goes into a team as any host does (3.4): Move and Copy, its vault and its outbox', () async {
    await _host(tree, 'h1');
    await _host(tree, 'f1', protocol: 'ftps');
    await _host(tree, 'f2', protocol: 'ftpsImplicit');
    for (final mode in TransferMode.values) {
      final plan = await transfer.plan(
          from: const TreeSpace(), kind: 'host', keys: ['h1', 'f1', 'f2'], to: const SavePlace.vault(_acme, _prod), mode: mode);
      expect(plan.problems, isEmpty, reason: mode.name);
      expect(plan.readyCount, 3, reason: mode.name);
    }
    final result = await transfer.run(await transfer.plan(
        from: const TreeSpace(), kind: 'host', keys: ['h1', 'f1', 'f2'], to: const SavePlace.vault(_acme, _prod), mode: TransferMode.move));
    expect(result.done, 3);
    expect(result.failed, isEmpty);
    expect(await _ids(tree, 'connections'), isEmpty, reason: 'moved out of Personal');
    final protocols = [
      for (final r in await acme.customSelect('SELECT protocol FROM connections ORDER BY protocol').get()) r.read<String>('protocol'),
    ];
    expect(protocols, ['ftps', 'ftpsImplicit', 'ssh']);
    for (final key in result.newKeys.values) {
      expect(await CratePlacement(acme).crateOf('host', key), _prod);
    }
    expect(await _outbox(acme, 'host'), 3);
  });

  test('a remote screen goes into a team as any host does (4.0): its carrier is asked about as a jump host, '
      'goes along or is left, and its options go with it', () async {
    const options = '{"v":1,"target":"unix","socket":"~/.vnc/zest.sock"}';
    await _host(tree, 'gw');
    await _host(tree, 's1', via: 'gw', protocol: 'vnc');
    await tree.customStatement("UPDATE connections SET screen_options = ? WHERE id = 's1'", [options]);
    for (final mode in TransferMode.values) {
      final plan = await transfer.plan(
          from: const TreeSpace(), kind: 'host', keys: ['s1'], to: const SavePlace.vault(_acme, _prod), mode: mode);
      expect(plan.problems, isEmpty, reason: mode.name);
      expect({for (final l in plan.links) l.ref}, {const LinkRef(LinkKind.host, 'gw')}, reason: 'its carrier');
    }
    final result = await transfer.run(await transfer.plan(
        from: const TreeSpace(), kind: 'host', keys: ['s1'], to: const SavePlace.vault(_acme, _prod), mode: TransferMode.copy));
    expect(result.done, 1);
    final screen = await (acme.select(acme.connections)..where((c) => c.id.equals(result.newKeys['s1']!))).getSingle();
    expect(screen.protocol, 'vnc');
    expect(screen.screenOptions, options);
    final carrier = await (acme.select(acme.connections)..where((c) => c.id.equals(screen.connectViaId!))).getSingle();
    expect(carrier.label, 'label-gw', reason: 'the carrier went along');
    expect(carrier.protocol, 'ssh');
    expect(await CratePlacement(acme).crateOf('host', screen.id), _prod);
  });

  // Found in a security review: a screen that arrived with no carrier
  // would read as one reached directly, its address (as the carrier saw it)
  // dialled from the device instead.
  test("a remote screen whose carrier is left behind does not go: it stays where it is, said as its carrier's",
      () async {
    await _host(tree, 'gw');
    await _host(tree, 's1', via: 'gw', protocol: 'vnc');
    await _host(tree, 'h1', via: 'gw');
    for (final mode in [TransferMode.copy, TransferMode.move]) {
      final plan = await transfer.plan(
          from: const TreeSpace(), kind: 'host', keys: ['s1', 'h1'], to: const SavePlace.vault(_acme, _prod), mode: mode);
      final result = await transfer.run(plan, choices: {const LinkRef(LinkKind.host, 'gw'): LinkChoice.leave});
      expect(result.done, 1, reason: '${mode.name}: the SSH host goes, without its jump host, as before');
      final failed = result.failed.single;
      expect((failed.key, failed.reason, failed.link), ('s1', TransferRefusal.linkFailed, 'label-gw'), reason: mode.name);
      final arrived = await acme.select(acme.connections).get();
      expect(arrived.where((c) => c.protocol == 'vnc'), isEmpty, reason: mode.name);
      expect((await tree.connectionsDao.getById('s1'))?.connectViaId, 'gw', reason: '${mode.name}: left as it was');
    }
    expect(await tree.connectionsDao.getById('h1'), isNull, reason: 'the SSH host moved');
  });

  test('an FTPS host leaves a team as any host does: only as its owners take it, and not where its rules say no export',
      () async {
    final member = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    addTearDown(member.close);
    await _seedTeam(member, _acme, 'Acme', role: 'admin', crates: {_prod: _all});
    await _host(member, 'f1', protocol: 'ftps');
    final t = ItemTransfer(tree: tree, openTeam: (_) async => member, storage: storage);
    final out = await t.plan(
        from: const OrchardSpace(_acme), kind: 'host', keys: ['f1'], to: const SavePlace.personal(), mode: TransferMode.copy);
    expect(out.problems.single.reason, TransferRefusal.ownersOnly);

    await acme.customStatement('UPDATE orchard_info SET rules = ?', [jsonEncode({'no_export': true})]);
    await _host(acme, 'f2', protocol: 'ftpsImplicit');
    final kept = await transfer.plan(
        from: const OrchardSpace(_acme), kind: 'host', keys: ['f2'], to: const SavePlace.personal(), mode: TransferMode.copy);
    expect(kept.problems.single.reason, TransferRefusal.teamKeepsItems);

    // Into a vault where this account may not add: refused, as any host.
    await _host(tree, 'f3', protocol: 'ftps');
    final readOnly = await transfer.plan(
        from: const TreeSpace(), kind: 'host', keys: ['f3'], to: const SavePlace.vault(_acme, _ro), mode: TransferMode.copy);
    expect(readOnly.problems.single.reason, TransferRefusal.mayNotAdd);
  });

  group('keys', () {
    test('Personal to a team: its secrets go into the team\'s database, and leave the device\'s storage on Move', () async {
      await _key(tree, 'k1');
      final personal = IdentitySecretStore.forDatabase(tree, storage);
      await personal.write('k1', IdentitySecret.privateKey, 'PEM');
      await personal.write('k1', IdentitySecret.passphrase, 'words');
      final result = await transfer.run(await transfer.plan(
          from: const TreeSpace(), kind: 'key', keys: ['k1'], to: const SavePlace.vault(_acme, _prod), mode: TransferMode.move));
      final k = result.newKeys['k1']!;
      final team = OrchardIdentitySecrets(acme);
      expect(await team.read(k, IdentitySecret.privateKey), 'PEM');
      expect(await team.read(k, IdentitySecret.passphrase), 'words');
      expect(await personal.read('k1', IdentitySecret.privateKey), isNull);
      expect(await _ids(tree, 'identities'), isEmpty);
    });

    test('team to Personal Copy: the team keeps it, the device\'s storage gets its secrets', () async {
      await _key(acme, 'k1');
      await OrchardIdentitySecrets(acme).write('k1', IdentitySecret.password, 'pw');
      final result = await transfer.run(await transfer.plan(
          from: const OrchardSpace(_acme), kind: 'key', keys: ['k1'], to: const SavePlace.personal(), mode: TransferMode.copy));
      final k = result.newKeys['k1']!;
      expect(await IdentitySecretStore.forDatabase(tree, storage).read(k, IdentitySecret.password), 'pw');
      expect(await _ids(acme, 'identities'), ['k1']);
    });

    test('a key whose secrets this account may not see does not leave its vault', () async {
      await acme.customStatement('UPDATE orchard_crates SET switches = ? WHERE crate_id = ?',
          [jsonEncode(({..._all}..remove(CrateSwitches.reveal)).toList()), _prod]);
      await _key(acme, 'k1');
      final plan = await transfer.plan(
          from: const OrchardSpace(_acme), kind: 'key', keys: ['k1'], to: const SavePlace.vault(_acme, _staging), mode: TransferMode.copy);
      expect(plan.problems.single.reason, TransferRefusal.keySecretsHidden);
    });

    test('a team certificate belongs to its vault', () async {
      await acme.into(acme.identities).insert(IdentitiesCompanion.insert(
          id: 'c1', label: 'cert', username: 'u', authMethod: 'teamCertificate', createdAt: DateTime(2026)));
      final plan = await transfer.plan(
          from: const OrchardSpace(_acme), kind: 'key', keys: ['c1'], to: const SavePlace.vault(_globex, _gx), mode: TransferMode.copy);
      expect(plan.problems.single.reason, TransferRefusal.keyBelongsToVault);
    });
  });

  group('linked items', () {
    Future<TransferPlan> planHost(TransferMode mode) async {
      await _key(tree, 'k1');
      await IdentitySecretStore.forDatabase(tree, storage).write('k1', IdentitySecret.privateKey, 'PEM');
      await _host(tree, 'h1', identity: 'k1');
      await _host(tree, 'other', identity: 'k1');
      return transfer.plan(
          from: const TreeSpace(), kind: 'host', keys: ['h1'], to: const SavePlace.vault(_acme, _prod), mode: mode);
    }

    test('the key a host uses is asked about once, with who else uses it', () async {
      final plan = await planHost(TransferMode.move);
      final link = plan.links.single;
      expect(link.ref, const LinkRef(LinkKind.key, 'k1'));
      expect(link.label, 'key-k1');
      expect(link.choices, {LinkChoice.move, LinkChoice.copy, LinkChoice.leave});
      expect(link.usedElsewhere, 1);
      expect(link.suggested, LinkChoice.copy);
    });

    test('Copy it: the host uses the copy, Personal keeps the key', () async {
      final plan = await planHost(TransferMode.move);
      final result = await transfer.run(plan, choices: {const LinkRef(LinkKind.key, 'k1'): LinkChoice.copy});
      final host = await (acme.select(acme.connections)..where((c) => c.id.equals(result.newKeys['h1']!))).getSingle();
      final keys = await _ids(acme, 'identities');
      expect(keys, hasLength(1));
      expect(host.identityId, keys.single);
      expect(await OrchardIdentitySecrets(acme).read(keys.single, IdentitySecret.privateKey), 'PEM');
      expect(await _ids(tree, 'identities'), ['k1']);
    });

    test('Move it too: the key leaves Personal, and the host left there loses it', () async {
      final plan = await planHost(TransferMode.move);
      final result = await transfer.run(plan, choices: {const LinkRef(LinkKind.key, 'k1'): LinkChoice.move});
      expect(result.done, 1);
      expect(await _ids(tree, 'identities'), isEmpty);
      final other = await (tree.select(tree.connections)..where((c) => c.id.equals('other'))).getSingle();
      expect(other.identityId, isNull);
      expect(await IdentitySecretStore.forDatabase(tree, storage).read('k1', IdentitySecret.privateKey), isNull);
    });

    test('Leave it: the host is saved without the key', () async {
      final plan = await planHost(TransferMode.copy);
      final result = await transfer.run(plan, choices: {const LinkRef(LinkKind.key, 'k1'): LinkChoice.leave});
      final host = await (acme.select(acme.connections)..where((c) => c.id.equals(result.newKeys['h1']!))).getSingle();
      expect(host.identityId, isNull);
      expect(await _ids(acme, 'identities'), isEmpty);
    });

    test('a jump host and its own key are asked about; a host of the batch is not', () async {
      await _key(tree, 'jk');
      await _host(tree, 'jump', identity: 'jk');
      await _host(tree, 'a', via: 'jump');
      await _host(tree, 'b', via: 'a');
      final plan = await transfer.plan(
          from: const TreeSpace(), kind: 'host', keys: ['a', 'b'], to: const SavePlace.vault(_acme, _prod), mode: TransferMode.copy);
      expect({for (final l in plan.links) l.ref}, {const LinkRef(LinkKind.host, 'jump'), const LinkRef(LinkKind.key, 'jk')});
      final result = await transfer.run(plan);
      final b = await (acme.select(acme.connections)..where((c) => c.id.equals(result.newKeys['b']!))).getSingle();
      expect(b.connectViaId, result.newKeys['a']);
      final a = await (acme.select(acme.connections)..where((c) => c.id.equals(result.newKeys['a']!))).getSingle();
      final jump = await (acme.select(acme.connections)..where((c) => c.id.equals(a.connectViaId!))).getSingle();
      expect(jump.label, 'label-jump');
      expect(jump.identityId, isNotNull);
    });

    test('a key that may not leave its team is offered only as left', () async {
      final member = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
      addTearDown(member.close);
      await _seedTeam(member, _acme, 'Acme', crates: {_prod: _all, _staging: {..._all}..remove(CrateSwitches.reveal)});
      await _key(member, 'k1');
      await CratePlacement(member).place('key', 'k1', _staging);
      await _host(member, 'h1', identity: 'k1');
      final t = ItemTransfer(tree: tree, openTeam: (_) async => member, storage: storage);
      final plan = await t.plan(
          from: const OrchardSpace(_acme), kind: 'host', keys: ['h1'], to: const SavePlace.personal(), mode: TransferMode.copy);
      expect(plan.links.single.choices, {LinkChoice.leave});
      expect(plan.links.single.refusal, TransferRefusal.keySecretsHidden);
    });
  });

  group('port forwards and snippets', () {
    test('a port forward goes with its host or not at all', () async {
      await _host(tree, 'h1');
      await tree.into(tree.portForwardRules).insert(PortForwardRulesCompanion.insert(
          id: 'f1', connectionId: 'h1', type: 'local', bindPort: 8080, remoteHost: 'db', remotePort: 5432, createdAt: DateTime(2026)));
      final plan = await transfer.plan(
          from: const TreeSpace(), kind: 'forward', keys: ['f1'], to: const SavePlace.vault(_acme, _prod), mode: TransferMode.move);
      final link = plan.links.single;
      expect(link.ref, const LinkRef(LinkKind.host, 'h1'));
      expect(link.neededByForward, isTrue);

      final left = await transfer.run(plan, choices: {link.ref: LinkChoice.leave});
      expect(left.done, 0);
      expect(left.failed.single.reason, TransferRefusal.needsItsHost);
      expect(await _ids(tree, 'port_forward_rules'), ['f1']);
      expect(await _ids(acme, 'port_forward_rules'), isEmpty);

      final again = await transfer.plan(
          from: const TreeSpace(), kind: 'forward', keys: ['f1'], to: const SavePlace.vault(_acme, _prod), mode: TransferMode.move);
      final copied = await transfer.run(again, choices: {link.ref: LinkChoice.copy});
      expect(copied.done, 1);
      final f = await (acme.select(acme.portForwardRules)..where((r) => r.id.equals(copied.newKeys['f1']!))).getSingle();
      expect(await _ids(acme, 'connections'), [f.connectionId]);
      expect(await _ids(tree, 'port_forward_rules'), isEmpty);
      expect(await _ids(tree, 'connections'), ['h1']);
    });

    test('a snippet takes its category where that has none of the name', () async {
      await tree.into(tree.snippetCategories).insert(SnippetCategoriesCompanion.insert(name: 'Docker'));
      await tree.into(tree.snippets).insert(SnippetsCompanion.insert(
          id: 's1', label: 'ps', command: 'docker ps', category: const Value('Docker'), createdAt: DateTime(2026), updatedAt: DateTime(2026)));
      final result = await transfer.run(await transfer.plan(
          from: const TreeSpace(), kind: 'snippet', keys: ['s1'], to: const SavePlace.vault(_globex, _gx), mode: TransferMode.copy));
      expect(result.done, 1);
      expect(await _ids(globex, 'snippet_categories', column: 'name'), ['Docker']);
      expect(await CratePlacement(globex).crateOf('category', 'Docker'), _gx);
      expect(await _ids(tree, 'snippets'), ['s1']);
    });

    test('team to team Move of a snippet', () async {
      await acme.into(acme.snippets).insert(SnippetsCompanion.insert(
          id: 's1', label: 'up', command: 'uptime', createdAt: DateTime(2026), updatedAt: DateTime(2026)));
      final result = await transfer.run(await transfer.plan(
          from: const OrchardSpace(_acme), kind: 'snippet', keys: ['s1'], to: const SavePlace.vault(_globex, _gx), mode: TransferMode.move));
      expect(result.done, 1);
      expect(await _ids(acme, 'snippets'), isEmpty);
      expect(await _ids(globex, 'snippets'), [result.newKeys['s1']]);
    });
  });

  group('Save in (a new item)', () {
    test('a new Personal key made for a team never stays in Personal, its secrets with it', () async {
      final draft = await captureNewItem(tree, storage, 'key', () async {
        await _key(tree, 'new-key');
        await IdentitySecretStore.forDatabase(tree, storage).write('new-key', IdentitySecret.privateKey, 'PEM');
        return 'new-key';
      });
      expect(await _ids(tree, 'identities'), isEmpty);
      expect(await IdentitySecretStore.forDatabase(tree, storage).read('new-key', IdentitySecret.privateKey), isNull);
      expect(draft.secrets[IdentitySecret.privateKey], 'PEM');

      final result = await transfer.run(
          await transfer.planDraft(from: const TreeSpace(), draft: draft, to: const SavePlace.vault(_acme, _staging)));
      expect(result.done, 1);
      expect(await _ids(acme, 'identities'), ['new-key']);
      expect(await CratePlacement(acme).crateOf('key', 'new-key'), _staging);
      expect(await OrchardIdentitySecrets(acme).read('new-key', IdentitySecret.privateKey), 'PEM');
    });

    test('a new host made in a team for Personal is never queued in the team', () async {
      final draft = await captureNewItem(acme, storage, 'host', () async {
        await _host(acme, 'nh');
        return 'nh';
      });
      expect(await _ids(acme, 'connections'), isEmpty);
      expect(await _outbox(acme, 'host'), 0);
      final result =
          await transfer.run(await transfer.planDraft(from: const OrchardSpace(_acme), draft: draft, to: const SavePlace.personal()));
      expect(result.done, 1);
      expect(await _ids(tree, 'connections'), ['nh']);
    });

    test('a new host for another vault of the same team keeps its key as it is', () async {
      await _key(acme, 'k1');
      final draft = await captureNewItem(acme, storage, 'host', () async {
        await _host(acme, 'nh', identity: 'k1');
        return 'nh';
      });
      final plan = await transfer.planDraft(from: const OrchardSpace(_acme), draft: draft, to: const SavePlace.vault(_acme, _staging));
      expect(plan.links, isEmpty);
      await transfer.run(plan);
      final host = await (acme.select(acme.connections)..where((c) => c.id.equals('nh'))).getSingle();
      expect(host.identityId, 'k1');
      expect(await CratePlacement(acme).crateOf('host', 'nh'), _staging);
    });
  });
}
