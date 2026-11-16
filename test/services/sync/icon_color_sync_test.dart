import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/models/host_icon_color.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

/// What colours a host's icon (3.0) rides the Tree's sync (blob 21), so the
/// choice made on one device is the choice on the others; a value that no
/// colour can be restores as the icon's own; a blob from before the choice
/// existed restores every icon in its own colour; the round trip is stable
/// (no push loop).

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
  const green = 0xFF22C55E;

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

  Future<void> seed(AppDatabase db, String id, int? iconColor) => db.connectionsDao.insertConnection(ConnectionsCompanion(
        id: Value(id),
        label: Value('host-$id'),
        host: Value('$id.example.com'),
        port: const Value(22),
        protocol: const Value('ssh'),
        iconId: const Value('debian'),
        iconColor: Value(iconColor),
        createdAt: Value(DateTime.utc(2026)),
        updatedAt: Value(DateTime.utc(2026)),
      ));

  Map<String, Object?> hostJson(String id, {bool withChoice = true, Object? iconColor}) => {
        'id': id,
        'label': id,
        'host': 'h.example.com',
        'port': 22,
        'protocol': 'ssh',
        'iconId': 'debian',
        if (withChoice) 'iconColor': iconColor,
        'createdAt': 0,
        // Changed on the other device after the hosts here were (a join keeps a
        // later change made here).
        'updatedAt': DateTime.utc(2026, 6).millisecondsSinceEpoch ~/ 1000,
      };

  test('the choice goes out with the host and comes back on the other device; the round trip is stable', () async {
    await seed(src, 'own', null);
    await seed(src, 'follows', HostIconColor.followsLabel);
    await seed(src, 'custom', green);
    final s = await settings();
    final blob = await _service(src, storage, s).gatherAll();
    expect(blob['schema_version'], 22);
    final sent = {for (final c in blob['connections'] as List) (c as Map)['id']: c['iconColor']};
    expect(sent, {'own': null, 'follows': 0, 'custom': green});

    final result = await _service(dst, storage, s).restoreAll(blob);
    expect(result.success, isTrue);
    final rows = {for (final c in await dst.connectionsDao.getAll()) c.id: c.iconColor};
    expect(rows, {'own': null, 'follows': 0, 'custom': green});

    final again = await _service(dst, storage, s).gatherAll();
    expect(SyncDataService.contentFingerprint(again, key), SyncDataService.contentFingerprint(blob, key));
  });

  test('a choice made on the other device replaces the one here, also back to the icon\'s own', () async {
    await seed(dst, 'a', green);
    await seed(dst, 'b', HostIconColor.followsLabel);
    await seed(dst, 'c', null);
    final s = await settings();
    final result = await _service(dst, storage, s).restoreAll({
      'schema_version': 21,
      'connections': [
        hostJson('a', iconColor: null),
        hostJson('b', iconColor: green),
        hostJson('c', iconColor: 0),
      ],
    });
    expect(result.success, isTrue);
    final rows = {for (final c in await dst.connectionsDao.getAll()) c.id: c.iconColor};
    expect(rows, {'a': null, 'b': green, 'c': 0});
  });

  test('a value no colour can be restores as the icon\'s own, on a new host and on one that is here', () async {
    await seed(dst, 'here-text', green);
    await seed(dst, 'here-negative', green);
    await seed(dst, 'here-too-big', HostIconColor.followsLabel);
    final s = await settings();
    final result = await _service(dst, storage, s).restoreAll({
      'schema_version': 21,
      'connections': [
        for (final (id, value) in <(String, Object?)>[
          ('text', '4280468830'),
          ('negative', -5),
          ('too-big', 0x100000000),
          ('fraction', 1.5),
          ('a-list', [1]),
          ('here-text', 'green'),
          ('here-negative', -1),
          ('here-too-big', 0x1FFFFFFFF),
          ('largest', 0xFFFFFFFF),
          ('odd-but-a-number', 7),
        ])
          hostJson(id, iconColor: value),
      ],
    });
    expect(result.success, isTrue);
    final rows = {for (final c in await dst.connectionsDao.getAll()) c.id: c.iconColor};
    expect(rows, {
      'text': null,
      'negative': null,
      'too-big': null,
      'fraction': null,
      'a-list': null,
      'here-text': null,
      'here-negative': null,
      'here-too-big': null,
      'largest': 0xFFFFFFFF,
      'odd-but-a-number': 7,
    });
  });

  test('a blob from before the choice existed restores every icon in its own colour', () async {
    final s = await settings();
    final result = await _service(dst, storage, s).restoreAll({
      'schema_version': 20,
      'connections': [hostJson('old', withChoice: false)],
    });
    expect(result.success, isTrue);
    final old = (await dst.connectionsDao.getAll()).single;
    expect(old.iconId, 'debian');
    expect(old.iconColor, isNull);
  });

  test('this build refuses a blob newer than it knows, and takes nothing of it', () async {
    expect(SyncDataService.supportedSchemaVersion, 22);
    final s = await settings();
    final result = await _service(dst, storage, s).restoreAll({
      'schema_version': 23,
      'connections': [hostJson('new', iconColor: green)],
    });
    expect(result.success, isFalse);
    expect(await dst.connectionsDao.getAll(), isEmpty, reason: 'nothing of a newer blob is taken');
  });
}
