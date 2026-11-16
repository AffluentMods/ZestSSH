import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/type_name.dart';

/// E2E encrypted Cloud Sync **crypto core**.
///
/// This is the provider-agnostic half of cloud sync: key derivation, DEK
/// wrapping, blob encrypt/decrypt, and verification hashes. It performs NO
/// network I/O - the transport (talking to a server or a bring-your-own
/// store) lives behind [SyncBackend]. Splitting the two lets the exact same
/// crypto guard every backend (hosted, self-hosted, WebDAV, S3, Drive).
///
/// Architecture (DEK indirection):
///
///   Password ──Argon2id──► MEK ──AES-GCM──► wrappedDEK_password
///                                                ↓
///   Recovery ──Argon2id──► KEK ──AES-GCM──► wrappedDEK_recovery
///                                                ↓
///   random DEK ─────────────────AES-GCM──► encrypted blob
///
/// The DEK (Data Encryption Key) is a random 256-bit key that encrypts
/// the actual data blob. It is wrapped (encrypted) separately by both
/// the password-derived MEK and the recovery-derived KEK. Password
/// change only re-wraps the DEK - no data re-encryption needed.
/// Recovery unwraps the DEK via the recovery KEK.
///
/// No backend ever sees plaintext data, the DEK, the MEK, or the recovery
/// key - only the already-encrypted blob and the (also-safe) wrapped DEKs.
class SyncService {
  // ── Argon2id Parameter Versioning ────────────────────────────

  /// Current parameter set version. Stored alongside the salt so future
  /// clients can bump parameters without breaking existing users' ability to
  /// derive their key - the params a blob was made with travel WITH the blob
  /// (see [argon2Params] carry-forward in the backends), and derivation always
  /// uses the pulled/stored params, never this default, for existing accounts.
  static const argon2Version = 2;
  static const _argon2Memory = 131072; // 128 MB (v2; was 64 MB in v1)
  static const _argon2Iterations = 3;
  static const _argon2Parallelism = 4;
  static const _argon2HashLength = 32; // 256 bits

  // Absolute MINIMUM acceptable KDF parameters (NOT the recommended values
  // above). A server returning anything weaker is refused as a downgrade.
  // Kept deliberately separate from the recommended constants so that
  // raising those in a future release can never retroactively lock users
  // out of blobs derived with today's (still strong) parameters.
  // Floor = the WEAKEST parameter set this app has ever written (the v1
  // legacy profile below), not the generic OWASP minimum. Accepting
  // 19456/2/1 left a downgrade window: the parameters arrive with the
  // pulled blob, so a hostile or compromised store could serve the weakest
  // accepted set plus a salt of its choosing and make every subsequent
  // password derivation ~7x cheaper to attack offline. Nothing legitimate
  // is below the v1 set, so this floor is backward-safe.
  static const _argon2MinMemory = 65536; // 64 MiB - the v1 profile
  static const _argon2MinIterations = 3;
  static const _argon2MinParallelism = 4;

  /// Hard cap on a pulled sync response body. Real sync data is a few KB
  /// to low MB even with many private keys; anything larger is a rogue/
  /// compromised store trying to OOM the client on the unattended
  /// launch/resume pull. Checked before the blob is decoded.
  static const maxBlobBytes = 16 * 1024 * 1024; // 16 MB

  /// Argon2id parameters for the current version, sent with every push
  /// so the store can return them on pull for correct key derivation.
  static Map<String, dynamic> get argon2Params => {
        'version': argon2Version,
        'memory': _argon2Memory,
        'iterations': _argon2Iterations,
        'parallelism': _argon2Parallelism,
      };

  /// The v1 parameter set (64 MB). An account that has sync credentials but no
  /// locally-persisted params was necessarily set up BEFORE the default was
  /// raised to v2 - so its wrapped DEK was derived with these. Using this as
  /// the fallback (instead of the current default) lets the default change
  /// without a migration: a data-only push from such an account still sends
  /// the params that actually match its wrapped DEK.
  static Map<String, dynamic> get legacyArgon2Params => const {
        'version': 1,
        'memory': 65536,
        'iterations': 3,
        'parallelism': 4,
      };

  // ── Key Derivation ────────────────────────────────────────────

