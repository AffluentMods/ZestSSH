import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v21 -> v22 upgrade path.
///
/// v22 (snippet-category metadata) adds ONE new table, `snippet_categories`
/// (name PK + sort_order + nullable color_index + hidden), which persists a
/// snippet category's display order, accent color, and hidden state. The step
/// is purely additive - no existing table is touched and no row is transformed
/// - so every pre-existing row migrates untouched, and a category with no
/// metadata row keeps the pre-v22 defaults (alpha order, no color, visible).
///
/// Strategy mirrors `migration_v20_to_v21_test.dart` (no drift_dev
/// schema-snapshot infra exists in this repo):
///   1. Seed a `NativeDatabase.memory()` - via its `setup` callback, on the
///      SAME connection drift will later use - with all 13 user tables shaped
///      as they were at v21 (`connection_groups` WITH its color_index AND
///      icon_code_point columns, plus minimal stubs for the other 12) but
///      WITHOUT `snippet_categories`, one pre-existing group row, and
///      `PRAGMA user_version = 21` so drift runs `onUpgrade(21, 22)`.
///   2. Open `AppDatabase.forTesting(executor)`; the first query triggers the
///      upgrade, which `createTable`s the new table.
///   3. Assert the pre-existing row survived, the new table physically
///      exists, and the categories DAO round-trips a row.

/// The `connection_groups` table exactly as it existed at schema v21 - with
/// both color_index (v17) and icon_code_point (v21).
const _v21ConnectionGroupsTable = '''
CREATE TABLE connection_groups (
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_expanded INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL,
  color_index INTEGER,
  icon_code_point INTEGER,
  PRIMARY KEY (id)
);
''';

/// The other 12 user-data tables `AppDatabase._verifyMigrationIntegrity`
/// expects to exist post-migration. The v21 -> v22 step never touches them, so
/// minimal empty stubs satisfy the existence + queryability checks.
const _otherStubTables = <String>[
  'CREATE TABLE connections (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE identities (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE known_hosts (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE snippets (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE port_forward_rules (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE port_forward_network_overrides (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE automation_history (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE workflows (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE scheduled_tasks (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE networks (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE host_network_overrides (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE connection_tags (id TEXT NOT NULL, PRIMARY KEY (id));',
];

/// Build a memory executor pre-seeded at user_version 21 with a v21
/// `connection_groups` table + one row + stub tables (but NO
/// `snippet_categories`), so opening drift over it runs the real
/// `onUpgrade(21, 22)`.
QueryExecutor _seededV21Executor() {
  return NativeDatabase.memory(setup: (rawDb) {
    rawDb.execute(_v21ConnectionGroupsTable);
    for (final stmt in _otherStubTables) {
      rawDb.execute(stmt);
    }
    // One pre-existing group - the row whose survival we assert on.
    rawDb.execute(
      "INSERT INTO connection_groups "
      "(id, name, sort_order, is_expanded, created_at, color_index, icon_code_point) "
      "VALUES ('g1', 'Homelab', 0, 1, 1000, 3, NULL);",
    );
    // Tell drift the on-disk schema is v21 so it runs onUpgrade(21 -> 22).
    rawDb.execute('PRAGMA user_version = 21;');
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
    db = AppDatabase.forTesting(_seededV21Executor());
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

  test('schemaVersion is >= 22 (guards the unbumped-migration regression)',
      () {
    expect(db.schemaVersion, greaterThanOrEqualTo(22));
  });

  test('v21 -> v22 upgrade runs and preserves the pre-existing row', () async {
    // First query forces drift to open the executor, read user_version = 21,
    // and run onUpgrade(21, 22).
    final count = await db
        .customSelect('SELECT COUNT(*) AS cnt FROM connection_groups')
        .getSingle();
    expect(
      count.read<int>('cnt'),
      1,
      reason: 'the pre-existing v21 group row must survive the migration',
    );
  });

  test('upgrade physically creates the snippet_categories table', () async {
    final tables = await db
        .customSelect(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='snippet_categories'")
        .get();
    expect(tables.length, 1,
        reason: 'the v22 createTable step must have executed');

    // Verify the expected columns exist with the right shape.
    final info = await db
        .customSelect('PRAGMA table_info(snippet_categories)')
        .get();
    final byName = {for (final r in info) r.read<String>('name'): r};
    expect(byName.containsKey('name'), isTrue);
    expect(byName.containsKey('sort_order'), isTrue);
    expect(byName.containsKey('color_index'), isTrue);
    expect(byName.containsKey('hidden'), isTrue);
  });

  test('snippet-categories DAO round-trips a metadata row', () async {
    final dao = db.snippetCategoriesDao;

    // Lazily create a row by picking a color, then flipping hidden.
    await dao.setColor('Docker', 4);
    var row = await dao.getByName('Docker');
    expect(row, isNotNull);
    expect(row!.colorIndex, 4);
    expect(row.hidden, isFalse);
    expect(row.sortOrder, 0);

    await dao.setHidden('Docker', true);
    row = await dao.getByName('Docker');
    expect(row!.hidden, isTrue);
    // Color is untouched by the hidden write.
    expect(row.colorIndex, 4);

    // Ordering persists via updateOrder (creating lazy rows as needed).
    await dao.updateOrder(['System', 'Docker', 'Network']);
    expect((await dao.getByName('System'))!.sortOrder, 0);
    expect((await dao.getByName('Docker'))!.sortOrder, 1);
    expect((await dao.getByName('Network'))!.sortOrder, 2);
    // Docker kept its earlier color/hidden through the order write.
    final docker = await dao.getByName('Docker');
    expect(docker!.colorIndex, 4);
    expect(docker.hidden, isTrue);

    // Clearing the color reverts to the neutral default (null).
    await dao.setColor('Docker', null);
    expect((await dao.getByName('Docker'))!.colorIndex, isNull);

    // Rename moves the metadata row.
    await dao.rename('Docker', 'Containers');
    expect(await dao.getByName('Docker'), isNull);
    final renamed = await dao.getByName('Containers');
    expect(renamed, isNotNull);
    expect(renamed!.hidden, isTrue);

    // deleteByName removes the row entirely.
    await dao.deleteByName('Containers');
    expect(await dao.getByName('Containers'), isNull);
  });
}
