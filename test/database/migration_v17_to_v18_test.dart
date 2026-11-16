import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v17 -> v18 upgrade path.
///
/// v18 (Part B) adds three columns to `connections`:
///   * `size_tier`  INTEGER NOT NULL DEFAULT 1  (home-screen card size)
///   * `pinned`     INTEGER NOT NULL DEFAULT 0  (pinned-as-synced-property)
///   * `note`       TEXT (nullable, no default)
///
/// This codebase has previously shipped a migration whose `schemaVersion`
/// was left unbumped, so the `onUpgrade` path never ran and existing users
/// hit a "no such column" data-loss failure. A fresh-DB test (see
/// `connections_partb_test.dart`) can't catch that class of bug because a
/// freshly created database always has every column. Only driving a real
/// pre-existing v17 database through `onUpgrade` does.
///
/// Strategy (no drift_dev schema-snapshot infra exists in this repo):
///   1. Seed a `NativeDatabase.memory()` - via its `setup` callback, on the
///      SAME connection drift will later use - with the `connections` table
///      shaped exactly as it was at v17 (every generated column MINUS the
///      three v18 ones), plus one pre-existing row, plus minimal stubs for
///      the other 11 user tables (the post-migration integrity check in
///      `AppDatabase` requires every expected table to exist), and finally
///      `PRAGMA user_version = 17` so drift believes the on-disk schema is
///      v17 and runs `onUpgrade(17, 18)`.
///   2. Open `AppDatabase.forTesting(executor)`; the first query triggers
///      the upgrade.
///   3. Assert the pre-existing row survived AND was back-filled with the
///      new column defaults, and that the three columns now physically exist.

/// The `connections` table exactly as it existed at schema v17 - i.e. every
/// column drift generates for the `Connections` table today MINUS the three
/// v18 columns (`size_tier`, `pinned`, `note`). Column names and defaults are
/// taken verbatim from the generated `database.g.dart`.
const _v17ConnectionsTable = '''
CREATE TABLE connections (
  id TEXT NOT NULL,
  label TEXT NOT NULL,
  host TEXT NOT NULL,
  port INTEGER NOT NULL DEFAULT 22,
  identity_id TEXT,
  group_id TEXT,
  color_index INTEGER NOT NULL DEFAULT 0,
  protocol TEXT NOT NULL DEFAULT 'ssh',
  zlib_compression INTEGER NOT NULL DEFAULT 0,
  startup_command TEXT,
  snippet_id TEXT,
  connect_via_id TEXT,
  keep_alive_seconds INTEGER NOT NULL DEFAULT 0,
  wol_mac_address TEXT,
  wol_broadcast_address TEXT DEFAULT '255.255.255.255',
  wol_port INTEGER DEFAULT 9,
  env_vars TEXT NOT NULL DEFAULT '',
  forward_agent INTEGER NOT NULL DEFAULT 0,
  compatibility_mode INTEGER NOT NULL DEFAULT 0,
  sort_order INTEGER NOT NULL DEFAULT 0,
  last_connected INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (id)
);
''';

/// The other 11 user-data tables `AppDatabase._verifyMigrationIntegrity`
/// expects to exist post-migration. The v17 -> v18 step never touches them,
/// so minimal empty stubs are enough to satisfy the existence + queryability
/// checks (they hold zero rows, so the row-count guard skips them).
const _otherStubTables = <String>[
  'CREATE TABLE identities (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE connection_groups (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE known_hosts (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE snippets (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE port_forward_rules (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE automation_history (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE workflows (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE scheduled_tasks (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE networks (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE host_network_overrides (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE connection_tags (id TEXT NOT NULL, PRIMARY KEY (id));',
];

/// Build a memory executor pre-seeded at user_version 17 with a v17
/// `connections` table + one row + stub tables, so opening drift over it
/// runs the real `onUpgrade(17, 18)`.
QueryExecutor _seededV17Executor() {
  return NativeDatabase.memory(setup: (rawDb) {
    rawDb.execute(_v17ConnectionsTable);
    for (final stmt in _otherStubTables) {
      rawDb.execute(stmt);
    }
    // One pre-existing connection, written with ONLY the v17 columns -
    // this is the row whose survival + back-fill we assert on.
    rawDb.execute(
      "INSERT INTO connections (id, label, host, port, created_at, updated_at) "
      "VALUES ('c1', 'prod box', 'example.com', 22, 1000, 1000);",
    );
    // Tell drift the on-disk schema is v17 so it runs onUpgrade(17 -> 18)
    // rather than onCreate.
    rawDb.execute('PRAGMA user_version = 17;');
  });
}

/// The user's real app-data directory receives a best-effort
/// `zestssh_backup_<ts>.db` copy every time `onUpgrade` runs (the migration
/// backs up before migrating). Snapshot the existing backups so tearDown can
/// remove only the ones this test caused, leaving the user's dir untouched.
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
    db = AppDatabase.forTesting(_seededV17Executor());
  });

  tearDown(() async {
    await db.close();
    // Remove only backup files the migration created during this test.
    final after = _backupSnapshot(appDataDir);
    for (final path in after.difference(backupsBefore)) {
      try {
        File(path).deleteSync();
      } catch (_) {}
    }
  });

  test('schemaVersion is >= 18 (guards the unbumped-migration regression)',
      () {
    // The v17 -> v18 step only runs when the target schemaVersion is at least
    // 18. Later additive bumps (v19+) push this higher; assert the floor so
    // this guard survives them while still catching an un-bumped v18.
    expect(db.schemaVersion, greaterThanOrEqualTo(18));
  });

  test('v17 -> v18 upgrade runs and preserves the pre-existing row', () async {
    // First query forces drift to open the executor, which seeds the v17
    // schema (setup callback), reads user_version = 17, and runs onUpgrade.
    final count = await db
        .customSelect('SELECT COUNT(*) AS cnt FROM connections')
        .getSingle();
    expect(
      count.read<int>('cnt'),
      1,
      reason: 'the pre-existing v17 row must survive the migration',
    );
  });

  test('upgrade physically adds size_tier / pinned / note columns', () async {
    final info =
        await db.customSelect('PRAGMA table_info(connections)').get();
    final columnNames =
        info.map((r) => r.read<String>('name')).toSet();
    expect(columnNames, containsAll(<String>['size_tier', 'pinned', 'note']),
        reason: 'the v18 addColumn statements must have executed');
  });

  test('existing row is back-filled with the correct v18 defaults',
      () async {
    final row = await db
        .customSelect(
          'SELECT size_tier, pinned, note FROM connections WHERE id = ?',
          variables: [Variable.withString('c1')],
        )
        .getSingle();

    // NOT NULL columns with DEFAULTs back-fill onto the existing row.
    expect(row.read<int>('size_tier'), 1, reason: 'Medium is the default tier');
    expect(row.read<int>('pinned'), 0, reason: 'unpinned by default');
    // note is nullable with no default -> stays NULL on the migrated row.
    expect(row.readNullable<String>('note'), isNull);
  });

  test('the DAO can read the migrated row through the drift model', () async {
    // Proves the generated Connections mapper (which reads all v18 columns)
    // works against the upgraded schema, not just raw SQL.
    final c = await db.connectionsDao.getById('c1');
    expect(c, isNotNull);
    expect(c!.host, 'example.com');
    expect(c.sizeTier, 1);
    expect(c.pinned, false);
    expect(c.note, isNull);
  });
}
