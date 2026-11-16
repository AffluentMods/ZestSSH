import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/utils/type_name.dart';

/// Secrets kept in the system's secure storage, sealed while the encrypting
/// lock ("Encrypt data at rest") is on (found in a
/// security review of the client).
///
/// The lock wraps the database's key behind the PIN, but the secrets of your
/// keys (private keys, passwords, passphrases, certificates, a CA's key), the
/// key of personal sync, your account's keys and each Orchard's database key
/// lived beside it in the system's secure storage, as they were: whatever could
/// read that storage (a program running as you, someone at the computer while
/// it was unlocked) read them without the PIN, which the setting said it
/// prevented. Now each is sealed (AES-256-GCM) under a key kept in the
/// database itself (device-local state: never synced, never in a backup), so
/// it opens only where the database does, after the PIN.
///
/// With the lock off the database's key is in that same storage, and a seal
/// would add nothing: secrets are kept as they were, and a sealed one is read
/// as long as the database opens. Turning the lock on seals every one
/// ([sealSecretsAtRest]), and so does each unlock, for any kept as it was.
class SecretSeal {
  SecretSeal._(this._key, this._active);

  /// None until sealing is first turned on ([setActive]): a device whose lock
  /// never was keeps nothing more in its database.
  SecretKey? _key;
  bool _active;

  /// What a sealed value starts with.
  static const prefix = 'zseal1:';

  static const _keyName = 'secret_seal_key_v1';
  static const _activeName = 'secret_seal_active_v1';

  /// The rows of the database's local store that are the seal's own.
  static const ownRows = [_keyName, _activeName];
  static final _cache = Expando<Future<SecretSeal>>();
  static final _aes = AesGcm.with256bits();

  /// The storage keys of the secrets that are sealed.
  static const _sealedPrefixes = [
    'identity_password_',
    'identity_key_',
    'identity_passphrase_',
    'identity_cert_',
    'ca_key_',
    'account_keys_v1_',
    'account_keys_next_v1_',
    'account_keys_prev_v1_',
    'orchard_db_key_',
    // The password of each WebDAV place backups are copied to
    // (BackupDestinationManager).
    'backup_dest_secret_',
    // This device's signing key for each account's teams (DeviceIdentityStore).
    'orchard_device_key_v1.',
    // Where a team's events are sent, with the header that carries its token
    // (ExportSettingsStore).
    'orchard_export_v1.',
  ];

  /// The storage keys of single secrets that are sealed (22 October 2026: the
  /// automatic backups' password was left as it was, beside backups that hold
  /// every key's secret, so whatever read the storage opened those backups
  /// without the PIN; the others were found by the same check).
  static const _sealedSlots = {
    'sync_dek',
    // The same key and what goes with it, set aside for the account a device
    // was signed out of without asking (AccountSecret.keptSync).
    'sync_kept_for_account_v1',
    // The password automatic backups are encrypted with (AutoBackupService).
    'auto_backup_password',
    // The key saved session recordings are encrypted with
    // (SessionTranscriptService).
    'zestssh_transcript_encryption_key',
    // The Google Drive sign-in on a computer, with its refresh token
    // (KeychainGoogleTokenStore).
    'google_desktop_oauth_v1',
    // The monitoring server's sign-in (PrometheusSecureSettings): its client
    // certificate and that certificate's password, a bearer token, a password
    // and a header's value. Its CA certificate and user name are not secrets.
    'prometheus_client_cert_p12',
    'prometheus_client_cert_pass',
    'prometheus_bearer_token',
    'prometheus_basic_pass',
    'prometheus_custom_header_val',
    // What lets a device act for its account on ZestSSH Cloud (AccountSecret;
    // 23 October 2026: kept as they were, so whatever read the storage could
    // push to the cloud copy or purge it without the PIN): the browser
    // sign-in's token and the sync password's verification value.
    'session_token',
    'sync_verification_hash',
    // The store sync uses, with what signs in to it (a WebDAV password, an S3
    // key, a sync server's token), and the cloud accounts hosts are imported
    // from, with their API tokens (AccountSecret; 23 October 2026: kept as
    // they were, so whatever read the storage could overwrite or delete the
    // copy on a store of one's own, or use those accounts, without the PIN).
    'sync_backend_config',
    'cloud_accounts_v1',
    // The ticket of an account recovery that waits on this device
    // (LockoutRecoveryStore; a cryptography audit found it kept as
    // it was, so whatever read the storage could complete the recovery once
    // its day came, or reset the account, without the PIN). It is only ever
    // used from a screen behind the lock.
    'lockout_recovery_v1',
  };

