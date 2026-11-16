import 'dart:convert';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/linux_keychain.dart';
import 'package:zestssh/services/profiles/mac_keychain.dart';
import 'package:zestssh/services/profiles/windows_keychain.dart';
import 'package:zestssh/services/secret_seal.dart';

// The one place the app opens the system's keychain (to-do 60). Fourteen
// places opened it on their own, each with its own copy of the options, and a
// test (test/services/profiles/settings_tags_test.dart) now fails for a new one.

/// The system's keychain itself. These options must stay as they are: they
/// say which backing store holds every key the app has.
///
/// macOS: the ad-hoc, unsigned distribution has no keychain-access-group
/// entitlement, so the default data-protection keychain fails every read with
/// errSecMissingEntitlement (-34018), the "Database Error" seen on launch. The
/// legacy keychain uses the app's bundle id as its access group (see the
/// rationale in macos/Runner/Release.entitlements) and needs no entitlement.
const FlutterSecureStorage deviceKeychain = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
  iOptions: IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  ),
  mOptions: MacOsOptions(useDataProtectionKeyChain: false),
  wOptions: WindowsOptions(),
);

/// Where a version before 1.7 kept certificate hashes (PinnedHttpClient, which
/// only deletes them): the default store on a phone, unlike all the rest.
const FlutterSecureStorage oldCertificateHashesKeychain = FlutterSecureStorage(
  mOptions: MacOsOptions(useDataProtectionKeyChain: false),
);

/// Puts the app's own store under the plugin's name, before anything touches the
/// keychain: a file that is safe to stop on Windows (windows_keychain.dart), a readAll
/// that works on a Mac (mac_keychain.dart), and a lock between processes for a write on
/// Linux (linux_keychain.dart). Every [FlutterSecureStorage], the released callers' too,
/// goes through it. In each window's engine: a pop-out has its own (it reads no secret
/// today, and if one ever does it takes the same lock). On a phone it does nothing: the
/// system's store takes each call whole.
void installKeychainStore() {
  final current = FlutterSecureStoragePlatform.instance;
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
      if (current is! SafeWindowsKeychain) FlutterSecureStoragePlatform.instance = SafeWindowsKeychain(SafeKeychainFile());
    case TargetPlatform.macOS:
      if (current is! MacKeychain) FlutterSecureStoragePlatform.instance = MacKeychain(current);
    case TargetPlatform.linux:
      if (current is! LinuxKeychain) FlutterSecureStoragePlatform.instance = LinuxKeychain(current);
    default:
      return;
  }
}

/// What macOS said no to in this run, where the keychain is a Mac's (3.3.2), and
/// null elsewhere: listened to by what says so, and cleared by its Try again.
KeychainDenials? get keychainDenials {
  final store = FlutterSecureStoragePlatform.instance;
  return store is MacKeychain ? store.denials : null;
}

/// Whether work nobody asked for waits for the person (3.3.2): macOS said no to a
/// read of one of the app's own keychain items in this run, and nobody has chosen
/// Try again since. Sync and a team's rounds wait instead of trying again: each try
/// could bring macOS's question up again, or fail for the same reason.
bool get keychainWaitsForPerson => keychainDenials?.any ?? false;

/// [body]'s keychain writes reach the store together, where it can do that (the
/// file on Windows, which is rewritten whole for each write otherwise). A stop or a
/// throw inside leaves it as it was. Elsewhere it is [body].
Future<T> keychainBatch<T>(Future<T> Function() body) {
  final store = FlutterSecureStoragePlatform.instance;
  return store is SafeWindowsKeychain ? store.batch(body) : body();
}

/// The keychain's file as it is, copied to [to], where there is one (Windows).
Future<void> copyKeychainFileTo(String to) async {
  final store = FlutterSecureStoragePlatform.instance;
  if (store is SafeWindowsKeychain) await store.copyFileTo(to);
}

/// The keychain's file does not open, and the person will not wait for it: it stays
/// under another name, and the keychain starts empty (Windows).
Future<void> setKeychainFileAside() async {
  final store = FlutterSecureStoragePlatform.instance;
  if (store is SafeWindowsKeychain) await store.setFileAside();
}

/// The names kept in the keychain [device], and nothing of what they hold. On a Mac
/// a list asks nothing of anyone, and each read may (the legacy keychain, with an
/// ad-hoc signature that changes with each build): what needs only names reads
/// nothing. Where the store is one file a read of all of it is the cheap way.
Future<List<String>> keychainNamesIn(FlutterSecureStorage device) async {
  final store = FlutterSecureStoragePlatform.instance;
  if (store is MacKeychain && identical(device, deviceKeychain)) return store.names(deviceKeychain.mOptions.params);
  return Map<String, String>.of(await device.readAll()).keys.toList();
}

