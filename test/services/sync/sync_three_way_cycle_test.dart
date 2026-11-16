// Real Argon2id key derivation (the weakest profile deriveKey accepts),
// done once for the file. Allow for a machine busy with the whole suite.
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/services/sync_service.dart';

import '../../helpers/memory_store_backend.dart';

/// A sync of this device, through the app's own cycle, while another device
/// syncs in between (3.0; checking the claim
/// "timestamps are compared and newest wins"). A change made here between
/// two syncs is kept, though the other device synced meanwhile, and sent;
/// the other device's change is taken; with nothing changed here nothing is
/// sent; and what this device last synced is kept for the next pull, and
/// forgotten when sync is taken apart. (A change made here was undone by the
/// next pull whenever another device had synced meanwhile.)
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const fast = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
  const storage = FlutterSecureStorage();

  late SettingsService settings;
  late AppDatabase deviceA;
  late AppDatabase deviceB;
  late MemoryStoreBackend backend;
  late AutoSyncService autoSyncA;
  late SecretKey dek;
  late SecretKey mek;
  late Uint8List salt;
  late Uint8List verHash;
  late int v1;

  setUpAll(() async {
    salt = SyncService.generateSalt();
    dek = SyncService.generateDek();
    mek = await SyncService.deriveKey('correct-password', salt, params: fast);
    verHash = await SyncService.computeVerificationHash(mek);
  });

  Future<void> host(AppDatabase db, String id, String label, DateTime at) =>
      db.into(db.connections).insertOnConflictUpdate(ConnectionsCompanion.insert(
          id: id, label: label, host: '$id.example.com', createdAt: DateTime.utc(2026, 10, 1), updatedAt: at));

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    settings = SettingsService(await SharedPreferences.getInstance());
    deviceA = AppDatabase.forTesting(NativeDatabase.memory());
    deviceB = AppDatabase.forTesting(NativeDatabase.memory());
    backend = MemoryStoreBackend(MemoryStore());
    autoSyncA = AutoSyncService(
      syncDataService: memoryDataService(deviceA, storage, settings),
      settingsService: settings,
      secureStorage: storage,
      resolveBackend: () => backend,
    );
    await storage.write(key: 'sync_salt', value: base64Encode(salt));
    await autoSyncA.storeSyncCredentials(dek, verHash, argon2Params: fast);

    // Both devices have the two hosts as the store has them, and A has
    // synced them.
    for (final db in [deviceA, deviceB]) {
      await host(db, 'h1', 'web-1', DateTime.utc(2026, 10, 1, 9));
      await host(db, 'h2', 'web-2', DateTime.utc(2026, 10, 1, 9));
    }
    v1 = (await backend.push(
      data: await memoryDataService(deviceA, storage, settings).gatherAll(),
      dek: dek,
      salt: salt,
      verificationHash: verHash,
      wrappedDekPassword: await SyncService.wrapDek(dek, mek),
      createOnly: true,
      argon2Params: fast,
    ))
        .version;
    await settings.setSyncServerVersion(v1);
    await settings.setLastSyncTime(DateTime.now());
  });

  tearDown(() async {
    autoSyncA.dispose();
    await deviceA.close();
    await deviceB.close();
  });

  Future<Map<String, dynamic>> store() async => SyncService.decrypt((await backend.pull()).encryptedData, dek);

  String? labelIn(Map<String, dynamic> data, String id) =>
      [for (final c in data['connections'] as List) if ((c as Map)['id'] == id) c['label'] as String?].singleOrNull;

  /// The other device changes [id] to [label] and sends what it holds.
  Future<void> otherDeviceChanges(String id, String label) async {
    await host(deviceB, id, label, DateTime.now().toUtc());
    await backend.push(
      data: await memoryDataService(deviceB, storage, settings).gatherAll(),
      dek: dek,
      salt: salt,
      verificationHash: verHash,
      expectedVersion: (await backend.getStatus()).version,
      argon2Params: fast,
    );
  }

  test('a change made here is kept though the other device synced meanwhile, and sent; the other device\'s is '
      'taken', () async {
    // A sync with nothing to do: what A holds is what it last synced.
    await autoSyncA.syncNowManual();
    expect(await memoryDataService(deviceA, storage, settings).loadSyncBase(), isNotNull);

    await host(deviceA, 'h1', 'web-1 renamed here', DateTime.now().toUtc());
    await settings.setSyncDirty(true);
    await otherDeviceChanges('h2', 'web-2 renamed there');

    await autoSyncA.syncNowManual();
    expect((await deviceA.connectionsDao.getById('h1'))!.label, 'web-1 renamed here');
    expect((await deviceA.connectionsDao.getById('h2'))!.label, 'web-2 renamed there');
    final now = await store();
    expect(labelIn(now, 'h1'), 'web-1 renamed here', reason: 'sent');
    expect(labelIn(now, 'h2'), 'web-2 renamed there');
    expect(await memoryDataService(deviceA, storage, settings).loadSyncBase(),
        SyncDataService.itemHashes(now, await dek.extractBytes()),
        reason: 'what was sent is what A last synced');
  });

  test('with no base yet, a host changed here later than there is kept and sent', () async {
    await host(deviceA, 'h1', 'web-1 renamed here', DateTime.now().toUtc().add(const Duration(minutes: 5)));
    await settings.setSyncDirty(true);
    await otherDeviceChanges('h1', 'web-1 renamed there');
    await autoSyncA.syncNowManual();
    expect((await deviceA.connectionsDao.getById('h1'))!.label, 'web-1 renamed here');
    expect(labelIn(await store(), 'h1'), 'web-1 renamed here');
  });

  test('nothing changed here, a sync by itself: the other device\'s change is taken, nothing is sent, and what was '
      'taken is what this device last synced', () async {
    await autoSyncA.syncNowManual();
    await otherDeviceChanges('h2', 'web-2 renamed there');
    final before = (await backend.getStatus()).version;
    await autoSyncA.triggerSync();
    expect((await deviceA.connectionsDao.getById('h2'))!.label, 'web-2 renamed there');
    expect((await backend.getStatus()).version, before, reason: 'nothing sent');
    expect(await memoryDataService(deviceA, storage, settings).loadSyncBase(),
        SyncDataService.itemHashes(await store(), await dek.extractBytes()));
  });

  test('what this device last synced decides, whatever the times say: changed here only, kept, though the other '
      'device wrote it again later unchanged', () async {
    await autoSyncA.syncNowManual();
    await host(deviceA, 'h1', 'web-1 renamed here', DateTime.utc(2026, 10, 1, 10));
    await settings.setSyncDirty(true);
    // The other device writes it again unchanged, later.
    await host(deviceB, 'h1', 'web-1', DateTime.now().toUtc());
    await otherDeviceChanges('h2', 'web-2 renamed there');
    await autoSyncA.syncNowManual();
    expect((await deviceA.connectionsDao.getById('h1'))!.label, 'web-1 renamed here');
    expect(labelIn(await store(), 'h1'), 'web-1 renamed here');
  });

  test('a change kept here is sent by a sync that runs by itself, though nothing marked this device as changed',
      () async {
    await autoSyncA.syncNowManual();
    await host(deviceA, 'h1', 'web-1 renamed here', DateTime.now().toUtc());
    await settings.setSyncDirty(false);
    await otherDeviceChanges('h2', 'web-2 renamed there');
    await autoSyncA.triggerSync();
    expect(settings.syncDirty, isFalse, reason: 'sent');
    expect(labelIn(await store(), 'h1'), 'web-1 renamed here');
    expect(labelIn(await store(), 'h2'), 'web-2 renamed there');
  });

  test('marked as changed with nothing changed: nothing is sent, and what this device holds is what it last '
      'synced', () async {
    await host(deviceA, 'h1', 'web-1 renamed here', DateTime.now().toUtc());
    await settings.setSyncDirty(true);
    await autoSyncA.syncNowManual();
    final sent = (await backend.getStatus()).version;
    final data = memoryDataService(deviceA, storage, settings);
    await data.saveSyncBase(const {'connections/h1': 'not what it is'});
    await settings.setSyncDirty(true);
    await autoSyncA.syncNowManual();
    expect((await backend.getStatus()).version, sent, reason: 'nothing sent');
    expect(await data.loadSyncBase(), SyncDataService.itemHashes(await data.gatherAll(), await dek.extractBytes()));
  });

  test('a device in step with the store, with nothing to send, keeps what it holds as what it last synced',
      () async {
    final data = memoryDataService(deviceA, storage, settings);
    expect(await data.loadSyncBase(), isNull);
    await autoSyncA.triggerSync();
    expect(await data.loadSyncBase(), SyncDataService.itemHashes(await data.gatherAll(), await dek.extractBytes()));
  });

  test('sync taken apart forgets what this device last synced', () async {
    await autoSyncA.syncNowManual();
    expect(await memoryDataService(deviceA, storage, settings).loadSyncBase(), isNotNull);
    await autoSyncA.clearSyncCredentials();
    expect(await memoryDataService(deviceA, storage, settings).loadSyncBase(), isNull);
  });
}
