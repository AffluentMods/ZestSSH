import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/hostkeys/team_host_keys.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/services/ssh_service.dart';

import '../../helpers/orchard_db_fixture.dart';

/// Team-pinned host keys (3.0): one pin per endpoint and jump
/// route in each Crate, written as known hosts write hosts, which counts
/// only for the hosts of its own Crate; a pin matches only the same encoded
/// key; pinning again replaces what was pinned there; every pin of an
/// endpoint in a Crate is listed, whatever its route, the direct one first,
/// with the jump host each is for; the Tree has none.

/// A Crate where this account may only connect: someone else edits it.
const _staging = '55555555-5555-4555-8555-555555555555';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  SSHHostKey key(int seed, {String type = 'ssh-ed25519'}) =>
      SSHHostKey(type: type, bytes: Uint8List.fromList(List<int>.generate(40, (i) => (seed * 7 + i) & 0xff)));

  /// An Orchard as its owner has it (Fixture, every switch), with Staging beside it.
  Future<AppDatabase> orchard() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    addTearDown(db.close);
    await seedOrchardAsOwner(db);
    await db.customStatement(
        "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, 'Staging', 'connect', ?, 1)",
        [_staging, jsonEncode(switchList(levelSwitches(CrateLevel.connect)))]);
    return db;
  }

  /// A pin of [host]:22 through [viaScope], as another device's sync leaves it, in [crate]: under [id], else the key
  /// a pin there has. Its key.
  Future<String> synced(AppDatabase db, String host, SSHHostKey k, String crate, {String? viaScope, String? id}) async {
    final itemKey = id ?? teamHostKeyId(host, 22, viaScope, crateId: crate);
    await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
    await db.customStatement('INSERT INTO team_host_keys (id, host, port, via_scope, host_keys) VALUES (?, ?, 22, ?, ?)',
        [itemKey, host, viaScope ?? '', jsonEncode([hostKeyLine(k)])]);
    await db.customStatement(
        "INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('hostkey', ?, ?, 1)",
        [itemKey, crate]);
    await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
    return itemKey;
  }

  Future<List<String>> ids(AppDatabase db) async =>
      [for (final r in await db.customSelect('SELECT id FROM team_host_keys ORDER BY id').get()) r.read<String>('id')];

  test('one pin per endpoint and route in each Crate, the host written as known hosts write it', () {
    expect(teamHostKeyId('Web1.Example.com.', 22, null, crateId: kFixtureCrateId), 'web1.example.com|22||$kFixtureCrateId');
    expect(teamHostKeyId('[::1]', 2222, 'bastion', crateId: _staging), '::1|2222|bastion|$_staging');
    expect(teamHostKeyId('web1', 22, null, crateId: _staging),
        isNot(teamHostKeyId('web1', 22, null, crateId: kFixtureCrateId)), reason: 'each Crate its own');
    expect(hostKeyLine(key(1, type: 'rsa-sha2-512')), startsWith('ssh-rsa '), reason: 'RSA by its key type');
  });

  test('a pin matches only the same key; pinning again replaces it; no pins in the Tree', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    addTearDown(db.close);
    await seedOrchardAsOwner(db);
    final pins = TeamHostKeys(db);
    expect(await pins.pinFor('web1', 22, crateId: kFixtureCrateId), isNull);
    await pins.pin('Web1', 22, key(1), crateId: kFixtureCrateId);
    var pin = (await pins.pinFor('web1.', 22, crateId: kFixtureCrateId))!;
    expect(pin.matches(key(1)), isTrue);
    expect(pin.matches(key(2)), isFalse);
    expect(pin.crateId, kFixtureCrateId);
    expect(pin.fingerprint, startsWith('SHA256:'));
    expect(await pins.pinFor('web1', 22, viaScope: 'bastion', crateId: kFixtureCrateId), isNull, reason: 'another route');
    expect(await pins.pinFor('web1', 22, crateId: null), isNull, reason: 'a host in no Crate');
    await pins.pin('web1', 22, key(2), crateId: kFixtureCrateId);
    pin = (await pins.pinFor('web1', 22, crateId: kFixtureCrateId))!;
    expect([pin.matches(key(1)), pin.matches(key(2))], [false, true]);
    expect(await ids(db), [teamHostKeyId('web1', 22, null, crateId: kFixtureCrateId)], reason: 'replaced, not added');
    expect(await pins.mayPinIn(kFixtureCrateId), isTrue);
    expect(await pins.mayPinIn(null), isFalse);

    final tree = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(tree.close);
    expect(await TeamHostKeys(tree).pinFor('web1', 22, crateId: kFixtureCrateId), isNull);
  });

  test('every pin of an endpoint, whatever its route: the direct one first; none of another endpoint; none in the Tree',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    addTearDown(db.close);
    await seedOrchardAsOwner(db);
    final pins = TeamHostKeys(db);
    expect(await pins.pinsOf('web1', 22, crateId: kFixtureCrateId), isEmpty);
    // As sessions pin them: through a jump host saved by its address, through
    // one kept by its id, and directly; then another port and another host.
    await pins.pin('web1', 22, key(2), viaScope: 'bastion.example.com:22', crateId: kFixtureCrateId);
    await pins.pin('web1', 22, key(3), viaScope: 'via:3f6c2a90-1b2d-4e5f-8a9b-0c1d2e3f4a5b', crateId: kFixtureCrateId);
    await pins.pin('Web1.', 22, key(1), crateId: kFixtureCrateId);
    await pins.pin('web1', 2222, key(4), crateId: kFixtureCrateId);
    await pins.pin('web2', 22, key(5), viaScope: 'bastion.example.com:22', crateId: kFixtureCrateId);
    final all = await pins.pinsOf('WEB1.', 22, crateId: kFixtureCrateId);
    expect([for (final p in all) p.viaScope], ['', 'bastion.example.com:22', 'via:3f6c2a90-1b2d-4e5f-8a9b-0c1d2e3f4a5b']);
    expect([for (final p in all) p.id], [
      teamHostKeyId('web1', 22, null, crateId: kFixtureCrateId),
      teamHostKeyId('web1', 22, 'bastion.example.com:22', crateId: kFixtureCrateId),
      teamHostKeyId('web1', 22, 'via:3f6c2a90-1b2d-4e5f-8a9b-0c1d2e3f4a5b', crateId: kFixtureCrateId),
    ]);
    expect([for (final p in all) p.matches(key(1))], [true, false, false]);
    expect([for (final p in all) p.matches(key(2))], [false, true, false]);
    expect([for (final p in all) p.matches(key(3))], [false, false, true]);
    expect([for (final p in all) p.crateId], [kFixtureCrateId, kFixtureCrateId, kFixtureCrateId]);
    expect([for (final p in all) p.jumpHost], [null, 'bastion.example.com:22', null]);
    // Each is the one a session through its route finds.
    for (final p in all) {
      expect((await pins.pinFor('web1', 22, viaScope: p.viaScope.isEmpty ? null : p.viaScope, crateId: kFixtureCrateId))!.id,
          p.id);
    }
    // Removed, it is no longer listed; the others are.
    await pins.unpin(all[1].id);
    expect([for (final p in await pins.pinsOf('web1', 22, crateId: kFixtureCrateId)) p.id], [all[0].id, all[2].id]);
    expect(await pins.pinsOf('web1', 22, crateId: null), isEmpty, reason: 'a host in no Crate');

    final tree = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(tree.close);
    expect(await TeamHostKeys(tree).pinsOf('web1', 22, crateId: kFixtureCrateId), isEmpty);
  });

  // A pin's key named its endpoint and route, not its Crate, and it counted
  // for every host at that address: someone who may edit one Crate could pin
  // a key for the address of another Crate's host, and every member of both
  // went by it there; and the other Crate could not pin the address for
  // itself (the write reached the first Crate's pin, which the guard refused).
  test("a pin counts only for the hosts of its own Crate: another Crate's pin of the same address is not theirs, and "
      'each Crate pins it for itself', () async {
    final db = await orchard();
    final pins = TeamHostKeys(db);
    // Someone who may edit Staging pinned web1:22.
    final staging = await synced(db, 'web1', key(1), _staging);
    expect(await pins.pinFor('web1', 22, crateId: kFixtureCrateId), isNull, reason: "not the pin of Fixture's hosts");
    expect(await pins.pinsOf('web1', 22, crateId: kFixtureCrateId), isEmpty);
    expect((await pins.pinFor('web1', 22, crateId: _staging))!.id, staging);
    expect([for (final p in await pins.pinsOf('web1', 22, crateId: _staging)) p.id], [staging]);

    // Someone who may edit Fixture pins it there: a pin of its own; Staging's is untouched.
    await pins.pin('web1', 22, key(2), crateId: kFixtureCrateId);
    final fixture = (await pins.pinFor('web1', 22, crateId: kFixtureCrateId))!;
    expect((fixture.id, fixture.crateId), (teamHostKeyId('web1', 22, null, crateId: kFixtureCrateId), kFixtureCrateId));
    expect([fixture.matches(key(1)), fixture.matches(key(2))], [false, true]);
    var kept = (await pins.pinFor('web1', 22, crateId: _staging))!;
    expect([kept.id == staging, kept.matches(key(1)), kept.matches(key(2))], [true, true, false]);
    expect([for (final p in await pins.pinsOf('web1', 22, crateId: kFixtureCrateId)) p.id], [fixture.id]);
    expect([for (final p in await pins.pinsOf('web1', 22, crateId: _staging)) p.id], [staging]);

    // Pinned again, Fixture's own is replaced, and only it.
    await pins.pin('web1', 22, key(3), crateId: kFixtureCrateId);
    expect((await pins.pinFor('web1', 22, crateId: kFixtureCrateId))!.matches(key(3)), isTrue);
    kept = (await pins.pinFor('web1', 22, crateId: _staging))!;
    expect([kept.matches(key(1)), kept.matches(key(3))], [true, false]);
    expect(await ids(db), [fixture.id, staging]..sort());

    // Removed, Fixture's goes; Staging's stays.
    await pins.unpin(fixture.id);
    expect(await pins.pinFor('web1', 22, crateId: kFixtureCrateId), isNull);
    expect((await pins.pinFor('web1', 22, crateId: _staging))!.id, staging);
  });

  test('a pin kept under the key of another Crate, or of another endpoint, counts for no host', () async {
    final db = await orchard();
    final pins = TeamHostKeys(db);
    // In Staging, under the key of a pin for Fixture's hosts at web1.
    await synced(db, 'web1', key(1), _staging, id: teamHostKeyId('web1', 22, null, crateId: kFixtureCrateId));
    // In Fixture, a pin of web2 under the key of one for web3.
    await synced(db, 'web2', key(2), kFixtureCrateId, id: teamHostKeyId('web3', 22, null, crateId: kFixtureCrateId));
    for (final crate in [kFixtureCrateId, _staging]) {
      for (final host in ['web1', 'web2', 'web3']) {
        expect(await pins.pinFor(host, 22, crateId: crate), isNull, reason: '$host, $crate');
        expect(await pins.pinsOf(host, 22, crateId: crate), isEmpty, reason: '$host, $crate');
      }
    }
  });

  test('a pin made before pins carried their Crate counts for the hosts of the Crate it is in, and is replaced there',
      () async {
    final db = await orchard();
    final pins = TeamHostKeys(db);
    // Kept by its endpoint and route alone, as pins were.
    final before = await synced(db, 'web1', key(1), _staging, id: 'web1|22|');
    final through = await synced(db, 'web2', key(2), kFixtureCrateId,
        viaScope: 'bastion.example.com:22', id: 'web2|22|bastion.example.com:22');
    expect(await pins.pinFor('web1', 22, crateId: kFixtureCrateId), isNull, reason: 'in Staging, not Fixture');
    expect(await pins.pinsOf('web1', 22, crateId: kFixtureCrateId), isEmpty);
    expect((await pins.pinFor('web1', 22, crateId: _staging))!.id, before);
    expect([for (final p in await pins.pinsOf('web1', 22, crateId: _staging)) p.id], [before]);
    expect((await pins.pinFor('web2', 22, viaScope: 'bastion.example.com:22', crateId: kFixtureCrateId))!.id, through);
    expect(await pins.pinFor('web2', 22, crateId: kFixtureCrateId), isNull, reason: 'another route');

    // Pinned again in its Crate, it is replaced where it is: no second pin for the route.
    await pins.pin('web2', 22, key(3), viaScope: 'bastion.example.com:22', crateId: kFixtureCrateId);
    final replaced = (await pins.pinFor('web2', 22, viaScope: 'bastion.example.com:22', crateId: kFixtureCrateId))!;
    expect([replaced.id == through, replaced.matches(key(3))], [true, true]);
    expect(await ids(db), [before, through]..sort());

    // Beside one made since (on a device that had not had the old one yet), the one made since is what counts.
    final since = await synced(db, 'web1', key(4), _staging);
    final found = (await pins.pinFor('web1', 22, crateId: _staging))!;
    expect([found.id == since, found.matches(key(4))], [true, true]);
  });

  test('the Crate whose pins count for a host: the one it is in; none for a host this database does not have',
      () async {
    final db = await orchard();
    final at = DateTime(2026, 10, 18);
    // As the sync engine leaves a host of Staging; then one made on this device, in no Crate yet.
    await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'h-staging', label: 'staging', host: 'web1', createdAt: at, updatedAt: at));
    await db.customStatement(
        "INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('host', 'h-staging', ?, 1)",
        [_staging]);
    await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'h-new', label: 'new', host: 'web1', createdAt: at, updatedAt: at));
    final pins = TeamHostKeys(db);
    expect(await pins.crateOfHost('h-staging'), _staging);
    expect(await pins.crateOfHost('h-new'), kFixtureCrateId, reason: 'where new items go');
    expect(await pins.crateOfHost('h-elsewhere'), isNull, reason: 'a host of another space');
  });

  test('the jump host a route names, as that host was saved', () {
    TeamHostKeyPin through(String route) =>
        TeamHostKeyPin(id: 'web1|22|$route', host: 'web1', port: 22, viaScope: route, keys: const [], crateId: null);
    expect(through('').jumpHost, isNull, reason: 'direct');
    expect(through('bastion.example.com:22').jumpHost, 'bastion.example.com:22');
    expect(through('2001:db8::10:2222').jumpHost, '[2001:db8::10]:2222', reason: 'IPv6, in brackets');
    expect(through('via:3f6c2a90-1b2d-4e5f-8a9b-0c1d2e3f4a5b').jumpHost, isNull, reason: 'kept by its id');
    expect(through('via:42').jumpHost, isNull, reason: 'kept by its id, of figures');
    expect(through('bastion').jumpHost, isNull, reason: 'no port');
    expect(through(':22').jumpHost, isNull, reason: 'no host');
    expect(through('bastion:70000').jumpHost, isNull, reason: 'no port there is');
  });
}
