import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/recovery_key_service.dart';
import 'package:zestssh/services/sync/sync_manifest.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/services/sync/sync_failure.dart';
import 'package:zestssh/l10n/l10n_global.dart';

/// A single object read from a dumb store: its bytes plus the store-native
/// concurrency token (ETag / revision id), if the store provides one.
class RawObject {
  final Uint8List bytes;
  final String? etag;
  const RawObject(this.bytes, this.etag);
}

/// Base class for every bring-your-own storage backend (WebDAV, S3, Google
/// Drive). It implements the ENTIRE [SyncBackend] contract - including
/// optimistic-lock CAS, DEK carry-forward, and client-side password/recovery
/// verification - on top of just three store primitives that each subclass
/// supplies: [readObject], [writeObject], [deleteObject].
///
/// Why this exists: dumb stores have no server logic, so all the sync
/// bookkeeping that the hosted server does in SQL must happen here on the
/// client, once, shared across every store. A new store type is ~100 lines
/// of HTTP, not a re-implementation of the sync protocol.
abstract class DumbStoreSyncBackend implements SyncBackend {
  /// Filename/key of the single manifest object within the store's ZestSSH
  /// folder. Subclasses decide the containing path/bucket/folder.
  static const manifestObjectName = 'zestssh-sync.json';

  @override
  bool get requiresEntitlement => false;

  /// Release any long-lived transport resources (the reused [http.Client]).
  /// Overridden by concrete stores; wired to `ref.onDispose` in
  /// `syncBackendProvider` so a backend swap doesn't leak socket pools.
  void dispose() {}

  // ── Store primitives (implemented per store) ──────────────────────

  /// Read the manifest object. Returns null if it does not exist.
  ///
  /// MUST refuse to buffer more than [SyncService.maxBlobBytes] * 2 bytes
  /// (the manifest is base64+JSON over the blob, ~1.4×) to bound memory
  /// against a hostile store - throw [SyncException] if the object is larger.
  Future<RawObject?> readObject();

  /// Write [bytes] as the manifest object.
  ///
  /// * [ifMatchEtag] non-null → the write MUST fail if the store's current
  ///   ETag differs (compare-and-swap). Translate a precondition failure
  ///   into [SyncConflictException].
  /// * [ifAbsent] true → the write MUST fail if the object already exists
  ///   (create-only). Translate the conflict into [SyncConflictException].
  ///
  /// Returns the new ETag if the store provides one.
  Future<String?> writeObject(
    Uint8List bytes, {
    String? ifMatchEtag,
    bool ifAbsent = false,
  });

  /// Delete the manifest object. A missing object is treated as success.
  Future<void> deleteObject();

  @override
  Future<void> checkConnection();

  // ── SyncBackend (shared implementation) ───────────────────────────

  @override
  Future<void> verifyEntitlement() async {
    // Bring-your-own stores are free - nothing to gate.
  }

  @override
  Future<SyncStatus> getStatus() async {
    final raw = await readObject();
    if (raw == null) {
      return const SyncStatus(hasData: false, version: 0, blobSize: 0);
    }
    final m = SyncManifest.fromBytes(raw.bytes);
    return SyncStatus(
      hasData: true,
      version: m.version,
      blobSize: m.encryptedData.length,
      updatedAt: m.updatedAt,
      lastDevice: m.deviceId,
      hasRecovery: m.wrappedDekRecovery != null,
    );
  }

