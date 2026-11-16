import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

/// Remote screens (4.0, VNC hosts) ride the Tree's sync in a list of their
/// own, `screen_hosts`, beside `connections` and `ftps_hosts`: 3.4 does not
/// read it, so it never sees a screen (it would have read the unknown protocol
/// as SSH, to localhost:5900). A version with screens puts the lists together
/// as it restores; a push from 3.4, without the list, deletes nothing and asks
/// nothing; and a person with no screen keeps the fingerprint 3.4 gave them.

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

final _options = ScreenOptions.defaults
    .copyWith(target: ScreenTargetKind.unix, socket: '~/.vnc/zest.sock', scaling: ScreenScaling.oneToOne)
    .encode();

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

  Future<void> host(AppDatabase db, String id, String protocol, int port, {String? via, String? options}) =>
      db.connectionsDao.insertConnection(ConnectionsCompanion(
        id: Value(id),
        label: Value(id),
        host: Value(protocol == 'vnc' ? 'localhost' : '192.0.2.30'),
        port: Value(port),
        protocol: Value(protocol),
        connectViaId: Value(via),
        screenOptions: Value(options),
        createdAt: Value(DateTime.utc(2026)),
        updatedAt: Value(DateTime.utc(2026)),
      ));

  Future<void> hosts(AppDatabase db) async {
    await host(db, 'db-primary', 'ssh', 22);
    await host(db, 'nas-files', 'ftps', 21);
    await host(db, 'desk-screen', 'vnc', 5900, via: 'db-primary', options: _options);
  }

  Set<Object?> ids(Map<String, dynamic> blob, String list) => {for (final c in blob[list] as List) (c as Map)['id']};

  test('screens go out in screen_hosts, never in connections, and come back as they were', () async {
    await hosts(src);
    final s = await settings();
    final blob = await _service(src, storage, s).gatherAll();
    expect(ids(blob, 'connections'), {'db-primary'}, reason: 'a version before screens reads connections');
    expect(ids(blob, SyncDataService.ftpsHostsKey), {'nas-files'});
    expect(ids(blob, SyncDataService.screenHostsKey), {'desk-screen'});
    expect(SyncDataService.screenHostsKey, 'screen_hosts');
    final screen = (blob[SyncDataService.screenHostsKey] as List).single as Map;
    expect(screen['screenOptions'], _options);
    expect(screen['connectViaId'], 'db-primary', reason: 'its carrier');
    for (final c in [...blob['connections'] as List, ...blob[SyncDataService.ftpsHostsKey] as List]) {
      expect((c as Map).containsKey('screenOptions'), isFalse, reason: 'left out while null');
    }

    final result = await _service(dst, storage, s).restoreAll(blob);
    expect(result.success, isTrue);
    final rows = {for (final c in await dst.connectionsDao.getAll()) c.id: (c.protocol, c.port, c.connectViaId, c.screenOptions)};
    expect(rows, {
      'db-primary': ('ssh', 22, null, null),
      'nas-files': ('ftps', 21, null, null),
      'desk-screen': ('vnc', 5900, 'db-primary', _options),
    });

    final again = await _service(dst, storage, s).gatherAll();
    expect(SyncDataService.contentFingerprint(again, key), SyncDataService.contentFingerprint(blob, key),
        reason: 'a pull, restore and gather round trip pushes nothing');
  });

  test('a push from 3.4 (no screen_hosts) deletes no screen here, and the reconcile asks about none', () async {
    await hosts(dst);
    final s = await settings();
    final service = _service(dst, storage, s);
    final from34 = await service.gatherAll()
      ..remove(SyncDataService.screenHostsKey);
    expect((await service.assessStaleReconcile(from34)).hasLocalOnly, isFalse,
        reason: 'not in the store by its doing, not because it was deleted');
    final result = await service.restoreAll(from34);
    expect(result.success, isTrue);
    expect((await dst.connectionsDao.getAll()).map((c) => c.id).toSet(), {'db-primary', 'nas-files', 'desk-screen'});

    // A store a version with screens wrote, without this one: it is asked about.
    final fromOther = await service.gatherAll()
      ..[SyncDataService.screenHostsKey] = <Object?>[];
    final report = await service.assessStaleReconcile(fromOther);
    expect(report.localOnlyIds, {
      'connections': ['desk-screen'],
    });
  });

  test('the fingerprint: unchanged for a person with no screen, and a screen change counts', () async {
    await host(src, 'db-primary', 'ssh', 22);
    final s = await settings();
    final service = _service(src, storage, s);
    final blob = await service.gatherAll();
    expect(blob[SyncDataService.screenHostsKey], isEmpty);
    final as34 = {...blob}..remove(SyncDataService.screenHostsKey);
    expect(SyncDataService.contentFingerprint(blob, key), SyncDataService.contentFingerprint(as34, key),
        reason: 'the update alone pushes nothing');

    await host(src, 'desk-screen', 'vnc', 5900, via: 'db-primary', options: _options);
    final withScreen = SyncDataService.contentFingerprint(await service.gatherAll(), key);
    expect(withScreen, isNot(SyncDataService.contentFingerprint(blob, key)));
    await (src.update(src.connections)..where((t) => t.id.equals('desk-screen')))
        .write(ConnectionsCompanion(screenOptions: Value(ScreenOptions.defaults.copyWith(viewOnly: true).encode())));
    final changed = SyncDataService.contentFingerprint(await service.gatherAll(), key);
    expect(changed, isNot(withScreen), reason: "a change of a screen's options alone is pushed");
    // Each screen is an item of the merge base, as any host.
    expect(SyncDataService.itemHashes(await service.gatherAll(), key).keys, contains('connections/desk-screen'));
  });

  test("a screen found in connections (a damaged or made-up blob) is taken through the restore's checks", () async {
    final s = await settings();
    final rogue = await _service(src, storage, s).gatherAll();
    rogue['connections'] = [
      for (final (id, protocol, options) in [
        ('screen-in-connections', 'vnc', '{"scaling":"stretch","later":1}'),
        ('screen-bad-options', 'vnc', '[1,2,3]'),
        ('screen-huge-options', 'vnc', 'x' * 5000),
        ('ssh-with-options', 'ssh', _options),
        ('unknown-kind', 'spice', _options),
      ])
        {
          'id': id,
          'label': id,
          'host': 'localhost',
          'port': 5900,
          'protocol': protocol,
          'screenOptions': options,
          'createdAt': DateTime.utc(2026).toIso8601String(),
          'updatedAt': DateTime.utc(2026).toIso8601String(),
        },
    ];
    final result = await _service(dst, storage, s).restoreAll(rogue);
    expect(result.success, isTrue);
    final rows = {for (final c in await dst.connectionsDao.getAll()) c.id: (c.protocol, c.screenOptions)};
    expect(rows, {
      'screen-in-connections': ('vnc', '{"scaling":"stretch","later":1}'),
      'screen-bad-options': ('vnc', null),
      'screen-huge-options': ('vnc', null),
      'ssh-with-options': ('ssh', null),
      'unknown-kind': ('ssh', null),
    });
    // A value it holds that this version cannot use opens with the default.
    expect(ScreenOptions.decode(rows['screen-in-connections']!.$2).scaling, ScreenScaling.fit);
  });

  test('joining takes only screens from the list, each once, and the FTPS list with it', () {
    final joined = SyncDataService.withHostListsJoined({
      'connections': [
        {'id': 'a', 'protocol': 'ssh'},
      ],
      SyncDataService.ftpsHostsKey: [
        {'id': 'f', 'protocol': 'ftps'},
      ],
      SyncDataService.screenHostsKey: [
        {'id': 'v', 'protocol': 'vnc'},
        {'id': 'a', 'protocol': 'vnc'},
        {'id': 'x', 'protocol': 'ssh'},
        {'id': 'y', 'protocol': 'ftps'},
      ],
    });
    expect(joined.containsKey(SyncDataService.screenHostsKey), isFalse);
    expect(joined.containsKey(SyncDataService.ftpsHostsKey), isFalse);
    expect([for (final c in joined['connections'] as List) (c as Map)['id']], ['a', 'f', 'v']);
  });

  test('a backup carries screens apart too, and restores them whole', () async {
    await hosts(src);
    final s = await settings();
    final backup = SyncDataService.withoutStoreCount(await _service(src, storage, s).gatherAll());
    expect(ids(backup, SyncDataService.screenHostsKey), {'desk-screen'});
    expect(ids(backup, 'connections'), {'db-primary'});
    final result = await _service(dst, storage, s).restoreAll(backup, asBackup: true);
    expect(result.success, isTrue);
    final screen = await dst.connectionsDao.getById('desk-screen');
    expect(screen!.protocol, 'vnc');
    expect(screen.connectViaId, 'db-primary');
    expect(screen.screenOptions, _options);

    // A 3.4 restore of the same backup reads connections and ftps_hosts:
    // no screen comes in, and nothing else is lost.
    final as34 = {...backup}..remove(SyncDataService.screenHostsKey);
    final older = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(older.close);
    expect((await _service(older, storage, s).restoreAll(as34, asBackup: true)).success, isTrue);
    expect((await older.connectionsDao.getAll()).map((c) => c.id).toSet(), {'db-primary', 'nas-files'});
  });
}