  /// Whether the secret kept under [slot] is one that is sealed.
  static bool sealsSlot(String slot) => _sealedSlots.contains(slot) || _sealedPrefixes.any(slot.startsWith);

  /// Your Tree's database while it is open, for the stores no provider hands
  /// a database to (the session recordings' key, the Google sign-in): set by
  /// the database's session (DatabaseSessionNotifier), none while the app is
  /// locked.
  static AppDatabase? get openTree => _openTree;
  static set openTree(AppDatabase? tree) {
    _openTree = tree;
    final waiting = _opened;
    if (tree == null || waiting == null) return;
    _opened = null;
    waiting.complete(tree);
  }

  static AppDatabase? _openTree;
  static Completer<AppDatabase>? _opened;

  /// Your Tree's database once it is open: now where it is, else at the
  /// unlock.
  static Future<AppDatabase> whenOpen() {
    final tree = _openTree;
    if (tree != null) return Future.value(tree);
    return (_opened ??= Completer<AppDatabase>()).future;
  }

  /// A change of profile: whoever waits for the database that was open waits for
  /// nothing now, and must not be handed the next person's.
  static void dropWaiters() {
    final waiting = _opened;
    _opened = null;
    waiting?.completeError(const NoProfileOpen());
  }

  /// Whether [stored] is sealed.
  static bool isSealed(String? stored) => stored != null && stored.startsWith(prefix);

  /// The seal of [tree], your Tree's database (never an Orchard's). Its key
  /// is made the first time sealing is turned on, and is the same from then
  /// on.
  static Future<SecretSeal> of(AppDatabase tree) {
    if (tree.isOrchard) throw ArgumentError('The seal is your Tree\'s, not an Orchard\'s');
    return _cache[tree] ??= _load(LocalStateStore(tree));
  }

  static Future<SecretSeal> _load(LocalStateStore store) async {
    final key = await store.read(_keyName);
    return SecretSeal._(key == null ? null : SecretKey(base64.decode(key)), await store.read(_activeName) == '1');
  }

  /// Whether a secret written now is sealed by the store that writes it: while
  /// the encrypting lock is on. On a computer the keychain itself seals every
  /// entry of a profile whatever the lock, and the stores hand it each value as
  /// it is (ProfileKeychain).
  bool get active => _active && !Profiles.on;

  /// Whether sealing was ever turned on here (its key was made): a device
  /// whose lock never was can hold no sealed secret.
  bool get everOn => _key != null;

  /// The seal of a profile's database, its key made where there is none: every
  /// personal secret on a computer is sealed by it, with the app lock on or off.
  /// (The first profile's database brings the key it had, if the lock was ever
  /// on: what it sealed opens with it.)
  static Future<SecretSeal> forProfile(AppDatabase tree) async {
    final seal = await of(tree);
    if (seal._key == null) {
      await setActive(tree, true);
      // In the main file before anything is sealed with it. Left in the
      // write-ahead file alone, a copy of the main file has no such key, and all
      // that was sealed reads as none once that copy is put back.
      await checkpoint(tree);
    }
    return seal;
  }

  /// What is in [tree]'s write-ahead file goes into its main file.
  static Future<void> checkpoint(AppDatabase tree) => tree.customSelect('PRAGMA wal_checkpoint(TRUNCATE)').get();