/// What the keychain [device] holds under the names [wanted] says yes to, and on a
/// Mac no other entry is read: nobody is asked about another profile's.
Future<Map<String, String>> keychainEntriesIn(FlutterSecureStorage device, bool Function(String name) wanted) async {
  final store = FlutterSecureStoragePlatform.instance;
  if (store is MacKeychain && identical(device, deviceKeychain)) {
    final out = <String, String>{};
    for (final name in await store.names(deviceKeychain.mOptions.params)) {
      if (!wanted(name)) continue;
      final value = await device.read(key: name);
      // One that went between the list and its read is simply not there.
      if (value != null) out[name] = value;
    }
    return out;
  }
  return {
    for (final entry in Map<String, String>.of(await device.readAll()).entries)
      if (wanted(entry.key)) entry.key: entry.value,
  };
}

/// The names a store sees in [storage], read no further than it takes: on a Mac
/// nothing of what they hold is read, the system's keychain itself included.
Future<List<String>> keychainStoreNames(FlutterSecureStorage storage) async =>
    storage is ProfileKeychain ? storage.names() : keychainNamesIn(storage);

/// What was set aside of the keychain's file goes (Everything on this computer).
Future<void> forgetKeychainSetAside() async {
  final store = FlutterSecureStoragePlatform.instance;
  if (store is SafeWindowsKeychain) await store.file.forgetSetAside();
}

ProfileKeychain? _profileKeychain;

/// The keychain as the app uses it: the profile's own names on a computer,
/// the system's on a phone.
FlutterSecureStorage get appKeychain {
  if (!Profiles.on) return deviceKeychain;
  return _profileKeychain ??= ProfileKeychain(deviceKeychain);
}

/// Which names are whose.
class KeychainNames {
  KeychainNames._();

  /// What stays with the computer, whoever uses it: the app lock (its PIN, its
  /// vault, the hardware layer), the list of profiles, the note of recovery
  /// proofs, and the old map of teams to accounts until each has found its
  /// profile.
  static const deviceNames = {
    'security_pin_hash',
    'security_lock_method',
    'security_auto_lock_timeout',
    'security_idle_lock_minutes',
    'security_lock_with_computer',
    'pin_failed_attempts',
    'pin_lockout_until',
    'vault_slots',
    'vault_tpm_sealed_key',
    'vault2_hw_on',
    'pinned_cert_hashes',
    'recovery_proof_accounts_v1',
    'orchard_owners_v1',
    'rc_stranded_anon_id',
    'profiles_v1',
    'profiles_v1_copy',
    'agent_keys_owed_v1',
  };

  /// Beginnings of names that stay with the computer: what waits for its
  /// account to sign in here (HeldEntries).
  static const devicePrefixes = ['held.'];

  /// Device names the lock has another name for with profiles, so an older
  /// version never mistakes them for its own: seeing its old vault's slots
  /// beside a database key of its own, it would drop them, and with them the
  /// only way to any profile's key.
  static const renamed = {'vault_slots': 'vault2_slots'};

  /// What is kept in a profile but cannot be sealed by its seal: the seal's
  /// key is in the database these open.
  static const unsealed = {
    databaseKey,
    wrappedDatabaseKey,
    hardwareWrappedDatabaseKey,
    lockedCopy,
    lockedCopyNext,
    lockedCopyOrphan,
    sealWaits,
  };

  /// The database's key, as it is while the app lock is off.
  static const databaseKey = 'zestssh_db_encryption_key';

  /// The same, wrapped by the vault key while the app lock is on.
  static const wrappedDatabaseKey = 'vault_wrapped_db_key';

  /// The same, wrapped again by the hardware layer while that is on.
  static const hardwareWrappedDatabaseKey = 'vault_hw_wrapped_db_key';

  /// The copy wrapped with a secret ZestSSH Cloud holds, and the one it is
  /// being told of (LockedCopies).
  static const lockedCopy = 'locked_copy_v1';
  static const lockedCopyNext = 'locked_copy_next_v1';

  /// The secret of the copy ZestSSH Cloud is being told of; sealed.
  static const lockedCopySecret = 'locked_copy_secret_v1';

  /// Copies ZestSSH Cloud still holds that this device no longer needs.
  static const lockedCopiesRetired = 'locked_copies_retired_v1';

  /// The id of a copy of a key that is gone (a Reset), until the next settle
  /// retires it. Not sealed: the seal went with that key, and an id is no secret.
  static const lockedCopyOrphan = 'locked_copy_orphan_v1';

  /// The whole names of what was written while the database was closed, kept plain
  /// until it opens ([sealWaitingIn]). Not sealed: there is no seal at hand then.
  static const sealWaits = 'seal_waits_v1';

