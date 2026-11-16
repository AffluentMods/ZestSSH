import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

/// Two devices that synced once, then each changed things on its own, merge
/// each other's data without an error, in both directions (a reported
/// bug: after both devices moved to 2.2.0 an Android device's
/// sync and "Restore from cloud" failed with a SQLite error until its data
/// was wiped).

late SettingsService _settings;

SyncDataService _service(AppDatabase db) => SyncDataService(
  database: db,
  connectionsDao: db.connectionsDao,
  identitiesDao: db.identitiesDao,
  groupsDao: db.connectionGroupsDao,
  knownHostsDao: db.knownHostsDao,
  snippetsDao: db.snippetsDao,
  snippetCategoriesDao: db.snippetCategoriesDao,
  portForwardRulesDao: db.portForwardRulesDao,
  networksDao: db.networksDao,
  connectionTagsDao: db.connectionTagsDao,
  secureStorage: const FlutterSecureStorage(),
  settingsService: _settings,
);

final _past = DateTime.utc(2026, 9, 1);

Future<void> _host(AppDatabase db, String id, {String? group, String? via}) =>
    db.connectionsDao.insertConnection(
      ConnectionsCompanion(
        id: Value(id),
        label: Value('host-$id'),
        host: Value('$id.example.com'),
        port: const Value(22),
        protocol: const Value('ssh'),
        groupId: Value(group),
        connectViaId: Value(via),
        createdAt: Value(_past),
        updatedAt: Value(_past),
      ),
    );

Future<void> _knownHost(AppDatabase db, String id, String host, {String device = 'W'}) => db
    .into(db.knownHosts)
    .insert(
      KnownHostsCompanion(
        id: Value(id),
        host: Value(host),
        port: const Value(22),
        keyType: const Value('ssh-ed25519'),
        fingerprint: const Value('SHA256:abc'),
        publicKeyBase64: const Value('AAAA'),
        firstSeen: Value(_past),
        lastSeen: Value(_past),
        recordedDevice: Value(device),
      ),
    );

Future<void> _seed(AppDatabase db) async {
  await db.connectionGroupsDao.insertGroup(
    ConnectionGroupsCompanion(
      id: const Value('g1'),
      name: const Value('Servers'),
      createdAt: Value(_past),
    ),
  );
  await _host(db, 'c1', group: 'g1');
  await _host(db, 'c2', via: 'c1');
  await db.connectionTagsDao.setTagsForConnection('c1', ['prod', 'eu']);
  await db.snippetCategoriesDao.upsert(const SnippetCategoriesCompanion(name: Value('Ops')));
  await db.snippetsDao.insertSnippet(
    SnippetsCompanion(
      id: const Value('s1'),
      label: const Value('uptime'),
      command: const Value('uptime'),
      category: const Value('Ops'),
      createdAt: Value(_past),
      updatedAt: Value(_past),
    ),
  );
  await db.networksDao.upsertNetwork(
    NetworksCompanion(
      id: const Value('n1'),
      name: const Value('Home'),
      triggersJson: const Value('[]'),
      iconCodePoint: const Value(0xe318),
      createdAt: Value(_past),
      updatedAt: Value(_past),
    ),
  );
  await _knownHost(db, 'kh1', 'c1.example.com');
}

/// Inserts a row into [table] with [values], filling every other NOT NULL
/// column that has no default from the live schema.
Future<void> _row(AppDatabase db, String table, Map<String, Object?> values) async {
  final columns = await db.customSelect('PRAGMA table_info($table)').get();
  final row = <String, Object?>{...values};
  for (final c in columns) {
    final name = c.read<String>('name');
    if (row.containsKey(name)) continue;
    final notNull = c.read<int>('notnull') == 1;
    final hasDefault = c.data['dflt_value'] != null;
    if (!notNull || hasDefault) continue;
    final type = c.read<String>('type').toUpperCase();
    row[name] = type.contains('INT')
        ? 1
        : type.contains('REAL')
        ? 1.5
        : 'x';
  }
  await db.customStatement(
    'INSERT INTO $table (${row.keys.map((k) => '"$k"').join(', ')}) '
    'VALUES (${List.filled(row.length, '?').join(', ')})',
    row.values.toList(),
  );
}

