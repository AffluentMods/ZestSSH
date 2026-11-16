import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/services/recovery_key_service.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/utils/type_name.dart';

/// A slot's unlock secret kind. Any one slot unlocks the same vault.
enum VaultSlotType { pin, master, recovery }

VaultSlotType? _slotTypeFromName(String s) => switch (s) {
      'pin' => VaultSlotType.pin,
      'master' => VaultSlotType.master,
      'recovery' => VaultSlotType.recovery,
      _ => null,
    };

String _slotTypeName(VaultSlotType t) => switch (t) {
      VaultSlotType.pin => 'pin',
      VaultSlotType.master => 'master',
      VaultSlotType.recovery => 'recovery',
    };

/// Thrown when no provided secret opens any slot (wrong PIN / master password /
/// recovery key), or when the vault is missing/corrupt.
class VaultLockedException implements Exception, HasTypeName {
  const VaultLockedException(this.message);
  final String message;
  @override
  String toString() => 'VaultLockedException: $message';

  @override
  String get typeName => 'VaultLockedException';
}

/// One key slot: a salt + KDF params + a blob = AES-GCM(KDF(secret, salt),
/// vaultKey). Self-describing so a slot's cost can be bumped without stranding
/// the others (same principle as the sync argon2Params carry-forward).
class _VaultSlot {
  _VaultSlot(this.type, this.salt, this.kdf, this.blob);
  final VaultSlotType type;
  final Uint8List salt;
  final Map<String, dynamic> kdf;
  final Uint8List blob;

  Map<String, dynamic> toJson() => {
        'type': _slotTypeName(type),
        'salt': base64Encode(salt),
        'kdf': kdf,
        'blob': base64Encode(blob),
      };

  static _VaultSlot? fromJson(Map<String, dynamic> j) {
    final type = _slotTypeFromName(j['type'] as String? ?? '');
    if (type == null) return null;
    return _VaultSlot(
      type,
      base64Decode(j['salt'] as String),
      Map<String, dynamic>.from(j['kdf'] as Map? ?? const {}),
      base64Decode(j['blob'] as String),
    );
  }
}

/// The encrypting-app-lock vault (1.8).
///
/// Three-layer indirection, the same shape as the cloud-sync DEK design:
///
///   dbKey (64-hex SQLCipher key)  --AES-GCM(vaultKey)-->  vault_wrapped_db_key
///   vaultKey (random 256-bit)     --AES-GCM(KEK_slot)-->  one blob per slot
///   KEK_slot                      = Argon2id(secret, salt_slot)
///
/// Any slot (PIN, master password, ZEST-XXXX recovery key) unwraps the SAME
/// random vaultKey, which unwraps the SAME DB key, so every unlock path opens
/// the same database. Changing/adding/removing a slot only re-wraps the 32-byte
/// vaultKey, never the database.
///
/// This class is pure orchestration over existing primitives: every
/// cryptographic step is a [SyncService] / [RecoveryKeyService] call (Argon2id,
/// AES-256-GCM). It writes no cipher, KDF, nonce, or MAC of its own. The
/// "encrypting lock OFF" state is the legacy plaintext `zestssh_db_encryption_key`
/// in secure storage, exactly as before; enabling the lock deletes that and
/// replaces it with the wrapped copy + slots.
class VaultSlotService {
  VaultSlotService(this._secure);

  final FlutterSecureStorage _secure;

  /// Secure-storage ids. `dbKeyId` is intentionally the SAME id database.dart
  /// uses for the plaintext key, so enable/disable swaps the two in place.
  static const String wrappedDbKeyId = 'vault_wrapped_db_key';
  static const String slotsId = 'vault_slots';
  static const String dbKeyId = 'zestssh_db_encryption_key';

  /// Secure-storage options for the pre-container boot decision
  /// ([reconcileBootLockState]). These MUST stay identical to
  /// `secureStorageProvider` (core_providers.dart) and database.dart's
  /// `_secureStorage`, or this would read a different backing store than the
  /// one that actually holds the keys.
  static const FlutterSecureStorage bootStorage = deviceKeychain;

