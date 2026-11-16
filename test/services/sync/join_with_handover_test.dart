// Real Argon2id key derivation (the weakest profile deriveKey accepts),
// done once for the file.
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/account/device_approvals.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync/join_with_handover.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/services/sync_service.dart';

import '../../helpers/memory_store_backend.dart';
import '../../helpers/recovery_proof_spy.dart';

/// A new device joins sync with the key another device of the account
/// handed over (3.0): the synced data opens and arrives, and
/// the device keeps exactly the key, the check and the salt it would have
/// after joining with the sync password. A key that does not open the data
/// leaves nothing behind.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const fast = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
  const storage = FlutterSecureStorage();

  late SecretKey dek;
  late SecretKey mek;
  late Uint8List salt;
  late Uint8List verHash;
  late MemoryStoreBackend backend;
  late SettingsService settings;
  late AppDatabase phone;
  late AutoSyncService autoSync;
  late int pushed;

  setUpAll(() async {
    salt = SyncService.generateSalt();
    dek = SyncService.generateDek();
    mek = await SyncService.deriveKey('correct-password', salt, params: fast);
    verHash = await SyncService.computeVerificationHash(mek);
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    // Sync was set to manual here once, with changes waiting: joining sets
    // it as joining with the password does.
    SharedPreferences.setMockInitialValues(const {'sync_mode': 'manual', 'sync_dirty': true});
    settings = SettingsService(await SharedPreferences.getInstance());
    backend = _CheckRecorded(MemoryStore());

    // The account's synced data, pushed by the desktop: two hosts.
    final desktop = AppDatabase.forTesting(NativeDatabase.memory());
    for (final id in ['h1', 'h2']) {
      await desktop.connectionsDao.insertConnection(ConnectionsCompanion(
        id: Value(id),
        label: Value('host-$id'),
        host: Value('$id.example.com'),
        port: const Value(22),
        protocol: const Value('ssh'),
        createdAt: Value(DateTime.utc(2026, 9, 25)),
        updatedAt: Value(DateTime.utc(2026, 9, 25)),
      ));
    }
    pushed = (await backend.push(
      data: await memoryDataService(desktop, storage, settings).gatherAll(),
      dek: dek,
      salt: salt,
      verificationHash: verHash,
      wrappedDekPassword: await SyncService.wrapDek(dek, mek),
      createOnly: true,
      argon2Params: fast,
    ))
        .version;
    await desktop.close();

    // The phone: nothing yet.
    phone = AppDatabase.forTesting(NativeDatabase.memory());
    autoSync = AutoSyncService(
      syncDataService: memoryDataService(phone, storage, settings),
      settingsService: settings,
      secureStorage: storage,
      resolveBackend: () => backend,
    );
  });

  tearDown(() async {
    autoSync.dispose();
    await phone.close();
  });

  Future<SyncHandover> handover({SecretKey? key}) async => SyncHandover(
        dek: Uint8List.fromList(await (key ?? dek).extractBytes()),
        verificationHash: verHash,
        // What the desktop remembered; the store's own params win.
        argon2Params: const {'memory': 131072, 'iterations': 3, 'parallelism': 4},
        salt: salt,
      );

  test('the key handed over opens the data, and the phone keeps what joining keeps', () async {
    final joined = await joinWithHandover(
      backend: backend,
      handover: await handover(),
      dataService: memoryDataService(phone, storage, settings),
      autoSync: autoSync,
      secureStorage: storage,
      settings: settings,
    );
    expect(joined.restore.success, isTrue);
    expect((await phone.connectionsDao.getAll()).map((c) => c.id).toSet(), {'h1', 'h2'});

    expect(await storage.read(key: 'sync_dek'), base64Encode(await dek.extractBytes()));
    expect(await storage.read(key: 'sync_verification_hash'), base64Encode(verHash));
    expect(await storage.read(key: 'sync_salt'), base64Encode(salt));
    expect(jsonDecode((await storage.read(key: 'sync_argon2_params'))!), containsPair('memory', 65536),
        reason: 'the params the key is wrapped under, from the store');
    expect(settings.syncServerVersion, pushed);
    expect(settings.syncMode, 'auto');
    expect(settings.syncDirty, isFalse);
    expect(settings.syncContentHash, isNotEmpty);

    // And this phone can now approve the next device with the same key:
    // what it would hand over is what it keeps.
    final container = ProviderContainer(overrides: [autoSyncServiceProvider.overrideWithValue(autoSync)]);
    addTearDown(container.dispose);
    final next = (await container.read(syncHandoverProvider)())!;
    expect(next.dek, await dek.extractBytes());
    expect(next.verificationHash, verHash);
    expect(next.salt, salt);
    expect(next.argon2Params, containsPair('memory', 65536));
  });

  test('a host only this device had waits to go up, as after joining with the password', () async {
    await phone.connectionsDao.insertConnection(ConnectionsCompanion(
      id: const Value('laptop'),
      label: const Value('laptop'),
      host: const Value('laptop.example.com'),
      port: const Value(22),
      protocol: const Value('ssh'),
      createdAt: Value(DateTime.utc(2026, 9, 25)),
      updatedAt: Value(DateTime.utc(2026, 9, 25)),
    ));
    await joinWithHandover(
      backend: backend,
      handover: await handover(),
      dataService: memoryDataService(phone, storage, settings),
      autoSync: autoSync,
      secureStorage: storage,
      settings: settings,
    );
    expect((await phone.connectionsDao.getAll()).map((c) => c.id).toSet(), {'h1', 'h2', 'laptop'});
    expect(settings.syncDirty, isTrue);
    final cloud = await backend.pull();
    expect(settings.syncContentHash,
        SyncDataService.contentFingerprint(await SyncService.decrypt(cloud.encryptedData, dek), await dek.extractBytes()),
        reason: "the cloud's fingerprint, so the next push is not taken for an echo");
  });

  test('with the encrypting lock on, the key handed over is kept sealed; sync runs with it and hands it on as it '
      'was (before, it lay in the storage as it was)', () async {
    await SecretSeal.setActive(phone, true);
    await joinWithHandover(
      backend: backend,
      handover: await handover(),
      dataService: memoryDataService(phone, storage, settings),
      autoSync: autoSync,
      secureStorage: storage,
      settings: settings,
    );
    final kept = (await storage.read(key: 'sync_dek'))!;
    expect(kept, startsWith(SecretSeal.prefix));
    expect(kept, isNot(contains(base64Encode(await dek.extractBytes()))));
    expect((await autoSync.readCredentials())!.dek, await dek.extractBytes());
    // The value that proves the sync password to the server is sealed too
    // (it was kept as it was), and read as it was.
    final check = (await storage.read(key: 'sync_verification_hash'))!;
    expect(check, startsWith(SecretSeal.prefix));
    expect(check, isNot(contains(base64Encode(verHash))));
    expect((await autoSync.readCredentials())!.verificationHash, verHash);

    // A host added here goes up with that key.
    await phone.connectionsDao.insertConnection(ConnectionsCompanion(
      id: const Value('laptop'),
      label: const Value('laptop'),
      host: const Value('laptop.example.com'),
      port: const Value(22),
      protocol: const Value('ssh'),
      createdAt: Value(DateTime.utc(2026, 9, 26)),
      updatedAt: Value(DateTime.utc(2026, 9, 26)),
    ));
    await settings.setSyncDirty(true);
    await autoSync.triggerSync();
    final cloud = await backend.pull();
    final data = await SyncService.decrypt(cloud.encryptedData, dek);
    expect(((data['connections'] as List).map((c) => (c as Map)['id'])).toSet(), {'h1', 'h2', 'laptop'});
    expect((backend as _CheckRecorded).checks.last, verHash, reason: 'the push carries the value opened, never the seal');
  });

  // joinWithPassword (the join of the old sync setup flow, removed in 3.4.2
  // as nothing opened it). It once marked sync as clean after joining, so a
  // device that already held hosts kept them to itself until its next edit.
  group('joining with the sync password', () {
    late RecoveryProofSpy proof;
    setUp(() => proof = RecoveryProofSpy());

    Future<({SyncPullResult pull, SyncRestoreResult? restore})> join(String password) => joinWithPassword(
          backend: backend,
          password: password,
          dataService: memoryDataService(phone, storage, settings),
          autoSync: autoSync,
          secureStorage: storage,
          settings: settings,
          recoveryProof: proof,
        );

    test("the password's key, proved, is the one the recovery proof is registered with", () async {
      final joined = await join('correct-password');
      expect(joined.restore?.success, isTrue);
      expect(proof.asked, hasLength(1));
      expect(await proof.asked.single.extractBytes(), await mek.extractBytes());
    });

    test('a host only this device had goes up with the first sync', () async {
      await phone.connectionsDao.insertConnection(ConnectionsCompanion(
        id: const Value('laptop'),
        label: const Value('laptop'),
        host: const Value('laptop.example.com'),
        port: const Value(22),
        protocol: const Value('ssh'),
        createdAt: Value(DateTime.utc(2026, 9, 25)),
        updatedAt: Value(DateTime.utc(2026, 9, 25)),
      ));
      final joined = await join('correct-password');
      expect(joined.restore?.success, isTrue);
      expect((await phone.connectionsDao.getAll()).map((c) => c.id).toSet(), {'h1', 'h2', 'laptop'});
      expect(settings.syncDirty, isTrue, reason: 'the merged data differs from the cloud, so changes wait');
      expect(settings.syncContentHash,
          SyncDataService.contentFingerprint(await SyncService.decrypt((await backend.pull()).encryptedData, dek),
              await dek.extractBytes()),
          reason: "the cloud's fingerprint, so the next push is not taken for an echo");

      await autoSync.triggerSync();
      final cloud = await SyncService.decrypt((await backend.pull()).encryptedData, dek);
      expect(((cloud['connections'] as List).map((c) => (c as Map)['id'])).toSet(), {'h1', 'h2', 'laptop'});
    });

    test('a fresh device keeps what joining keeps and stays clean', () async {
      final joined = await join('correct-password');
      expect(joined.restore?.success, isTrue);
      expect((await phone.connectionsDao.getAll()).map((c) => c.id).toSet(), {'h1', 'h2'});
      expect(await storage.read(key: 'sync_dek'), base64Encode(await dek.extractBytes()));
      expect(await storage.read(key: 'sync_verification_hash'), base64Encode(verHash));
      expect(await storage.read(key: 'sync_salt'), base64Encode(salt));
      expect(settings.syncServerVersion, pushed);
      expect(settings.syncMode, 'auto');
      expect(settings.syncDirty, isFalse);
    });

    test('a wrong password keeps nothing', () async {
      final joined = await join('wrong-password');
      expect(joined.restore, isNull);
      expect(proof.asked, isEmpty, reason: 'and registers nothing');
      expect(await phone.connectionsDao.getAll(), isEmpty);
      expect(await storage.read(key: 'sync_dek'), isNull);
      expect(await storage.read(key: 'sync_salt'), isNull);
      expect(settings.syncServerVersion, 0);
      expect(settings.syncMode, 'manual');
    });
  });

  test('a key that does not open the data leaves nothing behind', () async {
    await expectLater(
      joinWithHandover(
        backend: backend,
        handover: await handover(key: SyncService.generateDek()),
        dataService: memoryDataService(phone, storage, settings),
        autoSync: autoSync,
        secureStorage: storage,
        settings: settings,
      ),
      throwsA(isA<SyncDecryptionException>()),
    );
    expect(await phone.connectionsDao.getAll(), isEmpty);
    expect(await storage.read(key: 'sync_dek'), isNull);
    expect(await storage.read(key: 'sync_verification_hash'), isNull);
    expect(await storage.read(key: 'sync_salt'), isNull);
    expect(settings.syncServerVersion, 0);
    expect(await autoSync.readCredentials(), isNull);
  });
}

