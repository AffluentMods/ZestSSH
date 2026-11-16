import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as hash_lib;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/error_codes.dart' as auth_error;
import 'package:local_auth/local_auth.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/services/vault_slot_service.dart';

/// Result of a biometric authentication attempt. Richer than a bool so the
/// lock screen can tell "the user just failed / cancelled" (keep offering the
/// sensor) apart from "the OS has locked biometrics out" (drop to the PIN
/// fallback immediately, since retrying the sensor can't succeed).
enum BiometricAuthOutcome {
  /// Verified - unlock.
  success,

  /// The attempt failed or was cancelled; the sensor is still usable.
  failed,

  /// Biometrics are locked out at the OS level (too many device-wide failures,
  /// temporary or permanent). Retrying won't help until the user clears it with
  /// their device credential.
  lockedOut,

  /// No usable biometric - none enrolled, hardware unavailable, or no device
  /// passcode set.
  unavailable,
}

/// Manages app security lock (biometrics / PIN).
///
/// This is a free feature - security should not be paywalled.
class SecurityLockService {
  final FlutterSecureStorage _secureStorage;
  final LocalAuthentication _localAuth;

  static const _pinHashKey = 'security_pin_hash';
  static const _lockMethodKey = 'security_lock_method';
  static const _autoLockTimeoutKey = 'security_auto_lock_timeout';
  static const _idleLockKey = 'security_idle_lock_minutes';

  // ── Brute-force protection ──────────────────────────────────────
  static const _maxAttempts = 10;
  static const _failedAttemptsKey = 'pin_failed_attempts';
  static const _lockoutUntilKey = 'pin_lockout_until';

  int _failedAttempts = 0;
  DateTime? _lockoutUntil;
  bool _lockoutStateLoaded = false;

  /// Whether the PIN entry is currently locked out due to too many failures.
  bool get isLockedOut {
    if (_lockoutUntil == null) return false;
    if (DateTime.now().isAfter(_lockoutUntil!)) {
      _lockoutUntil = null;
      return false;
    }
    return true;
  }

  /// Seconds remaining in the current lockout period, or 0.
  int get remainingLockoutSeconds {
    if (_lockoutUntil == null) return 0;
    final remaining = _lockoutUntil!.difference(DateTime.now()).inSeconds;
    return remaining > 0 ? remaining : 0;
  }

  /// Current number of consecutive failed PIN attempts.
  int get failedAttempts => _failedAttempts;

  /// Max attempts before lockout is triggered.
  int get maxAttempts => _maxAttempts;

  SecurityLockService(this._secureStorage, this._localAuth);

  /// Check if device supports biometrics.
  Future<bool> isBiometricAvailable() async {
    try {
      final isSupported = await _localAuth.isDeviceSupported();
      // On desktop, Windows Hello / Touch ID counts as available whenever the
      // OS supports it, even with no fingerprint/face sensor: PIN-only Hello is
      // a perfectly valid unlock, and `canCheckBiometrics` is FALSE in that very
      // common case, so requiring it there wrongly reports "unavailable" and
      // hides the option. On mobile, still require a real biometric sensor,
      // since there "biometric" specifically means fingerprint / face.
      if (isDesktopPlatform) return isSupported;
      final canCheck = await _localAuth.canCheckBiometrics;
      return canCheck && isSupported;
    } on PlatformException catch (e) {
      AppLogger.error('Biometric check failed', e);
      return false;
    } on MissingPluginException {
      // No way to ask on this system (Linux has no plugin for it): none to
      // offer.
      return false;
    } catch (e) {
      AppLogger.error('Biometric check failed', e);
      return false;
    }
  }