  /// Decide the boot mode from the ACTUAL secure-storage contents instead of a
  /// cached prefs flag, and self-heal a half-finished enable/disable. Called
  /// once at startup (main.dart) before the database is opened.
  ///
  /// Returns true ONLY for a COMPLETE vault with the plaintext DB key removed
  /// (wrapped key + slots present, plaintext absent) - the single state where
  /// the database can only be opened by unwrapping the vault. Every reachable
  /// interrupted enable or disable still has the plaintext key on disk (enable
  /// deletes it LAST; disable restores it FIRST), so those are reported as
  /// lock-OFF and their orphan vault entries are dropped. This makes the two
  /// two-write operations crash-safe: a mistimed process kill can never funnel
  /// the user into the data-wiping "reset" error screen (interrupted enable) or
  /// a slot-less permanent lockout (interrupted disable).
  static Future<bool> reconcileBootLockState() =>
      VaultSlotService(bootStorage).reconcileAndIsLocked();

  /// See [reconcileBootLockState]. Instance form for tests / provider use.
  Future<bool> reconcileAndIsLocked() async {
    final slots = await _secure.read(key: slotsId);
    final wrapped = await _secure.read(key: wrappedDbKeyId);
    final hwWrapped = await _secure.read(key: hwWrappedDbKeyId);
    final plaintext = await _secure.read(key: dbKeyId);

    // The wrapped-DB-key blob lives in exactly ONE of the two ids: plain (PIN
    // only) or hardware-wrapped (PIN + Keystore/Secure-Enclave). Either form
    // completes the vault. The hw enable/disable swap uses the same
    // write-new-copy-first ordering as enable/disable, so mid-swap both may
    // briefly exist - still a complete vault.
    final completeVault = slots != null && (wrapped != null || hwWrapped != null);
    if (completeVault && plaintext == null) {
      return true; // genuine lock-ON: only the vault can open the database
    }
    // Clean up orphan vault entries ONLY when the plaintext key is present, so
    // dropping the redundant vault can never remove the sole key holder. This
    // covers every reachable interrupted enable/disable (all keep the plaintext
    // key on disk); a partial vault with NO plaintext key is unreachable given
    // the write orderings, and is left intact for manual recovery rather than
    // deleted.
    if (plaintext != null &&
        (slots != null || wrapped != null || hwWrapped != null)) {
      await _secure.delete(key: wrappedDbKeyId);
      await _secure.delete(key: hwWrappedDbKeyId);
      await _secure.delete(key: slotsId);
    }
    return false;
  }

  /// PIN KDF for a NEW vault slot. Params are stored PER SLOT (see [_buildSlot]
  /// / [_VaultSlot.toJson]) and read back at unlock, so changing this only
  /// affects vaults created from now on - existing vaults carry their own
  /// params and keep unlocking.
  ///
  /// Mobile stays light (4 MB): a low-entropy PIN there is protected by the
  /// secure-hardware rate limit (hardware binding) and the lock-service
  /// lockout, so a heavy KDF only hurts unlock latency.
  ///
  /// Desktop has NO hardware rate limit on the PIN (TPM binding is opt-in and
  /// separate), so an attacker who copies the raw files can brute-force the PIN
  /// offline with no throttle. A memory-hard 64 MB Argon2id raises that offline
  /// cost by ~16x per guess (GPU parallelism is bounded by memory bandwidth)
  /// while an interactive unlock still lands well under a second. The direct
  /// package:cryptography Argon2id is used (SyncService.deriveKey's 64 MiB floor
  /// makes it unsuitable for the mobile 4 MB case) - not new crypto.
  static Map<String, dynamic> get _pinKdf => {
        'algo': 'argon2id',
        'memory': isDesktopPlatform ? 65536 : 4096,
        'iterations': 4,
        'parallelism': 2,
      };

  /// True when the encrypting lock is active (a vault exists).
  Future<bool> isEnabled() async =>
      (await _secure.read(key: slotsId)) != null;

