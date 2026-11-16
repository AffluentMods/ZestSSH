import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v40 -> v41 upgrade path.
///
/// v41 adds the Orchard bookkeeping tables (3.0): crate_items_meta,
/// crate_leftovers, crate_outbox, orchard_info, orchard_crates, space_keys,
/// orchard_secrets and orchard_sync_control. Only an Orchard's own database
/// fills them; the Tree's gets them empty and gains no triggers. Existing
/// rows are untouched.

const _stubTablesV40 = <String>[
  'CREATE TABLE connections (id TEXT NOT NULL, icon_id TEXT, custom_icon TEXT, PRIMARY KEY (id));',
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
  'CREATE TABLE command_history (id TEXT NOT NULL, command TEXT NOT NULL, connection_id TEXT, host_label TEXT, exit_code INTEGER, duration_ms INTEGER, cwd TEXT, created_at INTEGER NOT NULL, updated_at INTEGER, PRIMARY KEY (id));',
  '''CREATE TABLE known_hosts (
    id TEXT NOT NULL, host TEXT NOT NULL, port INTEGER NOT NULL,
    key_type TEXT NOT NULL, fingerprint TEXT NOT NULL, public_key_base64 TEXT NOT NULL,
    first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL, recorded_device TEXT,
    locally_verified INTEGER NOT NULL DEFAULT 1, via_scope TEXT,
    PRIMARY KEY (id), UNIQUE (host, port, key_type, via_scope)
  );''',
];

QueryExecutor _seededV40Executor() {
  return NativeDatabase.memory(setup: (rawDb) {
    for (final stmt in _stubTablesV40) {
      rawDb.execute(stmt);
    }
    rawDb.execute("INSERT INTO connections (id) VALUES ('c-1');");
    rawDb.execute('PRAGMA user_version = 40;');
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(_seededV40Executor()));
  tearDown(() async => db.close());

  test('v41 adds the Orchard tables, empty, and keeps the Tree as it was', () async {
    expect(db.schemaVersion, greaterThanOrEqualTo(41));
    final tables = (await db
            .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
            .get())
        .map((r) => r.read<String>('name'))
        .toSet();
    const added = {
      'crate_items_meta',
      'crate_leftovers',
      'crate_outbox',
      'orchard_info',
      'orchard_crates',
      'space_keys',
      'orchard_secrets',
      'orchard_sync_control',
    };
    expect(tables, containsAll(added));
    for (final t in added) {
      final n = await db.customSelect('SELECT COUNT(*) AS n FROM $t').getSingle();
      expect(n.read<int>('n'), 0, reason: '$t is empty in the Tree');
    }
    final rows = await db.customSelect('SELECT id FROM connections').get();
    expect(rows.map((r) => r.read<String>('id')), ['c-1']);
    final triggers = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'trg_ob_%'")
        .get();
    expect(triggers, isEmpty, reason: "the Tree's database records nothing for Crates");
  });
}
