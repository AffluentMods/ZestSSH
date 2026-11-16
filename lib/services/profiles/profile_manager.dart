import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/features/orchards/spaces.dart' show kTeamsSetAsideFolder;
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/backup_service.dart' show BackupService;
import 'package:zestssh/services/migration_backup_service.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/guest_tables.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/locked_copies.dart';
import 'package:zestssh/services/profiles/profile_list.dart';
import 'package:zestssh/services/profiles/profile_move.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';
import 'package:zestssh/services/profiles/profile_vault.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/session_transcript_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/services/vault_slot_service.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/type_name.dart';
import 'package:zestssh/utils/error_kind.dart';

/// What a start found.
class ProfileStart {
  const ProfileStart({required this.lockOn, required this.olderVersionData, this.putBackFailed = false});

  /// Whether the app lock's vault holds the way to the data: nothing opens
  /// until the PIN.
  final bool lockOn;

  /// A database at the old place, made by an older version run after the move.
  final bool olderVersionData;

  /// What was asked to be put back could not be: said once the app is up.
  final bool putBackFailed;
}

/// A sign-in that cannot open its account's profile: the app says so, with this
/// code and Try again, and stays where it is. It never makes a new profile for
/// an account it knows.
/// Guest data's hosts and keys are in the account, and something holds [count] of its
/// files: it stays, as those would go with it, and it can be asked again.
class GuestFilesHeld implements Exception, HasTypeName {
  const GuestFilesHeld(this.count);

  final int count;

  @override
  String toString() => 'GuestFilesHeld($count)';

  @override
  String get typeName => 'GuestFilesHeld';
}

/// [count] of guest data's secrets could not be read, or did not read back the same
/// through the account's seal: the guest profile stays, as it holds the only copy.
class GuestSecretsNotBrought implements Exception, HasTypeName {
  const GuestSecretsNotBrought(this.count);

  final int count;

  @override
  String toString() => 'GuestSecretsNotBrought($count)';

  @override
  String get typeName => 'GuestSecretsNotBrought';
}

/// Guest data's hosts and keys are in the account, and these [tables] of it hold rows
/// nothing can carry: the guest profile stays, as they would go with it.
class GuestKindsStayed implements Exception, HasTypeName {
  const GuestKindsStayed(this.tables);

  final List<String> tables;

  @override
  String toString() => 'GuestKindsStayed(${tables.join(', ')})';

  @override
  String get typeName => 'GuestKindsStayed';
}

class ProfileCannotOpen implements Exception, HasTypeName {
  const ProfileCannotOpen(this.code, [this.cause]);

  /// `profile-offline` (ZestSSH Cloud could not be reached),
  /// `profile-signed-in-long-ago` (its secret wants a newer sign-in),
  /// `profile-copy-broken` (its secret opens nothing), `profile-not-opened`
  /// (its database did not open) or `profile-too-many-accounts` (it would be one
  /// more than a computer keeps).
  final String code;
  final Object? cause;

  @override
  String toString() => 'ProfileCannotOpen($code)';

  @override
  String get typeName => 'ProfileCannotOpen';
}

/// What a sign-in opens, decided before anything changes.
class AccountPlan {
  const AccountPlan._({required this.uid, this.label, this.known, this.hex, this.replaceSecret = false, this.losing, this.person});

  /// The account's profile is the one open already.
  const AccountPlan.same(ProfileEntry entry, {required String uid, String? label})
      : this._(uid: uid, label: label, known: entry);

  /// A profile of this account, with its key at hand.
  const AccountPlan.known(ProfileEntry entry,
      {required String uid, String? label, required String hex, bool replaceSecret = false, String? person})
      : this._(uid: uid, label: label, known: entry, hex: hex, replaceSecret: replaceSecret, person: person);

  /// Guest data, with its key at hand: what a switch opens where no account is asked for.
  const AccountPlan.guest(ProfileEntry entry, {required String hex}) : this._(uid: null, known: entry, hex: hex);

  /// An account new on this computer; [losing], one whose locked copy can no
  /// longer be opened (it was deleted at ZestSSH Cloud), which is left and said.
  const AccountPlan.fresh({required String uid, String? label, ProfileEntry? losing, String? person})
      : this._(uid: uid, label: label, losing: losing, person: person);

  /// Null for guest data.
  final String? uid;
  final String? label;
  final ProfileEntry? known;
  final String? hex;

  /// A new secret replaces the one just fetched, at once.
  final bool replaceSecret;
  final ProfileEntry? losing;

  /// Whose account this now is ([ProfileEntry.person]), where someone just said; else
  /// it stays as it was.
  final String? person;

  bool get isFresh => known == null;
}

/// A profile's database, opened and checked before anything else changes.
class PreparedProfile {
  const PreparedProfile({required this.plan, required this.id, required this.db, required this.hex});

  final AccountPlan plan;
  final String id;
  final AppDatabase db;
  final String hex;
}

/// What guest data holds, as the question about it says it.
@immutable
class GuestDataSummary {
  const GuestDataSummary({required this.hosts, required this.keys, this.staysOut = const GuestStaysOut()});

  final int hosts;
  final int keys;

  /// What goes with guest data if it is brought in, which the question names.
  final GuestStaysOut staysOut;

  bool get empty => hosts == 0 && keys == 0;
}

/// How a sign-out left the profile.
enum SignOutEnd {
  /// Only ZestSSH Cloud's secret opens it now.
  locked,

  /// Its secret never reached ZestSSH Cloud: hidden, as guest data is; the next
  /// sign-in online locks it properly. Said so.
  hidden,

  /// Guest data: nothing to lock.
  nothing,
}

/// What ZestSSH Cloud says of the locked copy of the profile on screen, asked
/// before the person's own sign-out ([ProfileManager.lockedCopyAtCloud]).
enum LockedCopyAtCloud {
  /// It holds it: the sign-out locks.
  held,

  /// It holds it no more (deleted under Locked copies on your computers on
  /// another computer): the profile is only hidden, its key kept here, and the
  /// next sign-in makes a new copy.
  gone,

  /// The account is no more (deleted from another device, its copies with it):
  /// no secret will ever open its data again, so it is kept as guest data.
  accountGone,

  /// Nothing to ask about: no copy of it was ever confirmed there (or no
  /// sign-in to ask with). The profile is only hidden, its key kept here, and
  /// the next sign-in online tells ZestSSH Cloud the secret.
  unknown,

  /// It could not be asked: this computer was offline, or ZestSSH Cloud did
  /// not answer. The profile is only hidden, its key and its copy kept here,
  /// and a sign-out made online locks it.
  unreachable,
}

/// Profiles on one computer: what opens at a start, what a sign-in opens, what
/// a sign-out locks, what deleting removes. No provider and no screen: the app's
/// side of it is ProfileController (lib/providers/profile_providers.dart).
class ProfileManager {
  ProfileManager({
    required this.base,
    required this.device,
    required this.prefs,
    required this.rawPrefs,
    required this.folders,
    this.firebaseUid,
    this.firebaseReported,
    this.firebaseWait = const Duration(seconds: 60),
    Future<AppDatabase> Function(Directory dir, String hex)? openDatabase,
    LockedCopiesApi? api,
    bool? strictKeys,
    this.stop,
  })  : _openDatabase = openDatabase ?? AppDatabase.openAt,
        api = api ?? LockedCopiesApi(),
        _strictKeys = strictKeys ?? !kDebugMode {
    MigrationBackupService.restoreHeld = _restoreHeld;
  }

  /// The app's own, on a computer.
  static ProfileManager? instance;

  final Directory base;
  final FlutterSecureStorage device;
  final ProfilePreferences prefs;
  final SharedPreferences rawPrefs;
  final PersonFolders Function() folders;
  final String? Function()? firebaseUid;

  /// Done once Firebase has said who is signed in, or that nobody is (a Mac: it
  /// says so a while after the app starts, and until then [firebaseUid] reads as
  /// nobody). Whose data this is, or whether to lock it, is never decided before.
  final Future<void> Function()? firebaseReported;

  /// How long a move waits for that before it says so and changes nothing.
  final Duration firebaseWait;

  final LockedCopiesApi api;
  final Future<AppDatabase> Function(Directory dir, String hex) _openDatabase;

  /// A debug build's database has no key, and whatever a device held under a
  /// release build's is gone: a key is made where none is. Release builds and
  /// the tests that stand in for them never do that over an existing database.
  final bool _strictKeys;

  @visibleForTesting
  final void Function(String boundary)? stop;

  late final ProfileVault vault = ProfileVault(device);
  late final LockedCopies copies = LockedCopies(device);

  ProfileList _list = ProfileList();
  String? _settingsOf;

  /// The vault key and the hardware key, in memory while the app is unlocked:
  /// making a profile, opening one after a sign-in and opening guest data all
  /// need them. Forgotten when the app locks.
  SecretKey? vaultKey;
  List<int>? hardwareKey;

  ProfileList get list => _list;

  /// The profiles whose database passed its migrations in this run. What fails after
  /// that (a database held for a moment, at an unlock later on) is no fault of the
  /// upgrade, and the copy from before it would lose all that was done since.
  final Set<String> _passedMigrations = {};

  Future<bool> _restoreHeld() async {
    if (!Profiles.on) return false;
    return _passedMigrations.contains(Profiles.current?.id) || await _move.markerFile.exists();
  }

  /// What was asked to be put back could not be, this start.
  bool putBackFailed = false;

  /// The profile whose settings are in memory, or null where none is.
  String? get settingsOf => _settingsOf;

  ProfileMove get _move => ProfileMove(
        base: base,
        device: device,
        rawPrefs: rawPrefs,
        folders: folders,
        firebaseUid: firebaseUid,
        stop: stop,
        listOfTheStart: _listOfTheStart,
      );

  /// The list as this start read it from the keychain, until the start is over: a
  /// start asks whether a move is needed three times (bootProfiles, Firebase's
  /// wait, beforeOpen) and then reads the list itself, and on a Mac each read of
  /// it may bring up macOS's question about the keychain (3.3.2: it was read five
  /// times at each start). Only a list that is there is kept: where there is none
  /// a move may be about to write it, and it is read again.
  ProfileList? _startList;
  bool _startOver = false;

