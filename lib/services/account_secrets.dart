import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/profiles/active_profile.dart' show NoProfileOpen;

/// The secrets in the system's secure storage that let a device act on a
/// store or service elsewhere, read and written here alone:
/// the sign-in token
/// of a browser sign-in ([sessionToken]), the value the server asks for on
/// every push to prove the sync password ([syncVerification]), the store
/// sync uses with what signs in to it ([syncStore]: a WebDAV password, an S3
/// key, a sync server's token) and the cloud accounts hosts are imported
/// from, with their API tokens ([cloudImports]); and what syncs a device
/// that was signed out without asking, kept for its account ([keptSync]).
///
/// With the encrypting lock ("Encrypt data at rest") on, every other secret
/// that opens data was sealed (SecretSeal), but these were kept as they
/// were: whatever could read that storage without the PIN (a program running
/// as you, a copy of the device's files) could not read a host or a key, but
/// held what the server needs to push to the cloud copy or purge it, and,
/// with the salt beside it, what a guess at the sync password needs; the
/// keys to overwrite or delete the copy on a store of one's own; and the
/// tokens of the person's cloud accounts. Now they are sealed like the
/// others: while the lock is on they open only after the PIN; with it off
/// they are kept as they were, as before.
///
/// While the app is locked a sealed one reads as none. Nothing that needs it
/// runs then (sync, the teams' sync and their live line, and the checks of
/// cloud accounts stop with the database, and the desktop sign-in is brought
/// back after the unlock), and what must not take "none" for an answer waits
/// for the unlock instead ([readOnceOpen]: a shared session's line, which
/// stays up through a lock, and the choice of sync store, which must never
/// be taken for the default) or refuses ([readOrThrow]: the cloud accounts,
/// which must never be written over as if there were none). Reading none
/// never signs anyone out, and never loses a setting.
class AccountSecret {
  const AccountSecret._(this.slot);

  /// Where it is kept in the system's secure storage.
  final String slot;

  /// The browser sign-in's token (the desktop apps; a phone signed in with
  /// Firebase keeps none).
  static const sessionToken = AccountSecret._('session_token');

  /// The sync password's verification value (AutoSyncService).
  static const syncVerification = AccountSecret._('sync_verification_hash');

  /// The store sync uses and what signs in to it (SyncProviderConfig as
  /// kept by syncProviderConfigProvider).
  static const syncStore = AccountSecret._('sync_backend_config');

  /// The cloud accounts hosts are imported from, with their API tokens
  /// (CloudAccountStore).
  static const cloudImports = AccountSecret._('cloud_accounts_v1');

  /// What syncs this device, set aside for the account it was signed out of
  /// without asking (KeptSync).
  static const keptSync = AccountSecret._('sync_kept_for_account_v1');

  /// An account recovery this device waits for, with the ticket that completes
  /// it (LockoutRecoveryStore).
  static const lockoutRecovery = AccountSecret._('lockout_recovery_v1');

  /// Every one of them.
  static const all = [sessionToken, syncVerification, syncStore, cloudImports, keptSync, lockoutRecovery];

  static AppDatabase? _openTree() => SecretSeal.openTree;

  /// The secret as kept, opened where it is sealed; none where there is none,
  /// or it is sealed and [tree] (your Tree's database, by default the one
  /// open now) is not there to open it (the app is locked), or it does not
  /// open. One kept as it was while sealing is on (written by an app from
  /// before this, or while the app was locked) is sealed now, the first time
  /// it is read.
  Future<String?> read(FlutterSecureStorage storage, {AppDatabase? Function()? tree}) async {
    final db = (tree ?? _openTree)();
    final stored = await storage.read(key: slot);
    if (stored == null) return null;
    if (SecretSeal.isSealed(stored)) return openKept(db, slot, stored);
    if (db != null) await _sealIfOn(storage, db, stored);
    return stored;
  }

  Future<void> _sealIfOn(FlutterSecureStorage storage, AppDatabase db, String stored) async {
    try {
      final seal = await SecretSeal.of(db);
      if (!seal.active) return;
      final sealed = await seal.seal(slot, stored);
      // Read again just before, as the sealing sweep does: one written
      // meanwhile is kept.
      if (await storage.read(key: slot) != stored) return;
      await storage.write(key: slot, value: sealed);
    } catch (_) {
      // Sealed at the next unlock (sealSecretsAtRest) instead.
    }
  }

  /// As [read], but one sealed while the app is locked throws
  /// [SecretSealBroken] instead of reading as none: for a store that writes
  /// the whole of what it read back, so it is never written over while the
  /// app is locked. (One that never opens, sealed by a database since reset,
  /// reads as none, so it can be replaced.)
  Future<String?> readOrThrow(FlutterSecureStorage storage, {AppDatabase? Function()? tree}) async {
    if (await waitsForUnlock(storage, tree: tree)) throw SecretSealBroken(slot);
    return read(storage, tree: tree);
  }

  /// Whether the secret is kept here but sealed while the app is locked, so
  /// it cannot be read until the unlock (a sign-in that is still there, not
  /// a signed-out device).
  Future<bool> waitsForUnlock(FlutterSecureStorage storage, {AppDatabase? Function()? tree}) async =>
      (tree ?? _openTree)() == null && SecretSeal.isSealed(await storage.read(key: slot));

  /// As [read], but a secret sealed while the app is locked is read once it
  /// is unlocked, instead of reading as none: for a line that stays up while
  /// the app is locked (a shared session) and would otherwise end as if
  /// signed out.
  Future<String?> readOnceOpen(FlutterSecureStorage storage) async {
    if (await waitsForUnlock(storage)) {
      final AppDatabase tree;
      try {
        tree = await SecretSeal.whenOpen();
      } on NoProfileOpen {
        return null; // Another person's profile is what opens next.
      }
      return read(storage, tree: () => tree);
    }
    return read(storage);
  }

  /// Keeps [value], sealed while the encrypting lock is on (as it was where
  /// it is off, or while the app is locked: then sealed at the next unlock).
  Future<void> write(FlutterSecureStorage storage, String value, {AppDatabase? Function()? tree}) async =>
      storage.write(key: slot, value: await keepSealed((tree ?? _openTree)(), slot, value));

  /// Forgets it (signing out, sync taken apart, the last cloud account
  /// forgotten).
  Future<void> delete(FlutterSecureStorage storage) => storage.delete(key: slot);
}