  /// Derive the 256-bit Master Encryption Key from password + salt.
  ///
  /// When [params] is provided (e.g. from a store pull response),
  /// those parameters are used instead of the current defaults - this
  /// allows blobs encrypted with older parameter sets to be decrypted.
  static Future<SecretKey> deriveKey(
    String password,
    Uint8List salt, {
    Map<String, dynamic>? params,
  }) async {
    // Coerce each param to int without ever throwing on a hostile/corrupt
    // store value: accept a num (jsonDecode yields double for `65536.0`), a
    // quoted numeric string (`"65536"`), and fall back to the current default
    // for anything else (null, a bool, an object, unparseable text). A wrong
    // fallback still fails closed downstream - the derived key won't unwrap
    // the DEK - so this never mis-derives a legitimate account's key.
    int intParam(Object? v, int fallback) {
      if (v is num) return v.toInt();
      if (v is String) {
        final parsed = int.tryParse(v.trim());
        if (parsed != null) return parsed;
      }
      return fallback;
    }

    final memory = intParam(params?['memory'], _argon2Memory);
    final iterations = intParam(params?['iterations'], _argon2Iterations);
    final parallelism = intParam(params?['parallelism'], _argon2Parallelism);

    // Harden against a malicious/compromised store manipulating the KDF
    // parameters it returns on pull.
    // (1) Never accept parameters WEAKER than the current published minimums
    //     - that would be a KDF-downgrade oracle yielding an easier-to-brute
    //     key. There are no legacy versions with weaker-than-current params,
    //     so a hard floor is backward-safe (older/stronger blobs still work).
    // (2) Cap ALL THREE cost dimensions so a huge value can't wedge the client
    //     during a user-initiated join/recovery/change-password derive:
    //     memory (KiB) -> OOM, iterations -> CPU spin, parallelism -> lane
    //     blow-up. The ceilings are far above any legitimate setting.
    if (memory < _argon2MinMemory ||
        iterations < _argon2MinIterations ||
        parallelism < _argon2MinParallelism) {
      throw const FormatException(
          'Refusing weaker-than-minimum Argon2id parameters from server');
    }
    const maxArgon2MemoryKib = 1024 * 1024; // 1 GiB
    const maxArgon2Iterations = 32;
    const maxArgon2Parallelism = 16;
    if (memory > maxArgon2MemoryKib ||
        iterations > maxArgon2Iterations ||
        parallelism > maxArgon2Parallelism) {
      throw const FormatException(
          'Argon2id parameters from server exceed the safe maximum');
    }

    final argon2 = Argon2id(
      memory: memory,
      iterations: iterations,
      parallelism: parallelism,
      hashLength: _argon2HashLength,
    );

    return argon2.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
  }