  /// Sealing on or off for what is written from now on; kept in [tree]. On,
  /// the key is made where there is none (never inside another transaction:
  /// the lock's switch and its unlock call this).
  static Future<void> setActive(AppDatabase tree, bool on) async {
    final seal = await of(tree);
    final store = LocalStateStore(tree);
    if (on && seal._key == null) {
      final key = await store.readOrCreate(_keyName, () {
        final rng = Random.secure();
        return base64.encode(List<int>.generate(32, (_) => rng.nextInt(256)));
      });
      seal._key = SecretKey(base64.decode(key));
    }
    await store.write(_activeName, on ? '1' : '0');
    seal._active = on;
  }

  /// [value] as it is kept under [slot]: sealed while [active] and [slot] is
  /// one of the sealed ([sealsSlot]); else as it is.
  Future<String> keep(String slot, String value) async =>
      active && _key != null && sealsSlot(slot) ? seal(slot, value) : value;

  /// [value] sealed for [slot]: it opens under that slot alone, so a sealed
  /// value moved to another secret's place does not open there.
  Future<String> seal(String slot, String value) async {
    final key = _key;
    if (key == null) throw StateError('Sealing was never turned on here');
    final box = await _aes.encrypt(utf8.encode(value), secretKey: key, aad: _boundTo(slot));
    return '$prefix${base64.encode(box.concatenation())}';
  }

  /// What a sealed value is bound to: the slot it is kept under.
  static List<int> _boundTo(String slot) => utf8.encode(slot);

  /// What [stored] under [slot] holds: opened where it is sealed, as it is
  /// where it is not. Throws [SecretSealBroken] where it is sealed and does
  /// not open (sealed by another database, or altered).
  Future<String> open(String slot, String stored) async {
    if (!isSealed(stored)) return stored;
    final key = _key;
    if (key == null) throw SecretSealBroken(slot);
    try {
      final bytes = base64.decode(stored.substring(prefix.length));
      final box = SecretBox.fromConcatenation(bytes,
          nonceLength: _aes.nonceLength, macLength: _aes.macAlgorithm.macLength, copy: false);
      return utf8.decode(await _aes.decrypt(box, secretKey: key, aad: _boundTo(slot)));
    } catch (_) {
      throw SecretSealBroken(slot);
    }
  }
}

/// A sealed secret that does not open here.
class SecretSealBroken implements Exception, HasTypeName {
  const SecretSealBroken(this.slot);

  final String slot;

  @override
  String toString() => 'A sealed secret does not open here';

  @override
  String get typeName => 'SecretSealBroken';
}

/// The secret of the key called [label] is kept on this device, sealed, and
/// does not open here: what gathers this device's data for sync or a backup
/// throws it rather than send the key on as one with no secret
/// (SyncDataService.gatherAll). Said to the person with the key's
/// name and what to do (ErrorCodes.syncKeySecretUnread), where a
/// [SecretSealBroken] alone was said as "Sync could not finish on this
/// device".
class KeySecretUnread extends SecretSealBroken {
  const KeySecretUnread(super.slot, {required this.label});

  /// The key's name, as the person gave it.
  final String label;

  @override
  String get typeName => 'KeySecretUnread';
}

/// [stored] under [slot] as a store reads it: opened with [tree]'s seal where
/// it is sealed (null where it does not open, or where there is no [tree] to
/// open it with), as it is where it is not.
Future<String?> openKept(AppDatabase? tree, String slot, String? stored) async {
  if (stored == null || !SecretSeal.isSealed(stored)) return stored;
  if (tree == null) return null;
  try {
    return await (await SecretSeal.of(tree)).open(slot, stored);
  } on SecretSealBroken {
    return null;
  }
}

/// [stored] under [slot] as a store reads it, for a store that would make a
/// new secret where it finds none (a key it encrypts with, a device's
/// signing key): as [openKept], but a sealed value that does not open here
/// throws [SecretSealBroken] instead of reading as none, so the secret is
/// never replaced while the app is locked.
Future<String?> openKeptOrThrow(AppDatabase? tree, String slot, String? stored) async {
  final value = await openKept(tree, slot, stored);
  if (value == null && stored != null) throw SecretSealBroken(slot);
  return value;
}

