// Real Argon2id key derivation (the weakest profile deriveKey accepts); allow
// for a machine busy with the whole suite.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/recovery_key_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync/recovery_key_replacement.dart';
import 'package:zestssh/services/sync/sync_manifest.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/services/sync_service.dart';

import '../../helpers/memory_store_backend.dart';

/// Replacing the vault's recovery key (3.0): the master password is
/// proved against the store as it is now, the new key opens the vault the
/// way a real restore does (under the account's own Argon2 parameters), the
/// old key stops working, and the new key rides a normal pull, merge and
/// push that always happens.

Future<void> _addHost(AppDatabase db, String id) =>
    db.connectionsDao.insertConnection(ConnectionsCompanion(
      id: Value(id),
      label: Value('host-$id'),
      host: Value('$id.example.com'),
      port: const Value(22),
      protocol: const Value('ssh'),
      createdAt: Value(DateTime.utc(2026, 9, 25)),
      updatedAt: Value(DateTime.utc(2026, 9, 25)),
    ));

Future<Set<String>> _storeHostIds(MemoryStoreBackend backend, SecretKey dek) async {
  final pulled = await backend.pull();
  final data = await SyncService.decrypt(pulled.encryptedData, dek);
  return (data['connections'] as List).map((c) => (c as Map)['id'] as String).toSet();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  // The account's own parameters: the weakest profile deriveKey accepts,
  // which is not this build's default. A recovery key derived under the
  // default would not open this account's vault.
  const accountParams = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
  const storage = FlutterSecureStorage();
  const password = 'correct horse battery staple';
  const oldRecoveryKey = 'ZEST-AAAA-BBBB-CCCC-DDDD-EEEE';

  late Uint8List salt;
  late SecretKey dek;
  late SecretKey mek;
  late Uint8List verHash;
  late Uint8List oldRecoverySalt;
  late Uint8List oldWrappedRecovery;
  late Uint8List oldRecoveryHash;

  setUpAll(() async {
    salt = SyncService.generateSalt();
    dek = SyncService.generateDek();
    mek = await SyncService.deriveKey(password, salt, params: accountParams);
    verHash = await SyncService.computeVerificationHash(mek);
    oldRecoverySalt = RecoveryKeyService.generateRecoverySalt();
    final oldKek = await SyncService.deriveKey(
        RecoveryKeyService.normalize(oldRecoveryKey), oldRecoverySalt,
        params: accountParams);
    oldWrappedRecovery = await SyncService.wrapDek(dek, oldKek);
    oldRecoveryHash = await SyncService.computeRecoveryVerificationHash(oldKek);
  });

  late SettingsService settings;
  late AppDatabase device;
  late MemoryStoreBackend backend;
  late AutoSyncService autoSync;

  /// The store as setup leaves it, optionally with a recovery key.
  Future<void> setUpStore({bool withRecovery = true}) async {
    await _addHost(device, 'a1');
    final v1 = await backend.push(
      data: await memoryDataService(device, storage, settings).gatherAll(),
      dek: dek,
      salt: salt,
      verificationHash: verHash,
      wrappedDekPassword: await SyncService.wrapDek(dek, mek),
      wrappedDekRecovery: withRecovery ? oldWrappedRecovery : null,
      recoverySalt: withRecovery ? oldRecoverySalt : null,
      recoveryHash: withRecovery ? oldRecoveryHash : null,
      createOnly: true,
      argon2Params: accountParams,
    );
    await settings.setSyncServerVersion(v1.version);
    await settings.setSyncContentHash(SyncDataService.contentFingerprint(
        await memoryDataService(device, storage, settings).gatherAll(), await dek.extractBytes()));
    await settings.setLastSyncTime(DateTime.now());
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    settings = SettingsService(await SharedPreferences.getInstance());
    device = AppDatabase.forTesting(NativeDatabase.memory());
    backend = MemoryStoreBackend(MemoryStore());
    autoSync = AutoSyncService(
      syncDataService: memoryDataService(device, storage, settings),
      settingsService: settings,
      secureStorage: storage,
      resolveBackend: () => backend,
    );
    await storage.write(key: 'sync_salt', value: base64Encode(salt));
    await autoSync.storeSyncCredentials(dek, verHash, argon2Params: accountParams);
  });

  tearDown(() async {
    autoSync.dispose();
    await device.close();
  });

  group('proving the master password', () {
    test('the right password proves the vault as the store holds it', () async {
      await setUpStore();
      final vault = await proveMasterPassword(backend, password,
          deviceDek: await dek.extractBytes());
      expect(await vault.dek.extractBytes(), await dek.extractBytes());
      expect(vault.salt, salt);
      expect(vault.verificationHash, verHash);
      expect(vault.argon2Params, accountParams);
      expect(vault.hadRecovery, isTrue);
    });

    test('a wrong password is refused', () async {
      await setUpStore();
      await expectLater(
        proveMasterPassword(backend, 'not the password', deviceDek: await dek.extractBytes()),
        throwsA(isA<VaultProofException>()
            .having((e) => e.failure, 'failure', VaultProofFailure.wrongPassword)),
      );
    });

    test('a vault with a different data key than this device is refused', () async {
      await setUpStore();
      final other = await SyncService.generateDek().extractBytes();
      await expectLater(
        proveMasterPassword(backend, password, deviceDek: other),
        throwsA(isA<VaultProofException>()
            .having((e) => e.failure, 'failure', VaultProofFailure.otherKey)),
      );
    });

    test('after a password change on another device, only the new password proves it', () async {
      await setUpStore();
      // Another device changes the password: new salt, same data key.
      final newSalt = SyncService.generateSalt();
      final newMek = await SyncService.deriveKey('the new password', newSalt, params: accountParams);
      await backend.push(
        data: await memoryDataService(device, storage, settings).gatherAll(),
        dek: dek,
        salt: newSalt,
        verificationHash: await SyncService.computeVerificationHash(newMek),
        wrappedDekPassword: await SyncService.wrapDek(dek, newMek),
        argon2Params: accountParams,
      );
      final deviceDek = await dek.extractBytes();
      await expectLater(
        proveMasterPassword(backend, password, deviceDek: deviceDek),
        throwsA(isA<VaultProofException>()
            .having((e) => e.failure, 'failure', VaultProofFailure.wrongPassword)),
        reason: 'the old password no longer opens the vault',
      );
      final vault = await proveMasterPassword(backend, 'the new password', deviceDek: deviceDek);
      expect(vault.salt, newSalt, reason: 'the store salt, not the one this device held');
    });

    test('a store without a password-wrapped key is not proved', () async {
      await backend.writeObject(
        (await _manifestWithoutWrappedKey(dek, salt, verHash, accountParams)),
        ifAbsent: true,
      );
      await expectLater(
        proveMasterPassword(backend, password, deviceDek: await dek.extractBytes()),
        throwsA(isA<VaultProofException>()
            .having((e) => e.failure, 'failure', VaultProofFailure.notSetUp)),
      );
    });
  });

  group('replacing the key', () {
    test('the new key opens the vault the way a restore does, and the old one stops', () async {
      await setUpStore();
      final vault = await proveMasterPassword(backend, password,
          deviceDek: await dek.extractBytes());
      final newKey = RecoveryKeyService.generateRecoveryKey();
      final wrap = await wrapForRecovery(vault, newKey);
      await autoSync.replaceRecoveryKey(
          wrappedDek: wrap.wrappedDek, salt: wrap.salt, hash: wrap.hash);

      final restored = await backend.pullWithRecoveryKey(newKey);
      expect(await restored.dek.extractBytes(), await dek.extractBytes());
      // The value the hosted server checks a restore and its new password
      // against belongs to the new key.
      expect(SyncManifest.fromBytes(backend.store.bytes!).recoveryHash,
          await SyncService.computeRecoveryVerificationHash(restored.recoveryKek));
      await expectLater(backend.pullWithRecoveryKey(oldRecoveryKey), throwsA(isA<SyncException>()));
      // The password still opens it, as before.
      final again = await proveMasterPassword(backend, password, deviceDek: await dek.extractBytes());
      expect(again.salt, salt);
      expect(settings.syncRecoveryKeySet, isTrue);
    });

    test('the key goes up whole, and the password material is untouched', () async {
      await setUpStore();
      final vault = await proveMasterPassword(backend, password, deviceDek: await dek.extractBytes());
      final wrap = await wrapForRecovery(vault, RecoveryKeyService.generateRecoveryKey());
      await autoSync.replaceRecoveryKey(
          wrappedDek: wrap.wrappedDek, salt: wrap.salt, hash: wrap.hash);
      final stored = SyncManifest.fromBytes(backend.store.bytes!);
      expect(stored.wrappedDekRecovery, wrap.wrappedDek);
      expect(stored.recoverySalt, wrap.salt);
      expect(stored.recoveryHash, wrap.hash);
      expect(stored.salt, salt);
      expect(stored.passwordHash, verHash);
      expect(stored.argon2Params, accountParams);
    });

    test('it pushes even when nothing else changed', () async {
      await setUpStore();
      expect(settings.syncDirty, isFalse);
      final before = (await backend.getStatus()).version;
      final vault = await proveMasterPassword(backend, password, deviceDek: await dek.extractBytes());
      final wrap = await wrapForRecovery(vault, RecoveryKeyService.generateRecoveryKey());
      await autoSync.replaceRecoveryKey(
          wrappedDek: wrap.wrappedDek, salt: wrap.salt, hash: wrap.hash);
      expect((await backend.getStatus()).version, before + 1);
    });

    test('another device\'s newer push is merged before the key goes up', () async {
      await setUpStore();
      // Another device adds b1 and pushes; this device has not pulled it.
      final other = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(other.close);
      await _addHost(other, 'a1');
      await _addHost(other, 'b1');
      await backend.push(
        data: await memoryDataService(other, storage, settings).gatherAll(),
        dek: dek,
        salt: salt,
        verificationHash: verHash,
        expectedVersion: settings.syncServerVersion,
        argon2Params: accountParams,
      );
      await _addHost(device, 'a2');

      final vault = await proveMasterPassword(backend, password, deviceDek: await dek.extractBytes());
      final newKey = RecoveryKeyService.generateRecoveryKey();
      final wrap = await wrapForRecovery(vault, newKey);
      await autoSync.replaceRecoveryKey(
          wrappedDek: wrap.wrappedDek, salt: wrap.salt, hash: wrap.hash);

      expect(await _storeHostIds(backend, dek), {'a1', 'a2', 'b1'});
      final restored = await backend.pullWithRecoveryKey(newKey);
      expect(await restored.dek.extractBytes(), await dek.extractBytes());
    });

    test('a key can be made where there was none', () async {
      await setUpStore(withRecovery: false);
      expect((await backend.getStatus()).hasRecovery, isFalse);
      final vault = await proveMasterPassword(backend, password, deviceDek: await dek.extractBytes());
      expect(vault.hadRecovery, isFalse);
      final newKey = RecoveryKeyService.generateRecoveryKey();
      final wrap = await wrapForRecovery(vault, newKey);
      await autoSync.replaceRecoveryKey(
          wrappedDek: wrap.wrappedDek, salt: wrap.salt, hash: wrap.hash);
      expect((await backend.getStatus()).hasRecovery, isTrue);
      expect(settings.syncRecoveryKeySet, isTrue, reason: 'the device knows at once, before any other check');
      final restored = await backend.pullWithRecoveryKey(newKey);
      expect(await restored.dek.extractBytes(), await dek.extractBytes());
    });

    test('an emptied store is not given a key', () async {
      final wrap = RecoveryWrap(
        wrappedDek: Uint8List(60),
        salt: Uint8List(32),
        hash: Uint8List(32),
      );
      // Refused before anything is sent: the store's own "missing" answer
      // would come from a push.
      await expectLater(
        autoSync.replaceRecoveryKey(wrappedDek: wrap.wrappedDek, salt: wrap.salt, hash: wrap.hash),
        throwsA(isA<SyncSetupRequiredException>()
            .having((e) => e.message, 'message', gl10n.syncNowNotSetUp)),
      );
      expect(backend.store.bytes, isNull, reason: 'nothing was written');
    });
  });

  group('what the device knows about the key', () {
    test('a sync cycle notes whether the store holds one, and forgetting sync forgets it', () async {
      await setUpStore();
      expect(settings.syncRecoveryKeySet, isNull);
      expect(await autoSync.recoveryKeyStatus(refresh: true), isTrue);
      expect(settings.syncRecoveryKeySet, isTrue);
      await autoSync.clearSyncCredentials();
      expect(settings.syncRecoveryKeySet, isNull);
    });

    test('what the device saw is updated when the store changes', () async {
      await setUpStore(withRecovery: false);
      expect(await autoSync.recoveryKeyStatus(refresh: true), isFalse);
      // Another device makes one.
      final pulled = await backend.pull();
      await backend.push(
        data: await memoryDataService(device, storage, settings).gatherAll(),
        dek: dek,
        salt: salt,
        verificationHash: verHash,
        expectedVersion: pulled.version,
        wrappedDekRecovery: oldWrappedRecovery,
        recoverySalt: oldRecoverySalt,
        recoveryHash: oldRecoveryHash,
        argon2Params: accountParams,
      );
      expect(await autoSync.recoveryKeyStatus(refresh: true), isTrue);
      expect(settings.syncRecoveryKeySet, isTrue);
    });

    test('the status of a store without one says so', () async {
      await setUpStore(withRecovery: false);
      await autoSync.syncNowManual();
      expect(settings.syncRecoveryKeySet, isFalse);
    });
  });

  group('checking a recovery key (recovery kit)', () {
    test('the kit\'s key works, however it is typed back', () async {
      await setUpStore();
      final mine = await dek.extractBytes();
      for (final typed in [
        oldRecoveryKey,
        oldRecoveryKey.toLowerCase(),
        oldRecoveryKey.replaceAll('-', ' '),
        oldRecoveryKey.replaceAll('-', ''),
        '  $oldRecoveryKey\n',
      ]) {
        expect(await checkRecoveryKey(backend, typed, deviceDek: mine), RecoveryKeyCheck.works, reason: typed);
      }
    });

    test('another key does not, and neither does something that is not a key', () async {
      await setUpStore();
      final mine = await dek.extractBytes();
      expect(await checkRecoveryKey(backend, 'ZEST-AAAA-BBBB-CCCC-DDDD-EEEF', deviceDek: mine), RecoveryKeyCheck.wrongKey);
      expect(await checkRecoveryKey(backend, 'my password', deviceDek: mine), RecoveryKeyCheck.wrongKey);
    });

    test('a key for another vault is told apart from one for this device\'s', () async {
      await setUpStore();
      final other = List<int>.generate(32, (i) => i + 1);
      expect(await checkRecoveryKey(backend, oldRecoveryKey, deviceDek: other), RecoveryKeyCheck.otherVault);
    });

    test('with no key stored, it says so', () async {
      await setUpStore(withRecovery: false);
      expect(await checkRecoveryKey(backend, oldRecoveryKey, deviceDek: await dek.extractBytes()),
          RecoveryKeyCheck.notSetUp);
    });

    test('nothing changes: the store is only read', () async {
      await setUpStore();
      final store = backend.store;
      final (counter, etag, bytes) = (store.counter, store.etag, List<int>.from(store.bytes!));
      await checkRecoveryKey(backend, oldRecoveryKey, deviceDek: await dek.extractBytes());
      await checkRecoveryKey(backend, 'ZEST-AAAA-BBBB-CCCC-DDDD-EEEF', deviceDek: await dek.extractBytes());
      expect(store.counter, counter, reason: 'nothing written');
      expect(store.etag, etag);
      expect(store.bytes, bytes);
    });
  });

  test('a key typed back is tidied, or refused when it cannot be one', () {
    expect(RecoveryKeyService.tidy('zest aaaa-bbbb cccc dddd eeee'), 'ZEST-AAAA-BBBB-CCCC-DDDD-EEEE');
    expect(RecoveryKeyService.tidy('ZESTAAAABBBBCCCCDDDDEEEE'), 'ZEST-AAAA-BBBB-CCCC-DDDD-EEEE');
    final made = RecoveryKeyService.generateRecoveryKey();
    expect(RecoveryKeyService.tidy(made), made);
    for (final bad in [
      '',
      'ZEST-AAAA',
      'ZEST-AAAA-BBBB-CCCC-DDDD-EEEE-F',
      'KEYS-AAAA-BBBB-CCCC-DDDD-EEEE',
      'ZEST-OOOO-BBBB-CCCC-DDDD-EEEE', // no O in the alphabet
      'ZEST-0000-1111-IIII-LLLL-EEEE', // nor 0, 1, I or L
    ]) {
      expect(RecoveryKeyService.tidy(bad), isNull, reason: bad);
    }
  });

  test('the setup-time error message is available', () {
    // replaceRecoveryKey's last resort names what happened in plain words.
    expect(gl10n.recoveryReplaceNotSaved, isNotEmpty);
  });
}

/// A store object whose manifest carries no password-wrapped key.
Future<Uint8List> _manifestWithoutWrappedKey(
    SecretKey dek, Uint8List salt, Uint8List verHash, Map<String, dynamic> params) async {
  final encrypted = await SyncService.encrypt(const {'connections': []}, dek, salt);
  return SyncManifest(
    version: 1,
    updatedAt: DateTime.utc(2026, 9, 25),
    salt: salt,
    argon2Params: params,
    encryptedData: encrypted,
    passwordHash: verHash,
  ).toBytes();
}
