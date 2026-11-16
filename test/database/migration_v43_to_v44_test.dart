import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v43 -> v44 upgrade path.
///
/// Removing people and replacing keys (3.0) marks members whose account
/// was deleted since the record added them, and keeps who wrote each item's
/// version. The rows already there stay: no member marked, no author known.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('zest-v44-'));
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {/* Windows may hold the file a moment */}
  });

  /// An Orchard database with two members, closed.
  Future<File> orchardDatabase() async {
    final file = File('${dir.path}${Platform.pathSeparator}orchard.db');
    final db = AppDatabase.forTesting(NativeDatabase(file), isOrchard: true);
    await db.customStatement(
        "INSERT INTO orchard_info (id, orchard_id, name, role, key_generation) VALUES (1, 'o-1', 'Acme', 'owner', 1)");
    await db.customStatement(
        "INSERT INTO member_keys (uid, role, status, ends_at) VALUES ('alice', 'admin', 'active', NULL), "
        "('bob', 'member-role', 'suspended', 1893456000)");
    await db.customStatement(
        "INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision, edited_at) "
        "VALUES ('host', 'h-1', '11111111-1111-4111-8111-111111111111', 4, 1790000000000)");
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

  test('a v43 database gains the deleted-account mark, every member unmarked, and keeps its rows', () async {
    final file = await orchardDatabase();
    final db = await reopen(file, (raw) {
      raw.execute('ALTER TABLE member_keys DROP COLUMN account_deleted');
      raw.execute('ALTER TABLE crate_items_meta DROP COLUMN author');
      raw.execute('PRAGMA user_version = 43');
    });
    addTearDown(db.close);

    final members = await db
        .customSelect('SELECT uid, role, status, ends_at, account_deleted FROM member_keys ORDER BY uid')
        .get();
    expect([for (final m in members) m.data], [
      {'uid': 'alice', 'role': 'admin', 'status': 'active', 'ends_at': null, 'account_deleted': 0},
      {'uid': 'bob', 'role': 'member-role', 'status': 'suspended', 'ends_at': 1893456000, 'account_deleted': 0},
    ]);
    await db.customStatement("UPDATE member_keys SET account_deleted = 1 WHERE uid = 'bob'");
    final meta = await db.customSelect('SELECT item_key, server_revision, author FROM crate_items_meta').getSingle();
    expect(meta.data, {'item_key': 'h-1', 'server_revision': 4, 'author': null});
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.data.values.single, db.schemaVersion, reason: 'upgraded through to the latest');
  });

  test('running the step again over a v44 database changes nothing', () async {
    final file = await orchardDatabase();
    final db = await reopen(file, (raw) {
      raw.execute("UPDATE member_keys SET account_deleted = 1 WHERE uid = 'bob'");
      raw.execute('PRAGMA user_version = 43');
    });
    addTearDown(db.close);
    final bob = await db.customSelect("SELECT account_deleted FROM member_keys WHERE uid = 'bob'").getSingle();
    expect(bob.read<int>('account_deleted'), 1, reason: 'kept as it was');
  });
}
