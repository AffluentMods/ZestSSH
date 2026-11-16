import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/services/security_lock_service.dart';
import 'package:zestssh/services/vault_slot_service.dart';

/// A vault whose turning off is where the app is stopped: what is in the
/// storage then is what the next start finds.
class _StoppedAfterTurningOff extends VaultSlotService {
  _StoppedAfterTurningOff(super.secure);

  @override
  Future<void> disableLock(String dbKeyHex) async {
    await super.disableLock(dbKeyHex);
    throw StateError('the app was stopped here');
  }
}

/// With the encrypting lock on, the PIN is checked against the vault's own
/// PIN slot, and no cheaper hash of it is kept beside it (found
/// in a security review): the app lock's hash (Argon2id at
/// 4 MB) lay in the same storage as the vault's slot (64 MB on a computer),
/// so a copy of that storage gave the PIN up sixteen times sooner, and the
/// PIN opened the vault.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();
  const pinHash = 'security_pin_hash';

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('the vault is what the PIN is checked against; a hash left from before goes once the PIN is right', () async {
    final service = SecurityLockService(storage, LocalAuthentication());
    await service.setPin('482915');
    expect(await storage.read(key: pinHash), isNotNull, reason: 'the app lock alone keeps its hash');
    await VaultSlotService(storage).enableLock(dbKeyHex: 'ab' * 32, pin: '482915');

    expect(await service.verifyPin('000000'), isFalse);
    expect(service.failedAttempts, 1, reason: 'a wrong PIN counts toward the lockout as before');
    expect(await storage.read(key: pinHash), isNotNull, reason: 'kept until the PIN is right');
    expect(await service.verifyPin('482915'), isTrue);
    expect(service.failedAttempts, 0);
    expect(await storage.read(key: pinHash), isNull);
    expect(await service.hasPinConfigured(), isTrue, reason: 'the vault has the PIN');

    await service.setPin('135792');
    expect(await storage.read(key: pinHash), isNull, reason: 'no hash beside the vault');
  });

  test('turning the encrypting lock on drops the hash; turning it off brings it back for the app lock', () async {
    SharedPreferences.setMockInitialValues(const {});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
    ]);
    addTearDown(container.dispose);
    container.read(databaseSessionProvider.notifier).seed(db);
    final service = container.read(securityLockServiceProvider);
    await service.setPin('482915');
    final lock = container.read(isAppLockedProvider.notifier);

    await lock.enableEncryptingLock(pin: '482915');
    expect(await storage.read(key: pinHash), isNull);
    expect(await service.verifyPin('482915'), isTrue);
    expect(await service.verifyPin('482916'), isFalse);

    await lock.disableEncryptingLock('482915');
    expect(await storage.read(key: pinHash), isNotNull);
    expect(await service.verifyPin('482915'), isTrue);
    expect(await service.verifyPin('482916'), isFalse);
  });

  test('the app stopped while the encrypting lock is turned off still opens with the PIN', () async {
    SharedPreferences.setMockInitialValues(const {});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
      vaultSlotServiceProvider.overrideWithValue(_StoppedAfterTurningOff(storage)),
    ]);
    addTearDown(container.dispose);
    container.read(databaseSessionProvider.notifier).seed(db);
    await container.read(securityLockServiceProvider).setPin('482915');
    final lock = container.read(isAppLockedProvider.notifier);
    await lock.enableEncryptingLock(pin: '482915');
    expect(await storage.read(key: pinHash), isNull);

    // Stopped just after the vault went: as the next start finds the storage.
    await expectLater(lock.disableEncryptingLock('482915'), throwsStateError);
    expect(await VaultSlotService(storage).isEnabled(), isFalse, reason: 'the vault is gone');
    final next = SecurityLockService(storage, LocalAuthentication());
    expect(await next.verifyPin('482916'), isFalse);
    expect(await next.verifyPin('482915'), isTrue, reason: 'the app lock opens with the PIN');
    expect(await next.hasPinConfigured(), isTrue);
  });
}
