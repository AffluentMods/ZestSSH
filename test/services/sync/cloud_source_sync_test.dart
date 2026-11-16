import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

/// Cloud import (3.0): where a host was imported from rides the Tree's sync
/// (since blob 20), so another device sees "from AWS" and a later check of that
/// account finds the same host; a damaged link restores as none; the round
/// trip is stable (no push loop).

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

const _link = '{"v":1,"p":"hetzner","id":"42","l":"Hetzner CI","a":"203.0.113.8","n":"builder"}';

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

  Future<void> seed(AppDatabase db, String id, String? link) => db.connectionsDao.insertConnection(ConnectionsCompanion(
        id: Value(id),
        label: Value('host-$id'),
        host: Value('$id.example.com'),
        port: const Value(22),
        protocol: const Value('ssh'),
        cloudSource: Value(link),
        createdAt: Value(DateTime.utc(2026)),
        updatedAt: Value(DateTime.utc(2026)),
      ));

  test('the link goes out with the host and comes back on the other device; the round trip is stable', () async {
    await seed(src, 'c1', _link);
    await seed(src, 'c2', null);
    final s = await settings();
    final blob = await _service(src, storage, s).gatherAll();
    expect(blob['schema_version'], 22);
    final sent = {for (final c in blob['connections'] as List) (c as Map)['id']: c['cloudSource']};
    expect(sent, {'c1': _link, 'c2': null});

    final result = await _service(dst, storage, s).restoreAll(blob);
    expect(result.success, isTrue);
    final rows = {for (final c in await dst.connectionsDao.getAll()) c.id: c.cloudSource};
    expect(rows, {'c1': _link, 'c2': null});

    final again = await _service(dst, storage, s).gatherAll();
    expect(SyncDataService.contentFingerprint(again, key), SyncDataService.contentFingerprint(blob, key));
  });

  test('a link that is not one restores as none', () async {
    final s = await settings();
    final blob = {
      'schema_version': 20,
      'connections': [
        for (final (id, link) in [
          ('bad-json', 'nope'),
          ('bad-provider', '{"v":1,"p":"gcp","id":"x"}'),
          ('too-big', '{"v":1,"p":"aws","id":"${'x' * 5000}"}'),
          ('not-text', 42),
          ('good', _link),
        ])
          {
            'id': id,
            'label': id,
            'host': 'h.example.com',
            'port': 22,
            'protocol': 'ssh',
            'cloudSource': link,
            'createdAt': 0,
            'updatedAt': 0,
          },
      ],
    };
    final result = await _service(dst, storage, s).restoreAll(blob);
    expect(result.success, isTrue);
    final rows = {for (final c in await dst.connectionsDao.getAll()) c.id: c.cloudSource};
    expect(rows, {'bad-json': null, 'bad-provider': null, 'too-big': null, 'not-text': null, 'good': _link});
  });
}
