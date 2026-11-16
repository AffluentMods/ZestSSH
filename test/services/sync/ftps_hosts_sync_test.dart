import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

/// FTPS hosts (3.4) ride the Tree's sync in a list of their own, `ftps_hosts`,
/// which a version from before FTPS does not read: it never sees one (it read
/// an unknown protocol as SSH, and would have tried SSH on port 21). A version
/// with FTPS puts the two lists together as it restores; a push from an older
/// version, without the list, deletes nothing.

SyncDataService _service(AppDatabase db, FlutterSecureStorage storage, SettingsService s) => SyncDataService(
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
      secureStorage: storage,
      settingsService: s,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  const storage = FlutterSecureStorage();
  final key = List<int>.filled(32, 7);

  late AppDatabase src;
  late AppDatabase dst;

  setUp(() {
    src = AppDatabase.forTesting(NativeDatabase.memory());
    dst = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() async {
    await src.close();
    await dst.close();
  });

  Future<SettingsService> settings() async {
    SharedPreferences.setMockInitialValues(const {});
    return SettingsService(await SharedPreferences.getInstance());
  }

  Future<void> hosts(AppDatabase db) async {
    for (final (id, protocol, port) in [
      ('nas-files', 'ftps', 21),
      ('shop-files', 'ftpsImplicit', 990),
      ('db-primary', 'ssh', 22),
    ]) {
      await db.connectionsDao.insertConnection(ConnectionsCompanion(
        id: Value(id),
        label: Value(id),
        host: const Value('192.0.2.30'),
        port: Value(port),
        protocol: Value(protocol),
        createdAt: Value(DateTime.utc(2026)),
        updatedAt: Value(DateTime.utc(2026)),
      ));
    }
  }

  test('FTPS hosts go out in ftps_hosts, never in connections, and come back as they were', () async {
    await hosts(src);
    final s = await settings();
    final blob = await _service(src, storage, s).gatherAll();
    final inConnections = {for (final c in blob['connections'] as List) (c as Map)['id']};
    final inFtps = {for (final c in blob[SyncDataService.ftpsHostsKey] as List) (c as Map)['id']: c['protocol']};
    expect(inConnections, {'db-primary'}, reason: 'an older version reads connections alone');
    expect(inFtps, {'nas-files': 'ftps', 'shop-files': 'ftpsImplicit'});

    final result = await _service(dst, storage, s).restoreAll(blob);
    expect(result.success, isTrue);
    final rows = {for (final c in await dst.connectionsDao.getAll()) c.id: (c.protocol, c.port)};
    expect(rows, {'nas-files': ('ftps', 21), 'shop-files': ('ftpsImplicit', 990), 'db-primary': ('ssh', 22)});

    final again = await _service(dst, storage, s).gatherAll();
    expect(SyncDataService.contentFingerprint(again, key), SyncDataService.contentFingerprint(blob, key));
  });

  test('a push from an older version (no ftps_hosts) deletes no FTPS host here', () async {
    await hosts(dst);
    final s = await settings();
    final fromOld = await _service(dst, storage, s).gatherAll()
      ..remove(SyncDataService.ftpsHostsKey);
    final result = await _service(dst, storage, s).restoreAll(fromOld);
    expect(result.success, isTrue);
    expect((await dst.connectionsDao.getAll()).map((c) => c.id).toSet(), {'nas-files', 'shop-files', 'db-primary'});
  });

  test('the change of an FTPS host counts as a host change (it is in the fingerprint)', () async {
    await hosts(src);
    final s = await settings();
    final before = SyncDataService.contentFingerprint(await _service(src, storage, s).gatherAll(), key);
    await (src.update(src.connections)..where((t) => t.id.equals('nas-files'))).write(const ConnectionsCompanion(port: Value(2121)));
    final after = SyncDataService.contentFingerprint(await _service(src, storage, s).gatherAll(), key);
    expect(after, isNot(before));
  });

  test('joining puts FTPS hosts with the others, takes only FTPS ones from the list, and each once', () {
    final joined = SyncDataService.withFtpsHostsJoined({
      'connections': [
        {'id': 'a', 'protocol': 'ssh'},
      ],
      SyncDataService.ftpsHostsKey: [
        {'id': 'b', 'protocol': 'ftps'},
        {'id': 'a', 'protocol': 'ftps'},
        {'id': 'c', 'protocol': 'ssh'},
      ],
    });
    expect(joined.containsKey(SyncDataService.ftpsHostsKey), isFalse);
    expect([for (final c in joined['connections'] as List) (c as Map)['id']], ['a', 'b']);
  });
}
