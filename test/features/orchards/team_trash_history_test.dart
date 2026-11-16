import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

import 'fake_crate_server.dart';

/// The trash and version history of a Crate (3.0): what was
/// deleted comes back from the trash on any device of someone who may add
/// there, as their own change; version history shows only what changed
/// after an owner turned it on, to owners and those who manage the Crate,
/// and puts an earlier version back; every version is opened and checked
/// on the device, so one a server slips in, written by someone who could
/// not write there, is left out.

const _owner = 'owner-1';
const _alice = 'alice';

class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async => dbs.remove(orchardId);

  @override
  Future<List<String>> list() async => dbs.keys.toList();
}

class _Device {
  _Device(FakeCrateServer shared, this.uid, this.keys) : server = shared.as(uid) {
    service = OrchardService(
      server: server,
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: uid, keys: keys),
    );
    coordinator = OrchardSyncCoordinator(service: service, server: server, databases: service.databases);
  }

  final String uid;
  final AccountKeys keys;
  final CrateServer server;
  final storage = _MemoryStorage();
  late final OrchardService service;
  late final OrchardSyncCoordinator coordinator;

  Future<AppDatabase> db(String orchardId) => service.databases.open(orchardId);

  Future<void> close() async {
    for (final db in storage.dbs.values) {
      await db.close();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final keys = <String, AccountKeys>{};
  late FakeCrateServer server;
  final devices = <_Device>[];
  var now = DateTime.utc(2026, 9, 25, 12);

  setUpAll(() async {
    for (final uid in [_owner, _alice]) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    now = DateTime.utc(2026, 9, 25, 12);
    server = FakeCrateServer(accountUid: _owner)..clock = () => now;
    for (final uid in [_owner, _alice]) {
      await server.publish(uid, keys[uid]!, email: '$uid@example.com');
    }
  });

  tearDown(() async {
    for (final d in devices) {
      await d.close();
    }
    devices.clear();
  });

  _Device device(String uid) {
    final d = _Device(server, uid, keys[uid]!);
    devices.add(d);
    return d;
  }

  /// An Orchard of the owner's with alice in it (she may only use its Crate).
  Future<(String, String)> team(_Device owner, _Device alice) async {
    final id = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final crate = server.recordOf(id).roles.values.single.crates.keys.single;
    await owner.service.invite(id, email: 'alice@example.com', role: server.recordOf(id).roles.values.single.id);
    server.acceptAs(id, (await owner.service.invites(id)).single.id, _alice);
    await owner.service.confirmInvite(id, (await owner.service.invites(id)).single);
    await alice.coordinator.syncAll();
    return (id, crate);
  }

  Future<void> addHost(AppDatabase db, String id, String label) => db.customStatement(
      "INSERT INTO connections (id, label, host, port, created_at, updated_at) VALUES (?, ?, 'web1.example.com', 22, 0, 0)",
      [id, label]);
  Future<void> rename(AppDatabase db, String id, String label) =>
      db.customStatement('UPDATE connections SET label = ? WHERE id = ?', [label, id]);
  Future<String?> labelOf(AppDatabase db, String id) async =>
      (await db.customSelect('SELECT label FROM connections WHERE id = ?', variables: [Variable(id)]).getSingleOrNull())
          ?.read<String>('label');

  test('deleted, then brought back from the trash on another device, as that device\'s own change', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    final db = await owner.db(id);

    await addHost(db, 'web1', 'Web 1');
    await owner.coordinator.syncAll();
    await rename(db, 'web1', 'Web One');
    await owner.coordinator.syncAll();
    now = now.add(const Duration(hours: 1));
    await db.customStatement("DELETE FROM connections WHERE id = 'web1'");
    expect((await owner.coordinator.syncAll())[id]!.sent, 1);
    final noted = await db.customSelect("SELECT server_deleted FROM crate_items_meta WHERE item_key = 'web1'").getSingle();
    expect(noted.read<bool>('server_deleted'), isTrue, reason: 'the Crate holds a deletion of it');

    final trash = await owner.service.trashOf(id, crate);
    expect(trash, hasLength(1));
    final t = trash.single;
    expect((t.kind, t.key, t.name, t.deletedBy), ('host', 'web1', 'Web One', _owner));
    expect(t.keptUntil, now.add(const Duration(days: 30)));

    // Someone who may only use the Crate has no trash.
    await expectLater(alice.service.trashOf(id, crate),
        throwsA(isA<OrchardServerException>().having((e) => e.need, 'need', CrateSwitches.add)));

    // The owner's laptop brings it back.
    final laptop = device(_owner);
    await laptop.service.refresh();
    await laptop.coordinator.syncAll();
    final laptopDb = await laptop.db(id);
    expect(await labelOf(laptopDb, 'web1'), isNull);
    final there = (await laptop.service.trashOf(id, crate)).single;
    await laptop.service.restoreFromTrash(id, there);
    expect(await labelOf(laptopDb, 'web1'), 'Web One');
    expect(await laptop.service.trashOf(id, crate), isEmpty, reason: 'back on this device');
    expect((await laptop.coordinator.syncAll())[id]!.sent, 1);
    final meta = await laptopDb.customSelect("SELECT server_deleted FROM crate_items_meta WHERE item_key = 'web1'").getSingle();
    expect(meta.read<bool>('server_deleted'), isFalse);

    // Everyone follows; the trash is empty.
    await owner.coordinator.syncAll();
    await alice.coordinator.syncAll();
    expect(await labelOf(db, 'web1'), 'Web One');
    expect(await labelOf(await alice.db(id), 'web1'), 'Web One');
    expect(await owner.service.trashOf(id, crate), isEmpty);
  });

  test('bringing an item back needs add: without it this device refuses the change', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    final db = await owner.db(id);
    await addHost(db, 'web1', 'Web 1');
    await owner.coordinator.syncAll();
    await db.customStatement("DELETE FROM connections WHERE id = 'web1'");
    await owner.coordinator.syncAll();
    final entry = (await owner.service.trashOf(id, crate)).single;

    // Alice's device holds the deletion too; she may not add there.
    await alice.coordinator.syncAll();
    await expectLater(alice.service.restoreFromTrash(id, entry), throwsA(predicate((e) => '$e'.contains('orchard-access'))));
    expect(await labelOf(await alice.db(id), 'web1'), isNull);
  });

  test('version history: nothing until an owner turns it on, then each version, one put back as a change', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    final db = await owner.db(id);
    await addHost(db, 'web1', 'Web 1');
    await owner.coordinator.syncAll();
    await rename(db, 'web1', 'Before');
    await owner.coordinator.syncAll();

    await expectLater(owner.service.itemVersions(id, crate, kind: 'host', key: 'web1'),
        throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'history-off')));

    now = now.add(const Duration(minutes: 5));
    await owner.service.setTracking(id, const RecordTracking(history: true));
    await owner.coordinator.syncAll();
    now = now.add(const Duration(minutes: 5));
    await rename(db, 'web1', 'Second');
    await owner.coordinator.syncAll();
    now = now.add(const Duration(minutes: 5));
    await rename(db, 'web1', 'Third');
    await owner.coordinator.syncAll();

    final versions = await owner.service.itemVersions(id, crate, kind: 'host', key: 'web1');
    expect([for (final v in versions) (v.name, v.isCurrent)], [('Third', true), ('Second', false), ('Before', false)],
        reason: 'what changed before it was turned on is not there: "Web 1" was replaced earlier');
    expect(versions.every((v) => v.record.author == _owner), isTrue);

    // Someone who may only use the Crate sees none of it.
    await expectLater(alice.service.itemVersions(id, crate, kind: 'host', key: 'web1'),
        throwsA(isA<OrchardServerException>().having((e) => e.need, 'need', CrateSwitches.manage)));

    // The Crate's changes: each version with the one it replaced.
    final changes = await owner.service.crateChanges(id, crate);
    expect([for (final c in changes.changes) (c.previous.name, c.version.name, c.by)],
        [('Second', 'Third', _owner), ('Before', 'Second', _owner)]);
    expect(changes.since, now.subtract(const Duration(minutes: 10)));

    // An earlier version put back, from the laptop: a change like any other.
    final laptop = device(_owner);
    await laptop.service.refresh();
    await laptop.coordinator.syncAll();
    final second = (await laptop.service.itemVersions(id, crate, kind: 'host', key: 'web1'))
        .firstWhere((v) => v.name == 'Second');
    await laptop.service.putVersionBack(id, second);
    expect((await laptop.coordinator.syncAll())[id]!.sent, 1);
    await owner.coordinator.syncAll();
    expect(await labelOf(db, 'web1'), 'Second');
  });

  test('a version the server slips in, written by someone who could not write there, is left out', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    final db = await owner.db(id);
    await owner.service.setTracking(id, const RecordTracking(history: true));
    await addHost(db, 'web1', 'Web 1');
    await owner.coordinator.syncAll();
    await rename(db, 'web1', 'Web 2');
    await owner.coordinator.syncAll();

    // Alice can open the Crate, so her device holds its key; she may not
    // edit there. A server that plays along keeps a version she signed.
    final key = (await db.customSelect(
      "SELECT secret FROM space_keys WHERE scope = 'crate' AND scope_id = ? AND generation = 1",
      variables: [Variable(crate)],
    ).getSingle())
        .read<Uint8List>('secret');
    final record = await LocalRecord.load(db, id);
    final forged = await sealItem(
      ItemRecord(
        kind: 'host',
        key: 'web1',
        author: _alice,
        authorKeyVersion: keys[_alice]!.version,
        editedAt: now.millisecondsSinceEpoch,
        data: {
          'connections': [
            {'id': 'web1', 'label': 'Evil', 'host': 'evil.example.com', 'port': 22, 'created_at': 0},
          ],
        },
        recordSeq: record.seq,
        recordHead: record.head,
      ),
      place: ItemPlace(
          orchardId: id,
          crateId: crate,
          itemId: crateItemId(await crateItemIdKey(key, orchardId: id, crateId: crate), kind: 'host', key: 'web1'),
          generation: 1),
      crateKey: key,
      signer: keys[_alice]!,
    );
    server.historyRows.add(FakeHistoryRow(999, crate, forged.itemId, 1, forged, now));
    // And one whose bytes were changed on the way.
    final flipped = Uint8List.fromList(forged.record)..[forged.record.length - 1] ^= 1;
    server.historyRows.add(FakeHistoryRow(1000, crate, forged.itemId, 1,
        SealedItem(itemId: forged.itemId, keyGeneration: 1, deleted: false, record: flipped, signature: forged.signature),
        now));

    final versions = await owner.service.itemVersions(id, crate, kind: 'host', key: 'web1');
    expect([for (final v in versions) v.name], ['Web 2', 'Web 1']);
    expect((await owner.service.crateChanges(id, crate)).changes.map((c) => c.version.name), isNot(contains('Evil')));
  });

  Future<bool?> serverDeleted(AppDatabase db, String key) async =>
      (await db.customSelect('SELECT server_deleted FROM crate_items_meta WHERE item_key = ?', variables: [Variable(key)])
              .getSingleOrNull())
          ?.read<bool>('server_deleted');

  test('someone who may add but not edit brings an item back; it goes as an add', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    final role = server.recordOf(id).roles.values.single.id;
    await owner.service.saveRole(id, id: role, name: 'Member', can: {}, crates: {
      crate: {CrateSwitches.connect, CrateSwitches.add},
    });
    final db = await owner.db(id);
    await addHost(db, 'web1', 'Web 1');
    await owner.coordinator.syncAll();
    await alice.coordinator.syncAll();
    final aliceDb = await alice.db(id);
    expect(await serverDeleted(aliceDb, 'web1'), isFalse);
    await db.customStatement("DELETE FROM connections WHERE id = 'web1'");
    await owner.coordinator.syncAll();
    await alice.coordinator.syncAll();
    expect(await serverDeleted(aliceDb, 'web1'), isTrue, reason: 'her device took the deletion');

    await alice.service.restoreFromTrash(id, (await alice.service.trashOf(id, crate)).single);
    expect((await alice.coordinator.syncAll())[id]!.sent, 1);
    expect(await serverDeleted(aliceDb, 'web1'), isFalse);
    await owner.coordinator.syncAll();
    expect(await labelOf(db, 'web1'), 'Web 1');
    // Changing it afterwards is editing, which she may not.
    await expectLater(rename(aliceDb, 'web1', 'Mine'), throwsA(predicate((e) => '$e'.contains('orchard-access'))));
  });

  test('a device that never had the item brings it back into its own Crate, not where new items go', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, production) = await team(owner, alice);
    final staging = await owner.service.createCrate(id, 'Staging');
    final db = await owner.db(id);
    await addHost(db, 'web1', 'Web 1');
    await owner.coordinator.syncAll();
    await db.customStatement("DELETE FROM connections WHERE id = 'web1'");
    await owner.coordinator.syncAll();

    final laptop = device(_owner);
    await laptop.service.refresh();
    await laptop.coordinator.syncAll();
    final laptopDb = await laptop.db(id);
    expect(await serverDeleted(laptopDb, 'web1'), isNull, reason: 'a deletion of something it never had is nothing');
    await CratePlacement(laptopDb).setDefaultCrate(staging);
    await laptop.service.restoreFromTrash(id, (await laptop.service.trashOf(id, production)).single);
    expect((await laptop.coordinator.syncAll())[id]!.sent, 1);
    final meta = await laptopDb.customSelect("SELECT crate_id FROM crate_items_meta WHERE item_key = 'web1'").getSingle();
    expect(meta.read<String>('crate_id'), production);
    final live = server.items[production]!.values.where((i) => i.item?.deleted == false);
    expect(live, hasLength(1));
    expect(server.items[staging]!.values.where((i) => i.item?.deleted == false), isEmpty);
  });

  test('an item moved to another Crate is not in the trash of the one it left', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, production) = await team(owner, alice);
    final staging = await owner.service.createCrate(id, 'Staging');
    final db = await owner.db(id);
    await addHost(db, 'web1', 'Web 1');
    await owner.coordinator.syncAll();
    await CratePlacement(db).moveItem('host', 'web1', staging);
    await owner.coordinator.syncAll();
    expect(server.items[production]!.values.single.item!.deleted, isTrue, reason: 'left by a deletion naming Staging');
    expect(await owner.service.trashOf(id, production), isEmpty);
  });

  test("a server that answers with other items' versions gets only this item's shown", () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setTracking(id, const RecordTracking(history: true));
    final db = await owner.db(id);
    await addHost(db, 'web1', 'Web 1');
    await addHost(db, 'web2', 'Other 1');
    await owner.coordinator.syncAll();
    await rename(db, 'web1', 'Web 2');
    await rename(db, 'web2', 'Other 2');
    await owner.coordinator.syncAll();
    server.historyIgnoresItem = true;
    final versions = await owner.service.itemVersions(id, crate, kind: 'host', key: 'web1');
    expect([for (final v in versions) v.name], ['Web 2', 'Web 1']);
  });

  test('an item moved to a Crate someone cannot open is not in the trash they see', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, production) = await team(owner, alice);
    final role = server.recordOf(id).roles.values.single.id;
    await owner.service.saveRole(id, id: role, name: 'Member', can: {}, crates: {
      production: {CrateSwitches.connect, CrateSwitches.add},
    });
    final staging = await owner.service.createCrate(id, 'Staging');
    final db = await owner.db(id);
    await addHost(db, 'web1', 'Web 1');
    await owner.coordinator.syncAll();
    await alice.coordinator.syncAll();
    expect(await labelOf(await alice.db(id), 'web1'), 'Web 1');
    await CratePlacement(db).moveItem('host', 'web1', staging);
    await owner.coordinator.syncAll();
    await alice.coordinator.syncAll();
    expect(await labelOf(await alice.db(id), 'web1'), isNull, reason: 'it left for a Crate she cannot open');
    expect(await alice.service.trashOf(id, production), isEmpty);
  });

  test('an edit that wins over a deletion goes as an add: without add it waits here, never sent to be refused', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, production) = await team(owner, alice);
    final role = server.recordOf(id).roles.values.single.id;
    await owner.service.saveRole(id, id: role, name: 'Member', can: {}, crates: {
      production: {CrateSwitches.connect, CrateSwitches.edit},
    });
    final db = await owner.db(id);
    await addHost(db, 'web1', 'Web 1');
    await owner.coordinator.syncAll();
    await alice.coordinator.syncAll();
    final aliceDb = await alice.db(id);

    // The owner deletes it; afterwards, before her device hears of it, alice edits it.
    await db.customStatement("DELETE FROM connections WHERE id = 'web1'");
    await owner.coordinator.syncAll();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await rename(aliceDb, 'web1', 'Still needed');
    final itemId = server.items[production]!.keys.single;
    final attempts = server.writeCalls.length;
    final report = (await alice.coordinator.syncAll())[id]!;
    expect(report.conflictsWon, 1);
    expect(report.unsent, 1, reason: 'bringing it back is adding it, which she may not');
    expect(server.writeCalls.skip(attempts).expand((w) => w).where((w) => w.item.itemId == itemId), isEmpty);
    expect(await serverDeleted(aliceDb, 'web1'), isTrue);
  });
}

