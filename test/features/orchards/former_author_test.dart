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

/// A version written by someone who has since lost the right to write it
/// (found in a client security review): a version names the
/// state of the record it was written under, and nothing says when, so
/// someone removed, suspended or whose access ended could go on writing,
/// naming a state from before, and a server could hand that to the team.
/// Here the server lets anyone write (a Crate set up without a record), as
/// one not playing by the rules would.

const _orchard = '6a1f3b2c-4d5e-4f60-8a71-92b3c4d5e6f7';
const _crate = '7b2e4c3d-5e6f-4a71-9b82-a3c4d5e6f708';
const _owner = 'owner-1';
const _bob = 'bob-2';
const _role = 'member-role';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AccountKeys ownerKeys;
  late AccountKeys bobKeys;
  late List<RecordEntry> record;
  late Uint8List crateKey;
  late FakeCrateServer server;
  late int t0;
  final dbs = <AppDatabase>[];

  Future<RecordEntry> sign(int seq, List<int> prev, String type, Map<String, Object?> body) =>
      signRecordEntry(ownerKeys, orchardId: _orchard, seq: seq, prev: prev, type: type, by: _owner, body: body);

  setUpAll(() async {
    ownerKeys = await AccountKeys.generate();
    bobKeys = await AccountKeys.generate();
    final create = await sign(1, const [], RecordTypes.create, {
      'owner': {...recordKeysBody(await ownerKeys.publish(_owner)), 'uid': _owner},
      'key_commit': testCommit('orchard'),
      'crate': {'id': _crate, 'owners_only': false, 'allow': const <String>[], 'key_commit': testCommit(_crate)},
      'roles': [
        {
          'id': _role,
          'rank': 100,
          'name_enc': base64Encode(utf8.encode('sealed-role')),
          'name_gen': 1,
          'can': const <String>[],
          'crates': {_crate: switchList(levelSwitches(CrateLevel.edit))},
        },
      ],
    });
    final add = await sign(2, create.hash(_orchard), RecordTypes.memberAdd,
        {...recordKeysBody(await bobKeys.publish(_bob)), 'uid': _bob, 'role': _role});
    record = [create, add];
  });

  setUp(() {
    t0 = DateTime.now().millisecondsSinceEpoch + 600000;
    crateKey = newSpaceKey();
    server = FakeCrateServer()..addCrate(_crate);
  });

  tearDown(() async {
    for (final db in dbs) {
      await db.close();
    }
    dbs.clear();
  });

  Future<List<int>?> signers(String uid, int version) async => switch (uid) {
        _owner when version == ownerKeys.version => ownerKeys.signingPublicKey,
        _bob when version == bobKeys.version => bobKeys.signingPublicKey,
        _ => null,
      };

  /// A device of [uid] with the record so far, whose clock says [now].
  Future<(AppDatabase, CrateSyncEngine)> device(String uid, AccountKeys keys, {int Function()? now}) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    dbs.add(db);
    await db.customStatement(
      'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id) '
      "VALUES (1, ?, 'Acme', 'owner', 1, ?)",
      [_orchard, _crate],
    );
    await LocalRecord.empty(_orchard).extend(db, record);
    await db.customStatement(
      "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, 'c', 'manage', ?, 1)",
      [_crate, jsonEncode(switchList(CrateSwitches.all.difference({CrateSwitches.agent})))],
    );
    await db.customStatement(
      "INSERT INTO space_keys (scope, scope_id, generation, secret) VALUES ('crate', ?, 1, ?)",
      [_crate, crateKey],
    );
    final engine = CrateSyncEngine(
      db: db,
      orchardId: _orchard,
      server: server,
      author: CrateAuthor(uid: uid, keys: keys),
      signers: signers,
      nowMs: now ?? () => t0,
    );
    return (db, engine);
  }

  Future<String?> label(AppDatabase db) async => (await db
          .customSelect("SELECT label FROM connections WHERE id = 'h-1'")
          .getSingleOrNull())
      ?.read<String>('label');

  /// The owner's device takes [entry] into its record, first seeing it at
  /// [seenMs].
  Future<void> learn(AppDatabase db, RecordEntry entry, int seenMs) async {
    await (await LocalRecord.load(db, _orchard))
        .extend(db, [entry], now: DateTime.fromMillisecondsSinceEpoch(seenMs));
  }

  /// A host on the owner's device, synced to Bob's; then Bob's edit of it,
  /// stamped [bobEditedMs], sent to the server. Returns the owner's device.
  Future<(AppDatabase, CrateSyncEngine)> bobEdits(int bobEditedMs, {int Function()? ownerNow}) async {
    final (ownerDb, owner) = await device(_owner, ownerKeys, now: ownerNow);
    final (bobDb, bob) = await device(_bob, bobKeys);
    final now = DateTime.fromMillisecondsSinceEpoch(t0);
    await ownerDb.into(ownerDb.connections).insert(ConnectionsCompanion.insert(
        id: 'h-1', label: 'web', host: '10.0.0.1', port: const Value(22), createdAt: now, updatedAt: now));
    await ownerDb.customStatement('UPDATE crate_outbox SET edited_at = ?', [t0 + 1000]);
    await owner.sync();
    await bob.sync();
    expect(await label(bobDb), 'web');
    await bobDb.customStatement("UPDATE connections SET label = 'from-bob' WHERE id = 'h-1'");
    await bobDb.customStatement('UPDATE crate_outbox SET edited_at = ?', [bobEditedMs]);
    await bob.sync();
    return (ownerDb, owner);
  }

  group('a member removed', () {
    late RecordEntry remove;
    setUp(() async {
      remove = await sign(3, record.last.hash(_orchard), RecordTypes.memberRemove, {'uid': _bob});
    });

    test('a version they say they edited after this device first saw the removal is refused', () async {
      final (ownerDb, owner) = await bobEdits(t0 + 60000);
      await learn(ownerDb, remove, t0 + 30000);
      final report = await owner.sync();
      expect(report.rejected, 1);
      expect(report.received, 0);
      expect(await label(ownerDb), 'web');
    });

    test('one edited before it, arriving late, is taken', () async {
      final (ownerDb, owner) = await bobEdits(t0 + 20000);
      await learn(ownerDb, remove, t0 + 30000);
      final report = await owner.sync();
      expect(report.rejected, 0);
      expect(await label(ownerDb), 'from-bob');
    });

    test('entries between the state the version names and the removal do not hide it', () async {
      final (ownerDb, owner) = await bobEdits(t0 + 60000);
      final later = await sign(3, record.last.hash(_orchard), RecordTypes.memberSet,
          {'uid': _bob, 'ends_at': t0 ~/ 1000 + 1000000});
      final removal = await sign(4, later.hash(_orchard), RecordTypes.memberRemove, {'uid': _bob});
      await learn(ownerDb, later, t0 + 10000);
      await learn(ownerDb, removal, t0 + 30000);
      final report = await owner.sync();
      expect(report.rejected, 1, reason: 'edited after the removal was seen, not after the end date was set');
      expect(await label(ownerDb), 'web');
    });

    test('so is one by someone who may still write it', () async {
      final (ownerDb, owner) = await bobEdits(t0 + 60000);
      final report = await owner.sync();
      expect(report.rejected, 0);
      expect(await label(ownerDb), 'from-bob');
    });
  });

  test('a member suspended: the same', () async {
    final suspend = await sign(3, record.last.hash(_orchard), RecordTypes.memberSuspend, {'uid': _bob});
    final (ownerDb, owner) = await bobEdits(t0 + 60000);
    await learn(ownerDb, suspend, t0 + 30000);
    expect((await owner.sync()).rejected, 1);
    expect(await label(ownerDb), 'web');
  });

  test('access to the Crate taken away by a role changed: the same', () async {
    final role = await sign(3, record.last.hash(_orchard), RecordTypes.roleSet, {
      'id': _role,
      'rank': 100,
      'name_enc': base64Encode(utf8.encode('sealed-role')),
      'name_gen': 1,
      'can': const <String>[],
      'crates': const <String, Object?>{},
    });
    final (ownerDb, owner) = await bobEdits(t0 + 60000);
    await learn(ownerDb, role, t0 + 30000);
    expect((await owner.sync()).rejected, 1);
    expect(await label(ownerDb), 'web');
  });

  group('a member whose end date has come', () {
    // Bob's time in the Orchard ends 40 seconds after t0, set before he
    // edits: the owner's device first saw that entry at t0, and its clock
    // says t0 + 2 minutes.
    Future<(AppDatabase, CrateSyncEngine)> ended(int bobEditedMs) async {
      final ends = (t0 + 40000) ~/ 1000;
      final set = await sign(3, record.last.hash(_orchard), RecordTypes.memberSet, {'uid': _bob, 'ends_at': ends});
      record = [...record, set];
      addTearDown(() => record = record.sublist(0, 2));
      return bobEdits(bobEditedMs, ownerNow: () => t0 + 120000);
    }

    test('a version they say they edited after it is refused', () async {
      final (ownerDb, owner) = await ended(t0 + 60000);
      expect((await owner.sync()).rejected, 1);
      expect(await label(ownerDb), 'web');
    });

    test('one edited before it is taken', () async {
      final (ownerDb, owner) = await ended(t0 + 20000);
      expect((await owner.sync()).rejected, 0);
      expect(await label(ownerDb), 'from-bob');
    });
  });
}
