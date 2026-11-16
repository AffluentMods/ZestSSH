import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Regression test for the multi-version upgrade crash reported on 1.6.x:
///
///   SqliteException(1): duplicate column name: color_value
///   ALTER TABLE "snippet_categories" ADD COLUMN "color_value" INTEGER NULL;
///
/// Every per-step migration test starts ONE version below its target, so none
/// crossed the interaction that caused this. A table `createTable`d in an
/// EARLIER step is built from the CURRENT schema - which already contains
/// columns added in LATER steps - so a subsequent `addColumn` for one of those
/// columns re-adds it and throws. Concretely: `snippet_categories` is created
/// at from<22 (already carrying `color_value`), then the from<24 step tried to
/// `addColumn` color_value again; `networks` (created at from<12) is the same
/// trap. ANY user upgrading from schema <= 21 (i.e. pre-1.6) hit it.
///
/// This seeds a v21 database (no `snippet_categories` yet, no `color_value`
/// anywhere) and lets drift run the FULL onUpgrade(21 -> schemaVersion) - the
/// exact failing path. It must now complete because every `addColumn` is
/// idempotent (`_addColumnIfAbsent` checks `PRAGMA table_info` first).

/// `connection_groups` exactly as it existed at schema v21 (color_index @v17 +
/// icon_code_point @v21, but NO color_value - that arrives at v24).
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

/// The other 12 user tables present at v21 (minimal stubs). Crucially NONE
/// carry `color_value`, and `snippet_categories` (v22) / `monitor_samples`
/// (v27) do not exist yet - so the full upgrade must createTable them AND make
/// the v24 color_value adds no-ops where the column already exists.
const _otherV21StubTables = <String>[
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

QueryExecutor _seededV21Executor() {
  return NativeDatabase.memory(setup: (rawDb) {
    rawDb.execute(_v21ConnectionGroupsTable);
    for (final stmt in _otherV21StubTables) {
      rawDb.execute(stmt);
    }
    // One pre-existing group - the row whose survival across the WHOLE
    // multi-version upgrade we assert on.
    rawDb.execute(
      "INSERT INTO connection_groups "
      "(id, name, sort_order, is_expanded, created_at, color_index, icon_code_point) "
      "VALUES ('g1', 'Servers', 0, 1, 0, NULL, NULL);",
    );
    // Tell drift the on-disk schema is v21 so it runs onUpgrade(21 -> current).
    rawDb.execute('PRAGMA user_version = 21;');
  });
}

/// onUpgrade drops a best-effort backup into the app-data dir; snapshot so
/// tearDown removes only the ones this test created.
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

  test(
    'v21 -> latest multi-version upgrade completes without a duplicate '
    'color_value crash and preserves data',
    () async {
      // The first query forces drift to read user_version = 21 and run the FULL
      // onUpgrade(21, schemaVersion). Before the idempotent-addColumn fix this
      // threw: duplicate column name: color_value (snippet_categories).
      final count = await db
          .customSelect('SELECT COUNT(*) AS cnt FROM connection_groups')
          .getSingle();
      expect(
        count.read<int>('cnt'),
        1,
        reason: 'the pre-existing v21 group row must survive the full upgrade',
      );
    },
  );

  test(
    'tables createTable-d before color_value was added end up with exactly one '
    'color_value column',
    () async {
      // Force the full upgrade to run first.
      await db
          .customSelect('SELECT COUNT(*) AS cnt FROM connection_groups')
          .getSingle();

      // snippet_categories (createTable @v22) and networks (createTable @v12)
      // are the two tables that carried color_value in from their createTable
      // step; connections is a base table that genuinely needs the v24 add.
      // All must have EXACTLY one color_value column post-upgrade.
      for (final table in const [
        'snippet_categories',
        'networks',
        'connections',
        'identities',
      ]) {
        final info = await db.customSelect('PRAGMA table_info($table)').get();
        final colorValueColumns = info
            .map((r) => r.read<String>('name'))
            .where((name) => name == 'color_value')
            .length;
        expect(
          colorValueColumns,
          1,
          reason: '$table must have exactly one color_value column',
        );
      }
    },
  );
}
