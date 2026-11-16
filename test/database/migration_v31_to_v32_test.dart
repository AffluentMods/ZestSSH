import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v31 -> v32 upgrade path.
///
/// v32 re-scopes host-key trust by the jump route: it adds a nullable
/// `via_scope` column to `known_hosts` (NULL = direct connection, so every
/// pre-v32 pinned key keeps matching) and WIDENS the natural key from
/// {host, port, key_type} to {host, port, key_type, via_scope}. Because that
/// unique key is a table-level constraint SQLite can't ALTER, the migration
/// rebuilds `known_hosts` via drift's TableMigration. This test seeds a v31 DB
/// with a real known_hosts row and asserts: (1) the row survives with
/// via_scope = NULL; (2) the column exists; (3) two rows sharing host/port/
/// key_type but differing in via_scope can now coexist (the widened key); and
/// (4) idx_known_hosts_host is recreated after the rebuild.

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
];

// The REAL v31 known_hosts schema (pre-viaScope), so TableMigration has every
// column it needs to copy forward.
const _knownHostsV31 = '''
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
  PRIMARY KEY (id),
  UNIQUE (host, port, key_type)
);
''';

QueryExecutor _seededV31Executor() {
  return NativeDatabase.memory(setup: (rawDb) {
    for (final stmt in _stubTables) {
      rawDb.execute(stmt);
    }
    rawDb.execute(_knownHostsV31);
    rawDb.execute('CREATE INDEX idx_known_hosts_host ON known_hosts (host);');
    // A pre-existing trusted key (direct connection) whose survival we assert.
    rawDb.execute(
      "INSERT INTO known_hosts (id, host, port, key_type, fingerprint, "
      "public_key_base64, first_seen, last_seen, recorded_device, "
      "locally_verified) VALUES ('kh1', '192.168.10.30', 22, 'ssh-ed25519', "
      "'SHA256:aaa', 'AAAAC3', 1000, 2000, 'DESK', 1);",
    );
    rawDb.execute('PRAGMA user_version = 31;');
  });
}

void main() {
  late AppDatabase db;

  setUp(() {
    // Opening forTesting at the current schema runs onUpgrade(31 -> 32) on the
    // first query below.
    db = AppDatabase.forTesting(_seededV31Executor());
  });
  tearDown(() async {
    await db.close();
  });

  test('v32 migration adds via_scope, preserves the row, widens the key',
      () async {
    expect(db.schemaVersion, greaterThanOrEqualTo(32));

    // (1) the pre-existing row survives with via_scope = NULL (still matches
    // as a direct connection).
    final row = await db
        .customSelect("SELECT host, via_scope FROM known_hosts WHERE id = 'kh1'")
        .getSingle();
    expect(row.read<String>('host'), '192.168.10.30');
    expect(row.readNullable<String>('via_scope'), isNull);

    // (2) the column exists.
    final info = await db.customSelect('PRAGMA table_info(known_hosts)').get();
    expect(
      info.any((r) => r.read<String>('name') == 'via_scope'),
      isTrue,
      reason: 'via_scope column must exist post-migration',
    );

    // (3) the widened natural key lets the SAME host/port/key_type coexist
    // under a DIFFERENT route - the whole point of the fix. Pre-v32 this insert
    // would violate UNIQUE(host, port, key_type).
    await db.customStatement(
      "INSERT INTO known_hosts (id, host, port, key_type, fingerprint, "
      "public_key_base64, first_seen, last_seen, locally_verified, via_scope) "
      "VALUES ('kh2', '192.168.10.30', 22, 'ssh-ed25519', 'SHA256:bbb', "
      "'BBBB', 1000, 2000, 1, 'jump-b.example.com:22');",
    );
    final cnt = await db
        .customSelect(
            "SELECT COUNT(*) AS c FROM known_hosts WHERE host = '192.168.10.30'")
        .getSingle();
    expect(cnt.read<int>('c'), 2,
        reason: 'same endpoint via different routes must coexist');

    // (4) the index was recreated after the table rebuild.
    final idx = await db
        .customSelect(
            "SELECT name FROM sqlite_master WHERE type='index' "
            "AND name='idx_known_hosts_host'")
        .get();
    expect(idx, isNotEmpty, reason: 'idx_known_hosts_host must be recreated');
  });
}
