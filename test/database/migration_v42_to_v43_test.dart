import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v42 -> v43 upgrade path.
///
/// The Orchard's record (3.0) adds the table of its entries, and what
/// follows from them: what the account may do and its standing in the
/// Orchard, each Crate's switches and settings, and each member's standing.
/// The rows already there stay, with the defaults a v42 Orchard means.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('zest-v43-'));
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {/* Windows may hold the file a moment */}
  });

  /// An Orchard database with an Orchard, a Crate and a member, closed.
  Future<File> orchardDatabase() async {
    final file = File('${dir.path}${Platform.pathSeparator}orchard.db');
    final db = AppDatabase.forTesting(NativeDatabase(file), isOrchard: true);
    await db.customStatement(
        "INSERT INTO orchard_info (id, orchard_id, name, role, key_generation) VALUES (1, 'o-1', 'Acme', 'owner', 1)");
    await db.customStatement(
        "INSERT INTO orchard_crates (crate_id, name, level, key_generation) VALUES ('c-1', 'Prod', 'manage', 1)");
    await db.customStatement("INSERT INTO member_keys (uid, role) VALUES ('alice', 'admin')");
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

  test('a v42 database gains the record and what follows from it, and keeps its rows', () async {
    final file = await orchardDatabase();
    final db = await reopen(file, (raw) {
      // As v42 made it: no write guards (they name columns v43 added).
      for (final t in raw.select("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'trg_gd_%'")) {
        raw.execute('DROP TRIGGER "${t['name']}"');
      }
      raw.execute('DROP TABLE orchard_record_entries');
      for (final c in ['can', 'status', 'rotation_due', 'record_problem']) {
        raw.execute('ALTER TABLE orchard_info DROP COLUMN $c');
      }
      for (final c in ['switches', 'owners_only', 'allow', 'rotation_due']) {
        raw.execute('ALTER TABLE orchard_crates DROP COLUMN $c');
      }
      for (final c in ['status', 'ends_at']) {
        raw.execute('ALTER TABLE member_keys DROP COLUMN $c');
      }
      raw.execute('PRAGMA user_version = 42');
    });
    addTearDown(db.close);

    // Made from today's schema, so it also carries what later steps add
    // (v46: first_seen).
    expect(await columns(db, 'orchard_record_entries'),
        {'seq', 'prev', 'type', 'body', 'by_uid', 'by_key_version', 'signature', 'hash', 'first_seen'});
    final info = await db
        .customSelect('SELECT name, can, status, rotation_due, record_problem FROM orchard_info')
        .getSingle();
    expect(info.data, {'name': 'Acme', 'can': '[]', 'status': 'active', 'rotation_due': 0, 'record_problem': null});
    final crate = await db
        .customSelect('SELECT name, level, switches, owners_only, allow, rotation_due FROM orchard_crates')
        .getSingle();
    expect(crate.data, {
      'name': 'Prod',
      'level': 'manage',
      'switches': '[]',
      'owners_only': 0,
      'allow': '["forward","sftp"]',
      'rotation_due': 0,
    });
    final member = await db.customSelect('SELECT role, status, ends_at FROM member_keys').getSingle();
    expect(member.data, {'role': 'admin', 'status': 'active', 'ends_at': null});
    await db.customStatement(
        'INSERT INTO orchard_record_entries (seq, prev, type, body, by_uid, by_key_version, signature, hash) '
        "VALUES (1, x'', 'create', '{}', 'u', 1, x'00', x'01')");
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.data.values.single, db.schemaVersion, reason: 'upgraded through to the latest');
  });

  test('running the step again over a v43 database changes nothing', () async {
    final file = await orchardDatabase();
    final db = await reopen(file, (raw) => raw.execute('PRAGMA user_version = 42'));
    addTearDown(db.close);
    final info = await db.customSelect('SELECT name, status FROM orchard_info').getSingle();
    expect(info.data, {'name': 'Acme', 'status': 'active'});
    final tables = await db
        .customSelect(
            "SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'orchard_record_entries'")
        .getSingle();
    expect(tables.read<int>('n'), 1);
  });
}
