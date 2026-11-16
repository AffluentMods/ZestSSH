import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/services/local_state_store.dart';

import '../../helpers/record_commits.dart';
import 'fake_crate_server.dart';

/// One key in two vaults (found in a cryptography review). An
/// item's key is one namespace across a team's vaults, and a version is bound
/// to the vault it sits in, not to the item's: someone who could add in vault
/// A wrote a version in A naming an item of vault B, with a later time. Every
/// device reading both overwrote the item with it, moved it to A and signed
/// the deletion of the real copy in B, for everyone; a fresh device took
/// whichever it read first.
///
/// Now, of two live copies, the one whose author could have moved it out of
/// the other's vault is the item; where both could, the newer; where neither
/// could, a device keeps what it holds, and one that has read nothing yet
/// holds both out.

const _orchard = '0c2f8a6e-5b1d-4d3a-9f47-2a61c0e9b7d3';

// A sorts before B: a device reads A first.
const _a = '2e4a0c8a-7d3f-4f5c-9a69-4c83e2a1d9f5';
const _b = '7b1c9e20-1f6a-4d2e-8b33-90aa11c2d3e4';
const _c = '9d2e0f31-2a7b-4e3f-9c44-a1bb22d3e4f5';

const _owner = 'owner-1';

/// May add in A; nothing in B.
const _mallory = 'mallory-1';

/// May add in A; Connect in B: sees B's items and their keys.
const _peeker = 'peeker-1';

/// May add and edit in B; nothing in A: writes the real items no owner wrote.
const _carol = 'carol-1';

/// May add in A and delete in B: may move an item from B to A.
const _alice = 'alice-1';

/// May edit in A and C; nothing in B: edits an item after it arrived there.
const _dave = 'dave-1';

/// May add in B; nothing in A: the same as Mallory the other way round.
const _bob = 'bob-1';

/// Could delete in B once, and may no longer; may add in A.
const _eve = 'eve-1';

/// May delete in B and add in C; nothing in A: moves an item from B to C.
const _frank = 'frank-1';

/// May add and delete in A; nothing in B.
const _grace = 'grace-1';

const _member = 'role-member';
const _prod = 'prod-db-host-id';

