import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

import '../../helpers/record_commits.dart';

import 'fake_crate_server.dart';

/// The sync engine and the Orchard's record (3.0): every version
/// written names the record's last entry (its anchor); a version read is
/// taken only when that entry is the one the device holds, and its author
/// could, as the record stood then, write it; and a change the account may
/// not make in its Crate is not sent.

const _orchard = '0c2f8a6e-5b1d-4d3a-9f47-2a61c0e9b7d3';
const _crate = '2e4a0c8a-7d3f-4f5c-9a69-4c83e2a1d9f5';
const _owner = 'owner-1';
const _alice = 'alice-1';
const _writer = 'role-writer';
const _viewer = 'role-viewer';
const _adder = 'role-adder';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AccountKeys ownerKeys;
  late AccountKeys aliceKeys;
  late Uint8List crateKey;
  late FakeCrateServer server;
  late List<RecordEntry> entries;
  final dbs = <AppDatabase>[];

  Map<String, Object?> role(String id, int rank, List<String> switches) => {
        'id': id,
        'rank': rank,
        'name_enc': base64Encode(utf8.encode('sealed-$id')),
        'name_gen': 1,
        'can': const <String>[],
        'crates': {_crate: switches},
      };

  /// The record: made with the Crate and three roles; Alice added as a
  /// writer (add and edit, no delete); then moved to viewer.
  setUpAll(() async {
    ownerKeys = await AccountKeys.generate();
    aliceKeys = await AccountKeys.generate();
    final chain = <RecordEntry>[];
    Future<void> add(AccountKeys keys, String by, String type, Map<String, Object?> body) async {
      chain.add(await signRecordEntry(keys,
          orchardId: _orchard,
          seq: chain.length + 1,
          prev: chain.isEmpty ? const [] : chain.last.hash(_orchard),
          type: type,
          body: body,
          by: by));
    }

    await add(ownerKeys, _owner, RecordTypes.create, {
      'owner': {...recordKeysBody(await ownerKeys.publish(_owner)), 'uid': _owner},
      'key_commit': testCommit('orchard'),
      'crate': {'id': _crate, 'owners_only': false, 'allow': ['forward', 'sftp'], 'key_commit': testCommit(_crate)},
      'roles': [
        role(_viewer, 10, ['connect']),
        role(_adder, 20, ['add', 'connect']),
        role(_writer, 30, ['add', 'connect', 'edit']),
      ],
    });
    await add(ownerKeys, _owner, RecordTypes.memberAdd,
        {...recordKeysBody(await aliceKeys.publish(_alice)), 'uid': _alice, 'role': _writer});
    await add(ownerKeys, _owner, RecordTypes.memberSet, {'uid': _alice, 'role': _viewer});
    // Entry 4: Alice may add, not edit (only the host key tests hold it).
    await add(ownerKeys, _owner, RecordTypes.memberSet, {'uid': _alice, 'role': _adder});
    entries = chain;
  });

  setUp(() {
    crateKey = newSpaceKey();
    server = FakeCrateServer(accountUid: _owner)..addCrate(_crate);
  });

  tearDown(() async {
    for (final db in dbs) {
      await db.close();
    }
    dbs.clear();
  });

  /// A device of [uid]'s holding the record up to entry [upTo], with
  /// [switches] in the Crate.
  Future<(AppDatabase, CrateSyncEngine)> device(String uid, AccountKeys keys,
      {int upTo = 3, Set<String>? switches}) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    dbs.add(db);
    await db.customStatement(
      'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id) '
      "VALUES (1, ?, 'Acme', 'owner', 1, ?)",
      [_orchard, _crate],
    );
    await LocalRecord.empty(_orchard).extend(db, entries.take(upTo).toList());
    await db.customStatement(
      "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, 'c', 'manage', ?, 1)",
      [_crate, jsonEncode(switchList(switches ?? CrateSwitches.all.difference({CrateSwitches.agent})))],
    );
    await db.customStatement(
      "INSERT INTO space_keys (scope, scope_id, generation, secret) VALUES ('crate', ?, 1, ?)",
      [_crate, crateKey],
    );
    Future<List<int>?> signers(String who, int version) async => switch (who) {
          _owner when version == ownerKeys.version => ownerKeys.signingPublicKey,
          _alice when version == aliceKeys.version => aliceKeys.signingPublicKey,
          _ => null,
        };
    return (
      db,
      CrateSyncEngine(
        db: db,
        orchardId: _orchard,
        server: server,
        author: CrateAuthor(uid: uid, keys: keys),
        signers: signers,
      ),
    );
  }

  Future<String> itemId(String key) async =>
      crateItemId(await crateItemIdKey(crateKey, orchardId: _orchard, crateId: _crate), kind: 'host', key: key);

  /// A host named [label] as [author] writes it, naming entry [seq] of the
  /// record (with its true hash unless [head] says otherwise), edited at
  /// [editedAt] (now unless given).
  Future<SealedItem> hostBy(String author, AccountKeys keys, String key, String label,
      {required int seq, Uint8List? head, bool deleted = false, int? editedAt}) async {
    final at = editedAt ?? DateTime.now().millisecondsSinceEpoch;
    final record = ItemRecord(
      kind: 'host',
      key: key,
      author: author,
      authorKeyVersion: keys.version,
      editedAt: at,
      deleted: deleted,
      data: deleted
          ? null
          : {
              'connections': [
                {
                  'id': key,
                  'label': label,
                  'host': '10.0.0.1',
                  'port': 22,
                  'created_at': at ~/ 1000,
                  'updated_at': at ~/ 1000,
                },
              ],
            },
      recordSeq: seq,
      recordHead: head ?? entries[seq - 1].hash(_orchard),
    );
    return sealItem(record,
        place: ItemPlace(orchardId: _orchard, crateId: _crate, itemId: await itemId(key), generation: 1),
        crateKey: crateKey,
        signer: keys);
  }

  /// A team-pinned host key for [key], as [author] writes it,
  /// naming entry [seq], edited at [editedAt] (now unless given).
  Future<SealedItem> hostKeyBy(String author, AccountKeys keys, String key, {required int seq, int? editedAt}) async {
    final at = editedAt ?? DateTime.now().millisecondsSinceEpoch;
    final record = ItemRecord(
      kind: kHostKeyKind,
      key: key,
      author: author,
      authorKeyVersion: keys.version,
      editedAt: at,
      data: {
        'team_host_keys': [
          {'id': key, 'host': 'web1', 'port': 22, 'via_scope': '', 'host_keys': '["ssh-ed25519 AAAA"]'},
        ],
      },
      recordSeq: seq,
      recordHead: entries[seq - 1].hash(_orchard),
    );
    return sealItem(record,
        place: ItemPlace(
            orchardId: _orchard,
            crateId: _crate,
            itemId: crateItemId(await crateItemIdKey(crateKey, orchardId: _orchard, crateId: _crate),
                kind: kHostKeyKind, key: key),
            generation: 1),
        crateKey: crateKey,
        signer: keys);
  }

  Future<List<String>> pins(AppDatabase db) async =>
      [for (final r in await db.customSelect('SELECT id FROM team_host_keys ORDER BY id').get()) r.read<String>('id')];

  Future<String?> label(AppDatabase db, String id) async => (await db
          .customSelect('SELECT label FROM connections WHERE id = ?', variables: [Variable(id)])
          .getSingleOrNull())
      ?.read<String>('label');

  test('what this device writes names the record\'s last entry here', () async {
    final (db, engine) = await device(_owner, ownerKeys);
    final now = DateTime.now();
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'h-1', label: 'web', host: '10.0.0.1', port: const Value(22), createdAt: now, updatedAt: now));
    expect((await engine.sync()).sent, 1);
    final sent = server.items[_crate]!.values.single.item!;
    final written = await openItem(sent,
        orchardId: _orchard,
        crateId: _crate,
        crateKey: crateKey,
        idKey: await crateItemIdKey(crateKey, orchardId: _orchard, crateId: _crate),
        signers: (uid, version) async => ownerKeys.signingPublicKey);
    expect(written.recordSeq, 3);
    expect(written.recordHead, entries[2].hash(_orchard));
  });

  test("an author's access is judged as the record stood when they wrote", () async {
    final (db, engine) = await device(_owner, ownerKeys);
    // Written while Alice was a writer (entry 2), before this device saw
    // her become a viewer: taken.
    final before = DateTime.now().millisecondsSinceEpoch - 300000;
    server.forceItem(_crate, await hostBy(_alice, aliceKeys, 'h-1', 'from-alice', seq: 2, editedAt: before));
    var report = await engine.sync();
    expect(report.rejected, 0);
    expect(await label(db, 'h-1'), 'from-alice');
    // Written after she became a viewer (entry 3): refused.
    server.forceItem(_crate, await hostBy(_alice, aliceKeys, 'h-2', 'late', seq: 3));
    report = await engine.sync();
    expect(report.rejected, 1);
    expect(await label(db, 'h-2'), isNull);
    // A deletion needs delete, which writers do not have.
    server.forceItem(_crate, await hostBy(_alice, aliceKeys, 'h-1', '', seq: 2, deleted: true, editedAt: before + 1000));
    report = await engine.sync();
    expect(report.rejected, 1);
    expect(await label(db, 'h-1'), 'from-alice');
  });

  test('an item naming an entry this device does not have waits for the record; one naming another entry is refused',
      () async {
    final (db, engine) = await device(_owner, ownerKeys, upTo: 2);
    server.forceItem(_crate, await hostBy(_owner, ownerKeys, 'h-1', 'after-3', seq: 3));
    var report = await engine.sync();
    expect(report.needsRecord, isTrue);
    expect(report.rejected, 0);
    expect(await label(db, 'h-1'), isNull, reason: 'not taken yet, and not skipped either');

    // The record catches up: the item is read again and taken.
    await (await LocalRecord.load(db, _orchard)).extend(db, [entries[2]]);
    report = await engine.sync();
    expect(report.needsRecord, isFalse);
    expect(await label(db, 'h-1'), 'after-3');

    // Naming entry 2 with a hash this device's entry 2 does not have: the
    // server shows someone a different record.
    server.forceItem(_crate, await hostBy(_owner, ownerKeys, 'h-2', 'forked', seq: 2, head: Uint8List(32)));
    report = await engine.sync();
    expect(report.recordMismatch, isTrue);
    expect(report.rejected, 1);
    expect(await label(db, 'h-2'), isNull);
  });

  test('a pinned host key counts only from someone who could edit the Crate then', () async {
    final (db, engine) = await device(_owner, ownerKeys, upTo: 4);
    // Written while Alice could edit (entry 2), before this device saw that
    // end: taken.
    server.forceItem(_crate,
        await hostKeyBy(_alice, aliceKeys, 'web1|22|', seq: 2, editedAt: DateTime.now().millisecondsSinceEpoch - 300000));
    var report = await engine.sync();
    expect(report.rejected, 0);
    expect(await pins(db), ['web1|22|']);
    // Written when she could only add (entry 4): refused, though a host she
    // adds then is taken.
    server.forceItem(_crate, await hostKeyBy(_alice, aliceKeys, 'web2|22|', seq: 4));
    server.forceItem(_crate, await hostBy(_alice, aliceKeys, 'h-add', 'added', seq: 4));
    report = await engine.sync();
    expect(report.rejected, 1);
    expect(await pins(db), ['web1|22|']);
    expect(await label(db, 'h-add'), 'added');
  });

  test('a pinned host key is not sent by someone who may only add', () async {
    final (db, engine) = await device(_alice, aliceKeys, switches: {'add', 'connect', 'edit'});
    await db.customStatement(
        "INSERT INTO team_host_keys (id, host, port, via_scope, host_keys) VALUES ('web1|22|', 'web1', 22, '', '[]')");
    // Before it syncs, her role changes: she may add, not edit.
    await db.customStatement('UPDATE orchard_crates SET switches = ? WHERE crate_id = ?', ['["add","connect"]', _crate]);
    final report = await engine.sync();
    expect(report.unsent, 1);
    expect(server.items[_crate] ?? const {}, isEmpty, reason: 'nothing reaches the Crate');
  });

  test('a change made while it was allowed is not sent once it is not, and waits', () async {
    // Alice may add and edit when she makes the change.
    final (db, engine) = await device(_alice, aliceKeys, switches: {'add', 'connect', 'edit'});
    final now = DateTime.now();
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'h-1', label: 'web', host: '10.0.0.1', port: const Value(22), createdAt: now, updatedAt: now));
    var report = await engine.sync();
    expect(report.sent, 1, reason: 'adding is hers to do');
    await (db.update(db.connections)..where((c) => c.id.equals('h-1'))).write(const ConnectionsCompanion(label: Value('edited')));
    // Before it syncs, her role changes: she may add, not edit.
    await db.customStatement('UPDATE orchard_crates SET switches = ? WHERE crate_id = ?', ['["add","connect"]', _crate]);
    final before = server.writeCalls.length;
    report = await engine.sync();
    expect(report.unsent, 1);
    expect(server.writeCalls, hasLength(before), reason: 'the server is not asked');
    expect((await db.customSelect('SELECT COUNT(*) AS n FROM crate_outbox').getSingle()).read<int>('n'), 1,
        reason: 'the change stays, for when she may make it');
    // And this device takes no new change she may not make.
    await expectLater(
      (db.update(db.connections)..where((c) => c.id.equals('h-1'))).write(const ConnectionsCompanion(label: Value('again'))),
      throwsA(predicate((e) => '$e'.contains('orchard-access'))),
    );
  });

  test('more people than seats: new items wait on this device, changes and deletions still go, and all goes once there are seats', () async {
    final (db, engine) = await device(_owner, ownerKeys);
    final now = DateTime.now();
    Future<void> host(String id, String label) => db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: id, label: label, host: '10.0.0.1', port: const Value(22), createdAt: now, updatedAt: now));
    Future<int> waiting() async => (await db.customSelect('SELECT COUNT(*) AS n FROM crate_outbox').getSingle()).read<int>('n');
    await host('h-1', 'web');
    await host('h-2', 'db');
    var report = await engine.sync();
    expect(report.sent, 2);
    final revisions = {for (final e in server.items[_crate]!.entries) e.key: e.value.revision};

    // A refund leaves the Orchard with more people than seats.
    server.seatsShort = true;
    await (db.update(db.connections)..where((c) => c.id.equals('h-1'))).write(const ConnectionsCompanion(label: Value('edited')));
    await (db.delete(db.connections)..where((c) => c.id.equals('h-2'))).go();
    await host('h-3', 'new');
    report = await engine.sync();
    expect(report.seatsNeeded, isTrue);
    expect(report.sent, 2, reason: 'the change and the deletion went');
    expect(report.unsent, 1, reason: 'the new host waits');
    expect(await waiting(), 1);
    final after = server.items[_crate]!;
    expect(after.length, 2, reason: 'nothing new reached the Crate');
    for (final id in revisions.keys) {
      expect(after[id]!.revision, greaterThan(revisions[id]!));
    }
    expect(await label(db, 'h-3'), 'new', reason: 'it is still here');

    // Still short: it waits again, and nothing else is refused for it.
    report = await engine.sync();
    expect(report.seatsNeeded, isTrue);
    expect(report.unsent, 1);
    expect(await waiting(), 1);

    // Seats bought: it goes.
    server.seatsShort = false;
    report = await engine.sync();
    expect(report.seatsNeeded, isFalse);
    expect(report.sent, 1);
    expect(report.unsent, 0);
    expect(await waiting(), 0);
    expect(server.items[_crate]!.length, 3);

    // Its vaults full, with seats to spare: told apart, and what waits, waits.
    server.vaultsFull = true;
    await host('h-4', 'another');
    report = await engine.sync();
    expect(report.seatsNeeded, isTrue);
    expect(report.vaultsFull, isTrue);
    expect(report.unsent, 1);
    expect(await waiting(), 1);
    expect(await label(db, 'h-4'), 'another');

    // Past what changes are let through for, too: nothing is lost, and nothing fails.
    server.vaultsPastChanges = true;
    await (db.update(db.connections)..where((c) => c.id.equals('h-1'))).write(const ConnectionsCompanion(label: Value('again')));
    report = await engine.sync();
    expect(report.vaultsFull, isTrue);
    expect(report.unsent, 2);
    expect(await waiting(), 2);
    expect(await label(db, 'h-1'), 'again');

    // Short of seats alone is not that.
    server
      ..vaultsFull = false
      ..vaultsPastChanges = false
      ..seatsShort = true;
    report = await engine.sync();
    expect(report.seatsNeeded, isTrue);
    expect(report.vaultsFull, isFalse);

    server.seatsShort = false;
    report = await engine.sync();
    expect(report.vaultsFull, isFalse);
    expect(await waiting(), 0);
  });
}
