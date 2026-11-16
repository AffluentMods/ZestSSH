import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:zestssh/database/database.dart';

/// Upgrading from the versions people have (3.0): ZestSSH 2.2.1 and 2.3.0
/// make schema v40, and every one of their databases goes through each step
/// from v40 to this version in one go when 3.0 first opens it.
///
/// Each step has its test, which starts one version below it with what that
/// test writes itself. This starts from the schema 2.3.0 itself makes
/// (test/database/fixtures/schema_v40_released.sql, read out of the 2.3.0
/// release), with something in every one of its tables,
/// and checks that what comes out is the schema a new install of this
/// version makes, table by table and column by column (a column an upgraded
/// database lacked would fail the first query that reads it, on every device
/// that upgraded and on none that installed anew), and that what was in it
/// is all there.
void main() {
  const t = 1790000000; // 21 September 2026, in seconds as drift keeps it.

  /// A database as 2.3.0 leaves it, with a row in each table.
  void released(File file) {
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute(File('test/database/fixtures/schema_v40_released.sql').readAsStringSync());
    void row(String table, List<Object?> values) =>
        raw.execute('INSERT INTO $table VALUES (${List.filled(values.length, '?').join(', ')})', values);
    row('connection_groups', ['g1', 'Lab', 0, 1, t, t, 3, null, null]);
    row('identities', [
      'i1', 'Alex key', 'alex', 'publicKey', 'ed25519', 'SHA256:demo-fingerprint', 'ssh-ed25519 AAAAdemo alex@example.com', //
      null, null, null, null, null, null, null, 0, 0, null, 1, 0, t, t,
    ]);
    row('identities', [
      'i2', 'Robin password', 'robin', 'password', null, null, null, //
      null, null, null, null, null, null, null, 0, 1, null, 0, 0, t, t,
    ]);
    row('connections', [
      'c1', 'web-01', '10.50.0.11', 22, 'i1', 'g1', 2, null, 'ssh', 0, null, null, null, 30, //
      null, '255.255.255.255', 9, '', 0, 0, 0, 1, null, null, 1, 'the web server', 1, null, '/var/www', 'alex', t, t, t, t,
    ]);
    row('connections', [
      'c2', 'db-01', '10.50.0.12', 2222, 'i2', null, 0, null, 'ssh', 1, 'uptime', null, 'c1', 0, //
      'AA:BB:CC:DD:EE:01', '192.0.2.255', 9, 'TERM=xterm-256color', 1, 1, 1, 2, 'postgres', null, 0, null, 0, null, null, null, null, null, t, t,
    ]);
    row('connection_tags', ['c1', 'prod', t]);
    row('connection_tags', ['c2', 'db', t]);
    row('known_hosts', ['k1', '10.50.0.11', 22, 'ssh-ed25519', 'SHA256:host-demo', 'AAAAC3NzaC1lZDI1NTE5demo', t, t, null, 1, null]);
    row('snippet_categories', ['Ops', 0, null, null, 0, t]);
    row('snippets', ['s1', 'Disk usage', 'df -h', 'Ops', 0, 0, null, 0, t, t]);
    row('networks', ['n1', 'Office', 0, null, 58136, 'MaterialIcons', null, '[]', 0, null, 0, t, t]);
    row('host_network_overrides', ['o1', 'c1', 'n1', '192.0.2.11', 22, null, null, null, null, 0, t, t]);
    row('port_forward_rules', ['r1', 'c2', 'local', '127.0.0.1', 15432, '127.0.0.1', 5432, 0, 1, 1, 0, null, 'db tunnel', null, t, t]);
    row('port_forward_network_overrides', ['po1', 'r1', 'n1', 'on', t, t]);
    row('workflows', ['w1', 'Restart web', 'restarts the web server', '[]', 1, 1, 0, t, null]);
    row('scheduled_tasks', ['st1', 'Nightly', 'execute', 'c1', 'uptime', null, null, 'daily', 60, 3, 0, null, 1, 'key-1', t, null, null]);
    row('terminal_triggers', ['tr1', 'Errors', 'ERROR', 0, 1, 1, null, 0, null, 1, 0, t, t]);
    row('command_history', ['h1', 'ls -la', 'c1', 'web-01', t, t, 0, 12, '/home/alex']);
    row('automation_history', ['a1', t, 'execute', 'c1', 'uptime', null, ' 10:00 up 3 days', '', 0, 1, 120]);
    row('monitor_samples', [1, 'c1', t, 1, 0, 12.5, 40.0, 0.0, 55.0, 0.5, 0.4, 0.3, null, 8]);
    row('sftp_sync_manifest', ['c1', '/srv', 'app/config.yml', 120, t, 'sha256:demo', t]);
    row('tombstones', ['connection', 'gone-1', t]);
    row('local_state', ['device_id', 'device-demo', t]);
    row('feedback_queue', ['nonce-1', '{}', t]);
    raw.execute('PRAGMA user_version = 40');
    raw.dispose();
  }

  /// Each table of [db] with its columns (name, type, not null, default,
  /// key), and the names of its indexes and triggers.
  Future<Map<String, Object>> shapeOf(AppDatabase db) async {
    final shape = <String, Object>{};
    final things = await db
        .customSelect("SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name")
        .get();
    for (final thing in things) {
      final type = thing.read<String>('type');
      final name = thing.read<String>('name');
      if (type != 'table') {
        shape['$type $name'] = type;
        continue;
      }
      final columns = await db.customSelect('PRAGMA table_info("$name")').get();
      shape['table $name'] = [
        for (final c in columns)
          '${c.read<String>('name')} ${c.read<String>('type')} notnull=${c.read<int>('notnull')} '
              'default=${c.readNullable<String>('dflt_value')} pk=${c.read<int>('pk')}',
      ]..sort();
    }
    return shape;
  }

  test('a database 2.2.1 and 2.3.0 made reaches this version whole: the schema of a new install, and all it held',
      () async {
    final dir = Directory.systemTemp.createTempSync('zest-upgrade-v40-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}zestssh.db');
    released(file);

    final upgraded = AppDatabase.forTesting(NativeDatabase(file));
    final fresh = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async {
      await upgraded.close();
      await fresh.close();
    });

    // Opening it runs every step from v40.
    final version = await upgraded.customSelect('PRAGMA user_version').getSingle();
    expect(version.data.values.single, upgraded.schemaVersion);
    expect(upgraded.schemaVersion, greaterThan(40));

    // The schema of a new install, table by table and column by column.
    final was = await shapeOf(upgraded);
    final anew = await shapeOf(fresh);
    expect(was.keys.toSet().difference(anew.keys.toSet()), isEmpty, reason: 'what an upgraded database has and a new one not');
    expect(anew.keys.toSet().difference(was.keys.toSet()), isEmpty, reason: 'what a new database has and an upgraded one not');
    for (final key in anew.keys) {
      expect(was[key], anew[key], reason: key);
    }

    // Everything that was in it.
    Future<List<String>> read(String sql) async => [
          for (final r in await upgraded.customSelect(sql).get()) r.data.values.map((v) => '$v').join('|'),
        ];
    expect(await read('SELECT id, label, host, port, identity_id, connect_via_id FROM connections ORDER BY id'),
        ['c1|web-01|10.50.0.11|22|i1|null', 'c2|db-01|10.50.0.12|2222|i2|c1']);
    expect(await read('SELECT id, auth_method, username FROM identities ORDER BY id'),
        ['i1|publicKey|alex', 'i2|password|robin']);
    expect(await read('SELECT connection_id, tag FROM connection_tags ORDER BY tag'), ['c2|db', 'c1|prod']);
    expect(await read('SELECT host, fingerprint FROM known_hosts'), ['10.50.0.11|SHA256:host-demo']);
    expect(await read('SELECT label, command, category FROM snippets'), ['Disk usage|df -h|Ops']);
    expect(await read('SELECT label, bind_port, remote_port FROM port_forward_rules'), ['db tunnel|15432|5432']);
    expect(await read('SELECT name FROM networks'), ['Office']);
    expect(await read('SELECT address FROM host_network_overrides'), ['192.0.2.11']);
    expect(await read('SELECT state FROM port_forward_network_overrides'), ['on']);
    expect(await read('SELECT name FROM workflows'), ['Restart web']);
    expect(await read('SELECT name, schedule_type FROM scheduled_tasks'), ['Nightly|daily']);
    expect(await read('SELECT name, pattern FROM terminal_triggers'), ['Errors|ERROR']);
    expect(await read('SELECT command, cwd FROM command_history'), ['ls -la|/home/alex']);
    expect(await read('SELECT command FROM automation_history'), ['uptime']);
    expect(await read('SELECT connection_id, cpu_percent FROM monitor_samples'), ['c1|12.5']);
    expect(await read('SELECT rel_path FROM sftp_sync_manifest'), ['app/config.yml']);
    expect(await read('SELECT entity_id FROM tombstones'), ['gone-1']);
    expect(await read("SELECT value FROM local_state WHERE key = 'device_id'"), ['device-demo']);
    expect(await read('SELECT nonce FROM feedback_queue'), ['nonce-1']);
    expect(await read('SELECT name FROM connection_groups'), ['Lab']);
    expect(await read('SELECT name FROM snippet_categories'), ['Ops']);
    // What the steps added: a key's password is never tried after it by
    // itself.
    expect(await read('SELECT id, password_after_key FROM identities ORDER BY id'), ['i1|0', 'i2|0']);

    // The app's own reads of it work.
    expect((await upgraded.select(upgraded.connections).get()).map((c) => c.label), ['web-01', 'db-01']);
    expect((await upgraded.select(upgraded.identities).get()).map((i) => i.label), ['Alex key', 'Robin password']);
    expect((await upgraded.select(upgraded.portForwardRules).get()).single.label, 'db tunnel');

    // Nothing in it is broken.
    expect(await read('PRAGMA integrity_check'), ['ok']);
    expect(await read('PRAGMA foreign_key_check'), isEmpty);
  });
}