  Future<SecretKey> _deriveKek(
    VaultSlotType type,
    String secret,
    Uint8List salt,
    Map<String, dynamic> kdf,
  ) async {
    switch (type) {
      case VaultSlotType.pin:
        final argon = Argon2id(
          memory: (kdf['memory'] as num?)?.toInt() ?? 4096,
          iterations: (kdf['iterations'] as num?)?.toInt() ?? 4,
          parallelism: (kdf['parallelism'] as num?)?.toInt() ?? 2,
          hashLength: 32,
        );
        return argon.deriveKey(
          secretKey: SecretKey(utf8.encode(secret)),
          nonce: salt,
        );
      case VaultSlotType.master:
        return SyncService.deriveKey(secret, salt, params: kdf);
      case VaultSlotType.recovery:
        return RecoveryKeyService.deriveRecoveryMek(secret, salt);
    }
  }

  Future<_VaultSlot> _buildSlot(
    VaultSlotType type,
    String secret,
    SecretKey vaultKey, {
    Uint8List? salt,
    Map<String, dynamic>? kdf,
  }) async {
    final s = salt ?? SyncService.generateSalt();
    final params = kdf ??
        (type == VaultSlotType.pin ? _pinKdf : SyncService.argon2Params);
    final kek = await _deriveKek(type, secret, s, params);
    final blob = await SyncService.wrapDek(vaultKey, kek);
    return _VaultSlot(type, s, params, blob);
  }

  Future<List<_VaultSlot>> _readSlots() async {
    final raw = await _secure.read(key: slotsId);
    if (raw == null) return [];
    final j = jsonDecode(raw) as Map<String, dynamic>;
    final list = (j['slots'] as List?) ?? const [];
    final out = <_VaultSlot>[];
    for (final e in list) {
      final slot = _VaultSlot.fromJson(Map<String, dynamic>.from(e as Map));
      if (slot != null) out.add(slot);
    }
    return out;
  }

  Future<void> _writeSlots(List<_VaultSlot> slots) async {
    final j = {
      'schema': 1,
      'slots': [for (final s in slots) s.toJson()],
    };
    await _secure.write(key: slotsId, value: jsonEncode(j));
  }

  /// Which slot kinds exist (so the recovery screen can offer the right paths).
  Future<Set<VaultSlotType>> slotTypes() async =>
      {for (final s in await _readSlots()) s.type};

  /// Turn ON the encrypting lock. Wraps [dbKeyHex] under a fresh random vault
  /// key, creates a PIN slot and a master-password slot (and a recovery slot
  /// when [recoveryKey] + [recoverySalt] are supplied), then DELETES the
  /// plaintext DB key so it no longer exists on disk.
  Future<void> enableLock({
    required String dbKeyHex,
    String? pin,
    String? masterPassword,
    String? recoveryKey,
    Uint8List? recoverySalt,
  }) async {
    final vaultKey = SyncService.generateDek();

    final wrappedDbKey =
        await SyncService.wrapDek(SecretKey(utf8.encode(dbKeyHex)), vaultKey);

    final slots = <_VaultSlot>[];
    if (pin != null) {
      slots.add(await _buildSlot(VaultSlotType.pin, pin, vaultKey));
    }
    if (masterPassword != null) {
      slots.add(await _buildSlot(VaultSlotType.master, masterPassword, vaultKey));
    }
    if (recoveryKey != null && recoverySalt != null) {
      slots.add(await _buildSlot(
        VaultSlotType.recovery,
        recoveryKey,
        vaultKey,
        salt: recoverySalt,
      ));
    }
    if (slots.isEmpty) {
      throw ArgumentError('enableLock requires at least one secret');
    }

    // Write the wrapped copy + slots FIRST, then remove the plaintext key, so a
    // crash mid-enable can never leave the DB unrecoverable (the plaintext key
    // survives until the wrapped path is fully in place).
    await _secure.write(
        key: wrappedDbKeyId, value: base64Encode(wrappedDbKey));
    await _writeSlots(slots);
    await _secure.delete(key: dbKeyId);
  }