  /// Generate a random 32-byte salt.
  static Uint8List generateSalt() {
    final rng = Random.secure();
    final salt = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      salt[i] = rng.nextInt(256);
    }
    return salt;
  }

  /// Compute a verification hash from a key using HKDF + SHA-256.
  ///
  /// The HKDF step with a domain-specific info string ensures the
  /// verification hash is cryptographically independent from the key,
  /// even though it is derived from it. A server stores this hash to
  /// verify the user's identity without ever seeing the key itself.
  static Future<Uint8List> computeVerificationHash(SecretKey key) async {
    final keyBytes = await key.extractBytes();
    final hkdf = Hkdf(hmac: Hmac(Sha256()), outputLength: 32);
    final verificationKey = await hkdf.deriveKey(
      secretKey: SecretKey(keyBytes),
      nonce: Uint8List(0),
      info: utf8.encode('zestssh-sync-verification'),
    );
    final derivedBytes = await verificationKey.extractBytes();
    final digest = hash.sha256.convert(derivedBytes);
    return Uint8List.fromList(digest.bytes);
  }

  /// Compute HKDF + SHA-256 verification hash using the recovery-
  /// specific domain string to ensure cryptographic independence from
  /// the password verification path.
  static Future<Uint8List> computeRecoveryVerificationHash(
    SecretKey key,
  ) async {
    final keyBytes = await key.extractBytes();
    final hkdf = Hkdf(hmac: Hmac(Sha256()), outputLength: 32);
    final verificationKey = await hkdf.deriveKey(
      secretKey: SecretKey(keyBytes),
      nonce: Uint8List(0),
      info: utf8.encode('zestssh-recovery-verification'),
    );
    final derivedBytes = await verificationKey.extractBytes();
    final digest = hash.sha256.convert(derivedBytes);
    return Uint8List.fromList(digest.bytes);
  }

  // ── DEK Operations ────────────────────────────────────────────

  /// Generate a random 256-bit Data Encryption Key.
  ///
  /// The DEK is the only key that touches user data. It is generated
  /// once during sync setup and never changes - password and recovery
  /// key changes only re-wrap the DEK, avoiding full data re-encryption.
  static SecretKey generateDek() {
    final rng = Random.secure();
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = rng.nextInt(256);
    }
    return SecretKey(List<int>.from(bytes));
  }

  /// Wrap (encrypt) the DEK with a wrapping key (MEK or recovery KEK).
  ///
  /// Returns: nonce(12) + tag(16) + ciphertext(32) = 60 bytes.
  static Future<Uint8List> wrapDek(
    SecretKey dek,
    SecretKey wrappingKey,
  ) async {
    final dekBytes = await dek.extractBytes();
    final aesGcm = AesGcm.with256bits();
    final secretBox = await aesGcm.encrypt(
      dekBytes,
      secretKey: wrappingKey,
    );
    final package = BytesBuilder();
    package.add(secretBox.nonce); // 12 bytes
    package.add(secretBox.mac.bytes); // 16 bytes
    package.add(secretBox.cipherText); // 32 bytes
    return package.toBytes();
  }

  /// Unwrap (decrypt) the DEK using the wrapping key.
  ///
  /// Throws [SyncDecryptionException] if the wrapping key is wrong
  /// or the wrapped DEK has been tampered with.
  static Future<SecretKey> unwrapDek(
    Uint8List wrappedDek,
    SecretKey wrappingKey,
  ) async {
    if (wrappedDek.length < 60) {
      throw SyncDecryptionException(gl10n.syncDataDamaged,
          detail: 'Wrapped DEK is too short - data may be corrupted');
    }
    final nonce = wrappedDek.sublist(0, 12);
    final mac = Mac(wrappedDek.sublist(12, 28));
    final cipherText = wrappedDek.sublist(28);
    final aesGcm = AesGcm.with256bits();
    try {
      final dekBytes = await aesGcm.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: mac),
        secretKey: wrappingKey,
      );
      return SecretKey(dekBytes);
    } catch (e) {
      AppLogger.error('DEK unwrap failed', e);
      throw SyncDecryptionException(gl10n.syncDataNotOpened,
          detail: 'Failed to unwrap data key - wrong password or data tampered.');
    }
  }

  // ── Encryption / Decryption ───────────────────────────────────

  /// Encrypt data: JSON → zlib compress → AES-256-GCM.
  ///
  /// Returns the encrypted package: salt(32) + IV(12) + tag(16) + ciphertext.
  /// The [salt] is embedded for portability.
  static Future<Uint8List> encrypt(
    Map<String, dynamic> data,
    SecretKey key,
    Uint8List salt,
  ) async {
    final json = jsonEncode(data);
    final compressed = zlib.encode(utf8.encode(json));
    final aesGcm = AesGcm.with256bits();
    final secretBox = await aesGcm.encrypt(
      compressed,
      secretKey: key,
    );
    final package = BytesBuilder();
    package.add(salt);
    package.add(secretBox.nonce); // 12 bytes
    package.add(secretBox.mac.bytes); // 16 bytes
    package.add(secretBox.cipherText);
    return package.toBytes();
  }

  /// Decrypt package → decompress → parse JSON.
  ///
  /// Throws [SyncDecryptionException] if the key is wrong or the
  /// data has been tampered with (GCM auth tag mismatch).
  static Future<Map<String, dynamic>> decrypt(
    Uint8List package,
    SecretKey key,
  ) async {
    if (package.length < 60) {
      throw SyncDecryptionException(gl10n.syncDataDamaged,
          detail: 'Encrypted data is too short - data may be corrupted');
    }
    // A large package is opened in a worker isolate: the decrypt, the
    // inflate (up to 64 MB) and the JSON decode of a blob near the 16 MB cap
    // held the screen still for as long as they took (found in a code
    // audit). A small one, the usual, stays here: starting a worker costs
    // more than it saves. The words of a failure are put in the person's
    // language here, where the app's language is known.
    final _Opened opened;
    if (package.length >= decryptOffIsolateFrom) {
      final keyBytes = await key.extractBytes();
      debugDecryptsOffIsolate++;
      opened = await Isolate.run(() => _open(package, SecretKey(keyBytes)));
    } else {
      opened = await _open(package, key);
    }
    final data = opened.data;
    if (data != null) return data;
    throw switch (opened.fault) {
      _OpenFault.tooLarge => SyncDecryptionException(gl10n.syncDataTooLargeToOpen,
          detail: 'Decompressed sync data exceeds the safe maximum - refusing to load.'),
      // Do NOT interpolate the error here: after a successful GCM decrypt this
      // only fires on a post-decrypt parse error (e.g. a FormatException whose
      // toString embeds a fragment of the DECRYPTED plaintext, which can hold
      // credential material). Include only the error TYPE so no plaintext can
      // reach the exception string, the UI, or the app log.
      // (The check of the encryption failing is the wrong key or data
      // that was changed; anything after it, data that is no sync data.)
      final fault => SyncDecryptionException(
          fault == _OpenFault.notOpened ? gl10n.syncDataNotOpened : gl10n.syncDataDamaged,
          detail: opened.detail,
        ),
    };
  }

  /// From this size on, [decrypt] opens a package in a worker isolate.
  @visibleForTesting
  static int decryptOffIsolateFrom = 256 * 1024;

  /// How many packages [decrypt] opened in a worker isolate (for tests).
  @visibleForTesting
  static int debugDecryptsOffIsolate = 0;

  /// Decrypts, inflates and decodes [package]; on whichever isolate calls it.
  /// No language here: a worker isolate does not know the app's.
  static Future<_Opened> _open(Uint8List package, SecretKey key) async {
    final nonce = package.sublist(32, 44);
    final mac = Mac(package.sublist(44, 60));
    final cipherText = package.sublist(60);
    final aesGcm = AesGcm.with256bits();
    final secretBox = SecretBox(cipherText, nonce: nonce, mac: mac);
    try {
      final compressed = await aesGcm.decrypt(secretBox, secretKey: key);
      // Bounded inflate: even though the ciphertext is GCM-authenticated, a
      // legitimate DEK holder (or a future format change) could ship a
      // zlib-bomb blob. Inflating with `zlib.decode` has no output ceiling and
      // would OOM the client. Stream-inflate and abort the moment cumulative
      // output crosses the cap.
      final json = utf8.decode(_boundedInflate(compressed));
      return (data: jsonDecode(json) as Map<String, dynamic>, fault: null, detail: '');
    } on _InflateTooLarge {
      return (data: null, fault: _OpenFault.tooLarge, detail: '');
    } catch (e) {
      // The detail is English and names only the error's type, so it is
      // written here, in whichever isolate opened the package.
      return (
        data: null,
        fault: e is SecretBoxAuthenticationError ? _OpenFault.notOpened : _OpenFault.damaged,
        detail: 'Decryption failed - sync data may be corrupted or tampered with. '
            'If this persists, try restoring from a backup. (${errorKind(e)})',
      );
    }
  }

  /// Max decompressed sync payload. Real data is a few KB-low MB even with many
  /// private keys; 64 MB is a generous ceiling far above any legitimate blob.
  static const _maxDecompressedBytes = 64 * 1024 * 1024;

  /// Inflate [compressed], throwing [SyncDecryptionException] if the running
  /// output total exceeds [_maxDecompressedBytes] (decompression-bomb guard).
  static Uint8List _boundedInflate(List<int> compressed) {
    final sink = _BoundedByteSink(_maxDecompressedBytes);
    final inflater = zlib.decoder.startChunkedConversion(sink);
    inflater.add(compressed);
    inflater.close();
    return sink.bytes;
  }
}

