import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/backup_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

import '../helpers/memory_store_backend.dart';

/// A backup restore adds and writes over, and deletes nothing here (found in a data
/// review). It could not bring back a host or a key deleted
/// after it was made, which is what a restore is for: this device's tombstones
/// kept its records out, though the import said it restored them. And another
/// device's backup deleted the hosts here that that device had deleted once,
/// with nothing in the preview to say so, and left its tombstones to delete
/// them again at every pull.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const storage = FlutterSecureStorage();
  final mergeKey = List<int>.generate(32, (i) => i * 7 % 256);
  final t0 = DateTime.utc(2026, 10, 1, 9);
  late SettingsService settings;
  late AppDatabase db;
  late SyncDataService data;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    settings = SettingsService(await SharedPreferences.getInstance());
    db = AppDatabase.forTesting(NativeDatabase.memory());
    data = memoryDataService(db, storage, settings);
  });

  tearDown(() => db.close());

  /// [payload] as a .zest file without a password (format 2, read without key
  /// derivation); every format is restored the same way.
  Future<File> fileWith(Map<String, dynamic> payload) async {
    final dir = await Directory.systemTemp.createTemp('restore_deleted_');
    addTearDown(() => dir.delete(recursive: true));
    return File('${dir.path}/demo.zest')
      ..writeAsBytesSync([...utf8.encode('ZEST'), 2, ...utf8.encode(jsonEncode(payload))]);
  }

  Future<BackupResult> restore(Map<String, dynamic> payload, {void Function(RestorePreview)? shown}) async =>
      BackupService(data).importBackup((await fileWith(payload)).path, '', allowLegacyUnencrypted: true,
          confirm: (preview) async {
        shown?.call(preview);
        return const RestoreChoice();
      });

  Future<void> hostAndKey(AppDatabase into) async {
    await into.into(into.identities).insert(IdentitiesCompanion.insert(
        id: 'k-1', label: 'prod key', username: 'deploy', authMethod: 'publicKey', createdAt: t0, updatedAt: Value(t0)));
    await into.into(into.connections).insert(ConnectionsCompanion.insert(
        id: 'h-1', label: 'prod', host: 'prod.example.com', identityId: const Value('k-1'), createdAt: t0, updatedAt: t0));
  }

  test('a host and a key deleted after the backup come back when it is restored, and stay at the next sync', () async {
    await hostAndKey(db);
    await storage.write(key: 'identity_key_k-1', value: '-----BEGIN OPENSSH PRIVATE KEY----- made up');
    final backup = SyncDataService.withoutStoreCount(await data.gatherAll());

    // Deleted by mistake, as the app deletes them (each leaves a tombstone).
    await db.tombstonesDao.mark('connections', 'h-1');
    await db.connectionsDao.deleteConnection('h-1');
    await db.identitiesDao.deleteIdentity('k-1');
    await storage.delete(key: 'identity_key_k-1');
    // What this device sent to its other devices since: the deletes.
    final pushedAfterDelete = await data.gatherAll();

    RestorePreview? preview;
    final result = await restore(backup, shown: (p) => preview = p);
    expect(result.success, isTrue);
    expect((preview!.hosts, preview!.keys), (1, 1));
    expect(await db.connectionsDao.getById('h-1'), isNotNull, reason: 'the deleted host is not restored from the backup');
    expect(await db.identitiesDao.getById('k-1'), isNotNull, reason: 'the deleted key is not restored from the backup');
    expect(await storage.read(key: 'identity_key_k-1'), isNotNull);

    // The next pull brings the deletes back from the store (every device has
    // them): what the person restored stays.
    final pulled = await data.restoreAll(pushedAfterDelete..remove('connections')..remove('identities'),
        merge: SyncMergeBase(key: mergeKey, base: SyncDataService.itemHashes(await data.gatherAll(), mergeKey)));
    expect(pulled.success, isTrue);
    expect(await db.connectionsDao.getById('h-1'), isNotNull, reason: 'the deletion removed it again at the next sync');
    expect(await db.identitiesDao.getById('k-1'), isNotNull);

    // And another device that holds the deletes takes it back from this one's push.
    final other = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(other.close);
    await other.tombstonesDao.mark('connections', 'h-1', at: DateTime.now().toUtc().subtract(const Duration(minutes: 1)));
    await other.tombstonesDao.mark('identities', 'k-1', at: DateTime.now().toUtc().subtract(const Duration(minutes: 1)));
    final otherData = memoryDataService(other, storage, settings);
    expect((await otherData.restoreAll(await data.gatherAll())).success, isTrue);
    expect(await other.connectionsDao.getById('h-1'), isNotNull, reason: 'the other devices delete it again');
    expect(await other.identitiesDao.getById('k-1'), isNotNull);
  });

  test('another device\'s backup deletes nothing here, and leaves no tombstone to delete it at a later pull', () async {
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'h-here', label: 'kept here', host: 'here.example.com', createdAt: t0, updatedAt: t0));
    // A backup made on another device, which deleted that host there once.
    final backup = <String, dynamic>{
      'schema_version': 22,
      'connections': <Object>[],
      'tombstones': [
        {'entityType': 'connections', 'entityId': 'h-here', 'deletedAt': DateTime.utc(2026, 10, 5).toIso8601String()},
      ],
    };

    RestorePreview? preview;
    final result = await restore(backup, shown: (p) => preview = p);
    expect(result.success, isTrue);
    expect(preview!.replaces, 0);
    expect(await db.connectionsDao.getById('h-here'), isNotNull, reason: 'a restore deleted a host of this device');
    expect(await db.tombstonesDao.getAll(), isEmpty, reason: 'its tombstone stays here, and deletes the host at a pull');
  });

  test('a backup still writes its copy over the one here, as the preview says', () async {
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'h-1', label: 'renamed here', host: 'prod.example.com', createdAt: t0, updatedAt: t0));
    final other = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(other.close);
    await hostAndKey(other);
    final backup = await memoryDataService(other, storage, settings).gatherAll();

    RestorePreview? preview;
    expect((await restore(backup, shown: (p) => preview = p)).success, isTrue);
    expect(preview!.replaces, 1);
    expect((await db.connectionsDao.getById('h-1'))!.label, 'prod');
  });

  test('a pull still deletes what another device deleted', () async {
    await hostAndKey(db);
    final blob = await data.gatherAll()
      ..['connections'] = <Object>[]
      ..['tombstones'] = [
        {'entityType': 'connections', 'entityId': 'h-1', 'deletedAt': DateTime.utc(2026, 10, 5).toIso8601String()},
      ];
    expect((await data.restoreAll(blob)).success, isTrue);
    expect(await db.connectionsDao.getById('h-1'), isNull);
  });
}
