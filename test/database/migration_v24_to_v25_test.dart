import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v24 -> v25 upgrade path.
///
/// v25 (unattended-runs opt-in) adds ONE new boolean column, `allowUnattended`
/// (default false), to `identities`. It's a device-local security flag - a
/// saved credential is refused by headless automation until the user opts it
/// in. The step is a plain additive `addColumn`, so all pre-existing identities
/// migrate untouched and stay OFF.
///
/// Strategy mirrors `migration_v23_to_v24_test.dart`: seed a
/// `NativeDatabase.memory()` with id-PK stubs for all 14 user tables at
/// `PRAGMA user_version = 24`, open `AppDatabase.forTesting(...)` (the first
/// query runs `onUpgrade(24, 25)`), then assert the pre-existing rows survived
/// and the new column exists with the right default.

const _stubTables = <String>[
  'CREATE TABLE connections (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE identities (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE connection_groups (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE known_hosts (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE snippets (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE snippet_categories (name TEXT NOT NULL, PRIMARY KEY (name));',
  'CREATE TABLE port_forward_rules (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE port_forward_network_overrides (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE automation_history (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE workflows (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE scheduled_tasks (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE networks (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE host_network_overrides (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE connection_tags (id TEXT NOT NULL, PRIMARY KEY (id));',
];

QueryExecutor _seededV24Executor() {
  return NativeDatabase.memory(setup: (rawDb) {
    for (final stmt in _stubTables) {
      rawDb.execute(stmt);
    }
    // Pre-existing rows - their survival + untouched default we assert on.
    rawDb.execute("INSERT INTO connections (id) VALUES ('c1');");
    rawDb.execute("INSERT INTO identities (id) VALUES ('i1');");
    // Tell drift the on-disk schema is v24 so it runs onUpgrade(24 -> 25).
    rawDb.execute('PRAGMA user_version = 24;');
  });
}

Directory? _appDataDir() {
  final localAppData = Platform.environment['LOCALAPPDATA'];
  if (localAppData == null || localAppData.isEmpty) return null;
  final dir = Directory('$localAppData/com.affluentlabs.zestssh');
  return dir.existsSync() ? dir : null;
}

Set<String> _backupSnapshot(Directory? dir) {
  if (dir == null) return const {};
  try {
    return dir
        .listSync()
        .whereType<File>()
        .map((f) => f.path)
        .where((p) => p.contains('zestssh_backup_'))
        .toSet();
  } catch (_) {
    return const {};
  }
}

void main() {
  late AppDatabase db;
  late Directory? appDataDir;
  late Set<String> backupsBefore;

  setUp(() {
    appDataDir = _appDataDir();
    backupsBefore = _backupSnapshot(appDataDir);
    db = AppDatabase.forTesting(_seededV24Executor());
  });

  tearDown(() async {
    await db.close();
    final after = _backupSnapshot(appDataDir);
    for (final path in after.difference(backupsBefore)) {
      try {
        File(path).deleteSync();
      } catch (_) {}
    }
  });

  test('schemaVersion is >= 25 (guards the unbumped-migration regression)', () {
    expect(db.schemaVersion, greaterThanOrEqualTo(25));
  });

  test('v24 -> v25 upgrade runs and preserves the pre-existing identity',
      () async {
    final count = await db
        .customSelect('SELECT COUNT(*) AS cnt FROM identities')
        .getSingle();
    expect(
      count.read<int>('cnt'),
      1,
      reason: 'the pre-existing v24 identity row must survive the migration',
    );
  });

  test('upgrade physically adds allow_unattended to identities', () async {
    await db.customSelect('SELECT COUNT(*) AS cnt FROM identities').getSingle();

    final info = await db.customSelect('PRAGMA table_info(identities)').get();
    final columns = {for (final r in info) r.read<String>('name')};
    // Drift snake-cases the Dart `allowUnattended` getter to `allow_unattended`.
    expect(
      columns.contains('allow_unattended'),
      isTrue,
      reason: 'the v25 addColumn step must add allow_unattended to identities',
    );
  });

  test('a pre-existing identity defaults to allow_unattended = 0 (opted OUT)',
      () async {
    // Migration must NOT silently enable unattended runs on existing credentials.
    final row = await db
        .customSelect("SELECT allow_unattended FROM identities WHERE id = 'i1'")
        .getSingle();
    expect(row.read<int>('allow_unattended'), 0);
  });

  test('allow_unattended round-trips as a boolean flag', () async {
    await db.customStatement(
      "UPDATE identities SET allow_unattended = 1 WHERE id = 'i1'",
    );
    final row = await db
        .customSelect("SELECT allow_unattended FROM identities WHERE id = 'i1'")
        .getSingle();
    expect(row.read<int>('allow_unattended'), 1);
  });
}