/// Why [SyncService._open] could not open a package.
enum _OpenFault { notOpened, damaged, tooLarge }

/// What [SyncService._open] made of a package: its data, or why not, with a
/// detail that names the error's type (never its text, which can hold
/// decrypted plaintext).
typedef _Opened = ({Map<String, dynamic>? data, _OpenFault? fault, String detail});

/// The inflated data crossed [SyncService._maxDecompressedBytes].
class _InflateTooLarge implements Exception, HasTypeName {
  const _InflateTooLarge();

  @override
  String get typeName => '_InflateTooLarge';

  @override
  String toString() => 'Decompressed sync data exceeds the safe maximum';
}

/// Output sink that accumulates inflated bytes but aborts once a hard cap is
/// crossed, so a decompression bomb can't exhaust memory.
class _BoundedByteSink extends ByteConversionSink {
  _BoundedByteSink(this.limit);
  final int limit;
  final BytesBuilder _b = BytesBuilder(copy: false);
  int _n = 0;

  void _guard(int added) {
    _n += added;
    if (_n > limit) throw const _InflateTooLarge();
  }

  @override
  void add(List<int> chunk) {
    _guard(chunk.length);
    _b.add(chunk);
  }

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    _guard(end - start);
    _b.add(chunk.sublist(start, end));
    if (isLast) close();
  }

  @override
  void close() {}

  Uint8List get bytes => _b.toBytes();
}

