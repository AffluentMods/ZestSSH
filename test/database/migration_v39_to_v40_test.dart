import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v39 -> v40 upgrade path.
///
/// v40 is the host-card icon override (2.0): two additive, nullable, SYNCED
/// columns on `connections` - `icon_id` (a built-in catalog id chosen in place
/// of the auto OS icon) and `custom_icon` (a base64 PNG upload). No new table
/// and no trigger change; the sync-blob schema_version bumps 16 -> 17 to signal
/// the new fields (asserted in the sync tests, not here).

const _stubTablesV39 = <String>[
  'CREATE TABLE connections (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE identities (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE connection_groups (id TEXT NOT NULL, PRIMARY KEY (id));',
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
  'CREATE TABLE monitor_samples (id TEXT NOT NULL, PRIMARY KEY (id));',
  'CREATE TABLE tombstones (entity_type TEXT NOT NULL, entity_id TEXT NOT NULL, deleted_at INTEGER NOT NULL, PRIMARY KEY (entity_type, entity_id));',
  'CREATE TABLE sftp_sync_manifest (host_id TEXT NOT NULL, remote_root TEXT NOT NULL, rel_path TEXT NOT NULL, local_size INTEGER NOT NULL, local_mtime_s INTEGER NOT NULL, content_hash TEXT, uploaded_at INTEGER NOT NULL, PRIMARY KEY (host_id, remote_root, rel_path));',
  'CREATE TABLE feedback_queue (nonce TEXT NOT NULL, payload TEXT NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY (nonce));',
  'CREATE TABLE local_state (key TEXT NOT NULL, value TEXT, updated_at INTEGER, PRIMARY KEY (key));',
  'CREATE TABLE terminal_triggers (id TEXT NOT NULL, name TEXT NOT NULL, pattern TEXT NOT NULL, case_sensitive INTEGER NOT NULL DEFAULT 0, notify INTEGER NOT NULL DEFAULT 1, highlight INTEGER NOT NULL DEFAULT 0, highlight_color INTEGER, play_sound INTEGER NOT NULL DEFAULT 0, connection_id TEXT, enabled INTEGER NOT NULL DEFAULT 1, sort_order INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER, PRIMARY KEY (id));',
  // command_history at v39: exit_code / duration_ms / cwd already present.
  'CREATE TABLE command_history (id TEXT NOT NULL, command TEXT NOT NULL, connection_id TEXT, host_label TEXT, exit_code INTEGER, duration_ms INTEGER, cwd TEXT, created_at INTEGER NOT NULL, updated_at INTEGER, PRIMARY KEY (id));',
];

const _knownHostsV39 = '''
CREATE TABLE known_hosts (
  id TEXT NOT NULL, host TEXT NOT NULL, port INTEGER NOT NULL,
  key_type TEXT NOT NULL, fingerprint TEXT NOT NULL, public_key_base64 TEXT NOT NULL,
  first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL, recorded_device TEXT,
  locally_verified INTEGER NOT NULL DEFAULT 1, via_scope TEXT,
  PRIMARY KEY (id), UNIQUE (host, port, key_type, via_scope)
);
''';

QueryExecutor _seededV39Executor() {
  return NativeDatabase.memory(setup: (rawDb) {
    for (final stmt in _stubTablesV39) {
      rawDb.execute(stmt);
    }
    rawDb.execute(_knownHostsV39);
    // A pre-existing connection (created at v39) must survive the upgrade and
    // gain the new icon columns as NULL.
    rawDb.execute("INSERT INTO connections (id) VALUES ('c-1');");
    rawDb.execute('PRAGMA user_version = 39;');
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(_seededV39Executor()));
  tearDown(() async => db.close());

  test('v40 adds icon_id / custom_icon to connections, keeping old rows',
      () async {
    expect(db.schemaVersion, greaterThanOrEqualTo(40));

    final cols = (await db.customSelect('PRAGMA table_info(connections)').get())
        .map((r) => r.read<String>('name'))
        .toSet();
    expect(cols, containsAll(<String>{'icon_id', 'custom_icon'}));

    // The pre-existing row survived; the new columns are null.
    final rows = await db
        .customSelect("SELECT id, icon_id, custom_icon FROM connections "
            "WHERE id = 'c-1'")
        .get();
    expect(rows, hasLength(1));
    expect(rows.single.read<String>('id'), 'c-1');
    expect(rows.single.readNullable<String>('icon_id'), isNull);
    expect(rows.single.readNullable<String>('custom_icon'), isNull);
  });
}
