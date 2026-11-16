import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

/// RDP hosts (4.0) ride personal sync in a list of their own,
/// `rdp_hosts`, beside `connections`, `ftps_hosts` and `screen_hosts`: a
/// version that has VNC and not RDP reads `screen_hosts` and never this one,
/// so it never sees an RDP host (it would have read the unknown protocol as
/// SSH, and offered the host's key to an SSH server at port 3389). The rules
/// are `screen_hosts`'s (screen_hosts_sync_test.dart), list for list.

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

final _rdpOptions = ScreenOptions.defaults.copyWith(nla: false, graphics: ScreenGraphics.remotefx).encode();
final _vncOptions = ScreenOptions.defaults.copyWith(scaling: ScreenScaling.oneToOne).encode();

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
        host: Value(via == null ? '192.0.2.30' : 'localhost'),
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
    await host(db, 'desk-screen', 'vnc', 5900, via: 'db-primary', options: _vncOptions);
    await host(db, 'office-pc', 'rdp', 3389, via: 'db-primary', options: _rdpOptions);
    await host(db, 'home-pc', 'rdp', 3389);
  }

  Set<Object?> ids(Map<String, dynamic> blob, String list) => {for (final c in blob[list] as List) (c as Map)['id']};

  test('RDP hosts go out in rdp_hosts, in no other list, and come back as they were', () async {
    await hosts(src);
    final s = await settings();
    final blob = await _service(src, storage, s).gatherAll();
    expect(SyncDataService.rdpHostsKey, 'rdp_hosts');
    expect(ids(blob, 'connections'), {'db-primary'}, reason: 'what every version reads');
    expect(ids(blob, SyncDataService.ftpsHostsKey), {'nas-files'});
    expect(ids(blob, SyncDataService.screenHostsKey), {'desk-screen'}, reason: 'what a version with VNC alone reads');
    expect(ids(blob, SyncDataService.rdpHostsKey), {'office-pc', 'home-pc'});
    final office = (blob[SyncDataService.rdpHostsKey] as List).firstWhere((c) => (c as Map)['id'] == 'office-pc') as Map;
    expect(office['screenOptions'], _rdpOptions);
    expect(office['connectViaId'], 'db-primary', reason: 'its carrier');

    final result = await _service(dst, storage, s).restoreAll(blob);
    expect(result.success, isTrue);
    final rows = {for (final c in await dst.connectionsDao.getAll()) c.id: (c.protocol, c.port, c.connectViaId, c.screenOptions)};
    expect(rows, {
      'db-primary': ('ssh', 22, null, null),
      'nas-files': ('ftps', 21, null, null),
      'desk-screen': ('vnc', 5900, 'db-primary', _vncOptions),
      'office-pc': ('rdp', 3389, 'db-primary', _rdpOptions),
      'home-pc': ('rdp', 3389, null, null),
    });

    final again = await _service(dst, storage, s).gatherAll();
    expect(SyncDataService.contentFingerprint(again, key), SyncDataService.contentFingerprint(blob, key),
        reason: 'a pull, restore and gather round trip pushes nothing');
  });

  test('a push from a version with VNC alone (no rdp_hosts) deletes no RDP host, and the reconcile asks about none',
      () async {
    await hosts(dst);
    final s = await settings();
    final service = _service(dst, storage, s);
    final fromVncOnly = await service.gatherAll()
      ..remove(SyncDataService.rdpHostsKey);
    expect((await service.assessStaleReconcile(fromVncOnly)).hasLocalOnly, isFalse,
        reason: 'not in the store by its doing, not because they were deleted');
    final result = await service.restoreAll(fromVncOnly);
    expect(result.success, isTrue);
    expect((await dst.connectionsDao.getAll()).map((c) => c.id).toSet(),
        {'db-primary', 'nas-files', 'desk-screen', 'office-pc', 'home-pc'});

    // A store a version with RDP wrote, without these: they are asked about,
    // and the VNC screen, which is in its own list, is not.
    final fromOther = await service.gatherAll()
      ..[SyncDataService.rdpHostsKey] = <Object?>[];
    final report = await service.assessStaleReconcile(fromOther);
    expect(report.localOnlyIds.keys, ['connections']);
    expect(report.localOnlyIds['connections']!.toSet(), {'office-pc', 'home-pc'});

    // And a store with RDP's list but not VNC's (it cannot be, but the two are
    // told apart): only the VNC screen is passed over.
    final noScreens = await service.gatherAll()
      ..remove(SyncDataService.screenHostsKey)
      ..[SyncDataService.rdpHostsKey] = <Object?>[];
    expect((await service.assessStaleReconcile(noScreens)).localOnlyIds['connections']!.toSet(), {'office-pc', 'home-pc'});
  });

  test('the fingerprint: unchanged for a person with no RDP host, and an RDP change counts', () async {
    await host(src, 'db-primary', 'ssh', 22);
    await host(src, 'desk-screen', 'vnc', 5900, via: 'db-primary', options: _vncOptions);
    final s = await settings();
    final service = _service(src, storage, s);
    final blob = await service.gatherAll();
    expect(blob[SyncDataService.rdpHostsKey], isEmpty);
    final asBefore = {...blob}..remove(SyncDataService.rdpHostsKey);
    expect(SyncDataService.contentFingerprint(blob, key), SyncDataService.contentFingerprint(asBefore, key),
        reason: 'the update alone pushes nothing');

    await host(src, 'office-pc', 'rdp', 3389, via: 'db-primary', options: _rdpOptions);
    final withRdp = SyncDataService.contentFingerprint(await service.gatherAll(), key);
    expect(withRdp, isNot(SyncDataService.contentFingerprint(blob, key)));
    await (src.update(src.connections)..where((t) => t.id.equals('office-pc')))
        .write(ConnectionsCompanion(screenOptions: Value(ScreenOptions.defaults.encode())));
    expect(SyncDataService.contentFingerprint(await service.gatherAll(), key), isNot(withRdp),
        reason: 'turning NLA back on alone is pushed');
    expect(SyncDataService.itemHashes(await service.gatherAll(), key).keys, contains('connections/office-pc'));
  });

  test('each list gives only its own kind: an RDP host in screen_hosts, or a VNC one in rdp_hosts, is not taken', () {
    Map<String, Object?> row(String id, String protocol) => {'id': id, 'protocol': protocol};
    final joined = SyncDataService.withHostListsJoined({
      'connections': [row('db-primary', 'ssh')],
      SyncDataService.screenHostsKey: [row('desk-screen', 'vnc'), row('rdp-in-screens', 'rdp'), row('ssh-in-screens', 'ssh')],
      SyncDataService.rdpHostsKey: [
        row('office-pc', 'rdp'),
        row('vnc-in-rdp', 'vnc'),
        row('ssh-in-rdp', 'ssh'),
        row('db-primary', 'rdp'),
      ],
    });
    expect([for (final c in joined['connections'] as List) ((c as Map)['id'], c['protocol'])], [
      ('db-primary', 'ssh'),
      ('desk-screen', 'vnc'),
      ('office-pc', 'rdp'),
    ], reason: 'a host in two lists is taken once, from connections');
  });

  test('an RDP host found in connections is restored as one, its options through the same checks as a screen',
      () async {
    final s = await settings();
    final rogue = await _service(src, storage, s).gatherAll();
    rogue['connections'] = [
      for (final (id, options) in [
        ('rdp-in-connections', '{"nla":false,"later":1}'),
        ('rdp-bad-options', '[1,2,3]'),
        ('rdp-huge-options', 'x' * 5000),
      ])
        {
          'id': id,
          'label': id,
          'host': 'localhost',
          'port': 3389,
          'protocol': 'rdp',
          'screenOptions': options,
          'createdAt': DateTime.utc(2026).toIso8601String(),
          'updatedAt': DateTime.utc(2026).toIso8601String(),
        },
    ];
    final result = await _service(dst, storage, s).restoreAll(rogue);
    expect(result.success, isTrue);
    final rows = {for (final c in await dst.connectionsDao.getAll()) c.id: (c.protocol, c.screenOptions)};
    expect(rows, {
      'rdp-in-connections': ('rdp', '{"nla":false,"later":1}'),
      'rdp-bad-options': ('rdp', null),
      'rdp-huge-options': ('rdp', null),
    });
    expect(ScreenOptions.decode(rows['rdp-in-connections']!.$2).nla, isFalse);
  });
}
