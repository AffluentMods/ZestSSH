import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart' show kUnlistedStatus;
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

import 'fake_crate_server.dart';

/// Making Orchards and keeping them on a person's devices (3.0):
/// an Orchard made on one device opens on the next with its names and keys,
/// its items sync, and what the account can no longer open leaves.

class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};
  final deleted = <String>[];

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async {
    deleted.add(orchardId);
    dbs.remove(orchardId);
  }

  @override
  Future<List<String>> list() async => dbs.keys.toList();
}

class _Device {
  _Device(this.storage, this.databases, this.service, this.coordinator);

  final _MemoryStorage storage;
  final OrchardDatabasesNotifier databases;
  final OrchardService service;
  final OrchardSyncCoordinator coordinator;

  Future<AppDatabase> db(String orchardId) => databases.open(orchardId);

  Future<List<Map<String, Object?>>> rows(String orchardId, String sql) async =>
      [for (final r in await (await db(orchardId)).customSelect(sql).get()) r.data];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AccountKeys keys;
  late FakeCrateServer server;
  final devices = <_Device>[];

  setUpAll(() async {
    keys = await AccountKeys.generate();
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer();
  });

  tearDown(() async {
    for (final d in devices) {
      for (final db in d.storage.dbs.values) {
        await db.close();
      }
    }
    devices.clear();
  });

  _Device device({bool keysReady = true}) {
    final storage = _MemoryStorage();
    final databases = OrchardDatabasesNotifier(
      OrchardDatabaseKeys(const FlutterSecureStorage()),
      storage: storage,
    );
    Future<CrateAuthor?> author() async =>
        keysReady ? CrateAuthor(uid: 'owner-1', keys: keys) : null;
    final service = OrchardService(server: server, databases: databases, author: author);
    final d = _Device(
      storage,
      databases,
      service,
      OrchardSyncCoordinator(service: service, server: server, databases: databases),
    );
    devices.add(d);
    return d;
  }

  test('an Orchard made on one device opens on the next, and its items sync', () async {
    final a = device();
    final id = await a.service.createOrchard(' Acme ', firstCrateName: 'Production', memberRoleName: 'Member');

    final info = (await a.rows(id, 'SELECT * FROM orchard_info')).single;
    expect(info['name'], 'Acme');
    expect(info['role'], 'owner');
    final crates = await a.rows(id, 'SELECT * FROM orchard_crates');
    expect(crates.single['name'], 'Production');
    expect(crates.single['level'], 'manage');
    expect(info['default_crate_id'], crates.single['crate_id']);

    final aDb = await a.db(id);
    final now = DateTime(2026, 9, 23);
    await aDb.into(aDb.connections).insert(ConnectionsCompanion.insert(
          id: 'h-1',
          label: 'prod-web',
          host: '10.0.0.1',
          port: const Value(22),
          createdAt: now,
          updatedAt: now,
        ));
    final sent = await a.coordinator.syncAll();
    expect(sent[id]!.sent, 1);

    final b = device();
    final got = await b.coordinator.syncAll();
    expect(got.keys, [id]);
    expect(got[id]!.received, 1);
    expect((await b.rows(id, 'SELECT name FROM orchard_info')).single['name'], 'Acme');
    expect((await b.rows(id, 'SELECT name FROM orchard_crates')).single['name'], 'Production');
    expect((await b.rows(id, 'SELECT label FROM connections')).single['label'], 'prod-web');
  });

  test('the server sees no names', () async {
    final a = device();
    final id = await a.service.createOrchard('Acme-zq', firstCrateName: 'Production-zq', memberRoleName: 'Member');
    final o = server.orchardsById[id]!;
    expect(latin1.decode(o.nameEnc).contains('Acme-zq'), isFalse);
    expect(latin1.decode(o.crates.single.nameEnc).contains('Production-zq'), isFalse);
  });

  test('a Crate added on one device reaches the other', () async {
    final a = device();
    final id = await a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final b = device();
    await b.service.refresh();
    final staging = await a.service.createCrate(id, 'Staging');
    await b.service.refresh();
    final names = (await b.rows(id, 'SELECT name FROM orchard_crates ORDER BY name'))
        .map((r) => r['name']);
    expect(names, ['Production', 'Staging']);
    final keysOnB = await b.rows(
        id, "SELECT generation FROM space_keys WHERE scope = 'crate' AND scope_id = '$staging'");
    expect(keysOnB, hasLength(1));
  });