  /// Get available biometric types.
  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _localAuth.getAvailableBiometrics();
    } on PlatformException catch (e) {
      AppLogger.error('Get biometrics failed', e);
      return [];
    } on MissingPluginException {
      return [];
    } catch (e) {
      AppLogger.error('Get biometrics failed', e);
      return [];
    }
  }

  /// Authenticate with biometrics. [reason] is what the system's prompt says
  /// (the lock screen passes its own words); without one it is said in the
  /// app's language ([gl10n]): it was an English sentence in every language.
  Future<BiometricAuthOutcome> authenticateWithBiometric({String? reason}) async {
    try {
      var timedOut = false;
      final ok = await _localAuth
          .authenticate(
        localizedReason: reason ?? gl10n.docCheckBiometricReason,
        options: AuthenticationOptions(
          stickyAuth: true,
          // On desktop "biometric" is Windows Hello / Touch ID, a single OS
          // credential that may be PIN, face, or fingerprint. Forcing
          // biometricOnly there suppresses the standard Hello prompt (the one
          // every other app shows) on machines without a face/fingerprint
          // sensor, so it never surfaces. Keep biometricOnly on mobile, where it
          // genuinely means fingerprint / face and we don't want the passcode.
          biometricOnly: !isDesktopPlatform,
        ),
      )
          .timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          timedOut = true;
          return false;
        },
      );
      // A prompt that never resolves (observed on some Windows Hello setups
      // where the OS dialog fails to surface) must not wedge the lock screen on
      // "Authenticating…". Treat a timeout as unavailable so the caller drops to
      // the PIN fallback instead of hanging with the PIN escape disabled.
      if (timedOut) return BiometricAuthOutcome.unavailable;
      return ok ? BiometricAuthOutcome.success : BiometricAuthOutcome.failed;
    } on PlatformException catch (e) {
      AppLogger.error('Biometric auth failed', e);
      // Distinguish an OS-level lockout (retrying the sensor is futile until the
      // user re-authenticates with their device credential) from a plain
      // failure so the lock screen can drop straight to the PIN fallback.
      if (e.code == auth_error.lockedOut ||
          e.code == auth_error.permanentlyLockedOut) {
        return BiometricAuthOutcome.lockedOut;
      }
      if (e.code == auth_error.notAvailable ||
          e.code == auth_error.notEnrolled ||
          e.code == auth_error.passcodeNotSet) {
        return BiometricAuthOutcome.unavailable;
      }
      return BiometricAuthOutcome.failed;
    } catch (e) {
      // Any other error from the plugin/OS must not wedge the lock screen -
      // fall through to the PIN.
      AppLogger.error('Biometric auth error', e);
      return BiometricAuthOutcome.unavailable;
    }
  }

  /// The encrypting lock's vault, in the same storage.
  VaultSlotService get _vault => VaultSlotService(_secureStorage);

  /// Set a PIN (stored as Argon2id hash with random salt).
  ///
  /// Format: `base64(salt):base64(hash)`. With the encrypting lock on there is
  /// none: the vault's PIN slot is what the PIN is checked against
  /// ([verifyPin]).
  Future<void> setPin(String pin) async {
    if (await _vault.isEnabled()) {
      await _secureStorage.delete(key: _pinHashKey);
    } else {
      await _secureStorage.write(key: _pinHashKey, value: await _hashPin(pin));
    }
    // A fresh PIN starts with a clean brute-force slate. Setting a PIN is
    // itself gated (first setup, or the current-PIN step in PinSetupScreen),
    // so this cannot be used to launder a lockout - but WITHOUT it, a lockout
    // earned against the OLD PIN kept rejecting the correct NEW PIN, which
    // surfaced as a bogus "PIN is not correct" right after changing it.
    _failedAttempts = 0;
    _lockoutUntil = null;
    _lockoutStateLoaded = true;
    await _persistLockoutState();
    AppLogger.info('Security PIN set');
  }

  /// Keeps [pin]'s hash for the app lock while the vault is still on, just
  /// before the encrypting lock is turned off: the vault goes next, and the
  /// PIN is then checked against this hash. Written first, so that the app
  /// stopped in between opens with the PIN (the vault went first, and an app
  /// stopped before the hash was written refused every PIN).
  Future<void> keepPinForVaultOff(String pin) async {
    await _secureStorage.write(key: _pinHashKey, value: await _hashPin(pin));
  }

  /// Verify a PIN against the stored hash.
  ///
  /// Includes brute-force protection: after [_maxAttempts] consecutive
  /// failures, further attempts are blocked for an escalating duration.
  /// Lockout state is persisted to secure storage so that restarting the
  /// app does not bypass the lockout.
  Future<bool> verifyPin(String pin) async {
    // Load persisted lockout state before checking
    await _loadLockoutState();

    // Enforce lockout
    if (isLockedOut) {
      AppLogger.warning(
        'PIN verify rejected - locked out for $remainingLockoutSeconds s',
      );
      return false;
    }

    final stored = await _secureStorage.read(key: _pinHashKey);
    bool success;

    if (await _vault.isEnabled()) {
      // With the encrypting lock on, the PIN is checked by opening the vault's
      // own PIN slot, at what a guess costs there (64 MB of Argon2id on a
      // computer). A hash kept beside it, at 4 MB, let a copy of the storage
      // give the PIN up sixteen times sooner, and the PIN then opened the
      // vault (found in a security review of the client); one
      // left from before goes once the PIN is right.
      try {
        await _vault.unlockVaultKey(pin: pin);
        success = true;
        if (stored != null) await _secureStorage.delete(key: _pinHashKey);
      } on VaultLockedException {
        success = false;
      }
    } else if (stored == null) {
      return false;
    } else if (stored.contains(':')) {
      // New Argon2id format: salt_b64:hash_b64
      success = await _verifyArgon2Pin(pin, stored);
    } else {
      // Legacy unsalted SHA-256 format - verify then migrate
      success = _verifyLegacySha256Pin(pin, stored);
      if (success) {
        // Migrate to Argon2id on successful legacy verification
        final newHash = await _hashPin(pin);
        await _secureStorage.write(key: _pinHashKey, value: newHash);
        AppLogger.info('PIN hash migrated from SHA-256 to Argon2id');
      }
    }

    if (success) {
      _failedAttempts = 0;
      _lockoutUntil = null;
      await _persistLockoutState();
    } else {
      _failedAttempts++;
      _applyLockoutIfNeeded();
      await _persistLockoutState();
      AppLogger.warning(
        'PIN verify failed (attempt $_failedAttempts)',
      );
    }

    return success;
  }

  /// Whether a PIN has been configured: its hash, or the encrypting lock's
  /// vault, which always has a PIN slot.
  Future<bool> hasPinConfigured() async {
    final stored = await _secureStorage.read(key: _pinHashKey);
    return stored != null || await _vault.isEnabled();
  }

  /// The encrypting lock was just turned on: the PIN is checked against its
  /// vault from now on, and no hash of it is kept beside it ([verifyPin]).
  Future<void> pinKeptByVault() => _secureStorage.delete(key: _pinHashKey);

  /// Get the current lock method.
  Future<SecurityLockMethod> getLockMethod() async {
    final value = await _secureStorage.read(key: _lockMethodKey);
    if (value == null) return SecurityLockMethod.none;
    return SecurityLockMethod.values.firstWhere(
      (m) => m.name == value,
      orElse: () => SecurityLockMethod.none,
    );
  }

  /// Set the lock method.
  Future<void> setLockMethod(SecurityLockMethod method) async {
    await _secureStorage.write(key: _lockMethodKey, value: method.name);
    AppLogger.info('Security lock method set to ${method.name}');
  }

  /// Get auto-lock timeout in minutes. 0 = lock immediately, negative = never.
  /// The default is platform-specific: desktop sessions are long-lived and sit
  /// behind an OS login, so 10 minutes; mobile is more exposed, so 1 minute.
  Future<int> getAutoLockTimeout() async {
    final value = await _secureStorage.read(key: _autoLockTimeoutKey);
    final fallback = isDesktopPlatform ? 10 : 1;
    return value != null ? int.tryParse(value) ?? fallback : fallback;
  }

  /// Set auto-lock timeout in minutes.
  Future<void> setAutoLockTimeout(int minutes) async {
    await _secureStorage.write(
        key: _autoLockTimeoutKey, value: minutes.toString());
  }

  /// "Lock when idle" (3.0): minutes without a key press or click
  /// after which the app locks even while it is in front; 0 when off (the
  /// default).
  Future<int> getIdleLockMinutes() async {
    final value = int.tryParse(await _secureStorage.read(key: _idleLockKey) ?? '');
    return value != null && value > 0 ? value : 0;
  }

  /// Set "Lock when idle" to [minutes] (0 turns it off).
  Future<void> setIdleLockMinutes(int minutes) async {
    if (minutes <= 0) {
      await _secureStorage.delete(key: _idleLockKey);
    } else {
      await _secureStorage.write(key: _idleLockKey, value: '$minutes');
    }
  }

  /// Remove all security lock configuration.
  Future<void> clearLock() async {
    await _secureStorage.delete(key: _pinHashKey);
    await _secureStorage.delete(key: _lockMethodKey);
    await _secureStorage.delete(key: _autoLockTimeoutKey);
    await Future.wait([_idleLockKey, _lockWithComputerKey].map((key) => _secureStorage.delete(key: key)));
    _failedAttempts = 0;
    _lockoutUntil = null;
    await _persistLockoutState();
    AppLogger.info('Security lock cleared');
  }

  /// Clear the brute-force lockout (attempt count + timer) without touching the
  /// PIN. Used after a recovery-key unlock, where the user has proven ownership
  /// by another factor and should not inherit the failed-PIN lockout.
  Future<void> resetLockout() async {
    _failedAttempts = 0;
    _lockoutUntil = null;
    _lockoutStateLoaded = true;
    await _persistLockoutState();
    AppLogger.info('Security lockout reset (recovery)');
  }

  // ── Lockout state persistence ────────────────────────────────────

  /// Load persisted lockout state from secure storage.
  ///
  /// Called lazily before the first lockout check. Expired lockouts
  /// are cleared automatically on load.
  Future<void> _loadLockoutState() async {
    if (_lockoutStateLoaded) return;

    final attemptsStr = await _secureStorage.read(key: _failedAttemptsKey);
    _failedAttempts = int.tryParse(attemptsStr ?? '') ?? 0;

    final lockoutStr = await _secureStorage.read(key: _lockoutUntilKey);
    if (lockoutStr != null) {
      _lockoutUntil = DateTime.tryParse(lockoutStr);
      // Clear expired lockout timer but preserve failed attempt count
      // so escalating lockouts continue (10→30s, 15→60s, 20→300s).
      if (_lockoutUntil != null && DateTime.now().isAfter(_lockoutUntil!)) {
        _lockoutUntil = null;
        // Do NOT reset _failedAttempts - keeps escalation intact
        await _persistLockoutState();
      }
    }

    _lockoutStateLoaded = true;
  }

  /// Persist lockout state to secure storage.
  Future<void> _persistLockoutState() async {
    await _secureStorage.write(
      key: _failedAttemptsKey,
      value: _failedAttempts.toString(),
    );
    if (_lockoutUntil != null) {
      await _secureStorage.write(
        key: _lockoutUntilKey,
        value: _lockoutUntil!.toIso8601String(),
      );
    } else {
      await _secureStorage.delete(key: _lockoutUntilKey);
    }
  }

  // ── Private helpers ───────────────────────────────────────────────

  /// Hash a PIN with Argon2id and a random 16-byte salt.
  ///
  /// Returns `base64(salt):base64(hash)`.
  Future<String> _hashPin(String pin) async {
    final rng = Random.secure();
    final salt = List<int>.generate(16, (_) => rng.nextInt(256));

    final argon2 = _pinArgon2();

    final result = await argon2.deriveKey(
      secretKey: SecretKey(utf8.encode(pin)),
      nonce: salt,
    );

    final hashBytes = await result.extractBytes();
    final saltB64 = base64Encode(salt);
    final hashB64 = base64Encode(hashBytes);

    return '$saltB64:$hashB64';
  }

  /// Argon2id parameters used for PIN hashing.
  ///
  /// 4 MB / 4 iter / 2 parallel - measured to take ~120-180 ms on a
  /// 2019-era mid-range Android. Tuned to be slow enough to defeat
  /// offline brute force on a 4-digit PIN while still feeling instant
  /// to the user. Higher memory was tried (16 MB) but caused jank on
  /// low-RAM devices and OOM on a few Android Go targets.
  Argon2id _pinArgon2() {
    return Argon2id(
      memory: 4096, // 4 MB
      iterations: 4,
      parallelism: 2,
      hashLength: 32,
    );
  }

  /// Verify a PIN against the Argon2id `salt_b64:hash_b64` stored value.
  Future<bool> _verifyArgon2Pin(String pin, String stored) async {
    final parts = stored.split(':');
    if (parts.length != 2) return false;

    final salt = base64Decode(parts[0]);
    final expectedHash = base64Decode(parts[1]);

    final argon2 = _pinArgon2();

    final result = await argon2.deriveKey(
      secretKey: SecretKey(utf8.encode(pin)),
      nonce: salt,
    );

    final derivedHash = await result.extractBytes();

    // Constant-time comparison to prevent timing attacks
    if (derivedHash.length != expectedHash.length) return false;
    var diff = 0;
    for (var i = 0; i < derivedHash.length; i++) {
      diff |= derivedHash[i] ^ expectedHash[i];
    }
    return diff == 0;
  }

  /// Verify a PIN against the legacy unsalted SHA-256 hex string.
  ///
  /// Used only for backward compatibility with PINs set before the
  /// Argon2id migration. On successful verification the caller
  /// re-hashes the PIN with Argon2id and overwrites the stored value.
  bool _verifyLegacySha256Pin(String pin, String storedHex) {
    final bytes = utf8.encode(pin);
    final digest = hash_lib.sha256.convert(bytes).toString();
    if (digest.length != storedHex.length) return false;
    var diff = 0;
    for (var i = 0; i < digest.length; i++) {
      diff |= digest.codeUnitAt(i) ^ storedHex.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Apply escalating lockout after repeated failures.
  ///
  /// - 5 failures → 30 seconds
  /// - 15 failures → 60 seconds
  /// - 20+ failures → 300 seconds (5 minutes)
  void _applyLockoutIfNeeded() {
    if (_failedAttempts < _maxAttempts) return;

    final int lockoutSeconds;
    if (_failedAttempts >= 20) {
      lockoutSeconds = 300;
    } else if (_failedAttempts >= 15) {
      lockoutSeconds = 60;
    } else {
      lockoutSeconds = 30;
    }

    _lockoutUntil = DateTime.now().add(Duration(seconds: lockoutSeconds));
    AppLogger.warning(
      'PIN lockout activated for $lockoutSeconds s '
      'after $_failedAttempts failed attempts',
    );
  }

  // ── Lock when the computer locks ─────────────────────────────────
  // (Kept below the rest, so that no line docs/whitepaper/claims.yml cites
  // moves.)

  static const _lockWithComputerKey = 'security_lock_with_computer';

  /// "Lock when the computer locks" (a security experience
  /// review): on a computer, the app locks
  /// when the computer locks or sleeps. On unless turned off, so it comes
  /// with the app lock, and on again with a new one ([clearLock] forgets it);
  /// only "off" is kept.
  Future<bool> getLockWithComputer() async => await _secureStorage.read(key: _lockWithComputerKey) != 'off';

  /// Turn "Lock when the computer locks" on or off.
  Future<void> setLockWithComputer(bool on) async {
    if (on) {
      await _secureStorage.delete(key: _lockWithComputerKey);
    } else {
      await _secureStorage.write(key: _lockWithComputerKey, value: 'off');
    }
  }

  // ── What the lock screen says of the wait (4.0) ──────────────────
  // (Below the rest too, for the same reason.)

  /// The wait, in seconds, that the [failures]th wrong PIN in a row starts: none
  /// before the [maxAttempts]th, then 30, 60 from the fifteenth and 300 from the
  /// twentieth, as [_applyLockoutIfNeeded] has it. The lock screen says how long
  /// the next wait will be from it; test/services/security_lock_wait_test.dart
  /// holds the two together.
  static int waitAfter(int failures) {
    if (failures < _maxAttempts) return 0;
    if (failures >= 20) return 300;
    if (failures >= 15) return 60;
    return 30;
  }
}
