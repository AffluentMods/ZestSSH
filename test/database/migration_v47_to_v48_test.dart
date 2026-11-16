import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v47 -> v48 upgrade path.
///
/// The trash (3.0): an Orchard database notes whether the Crate's
/// copy of an item is a deletion, since bringing it back is adding it. A
/// database made at v47 gains the note, filled in for the items that were
/// deleted in their Crate (no row here, a copy to base on, nothing of this
/// device's waiting), and its write guard then asks for add to bring one
/// back, as the server does.

const _crate = '11111111-1111-4111-8111-111111111111';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('zest-v48-'));
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {/* Windows may hold the file a moment */}
  });

  /// An Orchard database with hosts in every state an item can be in, closed.
  Future<File> orchardDatabase() async {
    final file = File('${dir.path}${Platform.pathSeparator}orchard.db');
    final db = AppDatabase.forTesting(NativeDatabase(file), isOrchard: true);
    await db.customStatement(
        'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id) '
        "VALUES (1, '44444444-4444-4444-8444-444444444444', 'Acme', 'owner', 1, '$_crate')");
    await db.customStatement(
        'INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES '
        '''('$_crate', 'Open', 'edit', '["add","connect","delete","edit"]', 1)''');
    await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
    await db.customStatement(
        "INSERT INTO connections (id, label, host, port, created_at, updated_at) VALUES ('live', 'Live', 'live.example.com', 22, 0, 0)");
    await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
    for (final (key, revision) in [('live', 5), ('gone', 7), ('pending', 9), ('fresh', null)]) {
      await db.customStatement(
          "INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('host', ?, ?, ?)",
          [key, _crate, revision]);
    }
    // 'pending' was deleted here and waits to be sent.
    await db.customStatement(
        "INSERT INTO crate_outbox (kind, item_key, change_seq, edited_at) VALUES ('host', 'pending', 1, 1)");
    await db.close();
    return file;
  }

  /// Reopens [file] after [change] ran on it, as the app would.
  Future<AppDatabase> reopen(File file, void Function(dynamic raw) change) {
    var done = false;
    final db = AppDatabase.forTesting(
      NativeDatabase(file, setup: (raw) {
        if (done) return;
        done = true;
        change(raw);
      }),
      isOrchard: true,
    );
    return db.customSelect('SELECT 1').get().then((_) => db);
  }

  test('a v47 database notes which items were deleted in their Crate; bringing one back then needs add', () async {
    final file = await orchardDatabase();
    final db = await reopen(file, (raw) {
      // A v47 database has v47's triggers, which never named the column.
      final triggers = raw.select("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'trg_gd_%'");
      for (final t in triggers) {
        raw.execute('DROP TRIGGER "${t['name']}"');
      }
      raw.execute('ALTER TABLE crate_items_meta DROP COLUMN server_deleted');
      raw.execute('PRAGMA user_version = 47');
    });
    addTearDown(db.close);

    final noted = {
      for (final r in await db.customSelect('SELECT item_key, server_deleted FROM crate_items_meta').get())
        r.read<String>('item_key'): r.read<bool>('server_deleted'),
    };
    expect(noted, {'live': false, 'gone': true, 'pending': false, 'fresh': false});

    Future<void> bringBack(String id) => db.customStatement(
        "INSERT INTO connections (id, label, host, port, created_at, updated_at) VALUES (?, 'Back', 'b.example.com', 22, 0, 0)",
        [id]);
    // Someone who may edit but not add cannot bring it back.
    await db.customStatement('''UPDATE orchard_crates SET switches = '["connect","delete","edit"]' ''');
    await expectLater(bringBack('gone'), throwsA(predicate((e) => '$e'.contains('orchard-access'))));
    // Someone who may add, but not edit, can.
    await db.customStatement('''UPDATE orchard_crates SET switches = '["add","connect"]' ''');
    await bringBack('gone');
    expect((await db.customSelect("SELECT kind, item_key FROM crate_outbox WHERE item_key = 'gone'").get()).length, 1,
        reason: 'queued to send');
    // An item that lives in its Crate is still edited, not added.
    await expectLater(
        db.customStatement("UPDATE connections SET label = 'Renamed' WHERE id = 'live'"),
        throwsA(predicate((e) => '$e'.contains('orchard-access'))));
  });
}