  /// The slots of the lock with profiles (ProfileVault.turnOn): a PIN slot
  /// opening [vaultKey]. It wraps each profile's key on its own, so no profile's
  /// key is written here.
  Future<void> writeNewSlots({required SecretKey vaultKey, required String pin}) async {
    await _writeSlots([await _buildSlot(VaultSlotType.pin, pin, vaultKey)]);
  }

  /// Unwrap the vault key with ANY provided secret. Tries each supplied secret
  /// against its slot(s); the first whose AES-GCM tag authenticates wins (the
  /// unwrap success IS the correctness check). Throws [VaultLockedException] if
  /// none match.
  Future<SecretKey> unlockVaultKey({
    String? pin,
    String? masterPassword,
    String? recoveryKey,
  }) async {
    final slots = await _readSlots();
    if (slots.isEmpty) {
      throw const VaultLockedException('No vault slots');
    }

    final attempts = <MapEntry<VaultSlotType, String>>[
      if (pin != null) MapEntry(VaultSlotType.pin, pin),
      if (masterPassword != null) MapEntry(VaultSlotType.master, masterPassword),
      if (recoveryKey != null) MapEntry(VaultSlotType.recovery, recoveryKey),
    ];
    if (attempts.isEmpty) {
      throw const VaultLockedException('No secret provided');
    }

    for (final a in attempts) {
      for (final slot in slots.where((s) => s.type == a.key)) {
        try {
          final kek = await _deriveKek(a.key, a.value, slot.salt, slot.kdf);
          return await SyncService.unwrapDek(slot.blob, kek);
        } on SyncDecryptionException {
          // Wrong secret for this slot; try the next.
        }
      }
    }
    throw const VaultLockedException('Wrong PIN, password, or recovery key');
  }

  /// Given the unlocked [vaultKey], recover the 64-hex SQLCipher DB key.
  /// [hardwareKey] is REQUIRED when the hardware layer is on (the wrapped-DB-key
  /// blob is additionally wrapped under the device's Keystore/Secure-Enclave
  /// key); it must come from HardwareVaultService.read(), which shows the
  /// device-auth prompt.
  Future<String> unwrapDbKeyHex(SecretKey vaultKey,
      {List<int>? hardwareKey}) async {
    // Read the hardware-wrapped blob FIRST so it is authoritative whenever the
    // hardware layer is on. If a crash between enableHardwareLayer's two writes
    // left a stale plain wrappedDbKeyId alongside the hw blob, the old
    // "plain first" order would silently take the PIN-only path while
    // isHardwareBound() reports true - so the TPM/Enclave would not actually be
    // required. Preferring the hw blob keeps the two consistent.
    final hwRaw = await _secure.read(key: hwWrappedDbKeyId);
    final String raw;
    if (hwRaw != null) {
      if (hardwareKey == null) {
        throw const VaultLockedException(
            'Hardware-backed encryption is on: device authentication required');
      }
      final inner = await SyncService.unwrapDek(
          base64Decode(hwRaw), SecretKey(hardwareKey));
      raw = base64Encode(await inner.extractBytes());
    } else {
      final plain = await _secure.read(key: wrappedDbKeyId);
      if (plain == null) {
        throw const VaultLockedException('No wrapped DB key');
      }
      raw = plain;
    }
    final keyBytes =
        await (await SyncService.unwrapDek(base64Decode(raw), vaultKey))
            .extractBytes();
    return utf8.decode(keyBytes);
  }

  /// Convenience: unlock the vault and return the DB key hex in one call.
  Future<String> unlockDbKeyHex({
    String? pin,
    String? masterPassword,
    String? recoveryKey,
    List<int>? hardwareKey,
  }) async {
    final vaultKey = await unlockVaultKey(
      pin: pin,
      masterPassword: masterPassword,
      recoveryKey: recoveryKey,
    );
    return unwrapDbKeyHex(vaultKey, hardwareKey: hardwareKey);
  }

  // ── Hardware-backed layer (opt-in, mobile) ────────────────────────

  /// Secure-storage id for the hardware-wrapped copy of the wrapped-DB-key
  /// blob: AES-GCM(hardwareKey, wrappedDbKeyBlob). When present, the plain
  /// [wrappedDbKeyId] entry is absent and unlocking additionally requires the
  /// Keystore/Secure-Enclave key (device-auth gated, non-exportable) - so an
  /// extracted storage image cannot be brute-forced offline.
  static const String hwWrappedDbKeyId = 'vault_hw_wrapped_db_key';

