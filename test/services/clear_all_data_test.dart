// Real Argon2id key derivation (the weakest profile deriveKey accepts).
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
import 'package:zestssh/services/clear_all_data.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync/sync_disconnect.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/services/sync_setup_state_service.dart';

import '../helpers/memory_store_backend.dart';

/// Settings > Data > Clear all data says it deletes every host, key and password
/// for good. It deleted the rows only: the keys' private keys, passwords and
/// passphrases stayed in the system's secure storage, and with sync on nothing
/// told the other devices, so everything came back at the next sync (found in a data
/// review). It now clears what the keys hold, and with sync
/// set up here it clears this device only and turns sync off on it first: the
/// other devices and the synced data keep everything (sending the deletes would
/// have cleared every device of the account).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const fast = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
  const storage = FlutterSecureStorage();
  final t0 = DateTime.utc(2026, 10, 1, 9);

  late SettingsService settings;
  late AppDatabase db;
  late MemoryStore store;
  late AutoSyncService sync;
  late SecretKey dek;
  late SecretKey mek;
  late Uint8List salt;
  late Uint8List verHash;

  setUpAll(() async {
    salt = SyncService.generateSalt();
    dek = SyncService.generateDek();
    mek = await SyncService.deriveKey('correct-password', salt, params: fast);
    verHash = await SyncService.computeVerificationHash(mek);
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    settings = SettingsService(await SharedPreferences.getInstance());
    await settings.setSyncMode('auto');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = MemoryStore();
    sync = AutoSyncService(
      syncDataService: memoryDataService(db, storage, settings),
      settingsService: settings,
      secureStorage: storage,
      resolveBackend: () => MemoryStoreBackend(store),
    );
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: 'k-1', label: 'prod key', username: 'deploy', authMethod: 'publicKey', createdAt: t0, updatedAt: Value(t0)));
    await storage.write(key: 'identity_key_k-1', value: '-----BEGIN OPENSSH PRIVATE KEY----- made up');
    await storage.write(key: 'identity_passphrase_k-1', value: 'made-up passphrase');
    await storage.write(key: 'identity_password_k-1', value: 'made-up password');
    await storage.write(key: 'identity_cert_k-1', value: base64Encode(utf8.encode('made-up certificate')));
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'h-1', label: 'prod', host: 'prod.example.com', identityId: const Value('k-1'), createdAt: t0, updatedAt: t0));
  });

  tearDown(() async {
    sync.dispose();
    await db.close();
  });

  /// Sync set up here, the store holding this device's data (another device's too).
  Future<void> syncSetUp() async {
    await storage.write(key: 'sync_salt', value: base64Encode(salt));
    await sync.storeSyncCredentials(dek, verHash, argon2Params: fast);
    final pushed = await MemoryStoreBackend(store).push(
      data: await memoryDataService(db, storage, settings).gatherAll(),
      dek: dek,
      salt: salt,
      verificationHash: verHash,
      wrappedDekPassword: await SyncService.wrapDek(dek, mek),
      createOnly: true,
      argon2Params: fast,
    );
    await settings.setSyncServerVersion(pushed.version);
  }

  Future<void> turnSyncOff() => disconnectSyncOnThisDevice(
        autoSync: sync,
        setup: SyncSetupStateService(storage),
        settings: settings,
        secureStorage: storage,
        lockVault: () {},
      );

  Future<List<String>> keyEntries() async =>
      [for (final k in (await storage.readAll()).keys) if (k.startsWith('identity_')) k];

  test('the keys\' private keys, passwords, passphrases and certificates go with them', () async {
    await storage.write(key: 'some_other_entry', value: 'kept');
    var orchards = 0;
    await clearAllDataOnThisDevice(tree: db, secureStorage: storage, forgetOrchards: () async => orchards++);

    expect(await db.identitiesDao.getAll(), isEmpty);
    expect(await db.connectionsDao.getAll(), isEmpty);
    expect(await keyEntries(), isEmpty, reason: 'what the dialog says is deleted for good stayed in secure storage');
    expect(await storage.read(key: 'some_other_entry'), 'kept');
    expect(orchards, 1);
  });

  test('with sync on, this device is cleared and sync is turned off on it: nothing comes back, and the synced data '
      'and the other devices keep everything', () async {
    await syncSetUp();
    expect(await sync.setUpHere(), isTrue);
    final writes = store.counter;

    await clearAllDataOnThisDevice(
        tree: db, secureStorage: storage, forgetOrchards: () async {}, turnSyncOff: turnSyncOff);

    expect(await sync.setUpHere(), isFalse, reason: 'sync is still on here: the next sync brings it all back');
    // The next sync (a timer, a launch, Sync now): nothing comes back, and nothing is sent.
    await sync.triggerSync();
    expect(await db.connectionsDao.getAll(), isEmpty, reason: 'what was cleared came back from the synced data');
    expect(await db.identitiesDao.getAll(), isEmpty);
    expect(store.counter, writes, reason: 'an empty copy was sent up');
    // The synced data, which the person's other devices sync with, keeps everything.
    final kept = await SyncService.decrypt((await MemoryStoreBackend(store).pull()).encryptedData, dek);
    expect([for (final c in kept['connections'] as List) (c as Map)['id']], ['h-1']);
    expect((kept['secrets'] as Map).containsKey('k-1'), isTrue);
  });

  test('sync is turned off before anything is cleared, so no sync starts on what is being cleared', () async {
    await syncSetUp();
    int? hostsWhenSyncWentOff;
    await clearAllDataOnThisDevice(
      tree: db,
      secureStorage: storage,
      forgetOrchards: () async {},
      turnSyncOff: () async {
        hostsWhenSyncWentOff = (await db.connectionsDao.getAll()).length;
        await turnSyncOff();
      },
    );
    expect(hostsWhenSyncWentOff, 1);
  });
}
