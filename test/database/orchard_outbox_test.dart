import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import '../helpers/orchard_db_fixture.dart';

/// An Orchard's database records every change of an item for its Crate's sync
/// (3.0): triggers queue the item in `crate_outbox`, whichever code
/// wrote the rows, and stay quiet while the sync engine writes changes that
/// came from the server. The Tree's database has no such triggers.

Future<List<(String, String, int)>> _outbox(AppDatabase db) async {
  final rows = await db
      .customSelect(
          'SELECT kind, item_key, change_seq FROM crate_outbox ORDER BY change_seq')
      .get();
  return [
    for (final r in rows)
      (r.read<String>('kind'), r.read<String>('item_key'), r.read<int>('change_seq')),
  ];
}

Future<void> _addHost(AppDatabase db, String id) {
  final now = DateTime(2026, 9, 23);
  return db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: id,
        label: 'web $id',
        host: '10.0.0.1',
        port: const Value(22),
        createdAt: now,
        updatedAt: now,
      ));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('an Orchard database', () {
    late AppDatabase db;
    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
      await seedOrchardAsOwner(db);
    });
    tearDown(() async => db.close());

    test('queues a host when it, its tags or its overrides change', () async {
      await _addHost(db, 'h-1');
      expect((await _outbox(db)).map((r) => (r.$1, r.$2)), [('host', 'h-1')]);

      final first = (await _outbox(db)).single.$3;
      await db.customStatement(
          "INSERT INTO connection_tags (connection_id, tag, created_at) VALUES ('h-1', 'prod', 0)");
      final afterTag = await _outbox(db);
      expect(afterTag.map((r) => (r.$1, r.$2)), [('host', 'h-1')],
          reason: 'one row per item, however often it changes');
      expect(afterTag.single.$3, greaterThan(first),
          reason: 'the change number rises, so a push never clears a newer change');

      await (db.delete(db.connections)..where((c) => c.id.equals('h-1'))).go();
      expect((await _outbox(db)).map((r) => r.$2), ['h-1']);
    });

    test('queues every kind of item under its own kind', () async {
      final now = DateTime(2026, 9, 23);
      await db.into(db.identities).insert(IdentitiesCompanion.insert(
            id: 'k-1',
            label: 'deploy key',
            username: 'deploy',
            authMethod: 'publicKey',
            createdAt: now,
          ));
      await db.customStatement(
          "INSERT INTO orchard_secrets (identity_id, private_key) VALUES ('k-2', 'x')");
      await db.customStatement(
          "INSERT INTO snippet_categories (name) VALUES ('Ops')");
      final kinds = (await _outbox(db)).map((r) => (r.$1, r.$2)).toSet();
      expect(kinds, {('key', 'k-1'), ('key', 'k-2'), ('category', 'Ops')});
    });

    test('a renamed category queues both its old and its new name', () async {
      await db.customStatement("INSERT INTO snippet_categories (name) VALUES ('Ops')");
      await db.customStatement('DELETE FROM crate_outbox');
      await db.customStatement(
          "UPDATE snippet_categories SET name = 'Operations' WHERE name = 'Ops'");
      final keys = (await _outbox(db)).map((r) => r.$2).toSet();
      expect(keys, {'Ops', 'Operations'});
    });

    test('changes written from the server are not queued again', () async {
      await db.transaction(() async {
        await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
        await _addHost(db, 'from-server');
        await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
      });
      expect(await _outbox(db), isEmpty);
      await _addHost(db, 'local');
      expect((await _outbox(db)).map((r) => r.$2), ['local']);
    });

    test('only a change to what the record carries queues the item', () async {
      await _addHost(db, 'h-1');
      await db.customStatement('DELETE FROM crate_outbox');

      // Yours alone: when you connected, your pins, your order.
      await db.customStatement(
          "UPDATE connections SET last_connected = 5, pinned = 1, sort_order = 3 WHERE id = 'h-1'");
      // The same value again changes nothing.
      await db.customStatement("UPDATE connections SET label = 'web h-1' WHERE id = 'h-1'");
      expect(await _outbox(db), isEmpty);

      await db.customStatement("UPDATE connections SET label = 'web' WHERE id = 'h-1'");
      expect((await _outbox(db)).map((r) => r.$2), ['h-1']);
    });

    test('writes that settle conflicts themselves still queue their item', () async {
      // The app's DAOs upsert networks, forwards, categories and triggers,
      // and INSERT OR IGNORE tags: none may fail, and each change must raise
      // the item's change number, or a push could clear a newer change.
      Future<int> seqOf(String key) async => (await _outbox(db))
          .firstWhere((r) => r.$2 == key)
          .$3;
      const upsert = "INSERT INTO snippet_categories (name, color_index) VALUES ('Ops', ?) "
          'ON CONFLICT(name) DO UPDATE SET color_index = excluded.color_index';
      await db.customStatement(upsert, [1]);
      final first = await seqOf('Ops');
      await db.customStatement(upsert, [2]);
      final second = await seqOf('Ops');
      expect(second, greaterThan(first));
      await db.customStatement(
          "INSERT OR REPLACE INTO snippet_categories (name, color_index) VALUES ('Ops', 3)");
      expect(await seqOf('Ops'), greaterThan(second));

      await _addHost(db, 'h-1');
      const tag = 'INSERT OR IGNORE INTO connection_tags (connection_id, tag, created_at) '
          "VALUES ('h-1', 'prod', 0)";
      await db.customStatement(tag);
      final tagged = await seqOf('h-1');
      await db.customStatement(tag);
      await db.customStatement("UPDATE connections SET label = 'renamed' WHERE id = 'h-1'");
      expect(await seqOf('h-1'), greaterThan(tagged));
      expect((await _outbox(db)).map((r) => r.$2).toList()..sort(), ['Ops', 'h-1'],
          reason: 'one row per item');
    });

    test('a queued change carries the time it was made', () async {
      final before = DateTime.now().millisecondsSinceEpoch;
      await _addHost(db, 'h-1');
      final row = await db
          .customSelect("SELECT edited_at FROM crate_outbox WHERE item_key = 'h-1'")
          .getSingle();
      final at = row.read<int>('edited_at');
      expect(at, greaterThanOrEqualTo(before - 1000));
      expect(at, lessThanOrEqualTo(DateTime.now().millisecondsSinceEpoch + 1000));
    });

    test('making the triggers again replaces them rather than adding more', () async {
      await db.createOrchardTriggers();
      final triggers = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'trg_ob_%'")
          .get();
      expect(triggers, hasLength(AppDatabase.orchardItemTables.length * 3));
      await _addHost(db, 'h-1');
      expect((await _outbox(db)).map((r) => r.$2), ['h-1']);
    });

    test('a sync that stopped halfway cannot leave the triggers switched off', () async {
      final dir = await Directory.systemTemp.createTemp('orchard_db_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/o.db');

      final first = AppDatabase.forTesting(NativeDatabase(file), isOrchard: true);
      // The app stops while the flag is set (written outside any transaction,
      // the worst case).
      await first.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      await first.close();

      final reopened = AppDatabase.forTesting(NativeDatabase(file), isOrchard: true);
      addTearDown(reopened.close);
      await seedOrchardAsOwner(reopened);
      final flag = await reopened
          .customSelect('SELECT applying FROM orchard_sync_control WHERE id = 1')
          .getSingle();
      expect(flag.read<int>('applying'), 0);
      await _addHost(reopened, 'after-restart');
      expect((await _outbox(reopened)).map((r) => r.$2), ['after-restart']);
    });
  });

  test("the Tree's database has no outbox triggers and records nothing", () async {
    final tree = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(tree.close);
    await _addHost(tree, 'personal');
    expect(await _outbox(tree), isEmpty);
    final triggers = await tree
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'trg_ob_%'")
        .get();
    expect(triggers, isEmpty);
  });
}
