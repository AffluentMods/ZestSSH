import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:zestssh/services/sync_service.dart'
    show SyncStatus, SyncPullResult, RecoveryPullResult;

/// The kind of storage a [SyncBackend] talks to.
///
/// This is what the user picks in the sync-provider settings. Each value
/// maps to exactly one concrete [SyncBackend] implementation.
enum SyncBackendKind {
  /// The hosted ZestSSH sync server (api.zestssh.com). Paid - entitlement
  /// gated. This is the default for every install.
  zestServer,

  /// A self-hosted server that speaks the ZestSSH sync protocol, reached at
  /// a user-supplied base URL (optionally with a static bearer token instead
  /// of the Firebase/session auth). NOT entitlement gated.
  custom,

  /// Any standards-compliant WebDAV server (Nextcloud, ownCloud, Synology,
  /// mailbox.org, Koofr, a NAS, …). Bring-your-own, free.
  webdav,

  /// Any S3-compatible object store (Cloudflare R2, Backblaze B2, Wasabi, a
  /// self-hosted MinIO, …). Bring-your-own, free.
  s3,

  /// The user's Google Drive (a single file in the hidden app-data folder).
  /// Bring-your-own, free.
  googleDrive,
}

extension SyncBackendKindX on SyncBackendKind {
  /// Stable string used in persisted config JSON. Do NOT reorder the enum
  /// and rely on the index - always serialize via this name.
  String get storageKey => name;

  static SyncBackendKind fromStorageKey(String? key) {
    for (final k in SyncBackendKind.values) {
      if (k.name == key) return k;
    }
    return SyncBackendKind.zestServer;
  }

  /// Human label for the settings picker.
  String get label {
    switch (this) {
      case SyncBackendKind.zestServer:
        return 'ZestSSH Cloud';
      case SyncBackendKind.custom:
        return 'Custom ZestSSH server';
      case SyncBackendKind.webdav:
        return 'WebDAV';
      case SyncBackendKind.s3:
        return 'S3-compatible';
      case SyncBackendKind.googleDrive:
        return 'Google Drive';
    }
  }

  /// Whether this backend is the paid, hosted option. Everything else is a
  /// bring-your-own store the user pays nothing to ZestSSH for.
  bool get isHosted => this == SyncBackendKind.zestServer;
}

/// A pluggable transport + storage target for end-to-end-encrypted cloud
/// sync.
///
/// A [SyncBackend] is ONLY responsible for moving the already-encrypted blob
/// and its (also-safe-to-expose) metadata to and from a store, and for the
/// optimistic-lock bookkeeping around that. It performs NO cryptography of
/// its own beyond calling the shared [SyncService] crypto core - the DEK,
/// MEK, master password, and recovery key never reach a backend and never
/// leave the device.
///
/// The contract deliberately mirrors the original hardcoded server API so
/// that every existing orchestration path (setup / join / manual sync /
/// restore / change-password / purge, plus the [AutoSyncService] cycle)
/// works against ANY backend with only the `SyncService.x()` → `backend.x()`
/// call-site change. In particular:
///
/// * [push] returns `(version, blobSize)` and throws [SyncConflictException]
///   on an optimistic-lock mismatch - the auto-sync 409 retry loop relies on
///   both.
/// * [pull] returns the same [SyncPullResult] every consumer already
///   destructures.
/// * [verifyPassword] returns whether the supplied MEK is the right key.
///   Server-backed backends ask the server; dumb stores verify by attempting
///   to unwrap the DEK client-side (a wrong key fails the GCM auth tag).
abstract class SyncBackend {
  SyncBackendKind get kind;

  /// Short human label shown in the UI (e.g. "ZestSSH Cloud",
  /// "Nextcloud (home)", "Backblaze B2").
  String get displayName;

  /// Whether push/pull require the paid Cloud Sync entitlement. Only the
  /// hosted [SyncBackendKind.zestServer] returns true; bring-your-own stores
  /// are free, so [verifyEntitlement] is a no-op for them.
  bool get requiresEntitlement;