/// A store that remembers the verification value each push carried.
class _CheckRecorded extends MemoryStoreBackend {
  _CheckRecorded(super.store);

  final checks = <Uint8List>[];

  @override
  Future<({int version, int blobSize, DateTime? updatedAt})> push({
    required Map<String, dynamic> data,
    required SecretKey dek,
    required Uint8List salt,
    required Uint8List verificationHash,
    String? deviceId,
    Uint8List? wrappedDekPassword,
    Uint8List? wrappedDekRecovery,
    Uint8List? recoverySalt,
    Uint8List? recoveryHash,
    int? expectedVersion,
    bool createOnly = false,
    Map<String, dynamic>? argon2Params,
    Uint8List? authorizeHash,
    Uint8List? authorizeRecoveryHash,
  }) {
    checks.add(verificationHash);
    return super.push(
      data: data,
      dek: dek,
      salt: salt,
      verificationHash: verificationHash,
      deviceId: deviceId,
      wrappedDekPassword: wrappedDekPassword,
      wrappedDekRecovery: wrappedDekRecovery,
      recoverySalt: recoverySalt,
      recoveryHash: recoveryHash,
      expectedVersion: expectedVersion,
      createOnly: createOnly,
      argon2Params: argon2Params,
      authorizeHash: authorizeHash,
      authorizeRecoveryHash: authorizeRecoveryHash,
    );
  }
}
