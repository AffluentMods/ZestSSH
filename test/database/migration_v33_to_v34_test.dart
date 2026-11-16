import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v33 -> v34 upgrade path.
///
/// v34 adds the SFTP host default (remember-last-folder spec, section 2):
/// three nullable columns on `connections`: `last_remote_path`,
/// `last_remote_user`, `last_remote_path_at`. Purely additive: no existing
/// row touched. This seeds a realistic v33 DB (with a connections row to
/// prove integrity is preserved) and asserts the columns exist, are usable
/// through the DAO, and the pre-existing data survived.

const _stubTables = <String>[
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
  // v33 shape of the device-local folder-sync manifest.
  'CREATE TABLE sftp_sync_manifest (host_id TEXT NOT NULL, remote_root TEXT NOT NULL, rel_path TEXT NOT NULL, local_size INTEGER NOT NULL, local_mtime_s INTEGER NOT NULL, content_hash TEXT, uploaded_at INTEGER NOT NULL, PRIMARY KEY (host_id, remote_root, rel_path));',
];

const _knownHostsV33 = '''
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

QueryExecutor _seededV33Executor() {
  return NativeDatabase.memory(setup: (rawDb) {
    for (final stmt in _stubTables) {
      rawDb.execute(stmt);
    }
    rawDb.execute(_knownHostsV33);
    rawDb.execute('CREATE INDEX idx_known_hosts_host ON known_hosts (host);');
    rawDb.execute("INSERT INTO connections (id) VALUES ('conn-1');");
    rawDb.execute('PRAGMA user_version = 33;');
  });
}

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(_seededV33Executor());
  });
  tearDown(() async {
    await db.close();
  });

  test('v34 adds the last-remote-folder columns, usable, data intact',
      () async {
    expect(db.schemaVersion, greaterThanOrEqualTo(34));

    final info = await db.customSelect('PRAGMA table_info(connections)').get();
    final cols = info.map((r) => r.read<String>('name')).toSet();
    expect(
      cols.containsAll({'last_remote_path', 'last_remote_user', 'last_remote_path_at'}),
      isTrue,
      reason: 'host-default columns present: $cols',
    );

    // Usable through the DAO: set, read back, clear.
    await db.connectionsDao.setLastRemotePath('conn-1',
        path: '/srv/www/site', user: 'deploy');
    var row = await db
        .customSelect(
            "SELECT last_remote_path, last_remote_user, last_remote_path_at FROM connections WHERE id = 'conn-1'")
        .getSingle();
    expect(row.read<String?>('last_remote_path'), '/srv/www/site');
    expect(row.read<String?>('last_remote_user'), 'deploy');
    expect(row.read<int?>('last_remote_path_at'), isNotNull);

    await db.connectionsDao.clearLastRemotePath('conn-1');
    row = await db
        .customSelect(
            "SELECT last_remote_path, last_remote_user, last_remote_path_at FROM connections WHERE id = 'conn-1'")
        .getSingle();
    expect(row.read<String?>('last_remote_path'), isNull);
    expect(row.read<String?>('last_remote_user'), isNull);
    expect(row.read<int?>('last_remote_path_at'), isNull);

    // The pre-existing row survived the upgrade.
    final conn = await db
        .customSelect("SELECT id FROM connections WHERE id = 'conn-1'")
        .get();
    expect(conn, isNotEmpty);
  });
}