  /// What no store's sweep sees: a clean-up must never take these for
  /// leftovers.
  static const hidden = {...unsealed, lockedCopySecret, lockedCopiesRetired};

  /// Names that have the account's id in them: inside a profile the id is
  /// left out ([selfMark]), so no name says who uses the device.
  static const accountPrefixes = [
    'account_keys_v1_',
    'account_keys_next_v1_',
    'account_keys_prev_v1_',
    'orchard_device_key_v1.',
    'orchard_export_v1.',
  ];

  /// What stands for the account's id in a name inside its profile.
  static const selfMark = 'me';

  static bool isDevice(String name) => deviceNames.contains(name) || devicePrefixes.any(name.startsWith);

  /// [name] as the system's keychain knows it, for a device name.
  static String deviceName(String name) => renamed[name] ?? name;

  /// The account whose id is in the old [name], or null where none is.
  static String? accountOf(String name) {
    for (final prefix in accountPrefixes) {
      if (!name.startsWith(prefix)) continue;
      final rest = name.substring(prefix.length);
      final end = rest.indexOf('.');
      return end < 0 ? rest : rest.substring(0, end);
    }
    return null;
  }

  /// [name] as a store says it, inside the profile of [uid].
  static String inner(String name, String? uid) {
    if (uid == null) return name;
    for (final prefix in accountPrefixes) {
      if (!name.startsWith(prefix)) continue;
      final rest = name.substring(prefix.length);
      if (rest == uid) return '$prefix$selfMark';
      if (rest.startsWith('$uid.')) return '$prefix$selfMark${rest.substring(uid.length)}';
    }
    return name;
  }

  /// The reverse of [inner].
  static String outer(String inner, String? uid) {
    if (uid == null) return inner;
    for (final prefix in accountPrefixes) {
      if (!inner.startsWith(prefix)) continue;
      final rest = inner.substring(prefix.length);
      if (rest == selfMark) return '$prefix$uid';
      if (rest.startsWith('$selfMark.')) return '$prefix$uid${rest.substring(selfMark.length)}';
    }
    return inner;
  }

  /// The whole name of the entry a store calls [name], in the profile [id] of
  /// the account [uid].
  static String full(String id, String? uid, String name) => '${KeychainPrefix.of(id)}${inner(name, uid)}';
}

/// The keychain with profiles: what a store calls `identity_key_x` is
/// `p.<id>.identity_key_x`, sealed with the profile's own seal whether or not
/// the app lock is on, so that a signed-out account's secrets open only where
/// its database does. A device name goes to the system's keychain as it is
/// ([KeychainNames]).
///
/// [readAll] shows the profile open now and nothing else, so that every
/// clean-up of keychain entries, the one after a restore included, sees only
/// its own profile's names.
///
/// While the database is closed (the app is locked) a sealed entry of a store
/// that reads through the seal's accessor ([SecretSeal.sealsSlot]) is handed back
/// sealed, as it always was: its own [openKept] reads it as none, and what must not
/// take that for an answer waits or refuses. Any other store never knew of seals,
/// and reads none: ciphertext is nobody's value. Written while the database is
/// closed, a value is kept as it is until the next open seals it ([sealWaiting]).
/// With the database open, one that does not open reads as none (one sealed by a
/// database since reset).
class ProfileKeychain extends FlutterSecureStorage {
  ProfileKeychain(this._device, {ActiveProfile? Function()? profile, AppDatabase? Function()? tree})
      : _profile = profile ?? (() => Profiles.current),
        _tree = tree ?? (() => SecretSeal.openTree);

  final FlutterSecureStorage _device;
  final ActiveProfile? Function() _profile;
  final AppDatabase? Function() _tree;

