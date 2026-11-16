import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/vault_slot_service.dart';

/// Exercises the 1.8 encrypting-lock vault end to end via the PIN slot (4 MB
/// Argon2id, fast enough for a unit test). The master-password and recovery
/// slots share the exact same wrap/unwrap mechanism and differ only in the KEK
/// derivation (SyncService.deriveKey / RecoveryKeyService), which is 64-128 MB
/// Argon2id - too slow for flutter_test's pure-Dart KDF - so those paths are
/// covered by the integration / red-team pass, not here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A realistic 64-hex SQLCipher key (the value database.dart stores).
  const dbKeyHex =
      'a1b2c3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff00';
  const pin = '1379';

  late VaultSlotService vault;

  setUp(() {
    // Simulate an existing install: the plaintext DB key is present.
    FlutterSecureStorage.setMockInitialValues({
      VaultSlotService.dbKeyId: dbKeyHex,
    });
    vault = VaultSlotService(const FlutterSecureStorage());
  });

  Future<Map<String, String>> readAll() =>
      const FlutterSecureStorage().readAll();

  test('enableLock wraps the DB key and DELETES the plaintext copy', () async {
    expect(await vault.isEnabled(), isFalse);
    await vault.enableLock(dbKeyHex: dbKeyHex, pin: pin);

    expect(await vault.isEnabled(), isTrue);
    final store = await readAll();
    // The plaintext key must be gone; the wrapped copy + slots present.
    expect(store.containsKey(VaultSlotService.dbKeyId), isFalse,
        reason: 'plaintext DB key must be deleted once the lock is on');
    expect(store.containsKey(VaultSlotService.wrappedDbKeyId), isTrue);
    expect(store.containsKey(VaultSlotService.slotsId), isTrue);
    expect(await vault.slotTypes(), {VaultSlotType.pin});
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('the correct PIN unlocks and recovers the original DB key', () async {
    await vault.enableLock(dbKeyHex: dbKeyHex, pin: pin);
    final recovered = await vault.unlockDbKeyHex(pin: pin);
    expect(recovered, dbKeyHex);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a wrong PIN throws VaultLockedException', () async {
    await vault.enableLock(dbKeyHex: dbKeyHex, pin: pin);
    await expectLater(
      vault.unlockVaultKey(pin: '0000'),
      throwsA(isA<VaultLockedException>()),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('changePin: old PIN stops working, new PIN recovers the same key',
      () async {
    await vault.enableLock(dbKeyHex: dbKeyHex, pin: pin);
    final vaultKey = await vault.unlockVaultKey(pin: pin);
    await vault.changePin(vaultKey, '2468');

    await expectLater(
      vault.unlockVaultKey(pin: pin),
      throwsA(isA<VaultLockedException>()),
    );
    expect(await vault.unlockDbKeyHex(pin: '2468'), dbKeyHex);
    expect(await vault.slotTypes(), {VaultSlotType.pin});
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('disableLock restores the exact plaintext DB key and drops the vault',
      () async {
    await vault.enableLock(dbKeyHex: dbKeyHex, pin: pin);
    final recovered = await vault.unlockDbKeyHex(pin: pin);
    await vault.disableLock(recovered);

    expect(await vault.isEnabled(), isFalse);
    final store = await readAll();
    expect(store[VaultSlotService.dbKeyId], dbKeyHex);
    expect(store.containsKey(VaultSlotService.wrappedDbKeyId), isFalse);
    expect(store.containsKey(VaultSlotService.slotsId), isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a tampered wrapped-DB-key blob fails to unwrap', () async {
    await vault.enableLock(dbKeyHex: dbKeyHex, pin: pin);
    final vaultKey = await vault.unlockVaultKey(pin: pin);
    // Corrupt the wrapped DB key so its GCM tag no longer authenticates.
    await const FlutterSecureStorage().write(
      key: VaultSlotService.wrappedDbKeyId,
      value: 'AAAA${'B' * 120}',
    );
    await expectLater(
      vault.unwrapDbKeyHex(vaultKey),
      throwsA(anything),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  // ── reconcileAndIsLocked: the crash-safe boot decision ─────────────
  // These are fast (pure secure-storage, no KDF): the boot path must decide
  // lock-ON vs lock-OFF from the ACTUAL storage state, never a prefs flag, and
  // self-heal a half-finished enable/disable so a mistimed process kill can
  // never funnel the user into the data-wiping reset screen or a lockout.

  VaultSlotService freshVault(Map<String, String> initial) {
    FlutterSecureStorage.setMockInitialValues(initial);
    return VaultSlotService(const FlutterSecureStorage());
  }

  test('reconcile: fresh install (nothing stored) -> lock-OFF, no crash',
      () async {
    final v = freshVault({});
    expect(await v.reconcileAndIsLocked(), isFalse);
  });

  test('reconcile: normal lock-OFF (only plaintext key) -> lock-OFF, key kept',
      () async {
    final v = freshVault({VaultSlotService.dbKeyId: dbKeyHex});
    expect(await v.reconcileAndIsLocked(), isFalse);
    expect((await readAll())[VaultSlotService.dbKeyId], dbKeyHex);
  });

  test('reconcile: genuine lock-ON (slots+wrapped, no plaintext) -> lock-ON',
      () async {
    final v = freshVault({
      VaultSlotService.slotsId: '{"schema":1,"slots":[]}',
      VaultSlotService.wrappedDbKeyId: 'd2Vjcg==',
    });
    expect(await v.reconcileAndIsLocked(), isTrue);
    // The vault must be left intact (nothing dropped).
    final store = await readAll();
    expect(store.containsKey(VaultSlotService.slotsId), isTrue);
    expect(store.containsKey(VaultSlotService.wrappedDbKeyId), isTrue);
  });

  test(
      'reconcile: interrupted ENABLE (plaintext still present + full vault) -> '
      'lock-OFF and orphan vault dropped', () async {
    final v = freshVault({
      VaultSlotService.dbKeyId: dbKeyHex,
      VaultSlotService.slotsId: '{"schema":1,"slots":[]}',
      VaultSlotService.wrappedDbKeyId: 'd2Vjcg==',
    });
    expect(await v.reconcileAndIsLocked(), isFalse);
    final store = await readAll();
    // Plaintext key (the sole real key holder) is preserved...
    expect(store[VaultSlotService.dbKeyId], dbKeyHex);
    // ...and the redundant orphan vault entries are cleaned up.
    expect(store.containsKey(VaultSlotService.slotsId), isFalse);
    expect(store.containsKey(VaultSlotService.wrappedDbKeyId), isFalse);
  });

  test(
      'reconcile: interrupted DISABLE (plaintext restored, wrapped gone, slots '
      'linger) -> lock-OFF and orphan slots dropped', () async {
    final v = freshVault({
      VaultSlotService.dbKeyId: dbKeyHex,
      VaultSlotService.slotsId: '{"schema":1,"slots":[]}',
    });
    expect(await v.reconcileAndIsLocked(), isFalse);
    final store = await readAll();
    expect(store[VaultSlotService.dbKeyId], dbKeyHex);
    expect(store.containsKey(VaultSlotService.slotsId), isFalse);
  });

  test('reconcile: end-to-end enableLock output reads back as lock-ON',
      () async {
    // A real enable must leave storage in the genuine lock-ON shape.
    await vault.enableLock(dbKeyHex: dbKeyHex, pin: pin);
    expect(await vault.reconcileAndIsLocked(), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));

  // ── Hardware-backed layer (crypto round-trip; the Keystore/Enclave side is
  //    device-only and covered by the manual test plan) ────────────────────
  final hwKey = List<int>.generate(32, (i) => 7 * i % 256);

  test('hardware layer: enable -> PIN alone fails, PIN+hwKey recovers the key',
      () async {
    await vault.enableLock(dbKeyHex: dbKeyHex, pin: pin);
    await vault.enableHardwareLayer(hwKey);
    expect(await vault.isHardwareBound(), isTrue);
    // The plain wrapped blob must be GONE (else the hw layer is decorative).
    expect((await readAll()).containsKey(VaultSlotService.wrappedDbKeyId),
        isFalse);
    // PIN without the hardware key must NOT decrypt.
    await expectLater(
      vault.unlockDbKeyHex(pin: pin),
      throwsA(isA<VaultLockedException>()),
    );
    // PIN + hardware key recovers the exact DB key.
    expect(await vault.unlockDbKeyHex(pin: pin, hardwareKey: hwKey), dbKeyHex);
    // A WRONG hardware key fails the GCM tag.
    await expectLater(
      vault.unlockDbKeyHex(pin: pin, hardwareKey: List<int>.filled(32, 1)),
      throwsA(anything),
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
      'hardware layer: a stale plain blob (crash mid-enable) does NOT bypass '
      'the hardware requirement', () async {
    await vault.enableLock(dbKeyHex: dbKeyHex, pin: pin);
    await vault.enableHardwareLayer(hwKey);
    // Simulate a crash between enableHardwareLayer's two writes: re-plant a
    // stale plain wrappedDbKeyId alongside the hw blob.
    await const FlutterSecureStorage()
        .write(key: VaultSlotService.wrappedDbKeyId, value: 'c3RhbGU=');
    expect(await vault.isHardwareBound(), isTrue);
    // The hw blob is authoritative: PIN alone must STILL fail (not silently
    // fall back to the stale plain path), and PIN + hwKey must recover the key.
    await expectLater(
      vault.unlockDbKeyHex(pin: pin),
      throwsA(isA<VaultLockedException>()),
    );
    expect(await vault.unlockDbKeyHex(pin: pin, hardwareKey: hwKey), dbKeyHex);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('hardware layer: disable restores PIN-only unlock', () async {
    await vault.enableLock(dbKeyHex: dbKeyHex, pin: pin);
    await vault.enableHardwareLayer(hwKey);
    await vault.disableHardwareLayer(hwKey);
    expect(await vault.isHardwareBound(), isFalse);
    expect(await vault.unlockDbKeyHex(pin: pin), dbKeyHex);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('hardware layer: reconcile treats the hw-wrapped vault as lock-ON',
      () async {
    await vault.enableLock(dbKeyHex: dbKeyHex, pin: pin);
    await vault.enableHardwareLayer(hwKey);
    expect(await vault.reconcileAndIsLocked(), isTrue,
        reason: 'hw-wrapped vault must NOT be treated as broken/lock-OFF');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('hardware layer: disableLock clears the hw blob too', () async {
    await vault.enableLock(dbKeyHex: dbKeyHex, pin: pin);
    await vault.enableHardwareLayer(hwKey);
    final recovered = await vault.unlockDbKeyHex(pin: pin, hardwareKey: hwKey);
    await vault.disableLock(recovered);
    final store = await readAll();
    expect(store[VaultSlotService.dbKeyId], dbKeyHex);
    expect(store.containsKey(VaultSlotService.hwWrappedDbKeyId), isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
