import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v41 -> v42 upgrade path.
///
/// Member fingerprints (3.0) added the member_keys table and the
/// Orchard's members_tag to v41 after a v41 test build had gone out (an
/// early test build). v42 adds both to a database that build
/// made, and leaves a database that already has them as it is. The rows
/// already there stay.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('zest-v42-'));
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {/* Windows may hold the file a moment */}
  });

  /// An Orchard database at v42 with an Orchard and a key, closed.
  Future<File> orchardDatabase() async {
    final file = File('${dir.path}${Platform.pathSeparator}orchard.db');
    final db = AppDatabase.forTesting(NativeDatabase(file), isOrchard: true);
    await db.customStatement(
        "INSERT INTO orchard_info (id, orchard_id, name, role, key_generation) VALUES (1, 'o-1', 'Acme', 'owner', 1)");
    await db.customStatement(
        "INSERT INTO space_keys (scope, scope_id, generation, secret) VALUES ('orchard', 'o-1', 1, x'0102')");
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

  Future<Set<String>> columns(AppDatabase db, String table) async => {
        for (final r in await db.customSelect('PRAGMA table_info("$table")').get()) r.read<String>('name'),
      };

  test('a v41 database from a test build gains the members table and tag, and keeps its rows', () async {
    final file = await orchardDatabase();
    final db = await reopen(file, (raw) {
      // What that test build made: no member_keys, no members_tag.
      raw.execute('DROP TABLE member_keys');
      raw.execute('ALTER TABLE orchard_info DROP COLUMN members_tag');
      raw.execute('PRAGMA user_version = 41');
    });
    addTearDown(db.close);

    expect(await columns(db, 'member_keys'),
        containsAll(['uid', 'email', 'role', 'key_version', 'signing_key', 'encryption_key', 'verified_by_me', 'verified_by', 'pending_keys']));
    expect(await columns(db, 'orchard_info'), contains('members_tag'));
    final info = await db.customSelect('SELECT orchard_id, name, members_tag FROM orchard_info').getSingle();
    expect(info.data, {'orchard_id': 'o-1', 'name': 'Acme', 'members_tag': null});
    final keys = await db.customSelect('SELECT COUNT(*) AS n FROM space_keys').getSingle();
    expect(keys.read<int>('n'), 1);
    // The table works as the member directory uses it.
    await db.customStatement("INSERT INTO member_keys (uid, role) VALUES ('alice', 'member')");
    await db.customStatement("UPDATE orchard_info SET members_tag = 'tag-1' WHERE id = 1");
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.data.values.single, db.schemaVersion, reason: 'upgraded through to the latest');
  });

  test('a v41 database that already has both is left as it is', () async {
    final file = await orchardDatabase();
    final db = await reopen(file, (raw) => raw.execute('PRAGMA user_version = 41'));
    addTearDown(db.close);
    expect(await columns(db, 'orchard_info'), contains('members_tag'));
    final tables = await db
        .customSelect("SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'member_keys'")
        .getSingle();
    expect(tables.read<int>('n'), 1);
    final info = await db.customSelect('SELECT name FROM orchard_info').getSingle();
    expect(info.read<String>('name'), 'Acme');
  });
}
