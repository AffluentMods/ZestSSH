import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v23 -> v24 upgrade path.
///
/// v24 (custom colour labels) adds ONE new nullable column, `colorValue` (an
/// ARGB int), to EACH coloured entity: connections, identities,
/// connection_groups, snippet_categories, networks. When set it overrides the
/// legacy palette `colorIndex`; NULL keeps the old index/default behaviour.
/// Every step is a plain additive `addColumn`, so all pre-existing rows migrate
/// untouched.
///
/// Strategy mirrors `migration_v22_to_v23_test.dart` (no drift_dev
/// schema-snapshot infra exists in this repo): seed a `NativeDatabase.memory()`
/// with id-PK stubs for all 14 user tables at `PRAGMA user_version = 23`, open
/// `AppDatabase.forTesting(...)` (the first query runs `onUpgrade(23, 24)`),
/// then assert the pre-existing row survived and every new column exists.

/// The 14 user-data tables `_verifyMigrationIntegrity` expects to exist. The
/// v23 -> v24 step only `addColumn`s onto five of them, so minimal id-PK stubs
/// satisfy the existence + count checks (snippet_categories keys on `name`).
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

/// The five tables the v24 step adds `colorValue` to.
const _colouredTables = <String>[
  'connections',
  'identities',
  'connection_groups',
  'snippet_categories',
  'networks',
];

QueryExecutor _seededV23Executor() {
  return NativeDatabase.memory(setup: (rawDb) {
    for (final stmt in _stubTables) {
      rawDb.execute(stmt);
    }
    // One pre-existing connection - the row whose survival we assert on.
    rawDb.execute("INSERT INTO connections (id) VALUES ('c1');");
    // Tell drift the on-disk schema is v23 so it runs onUpgrade(23 -> 24).
    rawDb.execute('PRAGMA user_version = 23;');
  });
}

/// The user's real app-data directory receives a best-effort backup copy every
/// time `onUpgrade` runs. Snapshot the existing backups so tearDown removes only
/// the ones this test caused.
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
    db = AppDatabase.forTesting(_seededV23Executor());
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

  test('schemaVersion is >= 24 (guards the unbumped-migration regression)', () {
    expect(db.schemaVersion, greaterThanOrEqualTo(24));
  });

  test('v23 -> v24 upgrade runs and preserves the pre-existing connection',
      () async {
    // First query forces drift to open the executor, read user_version = 23,
    // and run onUpgrade(23, 24).
    final count = await db
        .customSelect('SELECT COUNT(*) AS cnt FROM connections')
        .getSingle();
    expect(
      count.read<int>('cnt'),
      1,
      reason: 'the pre-existing v23 connection row must survive the migration',
    );
  });

  test('upgrade physically adds colorValue to every coloured table', () async {
    // Force the upgrade to run first.
    await db.customSelect('SELECT COUNT(*) AS cnt FROM connections').getSingle();

    for (final table in _colouredTables) {
      final info = await db.customSelect('PRAGMA table_info($table)').get();
      final columns = {for (final r in info) r.read<String>('name')};
      // Drift snake-cases the Dart `colorValue` getter to the `color_value`
      // SQL column.
      expect(
        columns.contains('color_value'),
        isTrue,
        reason: 'the v24 addColumn step must have added color_value to $table',
      );
    }
  });

  test('color_value round-trips as a nullable ARGB int on connections',
      () async {
    // Pre-existing row: color_value defaults to NULL (untouched by migration).
    final before = await db
        .customSelect("SELECT color_value FROM connections WHERE id = 'c1'")
        .getSingle();
    expect(before.read<int?>('color_value'), isNull);

    // Persist a custom ARGB value and read it back.
    await db.customStatement(
      "UPDATE connections SET color_value = ? WHERE id = 'c1'",
      [0xFF3B82F6],
    );
    final after = await db
        .customSelect("SELECT color_value FROM connections WHERE id = 'c1'")
        .getSingle();
    expect(after.read<int?>('color_value'), 0xFF3B82F6);
  });
}