Set<String> _can(String a, [String? b, String? c]) => {CrateSwitches.connect, a, ?b, ?c};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final keys = <String, AccountKeys>{};
  late Uint8List keyA;
  late Uint8List keyB;
  late Uint8List keyC;
  late List<RecordEntry> chain;

  /// The entry Eve still had delete in B at.
  late int eveCouldDelete;
  late FakeCrateServer server;
  final dbs = <AppDatabase>[];

  setUpAll(() async {
    for (final who in [_owner, _mallory, _peeker, _carol, _alice, _dave, _bob, _eve, _frank, _grace]) {
      keys[who] = await AccountKeys.generate();
    }
    chain = [];
    Future<void> add(String type, Map<String, Object?> body) async {
      chain.add(await signRecordEntry(keys[_owner]!,
          orchardId: _orchard,
          seq: chain.length + 1,
          prev: chain.isEmpty ? const [] : chain.last.hash(_orchard),
          type: type,
          body: body,
          by: _owner));
    }

    Future<void> join(String who, Map<String, Set<String>> grants) async =>
        add(RecordTypes.memberAdd, {
          ...recordKeysBody(await keys[who]!.publish(who)),
          'uid': who,
          'role': _member,
          'grants': {for (final g in grants.entries) g.key: switchList(g.value)},
        });

    await add(RecordTypes.create, {
      'owner': {...recordKeysBody(await keys[_owner]!.publish(_owner)), 'uid': _owner},
      'key_commit': testCommit('orchard'),
      'crate': {'id': _a, 'owners_only': false, 'allow': ['forward', 'sftp'], 'key_commit': testCommit(_a)},
      'roles': [
        {
          'id': _member,
          'rank': 10,
          'name_enc': base64Encode(utf8.encode('sealed')),
          'name_gen': 1,
          'can': const <String>[],
          'crates': const <String, Object?>{},
        },
      ],
    });
    await add(RecordTypes.crateAdd,
        {'id': _b, 'owners_only': false, 'allow': ['forward', 'sftp'], 'key_commit': testCommit(_b)});
    await add(RecordTypes.crateAdd,
        {'id': _c, 'owners_only': false, 'allow': ['forward', 'sftp'], 'key_commit': testCommit(_c)});
    await join(_mallory, {_a: _can(CrateSwitches.add)});
    await join(_peeker, {_a: _can(CrateSwitches.add), _b: const {CrateSwitches.connect}});
    await join(_carol, {_b: _can(CrateSwitches.add, CrateSwitches.edit)});
    await join(_alice, {_a: _can(CrateSwitches.add), _b: _can(CrateSwitches.delete)});
    await join(_dave, {_a: _can(CrateSwitches.edit), _c: _can(CrateSwitches.edit)});
    await join(_bob, {_b: _can(CrateSwitches.add)});
    await join(_eve, {_a: _can(CrateSwitches.add), _b: _can(CrateSwitches.delete)});
    await join(_frank, {_b: _can(CrateSwitches.delete), _c: _can(CrateSwitches.add)});
    await join(_grace, {_a: _can(CrateSwitches.add, CrateSwitches.delete)});
    eveCouldDelete = chain.length;
    await add(RecordTypes.memberSet, {'uid': _eve, 'grants': {_a: switchList(_can(CrateSwitches.add))}});
  });

  setUp(() {
    keyA = newSpaceKey();
    keyB = newSpaceKey();
    keyC = newSpaceKey();
    server = FakeCrateServer(accountUid: _owner)
      ..addCrate(_a)
      ..addCrate(_b)
      ..addCrate(_c);
  });

  tearDown(() async {
    for (final db in dbs) {
      await db.close();
    }
    dbs.clear();
  });

  List<int> keyOf(String crate) => switch (crate) {
        _a => keyA,
        _b => keyB,
        _ => keyC,
      };

  Future<List<int>?> signers(String who, int version) async =>
      version == keys[who]?.version ? keys[who]!.signingPublicKey : null;

  /// A device of [uid]'s, holding the whole record, that can open [crates],
  /// with its switches in each as the record gives them.
  Future<({AppDatabase db, CrateSyncEngine engine})> device(String uid, {List<String> crates = const [_a, _b]}) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    dbs.add(db);
    await db.customStatement(
      'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id) '
      "VALUES (1, ?, 'Acme', 'owner', 1, ?)",
      [_orchard, _b],
    );
    final record = await LocalRecord.empty(_orchard).extend(db, chain);
    for (final crate in crates) {
      await db.customStatement(
        "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, 'c', 'manage', ?, 1)",
        [crate, jsonEncode(switchList(record.latest.switchesAt(uid, crate, 0)))],
      );
      await db.customStatement(
        "INSERT INTO space_keys (scope, scope_id, generation, secret) VALUES ('crate', ?, 1, ?)",
        [crate, keyOf(crate)],
      );
    }
    return (
      db: db,
      engine: CrateSyncEngine(
        db: db,
        orchardId: _orchard,
        server: server,
        author: CrateAuthor(uid: uid, keys: keys[uid]!),
        signers: signers,
      ),
    );
  }

  Future<String> itemId(String crate, String kind, String key) async =>
      crateItemId(await crateItemIdKey(keyOf(crate), orchardId: _orchard, crateId: crate), kind: kind, key: key);

  /// A version of [key] of [kind] in [crate], by [by]: a live one with [data]
  /// (a host at [address] by default), or a deletion naming [movedTo]. It names
  /// the record's entry [anchor] (by default the last; 0 for none, as a version
  /// from before the record).
  Future<SealedItem> version(
    String crate,
    String by, {
    String kind = 'host',
    String key = _prod,
    String address = '10.0.0.1',
    Map<String, Object?>? data,
    required int at,
    bool deleted = false,
    String? movedTo,
    int? anchor,
  }) async {
    final seq = anchor ?? chain.length;
    final record = ItemRecord(
      kind: kind,
      key: key,
      author: by,
      authorKeyVersion: keys[by]!.version,
      editedAt: at,
      deleted: deleted,
      movedTo: movedTo,
      data: deleted
          ? null
          : data ??
              {
                'connections': [
                  {
                    'id': key,
                    'label': 'Prod DB',
                    'host': address,
                    'port': 22,
                    'created_at': at ~/ 1000,
                    'updated_at': at ~/ 1000,
                  },
                ],
              },
      recordSeq: seq == 0 ? null : seq,
      recordHead: seq == 0 ? null : chain[seq - 1].hash(_orchard),
    );
    return sealItem(record,
        place: ItemPlace(orchardId: _orchard, crateId: crate, itemId: await itemId(crate, kind, key), generation: 1),
        crateKey: keyOf(crate),
        signer: keys[by]!);
  }

  Future<String?> address(AppDatabase db, [String key = _prod]) async => (await db
          .customSelect('SELECT host FROM connections WHERE id = ?', variables: [Variable(key)])
          .getSingleOrNull())
      ?.read<String>('host');

  Future<String?> homeOf(AppDatabase db, [String kind = 'host', String key = _prod]) async => (await db
          .customSelect('SELECT crate_id FROM crate_items_meta WHERE kind = ? AND item_key = ?',
              variables: [Variable(kind), Variable(key)])
          .getSingleOrNull())
      ?.read<String>('crate_id');

  /// What the server holds of [key] of [kind] in [crate], opened; null for
  /// nothing.
  Future<ItemRecord?> held(String crate, {String kind = 'host', String key = _prod}) async {
    final idKey = await crateItemIdKey(keyOf(crate), orchardId: _orchard, crateId: crate);
    final id = crateItemId(idKey, kind: kind, key: key);
    final item = server.items[crate]![id]?.item;
    if (item == null) return null;
    return openItem(item, orchardId: _orchard, crateId: crate, crateKey: keyOf(crate), idKey: idKey, signers: signers);
  }

  final t0 = DateTime.now().millisecondsSinceEpoch - 3600000;

  group('a copy in another vault, by someone who could not have moved it', () {
    test('is refused: the item stays as it is, where it is, and nothing is signed', () async {
      final d = await device(_owner);
      server.forceItem(_b, await version(_b, _owner, at: t0));
      expect((await d.engine.sync()).rejected, 0);
      expect(await address(d.db), '10.0.0.1');
      expect(await homeOf(d.db), _b);

      // Add in A, nothing in B; a later time than the item's.
      server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 1000));
      server.writeCalls.clear();
      final report = await d.engine.sync();

      expect(report.rejected, 1);
      expect(report.received, 0);
      expect(await address(d.db), '10.0.0.1', reason: 'the host does not point at her server');
      expect(await homeOf(d.db), _b, reason: 'the item did not leave its vault');
      expect((await held(_b))!.deleted, isFalse, reason: 'the real copy is not deleted, for anyone');
      expect((await held(_a))!.deleted, isFalse, reason: 'and nothing is signed about her copy either');
      expect(server.writeCalls, isEmpty, reason: 'this device wrote nothing');
    });

    test('seeing the item at Connect is no more than having nothing there', () async {
      final d = await device(_owner);
      server.forceItem(_b, await version(_b, _owner, at: t0));
      await d.engine.sync();
      server.forceItem(_a, await version(_a, _peeker, address: 'evil.example.com', at: t0 + 1000));
      expect((await d.engine.sync()).rejected, 1);
      expect(await address(d.db), '10.0.0.1');
    });

    test('with an edit of its own waiting here: the change stays, and goes as usual', () async {
      final d = await device(_owner);
      server.forceItem(_b, await version(_b, _owner, at: t0));
      await d.engine.sync();
      await d.db.customStatement("UPDATE connections SET label = 'mine' WHERE id = ?", [_prod]);
      server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 7200000));
      final report = await d.engine.sync();
      expect(report.rejected, 1);
      expect(report.conflictsLost, 0, reason: 'nothing to lose to');
      expect(report.sent, 1);
      final there = await held(_b);
      expect(((there!.data!['connections'] as List).single as Map)['label'], 'mine');
      expect(await address(d.db), '10.0.0.1');
    });

    test('the real item goes on as before: its next edit is taken, her next one is not', () async {
      final d = await device(_owner);
      server.forceItem(_b, await version(_b, _owner, at: t0));
      await d.engine.sync();
      server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 1000));
      await d.engine.sync();

      server.forceItem(_b, await version(_b, _carol, address: '10.0.0.2', at: t0 + 2000));
      server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 3000));
      final report = await d.engine.sync();
      expect(report.received, 1);
      expect(report.rejected, 1);
      expect(await address(d.db), '10.0.0.2');
      expect(await homeOf(d.db), _b);
    });

    test('naming an entry from when its author could still delete there changes nothing', () async {
      // She held the move's right at the entry she names, and lost it before
      // she wrote this: its time says so, and the entry alone would not.
      final d = await device(_owner);
      server.forceItem(_b, await version(_b, _owner, at: t0));
      await d.engine.sync();
      server.forceItem(_a,
          await version(_a, _eve, address: 'evil.example.com', anchor: eveCouldDelete, at: DateTime.now().millisecondsSinceEpoch + 60000));
      expect((await d.engine.sync()).rejected, 1);
      expect(await address(d.db), '10.0.0.1');
      expect(await homeOf(d.db), _b);
    });

    test('every kind of item, and a pin: the same', () async {
      // The owner's device makes one of each in B, as the app does; a second
      // of the owner's devices holds them; Mallory copies each to A.
      final made = await device(_owner);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      Future<void> run(String sql) => made.db.customStatement(sql);
      await run("INSERT INTO connections (id, label, host, port, created_at, updated_at) VALUES ('h', 'H', '10.0.0.1', 22, $now, $now)");
      await run("INSERT INTO identities (id, label, username, auth_method, created_at) VALUES ('k', 'K', 'root', 'password', $now)");
      await run("INSERT INTO connection_groups (id, name, created_at) VALUES ('g', 'G', $now)");
      await run("INSERT INTO snippets (id, label, command, created_at, updated_at) VALUES ('s', 'S', 'ls', $now, $now)");
      await run("INSERT INTO snippet_categories (name) VALUES ('Ops')");
      await run('INSERT INTO port_forward_rules (id, connection_id, type, bind_port, remote_host, remote_port, created_at) '
          "VALUES ('f', 'h', 'local', 8080, 'db', 5432, $now)");
      await run("INSERT INTO networks (id, name, icon_code_point, created_at) VALUES ('n', 'N', 1, $now)");
      await run("INSERT INTO terminal_triggers (id, name, pattern, created_at) VALUES ('t', 'T', 'x', $now)");
      final pin = '10.0.0.1|22||$_b';
      await run("INSERT INTO team_host_keys (id, host, port, via_scope, host_keys) VALUES ('$pin', '10.0.0.1', 22, '', '[]')");
      final items = {
        'host': 'h',
        'key': 'k',
        'group': 'g',
        'snippet': 's',
        'category': 'Ops',
        'forward': 'f',
        'network': 'n',
        'trigger': 't',
        kHostKeyKind: pin,
      };
      expect((await made.engine.sync()).sent, items.length);

      final d = await device(_owner);
      await d.engine.sync();
      for (final e in items.entries) {
        final rows = (await held(_b, kind: e.key, key: e.value))!.data!;
        server.forceItem(_a, await version(_a, _mallory, kind: e.key, key: e.value, data: rows, at: t0 + 7200000));
      }
      server.writeCalls.clear();
      final report = await d.engine.sync();
      expect(report.rejected, items.length);
      expect(report.received, 0);
      expect(server.writeCalls, isEmpty);
      for (final e in items.entries) {
        expect(await homeOf(d.db, e.key, e.value), _b, reason: e.key);
        expect((await held(_b, kind: e.key, key: e.value))!.deleted, isFalse, reason: e.key);
      }
    });
  });

  group('a real move by someone allowed', () {
    test('made in the app: every device follows it, whichever vault it reads first', () async {
      // B to A: a device reads where it went first. A to B: where it left.
      for (final (from, to) in [(_b, _a), (_a, _b)]) {
        final mover = await device(_owner);
        server.forceItem(from, await version(from, _owner, at: t0));
        await mover.engine.sync();
        final d = await device(_owner);
        await d.engine.sync();
        await d.db.customStatement('UPDATE connections SET pinned = 1 WHERE id = ?', [_prod]);

        await mover.engine.moveItem('host', _prod, to);
        await mover.engine.sync();
        server.writeCalls.clear();
        final report = await d.engine.sync();

        expect(report.rejected, 0, reason: '$from to $to');
        expect(await homeOf(d.db), to);
        expect(await address(d.db), '10.0.0.1');
        final row = await d.db.customSelect('SELECT pinned FROM connections WHERE id = ?', variables: [const Variable(_prod)]).getSingle();
        expect(row.read<int>('pinned'), 1, reason: 'a move is not a delete and a new one');
        expect(server.writeCalls, isEmpty, reason: 'the move was all done: nothing is left to do');
        server.items[_a]!.clear();
        server.items[_b]!.clear();
      }
    });

    test('by a member who may delete in one vault and add in the other, and no more', () async {
      final d = await device(_owner);
      server.forceItem(_b, await version(_b, _carol, at: t0));
      await d.engine.sync();
      expect(await homeOf(d.db), _b);

      final mover = await device(_alice);
      await mover.engine.sync();
      await mover.engine.moveItem('host', _prod, _a);
      final moved = await mover.engine.sync();
      expect(moved.sent, 1);

      final report = await d.engine.sync();
      expect(report.rejected, 0);
      expect(await homeOf(d.db), _a);
      expect((await held(_b))!.movedTo, _a);
      expect((await held(_a))!.author, _alice);
    });

    test('an edit since, by someone who could not have moved it, reached after the move: it is the item', () async {
      // A first, B second: the device meets the edit while the item is still
      // in B here, and refuses it. B's deletion says it moved: read again.
      final d = await device(_owner);
      server.forceItem(_b, await version(_b, _carol, at: t0));
      await d.engine.sync();

      server.forceItem(_a, await version(_a, _alice, at: t0 + 1000));
      server.forceItem(_b, await version(_b, _alice, at: t0 + 1000, deleted: true, movedTo: _a));
      server.forceItem(_a, await version(_a, _dave, address: '10.0.0.3', at: t0 + 2000));
      server.writeCalls.clear();

      final report = await d.engine.sync();
      expect(report.rejected, 0, reason: 'read again in the same sync, it is no refusal');
      expect(await address(d.db), '10.0.0.3');
      expect(await homeOf(d.db), _a);
      expect(server.writeCalls, isEmpty);
    });

    test('and where the move is only read at a later sync: the edit is not lost', () async {
      final d = await device(_owner);
      server.forceItem(_b, await version(_b, _carol, at: t0));
      await d.engine.sync();

      server.forceItem(_a, await version(_a, _dave, address: '10.0.0.3', at: t0 + 2000));
      expect((await d.engine.sync()).rejected, 1);
      expect(await address(d.db), '10.0.0.1');

      server.forceItem(_b, await version(_b, _alice, at: t0 + 1000 + 2000, deleted: true, movedTo: _a));
      final report = await d.engine.sync();
      expect(await homeOf(d.db), _a);
      expect(await address(d.db), '10.0.0.3');
      expect(report.rejected, 0);
    });

    test('a read again survives a sync that stops part way', () async {
      final d = await device(_owner);
      server.forceItem(_b, await version(_b, _carol, at: t0));
      await d.engine.sync();
      server.forceItem(_a, await version(_a, _dave, address: '10.0.0.3', at: t0 + 2000));
      await d.engine.sync();
      server.forceItem(_b, await version(_b, _alice, at: t0 + 3000, deleted: true, movedTo: _a));

      // A second engine on the same database: the first was stopped after it
      // read the move, before it read A again.
      final stopped = CrateSyncEngine(
        db: d.db,
        orchardId: _orchard,
        server: _FailsOnce(server, _a, afterFirst: true),
        author: CrateAuthor(uid: _owner, keys: keys[_owner]!),
        signers: signers,
      );
      await expectLater(stopped.sync(), throwsA(isA<OrchardServerException>()));
      expect(await homeOf(d.db), _a);
      expect(await address(d.db), '10.0.0.1', reason: 'not read again yet');

      await d.engine.sync();
      expect(await address(d.db), '10.0.0.3');
    });

    test('old data: versions from before the record count by the record as it stands', () async {
      final d = await device(_owner);
      server.forceItem(_b, await version(_b, _owner, at: t0, anchor: 0));
      await d.engine.sync();
      server.forceItem(_a, await version(_a, _owner, at: t0 + 1000, anchor: 0));
      server.forceItem(_b, await version(_b, _owner, at: t0 + 1000, anchor: 0, deleted: true, movedTo: _a));
      expect((await d.engine.sync()).rejected, 0);
      expect(await homeOf(d.db), _a);

      // And by someone who could not have moved it, the same as ever.
      final e = await device(_owner);
      server.items[_a]!.clear();
      server.items[_b]!.clear();
      server.forceItem(_b, await version(_b, _owner, at: t0, anchor: 0));
      await e.engine.sync();
      server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 1000, anchor: 0));
      expect((await e.engine.sync()).rejected, 1);
      expect(await address(e.db), '10.0.0.1');
    });

    test('an edit of the copy it leaves, by someone who could not have moved it: the move still ends, on every device',
        () async {
      // E held the edit; D read the move first, and means to remove that copy
      // by the right the move's author had. Both end where the move went.
      server.forceItem(_b, await version(_b, _owner, at: t0));
      final d = await device(_owner);
      await d.engine.sync();
      final e = await device(_owner);
      await e.engine.sync();

      server.forceItem(_b, await version(_b, _carol, address: '10.0.0.5', at: t0 + 2000));
      await e.engine.sync();
      expect(await address(e.db), '10.0.0.5');

      server.forceItem(_a, await version(_a, _alice, address: '10.0.0.4', at: t0 + 1000));
      final report = await d.engine.sync();
      expect(report.rejected, 1, reason: "the edit is not the item, and D's deletion goes over it");
      expect(await address(d.db), '10.0.0.4');
      expect(await homeOf(d.db), _a);
      final gone = (await held(_b))!;
      expect(gone.deleted, isTrue);
      expect(gone.movedTo, _a);
      expect(gone.editedAt, t0 + 2001, reason: 'later than the edit, so that a device holding it takes the deletion');

      await e.engine.sync();
      expect(await address(e.db), '10.0.0.4');
      expect(await homeOf(e.db), _a);
    });

    test('moved here, not yet written there, and edited where it is: still a change like any other', () async {
      final mover = await device(_alice);
      server.forceItem(_b, await version(_b, _owner, at: t0));
      await mover.engine.sync();
      await mover.engine.moveItem('host', _prod, _a);

      server.forceItem(_b, await version(_b, _carol, address: '10.0.0.5', at: DateTime.now().millisecondsSinceEpoch + 60000));
      final report = await mover.engine.sync();
      expect(report.conflictsLost, 1);
      expect(report.rejected, 0);
      expect(await homeOf(mover.db), _b);
      expect(await address(mover.db), '10.0.0.5');
      expect(server.items[_a], isEmpty);
    });

    test('moved twice while a device was away: it follows both, to an edit since by someone who could not have moved it',
        () async {
      // In reading order (A, B, C) the device meets the second move's deletion,
      // then the first's, while it still holds the item at the chain's start,
      // and then the edit.
      final d = await device(_owner, crates: const [_a, _b, _c]);
      server.forceItem(_b, await version(_b, _carol, at: t0));
      await d.engine.sync();
      expect(await homeOf(d.db), _b);

      server.forceItem(_b, await version(_b, _owner, at: t0 + 1000, deleted: true, movedTo: _a));
      server.forceItem(_a, await version(_a, _owner, at: t0 + 2000, deleted: true, movedTo: _c));
      server.forceItem(_c, await version(_c, _dave, address: '10.0.0.3', at: t0 + 3000));

      final report = await d.engine.sync();
      expect(report.rejected, 0);
      expect(await homeOf(d.db), _c);
      expect(await address(d.db), '10.0.0.3');
    });

    test('a move that met a newer edit as it was sent: its other half is not sent after all', () async {
      final mover = await device(_alice);
      server.forceItem(_b, await version(_b, _owner, at: t0));
      await mover.engine.sync();
      await mover.engine.moveItem('host', _prod, _a);

      // The edit reaches the server after this device read it, and before its
      // deletion gets there.
      final racing = CrateSyncEngine(
        db: mover.db,
        orchardId: _orchard,
        server: _BeforeFirstWrite(server, () async {
          server.forceItem(_b,
              await version(_b, _carol, address: '10.0.0.5', at: DateTime.now().millisecondsSinceEpoch + 60000));
        }),
        author: CrateAuthor(uid: _alice, keys: keys[_alice]!),
        signers: signers,
      );
      final report = await racing.sync();

      expect(report.conflictsLost, 1);
      expect(await homeOf(mover.db), _b);
      expect(await address(mover.db), '10.0.0.5');
      expect(server.items[_a], isEmpty, reason: 'no second copy is left behind in the vault it did not reach');
      expect((await held(_b))!.deleted, isFalse);
    });

    test('a server restored from a backup lost the deletion a move left: the old copy goes again', () async {
      final d = await device(_owner);
      server.forceItem(_b, await version(_b, _carol, at: t0));
      await d.engine.sync();
      server.forceItem(_a, await version(_a, _alice, at: t0 + 1000));
      server.forceItem(_b, await version(_b, _alice, at: t0 + 1000, deleted: true, movedTo: _a));
      await d.engine.sync();
      expect(await homeOf(d.db), _a);

      // Back to before the move in B: the copy Carol wrote is there again, and
      // this device reads every vault again.
      server.forceItem(_b, await version(_b, _carol, at: t0));
      await LocalStateStore(d.db).write(kServerWentBackState, '1');
      final report = await d.engine.sync();
      expect(report.rejected, 0);
      expect(await homeOf(d.db), _a);
      expect((await held(_b))!.deleted, isTrue);
      expect((await held(_b))!.movedTo, _a);
    });

    test('two live copies, each moved by someone who could: the newer decides, and the other goes', () async {
      final d = await device(_owner);
      server.forceItem(_b, await version(_b, _owner, at: t0));
      await d.engine.sync();
      server.forceItem(_a, await version(_a, _owner, address: '10.0.0.9', at: t0 + 1000));
      final report = await d.engine.sync();
      expect(report.received, 1);
      expect(await homeOf(d.db), _a);
      expect(await address(d.db), '10.0.0.9');
      expect((await held(_b))!.deleted, isTrue);
      expect((await held(_b))!.movedTo, _a);
    });
  });

  group('a version older than the one held, in another vault', () {
    test('is never taken, by whoever could have moved it, and is counted', () async {
      // An old live copy in A, sent again: the item is in B now, newer.
      final d = await device(_owner);
      server.forceItem(_b, await version(_b, _owner, at: t0 + 5000));
      await d.engine.sync();
      server.forceItem(_a, await version(_a, _owner, address: 'old.example.com', at: t0));
      final report = await d.engine.sync();
      expect(report.rejected, 1);
      expect(report.received, 0);
      expect(await address(d.db), '10.0.0.1');
      expect(await homeOf(d.db), _b);
      expect((await held(_b))!.deleted, isFalse);
    });

    test('held by someone who could not have moved it: taken for nothing, and nothing is signed', () async {
      final d = await device(_owner);
      server.forceItem(_b, await version(_b, _carol, at: t0 + 5000));
      await d.engine.sync();
      server.forceItem(_a, await version(_a, _alice, address: 'old.example.com', at: t0));
      server.writeCalls.clear();
      expect((await d.engine.sync()).rejected, 1);
      expect(await address(d.db), '10.0.0.1');
      expect(await homeOf(d.db), _b);
      expect(server.writeCalls, isEmpty);
    });
  });

  group('a device that has read nothing yet', () {
    test('a copy read first, by someone who could not have moved it, gives way, whatever time it says', () async {
      // Read first and dated far ahead: it still is not the item.
      server.forceItem(_b, await version(_b, _owner, at: t0));
      server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 86400000));
      final d = await device(_owner);
      server.writeCalls.clear();
      final report = await d.engine.sync();
      expect(await address(d.db), '10.0.0.1');
      expect(await homeOf(d.db), _b);
      expect(report.rejected, 0);
      expect(server.writeCalls, isEmpty, reason: 'nothing is signed for what it only just read');
      expect((await held(_b))!.deleted, isFalse);
      expect((await held(_a))!.deleted, isFalse);
    });

    test('the same answer when the real copy is read first', () async {
      server.forceItem(_a, await version(_a, _owner, at: t0));
      server.forceItem(_b, await version(_b, _bob, address: 'evil.example.com', at: t0 + 86400000));
      final d = await device(_owner);
      server.writeCalls.clear();
      final report = await d.engine.sync();
      expect(report.rejected, 1);
      expect(await address(d.db), '10.0.0.1');
      expect(await homeOf(d.db), _a);
      expect(server.writeCalls, isEmpty);
    });

    test('and the same answer as a device that held the item all along', () async {
      final along = await device(_owner);
      server.forceItem(_b, await version(_b, _owner, at: t0));
      await along.engine.sync();
      server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 1000));
      await along.engine.sync();

      final fresh = await device(_owner);
      await fresh.engine.sync();
      expect(await address(fresh.db), await address(along.db));
      expect(await homeOf(fresh.db), await homeOf(along.db));
    });

    test('where both could have moved it: the newer, whichever is read first', () async {
      for (final (older, newer) in [(_a, _b), (_b, _a)]) {
        server.items[_a]!.clear();
        server.items[_b]!.clear();
        server.forceItem(older, await version(older, _owner, address: 'old.example.com', at: t0));
        server.forceItem(newer, await version(newer, _owner, address: 'new.example.com', at: t0 + 1000));
        final d = await device(_owner);
        await d.engine.sync();
        expect(await address(d.db), 'new.example.com', reason: 'newer in $newer');
        expect(await homeOf(d.db), newer);
      }
    });

    test('where neither could have: it takes neither, and signs nothing; a device that held one keeps it', () async {
      final along = await device(_owner);
      server.forceItem(_b, await version(_b, _carol, at: t0));
      await along.engine.sync();

      server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 1000));
      final kept = await along.engine.sync();
      expect(kept.rejected, 1);
      expect(await address(along.db), '10.0.0.1', reason: 'it held the real one, and takes no other');

      final d = await device(_owner);
      server.writeCalls.clear();
      final report = await d.engine.sync();
      expect(await address(d.db), isNull, reason: 'nobody can tell which is the item');
      expect(await homeOf(d.db), isNull);
      expect(report.rejected, 1);
      expect(server.writeCalls, isEmpty);
      expect((await held(_a))!.deleted, isFalse);
      expect((await held(_b))!.deleted, isFalse);

      // Stays out at the next sync, and when her copy changes.
      server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 2000));
      expect((await d.engine.sync()).rejected, 1);
      expect(await address(d.db), isNull);
    });

    test('the same whichever is read first', () async {
      server.forceItem(_a, await version(_a, _dave, at: t0));
      server.forceItem(_b, await version(_b, _carol, address: '10.0.0.2', at: t0));
      final d = await device(_owner);
      await d.engine.sync();
      expect(await address(d.db), isNull);
    });

    test('someone who could move it writes it: that copy is the item', () async {
      server.forceItem(_b, await version(_b, _carol, at: t0));
      server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 1000));
      final d = await device(_owner);
      await d.engine.sync();
      expect(await address(d.db), isNull);

      server.forceItem(_b, await version(_b, _owner, address: '10.0.0.2', at: t0 + 2000));
      final report = await d.engine.sync();
      expect(report.received, 1);
      expect(await address(d.db), '10.0.0.2');
      expect(await homeOf(d.db), _b);
    });

    test('one of the two goes: what is left is the item', () async {
      for (final (gone, left, there) in [(_a, _b, '10.0.0.1'), (_b, _a, 'evil.example.com')]) {
        server.items[_a]!.clear();
        server.items[_b]!.clear();
        server.forceItem(_b, await version(_b, _carol, at: t0));
        server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0));
        final d = await device(_owner);
        await d.engine.sync();
        expect(await address(d.db), isNull);

        // Deleted by someone who may.
        server.forceItem(gone, await version(gone, _owner, at: t0 + 1000, deleted: true));
        final report = await d.engine.sync();
        expect(report.rejected, 0);
        expect(await address(d.db), there, reason: '$gone gone');
        expect(await homeOf(d.db), left);
      }
    });

    test('stopped part way through the first sync, it still takes neither', () async {
      server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 1000));
      server.forceItem(_b, await version(_b, _carol, at: t0));
      final d = await device(_owner);
      final stopped = CrateSyncEngine(
        db: d.db,
        orchardId: _orchard,
        server: _FailsOnce(server, _b),
        author: CrateAuthor(uid: _owner, keys: keys[_owner]!),
        signers: signers,
      );
      await expectLater(stopped.sync(), throwsA(isA<OrchardServerException>()));
      await d.engine.sync();
      expect(await address(d.db), isNull);
    });

    test('a device that read for long and is given a new vault keeps what it holds', () async {
      final d = await device(_owner, crates: const [_b]);
      server.forceItem(_b, await version(_b, _carol, at: t0));
      await d.engine.sync();
      expect(await address(d.db), '10.0.0.1');

      server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 1000));
      await d.db.customStatement(
        "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, 'c', 'manage', ?, 1)",
        [_a, jsonEncode(switchList(CrateSwitches.all.difference({CrateSwitches.agent})))],
      );
      await d.db.customStatement(
        "INSERT INTO space_keys (scope, scope_id, generation, secret) VALUES ('crate', ?, 1, ?)",
        [_a, keyA],
      );
      expect((await d.engine.sync()).rejected, 1);
      expect(await address(d.db), '10.0.0.1');
    });
  });

  group('two copies neither could move: the list, and who may settle it', () {
    Future<void> twoCopies() async {
      server.forceItem(_b, await version(_b, _carol, at: t0));
      server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 1000));
    }

    Map<String, HeldBackCopy> byVault(HeldBackItem item) => {for (final c in item.copies) c.crateId: c};

    test('are listed with their vault, who wrote each and when, and a later edit shows', () async {
      await twoCopies();
      final d = await device(_owner);
      await d.engine.sync();
      expect(await address(d.db), isNull);
      final item = (await d.engine.heldBack()).single;
      expect(item.kind, 'host');
      expect(item.key, _prod);
      final copies = byVault(item);
      expect(copies.keys, unorderedEquals([_a, _b]));
      expect(copies[_a]!.author, _mallory);
      expect(copies[_a]!.editedAt, t0 + 1000);
      expect(copies[_b]!.author, _carol);
      expect(copies[_b]!.editedAt, t0);
      expect(copies[_b]!.name, 'Prod DB');
      expect(copies[_b]!.here, isFalse);
      expect(item.mayAct, isTrue);

      server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 2000));
      await d.engine.sync();
      expect(byVault((await d.engine.heldBack()).single)[_a]!.editedAt, t0 + 2000);
    });

    test('someone who could move it writes it, or one goes: nothing is listed any more', () async {
      await twoCopies();
      final written = await device(_owner);
      final gone = await device(_owner);
      await written.engine.sync();
      await gone.engine.sync();
      server.forceItem(_b, await version(_b, _owner, at: t0 + 2000));
      await written.engine.sync();
      expect(await written.engine.heldBack(), isEmpty);

      server.forceItem(_a, await version(_a, _owner, at: t0 + 3000, deleted: true));
      await gone.engine.sync();
      expect(await gone.engine.heldBack(), isEmpty);
    });

    test('Keep this one: signed by the person, the other copy goes, and every device settles', () async {
      for (final (kept, gone, there) in [(_a, _b, 'evil.example.com'), (_b, _a, '10.0.0.1')]) {
        server.items[_a]!.clear();
        server.items[_b]!.clear();
        await twoCopies();
        final along = await device(_peeker);
        // A device that read nothing yet, which holds both out.
        final waiting = await device(_peeker);
        await waiting.engine.sync();
        expect(await address(waiting.db), isNull);

        final d = await device(_owner);
        await d.engine.sync();
        expect(await d.engine.keepHeldBack('host', _prod, kept), isTrue);
        await d.engine.sync();
        expect(await address(d.db), there, reason: 'kept $kept');
        expect(await homeOf(d.db), kept);
        final written = (await held(kept))!;
        expect(written.deleted, isFalse);
        expect(written.author, _owner);
        final deletion = (await held(gone))!;
        expect(deletion.deleted, isTrue);
        expect(deletion.author, _owner);
        expect(deletion.movedTo, kept);
        expect(await d.engine.heldBack(), isEmpty);

        for (final other in [waiting, along, await device(_mallory)]) {
          await other.engine.sync();
          expect(await address(other.db), there);
          expect(await homeOf(other.db), kept);
          expect(await other.engine.heldBack(), isEmpty);
        }
      }
    });

    test('Remove: that copy goes, nothing else is signed, and what is left shows at once', () async {
      await twoCopies();
      final waiting = await device(_peeker);
      await waiting.engine.sync();
      final d = await device(_owner);
      await d.engine.sync();
      expect(await d.engine.removeHeldBack('host', _prod, _a), isTrue);
      await d.engine.sync();
      expect(await address(d.db), '10.0.0.1');
      expect(await homeOf(d.db), _b);
      expect((await held(_a))!.deleted, isTrue);
      expect((await held(_b))!.author, _carol, reason: 'its copy is not written again');
      expect(await d.engine.heldBack(), isEmpty);

      await waiting.engine.sync();
      expect(await address(waiting.db), '10.0.0.1');
    });

    test('a Remove goes with what someone changed since, whatever time that says', () async {
      await twoCopies();
      final d = await device(_owner);
      await d.engine.sync();
      expect(await d.engine.removeHeldBack('host', _prod, _a), isTrue);
      server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 172800000));
      await d.engine.sync();
      expect((await held(_a))!.deleted, isTrue);
      expect(await address(d.db), '10.0.0.1');
    });

    test('a Remove yields to someone who could have moved it, writing that copy since', () async {
      await twoCopies();
      final d = await device(_owner);
      await d.engine.sync();
      expect(await d.engine.removeHeldBack('host', _prod, _a), isTrue);
      server.forceItem(_a, await version(_a, _owner, address: 'new.example.com', at: t0 + 2000));
      await d.engine.sync();
      expect(await address(d.db), 'new.example.com');
      expect((await held(_a))!.deleted, isFalse);
      expect(await d.engine.heldBack(), isEmpty);
    });

    test('a person without the rights is offered nothing, and nothing they try is done', () async {
      await twoCopies();
      final d = await device(_dave);
      await d.engine.sync();
      final item = (await d.engine.heldBack()).single;
      expect(item.mayAct, isFalse);
      server.writeCalls.clear();
      expect(await d.engine.keepHeldBack('host', _prod, _a), isFalse);
      expect(await d.engine.keepHeldBack('host', _prod, _b), isFalse);
      expect(await d.engine.removeHeldBack('host', _prod, _a), isFalse);
      expect(await d.engine.removeHeldBack('host', _prod, _b), isFalse);
      await d.engine.sync();
      expect(server.writeCalls, isEmpty);
      expect(await address(d.db), isNull);
    });

    test('each right counts on its own', () async {
      await twoCopies();
      // Adds and deletes in A, nothing in B: may remove that copy, and keep none.
      final grace = await device(_grace);
      await grace.engine.sync();
      final hers = byVault((await grace.engine.heldBack()).single);
      expect(hers[_a]!.mayRemove, isTrue);
      expect(hers[_a]!.mayKeep, isFalse);
      expect(hers[_b]!.mayRemove, isFalse);
      expect(hers[_b]!.mayKeep, isFalse);
      expect(await grace.engine.keepHeldBack('host', _prod, _a), isFalse);
      // Adds in A and deletes in B: may remove that copy, and keep none, as keeping
      // is editing.
      final alice = await device(_alice);
      await alice.engine.sync();
      final others = byVault((await alice.engine.heldBack()).single);
      expect(others[_b]!.mayRemove, isTrue);
      expect(others[_a]!.mayRemove, isFalse);
      expect(others[_a]!.mayKeep, isFalse);
      expect(others[_b]!.mayKeep, isFalse);
    });

    test('the rights gone before it is read again: the choice goes, and nothing is signed', () async {
      await twoCopies();
      final d = await device(_owner);
      await d.engine.sync();
      expect(await d.engine.keepHeldBack('host', _prod, _a), isTrue);
      await d.db.customStatement('UPDATE orchard_crates SET switches = ? WHERE crate_id = ?', ['[]', _b]);
      server.writeCalls.clear();
      await d.engine.sync();
      expect(server.writeCalls, isEmpty);
      expect(await address(d.db), isNull);
      expect(byVault((await d.engine.heldBack()).single)[_a]!.mayKeep, isFalse);
    });

    test('kept with a time far ahead on the other copy: what is written is later still', () async {
      server.forceItem(_b, await version(_b, _carol, at: t0));
      server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 172800000));
      final d = await device(_owner);
      await d.engine.sync();
      expect(await d.engine.keepHeldBack('host', _prod, _b), isTrue);
      await d.engine.sync();
      expect((await held(_b))!.editedAt, greaterThan(t0 + 172800000));
      expect((await held(_a))!.deleted, isTrue);
    });

    test('kept here over a change of its own still waiting: the change goes, and the kept one is what is sent', () async {
      server.forceItem(_b, await version(_b, _carol, at: t0));
      final along = await device(_owner);
      await along.engine.sync();
      server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 1000));
      await along.engine.sync();
      await along.db.customStatement('UPDATE connections SET host = ? WHERE id = ?', ['203.0.113.9', _prod]);
      expect(await along.engine.keepHeldBack('host', _prod, _a), isTrue);
      await along.engine.sync();
      expect(await address(along.db), 'evil.example.com');
      final written = (await held(_a))!;
      expect(written.author, _owner);
      expect(written.editedAt, greaterThan(t0 + 1000));
      expect((await held(_b))!.deleted, isTrue);
      final idKey = await crateItemIdKey(keyOf(_b), orchardId: _orchard, crateId: _b);
      final kept = [
        for (final item in server.history[await itemId(_b, 'host', _prod)]!)
          await openItem(item, orchardId: _orchard, crateId: _b, crateKey: keyOf(_b), idKey: idKey, signers: signers),
      ];
      expect(
        kept.any((v) => ((v.data?['connections'] as List?)?.first as Map?)?['host'] == '203.0.113.9'),
        isTrue,
        reason: 'the change is kept in the history',
      );
    });

    test('a copy that became a deletion is off the list, and so is one by someone who could move it', () async {
      server.forceItem(_b, await version(_b, _carol, at: t0 + 5000));
      final along = await device(_owner);
      await along.engine.sync();
      server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 6000));
      await along.engine.sync();
      expect(await along.engine.heldBack(), hasLength(1));
      // Older than what is held, by someone who could have moved it: refused, and
      // no longer a pair nobody can tell apart.
      server.forceItem(_a, await version(_a, _owner, address: 'evil.example.com', at: t0 + 1000));
      await along.engine.sync();
      expect(await along.engine.heldBack(), isEmpty);

      server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 7000));
      await along.engine.sync();
      expect(await along.engine.heldBack(), hasLength(1));
      // Moved on to a vault this device cannot open.
      server.forceItem(_a, await version(_a, _owner, at: t0 + 8000, deleted: true, movedTo: _c));
      await along.engine.sync();
      expect(await along.engine.heldBack(), isEmpty);
    });

    test('a device that keeps the one it held lists them too: nobody else could see it', () async {
      for (final act in ['keep held', 'keep other', 'remove other']) {
        server.items[_a]!.clear();
        server.items[_b]!.clear();
        server.forceItem(_b, await version(_b, _carol, at: t0));
        final along = await device(_owner);
        await along.engine.sync();
        server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 1000));
        await along.engine.sync();
        expect(await address(along.db), '10.0.0.1');

        final copies = byVault((await along.engine.heldBack()).single);
        expect(copies[_b]!.here, isTrue);
        expect(copies[_b]!.author, _carol);
        expect(copies[_b]!.name, 'Prod DB');
        expect(copies[_a]!.author, _mallory);
        expect(copies[_b]!.mayKeep, isTrue);
        expect(copies[_a]!.mayKeep, isTrue);
        expect(copies[_a]!.mayRemove, isTrue);
        expect(copies[_b]!.mayRemove, isFalse, reason: 'it keeps the other instead');
        expect(await along.engine.removeHeldBack('host', _prod, _b), isFalse);

        switch (act) {
          case 'keep held':
            expect(await along.engine.keepHeldBack('host', _prod, _b), isTrue);
            await along.engine.sync();
            expect(await address(along.db), '10.0.0.1');
            expect((await held(_b))!.author, _owner);
            expect((await held(_a))!.deleted, isTrue);
          case 'keep other':
            expect(await along.engine.keepHeldBack('host', _prod, _a), isTrue);
            await along.engine.sync();
            expect(await address(along.db), 'evil.example.com');
            expect(await homeOf(along.db), _a);
            expect((await held(_a))!.author, _owner);
            expect((await held(_b))!.deleted, isTrue);
          default:
            expect(await along.engine.removeHeldBack('host', _prod, _a), isTrue);
            await along.engine.sync();
            expect(await address(along.db), '10.0.0.1');
            expect((await held(_b))!.author, _carol);
            expect((await held(_a))!.deleted, isTrue);
        }
        expect(await along.engine.heldBack(), isEmpty, reason: act);
      }
    });

    test('a device that holds a version by someone who could have moved it lists nothing', () async {
      server.forceItem(_b, await version(_b, _owner, at: t0));
      final along = await device(_owner);
      await along.engine.sync();
      server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 1000));
      await along.engine.sync();
      expect(await along.engine.heldBack(), isEmpty);
    });

    test('kinds whose key is a name are no such pair', () async {
      Map<String, Object?> category(int color) => {
            'snippet_categories': [
              {'name': 'Ops', 'color_value': color},
            ],
          };
      server.forceItem(_a, await version(_a, _dave, kind: 'category', key: 'Ops', data: category(1), at: t0));
      server.forceItem(_b, await version(_b, _carol, kind: 'category', key: 'Ops', data: category(2), at: t0 + 1000));
      final fresh = await device(_owner);
      await fresh.engine.sync();
      expect(await fresh.engine.heldBack(), isEmpty);
    });
  });

  group('all a device holds of the item is a deletion', () {
    /// This person is given [crate], as a refresh of the team does it.
    Future<void> giveVault(AppDatabase db, String crate) async {
      await db.customStatement(
        "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, 'c', 'manage', ?, 1)",
        [crate, jsonEncode(switchList(CrateSwitches.all.difference({CrateSwitches.agent})))],
      );
      await db.customStatement(
        "INSERT INTO space_keys (scope, scope_id, generation, secret) VALUES ('crate', ?, 1, ?)",
        [crate, keyOf(crate)],
      );
    }

    test('moved to a vault this person could not open, then given it: an edit since, by someone who could not have moved it, is the item',
        () async {
      final d = await device(_owner, crates: const [_b]);
      server.forceItem(_b, await version(_b, _carol, at: t0));
      await d.engine.sync();

      server.forceItem(_a, await version(_a, _alice, at: t0 + 1000));
      server.forceItem(_b, await version(_b, _alice, at: t0 + 1000, deleted: true, movedTo: _a));
      await d.engine.sync();
      expect(await address(d.db), isNull, reason: 'it moved where this person cannot look');

      server.forceItem(_a, await version(_a, _dave, address: '10.0.0.2', at: t0 + 2000));
      await giveVault(d.db, _a);
      server.writeCalls.clear();
      final report = await d.engine.sync();
      expect(report.rejected, 0);
      expect(report.received, 1);
      expect(await address(d.db), '10.0.0.2');
      expect(await homeOf(d.db), _a);
      expect(server.writeCalls, isEmpty, reason: 'nothing is signed for it');
      expect((await held(_a))!.deleted, isFalse);

      // And it goes on as any item does.
      server.forceItem(_a, await version(_a, _dave, address: '10.0.0.3', at: t0 + 3000));
      final later = await d.engine.sync();
      expect(later.rejected, 0);
      expect(await address(d.db), '10.0.0.3');
    });

    test('the same with no edit since the move, and the same as a fresh device', () async {
      final d = await device(_owner, crates: const [_b]);
      server.forceItem(_b, await version(_b, _carol, at: t0));
      await d.engine.sync();
      server.forceItem(_a, await version(_a, _alice, address: '10.0.0.2', at: t0 + 1000));
      server.forceItem(_b, await version(_b, _alice, at: t0 + 1000, deleted: true, movedTo: _a));
      await d.engine.sync();
      await giveVault(d.db, _a);
      expect((await d.engine.sync()).rejected, 0);
      expect(await address(d.db), '10.0.0.2');

      final fresh = await device(_owner);
      await fresh.engine.sync();
      expect(await address(fresh.db), await address(d.db));
      expect(await homeOf(fresh.db), await homeOf(d.db));
    });

    test('moved on through a vault it cannot open to one it has: read in that order', () async {
      final d = await device(_owner, crates: const [_a, _c]);
      server.forceItem(_a, await version(_a, _mallory, at: t0));
      await d.engine.sync();
      server.forceItem(_b, await version(_b, _owner, at: t0 + 1000));
      server.forceItem(_a, await version(_a, _owner, at: t0 + 1000, deleted: true, movedTo: _b));
      await d.engine.sync();
      expect(await address(d.db), isNull);

      server.forceItem(_c, await version(_c, _frank, address: '10.0.0.3', at: t0 + 2000));
      server.forceItem(_b, await version(_b, _frank, at: t0 + 2000, deleted: true, movedTo: _c));
      server.writeCalls.clear();
      final report = await d.engine.sync();
      expect(report.rejected, 0);
      expect(await address(d.db), '10.0.0.3');
      expect(await homeOf(d.db), _c);
      expect(server.writeCalls, isEmpty);
    });

    test('and read the other way: the copy first, while the item is live here; its deletion then says to read it again',
        () async {
      // In C, moved to B (which this device cannot open) and on to A by someone
      // with nothing in C. A sorts first.
      final d = await device(_owner, crates: const [_a, _c]);
      server.forceItem(_c, await version(_c, _dave, at: t0));
      await d.engine.sync();
      expect(await homeOf(d.db), _c);

      server.forceItem(_a, await version(_a, _alice, address: '10.0.0.3', at: t0 + 2000));
      server.forceItem(_c, await version(_c, _owner, at: t0 + 1000, deleted: true, movedTo: _b));
      server.writeCalls.clear();
      final report = await d.engine.sync();
      expect(report.rejected, 0, reason: 'read again in the same sync, it is no refusal');
      expect(await address(d.db), '10.0.0.3');
      expect(await homeOf(d.db), _a);
      expect(server.writeCalls, isEmpty);
    });

    test('the deletion is later than the copy and names its vault: that copy is the item, and is not signed away', () async {
      // A device removed what someone edited in the copy a move left, later
      // than that edit, naming where the item went.
      final d = await device(_owner, crates: const [_b]);
      server.forceItem(_b, await version(_b, _carol, at: t0));
      await d.engine.sync();
      server.forceItem(_a, await version(_a, _alice, address: '10.0.0.4', at: t0 + 1000));
      server.forceItem(_b, await version(_b, _owner, at: t0 + 2001, deleted: true, movedTo: _a));
      await d.engine.sync();

      await giveVault(d.db, _a);
      server.writeCalls.clear();
      final report = await d.engine.sync();
      expect(report.rejected, 0);
      expect(await address(d.db), '10.0.0.4');
      expect(await homeOf(d.db), _a);
      expect(server.writeCalls, isEmpty, reason: 'this host is not deleted for the whole team');
      expect((await held(_a))!.deleted, isFalse);
    });

    test('older than a deletion that names another vault: it stays out, unsigned, until it is edited', () async {
      final d = await device(_owner, crates: const [_a, _c]);
      server.forceItem(_a, await version(_a, _owner, at: t0));
      await d.engine.sync();
      server.forceItem(_a, await version(_a, _owner, at: t0 + 5000, deleted: true, movedTo: _b));
      await d.engine.sync();

      server.forceItem(_c, await version(_c, _owner, address: 'old.example.com', at: t0 + 1000));
      server.writeCalls.clear();
      expect((await d.engine.sync()).rejected, 1);
      expect(await address(d.db), isNull);
      expect(server.writeCalls, isEmpty);
      expect((await held(_c))!.deleted, isFalse);

      server.forceItem(_c, await version(_c, _dave, address: 'new.example.com', at: t0 + 6000));
      expect((await d.engine.sync()).rejected, 0);
      expect(await address(d.db), 'new.example.com');
    });

    test('a copy read before an item that came back does not take its place, and nothing is signed', () async {
      // A sorts first. Deleted, and brought back by someone with nothing in A;
      // meanwhile a later copy in A, by someone with nothing in B.
      final d = await device(_owner);
      server.forceItem(_b, await version(_b, _owner, at: t0));
      await d.engine.sync();
      server.forceItem(_b, await version(_b, _owner, at: t0 + 1000, deleted: true));
      await d.engine.sync();
      expect(await address(d.db), isNull);

      server.forceItem(_b, await version(_b, _carol, address: '10.0.0.2', at: t0 + 2000));
      server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 3000));
      server.writeCalls.clear();
      final report = await d.engine.sync();
      expect(report.rejected, 1);
      expect(await address(d.db), '10.0.0.2');
      expect(await homeOf(d.db), _b);
      expect(server.writeCalls, isEmpty);
      expect((await held(_b))!.deleted, isFalse);
      expect((await held(_a))!.deleted, isFalse);
    });

    test('a deleted item: a later copy is an item like any other, on this device as on a fresh one; an older one is not', () async {
      final d = await device(_owner);
      server.forceItem(_b, await version(_b, _owner, at: t0));
      await d.engine.sync();
      server.forceItem(_b, await version(_b, _owner, at: t0 + 5000, deleted: true));
      await d.engine.sync();

      server.forceItem(_a, await version(_a, _mallory, address: 'old.example.com', at: t0 + 1000));
      server.writeCalls.clear();
      expect((await d.engine.sync()).rejected, 1);
      expect(await address(d.db), isNull, reason: 'a server may send anything old again');

      server.forceItem(_a, await version(_a, _mallory, address: 'new.example.com', at: t0 + 6000));
      expect((await d.engine.sync()).rejected, 0);
      expect(await address(d.db), 'new.example.com');
      expect(await homeOf(d.db), _a);
      expect(server.writeCalls, isEmpty);
      expect((await held(_b))!.deleted, isTrue);

      final fresh = await device(_owner);
      await fresh.engine.sync();
      expect(await address(fresh.db), 'new.example.com');
    });

    test('a deletion of its own still waiting here is no deletion held: the live item is not overwritten', () async {
      final d = await device(_owner);
      server.forceItem(_b, await version(_b, _owner, at: t0));
      await d.engine.sync();
      await d.db.customStatement('DELETE FROM connections WHERE id = ?', [_prod]);
      server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 7200000));
      final report = await d.engine.sync();
      expect(report.rejected, 1);
      expect(report.sent, 1);
      expect(await address(d.db), isNull);
      expect((await held(_b))!.deleted, isTrue);
    });

    group('a copy from elsewhere took its place: the deletion\'s own vault', () {
      /// A host of B, deleted there, on a device of the owner's.
      Future<({AppDatabase db, CrateSyncEngine engine})> deletedInB({List<String> crates = const [_a, _b]}) async {
        final d = await device(_owner, crates: crates);
        server.forceItem(_b, await version(_b, _carol, address: 'real.example.com', at: t0));
        await d.engine.sync();
        server.forceItem(_b, await version(_b, _alice, at: t0 + 5000, deleted: true));
        await d.engine.sync();
        return d;
      }

      test('a member who may add in A plants a later copy: the real restore in B replaces it, and it stays replaced', () async {
        final d = await deletedInB();
        server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 6000));
        expect((await d.engine.sync()).rejected, 0);
        expect(await address(d.db), 'evil.example.com', reason: 'a device with only a deletion takes it, as one with nothing');

        server.forceItem(_b, await version(_b, _carol, address: 'real.example.com', at: t0 + 9000));
        server.writeCalls.clear();
        expect((await d.engine.sync()).rejected, 0);
        expect(await address(d.db), 'real.example.com');
        expect(await homeOf(d.db), _b);
        expect(server.writeCalls, isEmpty, reason: 'nothing is signed for it');
        expect((await d.engine.sync()).rejected, 0);

        // Her next edit is a copy that does not count, as any other.
        server.forceItem(_a, await version(_a, _mallory, address: 'evil2.example.com', at: t0 + 10000));
        expect((await d.engine.sync()).rejected, 1);
        expect(await address(d.db), 'real.example.com');
        expect(await homeOf(d.db), _b);
      });

      test('with a time far ahead it holds nothing off: an owner restores it in B', () async {
        final d = await deletedInB();
        server.forceItem(_a, await version(_a, _mallory, address: 'evil.example.com', at: t0 + 1000000000));
        await d.engine.sync();
        server.forceItem(_b, await version(_b, _owner, address: 'real.example.com', at: t0 + 9000));
        expect((await d.engine.sync()).rejected, 0);
        expect(await address(d.db), 'real.example.com');
        expect(await homeOf(d.db), _b);
      });

      test('a copy in B older than the deletion is no restore, and replaces nothing', () async {
        final d = await deletedInB();
        server.forceItem(_a, await version(_a, _mallory, address: 'planted.example.com', at: t0 + 6000));
        await d.engine.sync();
        server.forceItem(_b, await version(_b, _carol, address: 'old.example.com', at: t0 + 4000));
        expect((await d.engine.sync()).rejected, 1);
        expect(await address(d.db), 'planted.example.com');
      });

      test('deleted again in B before it came: it is no older than the later deletion that counts', () async {
        final d = await deletedInB();
        server.forceItem(_a, await version(_a, _mallory, address: 'planted.example.com', at: t0 + 6000));
        await d.engine.sync();
        server.forceItem(_b, await version(_b, _alice, at: t0 + 8000, deleted: true));
        await d.engine.sync();
        server.forceItem(_b, await version(_b, _carol, address: 'old.example.com', at: t0 + 7000));
        expect((await d.engine.sync()).rejected, 1);
        expect(await address(d.db), 'planted.example.com');
        server.forceItem(_b, await version(_b, _carol, address: 'real.example.com', at: t0 + 9000));
        expect((await d.engine.sync()).rejected, 0);
        expect(await address(d.db), 'real.example.com');
      });

      test('planted, deleted where it was planted, and restored: the note does not turn round, and a new plant is refused', () async {
        final d = await deletedInB();
        server.forceItem(_a, await version(_a, _grace, address: 'planted.example.com', at: t0 + 6000));
        await d.engine.sync();
        server.forceItem(_a, await version(_a, _grace, at: t0 + 7000, deleted: true));
        await d.engine.sync();
        expect(await address(d.db), isNull);

        server.forceItem(_b, await version(_b, _carol, address: 'real.example.com', at: t0 + 9000));
        expect((await d.engine.sync()).rejected, 0);
        expect(await address(d.db), 'real.example.com');
        expect(await homeOf(d.db), _b);

        server.forceItem(_a, await version(_a, _grace, address: 'evil.example.com', at: t0 + 10000));
        expect((await d.engine.sync()).rejected, 1);
        expect(await address(d.db), 'real.example.com');
        expect(await homeOf(d.db), _b);
      });

      test('and on through a third vault: B keeps its say, and its restore replaces what came from there as well', () async {
        final d = await deletedInB(crates: const [_a, _b, _c]);
        server.forceItem(_a, await version(_a, _grace, address: 'planted.example.com', at: t0 + 6000));
        await d.engine.sync();
        server.forceItem(_a, await version(_a, _grace, at: t0 + 7000, deleted: true));
        await d.engine.sync();
        server.forceItem(_c, await version(_c, _dave, address: 'third.example.com', at: t0 + 8000));
        await d.engine.sync();
        expect(await address(d.db), 'third.example.com');
        expect(await homeOf(d.db), _c);

        server.forceItem(_b, await version(_b, _carol, address: 'real.example.com', at: t0 + 9000));
        expect((await d.engine.sync()).rejected, 0);
        expect(await address(d.db), 'real.example.com');
        expect(await homeOf(d.db), _b);
      });

      test('an honest host moved to a vault this person could not open: it comes back, and a copy in the vault it left replaces nothing', () async {
        final d = await device(_owner, crates: const [_b]);
        server.forceItem(_b, await version(_b, _carol, address: 'real.example.com', at: t0));
        await d.engine.sync();
        server.forceItem(_a, await version(_a, _alice, address: 'moved.example.com', at: t0 + 1000));
        server.forceItem(_b, await version(_b, _alice, at: t0 + 1000, deleted: true, movedTo: _a));
        await d.engine.sync();
        await giveVault(d.db, _a);
        expect((await d.engine.sync()).rejected, 0);
        expect(await address(d.db), 'moved.example.com');
        expect(await homeOf(d.db), _a);

        server.forceItem(_b, await version(_b, _bob, address: 'evil.example.com', at: t0 + 2000));
        expect((await d.engine.sync()).rejected, 1);
        expect(await address(d.db), 'moved.example.com');
        expect(await homeOf(d.db), _a);
      });

      test('with an edit since, by someone who could not have moved it: the same', () async {
        final d = await device(_owner, crates: const [_b]);
        server.forceItem(_b, await version(_b, _carol, at: t0));
        await d.engine.sync();
        server.forceItem(_a, await version(_a, _alice, at: t0 + 1000));
        server.forceItem(_b, await version(_b, _alice, at: t0 + 1000, deleted: true, movedTo: _a));
        await d.engine.sync();
        server.forceItem(_a, await version(_a, _dave, address: 'edited.example.com', at: t0 + 2000));
        await giveVault(d.db, _a);
        expect((await d.engine.sync()).rejected, 0);
        expect(await address(d.db), 'edited.example.com');

        server.forceItem(_b, await version(_b, _bob, address: 'evil.example.com', at: t0 + 3000));
        expect((await d.engine.sync()).rejected, 1);
        expect(await address(d.db), 'edited.example.com');
      });

      test('a copy by someone who could have moved it out of B is a move: nothing is noted, and a copy in B does not replace it', () async {
        final d = await deletedInB();
        server.forceItem(_a, await version(_a, _alice, address: 'moved.example.com', at: t0 + 6000));
        await d.engine.sync();
        expect(await address(d.db), 'moved.example.com');
        server.forceItem(_b, await version(_b, _bob, address: 'evil.example.com', at: t0 + 9000));
        expect((await d.engine.sync()).rejected, 1);
        expect(await address(d.db), 'moved.example.com');
        expect(await homeOf(d.db), _a);
      });

      test('edited since by someone who could have moved it out of B: that is the item, and the copy in B is refused', () async {
        final d = await deletedInB();
        server.forceItem(_a, await version(_a, _mallory, address: 'planted.example.com', at: t0 + 6000));
        await d.engine.sync();
        server.forceItem(_a, await version(_a, _alice, address: 'looked-after.example.com', at: t0 + 7000));
        await d.engine.sync();
        server.forceItem(_b, await version(_b, _bob, address: 'evil.example.com', at: t0 + 9000));
        expect((await d.engine.sync()).rejected, 1);
        expect(await address(d.db), 'looked-after.example.com');

        // It is a move now, whoever edits it next.
        server.forceItem(_a, await version(_a, _mallory, address: 'edited.example.com', at: t0 + 10000));
        await d.engine.sync();
        server.forceItem(_b, await version(_b, _bob, address: 'evil2.example.com', at: t0 + 11000));
        expect((await d.engine.sync()).rejected, 1);
        expect(await address(d.db), 'edited.example.com');
      });
    });

    test('a sync stopped before it read where the deletion came from: the next one takes the copy', () async {
      final d = await device(_owner);
      server.forceItem(_b, await version(_b, _carol, at: t0));
      await d.engine.sync();
      server.forceItem(_b, await version(_b, _owner, at: t0 + 1000, deleted: true));
      await d.engine.sync();
      server.forceItem(_a, await version(_a, _dave, address: '10.0.0.2', at: t0 + 2000));

      final stopped = CrateSyncEngine(
        db: d.db,
        orchardId: _orchard,
        server: _FailsOnce(server, _b),
        author: CrateAuthor(uid: _owner, keys: keys[_owner]!),
        signers: signers,
      );
      await expectLater(stopped.sync(), throwsA(isA<OrchardServerException>()));
      expect(await address(d.db), isNull);

      expect((await d.engine.sync()).rejected, 0);
      expect(await address(d.db), '10.0.0.2');
    });

    test('where the deletion came from cannot be read: the sync ends, the copy waits, and comes once it can', () async {
      final d = await device(_owner);
      server.forceItem(_b, await version(_b, _carol, at: t0));
      await d.engine.sync();
      server.forceItem(_b, await version(_b, _owner, at: t0 + 1000, deleted: true));
      await d.engine.sync();
      server.forceItem(_a, await version(_a, _dave, address: '10.0.0.2', at: t0 + 2000));

      // Something new in B under a key this device has not got yet.
      final next = newSpaceKey();
      const other = 'another-host-id';
      server.forceItem(
          _b,
          await sealItem(
            ItemRecord(
              kind: 'host',
              key: other,
              author: _owner,
              authorKeyVersion: keys[_owner]!.version,
              editedAt: t0 + 2000,
              deleted: false,
              data: {
                'connections': [
                  {'id': other, 'label': 'Other', 'host': '10.0.0.8', 'port': 22, 'created_at': t0 ~/ 1000, 'updated_at': t0 ~/ 1000},
                ],
              },
              recordSeq: chain.length,
              recordHead: chain.last.hash(_orchard),
            ),
            place: ItemPlace(orchardId: _orchard, crateId: _b, itemId: await itemId(_b, 'host', other), generation: 2),
            crateKey: next,
            signer: keys[_owner]!,
          ));

      final waiting = await d.engine.sync().timeout(const Duration(seconds: 20));
      expect(waiting.needsKeys, isTrue);
      expect(await address(d.db), isNull);

      await d.db.customStatement(
          "INSERT INTO space_keys (scope, scope_id, generation, secret) VALUES ('crate', ?, 2, ?)", [_b, next]);
      expect((await d.engine.sync()).rejected, 0);
      expect(await address(d.db), '10.0.0.2');
      expect(await address(d.db, other), '10.0.0.8');
    });
  });

  group('kinds whose key is a name', () {
    Map<String, Object?> category(String name, int color) => {
          'snippet_categories': [
            {'name': name, 'color_value': color},
          ],
        };

    test('the same category name in two vaults, in all honesty: both stay, and the first read shows', () async {
      server.forceItem(_a, await version(_a, _dave, kind: 'category', key: 'Ops', data: category('Ops', 1), at: t0));
      server.forceItem(_b, await version(_b, _carol, kind: 'category', key: 'Ops', data: category('Ops', 2), at: t0 + 1000));
      final d = await device(_owner);
      server.writeCalls.clear();
      await d.engine.sync();
      expect(await homeOf(d.db, 'category', 'Ops'), _a);
      expect(server.writeCalls, isEmpty, reason: "no vault's own category is deleted for its members");
      expect((await held(_a, kind: 'category', key: 'Ops'))!.deleted, isFalse);
      expect((await held(_b, kind: 'category', key: 'Ops'))!.deleted, isFalse);
    });

    test("a pin in one vault under another's key is no pin: a device that read nothing yet takes the real one", () async {
      final pin = '10.0.0.1|22||$_b';
      Map<String, Object?> rows(String keyLine) => {
            'team_host_keys': [
              {'id': pin, 'host': '10.0.0.1', 'port': 22, 'via_scope': '', 'host_keys': jsonEncode([keyLine])},
            ],
          };
      server.forceItem(_a, await version(_a, _dave, kind: kHostKeyKind, key: pin, data: rows('ssh-ed25519 evil'), at: t0 + 1000));
      server.forceItem(_b, await version(_b, _carol, kind: kHostKeyKind, key: pin, data: rows('ssh-ed25519 real'), at: t0));
      final d = await device(_owner);
      final report = await d.engine.sync();
      expect(report.rejected, 1);
      expect(await homeOf(d.db, kHostKeyKind, pin), _b);
      final row = await d.db.customSelect('SELECT host_keys FROM team_host_keys WHERE id = ?', variables: [Variable(pin)]).getSingle();
      expect(row.read<String>('host_keys'), contains('real'));
    });
  });

  group('a change made here meets a move', () {
    test('by someone who could not have moved it there: it loses to the move, and is kept in the history', () async {
      // Carol edits; Alice's move reached the server first, earlier by the
      // clock. Written back over the move, her copy would be refused by every
      // device that followed it, and kept by the others.
      final d = await device(_carol, crates: const [_b]);
      server.forceItem(_b, await version(_b, _owner, at: t0));
      await d.engine.sync();
      await d.db.customStatement("UPDATE connections SET label = 'carols' WHERE id = ?", [_prod]);

      server.forceItem(_a, await version(_a, _alice, at: t0 + 1000));
      server.forceItem(_b, await version(_b, _alice, at: t0 + 1000, deleted: true, movedTo: _a));
      final report = await d.engine.sync();

      expect(report.conflictsLost, 1);
      expect(report.conflictsWon, 0);
      expect((await held(_b))!.deleted, isTrue, reason: 'nothing written over the move');
      expect((await held(_b))!.movedTo, _a);
      expect(await address(d.db), isNull, reason: 'she cannot open where it went');
      final kept = server.history[await itemId(_b, 'host', _prod)]!;
      expect(kept, isNotEmpty);
    });

    test('by someone who could: the newer change wins, and the item stays where it was', () async {
      final d = await device(_owner);
      server.forceItem(_b, await version(_b, _owner, at: t0));
      await d.engine.sync();
      await d.db.customStatement("UPDATE connections SET label = 'mine' WHERE id = ?", [_prod]);

      server.forceItem(_a, await version(_a, _alice, at: t0 + 1000));
      server.forceItem(_b, await version(_b, _alice, at: t0 + 1000, deleted: true, movedTo: _a));
      final report = await d.engine.sync();

      expect(report.conflictsWon, 1);
      expect(report.rejected, 0);
      expect(await homeOf(d.db), _b);
      expect((await held(_b))!.deleted, isFalse);
      expect((await held(_a))!.deleted, isTrue, reason: 'the other copy goes');
    });
  });
}