/// [value] as a store writes it under [slot]: sealed with [tree]'s seal while
/// sealing is on, as it is where it is off or where there is no [tree].
Future<String> keepSealed(AppDatabase? tree, String slot, String value) async =>
    tree == null ? value : (await SecretSeal.of(tree)).keep(slot, value);

/// Turns sealing off for [tree] and keeps every sealed secret in [storage] as
/// it was again (22 October 2026: turning the lock off left them sealed, so a
/// store that could not reach the database read none). Returns how many were
/// opened. Run when the encrypting lock is turned off: the database's key is
/// in that same storage again, and a seal adds nothing. One that does not
/// open is left as it is.
Future<int> unsealSecretsAtRest(AppDatabase tree, FlutterSecureStorage storage) async {
  // On a computer a personal secret is sealed whatever the lock.
  if (Profiles.on) return 0;
  await SecretSeal.setActive(tree, false);
  final seal = await SecretSeal.of(tree);
  var opened = 0;
  for (final entry in Map<String, String>.of(await storage.readAll()).entries) {
    if (!SecretSeal.isSealed(entry.value)) continue;
    final String value;
    try {
      value = await seal.open(entry.key, entry.value);
    } on SecretSealBroken {
      continue;
    }
    // Read again just before, as the sealing sweep does.
    if (await storage.read(key: entry.key) != entry.value) continue;
    await storage.write(key: entry.key, value: value);
    opened++;
  }
  return opened;
}

/// Turns sealing on for [tree] and seals every secret in [storage] that is
/// sealed ([SecretSeal.sealsSlot]) and kept as it was. Returns how many were
/// sealed. Run when the encrypting lock is turned on, and at each unlock
/// while it is on, for any secret written as it was (by a build before this
/// one, or a write that raced the switch).
Future<int> sealSecretsAtRest(AppDatabase tree, FlutterSecureStorage storage) async {
  if (Profiles.on) return 0;
  await SecretSeal.setActive(tree, true);
  final seal = await SecretSeal.of(tree);
  var sealed = 0;
  for (final entry in Map<String, String>.of(await storage.readAll()).entries) {
    if (!SecretSeal.sealsSlot(entry.key) || SecretSeal.isSealed(entry.value)) continue;
    final sealedValue = await seal.seal(entry.key, entry.value);
    // Read again just before: one written meanwhile (a password changed
    // while this ran) is kept, never the one read at the start.
    if (await storage.read(key: entry.key) != entry.value) continue;
    await storage.write(key: entry.key, value: sealedValue);
    sealed++;
  }
  return sealed;
}

/// The secrets in [storage] as the encrypting lock stands ([lockOn], the
/// lock as the vault says at start), each time [tree] opens: sealed while it
/// is on ([sealSecretsAtRest]); kept as they were while it is off, where
/// sealing was left on or a sealed one left behind ([unsealSecretsAtRest]).
/// Turning the lock off removes the vault first and unseals after, so an app
/// stopped in between started again with the vault off and sealing still on:
/// every secret written from then on was sealed, and a store that cannot
/// reach the database read none of them (found while checking the
/// whitepaper). With the lock off the database's key is in that same
/// storage, so opening them is safe, and what turning the lock off had left
/// to do is done. Returns how many were sealed or opened.
Future<int> settleSecretsAtRest(AppDatabase tree, FlutterSecureStorage storage, {required bool lockOn}) async {
  if (Profiles.on) return 0;
  if (lockOn) return sealSecretsAtRest(tree, storage);
  final seal = await SecretSeal.of(tree);
  if (!seal.everOn) return 0;
  if (!seal.active && !(await storage.readAll()).values.any(SecretSeal.isSealed)) return 0;
  return unsealSecretsAtRest(tree, storage);
}