  Future<ProfileList?> _listOfTheStart() async {
    if (_startOver) return ProfileList.read(device);
    return _startList ??= await ProfileList.read(device);
  }

  ProfileEntry? get currentEntry => _list.byId(_list.current);

  ActiveProfile _active(ProfileEntry entry) =>
      ActiveProfile(id: entry.id, dir: ProfilePaths.ofProfile(base, entry.id), uid: entry.uid);

  void _bind(ProfileEntry? entry) {
    Profiles.bind(entry == null ? null : _active(entry));
    Profiles.provisionalTeams.clear();
  }

  // ── A start ────────────────────────────────────────────────────────

  /// Before anything opens: a move goes as far as it can without the database,
  /// what a sign-out or a removal left unfinished is finished, and the lock's
  /// state is read from what the keychain holds. Binds the profile to open.
  /// With the lock on and no guest profile to open yet, it is made after the
  /// PIN.
  Future<ProfileStart> start() async {
    Profiles.turnOn();
    final MoveMarker? moving;
    try {
      await _finishPutBack();
      if (firebaseReported != null && await _move.moveNeeded()) {
        // Whose this data is, for good: never on a guess. Nothing has moved yet, and
        // a person who sees this says Retry.
        try {
          await firebaseReported!().timeout(firebaseWait);
        } on TimeoutException {
          throw const ProfileMoveFailed('firebase', 'it did not say who is signed in');
        }
      }
      moving = await _move.beforeOpen();
      // The list the questions above read, where no move went on in between.
      _list = (moving == null ? await _listOfTheStart() : await ProfileList.read(device)) ?? ProfileList();
    } finally {
      _startList = null;
      _startOver = true;
    }
    if (moving == null) await _takeInUnlisted();
    await _finishSetAsides();
    await _finishSignOuts();
    await _finishRemovals();
    if (await _wipeMarker.exists()) await finishWipeEverything();
    await _lockWithComputerIsTheComputers();
    final lockOn = await vault.startUpCheck(_list.withKeyHere);
    // A sign-out or the lock's switch that stopped before this went: it holds a key
    // that is to be out of reach.
    if (lockOn || _list.entries.any((e) => e.state == ProfileState.locked)) await dropKeychainCopies();
    var entry = currentEntry;
    if (entry == null || !(entry.state == ProfileState.open || entry.state == ProfileState.gone)) {
      entry = _list.guest;
      if (entry == null && !lockOn) entry = await _makeProfile();
      if (entry != null) {
        _list.current = entry.id;
        await _list.write(device);
      }
    }
    _bind(entry);
    final older = moving == null && await File(p.join(base.path, ProfileMove.mainFile)).exists();
    return ProfileStart(lockOn: lockOn, olderVersionData: older, putBackFailed: putBackFailed);
  }

  /// Profile folders the list does not name, with a database and its key here: never
  /// passed over for new, empty guest data. A list that read as nothing (an item the
  /// keychain no longer showed) made new guest data at once, and the person's own was
  /// left in its folder, named by nothing, as if it were gone (seen with
  /// guest data on a Mac). With no list at all, the newest of them that
  /// is no account's is the guest data again, as it was; any other is set aside, which
  /// the notice of what was set aside says, with Put it back. An account's is never
  /// opened without its sign-in. A folder with no key here opens with nothing, and is
  /// left as it is.
  Future<void> _takeInUnlisted() async {
    final root = ProfilePaths.root(base);
    if (!await root.exists()) return;
    final List<String> names;
    try {
      names = await keychainNamesIn(device);
    } catch (e) {
      AppLogger.warning('Folders the list does not name were not looked at (${errorKind(e)})');
      return;
    }
    final here = names.toSet();
    final found = <(String, int)>[];
    for (final dir in await root.list().toList()) {
      if (dir is! Directory) continue;
      final id = p.basename(dir.path);
      if (!isProfileId(id) || _list.byId(id) != null) continue;
      final db = File(p.join(dir.path, ProfileMove.mainFile));
      if (!await db.exists()) continue;
      final keyHere = here.contains(ProfileVault.plainName(id)) ||
          here.contains(ProfileVault.wrappedName(id)) ||
          here.contains(ProfileVault.hardwareName(id));
      if (!keyHere) continue;
      found.add((id, (await db.stat()).modified.millisecondsSinceEpoch));
    }
    if (found.isEmpty) return;
    found.sort((a, b) => b.$2.compareTo(a.$2));
    bool anAccounts(String id) {
      final prefix = KeychainPrefix.of(id);
      return names.any((n) {
        if (!n.startsWith(prefix)) return false;
        final inner = n.substring(prefix.length);
        return inner == 'session_token' ||
            inner.startsWith('locked_copy') ||
            KeychainNames.accountPrefixes.any(inner.startsWith);
      });
    }

    final noList = _list.entries.isEmpty;
    var adopted = false;
    for (final (id, made) in found) {
      if (noList && !adopted && !anAccounts(id)) {
        _list.put(ProfileEntry(id: id, made: made));
        _list.current = id;
        adopted = true;
      } else {
        _list.put(ProfileEntry(id: id, made: made, state: ProfileState.setAside));
      }
    }
    AppLogger.warning('Profile folders the list did not name were taken in (${found.length})');
    await _list.write(device);
  }

  /// "Lock when the computer locks" is the computer's, as the app lock's other settings
  /// are (found in an independent review); a build before kept it in
  /// each profile. Only "off" was ever kept, so such an entry says off whatever it holds
  /// (sealed or not): off in any profile is the computer's now, and the entries go.
  Future<void> _lockWithComputerIsTheComputers() async {
    const name = 'security_lock_with_computer';
    final kept = [
      for (final n in await keychainNamesIn(device))
        if (KeychainPrefix.profileOf(n) case final id? when n == '${KeychainPrefix.of(id)}$name') n,
    ];
    if (kept.isEmpty) return;
    if (await device.read(key: name) == null) await device.write(key: name, value: 'off');
    for (final n in kept) {
      await device.delete(key: n);
    }
  }

  /// What the list says is set aside goes to its folder, where a stop left it, or
  /// something held it: nothing opens it either way, and it is tried at each start.
  Future<void> _finishSetAsides() async {
    for (final entry in _list.entries) {
      if (entry.state != ProfileState.setAside) continue;
      try {
        await _move.setFolderAside(entry.id);
      } on FileSystemException catch (e) {
        AppLogger.warning('Data set aside stayed where it was for now (${e.osError?.errorCode})');
      }
    }
  }

  /// A sign-out stopped after the list said locked: what opens the profile
  /// otherwise goes now.
  Future<void> _finishSignOuts() async {
    if (!_list.entries.any((e) => e.state == ProfileState.locked)) return;
    final names = (await keychainNamesIn(device)).toSet();
    for (final entry in _list.entries) {
      if (entry.state != ProfileState.locked) continue;
      // Only where a copy of its key is left: nothing else is read, or written.
      if (!names.contains(ProfileVault.plainName(entry.id)) &&
          !names.contains(ProfileVault.wrappedName(entry.id)) &&
          !names.contains(ProfileVault.hardwareName(entry.id))) {
        continue;
      }
      if (await copies.confirmed(entry.id) != null) await vault.dropCopies(entry.id);
    }
  }

  Future<void> _finishRemovals() async {
    final gone = <String>{};
    for (final entry in List.of(_list.entries)) {
      if (entry.state != ProfileState.removing) continue;
      // One whose folder would not go stays on the list, and is tried again.
      if (await _deleteProfileFiles(entry.id)) gone.add(entry.id);
    }
    if (gone.isNotEmpty) {
      _list.entries.removeWhere((e) => gone.contains(e.id));
      await _list.write(device);
    }
  }

  /// Whether a move to profiles has yet to be checked.
  Future<bool> moveUnderWay() => _move.markerFile.exists();

  /// Whether this start has a move to do or to finish, so the person can be told.
  Future<bool> moveNeeded() => _move.moveNeeded();

  /// Whether the move that stopped has come far enough to be set aside.
  Future<bool> moveCanBeSetAside() => _move.canBeSetAside();

  /// Whether another profile than the one on screen can be opened in its place.
  bool get canOpenAnother => _list.guest != null && _list.guest!.id != _list.current;

  /// The guest profile is what opens at the next start.
  Future<void> openGuestNextStart() async {
    _list.current = _list.guest?.id;
    await _list.write(device);
  }

  /// Opens the profile a start bound, or guest data where there is none yet.
  /// The vault key must be there where the lock is on ([vaultKey]). Migrations
  /// run here, so a failure shows here. Nothing of the app reads a secret until
  /// this is done: an unfinished move finishes first.
  Future<AppDatabase> openCurrent() async {
    var entry = currentEntry;
    if (entry == null || entry.state != ProfileState.open && entry.state != ProfileState.gone) {
      entry = _list.guest ?? await _makeProfile();
      _list.current = entry.id;
      await _list.write(device);
    }
    _bind(entry);
    final hex = await keyHexOf(entry);
    final db = await _openChecked(ProfilePaths.ofProfile(base, entry.id), hex);
    _passedMigrations.add(entry.id);
    try {
      await profileOpened(db);
    } catch (_) {
      await _closeQuietly(db);
      rethrow;
    }
    // A deleted account's data whose question was never answered (the app was
    // ended): kept, as nothing says otherwise.
    if (currentEntry?.state == ProfileState.gone) await keepCurrentAsGuest();
    return db;
  }

  Future<AppDatabase> _openChecked(Directory dir, String hex) async {
    await dir.create(recursive: true);
    final db = await _openDatabase(dir, hex);
    try {
      await db.customSelect('SELECT 1').get();
      return db;
    } catch (_) {
      await _closeQuietly(db);
      rethrow;
    }
  }

  static Future<void> _closeQuietly(AppDatabase db) async {
    try {
      await db.close();
    } catch (_) {/* best effort */}
  }