  test('an Orchard the server no longer lists stays, held, until its person removes it', () async {
    final a = device();
    final id = await a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final b = device();
    await b.service.refresh();
    expect(b.storage.dbs.keys, [id]);

    server.hidden.add(id);
    await b.service.refresh();
    expect(b.storage.deleted, isEmpty, reason: 'the record here still has this account in it');
    expect((await b.rows(id, 'SELECT status FROM orchard_info')).single['status'], kUnlistedStatus);

    await b.service.removeUnlistedTeam(id);
    expect(b.storage.deleted, [id]);
    expect(await const FlutterSecureStorage().read(key: OrchardDatabaseKeys.storageKey(id)),
        isNull);
  });

  test('a Crate the list alone leaves out stays, held, with its items and keys', () async {
    final a = device();
    final id = await a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final staging = await a.service.createCrate(id, 'Staging');
    final aDb = await a.db(id);
    final now = DateTime(2026, 9, 23);
    for (final host in ['h-prod', 'h-staging']) {
      await aDb.into(aDb.connections).insert(ConnectionsCompanion.insert(
            id: host,
            label: host,
            host: '10.0.0.1',
            port: const Value(22),
            createdAt: now,
            updatedAt: now,
          ));
    }
    final engine = await a.coordinator
        .engineFor(id, author: CrateAuthor(uid: 'owner-1', keys: keys));
    await engine.place('host', 'h-staging', staging);
    await a.coordinator.syncAll();

    final b = device();
    await b.coordinator.syncAll();
    expect((await b.rows(id, 'SELECT id FROM connections ORDER BY id')).map((r) => r['id']),
        ['h-prod', 'h-staging']);

    server.dropCrate(id, staging);
    await b.coordinator.syncAll();
    // The record still opens it to this account: what is here stays (a
    // Crate the record no longer opens leaves: unlisted_team_test.dart).
    expect((await b.rows(id, 'SELECT id FROM connections ORDER BY id')).map((r) => r['id']),
        ['h-prod', 'h-staging']);
    expect(await b.rows(id, "SELECT * FROM space_keys WHERE scope_id = '$staging'"), isNotEmpty);
    expect(await b.rows(id, 'SELECT * FROM crate_outbox'), isEmpty, reason: 'keeping them is not a change to send');
  });

  test('without account keys ready, nothing is made or opened', () async {
    final a = device(keysReady: false);
    await expectLater(a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member'),
        throwsA(isA<AccountKeysNotReady>()));
    await expectLater(a.service.refresh(), throwsA(isA<AccountKeysNotReady>()));
    expect(server.orchardsById, isEmpty);
    expect(a.storage.dbs, isEmpty);
  });

  test('a server that cannot be asked takes nothing off the device', () async {
    final a = device();
    final id = await a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final failing = _FailingServer(server);
    final service = OrchardService(
      server: failing,
      databases: a.databases,
      author: () async => CrateAuthor(uid: 'owner-1', keys: keys),
    );
    await expectLater(service.refresh(), throwsA(isA<StateError>()));
    expect(a.storage.deleted, isEmpty);
    expect(a.storage.dbs.keys, [id]);
  });
  test('ZestSSH Cloud\'s list is told before anything opens one of its teams: a team with no owner goes on its word', () async {
    final a = device();
    final id = await a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final other = device();
    final heard = <Set<String>>[];
    final heardAs = <String>[];
    var openWhenTold = -1;
    final service = OrchardService(
      server: server,
      databases: other.databases,
      author: () async => CrateAuthor(uid: 'owner-1', keys: keys),
      onServerList: (ids, uid) async {
        heard.add(ids);
        heardAs.add(uid);
        openWhenTold = other.storage.dbs.length;
      },
    );
    await service.refresh();
    expect(heard, [
      {id}
    ]);
    expect(heardAs, ['owner-1'], reason: 'the account it asked as, for a list that comes late');
    expect(openWhenTold, 0);
    expect(other.storage.dbs.keys, [id]);
  });

