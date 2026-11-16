import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

/// A host that is SFTP only rides the Tree's
/// sync as `sftp`, with no change to the blob: it comes back SFTP only on the
/// other device, and the round trip is stable. (A version from before it
/// falls back to ssh for a protocol it does not know, as it does for every
/// such value.)

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

  test('a host that is SFTP only goes out as sftp and comes back so; the round trip is stable', () async {
    for (final (id, protocol) in [('files-01', 'sftp'), ('db-primary', 'ssh')]) {
      await src.connectionsDao.insertConnection(ConnectionsCompanion(
        id: Value(id),
        label: Value(id),
        host: const Value('192.0.2.20'),
        port: const Value(22),
        protocol: Value(protocol),
        createdAt: Value(DateTime.utc(2026)),
        updatedAt: Value(DateTime.utc(2026)),
      ));
    }
    final s = await settings();
    final blob = await _service(src, storage, s).gatherAll();
    final sent = {for (final c in blob['connections'] as List) (c as Map)['id']: c['protocol']};
    expect(sent, {'files-01': 'sftp', 'db-primary': 'ssh'});

    final result = await _service(dst, storage, s).restoreAll(blob);
    expect(result.success, isTrue);
    final rows = {for (final c in await dst.connectionsDao.getAll()) c.id: c.protocol};
    expect(rows, {'files-01': 'sftp', 'db-primary': 'ssh'});

    final again = await _service(dst, storage, s).gatherAll();
    expect(SyncDataService.contentFingerprint(again, key), SyncDataService.contentFingerprint(blob, key));
  });

  group('a device on an older version turns a host that is SFTP only back into SSH', () {
    final at = DateTime.utc(2026, 10, 1, 12);
    final merge = SyncMergeBase(key: key);

    // What the other device sends: the host, as that device has it.
    Map<String, dynamic> sent(String protocol, DateTime time) => {
          'schema_version': 22,
          'connections': [
            {
              'id': 'files-01',
              'label': 'files-01',
              'host': '192.0.2.20',
              'port': 22,
              'protocol': protocol,
              'createdAt': at.millisecondsSinceEpoch,
              'updatedAt': time.millisecondsSinceEpoch,
            },
          ],
        };

    Future<void> hostHere(String protocol) => dst.connectionsDao.insertConnection(ConnectionsCompanion(
          id: const Value('files-01'),
          label: const Value('files-01'),
          host: const Value('192.0.2.20'),
          port: const Value(22),
          protocol: Value(protocol),
          createdAt: Value(at),
          updatedAt: Value(at),
        ));

    test('with the time of change it had: taken as any change, and noted on this device alone', () async {
      final s = await settings();
      await hostHere('sftp');
      expect((await _service(dst, storage, s).restoreAll(sent('ssh', at), merge: merge)).success, isTrue);
      expect((await dst.connectionsDao.getById('files-01'))!.protocol, 'ssh', reason: 'the merge is as it was');
      expect(s.sftpOnlyTurnedBack, ['files-01']);
      expect(s.exportSyncedSettings().keys, isNot(contains('sftp_only_turned_back')), reason: 'never synced');
    });

    test('with a later time it is a person\'s change, and nothing is noted', () async {
      final s = await settings();
      await hostHere('sftp');
      await _service(dst, storage, s).restoreAll(sent('ssh', at.add(const Duration(minutes: 5))), merge: merge);
      expect((await dst.connectionsDao.getById('files-01'))!.protocol, 'ssh');
      expect(s.sftpOnlyTurnedBack, isEmpty);
    });

    test('a restored backup says nothing of any device', () async {
      final s = await settings();
      await hostHere('sftp');
      await _service(dst, storage, s).restoreAll(sent('ssh', at), asBackup: true);
      expect(s.sftpOnlyTurnedBack, isEmpty);
    });

    test('once it comes back SFTP only, there is nothing to say any more', () async {
      final s = await settings();
      await hostHere('ssh');
      await s.noteSftpOnlyTurnedBack('files-01');
      await _service(dst, storage, s).restoreAll(sent('sftp', at.add(const Duration(minutes: 5))), merge: merge);
      expect((await dst.connectionsDao.getById('files-01'))!.protocol, 'sftp');
      expect(s.sftpOnlyTurnedBack, isEmpty);
    });

    test('the note holds the latest 200 hosts, each once', () async {
      final s = await settings();
      for (var i = 0; i < 205; i++) {
        await s.noteSftpOnlyTurnedBack('h$i');
      }
      await s.noteSftpOnlyTurnedBack('h204');
      expect(s.sftpOnlyTurnedBack.length, 200);
      expect(s.sftpOnlyTurnedBack.first, 'h5');
      expect(s.sftpOnlyTurnedBack.last, 'h204');
    });
  });

  test('a protocol no version knows still falls back to ssh', () async {
    final s = await settings();
    final result = await _service(dst, storage, s).restoreAll({
      'schema_version': 22,
      'connections': [
        {
          'id': 'ftp-01',
          'label': 'ftp-01',
          'host': '192.0.2.30',
          'port': 21,
          'protocol': 'ftp',
          'createdAt': 0,
          'updatedAt': 0,
        },
      ],
    });
    expect(result.success, isTrue);
    expect((await dst.connectionsDao.getById('ftp-01'))!.protocol, 'ssh');
  });
}
