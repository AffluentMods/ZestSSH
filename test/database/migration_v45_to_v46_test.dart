import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v45 -> v46 upgrade path.
///
/// Trust on the Team page (3.0 UI) keeps, for each member, whether
/// their keys were replaced since this device's person compared them; for
/// each record entry, the date this device first saw it; and the keys to
/// change after someone lost access. The rows already there stay: nobody
/// marked replaced, no first-seen dates, nothing to change.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('zest-v46-'));
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {/* Windows may hold the file a moment */}
  });

  /// An Orchard database with a member and a record entry, closed.
  Future<File> orchardDatabase() async {
    final file = File('${dir.path}${Platform.pathSeparator}orchard.db');
    final db = AppDatabase.forTesting(NativeDatabase(file), isOrchard: true);
    await db.customStatement(
        "INSERT INTO member_keys (uid, email, role, key_version, verified_by_me, verified_by) "
        "VALUES ('alice', 'alice@example.com', 'admin', 2, 1, '[]')");
    await db.customStatement(
        'INSERT INTO orchard_record_entries (seq, prev, type, body, by_uid, by_key_version, signature, hash) '
        "VALUES (1, x'', 'create', '{}', 'alice', 1, x'00', x'01')");
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

  test('a v45 database gains the replaced mark, first-seen dates and the list to change, and keeps its rows',
      () async {
    final file = await orchardDatabase();
    final db = await reopen(file, (raw) {
      raw.execute('ALTER TABLE member_keys DROP COLUMN replaced_since_compared');
      raw.execute('ALTER TABLE orchard_record_entries DROP COLUMN first_seen');
      raw.execute('DROP TABLE change_next');
      raw.execute('PRAGMA user_version = 45');
    });
    addTearDown(db.close);

    final member = await db
        .customSelect('SELECT email, role, key_version, verified_by_me, replaced_since_compared FROM member_keys')
        .getSingle();
    expect(member.data, {
      'email': 'alice@example.com',
      'role': 'admin',
      'key_version': 2,
      'verified_by_me': 1,
      'replaced_since_compared': 0,
    });
    final entry = await db.customSelect('SELECT seq, type, first_seen FROM orchard_record_entries').getSingle();
    expect(entry.data, {'seq': 1, 'type': 'create', 'first_seen': null});
    await db.customStatement(
        'INSERT INTO change_next (subject_uid, entry_seq, key_id, label, crate_id, could_reveal, rank) '
        "VALUES ('kai', 4, 'k1', 'deploy key', 'c1', 1, 1)");
    expect(await db.customSelect('SELECT done_at FROM change_next').getSingle().then((r) => r.data),
        {'done_at': null});
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.data.values.single, db.schemaVersion, reason: 'upgraded through to the latest');
  });

  test('running the step again over a v46 database changes nothing', () async {
    final file = await orchardDatabase();
    final db = await reopen(file, (raw) {
      raw.execute('UPDATE member_keys SET replaced_since_compared = 1');
      raw.execute('UPDATE orchard_record_entries SET first_seen = 1790000000');
      raw.execute(
          'INSERT INTO change_next (subject_uid, entry_seq, key_id, label, crate_id, could_reveal, rank, done_at) '
          "VALUES ('kai', 4, 'k1', 'deploy key', 'c1', 0, 2, 1790000100)");
      raw.execute('PRAGMA user_version = 45');
    });
    addTearDown(db.close);
    final member = await db.customSelect('SELECT replaced_since_compared FROM member_keys').getSingle();
    expect(member.read<int>('replaced_since_compared'), 1, reason: 'kept as it was');
    final entry = await db.customSelect('SELECT first_seen FROM orchard_record_entries').getSingle();
    expect(entry.read<int>('first_seen'), 1790000000);
    final todo = await db.customSelect('SELECT rank, done_at FROM change_next').getSingle();
    expect(todo.data, {'rank': 2, 'done_at': 1790000100});
  });
}