  @override
  Future<SyncPullResult> pull() async {
    final raw = await readObject();
    if (raw == null) {
      throw SyncFailure.storeEmpty;
    }
    final m = SyncManifest.fromBytes(raw.bytes);
    if (m.encryptedData.length > SyncService.maxBlobBytes) {
      throw SyncFailure.storeTooLarge('Sync blob too large (${m.encryptedData.length} bytes), refused');
    }
    return SyncPullResult(
      encryptedData: m.encryptedData,
      salt: m.salt,
      version: m.version,
      updatedAt: m.updatedAt,
      wrappedDekPassword: m.wrappedDekPassword,
      wrappedDekRecovery: m.wrappedDekRecovery,
      recoverySalt: m.recoverySalt,
      // A blob with no params is pre-v2 material (64 MB); resolve it to the
      // legacy set here so every downstream derive/push treats it as 64 MB,
      // never the current 128 MB default.
      argon2Params: m.argon2Params.isEmpty
          ? SyncService.legacyArgon2Params
          : m.argon2Params,
    );
  }

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
    // Accepted for interface parity but unused: a dumb store has no server-side
    // write-verification - it guards writes with optimistic-lock / ETag CAS, so
    // there is no changed-password-hash to authorize.
    Uint8List? authorizeHash,
    // Also unused here (see [authorizeHash]): a dumb store has no server-side
    // write-verification to satisfy on a recovery-reset either.
    Uint8List? authorizeRecoveryHash,
  }) async {
    final encrypted = await SyncService.encrypt(data, dek, salt);
    if (encrypted.length > SyncService.maxBlobBytes) {
      throw SyncFailure.storeTooLarge('Encrypted sync data too large to upload (${encrypted.length} bytes)');
    }

    // Read the current object so we can (a) enforce the optimistic lock,
    // (b) compute the next version, and (c) carry forward wrapped-DEK
    // material that this push does not itself supply - mirroring the hosted
    // server's "retain existing wrapped DEKs on a normal data sync".
    final current = await readObject();
    final SyncManifest? cur =
        current == null ? null : SyncManifest.fromBytes(current.bytes);
    final curVersion = cur?.version ?? 0;

    // A push that says it creates ("Set up sync", or a first push to a store
    // that was empty) is never written over a vault that is there: another
    // device made it since the caller looked. The write below asks the store
    // to refuse that as well (only if nothing is there), which closes the
    // moment between this read and the write, but not every store honours
    // it; this check does not depend on the store.
    if (createOnly && cur != null) {
      throw SyncConflictException(
        serverVersion: curVersion,
        expectedVersion: expectedVersion ?? 0,
      );
    }

    if (expectedVersion != null) {
      // Optimistic lock: the store must still be at the version this push was
      // based on. This is the CAS backstop used even when the store has no
      // native ETag; when it does have one, [writeObject]'s ifMatch enforces
      // it a second time against the read→write race window.
      if (cur == null || curVersion != expectedVersion) {
        throw SyncConflictException(
          serverVersion: curVersion,
          expectedVersion: expectedVersion,
        );
      }
    }

    final effectiveWrappedPassword =
        wrappedDekPassword ?? cur?.wrappedDekPassword;

    // Never create a manifest that has no password-wrapped DEK - the result
    // is unrecoverable (a second device can't unwrap the DEK from the master
    // password, and the recovery key is gone too). This guards the case where
    // auto-sync tries to RE-create a store object that was deleted out of band
    // (it supplies no wrapped-DEK material and there is nothing to carry
    // forward). Setup/join always supply it, so this only trips on the bad
    // recreate path - surfacing it instead of silently writing a dead blob.
    if (cur == null && effectiveWrappedPassword == null) {
      throw SyncSetupRequiredException(gl10n.syncStoreDataMissing,
          detail: 'No sync data in the store, and no wrapped data key to write a recoverable one');
    }

    // Key material follows the wrapped DEK. A key-establishing push (setup, a
    // password change, a recovery reset) supplies a new password-wrapped DEK
    // together with the salt and verification value it was derived with. A
    // data-only push (the background cycle, "Sync now") supplies none and
    // carries the stored salt and verification value forward, like the
    // wrapped DEKs below. Writing a data-only push's own copies let a device
    // whose cached salt went stale (the password was changed on another
    // device) overwrite the account's salt while the new wrapped DEK stayed,
    // so joining with the new password failed.
    final establishesKeys = cur == null || wrappedDekPassword != null;
    final effectiveSalt = establishesKeys ? salt : cur.salt;
    final effectivePasswordHash =
        establishesKeys ? verificationHash : (cur.passwordHash ?? verificationHash);

    final newVersion = curVersion + 1;
    final manifest = SyncManifest(
      version: newVersion,
      updatedAt: DateTime.now().toUtc(),
      deviceId: deviceId,
      salt: effectiveSalt,
      // Params must match the wrapped DEK: use the supplied params (a
      // key-establishing push), else carry forward what's already stored (a
      // data-only sync), else the current default (first-ever push). This is
      // what lets the default Argon2 cost change without stranding accounts.
      argon2Params:
          argon2Params ?? cur?.argon2Params ?? SyncService.argon2Params,
      encryptedData: encrypted,
      passwordHash: effectivePasswordHash,
      wrappedDekPassword: effectiveWrappedPassword,
      wrappedDekRecovery: wrappedDekRecovery ?? cur?.wrappedDekRecovery,
      recoverySalt: recoverySalt ?? cur?.recoverySalt,
      recoveryHash: recoveryHash ?? cur?.recoveryHash,
    );

    // Write mode - the whole point of the CAS here is to never overwrite data
    // this push didn't merge:
    //  * A declared create ([createOnly]) OR no object present → create-only
    //    (If-None-Match). If an object has appeared since we last checked (a
    //    racing first push from another device), the store rejects the write →
    //    SyncConflictException → the caller re-pulls, merges, and retries. This
    //    is what stops the "both devices saw an empty store, second one clobbers
    //    the first" data-loss race.
    //  * Otherwise → compare-and-swap against the exact bytes we just read
    //    (If-Match on the ETag), so a concurrent write between our read and our
    //    write is caught. On stores without ETags this degrades to the
    //    version-compare above (best effort - documented for Google Drive).
    //  * A refused write is read again before anything else (see
    //    [_writeAfterRefusal]).
    //  * A write that goes without the If-Match this store gives a tag for
    //    (it refused one that held, twice) is read back ([_readBack]).
    final bytes = manifest.toBytes();
    final creates = createOnly || cur == null;
    final tag = creates || _ifMatchRefused ? null : current?.etag;
    try {
      if (creates) {
        await writeObject(bytes, ifAbsent: true);
      } else {
        await writeObject(bytes, ifMatchEtag: tag);
      }
      if (!creates && tag == null && current?.etag != null) {
        await _readBack(bytes, expectedVersion: expectedVersion ?? curVersion);
      }
    } on SyncConflictException catch (refused) {
      // (A conflict [_readBack] found is one already: it is not read again.)
      if (refused.readBack) rethrow;
      await _writeAfterRefusal(
        refused,
        bytes,
        read: current,
        creates: creates,
        expectedVersion: expectedVersion ?? curVersion,
      );
    }

    AppLogger.info(
      '${kind.name} sync push complete, version: $newVersion, '
      'blob: ${encrypted.length} bytes',
    );
    return (version: newVersion, blobSize: encrypted.length, updatedAt: manifest.updatedAt);
  }

  /// Whether this store refused an If-Match that held, twice on the same
  /// tag, so that updates to it go without one, each read back (see
  /// [_writeAfterRefusal]). Kept for as long as this backend is, which is as
  /// long as the store's settings are.
  bool _ifMatchRefused = false;

  /// [_ifMatchRefused], for tests.
  @visibleForTesting
  bool get ifMatchDroppedForTest => _ifMatchRefused;

  /// How long a write the store answered 409 waits before it looks again:
  /// the other write in flight has landed by then, or is still in flight.
  @visibleForTesting
  Duration inFlightPause = const Duration(seconds: 1);

  /// The store refused the write of [bytes] that asked for a condition
  /// ([refused]): only over the object this push [read], or, where it
  /// [creates], only where nothing is there. Read the store again to know
  /// why.
  ///
  /// What is there changed: another device wrote in between, a conflict,
  /// said with the version that is there now and what the store answered.
  ///
  /// A 409: another conditional write to the object is in flight at the
  /// store, not there to read yet (AWS S3's ConditionalRequestConflict). It
  /// is given [inFlightPause] before the look, and the condition is never
  /// dropped for it: unchanged, the write is asked again on the tag just
  /// read, and refused again it is a conflict, which the caller settles by
  /// pulling, merging and pushing again. A single refusal dropped the
  /// condition from 739023d8 on, and the write went over the other device's
  /// as it landed (found in a security review).
  ///
  /// A 412 on what is unchanged: the condition held, and the store refused
  /// it. Asked again once, on the tag just read. Refused so a second time,
  /// on the same tag, the store does not take the condition: Cloudflare R2
  /// did that to every update in 3.2.7 ("server is at v-1, expected v-1"),
  /// when it compressed what it sent and made its ETag a weak one (fixed in
  /// S3SyncBackend, which asks for nothing compressed and sends the tag
  /// inside a weak one). The version check in [push] has passed, so the
  /// write goes without the condition, as Google Drive's always has, and is
  /// read back ([_readBack]); later updates to this store do the same.
  Future<void> _writeAfterRefusal(
    SyncConflictException refused,
    Uint8List bytes, {
    required RawObject? read,
    required bool creates,
    required int expectedVersion,
  }) async {
    if (refused.storeStatus == 409) await Future<void>.delayed(inFlightPause);
    final now = await readObject();
    _conflictUnlessUnchanged(refused, read: read, now: now, expectedVersion: expectedVersion);
    try {
      if (creates) {
        await writeObject(bytes, ifAbsent: true);
      } else {
        await writeObject(bytes, ifMatchEtag: now?.etag);
      }
      return;
    } on SyncConflictException catch (again) {
      final after = await readObject();
      _conflictUnlessUnchanged(again, read: read, now: after, expectedVersion: expectedVersion);
      final twice412 = refused.storeStatus == 412 && again.storeStatus == 412;
      final sameTag = creates || (now?.etag != null && after?.etag == now?.etag);
      // (A refusal that says no store answer compared the versions itself,
      // and says so as it is.)
      if (!twice412 || !sameTag) throw again.storeAnswer == null ? again : _conflict(again, after, expectedVersion);
      AppLogger.warning('${kind.name} store refused a write whose condition held, twice on the same tag '
          '(${again.storeAnswer}); writing without the condition and reading it back');
      if (!creates) _ifMatchRefused = true;
      try {
        await writeObject(bytes);
      } on SyncConflictException catch (third) {
        throw _conflict(third, after, expectedVersion);
      }
      await _readBack(bytes, expectedVersion: expectedVersion);
    }
  }

  /// A conflict, where what the store holds ([now]) is not what this push
  /// [read]: another device wrote in between. Said with the version that is
  /// there now and what the store answered ([refused]).
  static void _conflictUnlessUnchanged(
    SyncConflictException refused, {
    required RawObject? read,
    required RawObject? now,
    required int expectedVersion,
  }) {
    final unchanged = now == null ? read == null : read != null && listEquals(now.bytes, read.bytes);
    if (!unchanged) throw _conflict(refused, now, expectedVersion);
  }

  /// The conflict [refused] comes to, with the version [there] holds.
  static SyncConflictException _conflict(SyncConflictException refused, RawObject? there, int expectedVersion) {
    final answer = refused.storeAnswer;
    if (answer == null) {
      return SyncConflictException(serverVersion: _versionIn(there), expectedVersion: expectedVersion);
    }
    return SyncConflictException.storeRefused(answer,
        storeStatus: refused.storeStatus, serverVersion: _versionIn(there), expectedVersion: expectedVersion);
  }

  /// After a write that went without the condition the store would have
  /// been asked for: what is there is read back, and anything other than
  /// [wrote] is another device's write that landed over it, a conflict the
  /// caller settles by pulling, merging and pushing again (it was taken as
  /// written, and that update lost).
  Future<void> _readBack(Uint8List wrote, {required int expectedVersion}) async {
    final there = await readObject();
    if (there != null && listEquals(there.bytes, wrote)) return;
    throw SyncConflictException.readBack(serverVersion: _versionIn(there), expectedVersion: expectedVersion);
  }

  /// The version [raw] holds: 0 where nothing is there, -1 where what is
  /// there cannot be read as sync data.
  static int _versionIn(RawObject? raw) {
    if (raw == null) return 0;
    try {
      return SyncManifest.fromBytes(raw.bytes).version;
    } on SyncException {
      return -1;
    }
  }

  @override
  Future<bool> verifyPassword(SecretKey mek) async {
    final raw = await readObject();
    if (raw == null) {
      throw SyncFailure.storeEmpty;
    }
    final m = SyncManifest.fromBytes(raw.bytes);
    // Legacy MEK-direct format is retired. Every manifest this client writes
    // carries a password-wrapped DEK - the push path (see the guard above)
    // refuses to create one without it, and the BYO backend has done so since
    // it launched in 1.5.41, so a null wrappedDekPassword can only be a
    // pre-indirection blob no ZestSSH client ever produced. Treat it as
    // re-enroll-required rather than silently unwrapping the master key as the
    // data key.
    if (m.wrappedDekPassword == null) {
      throw SyncSetupRequiredException(gl10n.syncStoreOldFormat,
          detail: 'Sync data in the retired format, with no password-wrapped data key');
    }
    try {
      // Unwrapping is the verification: a wrong MEK fails the GCM tag.
      await SyncService.unwrapDek(m.wrappedDekPassword!, mek);
      return true;
    } on SyncDecryptionException {
      return false;
    }
  }

  @override
  Future<RecoveryPullResult> pullWithRecoveryKey(String recoveryKey) async {
    final pullResult = await pull();
    if (pullResult.recoverySalt == null ||
        pullResult.wrappedDekRecovery == null) {
      throw SyncException(gl10n.syncStoreNoRecoveryKey, detail: 'Recovery key has not been configured for this sync store');
    }

    final normalizedKey = RecoveryKeyService.normalize(recoveryKey);
    final recoveryKek = await SyncService.deriveKey(
      normalizedKey,
      Uint8List.fromList(pullResult.recoverySalt!),
      params: pullResult.argon2Params,
    );

    // The unwrap IS the verification - no server round-trip needed.
    final SecretKey dek;
    try {
      dek = await SyncService.unwrapDek(
        pullResult.wrappedDekRecovery!,
        recoveryKek,
      );
    } on SyncDecryptionException {
      throw const SyncRecoveryKeyWrongException();
    }

    return RecoveryPullResult(
      pullResult: pullResult,
      dek: dek,
      recoveryKek: recoveryKek,
    );
  }

  @override
  Future<void> purge(Uint8List verificationHash) async {
    // On a dumb store, possession of the store credentials IS the
    // authorization - there is no server to check the verification hash
    // against. Delete the manifest object.
    await deleteObject();
    AppLogger.info('${kind.name} sync data purged');
  }

  @override
  Future<void> deleteAccount(Uint8List verificationHash) async {
    // No separate account on a dumb store - same as purge.
    await purge(verificationHash);
  }
}