// ── Data classes ───────────────────────────────────────────────

class SyncPullResult {
  final Uint8List encryptedData;
  final Uint8List salt;
  final int version;
  final DateTime updatedAt;

  /// DEK wrapped with the password-derived MEK.
  final Uint8List? wrappedDekPassword;

  /// DEK wrapped with the recovery-derived KEK.
  final Uint8List? wrappedDekRecovery;

  /// Salt used for recovery key derivation.
  final Uint8List? recoverySalt;

  /// Argon2id parameters used when the blob was created.
  final Map<String, dynamic>? argon2Params;

  const SyncPullResult({
    required this.encryptedData,
    required this.salt,
    required this.version,
    required this.updatedAt,
    this.wrappedDekPassword,
    this.wrappedDekRecovery,
    this.recoverySalt,
    this.argon2Params,
  });
}

/// Result of pulling and decrypting with a recovery key.
///
/// Contains the unwrapped DEK and recovery KEK so the caller can
/// re-wrap the DEK with a new password-derived MEK.
class RecoveryPullResult {
  final SyncPullResult pullResult;
  final SecretKey dek;
  final SecretKey recoveryKek;

  const RecoveryPullResult({
    required this.pullResult,
    required this.dek,
    required this.recoveryKek,
  });
}

class SyncStatus {
  final bool hasData;
  final int version;
  final int blobSize;
  final DateTime? updatedAt;
  final String? lastDevice;

  /// The server's own clock at the moment of this status call (from the HTTP
  /// Date header where the backend provides one; null otherwise). Used to detect
  /// a skewed LOCAL clock, which would silently corrupt newest-wins conflict
  /// resolution (a device whose clock runs fast wins every conflict forever).
  final DateTime? serverTime;

  /// Whether the store holds the data key wrapped under a recovery key
  /// (3.0). Null when the store does not say (an older server).
  final bool? hasRecovery;

  const SyncStatus({
    required this.hasData,
    required this.version,
    required this.blobSize,
    this.updatedAt,
    this.lastDevice,
    this.serverTime,
    this.hasRecovery,
  });
}

class SyncException implements Exception, HasTypeName {
  /// Plain-language, user-safe message. Surfaces should show THIS, not the
  /// raw exception - no stack traces, class names, or socket text.
  final String message;

  /// Optional raw technical text (the underlying exception, an HTTP body, a
  /// status line) kept aside for a "Copy details" affordance. Null when
  /// [message] already tells the whole story. Never shown as the headline.
  final String? detail;

  const SyncException(this.message, {this.detail});
  @override
  String toString() => 'SyncException: $message';

  @override
  String get typeName => 'SyncException';
}

/// Thrown when decryption fails - indicates wrong key, data corruption,
/// or tampering (GCM authentication tag mismatch).
///
/// The UI should surface this distinctly from a generic sync error,
/// e.g. "Your sync data appears corrupted or tampered with."
class SyncDecryptionException extends SyncException {
  const SyncDecryptionException(super.message, {super.detail});

  @override
  String get typeName => 'SyncDecryptionException';
}

/// Thrown when a bring-your-own store has no sync object AND this device has
/// no key material to write a recoverable one (i.e. the store was emptied out
/// of band). The user must re-run sync setup - auto-sync surfaces this rather
/// than silently writing an unrecoverable, password-less blob.
class SyncSetupRequiredException extends SyncException {
  const SyncSetupRequiredException(super.message, {super.detail});

  @override
  String get typeName => 'SyncSetupRequiredException';
}

/// Thrown when this device's sync keys are not the account's any more: the
/// hosted server refuses a push because the salt and verification value this
/// device sends are not the account's, or this device cannot read what the
/// store holds. The sync password was changed, or sync was set up again, on
/// another device. No retry can succeed until the account's password is
/// proved on this device, which the account page's "Sync now" does, so
/// auto-sync pauses, as it does whenever setup is required, instead of
/// trying the same thing on every cycle.
class SyncKeysMismatchException extends SyncSetupRequiredException {
  const SyncKeysMismatchException(super.message);

  @override
  String get typeName => 'SyncKeysMismatchException';
}

