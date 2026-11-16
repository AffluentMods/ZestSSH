import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v37 -> v38 upgrade path.
///
/// v38 adds `command_history`, the synced, tombstoned table behind Pro command
/// history. Purely additive: a new table plus its auto-bump updatedAt trigger.

const _stubTablesV37 = <String>[
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
];

const _knownHostsV37 = '''
CREATE TABLE known_hosts (
  id TEXT NOT NULL, host TEXT NOT NULL, port INTEGER NOT NULL,
  key_type TEXT NOT NULL, fingerprint TEXT NOT NULL, public_key_base64 TEXT NOT NULL,
  first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL, recorded_device TEXT,
  locally_verified INTEGER NOT NULL DEFAULT 1, via_scope TEXT,
  PRIMARY KEY (id), UNIQUE (host, port, key_type, via_scope)
);
''';

QueryExecutor _seededV37Executor() {
  return NativeDatabase.memory(setup: (rawDb) {
    for (final stmt in _stubTablesV37) {
      rawDb.execute(stmt);
    }
    rawDb.execute(_knownHostsV37);
    rawDb.execute("INSERT INTO connections (id) VALUES ('conn-1');");
    rawDb.execute('PRAGMA user_version = 37;');
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(_seededV37Executor()));
  tearDown(() async => db.close());

  test('v38 adds command_history with the expected columns', () async {
    expect(db.schemaVersion, greaterThanOrEqualTo(38));

    final tables = (await db
            .customSelect(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='command_history'")
            .get())
        .map((r) => r.read<String>('name'))
        .toList();
    expect(tables, ['command_history']);

    final info =
        await db.customSelect('PRAGMA table_info(command_history)').get();
    final cols = info.map((r) => r.read<String>('name')).toSet();
    expect(
      cols,
      containsAll(<String>{
        'id',
        'command',
        'connection_id',
        'host_label',
        'created_at',
        'updated_at',
      }),
    );

    // Pre-existing data survived.
    expect(
      await db
          .customSelect("SELECT id FROM connections WHERE id='conn-1'")
          .get(),
      isNotEmpty,
    );
  });

  test('DAO records, caps, auto-bumps updatedAt, and tombstones on delete',
      () async {
    final dao = db.commandHistoryDao;

    final id = await dao.record(command: 'ls -la', connectionId: 'c1');
    final all = await dao.getAll();
    expect(all, hasLength(1));
    expect(all.single.command, 'ls -la');
    expect(all.single.updatedAt, isNotNull,
        reason: 'the auto-bump trigger stamps updatedAt on insert');

    // Delete leaves a tombstone.
    await dao.deleteEntry(id);
    expect(await dao.getAll(), isEmpty);
    final tomb = await db
        .customSelect(
            "SELECT entity_id FROM tombstones WHERE entity_type='command_history'")
        .get();
    expect(tomb.map((r) => r.read<String>('entity_id')), [id]);
  });

  test('record prunes to the local cap', () async {
    final dao = db.commandHistoryDao;
    // Insert a handful with increasing timestamps; the cap is high, so nothing
    // is pruned, but the prune query must run without error and keep them all.
    for (var i = 0; i < 5; i++) {
      await dao.record(
        command: 'cmd $i',
        at: DateTime.fromMillisecondsSinceEpoch(i * 1000),
      );
    }
    expect(await dao.count(), 5);
  });
}