/// A server that lets [before] run as the first write reaches it: another
/// member's write that gets in first.
class _BeforeFirstWrite implements CrateServer {
  _BeforeFirstWrite(this._server, this.before);

  final FakeCrateServer _server;
  Future<void> Function()? before;

  @override
  Future<ItemsPage> changes(String crateId, {required int since, int? limit, ItemCheck? check}) =>
      _server.changes(crateId, since: since, limit: limit, check: check);

  @override
  Future<List<WriteResult>> write(String crateId, List<ItemWrite> writes, {required int keyVersion}) async {
    final hook = before;
    before = null;
    if (hook != null) await hook();
    return _server.write(crateId, writes, keyVersion: keyVersion);
  }

  @override
  Future<void> keepInHistory(String crateId, SealedItem item, {int? revision}) =>
      _server.keepInHistory(crateId, item, revision: revision);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

/// A server whose answer for [crateId]'s changes fails once, as a dropped
/// connection does; with [afterFirst], only where it was asked once before it.
class _FailsOnce implements CrateServer {
  _FailsOnce(this._server, this._crateId, {this.afterFirst = false});

  final FakeCrateServer _server;
  final String _crateId;
  final bool afterFirst;
  var _asked = 0;
  var _failed = false;

  @override
  Future<ItemsPage> changes(String crateId, {required int since, int? limit, ItemCheck? check}) {
    if (crateId == _crateId && !_failed) {
      _asked++;
      if (!afterFirst || _asked > 1) {
        _failed = true;
        throw const OrchardServerException(503, null);
      }
    }
    return _server.changes(crateId, since: since, limit: limit, check: check);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}