Future<void> _everyKind(AppDatabase db, String side) async {
  await _row(db, 'identities', {
    'id': 'i-$side',
    'label': 'key-$side',
    'username': 'root',
    'auth_method': 'password',
  });
  await _row(db, 'port_forward_rules', {
    'id': 'r-$side',
    'connection_id': 'c1',
    'type': 'local',
    'bind_port': 8080,
    'remote_host': 'localhost',
    'remote_port': 80,
  });
  await _row(db, 'port_forward_network_overrides', {
    'id': 'pfo-$side',
    'rule_id': 'r-shared',
    'network_id': 'n1',
    'state': 'on',
  });
  await _row(db, 'host_network_overrides', {
    'id': 'hno-$side',
    'connection_id': 'c1',
    'network_id': 'n1',
  });
  await _row(db, 'terminal_triggers', {
    'id': 't-$side',
    'name': 'trigger-$side',
    'pattern': 'error',
  });
  await _row(db, 'command_history', {'id': 'h-$side', 'command': 'ls -la', 'connection_id': 'c1'});
}

Future<void> _mergeOk(AppDatabase into, AppDatabase from) async {
  final data = await _service(from).gatherAll();
  final result = await _service(into).restoreAll(data);
  expect(result.error, isNull);
  expect(result.success, isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase windows;
  late AppDatabase android;

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    _settings = SettingsService(await SharedPreferences.getInstance());
    windows = AppDatabase.forTesting(NativeDatabase.memory());
    android = AppDatabase.forTesting(NativeDatabase.memory());
    await _seed(windows);
    await _mergeOk(android, windows); // the first sync
  });

  tearDown(() async {
    await windows.close();
    await android.close();
  });

  test('edits and new records on both sides merge both ways', () async {
    await windows.customStatement("UPDATE connections SET label = 'web-w' WHERE id = 'c1'");
    await android.customStatement("UPDATE connections SET label = 'jump-a' WHERE id = 'c2'");
    await _host(windows, 'c3');
    await _host(android, 'c4', group: 'g1');
    await windows.connectionTagsDao.setTagsForConnection('c1', ['prod']);
    await android.connectionTagsDao.setTagsForConnection('c1', ['prod', 'eu', 'db']);
    // The same host trusted on each device separately, under different ids.
    await _knownHost(windows, 'kh-w', 'db.example.com');
    await _knownHost(android, 'kh-a', 'db.example.com', device: 'A');
    // The same category made on both.
    await windows.snippetCategoriesDao.upsert(
      const SnippetCategoriesCompanion(name: Value('Deploy')),
    );
    await android.snippetCategoriesDao.upsert(
      const SnippetCategoriesCompanion(name: Value('Deploy')),
    );
    // A network with the same name made on both, under different ids.
    await windows.networksDao.upsertNetwork(
      NetworksCompanion(
        id: const Value('n-w'),
        name: const Value('Office'),
        triggersJson: const Value('[]'),
        iconCodePoint: const Value(0xe318),
        createdAt: Value(_past),
        updatedAt: Value(_past),
      ),
    );
    await android.networksDao.upsertNetwork(
      NetworksCompanion(
        id: const Value('n-a'),
        name: const Value('Office'),
        triggersJson: const Value('[]'),
        iconCodePoint: const Value(0xe318),
        createdAt: Value(_past),
        updatedAt: Value(_past),
      ),
    );

    await _mergeOk(android, windows);
    await _mergeOk(windows, android);
    await _mergeOk(android, windows);
  });

  test('a device holding the same known host twice still merges', () async {
    // SQLite lets two rows share host, port and key type when the route is
    // NULL (a direct connection): NULLs never collide in a UNIQUE key.
    await _knownHost(android, 'kh1-dup', 'c1.example.com', device: 'A');
    await _mergeOk(android, windows);
  });

  test('a blob holding the same known host twice merges', () async {
    await _knownHost(windows, 'kh1-dup', 'c1.example.com');
    final fresh = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(fresh.close);
    await _mergeOk(fresh, windows);
    await _mergeOk(android, windows);
  });
  test('every kind of record made on both sides merges both ways', () async {
    await _row(windows, 'port_forward_rules', {
      'id': 'r-shared',
      'connection_id': 'c1',
      'type': 'local',
      'bind_port': 9000,
      'remote_host': 'localhost',
      'remote_port': 90,
    });
    await _mergeOk(android, windows);
    await _everyKind(windows, 'w');
    await _everyKind(android, 'a');
    await _mergeOk(android, windows);
    await _mergeOk(windows, android);
    await _mergeOk(android, windows);
  });

  test('a delete on one side and an edit on the other merge both ways', () async {
    await windows.tombstonesDao.mark('connections', 'c2');
    await windows.customStatement("DELETE FROM connections WHERE id = 'c2'");
    await android.customStatement("UPDATE connections SET label = 'edited' WHERE id = 'c2'");
    await android.tombstonesDao.mark('snippets', 's1');
    await android.customStatement("DELETE FROM snippets WHERE id = 's1'");
    await windows.customStatement("UPDATE snippets SET label = 'edited' WHERE id = 's1'");
    await android.tombstonesDao.mark('connection_groups', 'g1');
    await android.customStatement("DELETE FROM connection_groups WHERE id = 'g1'");
    await _host(windows, 'c5', group: 'g1');
    await _mergeOk(android, windows);
    await _mergeOk(windows, android);
    await _mergeOk(android, windows);
  });

  // Found in a security review: a crafted backup
  // could add a second key type for a host this device trusts.
  test('a key type new to this device is not adopted for a host it confirmed under another type', () async {
    Future<List<String>> types(AppDatabase db) async =>
        [for (final r in await db.knownHostsDao.getAll()) if (r.host == 'c1.example.com') r.keyType]..sort();

    // Android has connected to c1 and matched its ed25519 key itself.
    await android.customStatement("UPDATE known_hosts SET locally_verified = 1 WHERE id = 'kh1'");
    await windows
        .into(windows.knownHosts)
        .insert(
          KnownHostsCompanion(
            id: const Value('kh1-ecdsa'),
            host: const Value('c1.example.com'),
            port: const Value(22),
            keyType: const Value('ecdsa-sha2-nistp256'),
            fingerprint: const Value('SHA256:other'),
            publicKeyBase64: const Value('AAAB'),
            firstSeen: Value(_past),
            lastSeen: Value(_past),
            recordedDevice: const Value('W'),
          ),
        );

    await _mergeOk(android, windows);
    expect(await types(android), ['ssh-ed25519']);

    // A device that confirmed nothing of the host takes every type, as before.
    final fresh = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(fresh.close);
    await _mergeOk(fresh, windows);
    expect(await types(fresh), ['ecdsa-sha2-nistp256', 'ssh-ed25519']);
  });

  test('a host trusted again through a jump host on one device still merges', () async {
    // The Android device reached c1 through a jump host, so the app moved its
    // copy of the synced trust record (same id) to that route, while Windows
    // still has it as a direct connection. Every merge on Android then failed
    // with "UNIQUE constraint failed: known_hosts.id".
    // (As an app before 3.3 did: it moved the row; 3.3 copies it.)
    await (android.update(android.knownHosts)..where((t) => t.id.equals('kh1')))
        .write(const KnownHostsCompanion(viaScope: Value('via:c2')));

    Future<List<String?>> routes(AppDatabase db) async => [
      for (final r in await db.knownHostsDao.getAll())
        if (r.host == 'c1.example.com') r.viaScope,
    ]..sort((a, b) => (a ?? '').compareTo(b ?? ''));

    for (var round = 0; round < 3; round++) {
      await _mergeOk(android, windows);
      await _mergeOk(windows, android);
    }
    // Both devices trust the host both ways, once each, however often they
    // sync.
    expect(await routes(android), [null, 'via:c2']);
    expect(await routes(windows), [null, 'via:c2']);
    expect(
      (await android.knownHostsDao.getById('kh1'))!.viaScope,
      'via:c2',
      reason: "this device's own record keeps its id and route",
    );
  });
}
