import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v44 -> v45 upgrade path.
///
/// The Orchard's rules (3.0) keep the rules from the record, what the
/// server says this account falls short of, and each Crate's "ask again
/// before revealing". The rows already there stay: no rules known, nothing
/// held, no Crate asking again.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('zest-v45-'));
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {/* Windows may hold the file a moment */}
  });

  /// An Orchard database with its info row and one Crate, closed.
  Future<File> orchardDatabase() async {
    final file = File('${dir.path}${Platform.pathSeparator}orchard.db');
    final db = AppDatabase.forTesting(NativeDatabase(file), isOrchard: true);
    await db.customStatement(
        "INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, status) "
        "VALUES (1, 'o-1', 'Acme', 'owner', 2, 'active')");
    await db.customStatement(
        "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation, last_revision) "
        "VALUES ('11111111-1111-4111-8111-111111111111', 'Prod', 'manage', '[\"manage\"]', 3, 9)");
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

  test('a v44 database gains the rules, the held list and the ask-again switch, and keeps its rows', () async {
    final file = await orchardDatabase();
    final db = await reopen(file, (raw) {
      raw.execute('ALTER TABLE orchard_info DROP COLUMN rules');
      raw.execute('ALTER TABLE orchard_info DROP COLUMN held');
      raw.execute('ALTER TABLE orchard_crates DROP COLUMN confirm_reveal');
      raw.execute('PRAGMA user_version = 44');
    });
    addTearDown(db.close);

    final info = await db.customSelect('SELECT name, role, key_generation, status, rules, held FROM orchard_info').getSingle();
    expect(info.data, {'name': 'Acme', 'role': 'owner', 'key_generation': 2, 'status': 'active', 'rules': null, 'held': null});
    final crate = await db.customSelect('SELECT name, key_generation, last_revision, confirm_reveal FROM orchard_crates').getSingle();
    expect(crate.data, {'name': 'Prod', 'key_generation': 3, 'last_revision': 9, 'confirm_reveal': 0});
    await db.customStatement("UPDATE orchard_info SET rules = '{}', held = '{\"unmet\":[\"two_step\"]}'");
    await db.customStatement('UPDATE orchard_crates SET confirm_reveal = 1');
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.data.values.single, db.schemaVersion, reason: 'upgraded through to the latest');
  });

  test('running the step again over a v45 database changes nothing', () async {
    final file = await orchardDatabase();
    final db = await reopen(file, (raw) {
      raw.execute("UPDATE orchard_info SET rules = '{\"no_export\":true}', held = '{\"unmet\":[\"reauth\"]}'");
      raw.execute('UPDATE orchard_crates SET confirm_reveal = 1');
      raw.execute('PRAGMA user_version = 44');
    });
    addTearDown(db.close);
    final info = await db.customSelect('SELECT rules, held FROM orchard_info').getSingle();
    expect(info.data, {'rules': '{"no_export":true}', 'held': '{"unmet":["reauth"]}'}, reason: 'kept as they were');
    final crate = await db.customSelect('SELECT confirm_reveal FROM orchard_crates').getSingle();
    expect(crate.read<int>('confirm_reveal'), 1);
  });
}