/// Thrown when ZestSSH Cloud says the account's cloud sync was reset (its
/// 426 with the code SYNC_WAS_RESET): the cloud copy this device's keys were
/// for is out of use, and no new one has been set up yet. Nothing on the
/// device is touched. Sync is set up again on the device that holds the
/// data, and the others join that; until then auto-sync pauses, as it does
/// whenever setup is required.
class SyncWasResetException extends SyncSetupRequiredException {
  const SyncWasResetException(super.message);

  @override
  String get typeName => 'SyncWasResetException';
}

/// Thrown when ZestSSH Cloud keeps no copy for this account: its storage
/// comes with Juiced (the Cloud Sync purchase), and the account has none
/// (its 403 with the code ENTITLEMENT_REQUIRED, or its entitlement check
/// saying so). Sync itself is free with storage of the person's own, so it
/// is said as that, never as a server that could not be reached; no retry
/// can succeed until the storage is changed or Juiced is bought, so
/// auto-sync pauses, as it does whenever setup is required.
class SyncHostingRequiredException extends SyncSetupRequiredException {
  const SyncHostingRequiredException(super.message);

  @override
  String get typeName => 'SyncHostingRequiredException';
}

/// Thrown when ZestSSH Cloud refuses this device because the account syncs
/// on as many devices as one person may (7: Juiced, or a seat of a team;
/// none for a member of a Business team), its 403 with the code
/// cloud-device-limit. Signing out a device no longer used lets this one
/// sync; until then no retry can succeed, so auto-sync pauses, as it does
/// whenever setup is required. Storage of the person's own counts nothing.
class SyncCloudDeviceLimitException extends SyncSetupRequiredException {
  const SyncCloudDeviceLimitException(super.message);

  @override
  String get typeName => 'SyncCloudDeviceLimitException';
}

/// Thrown when a recovery key is not the store's: the store said so, or the
/// key does not open what the store holds. It is the one failure of a
/// restore that is about the key. Whatever else stops one (the store not
/// reached, too many tries, a fault of the server's) says nothing of the
/// key and is said as what it is; until this was held, each of those told
/// the person that their recovery key did not work.
class SyncRecoveryKeyWrongException extends SyncException {
  const SyncRecoveryKeyWrongException() : super('Invalid recovery key');

  @override
  String get typeName => 'SyncRecoveryKeyWrongException';
}

/// Thrown when a store rejects a push due to a version mismatch.
class SyncConflictException extends SyncException {
  final int serverVersion;
  final int expectedVersion;

  /// What a store of the person's own answered when it refused a write
  /// that asked for a condition ("S3 PUT: HTTP 412 PreconditionFailed"),
  /// where that is what happened; null where the versions were compared.
  final String? storeAnswer;

  /// The HTTP status of [storeAnswer] (409, 412), where the store said one.
  final int? storeStatus;

  /// Whether a write that went without a condition was read back and found
  /// written over (DumbStoreSyncBackend).
  final bool readBack;

  const SyncConflictException({
    required this.serverVersion,
    required this.expectedVersion,
  })  : storeAnswer = null,
        storeStatus = null,
        readBack = false,
        super('Version conflict: server is at v$serverVersion, '
            'expected v$expectedVersion. Pull and retry.');

  /// A write that went without a condition, to a store that does not take
  /// one, was read back and another device's was there: holding
  /// [serverVersion], where this push wrote over [expectedVersion].
  const SyncConflictException.readBack({
    required this.serverVersion,
    required this.expectedVersion,
  })  : storeAnswer = null,
        storeStatus = null,
        readBack = true,
        super('Written over by another device: the store holds v$serverVersion '
            'where this push wrote over v$expectedVersion. Pull and retry.');

  /// A store refused a write that asked for a condition, answering
  /// [storeAnswer]: with the versions a read after it found, where one was
  /// made (a negative [serverVersion] where none was, or what is there could
  /// not be read). Its message, kept for Copy details, is the store's own
  /// answer: it was "server is at v-1, expected v-1", which said nothing
  /// (3.3, a Cloudflare R2 store refusing every update).
  const SyncConflictException.storeRefused(
    String this.storeAnswer, {
    this.storeStatus,
    this.serverVersion = -1,
    this.expectedVersion = -1,
  })  : readBack = false,
        super(serverVersion < 0
            ? 'The store refused the write: $storeAnswer.'
            : 'The store refused the write: $storeAnswer. It holds '
                'v$serverVersion, this push expected v$expectedVersion.');

  @override
  String get typeName => 'SyncConflictException';
}
