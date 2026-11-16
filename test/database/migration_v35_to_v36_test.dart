import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/session_persistence_service.dart';

/// Exercises the REAL schema v35 -> v36 upgrade path.
///
/// v36 adds `local_state`, the device-local key-value table that takes the
/// tab snapshot, the saved workspaces and the folder-pin counters out of
/// plaintext preferences (they name SFTP folders and remote users). Purely
/// additive: a new table only, no existing row touched. This seeds a
/// realistic v35 DB and asserts the table exists, that the store works, and
/// that a snapshot an older build left in preferences is imported once and
/// the preference removed.

const _stubTables = <String>[
  'CREATE TABLE connections (id TEXT NOT NULL, last_remote_path TEXT, last_remote_user TEXT, last_remote_path_at INTEGER, PRIMARY KEY (id));',
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
];

const _knownHostsV35 = '''
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

QueryExecutor _seededV35Executor() {
  return NativeDatabase.memory(setup: (rawDb) {
    for (final stmt in _stubTables) {
      rawDb.execute(stmt);
    }
    rawDb.execute(_knownHostsV35);
    rawDb.execute('CREATE INDEX idx_known_hosts_host ON known_hosts (host);');
    rawDb.execute("INSERT INTO connections (id) VALUES ('conn-1');");
    rawDb.execute('PRAGMA user_version = 35;');
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(_seededV35Executor());
  });
  tearDown(() async {
    await db.close();
  });

  test('v36 adds local_state, the store works, data intact', () async {
    expect(db.schemaVersion, greaterThanOrEqualTo(36));

    final tables = (await db
            .customSelect(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='local_state'")
            .get())
        .map((r) => r.read<String>('name'))
        .toList();
    expect(tables, ['local_state']);

    final info = await db.customSelect('PRAGMA table_info(local_state)').get();
    final cols = info.map((r) => r.read<String>('name')).toSet();
    expect(cols, {'key', 'value', 'updated_at'});

    final store = LocalStateStore(db);
    await store.write('a:1', 'one');
    await store.write('a:2', 'two');
    await store.write('b:1', 'three');
    await store.writeInt('n', 3);
    await store.writeBool('flag', true);
    expect(await store.read('a:1'), 'one');
    expect(await store.readInt('n'), 3);
    expect(await store.readBool('flag'), isTrue);
    expect(await store.readBool('missing'), isFalse);
    await store.write('a:1', 'uno');
    expect(await store.read('a:1'), 'uno', reason: 'upsert');
    expect((await store.keysWithPrefix('a:'))..sort(), ['a:1', 'a:2']);
    await store.removeWithPrefix('a:');
    expect(await store.keysWithPrefix('a:'), isEmpty);
    expect(await store.read('b:1'), 'three');

    // The pin-counter prefixes contain underscores, which LIKE would treat
    // as wildcards: the prefix match must stay exact.
    await store.writeInt('sftp_folder_visits:c1:/srv', 2);
    await store.writeInt('sftp_folder_visits:c2:/srv', 1);
    await store.writeBool('sftpXfolderXvisits:c1:/srv', true);
    await store.removeWithPrefix('sftp_folder_visits:c1:');
    expect(await store.readInt('sftp_folder_visits:c1:/srv'), isNull);
    expect(await store.readInt('sftp_folder_visits:c2:/srv'), 1);
    expect(await store.readBool('sftpXfolderXvisits:c1:/srv'), isTrue,
        reason: 'a lookalike key is not a prefix match');

    // The pre-existing row survived the upgrade.
    final conn = await db
        .customSelect("SELECT id FROM connections WHERE id = 'conn-1'")
        .get();
    expect(conn, isNotEmpty);
  });

  test('a snapshot left in preferences by an older build is imported once',
      () async {
    const legacyTabs = '[]';
    SharedPreferences.setMockInitialValues({
      'persisted_tab_snapshots_v1': legacyTabs,
      'persisted_active_tab_index': 2,
      'persisted_sessions':
          '[{"connectionId":"c1","label":"nas","host":"","port":22,"username":""}]',
    });
    final prefs = await SharedPreferences.getInstance();
    final store = LocalStateStore(db);
    final service = SessionPersistenceService(prefs, store);

    expect(await service.hasSavedSessions(), isTrue);
    expect(prefs.getString('persisted_tab_snapshots_v1'), isNull,
        reason: 'the plaintext copy is gone after the import');
    expect(prefs.getInt('persisted_active_tab_index'), isNull);
    expect(prefs.getString('persisted_sessions'), isNull);
    expect(await store.read('persisted_tab_snapshots_v1'), legacyTabs);
    expect(await store.readInt('persisted_active_tab_index'), 2);

    final sessions = await service.loadSavedSessions();
    expect(sessions.single.connectionId, 'c1');
    expect(sessions.single.label, 'nas');

    await service.clearSavedSessions();
    expect(await service.hasSavedSessions(), isFalse);
    expect(await store.read('persisted_sessions'), isNull);
  });
}