  /// The profile's database is open: its seal is there, an unfinished move
  /// finishes, what was written while it was closed is sealed, and its settings
  /// are read, or, opened again after the lock, what waited is written.
  Future<void> profileOpened(AppDatabase db) async {
    final entry = currentEntry;
    if (entry == null) throw StateError('No profile is open');
    final seal = await SecretSeal.forProfile(db);
    final moving = await _move.markerFile.exists();
    await _move.afterOpen(db, profile: entry.id, vaultKey: vaultKey);
    // The move may have learnt whose this is (a session sealed by the lock). With no
    // move the list in memory is the one written last, and it is not read again.
    if (moving) _list = await ProfileList.read(device) ?? _list;
    final now = currentEntry!;
    _bind(now);
    final active = _active(now);
    await sealWaitingIn(device, active, seal);
    await _claimWhatWaits(active, seal);
    if (_settingsOf == now.id && prefs.loaded) {
      await prefs.reattach(db);
    } else {
      await prefs.load(db);
      _settingsOf = now.id;
    }
    await _purgeOldCopies(active);
    final key = vaultKey;
    if (key != null) await vault.settleAfterUnlock(_list.withKeyHere, key, hardwareKey: hardwareKey);
  }

  /// What waits for this account, taken in as its profile opens: a sign-in that
  /// stopped after the list named its profile finishes here. Nothing here stands in
  /// the way of the profile opening.
  Future<void> _claimWhatWaits(ActiveProfile active, SecretSeal seal) async {
    final uid = active.uid;
    if (uid == null) return;
    try {
      await keychainBatch(() async {
        await claimHeldEntries(device: device, profile: active, seal: seal, uid: uid, vaultKey: vaultKey);
        await adoptHeldTeamsOf(
            base: base, device: device, profile: active, seal: seal, owners: await readTeamOwners(device), vaultKey: vaultKey);
      });
    } catch (e) {
      AppLogger.warning('What waits for the account stays where it is (${errorKind(e)})');
    }
  }

  /// The database closes with the app lock: the keys in memory go, and what is
  /// written waits. Nothing else changes.
  Future<void> locked() async {
    vaultKey = null;
    hardwareKey = null;
    await prefs.detach();
  }

  /// The database's key of [entry]: plain, or from the vault; made where there
  /// is none and no database that needs it. A key that is gone from over a
  /// database is said, never replaced, as that would make the data unreadable.
  Future<String> keyHexOf(ProfileEntry entry) async {
    final plain = await device.read(key: ProfileVault.plainName(entry.id));
    if (plain != null) return plain;
    final wrapped = await device.read(key: ProfileVault.wrappedName(entry.id)) ??
        await device.read(key: ProfileVault.hardwareName(entry.id));
    if (wrapped != null) {
      final key = vaultKey;
      if (key == null) throw const VaultLockedException('The app lock is on: unlock first');
      return vault.unwrap(entry.id, key, hardwareKey: hardwareKey);
    }
    final file = File(p.join(ProfilePaths.ofProfile(base, entry.id).path, ProfileMove.mainFile));
    if (_strictKeys && await file.exists()) {
      throw StateError(
        'Encryption key not found in secure storage, but database file '
        'already exists. Generating a new key would make existing data '
        'permanently unreadable.',
      );
    }
    final hex = _newKeyHex();
    // What wrapped the key before it (a Reset of a signed-in profile) opens
    // nothing now, and read at a sign-in it would fail at every one, for good.
    await copies.forgetForNewKey(entry.id);
    await _keepKey(entry.id, hex);
    return hex;
  }

