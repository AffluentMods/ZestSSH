import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v32 -> v33 upgrade path.
///
/// v33 adds the device-local folder-sync manifest table (spec §4). The
/// migration is purely additive: a single new table, no existing row touched.
/// This seeds a realistic v32 DB (with a connections row to prove integrity is
/// preserved) and asserts: (1) the new table exists, (2) it is usable through
/// its DAO, and (3) the pre-existing data survived the upgrade.

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
];

// The v32 known_hosts schema (post-viaScope), so a from=32 upgrade sees the
// table exactly as it stands at v32.
const _knownHostsV32 = '''
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

QueryExecutor _seededV32Executor() {
  return NativeDatabase.memory(setup: (rawDb) {
    for (final stmt in _stubTables) {
      rawDb.execute(stmt);
    }
    rawDb.execute(_knownHostsV32);
    rawDb.execute('CREATE INDEX idx_known_hosts_host ON known_hosts (host);');
    // A pre-existing row whose survival across the upgrade we assert.
    rawDb.execute("INSERT INTO connections (id) VALUES ('conn-1');");
    rawDb.execute('PRAGMA user_version = 32;');
  });
}

void main() {
  late AppDatabase db;

  setUp(() {
    // Opening forTesting at the current schema runs onUpgrade(32 -> 33) on the
    // first query below.
    db = AppDatabase.forTesting(_seededV32Executor());
  });
  tearDown(() async {
    await db.close();
  });

  test('v33 migration adds the sftp_sync_manifest table, usable, data intact',
      () async {
    expect(db.schemaVersion, greaterThanOrEqualTo(33));

    // (1) the new table exists.
    final info =
        await db.customSelect('PRAGMA table_info(sftp_sync_manifest)').get();
    expect(info, isNotEmpty,
        reason: 'sftp_sync_manifest must exist after the v33 migration');
    final cols = info.map((r) => r.read<String>('name')).toSet();
    expect(
      cols.containsAll(
          {'host_id', 'remote_root', 'rel_path', 'local_size', 'local_mtime_s', 'content_hash', 'uploaded_at'}),
      isTrue,
      reason: 'manifest columns present',
    );

    // (2) it is usable through the DAO (insert, upsert, read back).
    await db.sftpSyncManifestDao.record(
      hostId: 'h1',
      remoteRoot: '/var/www/html',
      relPath: 'css/app.css',
      size: 1234,
      mtimeSeconds: 1700000000,
      contentHash: 'deadbeef',
    );
    var byRoot = await db.sftpSyncManifestDao.forRoot('h1', '/var/www/html');
    expect(byRoot['css/app.css']?.localSize, 1234);
    expect(byRoot['css/app.css']?.contentHash, 'deadbeef');

    // Upsert on the natural key replaces, not duplicates.
    await db.sftpSyncManifestDao.record(
      hostId: 'h1',
      remoteRoot: '/var/www/html',
      relPath: 'css/app.css',
      size: 5678,
      mtimeSeconds: 1700000100,
    );
    byRoot = await db.sftpSyncManifestDao.forRoot('h1', '/var/www/html');
    expect(byRoot.length, 1);
    expect(byRoot['css/app.css']?.localSize, 5678);
    expect(byRoot['css/app.css']?.contentHash, isNull);

    // (3) the pre-existing connection row survived the upgrade.
    final conn = await db
        .customSelect("SELECT id FROM connections WHERE id = 'conn-1'")
        .get();
    expect(conn, isNotEmpty, reason: 'existing data must survive an additive migration');
  });
}
