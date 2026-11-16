import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:typed_data';

import 'package:biometric_storage/biometric_storage.dart';
import 'package:zestssh/services/hardware_backed_vault.dart';

/// Opt-in hardware-backed layer for the at-rest vault.
///
/// Stores a random 256-bit key behind the device's secure hardware (Android
/// Keystore / iOS Secure Enclave) via biometric_storage, gated by device
/// authentication. That key then wraps the vault's inner secrets, so the
/// encrypted data cannot be brute-forced offline from an extracted file:
/// unwrapping has to go through the hardware's rate-limited auth, which cannot
/// be copied off the device.
///
/// Auth deliberately allows the DEVICE CREDENTIAL (PIN / pattern / passcode) as
/// a fallback, not biometrics only - so re-enrolling a fingerprint or a face
/// does NOT invalidate the key (a data-loss guard). Removing the device's
/// screen lock entirely can still invalidate it, which is why hardware binding
/// is opt-in and gated behind a backup warning.
///
/// iOS, until 2.2.1, did not get that fallback: biometric_storage's
/// `darwinBiometricOnly` defaults to true, which stores the key under
/// `.biometryCurrentSet`, and iOS deletes such a key the moment Face ID or
/// Touch ID enrollment changes, leaving the vault unopenable. The keychain
/// never changes an existing item's access rule on a later write, so the fixed
/// key lives under a new name ([iosStorageName], `.userPresence`: Face ID,
/// Touch ID or the passcode), and [read] moves an older key there once, the
/// first time it opens it.
class HardwareVaultService implements HardwareBackedVault {
  HardwareVaultService({HardwareKeyStore? store, bool? isIOS})
      : _store = store ?? const PluginHardwareKeyStore(),
        _isIOS = isIOS ?? Platform.isIOS;

  final HardwareKeyStore _store;
  final bool _isIOS;

  /// The key's name on Android, and on iOS before 2.2.1.
  static const legacyStorageName = 'zestssh_vault_hw_key';

  /// The key's name on iOS since 2.2.1.
  static const iosStorageName = 'zestssh_vault_hw_key_ios2';

  /// Android: device credential allowed as a fallback. Android requires a
  /// time-bound auth validity when the device credential is allowed (per-use
  /// auth, -1, is biometric-only and throws IllegalArgumentException - caught
  /// by the on-device test). 10s is just enough to read the key during one
  /// unlock flow. Unchanged since the layer shipped, so existing keys open.
  static final StorageFileInitOptions androidOptions = StorageFileInitOptions(
    authenticationRequired: true,
    androidBiometricOnly: false,
    authenticationValidityDurationSeconds: 10,
  );

  /// iOS since 2.2.1: `.userPresence`, so Face ID, Touch ID or the device
  /// passcode opens the key and a change to the enrolled faces or fingers
  /// leaves it alone.
  static final StorageFileInitOptions iosOptions = StorageFileInitOptions(
    authenticationRequired: true,
    androidBiometricOnly: false,
    darwinBiometricOnly: false,
    authenticationValidityDurationSeconds: 10,
  );

  /// The options an iOS key was written with before 2.2.1 (the plugin default,
  /// `darwinBiometricOnly: true`). Only used to read and remove that key, with
  /// exactly the query it was written under.
  static final StorageFileInitOptions legacyIosOptions = StorageFileInitOptions(
    authenticationRequired: true,
    androidBiometricOnly: false,
    authenticationValidityDurationSeconds: 10,
  );

  /// Whether this device can back a hardware key with device auth.
  ///
  /// `errorNoBiometricEnrolled` still counts as available: we allow the DEVICE
  /// CREDENTIAL (PIN/pattern/passcode) as the auth method, so a phone with a
  /// screen lock but no enrolled fingerprint or face can use hardware binding.
  /// `errorPasscodeNotSet` (no screen lock at all) is genuinely unavailable.
  @override
  Future<bool> isAvailable() async {
    try {
      final r = await _store.canAuthenticate();
      return r == CanAuthenticateResponse.success ||
          r == CanAuthenticateResponse.errorNoBiometricEnrolled;
    } catch (_) {
      return false;
    }
  }

