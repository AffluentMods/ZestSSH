import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v20 -> v21 upgrade path.
///
/// v21 (folder icons) adds ONE new column, `connection_groups.icon_code_point`
/// (a nullable INTEGER holding the codePoint of a const IconData), which lets
/// a user pick a folder icon. The step is purely additive - no existing table
/// is touched and no row is transformed - so every pre-existing group migrates
/// untouched with `iconCodePoint = null` (the default folder glyph).
///
/// Strategy mirrors `migration_v19_to_v20_test.dart` (no drift_dev
/// schema-snapshot infra exists in this repo):
///   1. Seed a `NativeDatabase.memory()` - via its `setup` callback, on the
///      SAME connection drift will later use - with all 13 user tables shaped
///      as they were at v20 (the `connection_groups` table with its
///      color_index column but WITHOUT icon_code_point, plus minimal stubs for
///      the other 12), one pre-existing group row, and
///      `PRAGMA user_version = 20` so drift runs `onUpgrade(20, 21)`.
///   2. Open `AppDatabase.forTesting(executor)`; the first query triggers the
///      upgrade, which `addColumn`s the new column.
///   3. Assert the pre-existing row survived, the new column physically
///      exists with the correct default, and the groups DAO round-trips it.

/// The `connection_groups` table exactly as it existed at schema v20 - i.e.
/// WITHOUT the v21 `icon_code_point` column the migration must add. Column
/// names/defaults match the drift table (colorIndex added at v17).
const _v20ConnectionGroupsTable = '''
CREATE TABLE connection_groups (
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_expanded INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL,
  color_index INTEGER,
  PRIMARY KEY (id)
);
''';

/// The other 12 user-data tables `AppDatabase._verifyMigrationIntegrity`
/// expects to exist post-migration. The v20 -> v21 step never touches them, so
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

/// Build a memory executor pre-seeded at user_version 20 with a v20
/// `connection_groups` table + one row + stub tables, so opening drift over it
/// runs the real `onUpgrade(20, 21)`.
QueryExecutor _seededV20Executor() {
  return NativeDatabase.memory(setup: (rawDb) {
    rawDb.execute(_v20ConnectionGroupsTable);
    for (final stmt in _otherStubTables) {
      rawDb.execute(stmt);
    }
    // One pre-existing group - the row whose survival we assert on. It has a
    // picked color_index but (of course) no icon yet.
    rawDb.execute(
      "INSERT INTO connection_groups "
      "(id, name, sort_order, is_expanded, created_at, color_index) "
      "VALUES ('g1', 'Homelab', 0, 1, 1000, 3);",
    );
    // Tell drift the on-disk schema is v20 so it runs onUpgrade(20 -> 21).
    rawDb.execute('PRAGMA user_version = 20;');
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
    db = AppDatabase.forTesting(_seededV20Executor());
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

  test('schemaVersion is >= 21 (guards the unbumped-migration regression)',
      () {
    // The v20 -> v21 step only runs when the target schemaVersion is at least
    // 21; kept as `>=` so a later bump doesn't spuriously fail.
    expect(db.schemaVersion, greaterThanOrEqualTo(21));
  });

  test('v20 -> v21 upgrade runs and preserves the pre-existing row', () async {
    // First query forces drift to open the executor, read user_version = 20,
    // and run onUpgrade(20, 21).
    final count = await db
        .customSelect('SELECT COUNT(*) AS cnt FROM connection_groups')
        .getSingle();
    expect(
      count.read<int>('cnt'),
      1,
      reason: 'the pre-existing v20 group row must survive the migration',
    );
  });

  test('upgrade physically adds connection_groups.icon_code_point (null)',
      () async {
    final info = await db
        .customSelect('PRAGMA table_info(connection_groups)')
        .get();
    final byName = {for (final r in info) r.read<String>('name'): r};
    expect(byName.containsKey('icon_code_point'), isTrue,
        reason: 'the v21 addColumn step must have executed');

    // Existing rows migrate untouched → icon_code_point is NULL.
    final row = await db
        .customSelect(
            "SELECT icon_code_point FROM connection_groups WHERE id = 'g1'")
        .getSingle();
    expect(row.data['icon_code_point'], isNull);
  });

  test('groups DAO round-trips the picked icon', () async {
    final dao = db.connectionGroupsDao;

    // Pre-existing row starts with no icon but keeps its color pick.
    final before = await dao.getById('g1');
    expect(before, isNotNull);
    expect(before!.iconCodePoint, isNull);
    expect(before.colorIndex, 3);

    // Pick an icon.
    await dao.updateGroup(const ConnectionGroupsCompanion(
      id: Value('g1'),
      iconCodePoint: Value(0xf2f8), // LucideIcons.folder codePoint
    ));
    final after = await dao.getById('g1');
    expect(after!.iconCodePoint, 0xf2f8);
    // The color pick is untouched by the icon write.
    expect(after.colorIndex, 3);

    // Clear it again.
    await dao.updateGroup(const ConnectionGroupsCompanion(
      id: Value('g1'),
      iconCodePoint: Value(null),
    ));
    expect((await dao.getById('g1'))!.iconCodePoint, isNull);
  });
}
