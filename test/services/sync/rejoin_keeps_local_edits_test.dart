// Real Argon2id key derivation (the weakest profile deriveKey accepts).
@Timeout(Duration(minutes: 2))
library;


import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync/join_with_handover.dart';
import 'package:zestssh/services/sync_service.dart';

import '../../helpers/memory_store_backend.dart';

/// Joining sync again (the sign-in after the person's own Sign out, a recovery
/// key, another device's approval) no longer writes the store's copy of every
/// item over this device's: a host edited here while sync was off went back to
/// the store's older copy, with nothing said, and the next push sent the old
/// copy everywhere (found in a data review). Every way of joining
/// restores without a merge base (restoreAll with no merge, which is now a merge
/// with none): the later change stands where its time can be trusted, the
/// store's copy otherwise, and what stayed here goes up at the next sync.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const fast = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
  const storage = FlutterSecureStorage();

  late SecretKey dek;
  late SecretKey mek;
  late Uint8List salt;
  late Uint8List verHash;
  late MemoryStore store;
  late SettingsService settings;
  late AppDatabase phone;
  late AutoSyncService autoSync;

  setUpAll(() async {
    salt = SyncService.generateSalt();
    dek = SyncService.generateDek();
    mek = await SyncService.deriveKey('correct-password', salt, params: fast);
    verHash = await SyncService.computeVerificationHash(mek);
  });

  Future<void> host(AppDatabase db, String id, String address, DateTime at) => db.into(db.connections).insertOnConflictUpdate(
      ConnectionsCompanion.insert(id: id, label: id, host: address, createdAt: DateTime.utc(2026, 9, 1), updatedAt: at));

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    settings = SettingsService(await SharedPreferences.getInstance());
    store = MemoryStore();

    // The account's store, as another device last pushed it.
    final other = AppDatabase.forTesting(NativeDatabase.memory());
    await host(other, 'h-1', 'old.example.com', DateTime.utc(2026, 10, 1));
    await host(other, 'h-2', 'moved-there.example.com', DateTime.utc(2026, 11, 3));
    await MemoryStoreBackend(store).push(
      data: await memoryDataService(other, storage, settings).gatherAll(),
      dek: dek,
      salt: salt,
      verificationHash: verHash,
      wrappedDekPassword: await SyncService.wrapDek(dek, mek),
      createOnly: true,
      argon2Params: fast,
    );
    await other.close();

    // This device, signed out: h-1 moved to its new address here after the
    // store's copy; h-2 as it was before the other device moved it.
    phone = AppDatabase.forTesting(NativeDatabase.memory());
    await host(phone, 'h-1', 'new.example.com', DateTime.utc(2026, 11, 2));
    await host(phone, 'h-2', 'before.example.com', DateTime.utc(2026, 10, 1));
    autoSync = AutoSyncService(
      syncDataService: memoryDataService(phone, storage, settings),
      settingsService: settings,
      secureStorage: storage,
      resolveBackend: () => MemoryStoreBackend(store),
    );
  });

  tearDown(() async {
    autoSync.dispose();
    await phone.close();
  });

  Future<String?> addressOf(AppDatabase db, String id) async => (await db.connectionsDao.getById(id))?.host;

  test('joining with the sync password keeps the later edit here, takes the later one there, and sends what it kept',
      () async {
    final joined = await joinWithPassword(
      backend: MemoryStoreBackend(store),
      password: 'correct-password',
      dataService: memoryDataService(phone, storage, settings),
      autoSync: autoSync,
      secureStorage: storage,
      settings: settings,
    );
    expect(joined.restore!.success, isTrue);
    expect(await addressOf(phone, 'h-1'), 'new.example.com',
        reason: 'the edit made here, later than the store\'s copy, was written over at the join');
    expect(await addressOf(phone, 'h-2'), 'moved-there.example.com');
    expect(joined.restore!.keptHere, 1);
    expect(settings.syncDirty, isTrue, reason: 'what was kept here waits to go up');

    // The next sync sends it to the store, where the other devices find it.
    await autoSync.triggerSync();
    final now = await SyncService.decrypt((await MemoryStoreBackend(store).pull()).encryptedData, dek);
    final addresses = {for (final c in now['connections'] as List) (c as Map)['id']: c['host']};
    expect(addresses, {'h-1': 'new.example.com', 'h-2': 'moved-there.example.com'});
  });

  test('every join path\'s restore (no merge given) keeps the later edit here; a backup still writes its copy', () async {
    final data = memoryDataService(phone, storage, settings);
    final storeData = await SyncService.decrypt((await MemoryStoreBackend(store).pull()).encryptedData, dek);

    final joined = await data.restoreAll(Map<String, dynamic>.from(storeData));
    expect(joined.success, isTrue);
    expect(await addressOf(phone, 'h-1'), 'new.example.com');
    expect(await addressOf(phone, 'h-2'), 'moved-there.example.com');

    final restored = await data.restoreAll(Map<String, dynamic>.from(storeData), asBackup: true);
    expect(restored.success, isTrue);
    expect(await addressOf(phone, 'h-1'), 'old.example.com', reason: 'a backup writes every item it holds');
  });
}