  group('key copies the server hands out', () {
    /// [orchardId]'s Crate as the server lists it, with [keys] instead.
    void serveCrateKeys(String orchardId, List<SealedSpaceKey> keys, {int? generation}) =>
        server.serveKeys(orchardId, keys,
            crateId: server.orchardsById[orchardId]!.crates.single.id, generation: generation);

    SealedSpaceKey signedBy(AccountKeys signer, int generation, Uint8List sealed,
            {String uid = 'owner-1', Uint8List? signature}) =>
        SealedSpaceKey(generation, sealed,
            recipientKeyVersion: keys.version,
            sealedBy: uid,
            sealerKeyVersion: signer.version,
            signature: signature);

    test('a key the server slipped in is refused, and nothing is written with it', () async {
      final a = device();
      final id = await a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
      final crate = server.orchardsById[id]!.crates.single;

      // The server knows this account's public key, so it can seal a key of
      // its own to it as a "new generation". It cannot sign as the account.
      final serverKey = newSpaceKey();
      final sealed = await sealCrateKey(keys.encryption.publicKey, serverKey,
          orchardId: id, crateId: crate.id, generation: 2);
      serveCrateKeys(id, [
        ...crate.keys,
        signedBy(keys, 2, sealed, signature: Uint8List(64)),
      ], generation: 2);

      final db = await a.db(id);
      final now = DateTime(2026, 9, 24);
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'h-1',
            label: 'web',
            host: '10.0.0.1',
            createdAt: now,
            updatedAt: now,
          ));
      final report = (await a.coordinator.syncAll())[id]!;
      expect(report.needsKeys, isTrue);
      expect(await a.rows(id, "SELECT generation FROM space_keys WHERE scope = 'crate'"),
          [{'generation': 1}]);
      expect(server.items[crate.id], isEmpty, reason: 'nothing was written under that key');
      expect((await a.rows(id, 'SELECT COUNT(*) AS n FROM crate_outbox')).single['n'], 1,
          reason: 'the change waits for a key this account signed');
    });

    test('an unsigned copy, or one another account signed, does not open', () async {
      final a = device();
      final id = await a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
      final crate = server.orchardsById[id]!.crates.single;
      final other = await AccountKeys.generate();
      final copy = crate.keys.single;
      final foreign = await signKeyCopy(
        other,
        KeyCopyPlace(
          orchardId: id,
          crateId: crate.id,
          generation: 1,
          recipient: 'owner-1',
          recipientKeyVersion: keys.version,
          sealer: 'owner-1',
          sealerKeyVersion: other.version,
        ),
        copy.sealed,
      );
      for (final served in [
        SealedSpaceKey(1, copy.sealed),
        signedBy(other, 1, copy.sealed, signature: foreign),
        signedBy(keys, 1, copy.sealed, uid: 'someone-else', signature: copy.signature),
      ]) {
        serveCrateKeys(id, [served]);
        // A device that has never held the key.
        final b = device();
        await b.service.refresh();
        expect(await b.rows(id, "SELECT * FROM space_keys WHERE scope = 'crate'"), isEmpty);
        expect((await b.rows(id, 'SELECT name FROM orchard_crates')).single['name'], isNull,
            reason: 'its name stays unreadable too');
      }
    });

    test('a key this device holds is never replaced by a later copy', () async {
      final a = device();
      final id = await a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
      final crate = server.orchardsById[id]!.crates.single;
      final before = await a.rows(id, "SELECT secret FROM space_keys WHERE scope = 'crate'");

      // Even a copy this account signed (say, a bug on another of its
      // devices) cannot swap the key of a generation this device holds.
      final place = KeyCopyPlace(
        orchardId: id,
        crateId: crate.id,
        generation: 1,
        recipient: 'owner-1',
        recipientKeyVersion: keys.version,
        sealer: 'owner-1',
        sealerKeyVersion: keys.version,
      );
      final sealed = await sealCrateKey(keys.encryption.publicKey, newSpaceKey(),
          orchardId: id, crateId: crate.id, generation: 1);
      serveCrateKeys(id, [signedBy(keys, 1, sealed, signature: await signKeyCopy(keys, place, sealed))]);
      await a.service.refresh();
      expect(await a.rows(id, "SELECT secret FROM space_keys WHERE scope = 'crate'"), before);
    });
  });
}

class _FailingServer extends FakeCrateServer {
  _FailingServer(this.inner);

  final FakeCrateServer inner;

  @override
  Future<List<Never>> orchards() async => throw StateError('offline');
}
