import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v19 -> v20 upgrade path.
///
/// v20 (Server Monitor) adds ONE new column, `connections.monitored` (a
/// BOOL defaulting to false), which opts a host in to agentless SSH polling.
/// The step is purely additive - no existing table is touched and no row is
/// transformed - so every pre-existing connection migrates untouched with
/// `monitored = false`.
///
/// Strategy mirrors `migration_v18_to_v19_test.dart` (no drift_dev
/// schema-snapshot infra exists in this repo):
///   1. Seed a `NativeDatabase.memory()` - via its `setup` callback, on the
///      SAME connection drift will later use - with all 13 user tables shaped
///      as they were at v19 (the `connections` table with the v18/v19 columns
///      but WITHOUT `monitored`, plus minimal stubs for the other 12), one
///      pre-existing connection row, and `PRAGMA user_version = 19` so drift
///      runs `onUpgrade(19, 20)`.
///   2. Open `AppDatabase.forTesting(executor)`; the first query triggers the
///      upgrade, which `addColumn`s the new column.
///   3. Assert the pre-existing row survived, the new column physically
///      exists with the correct default, and the new DAO methods round-trip.

/// The `connections` table exactly as it existed at schema v19 - identical to
/// v18 (v19 added no `connections` columns), i.e. WITHOUT the v20 `monitored`
/// column the migration must add. Names/defaults verbatim from the v18 test.
const _v19ConnectionsTable = '''
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
  size_tier INTEGER NOT NULL DEFAULT 1,
  pinned INTEGER NOT NULL DEFAULT 0,
  note TEXT,
  last_connected INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (id)
);
''';

/// The other 12 user-data tables `AppDatabase._verifyMigrationIntegrity`
/// expects to exist post-migration. The v19 -> v20 step never touches them, so
/// minimal empty stubs satisfy the existence + queryability checks. At v19
/// `port_forward_network_overrides` already exists, so it is seeded here.
const _otherStubTables = <String>[
  'CREATE TABLE identities (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE connection_groups (id TEXT NOT NULL, PRIMARY KEY (id));',
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

/// Build a memory executor pre-seeded at user_version 19 with a v19
/// `connections` table + one row + stub tables, so opening drift over it runs
/// the real `onUpgrade(19, 20)`.
QueryExecutor _seededV19Executor() {
  return NativeDatabase.memory(setup: (rawDb) {
    rawDb.execute(_v19ConnectionsTable);
    for (final stmt in _otherStubTables) {
      rawDb.execute(stmt);
    }
    // One pre-existing connection - the row whose survival we assert on.
    rawDb.execute(
      "INSERT INTO connections (id, label, host, port, created_at, updated_at) "
      "VALUES ('c1', 'prod box', 'example.com', 22, 1000, 1000);",
    );
    // Tell drift the on-disk schema is v19 so it runs onUpgrade(19 -> 20).
    rawDb.execute('PRAGMA user_version = 19;');
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
    db = AppDatabase.forTesting(_seededV19Executor());
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

  test('schemaVersion is >= 20 (guards the unbumped-migration regression)',
      () {
    // The v19 -> v20 step only runs when the target schemaVersion is at least
    // 20; kept as `>=` so a later bump (v21, …) doesn't spuriously fail.
    expect(db.schemaVersion, greaterThanOrEqualTo(20));
  });

  test('v19 -> v20 upgrade runs and preserves the pre-existing row', () async {
    // First query forces drift to open the executor, read user_version = 19,
    // and run onUpgrade(19, 20).
    final count = await db
        .customSelect('SELECT COUNT(*) AS cnt FROM connections')
        .getSingle();
    expect(
      count.read<int>('cnt'),
      1,
      reason: 'the pre-existing v19 row must survive the migration',
    );
  });

  test('upgrade physically adds connections.monitored (default false)',
      () async {
    final info =
        await db.customSelect('PRAGMA table_info(connections)').get();
    final byName = {for (final r in info) r.read<String>('name'): r};
    expect(byName.containsKey('monitored'), isTrue,
        reason: 'the v20 addColumn step must have executed');

    // Existing rows migrate untouched → monitored = 0 (false).
    final row = await db
        .customSelect("SELECT monitored FROM connections WHERE id = 'c1'")
        .getSingle();
    expect(row.read<int>('monitored'), 0);
  });

  test('new DAO methods round-trip the monitored opt-in', () async {
    final dao = db.connectionsDao;

    // Pre-existing row starts unmonitored.
    expect(await dao.countMonitored(), 0);
    expect(await dao.getMonitored(), isEmpty);

    // Opt the host in.
    await dao.setMonitored('c1', true);
    expect(await dao.countMonitored(), 1);
    final monitored = await dao.getMonitored();
    expect(monitored, hasLength(1));
    expect(monitored.single.id, 'c1');
    expect(monitored.single.monitored, isTrue);

    // The reactive stream reflects the opt-in too.
    expect((await dao.watchMonitored().first).single.id, 'c1');

    // Opt back out.
    await dao.setMonitored('c1', false);
    expect(await dao.countMonitored(), 0);
    expect(await dao.getMonitored(), isEmpty);
  });
}