  Future<SecretSeal?> _seal() async {
    final tree = _tree();
    if (tree == null) return null;
    final seal = await SecretSeal.of(tree);
    return seal.everOn ? seal : null;
  }

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (KeychainNames.isDevice(key)) return _device.read(key: KeychainNames.deviceName(key));
    final profile = _profile();
    if (profile == null) return null;
    final name = KeychainNames.full(profile.id, profile.uid, key);
    final stored = await _device.read(key: name);
    if (stored == null || !SecretSeal.isSealed(stored) || KeychainNames.unsealed.contains(key)) return stored;
    final tree = _tree();
    if (tree == null) return SecretSeal.sealsSlot(key) ? stored : null;
    try {
      return await (await SecretSeal.of(tree)).open(name, stored);
    } on SecretSealBroken {
      return null;
    }
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) return delete(key: key);
    if (KeychainNames.isDevice(key)) return _device.write(key: KeychainNames.deviceName(key), value: value);
    final profile = _profile();
    if (profile == null) throw const NoProfileOpen();
    final name = KeychainNames.full(profile.id, profile.uid, key);
    if (KeychainNames.unsealed.contains(key)) return _device.write(key: name, value: value);
    final seal = await _seal();
    // Noted first: a value that waits is found by this list, and nothing is read
    // at an open to look for one.
    if (seal == null) await _noteWaiting(profile, name);
    await _device.write(key: name, value: seal == null ? value : await seal.seal(name, value));
  }

  Future<void> _noteWaiting(ActiveProfile profile, String name) async {
    final listName = '${profile.prefix}${KeychainNames.sealWaits}';
    final waiting = _waitingNames(await _device.read(key: listName));
    if (waiting.add(name)) await _device.write(key: listName, value: jsonEncode(waiting.toList()));
  }

  @override
  Future<bool> containsKey({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (KeychainNames.isDevice(key)) return _device.containsKey(key: KeychainNames.deviceName(key));
    final profile = _profile();
    if (profile == null) return false;
    return _device.containsKey(key: KeychainNames.full(profile.id, profile.uid, key));
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (KeychainNames.isDevice(key)) return _device.delete(key: KeychainNames.deviceName(key));
    final profile = _profile();
    if (profile == null) throw const NoProfileOpen();
    await _device.delete(key: KeychainNames.full(profile.id, profile.uid, key));
  }

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final profile = _profile();
    if (profile == null) return const {};
    final prefix = profile.prefix;
    final seal = await _seal();
    final out = <String, String>{};
    for (final entry in (await keychainEntriesIn(_device, (name) => name.startsWith(prefix))).entries) {
      final inner = entry.key.substring(prefix.length);
      final name = KeychainNames.outer(inner, profile.uid);
      if (KeychainNames.hidden.contains(name)) continue;
      var value = entry.value;
      if (SecretSeal.isSealed(value) && !KeychainNames.unsealed.contains(name)) {
        if (seal == null) {
          if (!SecretSeal.sealsSlot(name)) continue;
        } else {
          try {
            value = await seal.open(entry.key, value);
          } on SecretSealBroken {
            continue;
          }
        }
      }
      out[name] = value;
    }
    return out;
  }

  /// This keychain as it is right now, bound to the profile and database open now,
  /// whatever opens later, and the database it is bound to.
  (ProfileKeychain, AppDatabase?) boundToNow() {
    final profile = _profile();
    final tree = _tree();
    return (ProfileKeychain(_device, profile: () => profile, tree: () => tree), tree);
  }

  /// The names [readAll] would look at, with nothing read: what wants to know
  /// which there are never brings up a question about each.
  Future<List<String>> names() async {
    final profile = _profile();
    if (profile == null) return const [];
    final prefix = profile.prefix;
    return [
      for (final name in await keychainNamesIn(_device))
        if (name.startsWith(prefix) && !KeychainNames.hidden.contains(KeychainNames.outer(name.substring(prefix.length), profile.uid)))
          KeychainNames.outer(name.substring(prefix.length), profile.uid),
    ];
  }

  /// Everything of the profile open now, and nothing else.
  @override
  Future<void> deleteAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final profile = _profile();
    if (profile == null) throw const NoProfileOpen();
    for (final key in (await readAll()).keys) {
      await delete(key: key);
    }
  }

  /// What was written while the database was closed, sealed now: run as a
  /// profile opens. Returns how many.
  Future<int> sealWaiting(ActiveProfile profile, SecretSeal seal) => sealWaitingIn(_device, profile, seal);
}

Set<String> _waitingNames(String? raw) {
  if (raw == null) return {};
  try {
    return {for (final name in jsonDecode(raw) as List) name as String};
  } catch (_) {
    return {};
  }
}

/// [ProfileKeychain.sealWaiting], on the system's keychain [device]: what was noted
/// as written while the database was closed, and nothing else is read. A value
/// written meanwhile is left for the next time.
Future<int> sealWaitingIn(FlutterSecureStorage device, ActiveProfile profile, SecretSeal seal) async {
  final listName = '${profile.prefix}${KeychainNames.sealWaits}';
  final raw = await device.read(key: listName);
  if (raw == null) return 0;
  var sealed = 0;
  await keychainBatch(() async {
    for (final name in _waitingNames(raw)) {
      if (!name.startsWith(profile.prefix)) continue;
      final stored = await device.read(key: name);
      if (stored == null || SecretSeal.isSealed(stored)) continue;
      final value = await seal.seal(name, stored);
      if (await device.read(key: name) != stored) continue;
      await device.write(key: name, value: value);
      sealed++;
    }
    await device.delete(key: listName);
  });
  return sealed;
}
