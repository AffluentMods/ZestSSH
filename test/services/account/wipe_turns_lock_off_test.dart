// "Delete all local data" on a phone with Encrypt data at rest on (found in a
// review). With the lock on the database's key is in the storage
// only wrapped, beside the PIN slots; the wipe spared the plain key by name
// alone, so it deleted the only copies of the key of a database that stayed
// open and in use, and it deleted the seal's key row on a phone. What was
// added between the wipe and the next start could never be read again.
//
// The wipe now turns the lock off, as its description says the app lock goes:
// the key is written back as it is
// with the lock off, then the wrapped key and its slots go.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/account/local_data_wiper.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/vault_slot_service.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zest-wipe-lock-');
  });

  tearDown(() async {
    DatabaseSessionNotifier.debugOpen = null;
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<LocalDataWiper> wipe(AppDatabase db, FlutterSecureStorage storage, {String? lockedKeyHex}) async {
    final wiper = LocalDataWiper(
      database: db,
      secureStorage: storage,
      preferences: await SharedPreferences.getInstance(),
      targets: const WipeTargets(),
      lockedKeyHex: lockedKeyHex,
      deleteDatabaseCopies: () async {},
      listMigrationBackups: () async => const [],
    );
    await wiper.wipe();
    return wiper;
  }

  final dbKeyHex = 'ab' * 32;

  /// A phone with the lock on: the plain key gone, the wrapped key and a PIN
  /// slot in its place, sealing on.
  Future<(AppDatabase, FlutterSecureStorage, VaultSlotService)> lockedPhone({File? file}) async {
    final db = AppDatabase.forTesting(file == null ? NativeDatabase.memory() : NativeDatabase(file));
    FlutterSecureStorage.setMockInitialValues({
      AppDatabase.encryptionKeyStorageKey: dbKeyHex,
      'identity_key_1': 'a private key',
    });
    SharedPreferences.setMockInitialValues({'encrypting_lock_enabled': true});
    const storage = FlutterSecureStorage();
    final vault = VaultSlotService(storage);
    await vault.enableLock(dbKeyHex: dbKeyHex, pin: '135790');
    await sealSecretsAtRest(db, storage);
    expect(await storage.read(key: AppDatabase.encryptionKeyStorageKey), isNull);
    expect((await SecretSeal.of(db)).active, isTrue);
    return (db, storage, vault);
  }

  test('with the lock on, a wipe turns it off: the key of the open database is in the storage as it is, and nothing else', () async {
    final (db, storage, vault) = await lockedPhone();
    addTearDown(db.close);

    final wiper = await wipe(db, storage, lockedKeyHex: dbKeyHex);

    expect(wiper.turnedLockOff, isTrue);
    expect(await storage.readAll(), {AppDatabase.encryptionKeyStorageKey: dbKeyHex},
        reason: 'the key the database is open by, where a start with the lock off looks for it');
    expect(await vault.isEnabled(), isFalse);
    expect(await vault.reconcileAndIsLocked(), isFalse, reason: 'the next start asks for no PIN');
    expect((await SecretSeal.of(db)).active, isFalse, reason: 'what is written from now on is kept as it is');
  });

  test('the same where the device hardware held the wrapped key too', () async {
    final (db, storage, vault) = await lockedPhone();
    addTearDown(db.close);
    await vault.enableHardwareLayer(List<int>.generate(32, (i) => i));
    expect(await vault.isHardwareBound(), isTrue);

    await wipe(db, storage, lockedKeyHex: dbKeyHex);

    expect(await storage.readAll(), {AppDatabase.encryptionKeyStorageKey: dbKeyHex});
    expect(await vault.reconcileAndIsLocked(), isFalse);
  });

  test('a wipe stopped right after the lock went leaves a database its key opens', () async {
    final (db, storage, vault) = await lockedPhone();
    addTearDown(db.close);
    // What the wipe does first, and nothing after it.
    await vault.disableLock(dbKeyHex);
    expect(await storage.read(key: AppDatabase.encryptionKeyStorageKey), dbKeyHex);
    expect(await vault.reconcileAndIsLocked(), isFalse);
    // The secret sealed while the lock was on still opens: the seal's key is
    // in the database, which that key opens.
    final kept = await storage.read(key: 'identity_key_1');
    expect(SecretSeal.isSealed(kept), isTrue);
    expect(await openKept(db, 'identity_key_1', kept), 'a private key');
  });

  test('with the lock on and no key given, the wrapped key and its slots stay: the lock stays, the PIN still opens it', () async {
    final (db, storage, vault) = await lockedPhone();
    addTearDown(db.close);

    final wiper = await wipe(db, storage);

    expect(wiper.turnedLockOff, isFalse);
    expect((await storage.readAll()).keys.toSet(), {VaultSlotService.wrappedDbKeyId, VaultSlotService.slotsId});
    expect(await vault.reconcileAndIsLocked(), isTrue);
    expect(await vault.unlockDbKeyHex(pin: '135790'), dbKeyHex);
  });

  test('with the lock off, a wipe keeps the plain key and nothing else', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    FlutterSecureStorage.setMockInitialValues({
      AppDatabase.encryptionKeyStorageKey: 'cd' * 32,
      'identity_key_1': 'a private key',
      'sync_key': 'a sync key',
    });
    SharedPreferences.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    final wiper = await wipe(db, storage);
    expect(wiper.turnedLockOff, isFalse);
    expect((await storage.readAll()).keys.toList(), [AppDatabase.encryptionKeyStorageKey]);
  });

  test('what is saved after the wipe still reads after a restart', () async {
    final file = File(p.join(root.path, 'tree.db'));
    var (db, storage, _) = await lockedPhone(file: file);

    await wipe(db, storage, lockedKeyHex: dbKeyHex);

    // The person goes on in the same run: a new key's private key is saved.
    const slot = 'identity_key_new';
    const pem = '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----';
    final stored = await keepSealed(db, slot, pem);
    await storage.write(key: slot, value: stored);
    expect(SecretSeal.isSealed(stored), isFalse, reason: 'the lock is off: kept as it is');

    // The app is closed and started again.
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    expect((await SecretSeal.of(db)).active, isFalse);
    expect(await openKept(db, slot, await storage.read(key: slot)), pem);
  });

  test('a secret sealed after wipeAllData still opens after a restart, on a phone as on a computer', () async {
    final file = File(p.join(root.path, 'tree.db'));
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();

    var db = AppDatabase.forTesting(NativeDatabase(file));
    // The lock is on: sealing is on, its key made in local_state.
    await sealSecretsAtRest(db, storage);
    expect((await SecretSeal.of(db)).active, isTrue);

    await db.wipeAllData();

    const slot = 'identity_key_new';
    const pem = '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----';
    final stored = await keepSealed(db, slot, pem);
    await storage.write(key: slot, value: stored);
    expect(SecretSeal.isSealed(stored), isTrue);

    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    await sealSecretsAtRest(db, storage);

    final after = await storage.read(key: slot);
    expect(SecretSeal.isSealed(after), isTrue);
    expect(await openKept(db, slot, after), pem, reason: "the seal's key stayed with its database");
  });

  test('the session holds the key only while the lock is on and the app unlocked', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final session = container.read(databaseSessionProvider.notifier);
    expect(session.lockedKeyHex, isNull);

    // Unlocked with the PIN: opened by the key the vault gave.
    final opened = AppDatabase.forTesting(NativeDatabase.memory());
    DatabaseSessionNotifier.debugOpen = (hex) async => opened;
    await session.open(dbKeyHex);
    expect(session.lockedKeyHex, dbKeyHex);
    // Locked again: closed, and the key forgotten.
    await session.close();
    expect(session.lockedKeyHex, isNull);

    // The lock turned on over a database opened without it, then off again.
    final seeded = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(seeded.close);
    session.seed(seeded);
    expect(session.lockedKeyHex, isNull);
    session.lockTurnedOn(dbKeyHex);
    expect(session.lockedKeyHex, dbKeyHex);
    session.lockTurnedOff();
    expect(session.lockedKeyHex, isNull);
  });
}
