import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/features/feedback/feedback_service.dart';

/// Exercises the REAL schema v34 -> v35 upgrade path.
///
/// v35 adds `feedback_queue`, the device-local table that holds unsent in-app
/// reports (help/feedback/support spec 3b) so report text never rests in
/// plaintext preferences. Purely additive: a new table only, no existing row
/// touched. This seeds a realistic v34 DB (with a connections row to prove
/// integrity is preserved) and asserts the table exists, is usable through
/// FeedbackService, and the pre-existing data survived.

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
];

const _knownHostsV34 = '''
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

QueryExecutor _seededV34Executor() {
  return NativeDatabase.memory(setup: (rawDb) {
    for (final stmt in _stubTables) {
      rawDb.execute(stmt);
    }
    rawDb.execute(_knownHostsV34);
    rawDb.execute('CREATE INDEX idx_known_hosts_host ON known_hosts (host);');
    rawDb.execute("INSERT INTO connections (id) VALUES ('conn-1');");
    rawDb.execute('PRAGMA user_version = 34;');
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(_seededV34Executor());
  });
  tearDown(() async {
    await db.close();
  });

  test('v35 adds feedback_queue, usable through FeedbackService, data intact',
      () async {
    expect(db.schemaVersion, greaterThanOrEqualTo(35));

    final tables = (await db
            .customSelect(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='feedback_queue'")
            .get())
        .map((r) => r.read<String>('name'))
        .toList();
    expect(tables, ['feedback_queue']);

    final info =
        await db.customSelect('PRAGMA table_info(feedback_queue)').get();
    final cols = info.map((r) => r.read<String>('name')).toSet();
    expect(cols, {'nonce', 'payload', 'created_at'});

    // Usable: an offline send lands in the table, a later launch delivers it.
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    const ctx = FeedbackContext(
        appVersion: '1.9.7',
        build: 212,
        platform: 'linux',
        osVersion: 'Linux 6.8',
        locale: 'en-US',
        tier: 'free');
    final offline = FeedbackService(db, prefs, client: MockClient((_) async {
      throw http.ClientException('offline');
    }));
    final r = FeedbackReport(
        type: FeedbackType.bug, body: 'migrated queue', context: ctx);
    expect((await offline.send(r)).outcome, FeedbackOutcome.queued);
    final row = await db
        .customSelect('SELECT nonce, payload FROM feedback_queue')
        .getSingle();
    expect(row.read<String>('nonce'), r.nonce);
    expect(jsonDecode(row.read<String>('payload'))['body'], 'migrated queue');

    final online = FeedbackService(db, prefs,
        client: MockClient((_) async => http.Response('{"ok":true}', 200)));
    expect(await online.retryQueued(), 1);
    expect(await online.queued(), isEmpty);

    // The pre-existing row survived the upgrade.
    final conn = await db
        .customSelect("SELECT id FROM connections WHERE id = 'conn-1'")
        .get();
    expect(conn, isNotEmpty);
  });
}