  /// Generate a fresh hardware-backed 256-bit key and store it (device-auth
  /// prompt). Returns the key bytes; the caller wraps the vault with them and
  /// discards them.
  @override
  Future<Uint8List> generateAndStore() async {
    final rng = Random.secure();
    final key =
        Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256)));
    final value = base64Encode(key);
    if (_isIOS) {
      await _store.write(iosStorageName, iosOptions, value);
      // A key left under the old name from an earlier binding must not linger.
      await _deleteQuietly(legacyStorageName, legacyIosOptions);
    } else {
      await _store.write(legacyStorageName, androidOptions, value);
    }
    return key;
  }

  /// Read the stored hardware key - triggers a device-auth prompt. Throws if
  /// the item is missing or authentication fails / is cancelled.
  @override
  Future<Uint8List> read() async {
    if (!_isIOS) {
      return _decode(await _store.read(legacyStorageName, androidOptions));
    }
    final current = await _store.read(iosStorageName, iosOptions);
    if (current != null) return base64Decode(current);
    // A key written before 2.2.1: still Face ID / Touch ID only. Open it once,
    // then keep it under the new name, which also accepts the passcode.
    final legacy = await _store.read(legacyStorageName, legacyIosOptions);
    final key = _decode(legacy);
    await _moveToCurrent(legacy!);
    return key;
  }

  /// Remove the hardware key (when turning hardware binding off).
  @override
  Future<void> delete() async {
    if (_isIOS) {
      await _store.delete(iosStorageName, iosOptions);
      await _deleteQuietly(legacyStorageName, legacyIosOptions);
    } else {
      await _store.delete(legacyStorageName, androidOptions);
    }
  }

  /// Write the new copy first and remove the old one only after, so a failure
  /// at any point leaves a key this device can still open; a failed move is
  /// simply tried again at the next unlock.
  Future<void> _moveToCurrent(String value) async {
    try {
      await _store.write(iosStorageName, iosOptions, value);
    } catch (_) {
      return;
    }
    await _deleteQuietly(legacyStorageName, legacyIosOptions);
  }

  Future<void> _deleteQuietly(
      String name, StorageFileInitOptions options) async {
    try {
      await _store.delete(name, options);
    } catch (_) {}
  }

  static Uint8List _decode(String? value) {
    if (value == null) {
      throw StateError('Hardware key not found');
    }
    return base64Decode(value);
  }
}

/// The biometric_storage calls [HardwareVaultService] makes, one named key at
/// a time, so tests can stand in for the platform plugin.
abstract class HardwareKeyStore {
  Future<CanAuthenticateResponse> canAuthenticate();

  /// The stored value, or null when there is no key under [name].
  Future<String?> read(String name, StorageFileInitOptions options);

  Future<void> write(String name, StorageFileInitOptions options, String value);

  /// Removing a key that is not there succeeds.
  Future<void> delete(String name, StorageFileInitOptions options);
}

/// [HardwareKeyStore] over the biometric_storage plugin.
class PluginHardwareKeyStore implements HardwareKeyStore {
  const PluginHardwareKeyStore();

  Future<BiometricStorageFile> _file(
          String name, StorageFileInitOptions options) =>
      BiometricStorage().getStorage(name, options: options);

  @override
  Future<CanAuthenticateResponse> canAuthenticate() =>
      BiometricStorage().canAuthenticate();

  @override
  Future<String?> read(String name, StorageFileInitOptions options) async =>
      (await _file(name, options)).read();

  @override
  Future<void> write(
          String name, StorageFileInitOptions options, String value) async =>
      (await _file(name, options)).write(value);

  @override
  Future<void> delete(String name, StorageFileInitOptions options) async =>
      (await _file(name, options)).delete();
}
