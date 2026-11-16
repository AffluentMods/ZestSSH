import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v38 -> v39 upgrade path.
///
/// v39 is the command-history "record extension" (Phase 2b): three additive,
/// nullable, LOCAL-ONLY columns on `command_history` - exit_code, duration_ms
/// and cwd - captured from OSC 133 / OSC 7 shell integration. No new table, no
/// trigger change, and (crucially) no sync-blob change: the columns are stripped
/// from the sync dump so the blob shape and schema_version stay 16.

const _stubTablesV38 = <String>[
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
  // command_history as it existed at v38: no exit_code / duration_ms / cwd yet.
  'CREATE TABLE command_history (id TEXT NOT NULL, command TEXT NOT NULL, connection_id TEXT, host_label TEXT, created_at INTEGER NOT NULL, updated_at INTEGER, PRIMARY KEY (id));',
];

const _knownHostsV38 = '''
CREATE TABLE known_hosts (
  id TEXT NOT NULL, host TEXT NOT NULL, port INTEGER NOT NULL,
  key_type TEXT NOT NULL, fingerprint TEXT NOT NULL, public_key_base64 TEXT NOT NULL,
  first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL, recorded_device TEXT,
  locally_verified INTEGER NOT NULL DEFAULT 1, via_scope TEXT,
  PRIMARY KEY (id), UNIQUE (host, port, key_type, via_scope)
);
''';

QueryExecutor _seededV38Executor() {
  return NativeDatabase.memory(setup: (rawDb) {
    for (final stmt in _stubTablesV38) {
      rawDb.execute(stmt);
    }
    rawDb.execute(_knownHostsV38);
    // A pre-existing history row (created at v38) must survive the upgrade and
    // read back with NULLs for the new columns.
    rawDb.execute(
      "INSERT INTO command_history (id, command, created_at) "
      "VALUES ('h-1', 'echo hi', 1000);",
    );
    rawDb.execute('PRAGMA user_version = 38;');
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(_seededV38Executor()));
  tearDown(() async => db.close());

  test('v39 adds exit_code / duration_ms / cwd, keeping old rows', () async {
    expect(db.schemaVersion, greaterThanOrEqualTo(39));

    final cols = (await db.customSelect('PRAGMA table_info(command_history)').get())
        .map((r) => r.read<String>('name'))
        .toSet();
    expect(
      cols,
      containsAll(<String>{'exit_code', 'duration_ms', 'cwd'}),
    );

    // The pre-existing row survived and the new columns default to null.
    final all = await db.commandHistoryDao.getAll();
    expect(all, hasLength(1));
    expect(all.single.command, 'echo hi');
    expect(all.single.exitCode, isNull);
    expect(all.single.durationMs, isNull);
    expect(all.single.cwd, isNull);
  });

  test('record stores cwd; updateResult attaches exit code + duration',
      () async {
    final dao = db.commandHistoryDao;
    final id = await dao.record(
      command: 'npm run build',
      connectionId: 'c1',
      cwd: '/home/me/site',
    );
    await dao.updateResult(id, exitCode: 0, durationMs: 3200);

    final row = (await dao.getAll()).firstWhere((e) => e.id == id);
    expect(row.cwd, '/home/me/site');
    expect(row.exitCode, 0);
    expect(row.durationMs, 3200);
  });
}
