import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v22 -> v23 upgrade path.
///
/// v23 (1.7 snippet detail pane) adds ONE new nullable column,
/// `snippets.metadata` (JSON: a snippet description + per-variable
/// descriptions). The step is purely additive - no existing table is touched
/// and no row is transformed - so every pre-existing snippet migrates
/// untouched, and a snippet with no metadata row keeps NULL (no description).
///
/// Strategy mirrors `migration_v21_to_v22_test.dart` (no drift_dev
/// schema-snapshot infra exists in this repo):
///   1. Seed a `NativeDatabase.memory()` with all 14 user tables shaped as they
///      were at v22 (`snippets` WITHOUT its metadata column, plus stubs for the
///      rest incl. the v22 `snippet_categories`), one pre-existing snippet row,
///      and `PRAGMA user_version = 22` so drift runs `onUpgrade(22, 23)`.
///   2. Open `AppDatabase.forTesting(executor)`; the first query triggers the
///      upgrade, which `addColumn`s the new column.
///   3. Assert the pre-existing row survived, the new column physically exists,
///      and the snippets DAO round-trips metadata.

/// The `snippets` table exactly as it existed at schema v22 - every column
/// EXCEPT the v23 `metadata`.
const _v22SnippetsTable = '''
CREATE TABLE snippets (
  id TEXT NOT NULL,
  label TEXT NOT NULL,
  command TEXT NOT NULL,
  category TEXT,
  confirm_before_run INTEGER NOT NULL DEFAULT 0,
  is_default INTEGER NOT NULL DEFAULT 0,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (id)
);
''';

/// The other 13 user-data tables `_verifyMigrationIntegrity` expects to exist
/// post-migration. The v22 -> v23 step never touches them, so minimal empty
/// stubs satisfy the existence + count checks. `snippet_categories` already
/// exists at v22 (created in the v22 step), so it is seeded here too.
const _otherStubTables = <String>[
  'CREATE TABLE connections (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE identities (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE connection_groups (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE known_hosts (id TEXT NOT NULL, PRIMARY KEY (id));',
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

/// Build a memory executor pre-seeded at user_version 22 with a v22 `snippets`
/// table + one row + stub tables (but NO `metadata` column), so opening drift
/// over it runs the real `onUpgrade(22, 23)`.
QueryExecutor _seededV22Executor() {
  return NativeDatabase.memory(setup: (rawDb) {
    rawDb.execute(_v22SnippetsTable);
    for (final stmt in _otherStubTables) {
      rawDb.execute(stmt);
    }
    // One pre-existing snippet - the row whose survival we assert on. It uses a
    // `${VAR:-default}` command so the default lives in the command itself.
    rawDb.execute(
      "INSERT INTO snippets "
      "(id, label, command, category, confirm_before_run, is_default, "
      "sort_order, created_at, updated_at) "
      "VALUES ('s1', 'Restart', 'docker restart \${NAME:-web}', 'Docker', "
      "0, 1, 0, 1000, 1000);",
    );
    // Tell drift the on-disk schema is v22 so it runs onUpgrade(22 -> 23).
    rawDb.execute('PRAGMA user_version = 22;');
  });
}

/// The user's real app-data directory receives a best-effort
/// `zestssh_backup_<ts>.db` copy every time `onUpgrade` runs. Snapshot the
/// existing backups so tearDown removes only the ones this test caused.
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
    db = AppDatabase.forTesting(_seededV22Executor());
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

  test('schemaVersion is >= 23 (guards the unbumped-migration regression)', () {
    expect(db.schemaVersion, greaterThanOrEqualTo(23));
  });

  test('v22 -> v23 upgrade runs and preserves the pre-existing snippet',
      () async {
    // First query forces drift to open the executor, read user_version = 22,
    // and run onUpgrade(22, 23).
    final count = await db
        .customSelect('SELECT COUNT(*) AS cnt FROM snippets')
        .getSingle();
    expect(
      count.read<int>('cnt'),
      1,
      reason: 'the pre-existing v22 snippet row must survive the migration',
    );
  });

  test('upgrade physically adds the metadata column', () async {
    final info =
        await db.customSelect('PRAGMA table_info(snippets)').get();
    final columns = {for (final r in info) r.read<String>('name')};
    expect(columns.contains('metadata'), isTrue,
        reason: 'the v23 addColumn step must have executed');
    // And the old columns are all still present.
    expect(columns, containsAll(<String>{'id', 'label', 'command', 'category'}));
  });

  test('snippets DAO round-trips metadata after the migration', () async {
    final dao = db.snippetsDao;

    // Pre-existing row loads and has NULL metadata (untouched by the migration).
    final before = await dao.getById('s1');
    expect(before, isNotNull);
    expect(before!.metadata, isNull);

    // Persist metadata and read it back.
    await dao.updateSnippet(SnippetsCompanion(
      id: const Value('s1'),
      metadata: const Value('{"description":"restarts web","variables":'
          '{"NAME":"container"}}'),
    ));
    final after = await dao.getById('s1');
    expect(after!.metadata, contains('restarts web'));
    // The command (and its baked-in default) is untouched.
    expect(after.command, r'docker restart ${NAME:-web}');
  });
}
