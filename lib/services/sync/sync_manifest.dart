import 'dart:convert';
import 'dart:typed_data';

import 'package:zestssh/services/sync_service.dart' show SyncException;
import 'package:zestssh/l10n/l10n_global.dart';

/// The single self-contained document a [DumbStoreSyncBackend] stores.
///
/// A dumb store (WebDAV / S3 / Drive) has no columns and no server-side
/// logic, so everything the hosted server would keep in a row - the
/// encrypted blob AND the metadata needed to derive keys and unwrap the DEK
/// on another device - is bundled into this one JSON file and stored as a
/// single object.
///
/// Everything in here is safe to expose to the store operator: the blob and
/// the wrapped DEKs are AES-256-GCM ciphertext, and the hashes are one-way.
/// The DEK, MEK, master password, and recovery key are never present.
///
/// ## Trust model on an untrusted store
///
/// The ciphertext fields are authenticated (GCM), so tampering is caught on
/// decrypt/unwrap. The plaintext metadata (`version`, `salt`,
/// `argon2_params`) is NOT authenticated by this envelope:
///
/// * A tampered `argon2_params` is caught by the min/max floor+ceiling guard
///   in [SyncService.deriveKey].
/// * A tampered `salt` just yields a wrong key → the GCM auth tag fails →
///   [SyncDecryptionException]. No data is lost (local data is untouched).
/// * A rolled-back `version` (the store serves an old copy) is a rollback
///   attack inherent to any untrusted store, and a `version` set higher hides
///   it. The blob counts for itself inside its encryption, and a device given
///   one below the highest count it saw merges it as a store that went back
///   and says so (SyncDataService.compareStoreCount); restore is merge-only
///   (nothing is ever deleted locally). A brand new device has seen nothing,
///   and takes what it is given. This is the same guarantee the hosted server
///   gives against a malicious operator.
class SyncManifest {
  /// On-disk schema version for the envelope itself (NOT the sync data
  /// version). Bump only if the field layout changes.
  static const currentManifestVersion = 1;

  /// Monotonic sync data version - the optimistic-lock counter. Mirrors the
  /// hosted server's `version` column.
  final int version;

  final DateTime updatedAt;
  final String? deviceId;

  /// Password-KDF salt (Argon2id nonce for the MEK).
  final Uint8List salt;

  final Map<String, dynamic> argon2Params;

  /// The AES-256-GCM encrypted data blob (salt(32)+iv(12)+tag(16)+ct).
  final Uint8List encryptedData;

  /// MEK-derived verification hash. Stored for parity with the server so a
  /// future server-side check is possible; dumb stores verify by unwrapping.
  final Uint8List? passwordHash;

  final Uint8List? wrappedDekPassword;
  final Uint8List? wrappedDekRecovery;
  final Uint8List? recoverySalt;
  final Uint8List? recoveryHash;

  const SyncManifest({
    required this.version,
    required this.updatedAt,
    required this.salt,
    required this.argon2Params,
    required this.encryptedData,
    this.deviceId,
    this.passwordHash,
    this.wrappedDekPassword,
    this.wrappedDekRecovery,
    this.recoverySalt,
    this.recoveryHash,
  });

  Map<String, dynamic> toJson() => {
        'manifest_version': currentManifestVersion,
        'app': 'zestssh',
        'version': version,
        'updated_at': updatedAt.toUtc().toIso8601String(),
        if (deviceId != null) 'device_id': deviceId,
        'salt': base64Encode(salt),
        'argon2_params': argon2Params,
        'encrypted_data': base64Encode(encryptedData),
        if (passwordHash != null) 'password_hash': base64Encode(passwordHash!),
        if (wrappedDekPassword != null)
          'wrapped_dek_password': base64Encode(wrappedDekPassword!),
        if (wrappedDekRecovery != null)
          'wrapped_dek_recovery': base64Encode(wrappedDekRecovery!),
        if (recoverySalt != null)
          'recovery_salt': base64Encode(recoverySalt!),
        if (recoveryHash != null)
          'recovery_hash': base64Encode(recoveryHash!),
      };

  Uint8List toBytes() =>
      Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  /// Parse a manifest from stored bytes. Throws [SyncException] on anything
  /// malformed - never a raw TypeError/FormatException - so callers can
  /// surface a clean message and leave local data untouched.
  static SyncManifest fromBytes(Uint8List bytes) {
    final Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw _unreadable('Sync manifest is not a JSON object');
      }
      json = decoded;
    } on SyncException {
      rethrow;
    } catch (_) {
      throw _unreadable('Sync data at this location is not a valid ZestSSH manifest');
    }

    // Guard against pointing sync at an unrelated file.
    final app = json['app'];
    if (app != null && app != 'zestssh') {
      throw _unreadable('This file was not written by ZestSSH cloud sync');
    }

    final mv = (json['manifest_version'] as num?)?.toInt() ?? 1;
    if (mv > currentManifestVersion) {
      throw SyncException(gl10n.syncStoreDataNewer, detail: 'Sync data written by a newer version (manifest v$mv)');
    }

    Uint8List? b64(String key) {
      final v = json[key];
      if (v == null) return null;
      if (v is! String) {
        throw _unreadable('Sync manifest field "$key" is malformed');
      }
      try {
        return Uint8List.fromList(base64Decode(v));
      } catch (_) {
        throw _unreadable('Sync manifest field "$key" is not valid base64');
      }
    }

    final salt = b64('salt');
    final encryptedData = b64('encrypted_data');
    if (salt == null || encryptedData == null) {
      throw _unreadable('Sync manifest is missing required fields');
    }

    final argon2Params = json['argon2_params'];
    // Validate the optimistic-lock counter: a non-numeric value yields a clean
    // SyncException (not a raw TypeError), and a negative / absurdly-large
    // version is rejected so a single hostile response can't wedge sync by
    // pinning the counter at, e.g., INT64_MAX (every subsequent push then
    // 409s forever). Rollback (a lower-than-seen version) is handled upstream
    // by highest-seen tracking + merge-only restore, per this class's docs.
    final versionRaw = json['version'];
    if (versionRaw != null && versionRaw is! num) {
      throw _unreadable('Sync manifest "version" is not a number');
    }
    final version = (versionRaw as num?)?.toInt() ?? 0;
    if (version < 0 || version > 0x7fffffff) {
      throw _unreadable('Sync manifest "version" is out of range');
    }
    final updatedAtRaw = json['updated_at'];
    final updatedAt = updatedAtRaw is String
        ? (DateTime.tryParse(updatedAtRaw) ?? DateTime.now())
        : DateTime.now();

    return SyncManifest(
      version: version,
      updatedAt: updatedAt,
      deviceId: json['device_id'] as String?,
      salt: salt,
      argon2Params: argon2Params is Map<String, dynamic>
          ? argon2Params
          : <String, dynamic>{},
      encryptedData: encryptedData,
      passwordHash: b64('password_hash'),
      wrappedDekPassword: b64('wrapped_dek_password'),
      wrappedDekRecovery: b64('wrapped_dek_recovery'),
      recoverySalt: b64('recovery_salt'),
      recoveryHash: b64('recovery_hash'),
    );
  }
}

/// The sync data in a store that cannot be read (damaged, or not ZestSSH's),
/// said in the person's language, with what was wrong with it ([what], in
/// English) kept for the details (3.0, 16 October 2026: said in English, in
/// every language). Data a newer version wrote is said as that, apart.
SyncException _unreadable(String what) => SyncException(gl10n.syncStoreDataUnreadable, detail: what);
