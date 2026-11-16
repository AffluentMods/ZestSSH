import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/tables/port_forward_network_overrides.dart';

/// Exercises the REAL schema v18 -> v19 upgrade path.
///
/// v19 (Networks completion) adds ONE new table,
/// `port_forward_network_overrides`, holding per-`(rule, network)` enable
/// state. The step is purely additive - no existing table is touched and no
/// row is transformed - so every pre-existing port-forward rule keeps its
/// exact pre-v19 semantics (absence of an override row == "inherit").
///
/// Strategy mirrors `migration_v17_to_v18_test.dart` (no drift_dev
/// schema-snapshot infra exists in this repo):
///   1. Seed a `NativeDatabase.memory()` - via its `setup` callback, on the
///      SAME connection drift will later use - with all 12 user tables shaped
///      as they were at v18 (the `connections` table with the v18 columns,
///      plus minimal stubs for the other 11), one pre-existing connection
///      row, and `PRAGMA user_version = 18` so drift runs `onUpgrade(18, 19)`.
///   2. Open `AppDatabase.forTesting(executor)`; the first query triggers the
///      upgrade, which `createTable`s the new table.
///   3. Assert the pre-existing row survived, the new table physically
///      exists + is queryable, and the new DAO methods round-trip.

/// The `connections` table exactly as it existed at schema v18 - the v17
/// columns plus the three v18 columns (`size_tier`, `pinned`, `note`). Names
/// and defaults taken verbatim from the generated `database.g.dart`.
const _v18ConnectionsTable = '''
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

/// The other 11 user-data tables `AppDatabase._verifyMigrationIntegrity`
/// expects to exist post-migration. The v18 -> v19 step never touches them,
/// so minimal empty stubs satisfy the existence + queryability checks. The
/// 13th expected table, `port_forward_network_overrides`, is deliberately NOT
/// seeded - the migration must create it.
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

/// Build a memory executor pre-seeded at user_version 18 with a v18
/// `connections` table + one row + stub tables, so opening drift over it runs
/// the real `onUpgrade(18, 19)`.
QueryExecutor _seededV18Executor() {
  return NativeDatabase.memory(setup: (rawDb) {
    rawDb.execute(_v18ConnectionsTable);
    for (final stmt in _otherStubTables) {
      rawDb.execute(stmt);
    }
    // One pre-existing connection - the row whose survival we assert on.
    rawDb.execute(
      "INSERT INTO connections (id, label, host, port, created_at, updated_at) "
      "VALUES ('c1', 'prod box', 'example.com', 22, 1000, 1000);",
    );
    // Tell drift the on-disk schema is v18 so it runs onUpgrade(18 -> 19).
    rawDb.execute('PRAGMA user_version = 18;');
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
    db = AppDatabase.forTesting(_seededV18Executor());
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

  test('schemaVersion is >= 19 (guards the unbumped-migration regression)',
      () {
    // The v18 -> v19 step only runs when the target schemaVersion is at least
    // 19; kept as `>=` so a later bump (v20, v21, …) doesn't spuriously fail.
    expect(db.schemaVersion, greaterThanOrEqualTo(19));
  });

  test('v18 -> v19 upgrade runs and preserves the pre-existing row', () async {
    // First query forces drift to open the executor, read user_version = 18,
    // and run onUpgrade(18, 19).
    final count = await db
        .customSelect('SELECT COUNT(*) AS cnt FROM connections')
        .getSingle();
    expect(
      count.read<int>('cnt'),
      1,
      reason: 'the pre-existing v18 row must survive the migration',
    );
  });

  test('upgrade physically creates port_forward_network_overrides', () async {
    final tables = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name = 'port_forward_network_overrides'",
        )
        .get();
    expect(tables, hasLength(1),
        reason: 'the v19 createTable step must have executed');

    final info = await db
        .customSelect('PRAGMA table_info(port_forward_network_overrides)')
        .get();
    final columnNames = info.map((r) => r.read<String>('name')).toSet();
    expect(
      columnNames,
      containsAll(<String>[
        'id',
        'rule_id',
        'network_id',
        'state',
        'created_at',
        'updated_at',
      ]),
    );
  });

  test('the new table is queryable (empty on a migrated DB)', () async {
    final rows = await db
        .customSelect('SELECT * FROM port_forward_network_overrides')
        .get();
    expect(rows, isEmpty);
  });

  test('new DAO methods round-trip a (rule, network) state override',
      () async {
    final dao = db.portForwardRulesDao;

    // Absent => inherit (existing rules keep their base semantics).
    expect(
      await dao.effectiveStateForNetwork('r1', 'n1'),
      PortForwardNetworkState.inherit,
    );
    expect(await dao.getNetworkOverridesForRule('r1'), isEmpty);

    // Set 'off' - upserts a single row.
    await dao.setNetworkOverrideState(
      ruleId: 'r1',
      networkId: 'n1',
      state: PortForwardNetworkState.off,
    );
    expect(
      await dao.effectiveStateForNetwork('r1', 'n1'),
      PortForwardNetworkState.off,
    );
    expect(await dao.getNetworkOverridesForRule('r1'), hasLength(1));

    // Re-set 'on' - updates in place (still one row, no unique-key churn).
    await dao.setNetworkOverrideState(
      ruleId: 'r1',
      networkId: 'n1',
      state: PortForwardNetworkState.on,
    );
    expect(
      await dao.effectiveStateForNetwork('r1', 'n1'),
      PortForwardNetworkState.on,
    );
    expect(await dao.getNetworkOverridesForRule('r1'), hasLength(1));

    // A different network for the same rule is independent.
    await dao.setNetworkOverrideState(
      ruleId: 'r1',
      networkId: 'n2',
      state: PortForwardNetworkState.off,
    );
    expect(await dao.getNetworkOverridesForRule('r1'), hasLength(2));

    // Back to inherit - deletes the row rather than storing a no-op.
    await dao.setNetworkOverrideState(
      ruleId: 'r1',
      networkId: 'n1',
      state: PortForwardNetworkState.inherit,
    );
    expect(
      await dao.effectiveStateForNetwork('r1', 'n1'),
      PortForwardNetworkState.inherit,
    );
    expect(await dao.getNetworkOverridesForRule('r1'), hasLength(1));
  });
}