  static String _newKeyHex() {
    final rng = Random.secure();
    return List<int>.generate(32, (_) => rng.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// [hex] kept as the profile's key, as the lock stands.
  Future<void> _keepKey(String id, String hex) async {
    final key = vaultKey;
    if (key != null) {
      await vault.wrap(id, hex, key, hardwareKey: hardwareKey);
    } else {
      if (await vault.hasSlots()) throw const VaultLockedException('The app lock is on: unlock first');
      await device.write(key: ProfileVault.plainName(id), value: hex);
      if (await device.read(key: ProfileVault.plainName(id)) != hex) throw StateError('A key did not read back');
    }
  }

  Future<ProfileEntry> _makeProfile({String? uid, String? label, String? id}) async {
    final entry = ProfileEntry(id: id ?? newProfileId(), uid: uid, label: label, made: DateTime.now().millisecondsSinceEpoch);
    await ProfilePaths.ofProfile(base, entry.id).create(recursive: true);
    _list.put(entry);
    await _list.write(device);
    return entry;
  }

  /// The copy the move took first, gone after thirty days: until then, a move
  /// that went wrong in a way nobody foresaw can still be put right by hand.
  Future<void> _purgeOldCopies(ActiveProfile profile) async {
    try {
      final copy = Directory(p.join(profile.dir.path, 'pre_move'));
      if (await copy.exists()) {
        final stat = await copy.stat();
        if (DateTime.now().difference(stat.modified) > const Duration(days: 30)) await copy.delete(recursive: true);
      }
      final aside = Directory(p.join(profile.dir.path, 'orchards', kTeamsSetAsideFolder));
      if (await aside.exists()) {
        for (final file in await aside.list().toList()) {
          if (file is! File) continue;
          final stat = await file.stat();
          if (DateTime.now().difference(stat.modified) > const Duration(days: 30)) await file.delete();
        }
      }
    } catch (e) {
      AppLogger.warning('Old copies were not cleared (${errorKind(e)})');
    }
  }

  // ── A sign-in ──────────────────────────────────────────────────────

  /// What the account [uid] opens, decided before anything changes. Nothing is
  /// written, and a known account whose secret cannot be fetched throws
  /// [ProfileCannotOpen]: it never gets a new profile because ZestSSH Cloud
  /// could not be reached.
  ///
  /// [person] says whose account this now is, where someone just said so ("Add
  /// account"). An account that would be one more than a computer keeps throws, as
  /// nothing is made for it; so does one that only a lost profile knew, when it has
  /// no room of its own.
  Future<AccountPlan> planForAccount({required String uid, String? label, required String? bearer, String? person}) async {
    final known = _list.byUid(uid);
    AccountPlan fresh({ProfileEntry? losing}) {
      final held = _list.accounts.where((e) => e.id != losing?.id).length;
      if (held >= ProfileList.maxAccounts) throw const ProfileCannotOpen('profile-too-many-accounts');
      // A new profile of an account this computer knew (its copy lost, or its data
      // set aside) is that account's person's still: without the mark, the person's
      // other accounts were someone else's (found in a code review).
      final mark = person ?? _list.entries.where((e) => e.uid == uid).map((e) => e.person).nonNulls.firstOrNull;
      return AccountPlan.fresh(uid: uid, label: label, losing: losing, person: mark);
    }

    if (known == null) return fresh();
    if (known.id == _list.current && Profiles.current?.id == known.id) {
      return AccountPlan.same(known, uid: uid, label: label);
    }
    switch (known.state) {
      case ProfileState.locked:
        final copy = await copies.confirmed(known.id);
        if (copy == null) return fresh(losing: known);
        if (bearer == null) throw const ProfileCannotOpen('profile-signed-in-long-ago');
        final Uint8List secret;
        try {
          secret = await api.handBack(bearer: bearer, id: copy.id);
        } on LockedCopyRefused catch (e) {
          if (e.code == 'locked-copy-not-found') return fresh(losing: known);
          if (e.code == 'recent-sign-in-required') throw ProfileCannotOpen('profile-signed-in-long-ago', e);
          throw ProfileCannotOpen('profile-offline', e);
        } catch (e) {
          throw ProfileCannotOpen('profile-offline', e);
        }
        final String hex;
        try {
          hex = await copies.open(known.id, copy, secret);
        } on LockedCopyDoesNotOpen catch (e) {
          throw ProfileCannotOpen('profile-copy-broken', e);
        } finally {
          secret.fillRange(0, secret.length, 0);
        }
        return AccountPlan.known(known, uid: uid, label: label, hex: hex, replaceSecret: true, person: person);
      case ProfileState.open:
      case ProfileState.hidden:
      case ProfileState.gone:
        return AccountPlan.known(known, uid: uid, label: label, hex: await keyHexOf(known), person: person);
      case ProfileState.lost:
      case ProfileState.kept:
      case ProfileState.removing:
      case ProfileState.setAside:
        return fresh();
    }
  }

  /// What a switch to [target] opens, needing no sign-in: an account still signed in
  /// here, or guest data ([ProfileState.kept] included). Nothing changes by asking.
  /// [ProfileCannotOpen] where its key cannot be read, and for one signed out, whose
  /// key is not to be had without that account's sign-in ([planForAccount]).
  Future<AccountPlan> planForSwitch(ProfileEntry target) async {
    if (target.state != ProfileState.open && target.state != ProfileState.kept) {
      throw const ProfileCannotOpen('profile-signed-in-long-ago');
    }
    // Someone else's opens with its own sign-in only (from a security review), whoever
    // asks: the account list asked for it, but a switch itself opened any account
    // still signed in here (found in a code review).
    if (target.uid != null && target.id != _list.current && someoneElses(target)) {
      throw const ProfileCannotOpen('profile-signed-in-long-ago');
    }
    final String hex;
    try {
      hex = await keyHexOf(target);
    } catch (e) {
      throw ProfileCannotOpen('profile-not-opened', e);
    }
    final uid = target.uid;
    return uid == null ? AccountPlan.guest(target, hex: hex) : AccountPlan.known(target, uid: uid, label: target.label, hex: hex);
  }

  /// [planForSwitch] for guest data, made where this computer has none now (what it
  /// held was brought into an account, or removed).
  Future<AccountPlan> planForGuest() async => planForSwitch(_list.guest ?? await _makeProfile());

  /// Opens the plan's database beside the one open now, and checks it. If this
  /// fails nothing has changed: the app stays where it is.
  Future<PreparedProfile> prepare(AccountPlan plan) async {
    final id = plan.known?.id ?? newProfileId();
    final hex = plan.hex ?? _newKeyHex();
    final dir = ProfilePaths.ofProfile(base, id);
    AppDatabase? db;
    try {
      db = plan.isFresh ? await _openChecked(dir, hex) : await _openBeside(id, dir, hex);
      await SecretSeal.forProfile(db);
    } catch (e) {
      if (db != null) await _closeQuietly(db);
      if (plan.isFresh) {
        try {
          if (await dir.exists()) await dir.delete(recursive: true);
        } catch (_) {/* an empty folder says nothing */}
      }
      throw ProfileCannotOpen('profile-not-opened', e);
    }
    _passedMigrations.add(id);
    return PreparedProfile(plan: plan, id: id, db: db, hex: hex);
  }

  /// A database that is not the one a start opened (a sign-in's, guest data's), with
  /// what a start has for its own: migrations are not transactional, and one that
  /// failed halfway would fail at every open, with nothing to go back to.
  Future<AppDatabase> _openBeside(String id, Directory dir, String hex) async {
    final copy = await _copyBeforeOpening(id, dir);
    try {
      final db = await _openChecked(dir, hex);
      _passedMigrations.add(id);
      return db;
    } catch (e) {
      if (copy != null && MigrationBackupService.looksLikeMigrationFailure(e)) await _restoreCopy(id, dir, copy);
      rethrow;
    }
  }

  /// The copy of a database before it opens beside a start, where one can be made and
  /// may be needed. Never stands in the way of the open.
  Future<String?> _copyBeforeOpening(String id, Directory dir) async {
    if (_passedMigrations.contains(id)) return null;
    try {
      // Only where opening it will upgrade it: a copy at every sign-in was a
      // whole copy of the database each time (3.3).
      return await MigrationBackupService.backupBeforeUpgrade(
          schemaVersion: AppDatabase.currentSchemaVersion, folder: dir);
    } catch (e) {
      AppLogger.warning('A copy before opening was not made (${errorKind(e)})');
      return null;
    }
  }

  Future<void> _restoreCopy(String id, Directory dir, String copy) async {
    try {
      if ((await _move.markerAsItIs())?.profile == id) return;
      await MigrationBackupService.restoreFromBackup(copy, folder: dir);
      AppLogger.info('A database that failed its upgrade at a sign-in was put back as it was');
    } catch (e) {
      AppLogger.warning('A database that failed its upgrade was not put back (${errorKind(e)})');
    }
  }

  /// The profile opened by [prepare] is the one from now on: its key kept as
  /// the lock stands, a new account's held secrets and teams taken in, the list
  /// says so, its settings read. Run once the one before it is closed.
  Future<void> commit(PreparedProfile prepared) async {
    final plan = prepared.plan;
    await _keepKey(prepared.id, prepared.hex);
    final entry = ProfileEntry(
      id: prepared.id,
      uid: plan.uid,
      label: plan.label ?? plan.known?.label,
      made: plan.known?.made ?? DateTime.now().millisecondsSinceEpoch,
      person: plan.person ?? plan.known?.person,
    );
    final active = _active(entry);
    final seal = await SecretSeal.forProfile(prepared.db);
    // The list first: held secrets and teams go into a profile it names, and a
    // stop before they do is finished as that profile opens (profileOpened).
    final losing = plan.losing;
    if (losing != null) _list.put(losing.copyWith(state: ProfileState.lost));
    // Guest data set aside comes back in place of what is guest data now, which is
    // set aside in turn: nothing is merged and nothing is lost.
    final guestNow = _list.guest;
    if (entry.uid == null && guestNow != null && guestNow.id != entry.id) {
      _list.put(guestNow.copyWith(state: ProfileState.kept));
    }
    _list.put(entry);
    _list.current = entry.id;
    await _list.write(device);
    _bind(entry);
    // What was written while its database was closed (the lock came, and then a
    // switch or a sign-out), as at any other opening.
    await sealWaitingIn(device, active, seal);
    await _claimWhatWaits(active, seal);
    await prefs.load(prepared.db);
    _settingsOf = entry.id;
  }

  /// A change of profile stopped: the app stays on [id], whose database [db] never
  /// closed, whatever the change had got to. Nothing is written over either one's.
  Future<void> stayOn(String id, AppDatabase db) async {
    final entry = _list.byId(id);
    if (entry == null) return;
    _list.current = id;
    try {
      await _list.write(device);
    } catch (e) {
      AppLogger.warning('The list of profiles was not put back (${errorKind(e)})');
    }
    _bind(entry);
    if (_settingsOf != id || !prefs.loaded) {
      await prefs.load(db);
      _settingsOf = id;
    }
  }

  /// Removes the account [id], which is not on screen, from this computer: its folder,
  /// its keys and its files go, whatever its state; what it synced stays at ZestSSH
  /// Cloud. The list says so first: a removal stopped in between, or a folder something
  /// holds, is finished at a later start, and nothing opens it meanwhile. False where
  /// the folder would not go.
  Future<bool> removeAccount(String id) async {
    final entry = _list.byId(id);
    if (entry == null || entry.uid == null || id == _list.current) return false;
    _list.put(entry.copyWith(state: ProfileState.removing));
    await _list.write(device);
    await _finishRemovals();
    return _list.byId(id) == null;
  }

  /// The session kept in the profile [entry], read without its being on screen, for
  /// what must be told to ZestSSH Cloud as that account: its database opened beside the
  /// one on screen, for its seal. Null where it holds none or does not open.
  Future<String?> sessionOf(ProfileEntry entry) async {
    AppDatabase? db;
    try {
      db = await _openBeside(entry.id, ProfilePaths.ofProfile(base, entry.id), await keyHexOf(entry));
      final opened = db;
      final active = _active(entry);
      final theirs = ProfileKeychain(device, profile: () => active, tree: () => opened);
      return await AccountSecret.sessionToken.read(theirs);
    } catch (e) {
      AppLogger.warning('Another account\'s session could not be read (${errorKind(e)})');
      return null;
    } finally {
      if (db != null) await _closeQuietly(db);
    }
  }

  /// Whether [e] is someone else's than whoever is on screen:
  /// another person's than the account on screen, or from guest data any
  /// account where this computer has had more than one person's. Had, not has: counted
  /// as it stands now, the second person removed their own account and was one person
  /// here, and the first's accounts opened and went from guest data with no sign-in
  /// (found in an independent review). [ProfileList.shared].
  /// Another profile of the account on screen is its own person's, mark or none
  /// (as [ProfileList.peopleHere] counts it): one set aside was someone else's to
  /// Everything (found in a code review).
  bool someoneElses(ProfileEntry e) {
    final current = currentEntry;
    if (current != null && current.uid != null) return !(e.uid == current.uid || e.sameOwnerAs(current));
    return _list.shared;
  }

  /// The mark of whose this is for the next account added as one of the same person's
  /// as [entry], made and kept on [entry] where it has none yet.
  Future<String> personOf(ProfileEntry entry) async {
    final mark = entry.person;
    if (mark != null) return mark;
    final made = newProfileId();
    _list.put(entry.copyWith(person: made));
    await _list.write(device);
    return made;
  }

  /// Tells ZestSSH Cloud of the open profile's locked copy, as far as it can:
  /// after a sign-in, and at each start until it has worked. [replace]: a new
  /// secret takes the place of the one just fetched. False where it is left to
  /// try again; nothing else changes, and nothing is thrown.
  Future<bool> settleLockedCopy({required AppDatabase db, required String? bearer, bool replace = false, bool signedInNow = false}) async {
    final entry = currentEntry;
    if (entry == null || entry.uid == null || bearer == null) return false;
    try {
      return await copies.settle(
        profile: _active(entry),
        hex: await keyHexOf(entry),
        seal: await SecretSeal.forProfile(db),
        bearer: bearer,
        api: api,
        replace: replace,
        signedInNow: signedInNow,
      );
    } catch (e) {
      AppLogger.warning('The locked copy was left to try again (${errorKind(e)})');
      return false;
    }
  }

  // ── A sign-out ─────────────────────────────────────────────────────

  /// Before a sign-out the person asked for, while its sign-in still works
  /// ([bearer]): whether ZestSSH Cloud still holds the locked copy of the
  /// profile on screen, which the lock that follows leaves as the only way in
  /// ([LockedCopyAtCloud]). The copy was confirmed once, long ago, and the lock
  /// trusted that alone: with the copy deleted at ZestSSH Cloud since, or the
  /// account, it dropped the only key to this computer's data, and the next
  /// sign-in found a new, empty profile (found in a data review).
  /// A copy ZestSSH Cloud holds no more opens nothing, and is forgotten here, so
  /// the next sign-in makes a new one.
  Future<LockedCopyAtCloud> lockedCopyAtCloud({required String? bearer}) async {
    final entry = currentEntry;
    if (entry == null || entry.uid == null || bearer == null) return LockedCopyAtCloud.unknown;
    final copy = await copies.confirmed(entry.id);
    // None confirmed: the sign-out hides it, as ever.
    if (copy == null) return LockedCopyAtCloud.unknown;
    try {
      final listed = await api.list(bearer: bearer).timeout(const Duration(seconds: 8));
      if (listed.any((c) => c.id == copy.id)) return LockedCopyAtCloud.held;
    } on LockedCopyRefused catch (e) {
      if (e.code == 'account-not-found') return LockedCopyAtCloud.accountGone;
      AppLogger.warning('ZestSSH Cloud did not say whether it holds the locked copy (${e.code})');
      return LockedCopyAtCloud.unreachable;
    } catch (e) {
      AppLogger.warning('Whether ZestSSH Cloud holds the locked copy was not asked (${errorKind(e)})');
      return LockedCopyAtCloud.unreachable;
    }
    await copies.forgetGone(entry.id, copy.id);
    return LockedCopyAtCloud.gone;
  }

  /// Locks the profile on screen, with its database closed, and needs no
  /// server: the plain and vault-wrapped copies of its key go, and only the one
  /// ZestSSH Cloud's secret opens stays. If that secret never reached ZestSSH
  /// Cloud, or [cloud] does not say ZestSSH Cloud was just found to hold it
  /// ([lockedCopyAtCloud]), the profile is hidden instead, its key kept here,
  /// which the caller says. A sign-out from elsewhere has no session left to
  /// ask with, and locks on the copy confirmed here. The list says so first: a
  /// sign-out stopped in between is finished at the next start.
  Future<SignOutEnd> lockCurrent({LockedCopyAtCloud cloud = LockedCopyAtCloud.held}) async {
    final entry = currentEntry;
    if (entry == null || entry.uid == null) return SignOutEnd.nothing;
    final copy = await copies.confirmed(entry.id);
    if (copy == null || cloud != LockedCopyAtCloud.held) {
      _list.put(entry.copyWith(state: ProfileState.hidden));
      await _list.write(device);
      return SignOutEnd.hidden;
    }
    _list.put(entry.copyWith(state: ProfileState.locked));
    await _list.write(device);
    await vault.dropCopies(entry.id);
    await dropKeychainCopies();
    return SignOutEnd.locked;
  }

  /// The move's copy of the keychain's file holds the database's key as it was
  /// then, plain with the app lock off. Locking a profile or turning the lock on
  /// means that key is to be out of reach, so the copy goes then, early. The copy of
  /// the database stays: it opens with nothing that is left in the open.
  Future<void> dropKeychainCopies() async {
    for (final entry in _list.entries) {
      if (!isProfileId(entry.id)) continue;
      final copy = File(p.join(ProfilePaths.ofProfile(base, entry.id).path, 'pre_move', ProfileMove.keychainCopyName));
      try {
        if (await copy.exists()) await copy.delete();
      } on FileSystemException catch (e) {
        AppLogger.warning('A copy of the keychain was left (${e.osError?.errorCode})');
      }
    }
  }

  // ── Guest data that may be an account's ───────────────────────────

  /// Whether the move found an account signed in here but not which, and made the
  /// data the guest data [id] for now (ProfileMove.whoseUnknownFile).
  Future<bool> whoseUnknown(String id) async {
    final file = ProfileMove.whoseUnknownFile(base);
    try {
      return await file.exists() && (await file.readAsString()).trim() == id;
    } on FileSystemException {
      return false;
    }
  }

  /// The next sign-in has asked whether to bring it in.
  Future<void> forgetWhoseUnknown() async {
    final file = ProfileMove.whoseUnknownFile(base);
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException catch (e) {
      AppLogger.warning('The note of whose data this is was left (${e.osError?.errorCode})');
    }
  }

  // ── Whether a sign-in that is not there was a sign-out ─────────────

  /// Whether Firebase is what keeps a sign-in on this computer, with no session of
  /// the app's own to say so. A Mac build has no Firebase (no GoogleService-Info.plist):
  /// there this is false, and the sign-in is the session in the keychain.
  bool get firebaseKeepsSignIns => firebaseReported != null;

  /// Whether a sign-in kept on this computer may read as nobody with nobody signed
  /// out: Firebase's ([firebaseKeepsSignIns]), or a session in a Mac's keychain
  /// (MacKeychain), whose item macOS may not let the app read, or no longer show it,
  /// after an update or a change of the app's signature (3.4.0 went from ad-hoc to
  /// Developer ID).
  bool get signInMayReadAsNone => firebaseKeepsSignIns || keychainDenials != null;

  /// The accounts Firebase said were signed in, in this run.
  final Set<String> _firebaseSaidIn = {};

  /// Firebase says [uid] is signed in: from now on in this run, Firebase saying
  /// nobody is that account signed out.
  void firebaseSaidSignedIn(String uid) => _firebaseSaidIn.add(uid);

  File get _signOutMarker => File(p.join(ProfilePaths.root(base).path, 'sign_out_v1'));

  /// The person's own sign-out of the profile on screen begins: said first, so one
  /// that stops before its lock is finished at the next start, whatever Firebase says.
  Future<void> signOutBegins() async {
    final entry = currentEntry;
    if (entry == null || entry.uid == null) return;
    await _signOutMarker.parent.create(recursive: true);
    await _signOutMarker.writeAsString(entry.id, flush: true);
  }

  /// The sign-out has locked what it was to lock, or the account is signed in again.
  Future<void> signOutDone() async {
    try {
      if (await _signOutMarker.exists()) await _signOutMarker.delete();
    } on FileSystemException catch (e) {
      AppLogger.warning('The note of a sign-out was left (${e.osError?.errorCode})');
    }
  }

  /// Whether [entry], an account's profile with no session and with Firebase saying
  /// nobody is signed in, was signed out. Where the keychain answers whole (Windows,
  /// Linux) none is a sign-out that stopped. On a Mac none is no sign-out by itself:
  /// the session (or Firebase's sign-in) is in the keychain, and an item macOS did not
  /// let the app read, or no longer showed it, after an update reads as nobody (a
  /// reported problem, where every start then locked the data and
  /// opened empty guest data, saying nothing; 3.3.3 kept it open only where Firebase
  /// kept the sign-in, and the Mac build has no Firebase, so it went on: 3.4.1). There
  /// it is one only where the person's own sign-out began (a session's sign-out always
  /// does, wherever it was asked for), or Firebase said in this run that the account
  /// was signed in.
  Future<bool> signedOut(ProfileEntry entry) async {
    if (!signInMayReadAsNone) return true;
    if (_firebaseSaidIn.contains(entry.uid)) return true;
    try {
      return await _signOutMarker.exists() && (await _signOutMarker.readAsString()).trim() == entry.id;
    } on FileSystemException {
      return false;
    }
  }

  /// [lockCurrent] while the app lock has the database closed: nothing can open
  /// until the PIN, and guest data is what opens then. What the profile had in
  /// memory goes now; nothing of it may be written over the next one's.
  Future<SignOutEnd> lockCurrentWhileClosed({LockedCopyAtCloud cloud = LockedCopyAtCloud.held}) async {
    final end = await lockCurrent(cloud: cloud);
    _list.current = _list.guest?.id;
    await _list.write(device);
    _bind(_list.guest);
    await prefs.forget();
    _settingsOf = null;
    return end;
  }

  /// Opens guest data, made here where there is none: what a sign-out goes on
  /// to, and what a removal does.
  Future<AppDatabase> openGuest() async {
    final entry = _list.guest ?? await _makeProfile();
    _list.current = entry.id;
    await _list.write(device);
    return openCurrent();
  }

  /// In between two profiles: nothing can be read or written under either.
  Future<void> unbind() async {
    _bind(null);
    await prefs.forget();
    _settingsOf = null;
  }

  // ── Deleting ───────────────────────────────────────────────────────

  /// The account of the profile on screen was deleted at ZestSSH Cloud: no
  /// secret will open this profile again, so it is never locked. Until the
  /// person answers, or if nobody does, it stays open.
  Future<void> markAccountGone() async {
    final entry = currentEntry;
    if (entry == null) return;
    _list.put(entry.copyWith(state: ProfileState.gone));
    await _list.write(device);
    await device.delete(key: '${KeychainPrefix.of(entry.id)}${KeychainNames.lockedCopy}');
    await device.delete(key: '${KeychainPrefix.of(entry.id)}${KeychainNames.lockedCopyNext}');
    await device.delete(key: '${KeychainPrefix.of(entry.id)}${KeychainNames.lockedCopySecret}');
    await device.delete(key: '${KeychainPrefix.of(entry.id)}${KeychainNames.lockedCopiesRetired}');
  }

  /// The person kept the data of a deleted account: it becomes the guest data
  /// on screen, as it is. Guest data there was before is set aside whole, for
  /// the switcher; nothing is merged and nothing is lost.
  Future<void> keepCurrentAsGuest() async {
    final entry = currentEntry;
    if (entry == null) return;
    final before = _list.guest;
    if (before != null && before.id != entry.id) _list.put(before.copyWith(state: ProfileState.kept));
    // What was kept under the account's mark can no longer be reached, and is
    // of no use: the account is gone.
    final prefix = KeychainPrefix.of(entry.id);
    for (final name in await keychainNamesIn(device)) {
      if (!name.startsWith(prefix)) continue;
      final inner = name.substring(prefix.length);
      if (KeychainNames.accountPrefixes.any(inner.startsWith)) await device.delete(key: name);
    }
    final now = entry.copyWith(noAccount: true, state: ProfileState.open);
    _list.put(now);
    await _list.write(device);
    _bind(now);
  }

  /// The profile on screen, wiped while it was open (LocalDataWiper), is to go:
  /// the list says so first, so a removal stopped in between is finished at the
  /// next start. Its folder and keys go once its database is closed
  /// ([finishRemovals]). Nothing of another profile, the lock or the list's
  /// other entries is touched.
  Future<void> markCurrentRemoving() async {
    final entry = currentEntry;
    if (entry == null) return;
    _list.put(entry.copyWith(state: ProfileState.removing));
    _list.current = null;
    await _list.write(device);
    _bind(null);
  }

  /// Its folder, its keys, its files, for each profile marked as going.
  Future<void> finishRemovals() => _finishRemovals();

  /// Everything of one profile: its folder, its files, its entries. False where
  /// its folder would not go. An id that is no profile's reaches nothing.
  Future<bool> _deleteProfileFiles(String id) async {
    if (!isProfileId(id)) return true;
    final prefix = KeychainPrefix.of(id);
    final names = await keychainNamesIn(device);
    await keychainBatch(() async {
      for (final name in names) {
        if (name.startsWith(prefix)) await device.delete(key: name);
      }
    });
    final gone = await _deleteFolder(ProfilePaths.ofProfile(base, id));
    try {
      final where = folders();
      for (final dir in personFoldersOf(where, id)) {
        await _deleteFolder(dir);
      }
    } catch (e) {
      AppLogger.warning('A profile\'s files were left (${errorKind(e)})');
    }
    return gone;
  }

  /// The folders of a person's files in [where] for the profile [id]: session
  /// logs, transcripts, automatic backups (in the app's folder, and the copies
  /// for the local backup destination), the picture.
  static List<Directory> personFoldersOf(PersonFolders where, String id) => [
        Directory(p.join(where.documents.path, 'ZestSSH', 'session-logs', id)),
        Directory(p.join(where.documents.path, 'ZestSSH', 'transcripts', id)),
        Directory(p.join(where.documents.path, 'ZestSSH', 'backups', id)),
        Directory(p.join(where.documents.path, 'profile', id)),
        Directory(p.join(where.support.path, 'ZestSSH', 'backups', id)),
      ];

  static Future<bool> _deleteFolder(Directory dir) async {
    for (var attempt = 0;; attempt++) {
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
        return true;
      } on FileSystemException catch (e) {
        if (attempt >= 4) {
          AppLogger.warning('A folder was left (${e.osError?.errorCode})');
          return false;
        }
        await Future<void>.delayed(Duration(milliseconds: 150 * (attempt + 1)));
      }
    }
  }

  /// Everything on this computer, on the person's word: every profile, what
  /// waits for an account, an older version's data, the lock, the list, every
  /// preference. First the lock goes and every profile is marked as going, so
  /// the new guest data that opens next needs nothing of them; the rest once
  /// the database on screen is closed ([finishWipeEverything]).
  Future<void> beginWipeEverything() async {
    await _wipeMarker.parent.create(recursive: true);
    await _wipeMarker.writeAsString('1', flush: true);
    await device.delete(key: ProfileVault.slotsName);
    await device.delete(key: ProfileVault.hardwareOnName);
    vaultKey = null;
    hardwareKey = null;
    for (final entry in List.of(_list.entries)) {
      _list.put(entry.copyWith(state: ProfileState.removing, noAccount: true));
    }
    // Nobody's accounts are here any more: the next to sign in is the first.
    _list.forgetPeople();
    _list.current = null;
    await _list.write(device);
    _bind(null);
  }

  /// The rest of it, with only the new guest data open.
  Future<void> finishWipeEverything() async {
    await _finishRemovals();
    final keep = currentEntry;
    final keepPrefix = keep == null ? null : KeychainPrefix.of(keep.id);
    for (final name in await keychainNamesIn(device)) {
      if (keepPrefix != null && name.startsWith(keepPrefix)) continue;
      if (name == ProfileList.name || name == ProfileList.copyName) continue;
      // Fingerprints of keys the system's agent has yet to give back: taken back at the
      // next opening where an agent did not answer now.
      if (name == 'agent_keys_owed_v1') continue;
      await device.delete(key: name);
    }
    await _deleteFolder(ProfilePaths.heldTeams(base).parent);
    await _deleteFolder(ProfilePaths.setAside(base));
    await forgetKeychainSetAside();
    await _deleteFolder(Directory(p.join(base.path, 'orchards')));
    await _deleteFolder(Directory(p.join(base.path, 'migration_backups')));
    for (final suffix in ['', ...ProfileMove.sideSuffixes]) {
      final file = File(p.join(base.path, '${ProfileMove.mainFile}$suffix'));
      if (await file.exists()) await file.delete();
    }
    await _deleteLooseFiles();
    await rawPrefs.clear();
    if (await _wipeMarker.exists()) await _wipeMarker.delete();
  }

  /// There while everything on this computer is being deleted: a wipe that
  /// stopped is finished at the next start.
  File get _wipeMarker => File(p.join(ProfilePaths.root(base).path, 'wipe_everything_v1'));

  /// What lies outside any profile's folder: what stayed where it was at the
  /// move (a file held open then), and the app's own log files. A backup the
  /// person exported is theirs, and matches none of these.
  Future<void> _deleteLooseFiles() async {
    final PersonFolders where;
    try {
      where = folders();
    } catch (e) {
      AppLogger.warning('Files of a person were left (${errorKind(e)})');
      return;
    }
    bool autoBackup(String name) =>
        name.startsWith('zestssh_auto_') &&
        (name.endsWith('.zest') || name.endsWith('.zest${BackupService.unfinishedSuffix}'));
    final sets = <(Directory, bool Function(String))>[
      (Directory(p.join(where.documents.path, 'ZestSSH', 'session-logs')), (_) => true),
      (Directory(p.join(where.documents.path, 'ZestSSH', 'transcripts')), (_) => true),
      (Directory(p.join(where.documents.path, 'ZestSSH', 'backups')), autoBackup),
      (Directory(p.join(where.support.path, 'ZestSSH', 'backups')), autoBackup),
      (Directory(p.join(where.documents.path, 'profile')), (n) => n.startsWith('avatar_') && n.endsWith('.png')),
      (where.support, (n) => n.startsWith('zestssh_logs_') && n.endsWith('.txt')),
    ];
    for (final (folder, matches) in sets) {
      try {
        if (!await folder.exists()) continue;
        for (final entry in await folder.list().toList()) {
          if (entry is File && matches(p.basename(entry.path))) await entry.delete();
        }
      } catch (e) {
        AppLogger.warning('Files of a person were left (${errorKind(e)})');
      }
    }
  }

  // ── Data that did not open ─────────────────────────────────────────

  /// The profile that did not open, or the move that could not finish, goes to a
  /// folder of its own, and the app starts fresh. Nothing is deleted: not its files,
  /// not its keys, and what a move had yet to touch stays where it was. It is said at
  /// each start until the person puts it back or deletes it.
  ///
  /// The list says so first, so a stop anywhere after that is finished at the next
  /// start. A folder that will not go leaves everything as it was, and throws.
  Future<void> setAsideCurrent() async {
    _list = await ProfileList.read(device) ?? _list;
    final marker = await _move.markerAsItIs();
    // A move that has moved nothing has nothing to set aside, whoever asks: its data
    // would stay at the old place, and no move would ever take it up again.
    if (marker != null && !await _move.canBeSetAside()) return;
    final id = marker?.profile ?? _list.current;
    if (isProfileId(id)) {
      final was = _list.byId(id);
      final current = _list.current;
      _list.put((was ?? ProfileEntry(id: id!, made: DateTime.now().millisecondsSinceEpoch)).copyWith(state: ProfileState.setAside));
      if (_list.current == id) _list.current = null;
      _list.current ??= _list.guest?.id;
      await _list.write(device);
      stop?.call('setAside:listed');
      try {
        await _move.setFolderAside(id!);
      } on FileSystemException {
        if (was != null) {
          _list.put(was);
        } else {
          _list.entries.removeWhere((e) => e.id == id);
        }
        _list.current = current;
        await _list.write(device);
        rethrow;
      }
      stop?.call('setAside:folder');
      await _move.setMarkerAside(id);
      _passedMigrations.remove(id);
    }
    _bind(_list.byId(_list.current));
    await prefs.forget();
    _settingsOf = null;
  }

  /// What was set aside and waits here: of it, only what [where] lets through (the
  /// app passes what the person on screen may act on; found in a security
  /// review). A folder set aside that the list does not name is
  /// nobody's in particular and counts where the list names none.
  Future<bool> setAsideHere({bool Function(ProfileEntry entry)? where}) async {
    final listed = _list.entries.where((e) => e.state == ProfileState.setAside).toList();
    if (listed.any((e) => where == null || where(e))) return true;
    if (listed.isNotEmpty) return false;
    final dir = ProfilePaths.setAside(base);
    return await dir.exists() && !await dir.list().isEmpty;
  }

  /// The newest of what was set aside that [where] lets through: the one the notice
  /// is about.
  Future<ProfileEntry?> newestSetAside({bool Function(ProfileEntry entry)? where}) async {
    ProfileEntry? newest;
    var at = -1;
    for (final entry in _list.entries) {
      if (entry.state != ProfileState.setAside) continue;
      if (where != null && !where(entry)) continue;
      final folder = await _move.asideFolderOf(entry.id);
      final name = folder == null ? '' : p.basename(folder.path);
      final when = int.tryParse(name.substring(name.indexOf('.') + 1)) ?? 0;
      if (when > at) {
        at = when;
        newest = entry;
      }
    }
    return newest;
  }

  File get _putBackFile => File(p.join(ProfilePaths.root(base).path, 'put_back_v1'));

  /// The newest of what was set aside is put back at the next start, when nothing of
  /// the app runs and no file is held: what is on screen may be what goes in its place.
  Future<void> askPutBack({bool Function(ProfileEntry entry)? where}) async {
    final entry = await newestSetAside(where: where);
    if (entry == null) return;
    await _putBackFile.parent.create(recursive: true);
    await _putBackFile.writeAsString(entry.id, flush: true);
  }

  /// Back where it was, with the marker of a move it was in the middle of, and it is
  /// what opens. What stands in its place (the fresh guest data, or a new profile of
  /// the same account) is set aside in turn, so nothing is merged and nothing is lost.
  /// Its folder first and the list in one write: a stop anywhere is gone on from.
  Future<void> _finishPutBack() async {
    final asked = _putBackFile;
    if (!await asked.exists()) return;
    try {
      final id = (await asked.readAsString()).trim();
      // The start's own: what is written here is what the rest of the start reads.
      final list = await _listOfTheStart();
      final entry = list?.byId(id);
      if (list != null && entry != null && entry.state == ProfileState.setAside) {
        await _move.putFolderBack(id);
        stop?.call('putBack:folder');
        final inTheWay = entry.uid != null ? list.byUid(entry.uid!) : list.guest;
        if (inTheWay != null && inTheWay.id != id) list.put(inTheWay.copyWith(state: ProfileState.setAside));
        list.put(entry.copyWith(state: ProfileState.open));
        list.current = id;
        await list.write(device);
        stop?.call('putBack:listed');
      }
      await asked.delete();
    } on FileSystemException catch (e) {
      // It stays set aside, nothing is lost, and the person is told and can ask again.
      AppLogger.warning('Data set aside was not put back (${e.osError?.errorCode})');
      putBackFailed = true;
      try {
        await asked.delete();
      } on FileSystemException {/* the next start tries it again */}
    }
  }

  /// The newest of what was set aside goes, on the person's word: its folder, its
  /// keys, and of a move set aside midway what that had yet to delete.
  Future<void> deleteSetAside({bool Function(ProfileEntry entry)? where}) async {
    final entry = await newestSetAside(where: where);
    if (entry != null) {
      final folder = await _move.asideFolderOf(entry.id);
      final midMove = folder != null && await File(p.join(folder.path, 'move_v1.json')).exists();
      _list.put(entry.copyWith(state: ProfileState.removing));
      await _list.write(device);
      await _finishRemovals();
      if (folder != null) await _deleteFolder(folder);
      if (midMove) await _move.forgetOriginalsOfSetAside();
    }
    if (!_list.entries.any((e) => e.state == ProfileState.setAside)) await _deleteFolder(ProfilePaths.setAside(base));
  }

  /// Whether this computer holds anything a wipe of the profile on screen leaves:
  /// another profile, what waits for another account, the app lock, what an older
  /// version left, what was set aside.
  Future<bool> otherDataHere() async {
    if (_list.entries.any((e) => e.id != _list.current && e.state != ProfileState.removing)) return true;
    if ((await heldTeams()).isNotEmpty) return true;
    if ((await HeldEntries(device).names()).isNotEmpty) return true;
    if (await vault.hasSlots() || await device.read(key: 'security_pin_hash') != null) return true;
    if (await File(p.join(base.path, ProfileMove.mainFile)).exists()) return true;
    return setAsideHere();
  }

  // ── Guest data, and an account ─────────────────────────────────────

  /// The guest profile, where one is here beside the profile on screen and holds a
  /// database.
  Future<ProfileEntry?> _guestToBring() async {
    final guest = _list.guest;
    if (guest == null || guest.id == _list.current || currentEntry?.uid == null) return null;
    final file = File(p.join(ProfilePaths.ofProfile(base, guest.id).path, ProfileMove.mainFile));
    return await file.exists() ? guest : null;
  }

  /// What guest data holds, to ask about it, and what of it would stay out of [into],
  /// the account on screen: null where there is none beside an account on screen, or it
  /// does not open. Nothing changes by asking.
  Future<GuestDataSummary?> lookAtGuest({AppDatabase? into}) async {
    final guest = await _guestToBring();
    if (guest == null) return null;
    AppDatabase? db;
    try {
      final old = db = await _openBeside(guest.id, ProfilePaths.ofProfile(base, guest.id), await keyHexOf(guest));
      final hosts = await old.customSelect('SELECT COUNT(*) AS n FROM connections').getSingle();
      final keys = await old.customSelect('SELECT COUNT(*) AS n FROM identities').getSingle();
      final active = _active(guest);
      return GuestDataSummary(
        hosts: hosts.read<int>('n'),
        keys: keys.read<int>('n'),
        staysOut: await whatStaysOut(from: old, keychain: ProfileKeychain(device, profile: () => active, tree: () => old), into: into),
      );
    } catch (e) {
      AppLogger.warning('Guest data could not be looked at (${errorKind(e)})');
      return null;
    } finally {
      if (db != null) await _closeQuietly(db);
    }
  }

  /// Guest data comes into the profile on screen: its hosts and keys, sealed for this
  /// profile, its session logs and recordings, as a restore brings them, and the rest
  /// of its tables ([kGuestTables] says what comes of each). Of two copies of one thing
  /// the one changed last stands, so what the account changed since stays. Only once
  /// every secret reads back as it should does the guest profile go, with its folder,
  /// its keys and its automatic backups: signing out locks all of this, and no copy
  /// stays in the open. Stopped anywhere nothing is lost: run again it brings the same
  /// again, and a removal under way is finished at the next start. Throws, with guest
  /// data as it was, where it cannot be read or brought in.
  Future<void> bringGuestInto(SyncDataService into, {required AppDatabase db, required FlutterSecureStorage keychain}) async {
    final guest = await _guestToBring();
    if (guest == null) return;
    // A move that has not finished may be of this very profile: it finishes at the next
    // start, and with the profile gone that start would open an empty one.
    if (await _move.moveNeeded()) throw StateError('A move of the data has not finished');
    final dir = ProfilePaths.ofProfile(base, guest.id);
    final old = await _openBeside(guest.id, dir, await keyHexOf(guest));
    try {
      final active = _active(guest);
      final theirs = ProfileKeychain(device, profile: () => active, tree: () => old);
      final from = SyncDataService(
        database: old,
        connectionsDao: old.connectionsDao,
        identitiesDao: old.identitiesDao,
        groupsDao: old.connectionGroupsDao,
        knownHostsDao: old.knownHostsDao,
        snippetsDao: old.snippetsDao,
        snippetCategoriesDao: old.snippetCategoriesDao,
        portForwardRulesDao: old.portForwardRulesDao,
        networksDao: old.networksDao,
        connectionTagsDao: old.connectionTagsDao,
        secureStorage: theirs,
        settingsService: SettingsService(rawPrefs),
      );
      // A secret that will not open here stops it first: nothing has moved.
      final secrets = await _secretsOfGuest(guest, old, theirs);
      // Its hosts and keys. Not its settings: the account's stay. Not what it deleted
      // once: that is none of this account's business. Not how far it saw a store it
      // has none of: this account's would read as gone back.
      final payload = SyncDataService.withoutStoreCount(await from.gatherAll())
        ..remove('settings')
        ..remove('account_keys')
        ..remove('tombstones');
      final state = LocalStateStore(db);
      final result = await into.restoreAll(
        payload,
        merge: SyncMergeBase.lastChanged(
          key: List<int>.generate(32, (_) => Random.secure().nextInt(256)),
          owed: await _secretsOwed(state),
          onTaken: (taken) =>
              state.write(_guestSecretsOwed, jsonEncode([for (final item in taken) if (item.startsWith('identities/')) item])),
        ),
      );
      if (!result.success) throw StateError('It could not be brought in: ${result.error}');
      stop?.call('guest:restored');
      await carryGuestTables(from: old, into: db, taken: result.taken);
      stop?.call('guest:tables');
      await _settleGuestSecrets(secrets, result.taken, db, keychain);
      await state.remove(_guestSecretsOwed);
      stop?.call('guest:secrets');
      // Something holds a file: the guest profile stays, as that file would go with
      // it. Its hosts are in both for now, and it can be asked again.
      final left = await _bringGuestFiles(guest.id, theirs, old, keychain, db);
      if (left > 0) throw GuestFilesHeld(left);
      stop?.call('guest:files');
      final stay = await guestTablesThatStay(old);
      if (stay.isNotEmpty) throw GuestKindsStayed(stay);
    } finally {
      await _closeQuietly(old);
    }
    _list.put(guest.copyWith(state: ProfileState.removing));
    await _list.write(device);
    stop?.call('guest:listed');
    await _finishRemovals();
  }

  /// The keys whose secrets a Bring wrote or was about to, until they read back:
  /// [_settleGuestSecrets]. In the account's database.
  static const _guestSecretsOwed = 'guest.secrets_owed';

  Future<Set<String>> _secretsOwed(LocalStateStore state) async {
    try {
      final raw = await state.read(_guestSecretsOwed);
      return raw == null ? const {} : {...(jsonDecode(raw) as List).cast<String>()};
    } catch (e) {
      AppLogger.warning('What a Bring still owed could not be read (${errorKind(e)})');
      return const {};
    }
  }

  /// Every secret guest data's keys hold, opened. One kept that does not open throws:
  /// read as none, it would go with the guest profile, and it is the only copy.
  Future<Map<String, Map<IdentitySecret, String>>> _secretsOfGuest(
    ProfileEntry guest,
    AppDatabase old,
    FlutterSecureStorage theirs,
  ) async {
    final store = SecureStorageIdentitySecrets(theirs, sealedBy: old);
    final held = <String, Map<IdentitySecret, String>>{};
    var closed = 0;
    for (final identity in await old.identitiesDao.getAll()) {
      for (final secret in IdentitySecret.values) {
        final name = KeychainNames.full(guest.id, guest.uid, SecureStorageIdentitySecrets.keyFor(secret, identity.id));
        if (await device.read(key: name) == null) continue;
        final value = await store.read(identity.id, secret);
        if (value == null) {
          closed++;
        } else {
          (held[identity.id] ??= {})[secret] = value;
        }
      }
    }
    if (closed > 0) throw GuestSecretsNotBrought(closed);
    return held;
  }

  /// Every secret of guest data, through the account's seal, against what it held
  /// ([taken]: the keys the restore wrote). Of a key that came, each reads as guest data
  /// had it; of a key the account's copy stands for, the account's stays, and only what
  /// it has none of is added, so a key the restore could not write in a run that stopped
  /// is not lost. One still not there is written here, as a restore's limits are for
  /// what comes from outside this device; one that then does not read back throws, with
  /// nothing of the guest removed. A key this account has deleted since is not asked
  /// about: that deletion stands, and the question said how many stay out.
  Future<void> _settleGuestSecrets(
    Map<String, Map<IdentitySecret, String>> held,
    Set<String> taken,
    AppDatabase db,
    FlutterSecureStorage keychain,
  ) async {
    final mine = SecureStorageIdentitySecrets(keychain, sealedBy: db);
    final here = {for (final identity in await db.identitiesDao.getAll()) identity.id};
    var failed = 0;
    for (final MapEntry(key: id, value: secrets) in held.entries) {
      if (!here.contains(id)) continue;
      final came = taken.contains('identities/$id');
      for (final MapEntry(key: secret, value: theirs) in secrets.entries) {
        try {
          final kept = await mine.read(id, secret);
          if (kept == theirs || (kept != null && !came)) continue;
          await mine.write(id, secret, theirs);
          if (await mine.read(id, secret) != theirs) failed++;
        } catch (e) {
          AppLogger.warning('A secret of guest data was not brought in (${errorKind(e)})');
          failed++;
        }
      }
    }
    if (failed > 0) throw GuestSecretsNotBrought(failed);
  }

  /// Session logs and recordings of the guest profile, in the folders of the one on
  /// screen. How many could not be moved now, and stay where they are.
  Future<int> _bringGuestFiles(
    String guestId,
    FlutterSecureStorage theirs,
    AppDatabase theirTree,
    FlutterSecureStorage mine,
    AppDatabase myTree,
  ) async {
    final id = _list.current;
    if (!isProfileId(id)) return 0;
    final PersonFolders where;
    try {
      where = folders();
    } catch (e) {
      AppLogger.warning('A person\'s files were not brought in (${errorKind(e)})');
      return 0;
    }
    final logs = Directory(p.join(where.documents.path, 'ZestSSH', 'session-logs'));
    final left = await moveFilesBetween(Directory(p.join(logs.path, guestId)), Directory(p.join(logs.path, id!)));
    final recordings = Directory(p.join(where.documents.path, 'ZestSSH', 'transcripts'));
    return left + await SessionTranscriptService.bringIn(
      from: Directory(p.join(recordings.path, guestId)),
      to: Directory(p.join(recordings.path, id)),
      fromKeychain: theirs,
      fromTree: theirTree,
      toKeychain: mine,
      toTree: myTree,
    );
  }

  // ── Teams with no owner ────────────────────────────────────────────

  /// The teams that wait in the held folder.
  Future<List<String>> heldTeams() async {
    final dir = ProfilePaths.heldTeams(base);
    if (!await dir.exists()) return const [];
    return [
      for (final e in await dir.list().toList())
        if (e is File && e.path.endsWith('.db')) p.basenameWithoutExtension(e.path),
    ];
  }

  /// The key of a held team, for one opened where it is.
  Future<String?> heldTeamKey(String teamId) async => HeldEntries(device).read('orchard_db_key_$teamId', vaultKey: vaultKey);

  /// ZestSSH Cloud's list of the teams of [uid], the account it was asked as, came: a
  /// held team with no owner goes into the profile only when this list names it. [close]
  /// closes one opened where it was while ZestSSH Cloud could not be asked. A list that
  /// comes after a change of profile is another account's, and says nothing of this one.
  Future<void> teamsOnServer(
    Set<String> ids, {
    required String uid,
    required AppDatabase db,
    Future<void> Function(String id)? close,
  }) async {
    final entry = currentEntry;
    if (entry == null || entry.uid != uid) return;
    final owners = await readTeamOwners(device);
    final seal = await SecretSeal.forProfile(db);
    for (final teamId in await heldTeams()) {
      final owner = owners[teamId];
      if (owner != null && owner != entry.uid) continue;
      if (owner == null && !ids.contains(teamId)) {
        if (Profiles.provisionalTeams.remove(teamId)) await close?.call(teamId);
        continue;
      }
      if (Profiles.provisionalTeams.remove(teamId)) await close?.call(teamId);
      await adoptHeldTeam(base: base, device: device, profile: _active(entry), seal: seal, teamId: teamId, vaultKey: vaultKey);
    }
  }

  /// ZestSSH Cloud could not be asked, or has not been yet: a held team with no
  /// owner whose own record names this account can be used where it is, so the
  /// backend being down never stops anyone reaching hosts already on the
  /// device. It is not taken into the profile. [namesMember] looks in it.
  Future<int> useHeldTeamsInPlace(Future<bool> Function(String teamId, String keyHex, String uid) namesMember) async {
    final entry = currentEntry;
    if (entry == null || entry.uid == null) return 0;
    final owners = await readTeamOwners(device);
    var added = 0;
    for (final teamId in await heldTeams()) {
      if (Profiles.provisionalTeams.contains(teamId)) continue;
      final owner = owners[teamId];
      if (owner != null && owner != entry.uid) continue;
      try {
        final key = await heldTeamKey(teamId);
        if (key == null) continue;
        if (await namesMember(teamId, key, entry.uid!)) {
          Profiles.provisionalTeams.add(teamId);
          added++;
        }
      } catch (e) {
        AppLogger.warning('A held team could not be looked at (${errorKind(e)})');
      }
    }
    return added;
  }

  // ── Data elsewhere on this computer ────────────────────────────────

  /// Where the profile on screen, [onScreen], holds nothing, what else on this computer
  /// holds the person's data and opens with a key that is here (as when
  /// a Mac's data seemed wiped by an update, while another folder, or a copy
  /// beside it, may still hold it): other guest data set aside for the switcher, the
  /// copies taken before an upgrade and before the move to profiles, or an account's
  /// data, which its own sign-in opens. Null where it holds something, or nothing is
  /// found. What is set aside has a notice of its own. Nothing is changed by looking:
  /// a copy is looked at in a folder of its own, never where it lies.
  Future<DataElsewhere?> dataElsewhere(AppDatabase onScreen) async {
    if (await _holdsData(onScreen)) return null;
    final current = currentEntry;
    if (current == null) return null;
    final names = (await keychainNamesIn(device)).toSet();
    bool keyHere(String id) =>
        names.contains(ProfileVault.plainName(id)) ||
        (vaultKey != null && (names.contains(ProfileVault.wrappedName(id)) || names.contains(ProfileVault.hardwareName(id))));
    // Guest data of this computer that waits in the switcher.
    for (final e in _list.entries) {
      if (e.id == current.id || e.uid != null || e.state != ProfileState.kept || !keyHere(e.id)) continue;
      final db = File(p.join(ProfilePaths.ofProfile(base, e.id).path, ProfileMove.mainFile));
      if (await _copyHoldsData(e, db)) return DataElsewhere(DataElsewhereKind.open, profile: e.id, file: db);
    }
    // The copies beside the profile on screen, newest first.
    if (keyHere(current.id)) {
      for (final db in await _copiesIn(ProfilePaths.ofProfile(base, current.id))) {
        if (await _copyHoldsData(current, db)) return DataElsewhere(DataElsewhereKind.copy, profile: current.id, file: db);
      }
    }
    // An account's, which only its sign-in opens: on screen is guest data, or another account.
    for (final e in _list.entries) {
      if (e.id == current.id || e.uid == null || e.uid == current.uid) continue;
      if (!await File(p.join(ProfilePaths.ofProfile(base, e.id).path, ProfileMove.mainFile)).exists()) continue;
      final opens = switch (e.state) {
        ProfileState.locked => await copies.confirmed(e.id) != null,
        ProfileState.open || ProfileState.hidden => keyHere(e.id),
        _ => false,
      };
      if (opens && !someoneElses(e)) return DataElsewhere(DataElsewhereKind.signIn, profile: e.id, label: e.label);
    }
    return null;
  }

  static Future<bool> _holdsData(AppDatabase db) async {
    final hosts = await db.customSelect('SELECT COUNT(*) AS n FROM connections').getSingle();
    final keys = await db.customSelect('SELECT COUNT(*) AS n FROM identities').getSingle();
    return hosts.read<int>('n') > 0 || keys.read<int>('n') > 0;
  }

  /// The copies of a profile's database in its folder: those before each upgrade, the
  /// older kind beside it, and the one taken before the move to profiles. Newest first.
  static Future<List<File>> _copiesIn(Directory dir) async {
    final found = <(File, int)>[];
    Future<void> add(File f) async {
      if (await f.exists()) found.add((f, (await f.stat()).modified.millisecondsSinceEpoch));
    }

    final upgrades = Directory(p.join(dir.path, 'migration_backups'));
    if (await upgrades.exists()) {
      for (final f in await upgrades.list().toList()) {
        if (f is File && f.path.endsWith('.db')) await add(f);
      }
    }
    if (await dir.exists()) {
      for (final f in await dir.list().toList()) {
        final name = p.basename(f.path);
        if (f is File && name.startsWith('zestssh_backup_') && name.endsWith('.db')) await add(f);
      }
    }
    await add(File(p.join(dir.path, 'pre_move', ProfileMove.mainFile)));
    found.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final (f, _) in found) f];
  }

  /// [db], a database of [owner]'s or a copy of one, opened in a folder of its own with
  /// [owner]'s key; null where it does not open. What lies where it was is never
  /// opened, nor changed: an upgrade runs on the copy alone.
  Future<(AppDatabase, Directory)?> _openCopy(ProfileEntry owner, File db) async {
    final dir = Directory(p.join(ProfilePaths.root(base).path, 'looking', newProfileId()));
    try {
      final hex = await keyHexOf(owner);
      await dir.create(recursive: true);
      for (final suffix in ['', '-wal']) {
        final f = File('${db.path}$suffix');
        if (await f.exists()) await f.copy(p.join(dir.path, '${ProfileMove.mainFile}$suffix'));
      }
      final opened = await _openChecked(dir, hex);
      return (opened, dir);
    } catch (e) {
      AppLogger.warning('A copy of the data did not open (${errorKind(e)})');
      await _deleteFolder(dir);
      return null;
    }
  }

  Future<bool> _copyHoldsData(ProfileEntry owner, File db) async {
    if (!await db.exists()) return false;
    final opened = await _openCopy(owner, db);
    if (opened == null) return false;
    final (copy, dir) = opened;
    try {
      return await _holdsData(copy);
    } catch (e) {
      AppLogger.warning('A copy of the data could not be read (${errorKind(e)})');
      return false;
    } finally {
      await _closeQuietly(copy);
      await _deleteFolder(dir);
    }
  }

  /// What [found] holds is brought into the profile on screen ([into]), as a restore
  /// does: its hosts, keys and their secrets, and none of its settings. What it was
  /// brought from stays as it is. Throws, with nothing changed here, where it does not open.
  Future<void> bringBack(DataElsewhere found, SyncDataService into) async {
    final owner = _list.byId(found.profile);
    final file = found.file;
    if (owner == null || file == null) throw StateError('Nothing to bring back');
    final opened = await _openCopy(owner, file);
    if (opened == null) throw StateError('It does not open');
    final (copy, dir) = opened;
    try {
      final active = _active(owner);
      final theirs = ProfileKeychain(device, profile: () => active, tree: () => copy);
      final from = SyncDataService(
        database: copy,
        connectionsDao: copy.connectionsDao,
        identitiesDao: copy.identitiesDao,
        groupsDao: copy.connectionGroupsDao,
        knownHostsDao: copy.knownHostsDao,
        snippetsDao: copy.snippetsDao,
        snippetCategoriesDao: copy.snippetCategoriesDao,
        portForwardRulesDao: copy.portForwardRulesDao,
        networksDao: copy.networksDao,
        connectionTagsDao: copy.connectionTagsDao,
        secureStorage: theirs,
        settingsService: SettingsService(rawPrefs),
      );
      final payload = SyncDataService.withoutStoreCount(await from.gatherAll())
        ..remove('settings')
        ..remove('account_keys')
        ..remove('tombstones');
      final result = await into.restoreAll(payload);
      if (!result.success) throw StateError('It could not be brought back: ${result.error}');
    } finally {
      await _closeQuietly(copy);
      await _deleteFolder(dir);
    }
  }
}

/// What [ProfileManager.dataElsewhere] found.
enum DataElsewhereKind {
  /// Other guest data, which a switch opens.
  open,

  /// A copy of the data on screen from before, which can be brought back into it.
  copy,

  /// An account's data, which its own sign-in opens.
  signIn,
}

@immutable
class DataElsewhere {
  const DataElsewhere(this.kind, {required this.profile, this.file, this.label});

  final DataElsewhereKind kind;

  /// The profile whose key opens it.
  final String profile;

  /// The database, or the copy of one.
  final File? file;

  /// What the account is called, where it is one.
  final String? label;
}