  /// Lightweight probe used by the settings "Test connection" button.
  ///
  /// Succeeds if the store is reachable and the supplied credentials are
  /// accepted. Throws a [SyncException] (with a user-facing message) on
  /// failure. Must NOT create, mutate, or require existing sync data.
  Future<void> checkConnection();

  /// Get sync status without downloading the blob.
  Future<SyncStatus> getStatus();

  /// Pull the encrypted blob + metadata.
  Future<SyncPullResult> pull();

  /// Encrypt [data] with [dek]+[salt] and store it.
  ///
  /// [verificationHash] authenticates the write on server-backed backends
  /// (ignored by dumb stores, where possession of the store credentials is
  /// the authorization). When [wrappedDekPassword]/[wrappedDekRecovery]/
  /// [recoverySalt]/[recoveryHash] are omitted (a normal data sync), the
  /// backend MUST retain whatever it already has stored for those - only a
  /// setup / password-change / recovery-setup supplies fresh ones.
  ///
  /// [expectedVersion] is the optimistic lock: when non-null the write must
  /// fail with [SyncConflictException] if the store is no longer at that
  /// version. When null the write is unconditional (last-writer-wins); the
  /// merge-only restore backstops against data loss.
  ///
  /// [createOnly] declares that the caller believes there is NO existing sync
  /// data (a first setup push, or an auto-sync recreate) and did NOT merge the
  /// store's current contents. Stores that support it MUST then write
  /// create-only (conflict if data has since appeared) so an unmerged clobber
  /// becomes a [SyncConflictException] the caller re-pulls from - instead of
  /// silently overwriting another device's just-created data. The hosted
  /// server keeps its existing upsert semantics regardless.
  ///
  /// [argon2Params] are the KDF parameters the wrapped DEK was derived under.
  /// They MUST match `wrapped_dek_password` so another device can re-derive the
  /// key. Pass them on any push that (re)establishes key material; on a
  /// data-only sync pass the account's current params (or null to let a dumb
  /// store carry forward what it already has). This is what lets the app change
  /// the default Argon2 cost without stranding existing accounts.
  ///
  /// Returns the new server version, the encrypted blob size in bytes, and
  /// when the store says it was written (null where the store does not say:
  /// a hosted server from before 3.0).
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
    // Proof of the OLD password on a password change: the verification hash the
    // server currently has stored. When the hosted server runs push write-
    // verification (SYNC_VERIFY_ENFORCE), a push that changes password_hash is
    // only accepted if this equals the stored hash - so a stolen session token
    // (which doesn't know the master password) can't rewrite the vault's
    // password. Null on every non-password-change push. Ignored by dumb stores
    // (they use compare-and-swap, not a server-side verify).
    Uint8List? authorizeHash,
    // Proof of the RECOVERY key on a recovery-key restore that resets the
    // password. The recovering user does NOT know the old password, so they
    // authorize the changed password_hash with this instead: the recovery
    // verification hash, which the hosted server compares against the stored
    // recovery_hash. Null on every non-recovery push. Ignored by dumb stores.
    Uint8List? authorizeRecoveryHash,
  });

  /// Whether [mek] is the correct master key for the stored data.
  Future<bool> verifyPassword(SecretKey mek);

  /// Ensure the paid Cloud Sync entitlement is active. No-op for
  /// bring-your-own backends ([requiresEntitlement] == false).
  Future<void> verifyEntitlement();

  /// Pull and unwrap the DEK using a recovery key.
  Future<RecoveryPullResult> pullWithRecoveryKey(String recoveryKey);

  /// Delete all sync data from the store. [verificationHash] gates the
  /// destruction on server-backed backends.
  Future<void> purge(Uint8List verificationHash);

  /// Delete the user's account/data on the store. For dumb stores this is
  /// equivalent to [purge] (there is no separate account).
  Future<void> deleteAccount(Uint8List verificationHash);
}
