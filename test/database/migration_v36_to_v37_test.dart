import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v36 -> v37 upgrade path.
///
/// v37 adds `terminal_triggers`, the synced, tombstoned table behind the
/// trigger / highlight rules feature. Purely additive: a new table only, plus
/// its auto-bump updatedAt trigger. This seeds a realistic v36 DB and asserts
/// the table + columns exist, the DAO round-trips, a delete leaves a tombstone,
/// and the auto-bump trigger stamps updatedAt.

const _stubTablesV36 = <String>[
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
];

const _knownHostsV36 = '''
CREATE TABLE known_hosts (
  id TEXT NOT NULL,
  host TEXT NOT NULL,
  port INTEGER NOT NULL,
  key_type TEXT NOT NULL,
  fingerprint TEXT NOT NULL,
  public_key_base64 TEXT NOT NULL,
  first_seen INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  recorded_device TEXT,
  locally_verified INTEGER NOT NULL DEFAULT 1,
  via_scope TEXT,
  PRIMARY KEY (id),
  UNIQUE (host, port, key_type, via_scope)
);
''';

QueryExecutor _seededV36Executor() {
  return NativeDatabase.memory(setup: (rawDb) {
    for (final stmt in _stubTablesV36) {
      rawDb.execute(stmt);
    }
    rawDb.execute(_knownHostsV36);
    rawDb.execute("INSERT INTO connections (id) VALUES ('conn-1');");
    rawDb.execute('PRAGMA user_version = 36;');
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(_seededV36Executor());
  });
  tearDown(() async {
    await db.close();
  });

  test('v37 adds terminal_triggers with the expected columns', () async {
    expect(db.schemaVersion, greaterThanOrEqualTo(37));

    final tables = (await db
            .customSelect(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='terminal_triggers'")
            .get())
        .map((r) => r.read<String>('name'))
        .toList();
    expect(tables, ['terminal_triggers']);

    final info =
        await db.customSelect('PRAGMA table_info(terminal_triggers)').get();
    final cols = info.map((r) => r.read<String>('name')).toSet();
    expect(
      cols,
      containsAll(<String>{
        'id',
        'name',
        'pattern',
        'case_sensitive',
        'notify',
        'highlight',
        'highlight_color',
        'play_sound',
        'connection_id',
        'enabled',
        'sort_order',
        'created_at',
        'updated_at',
      }),
    );

    // The pre-existing row survived the upgrade.
    final conn = await db
        .customSelect("SELECT id FROM connections WHERE id = 'conn-1'")
        .get();
    expect(conn, isNotEmpty);
  });

  test('DAO round-trips, auto-bumps updatedAt, and tombstones on delete',
      () async {
    final dao = db.terminalTriggersDao;

    await dao.upsert(TerminalTriggersCompanion.insert(
      id: 't1',
      name: 'Error',
      pattern: r'(?i)error',
      notify: const Value(true),
      highlight: const Value(true),
      highlightColor: const Value(0xFFEF4444),
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      // updatedAt intentionally absent -> the insert trigger stamps it.
    ));

    final all = await dao.getAll();
    expect(all, hasLength(1));
    expect(all.single.name, 'Error');
    expect(all.single.highlightColor, 0xFFEF4444);
    expect(all.single.updatedAt, isNotNull,
        reason: 'the auto-bump trigger stamps updatedAt on insert');

    // Toggle enabled.
    await dao.setEnabled('t1', false);
    expect((await dao.getById('t1'))!.enabled, isFalse);

    // Delete leaves a tombstone so the removal propagates to other devices.
    await dao.deleteTrigger('t1');
    expect(await dao.getAll(), isEmpty);
    final tombstones = await db
        .customSelect(
            "SELECT entity_id FROM tombstones WHERE entity_type = 'terminal_triggers'")
        .get();
    expect(tombstones.map((r) => r.read<String>('entity_id')), ['t1']);
  });
}