  /// True when the hardware layer is active. With profiles it is a device's
  /// matter, kept apart from any one profile's wrap, which a signed-out profile
  /// no longer has.
  Future<bool> isHardwareBound() async => Profiles.on
      ? (await _secure.read(key: 'vault2_hw_on')) != null
      : (await _secure.read(key: hwWrappedDbKeyId)) != null;

  /// Turn ON the hardware layer: wrap the existing wrapped-DB-key blob under
  /// [hardwareKey]. Crash-safe ordering: the hw-wrapped copy is written FIRST,
  /// then the plain wrapped copy is deleted - at every interruption point at
  /// least one decryptable copy of the DB key chain exists.
  Future<void> enableHardwareLayer(List<int> hardwareKey) async {
    final raw = await _secure.read(key: wrappedDbKeyId);
    if (raw == null) {
      throw const VaultLockedException(
          'Encrypting lock is not enabled (no wrapped DB key)');
    }
    final wrapped = await SyncService.wrapDek(
        SecretKey(base64Decode(raw)), SecretKey(hardwareKey));
    await _secure.write(key: hwWrappedDbKeyId, value: base64Encode(wrapped));
    await _secure.delete(key: wrappedDbKeyId);
  }

  /// Turn OFF the hardware layer: restore the plain wrapped-DB-key blob (PIN
  /// wrap only). Same crash-safe ordering (write the restored copy first).
  Future<void> disableHardwareLayer(List<int> hardwareKey) async {
    final hwRaw = await _secure.read(key: hwWrappedDbKeyId);
    if (hwRaw == null) return; // already off
    final inner = await SyncService.unwrapDek(
        base64Decode(hwRaw), SecretKey(hardwareKey));
    await _secure.write(
        key: wrappedDbKeyId, value: base64Encode(await inner.extractBytes()));
    await _secure.delete(key: hwWrappedDbKeyId);
  }

  /// Turn OFF the encrypting lock: re-store the plaintext DB key and drop the
  /// vault. [dbKeyHex] must be the key just recovered via [unwrapDbKeyHex] so
  /// the DB stays openable. Plaintext is restored FIRST, then the vault is
  /// removed, so a crash never strands the data.
  Future<void> disableLock(String dbKeyHex) async {
    await _secure.write(key: dbKeyId, value: dbKeyHex);
    await _secure.delete(key: wrappedDbKeyId);
    await _secure.delete(key: hwWrappedDbKeyId);
    await _secure.delete(key: slotsId);
  }

  /// Re-wrap the PIN slot with a [newPin] (the vault key must already be
  /// unlocked via the old PIN / master password / recovery key).
  Future<void> changePin(SecretKey vaultKey, String newPin) async {
    final slots = await _readSlots();
    slots.removeWhere((s) => s.type == VaultSlotType.pin);
    slots.insert(0, await _buildSlot(VaultSlotType.pin, newPin, vaultKey));
    await _writeSlots(slots);
  }

  /// Re-wrap the master-password slot with [newMasterPassword].
  Future<void> changeMasterPassword(
      SecretKey vaultKey, String newMasterPassword) async {
    final slots = await _readSlots();
    slots.removeWhere((s) => s.type == VaultSlotType.master);
    slots.add(await _buildSlot(
        VaultSlotType.master, newMasterPassword, vaultKey));
    await _writeSlots(slots);
  }

  /// Add (or replace) the ZEST-XXXX recovery slot.
  Future<void> setRecoverySlot(
      SecretKey vaultKey, String recoveryKey, Uint8List recoverySalt) async {
    final slots = await _readSlots();
    slots.removeWhere((s) => s.type == VaultSlotType.recovery);
    slots.add(await _buildSlot(
      VaultSlotType.recovery,
      recoveryKey,
      vaultKey,
      salt: recoverySalt,
    ));
    await _writeSlots(slots);
  }
}
