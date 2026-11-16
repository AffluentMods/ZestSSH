import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/desktop_browser_sign_in.dart' show sessionAccountUid;
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/profile_list.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';
import 'package:zestssh/services/profiles/profile_vault.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/type_name.dart';
import 'package:zestssh/utils/error_kind.dart';

// Moving a device to profiles (to-do 60), at the first start of the version
// that has them, before anything opens. It moves real people's data, so it is
// built to stop at any step and go on from there at the next launch, and to
// keep both copies whenever it is in doubt.
//
//  1. A copy of the personal database that includes its write-ahead changes:
//     the window closes without merging them, so the newest changes are often
//     in that file alone. (And before step 3 a copy of the keychain's file, where
//     it is one.)
//  2. The database and its two side files move as one set, with the schema
//     backups and the copies made before each upgrade, by renames on the same
//     disk. The marker records the set first. Teams go to a folder of their
//     own until their account says which is whose.
//  3. Today's keys, by name: the database's plain key, or its copy wrapped by
//     the vault with the vault's slots under their new name. No slot's blob is
//     touched, so this needs no PIN.
//  --- The database opens here (with the app lock on, after the PIN). ---
//  4. Every keychain entry opened under its old name and sealed again under
//     the profile's: a sealed secret is bound to its name, so a copy under the
//     new name would read as missing, and device keys would then be made anew
//     and team databases deleted. Read back and opened before going on.
//  5. The settings that are a person's go into the profile's database.
//  6. The person's files, and the teams known to be the account's.
//  7. Only now the originals are deleted, and the marker goes: the move is
//     checked.

/// The steps, in order. The marker holds the last one finished.
enum MoveStage { started, copied, filesMoved, keysNamed, entriesSealed, settingsMoved, teamsMoved }

/// A file of the set as it was when the copy was taken.
class MovedFile {
  const MovedFile(this.name, this.size, this.hash);

  factory MovedFile.fromJson(Map<String, dynamic> j) =>
      MovedFile(j['name'] as String, j['size'] as int, j['hash'] as String);

  Map<String, dynamic> toJson() => {'name': name, 'size': size, 'hash': hash};

  final String name;
  final int size;

  /// Its SHA-256: a file's modified time says too little, to the second on some
  /// systems, and a change can leave its size as it was.
  final String hash;
}

/// How far a move has come.
class MoveMarker {
  const MoveMarker({required this.profile, required this.stage, this.files = const []});

  /// Throws where it is not one: never an id that is not a profile's, which
  /// would name another folder.
  factory MoveMarker.fromJson(Map<String, dynamic> j) {
    final profile = j['profile'] as String;
    if (!isProfileId(profile)) throw const FormatException('Not the id of a profile');
    return MoveMarker(
      profile: profile,
      stage: MoveStage.values.byName(j['stage'] as String),
      files: [for (final f in j['files'] as List? ?? const []) MovedFile.fromJson(Map<String, dynamic>.from(f as Map))],
    );
  }

  Map<String, dynamic> toJson() => {
        'v': 1,
        'profile': profile,
        'stage': stage.name,
        'files': [for (final f in files) f.toJson()],
      };

  final String profile;
  final MoveStage stage;

  /// The set as the copy found it, to tell it from what an older version made
  /// in its place should one be run before the move is done.
  final List<MovedFile> files;

  MoveMarker at(MoveStage next, {List<MovedFile>? files}) =>
      MoveMarker(profile: profile, stage: next, files: files ?? this.files);
}

/// Takes the digest a chunked hash gives.
class _DigestSink implements Sink<hash.Digest> {
  late hash.Digest value;

  @override
  void add(hash.Digest data) => value = data;

  @override
  void close() {}
}

/// A move that could not go on: nothing is lost, and the next launch goes on
/// from where it stopped.
class ProfileMoveFailed implements Exception, HasTypeName {
  const ProfileMoveFailed(this.step, this.cause);

  final String step;
  final Object cause;

  @override
  String toString() => 'ProfileMoveFailed($step, $cause)';

  @override
  String get typeName => 'ProfileMoveFailed';
}

/// Moves the device to profiles. [stop], in a test, is told each boundary as
/// the move reaches it, and throws to stop it there.
class ProfileMove {
  ProfileMove({
    required this.base,
    required this.device,
    required this.rawPrefs,
    required this.folders,
    this.firebaseUid,
    this.stop,
    Future<ProfileList?> Function()? listOfTheStart,
  }) : _listOfTheStart = listOfTheStart;

  final Directory base;
  final FlutterSecureStorage device;
  final SharedPreferences rawPrefs;
  final PersonFolders Function() folders;

  /// The list of profiles as the start under way read it, where it passes it on
  /// (ProfileManager): [moveNeeded] reads it no second time. On a Mac each read
  /// of it may bring up macOS's question about the keychain (3.3.2: a start read
  /// it five times).
  final Future<ProfileList?> Function()? _listOfTheStart;

  /// The Firebase account signed in (a Mac), which keeps no session token.
  final String? Function()? firebaseUid;

  @visibleForTesting
  final void Function(String boundary)? stop;

  static const mainFile = 'zestssh.db';

  /// The keychain's file as the move found it, in the profile's `pre_move`.
  static const keychainCopyName = 'keychain.dat';

  /// The set, its side files before the main file. With the main file last, an
  /// app or an older version stopped in between finds a database where there
  /// was one, with no newer changes, and never an empty one.
  static const sideSuffixes = ['-shm', '-wal', '-journal'];

  /// The keys with names of their own in step 3, of the old layout.
  static const _oldKeyNames = {
    KeychainNames.databaseKey,
    KeychainNames.wrappedDatabaseKey,
    KeychainNames.hardwareWrappedDatabaseKey,
  };

  /// How long another process's move is waited for (`zestssh admin`, which runs
  /// beside the app, or a second start on Linux).
  static const _otherProcessWait = Duration(seconds: 60);

  /// Set once this run copied the set: nothing came between that and the move, so
  /// it is not read a third and a fourth time.
  bool _copiedThisRun = false;

  /// The originals as this run read them to seal them: read again at the end they
  /// might ask a person again, on a Mac, for each.
  Map<String, String>? _originalsRead;

  File get markerFile => File(p.join(ProfilePaths.root(base).path, 'move_v1.json'));

  /// One process moves at a time. The operating system lets go of it where a
  /// process ends, so a stop leaves nothing to clean up.
  Future<T> _holdingMoveLock<T>(Future<T> Function() body) async {
    final root = ProfilePaths.root(base);
    await root.create(recursive: true);
    final handle = await File(p.join(root.path, 'move.lock')).open(mode: FileMode.append);
    try {
      final until = DateTime.now().add(_otherProcessWait);
      while (true) {
        try {
          await handle.lock(FileLock.exclusive);
          break;
        } on FileSystemException {
          if (DateTime.now().isAfter(until)) throw const ProfileMoveFailed('lock', 'another process is moving');
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
      return await body();
    } finally {
      await handle.close();
    }
  }

  Directory _profileDir(String id) => ProfilePaths.ofProfile(base, id);

  Directory _copyDir(String id) => Directory(p.join(_profileDir(id).path, 'pre_move'));

  void _at(String boundary) => stop?.call(boundary);

  /// How far the move came, or null where there is none. A marker that cannot be
  /// read is set aside, and what it said is worked out from what is on the disk.
  Future<MoveMarker?> readMarker() async {
    final file = markerFile;
    if (!await file.exists()) return null;
    try {
      return MoveMarker.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } on FileSystemException {
      rethrow;
    } catch (_) {
      return _markerFromTheDisk(file);
    }
  }

  /// The marker as it is, with nothing changed by reading it: null where there is
  /// none, or it cannot be read.
  Future<MoveMarker?> markerAsItIs() async {
    final file = markerFile;
    try {
      if (!await file.exists()) return null;
      return MoveMarker.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Whether setting this move aside can mean anything: from the files moved on. A
  /// move that stopped before that has moved nothing, and Try again is all there is
  /// to it: setting it aside would leave the data at the old place, taken for what an
  /// older version left, and no move would ever take it up again.
  Future<bool> canBeSetAside() async {
    final marker = await markerAsItIs();
    return marker != null && marker.stage.index >= MoveStage.filesMoved.index;
  }

  /// Whether the marker there is of data that was set aside: all it asks is to go
  /// with it.
  Future<bool> _markerIsOfSetAside() async {
    final marker = await markerAsItIs();
    if (marker == null) return false;
    return (await ProfileList.read(device))?.byId(marker.profile)?.state == ProfileState.setAside;
  }

  /// It is written whole, so this takes a fault of the disk or someone's hand.
  /// Every step can run again, so the move goes on from its copy. With no copy
  /// nothing had moved. With several, nothing here can tell which, and that is
  /// said (the error screen offers to set the data aside).
  Future<MoveMarker?> _markerFromTheDisk(File file) async {
    AppLogger.warning('The marker of the move could not be read');
    var found = <String>[];
    final root = ProfilePaths.root(base);
    for (final entry in await root.list().toList()) {
      final id = p.basename(entry.path);
      if (entry is Directory && isProfileId(id) && await _copyDir(id).exists()) found.add(id);
    }
    // More than one copy: the one that holds a database is the one under way.
    if (found.length > 1) {
      found = [
        for (final id in found)
          if (await File(p.join(_profileDir(id).path, mainFile)).exists()) id,
      ];
    }
    if (found.length > 1) throw const ProfileMoveFailed('marker', 'it cannot be read, and several copies are here');
    await _rename(file, '${file.path}.broken.${DateTime.now().millisecondsSinceEpoch}');
    if (found.isEmpty) return null;
    final id = found.single;
    final files = <MovedFile>[];
    for (final entry in await _copyDir(id).list().toList()) {
      final name = p.basename(entry.path);
      if (entry is File && name.startsWith(mainFile) && !name.endsWith('.part')) {
        files.add(MovedFile(name, await entry.length(), await _hashOf(entry)));
      }
    }
    final marker = MoveMarker(profile: id, stage: MoveStage.copied, files: files);
    await _writeMarker(marker);
    return marker;
  }

  /// Whether a start has a move to do or to finish. Nothing is changed by asking,
  /// so the person can be told before it begins.
  Future<bool> moveNeeded() async {
    if (await markerFile.exists()) return !await _markerIsOfSetAside();
    if (await (_listOfTheStart ?? () => ProfileList.read(device))() != null) return false;
    return _oldLayoutThere();
  }

  /// Written to a temporary name and renamed, so it is whole or the last one.
  Future<void> _writeMarker(MoveMarker marker) async {
    final file = markerFile;
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    final sink = await temp.open(mode: FileMode.write);
    await sink.writeString(jsonEncode(marker.toJson()));
    await sink.flush();
    await sink.close();
    await _rename(temp, file.path);
  }

  /// Whether this device holds data from before profiles.
  Future<bool> _oldLayoutThere() async {
    if (await File(p.join(base.path, mainFile)).exists()) return true;
    for (final name in await keychainNamesIn(device)) {
      if (_isOldEntry(name) || _oldKeyNames.contains(name)) return true;
    }
    return rawPrefs.getKeys().any((key) => SettingsService.isProfileKey(key) && !ProfilePreferences.layered.contains(key));
  }

  /// Whether [name] is an entry of the old layout that a profile takes over.
  static bool _isOldEntry(String name) {
    if (KeychainNames.isDevice(name) || name.startsWith('p.') || name.startsWith('vault2_')) return false;
    return !_oldKeyNames.contains(name);
  }

  /// A file that could not be moved says so without its path, which has a
  /// person's name in it, and the next start goes on from there.
  static Future<T> _sayingNoPath<T>(String step, Future<T> Function() work) async {
    try {
      return await work();
    } on FileSystemException catch (e) {
      throw ProfileMoveFailed(step, 'file error ${e.osError?.errorCode}');
    }
  }

  /// The part before anything opens. Returns the marker, or null where no move
  /// is under way: a clean device, or one moved long ago.
  Future<MoveMarker?> beforeOpen() => _sayingNoPath('before opening', () async {
        if (!await markerFile.exists() && !await moveNeeded()) return null;
        return _holdingMoveLock(_beforeOpen);
      });

  Future<MoveMarker?> _beforeOpen() async {
    // What another process did while this one waited for the lock counts.
    var marker = await readMarker();
    if (marker != null && (await ProfileList.read(device))?.byId(marker.profile)?.state == ProfileState.setAside) {
      // Its data was set aside, and a stop or a held file left the marker behind. It
      // goes with the data: no other database ever runs this move.
      await setFolderAside(marker.profile);
      await setMarkerAside(marker.profile);
      return null;
    }
    if (marker == null) {
      if (await ProfileList.read(device) != null) return null;
      if (!await _oldLayoutThere()) return null;
      marker = MoveMarker(profile: newProfileId(), stage: MoveStage.started);
      await _writeMarker(marker);
      _at('started');
    }
    if (marker.stage == MoveStage.started) {
      final files = await _copySet(marker.profile);
      marker = marker.at(MoveStage.copied, files: files);
      await _writeMarker(marker);
      _at('copied');
    }
    if (marker.stage == MoveStage.copied) {
      await _moveSet(marker);
      await _holdTeams();
      marker = marker.at(MoveStage.filesMoved);
      await _writeMarker(marker);
      _at('filesMoved');
    }
    if (marker.stage == MoveStage.filesMoved) {
      // The keychain's file as it is, before anything in it changes.
      await copyKeychainFileTo(p.join(_copyDir(marker.profile).path, keychainCopyName));
      await _nameKeys(marker);
      marker = marker.at(MoveStage.keysNamed);
      await _writeMarker(marker);
      _at('keysNamed');
    }
    return marker;
  }

  // ── Step 1: the copy ───────────────────────────────────────────────

  Future<List<MovedFile>> _copySet(String id) async {
    final dir = _copyDir(id);
    await dir.create(recursive: true);
    final out = <MovedFile>[];
    for (final name in [mainFile, for (final s in sideSuffixes) '$mainFile$s']) {
      final source = File(p.join(base.path, name));
      if (!await source.exists()) continue;
      // Hashed as it is copied, so a large database is read once for both.
      final temp = File(p.join(dir.path, '$name.part'));
      final digest = _DigestSink();
      final hashing = hash.sha256.startChunkedConversion(digest);
      final copying = temp.openWrite();
      var size = 0;
      await for (final chunk in source.openRead()) {
        hashing.add(chunk);
        copying.add(chunk);
        size += chunk.length;
      }
      hashing.close();
      await copying.close();
      final sink = await temp.open(mode: FileMode.append);
      await sink.flush();
      await sink.close();
      final sum = digest.value.toString();
      if (await temp.length() != size || await _hashOf(temp) != sum) throw const ProfileMoveFailed('copy', 'not the same');
      await _rename(temp, p.join(dir.path, name));
      out.add(MovedFile(name, size, sum));
      _at('copied:$name');
    }
    _copiedThisRun = true;
    return out;
  }

  // ── Step 2: the set ────────────────────────────────────────────────

  Future<void> _moveSet(MoveMarker marker) async {
    final id = marker.profile;
    final to = _profileDir(id);
    await to.create(recursive: true);
    final recorded = {for (final f in marker.files) f.name: f};
    // Side files first (see [sideSuffixes]).
    for (final name in [for (final s in sideSuffixes) '$mainFile$s', mainFile]) {
      final file = recorded[name];
      final source = File(p.join(base.path, name));
      final target = File(p.join(to.path, name));
      if (await target.exists()) {
        // Already moved, and what is at the old name now, if anything, is an
        // older version's: it stays there.
        continue;
      }
      if (file == null) {
        // Not in the set: a side file that came after the copy can only be an
        // older version's, and stays.
        continue;
      }
      if (await source.exists() && await _isAsRecorded(source, file)) {
        await _rename(source, target.path);
      } else {
        // Gone or changed since the copy: an older version ran in between. The
        // copy is what this set was; what is there now stays where it is.
        await File(p.join(_copyDir(id).path, name)).copy(target.path);
      }
      _at('moved:$name');
    }
    // The schema backups and the copies made before each upgrade.
    if (await base.exists()) {
      for (final entry in await base.list().toList()) {
        final name = p.basename(entry.path);
        if (entry is File && name.startsWith('zestssh_backup_') && name.endsWith('.db')) {
          final target = File(p.join(to.path, name));
          if (!await target.exists()) await _rename(entry, target.path);
          _at('moved:$name');
        }
      }
    }
    final upgrades = Directory(p.join(base.path, 'migration_backups'));
    if (await upgrades.exists()) {
      final target = Directory(p.join(to.path, 'migration_backups'));
      await target.create(recursive: true);
      for (final entry in await upgrades.list().toList()) {
        if (entry is! File) continue;
        final into = File(p.join(target.path, p.basename(entry.path)));
        if (!await into.exists()) await _rename(entry, into.path);
      }
      _at('moved:migration_backups');
    }
  }

  /// Whether [file] is as the copy found it. In the run that took the copy nothing
  /// can have come between; after a stop an older version may have.
  Future<bool> _isAsRecorded(File file, MovedFile recorded) async =>
      await file.length() == recorded.size && (_copiedThisRun || await _hashOf(file) == recorded.hash);

  static Future<String> _hashOf(File file) async => (await hash.sha256.bind(file.openRead()).first).toString();

  /// Teams go where an older version run after the move does not see them, as
  /// it would read their keys as lost and delete them. Which is whose comes
  /// later ([adoptHeldTeam]).
  Future<void> _holdTeams() async {
    final from = Directory(p.join(base.path, 'orchards'));
    if (!await from.exists()) return;
    final to = ProfilePaths.heldTeams(base);
    await to.create(recursive: true);
    final mains = [
      for (final e in await from.list().toList())
        if (e is File && e.path.endsWith('.db')) e,
    ];
    for (final main in mains) {
      final name = p.basename(main.path);
      await moveTeamFiles(from, to, name);
      _at('held:$name');
    }
  }

  // ── Step 3: the keys, by name ──────────────────────────────────────

  Future<void> _nameKeys(MoveMarker marker) async {
    final id = marker.profile;
    final plain = await device.read(key: KeychainNames.databaseKey);
    final wrapped = await device.read(key: KeychainNames.wrappedDatabaseKey);
    final hardware = await device.read(key: KeychainNames.hardwareWrappedDatabaseKey);
    final slots = await device.read(key: 'vault_slots');
    // As the app lock's own start-up check said it: the plain key there means
    // a turning on or off that stopped, and the lock is off.
    if (plain != null) {
      await _keep(ProfileVault.plainName(id), plain);
    } else {
      if (wrapped != null) await _keep(ProfileVault.wrappedName(id), wrapped);
      if (hardware != null) {
        await _keep(ProfileVault.hardwareName(id), hardware);
        await _keep(ProfileVault.hardwareOnName, '1');
      }
      if (slots != null) await _keep(ProfileVault.slotsName, slots);
    }
    _at('keys');
    // The lock's switches under their new names.
    if (!rawPrefs.containsKey('lock2_app_lock')) {
      await rawPrefs.setBool('lock2_app_lock', rawPrefs.getBool('security_lock_enabled') ?? false);
    }
    if (!rawPrefs.containsKey('lock2_encrypting')) {
      await rawPrefs.setBool('lock2_encrypting', plain == null && slots != null && (wrapped != null || hardware != null));
    }
    final list = await ProfileList.read(device) ?? ProfileList();
    // Run again after a marker that could not be read, what it wrote stands: the
    // names it read from may be gone by now. Set aside before this step and put
    // back, it has an entry with no account yet.
    final named = list.byId(id);
    if (named == null || named.uid == null) {
      final uid = await _accountAtFirstStart();
      if (uid == null && await _anAccountWasSignedIn()) await _noteWhoseUnknown(id);
      // What the account is called: the question of Delete all local data says it.
      final label = uid == null ? null : await device.read(key: 'session_email');
      list.put(ProfileEntry(
        id: id,
        uid: uid,
        label: label != null && !SecretSeal.isSealed(label) ? label : null,
        made: named?.made ?? DateTime.now().millisecondsSinceEpoch,
      ));
    }
    list.current = id;
    await list.write(device);
  }

  Future<void> _keep(String name, String value) async {
    await device.write(key: name, value: value);
    if (await device.read(key: name) != value) throw const ProfileMoveFailed('keys', 'read back');
  }

  /// The account signed in at the first start: its data is what is here. A
  /// session sealed away by the app lock with no id beside it is read again
  /// after the PIN ([_accountOnceOpen]).
  Future<String?> _accountAtFirstStart() async {
    final firebase = firebaseUid?.call();
    if (firebase != null) return firebase;
    final token = await device.read(key: 'session_token');
    final kept = await device.read(key: 'session_uid');
    // Which account was signed in, where that is said with no session (3.3.3): the data
    // is that account's, never guest data on Firebase's or a session's word of nobody.
    if (kept != null && kept.isNotEmpty && !SecretSeal.isSealed(kept)) return kept;
    if (token == null) return null;
    return SecretSeal.isSealed(token) ? null : sessionAccountUid(token);
  }

  /// Whether an account was signed in here before, whoever it was: what a sign-in
  /// leaves in the old layout and its sign-out takes away (the account's address, the
  /// tier ZestSSH Cloud last said).
  Future<bool> _anAccountWasSignedIn() async {
    if (rawPrefs.containsKey('desktop_entitlement_checked_at')) return true;
    final names = (await keychainNamesIn(device)).toSet();
    return names.contains('session_email') || names.contains('session_token') || names.contains('session_uid');
  }

  /// Where the move found that an account was signed in, but not which: the data is
  /// guest data for now, which is said, and the next sign-in asks whether to bring it in.
  static File whoseUnknownFile(Directory base) => File(p.join(ProfilePaths.root(base).path, 'whose_unknown_v1'));

  Future<void> _noteWhoseUnknown(String id) async {
    final file = whoseUnknownFile(base);
    await file.parent.create(recursive: true);
    await file.writeAsString(id, flush: true);
  }

  // ── After the database opened ──────────────────────────────────────

  /// The part with the database open, from the new place under the new key's
  /// name. [db] is that database; [vaultKey] the vault key while the app lock
  /// is on. Until this has run nothing else of the app may read a secret: it
  /// would read as missing. [profile] is whose database [db] is: a marker of another
  /// is none of its business, as its secrets would be sealed with this one's seal.
  Future<void> afterOpen(AppDatabase db, {required String profile, SecretKey? vaultKey}) =>
      _sayingNoPath('after opening', () async {
        if (!await markerFile.exists()) return;
        await _holdingMoveLock(() => _afterOpen(db, profile, vaultKey));
      });

  Future<void> _afterOpen(AppDatabase db, String profile, SecretKey? vaultKey) async {
    var marker = await readMarker();
    if (marker == null || marker.profile != profile) return;
    final seal = await SecretSeal.forProfile(db);
    if (marker.stage == MoveStage.keysNamed) {
      await _accountOnceOpen(marker, seal);
      // All of them reach the keychain together, or none: on Windows each write
      // would rewrite the whole file, once for each secret.
      await keychainBatch(() => _sealEntries(marker!, seal, vaultKey));
      marker = marker.at(MoveStage.entriesSealed);
      await _writeMarker(marker);
      _at('entriesSealed');
    }
    if (marker.stage == MoveStage.entriesSealed) {
      await _moveSettings(db);
      marker = marker.at(MoveStage.settingsMoved);
      await _writeMarker(marker);
      _at('settingsMoved');
    }
    if (marker.stage == MoveStage.settingsMoved) {
      await keychainBatch(() => _moveFiles(marker!.profile, db, vaultKey));
      marker = marker.at(MoveStage.teamsMoved);
      await _writeMarker(marker);
      _at('teamsMoved');
    }
    if (marker.stage == MoveStage.teamsMoved) {
      await keychainBatch(() => _deleteOriginals(marker!, seal, vaultKey));
      await markerFile.delete();
      _at('done');
    }
  }

  /// The account, where only the sealed session could say it.
  Future<void> _accountOnceOpen(MoveMarker marker, SecretSeal seal) async {
    final list = await ProfileList.read(device);
    final entry = list?.byId(marker.profile);
    if (list == null || entry == null || entry.uid != null) return;
    final firebase = firebaseUid?.call();
    var uid = firebase;
    if (uid == null) {
      final stored = await device.read(key: 'session_token');
      if (stored == null) return;
      try {
        uid = sessionAccountUid(await seal.open('session_token', stored));
      } on SecretSealBroken {
        return;
      }
    }
    if (uid == null) return;
    list.put(entry.copyWith(uid: uid));
    await list.write(device);
  }

  Future<void> _sealEntries(MoveMarker marker, SecretSeal seal, SecretKey? vaultKey) async {
    final list = await ProfileList.read(device);
    final uid = list?.byId(marker.profile)?.uid;
    final held = HeldEntries(device);
    final all = await keychainEntriesIn(device, _isOldEntry);
    _originalsRead = all;
    final names = all.keys.toList()..sort();
    for (final name in names) {
      final stored = all[name]!;
      final String value;
      try {
        value = await seal.open(name, stored);
      } on SecretSealBroken {
        // Sealed by a database since reset: it reads as none today, and stays
        // where it is. Nothing is lost by leaving it.
        AppLogger.warning('A sealed secret that does not open was left as it was');
        continue;
      }
      final owner = KeychainNames.accountOf(name);
      if (name.startsWith('orchard_db_key_') || (owner != null && owner != uid)) {
        // A team's key, or another account's secret: it waits for its owner.
        // Sealed by a seal that is now one profile's, it would be out of reach.
        await held.put(name, value, vaultKey: vaultKey);
      } else {
        final full = KeychainNames.full(marker.profile, uid, name);
        await device.write(key: full, value: await seal.seal(full, value));
        final back = await device.read(key: full);
        if (back == null || await seal.open(full, back) != value) throw const ProfileMoveFailed('entries', 'read back');
      }
      _at('entry:$name');
    }
  }

  // ── Step 5: the settings ───────────────────────────────────────────

  Future<void> _moveSettings(AppDatabase db) async {
    final values = <String, Object>{};
    for (final key in rawPrefs.getKeys()) {
      if (!SettingsService.isProfileKey(key)) continue;
      final value = rawPrefs.get(key);
      if (value == null) continue;
      values[key] = value is List ? value.cast<String>().toList() : value;
    }
    await ProfilePreferences.importInto(db, values);
    _at('settingsInDatabase');
    for (final key in values.keys) {
      // What the lock screen looks like stays on the device as well.
      if (ProfilePreferences.layered.contains(key)) continue;
      await rawPrefs.remove(key);
    }
  }

  // ── Step 6: the person's files, and the teams known to be theirs ───

  Future<void> _moveFiles(String id, AppDatabase db, SecretKey? vaultKey) async {
    final PersonFolders where;
    try {
      where = folders();
    } catch (e) {
      AppLogger.warning('Moving to profiles: no folders of a person (${errorKind(e)})');
      return;
    }
    await moveFolderContents(Directory(p.join(where.documents.path, 'ZestSSH', 'session-logs')), id);
    await moveFolderContents(Directory(p.join(where.documents.path, 'ZestSSH', 'transcripts')), id);
    // Automatic backups, in the app's folder and as the local backup
    // destination's copies. A backup the person exported stays where they put it.
    bool autoBackup(String name) => name.startsWith('zestssh_auto_') && name.endsWith('.zest');
    await moveFolderContents(Directory(p.join(where.support.path, 'ZestSSH', 'backups')), id, only: autoBackup);
    await moveFolderContents(Directory(p.join(where.documents.path, 'ZestSSH', 'backups')), id, only: autoBackup);
    await _moveAvatar(where, id, db);
    _at('files');

    final list = await ProfileList.read(device);
    final uid = list?.byId(id)?.uid;
    if (uid != null) {
      final owners = await readTeamOwners(device);
      await adoptHeldTeamsOf(base: base, device: device, profile: ActiveProfile(id: id, dir: _profileDir(id), uid: uid),
          seal: await SecretSeal.forProfile(db), owners: owners, vaultKey: vaultKey, stop: _at);
    }
  }

  /// The custom picture moves, and the setting says where.
  Future<void> _moveAvatar(PersonFolders where, String id, AppDatabase db) async {
    const key = 'profile_custom_avatar_path';
    final stored = (await ProfilePreferences.readStored(db))[key];
    if (stored is! String || stored.isEmpty) return;
    final from = File(stored);
    if (!await from.exists()) return;
    final folder = Directory(p.join(where.documents.path, 'profile', id));
    if (p.isWithin(folder.path, stored)) return;
    try {
      await folder.create(recursive: true);
      final to = p.join(folder.path, p.basename(stored));
      await _rename(from, to);
      await db.customStatement(
        'UPDATE local_state SET value = ? WHERE key = ?',
        [jsonEncode(to), '${ProfilePreferences.storePrefix}$key'],
      );
    } catch (e) {
      // It stays where it is, and the setting with it: the picture still shows.
      AppLogger.warning('Moving to profiles: the picture stayed (${errorKind(e)})');
    }
  }

  // ── Set aside, and put back ────────────────────────────────────────

  /// The newest folder of what was set aside of the profile [id], if any.
  Future<Directory?> asideFolderOf(String id) async {
    final dir = ProfilePaths.setAside(base);
    if (!await dir.exists()) return null;
    Directory? newest;
    var at = -1;
    for (final entry in await dir.list().toList()) {
      final name = p.basename(entry.path);
      if (entry is! Directory || !name.startsWith('$id.')) continue;
      final when = int.tryParse(name.substring(id.length + 1)) ?? 0;
      if (when > at) {
        at = when;
        newest = entry;
      }
    }
    return newest;
  }

  /// The profile [id], which the list already says is set aside, goes to a folder of
  /// its own. Throws where it cannot. Run again it does what is left.
  Future<void> setFolderAside(String id) async {
    final from = _profileDir(id);
    if (!await from.exists()) return;
    final to = Directory(p.join(ProfilePaths.setAside(base).path, '$id.${DateTime.now().millisecondsSinceEpoch}'));
    await to.parent.create(recursive: true);
    await _renameFolder(from, to.path);
  }

  /// The marker of a move of [id], which was set aside, goes with it. One that cannot
  /// go now is moved at the next start, and until then it runs for no database of
  /// anyone else ([afterOpen]).
  Future<void> setMarkerAside(String id) async {
    final marker = await markerAsItIs();
    if (marker?.profile != id) return;
    final aside = await asideFolderOf(id);
    try {
      await _rename(markerFile, aside != null ? p.join(aside.path, 'move_v1.json') : '${markerFile.path}.set_aside.$id');
    } on FileSystemException catch (e) {
      AppLogger.warning('The marker of a move set aside stayed for now (${e.osError?.errorCode})');
    }
  }

  /// The profile [id] back in its place, with the marker of the move it was in the
  /// middle of. Run again it does what is left.
  Future<void> putFolderBack(String id) async {
    final to = _profileDir(id);
    final aside = await asideFolderOf(id);
    if (aside != null && !await to.exists()) await _renameFolder(aside, to.path);
    final kept = File(p.join(to.path, 'move_v1.json'));
    if (await kept.exists()) await _rename(kept, markerFile.path);
  }

  /// A move set aside midway is being deleted: what it had yet to delete goes with
  /// it, the entries under their old names and the settings in the system's store.
  /// Where a database is at the old place they are an older version's, and stay.
  Future<void> forgetOriginalsOfSetAside() async {
    if (await File(p.join(base.path, mainFile)).exists()) return;
    await deleteOldLayoutEntries(device, rawPrefs);
  }

  // ── Step 7: the originals ──────────────────────────────────────────

  Future<void> _deleteOriginals(MoveMarker marker, SecretSeal seal, SecretKey? vaultKey) async {
    // An older version made a database at the old place while this move was
    // under way: its key and its secrets are the old names, and they stay until
    // the person says what becomes of it (OlderVersionData).
    final olderVersionRan = await File(p.join(base.path, mainFile)).exists();
    if (!olderVersionRan) {
      final held = HeldEntries(device);
      final list = await ProfileList.read(device);
      final uid = list?.byId(marker.profile)?.uid;
      final originals = _originalsRead ?? await keychainEntriesIn(device, _isOldEntry);
      _originalsRead = null;
      for (final name in originals.keys.toList()) {
        // Only an original whose copy opens to the same value goes. One that did
        // not open was moved nowhere, and one whose copy differs is all there is.
        final String original;
        try {
          original = await seal.open(name, originals[name]!);
        } on SecretSealBroken {
          continue;
        }
        final full = KeychainNames.full(marker.profile, uid, name);
        if (!await _copyOpensTo(seal, full, await device.read(key: full), original) &&
            await held.read(name, vaultKey: vaultKey) != original) {
          AppLogger.warning('A secret whose copy did not open to the same was left as it was');
          continue;
        }
        await device.delete(key: name);
        _at('deleted:$name');
      }
      // What opens the database and the lock's slots are moved by name, as they
      // are: each goes if its new name holds the same.
      final id = marker.profile;
      for (final (old, moved) in [
        (KeychainNames.databaseKey, ProfileVault.plainName(id)),
        (KeychainNames.wrappedDatabaseKey, ProfileVault.wrappedName(id)),
        (KeychainNames.hardwareWrappedDatabaseKey, ProfileVault.hardwareName(id)),
        ('vault_slots', ProfileVault.slotsName),
      ]) {
        final was = await device.read(key: old);
        if (was == null) continue;
        // A plain key beside the wraps is what a turning on or off that stopped
        // leaves, and the move took the plain one: the wraps open nothing more.
        final byPlain = old != KeychainNames.databaseKey && await device.read(key: KeychainNames.databaseKey) != null;
        if (byPlain || await device.read(key: moved) == was) await device.delete(key: old);
      }
    }
    // An older version finds its own switches off, and does not sit at a PIN it
    // can no longer check.
    await rawPrefs.setBool('security_lock_enabled', false);
    await rawPrefs.setBool('encrypting_lock_enabled', false);
    _at('originals');
  }
}

/// Everything of the old layout in the keychain [device] and the system's store
/// [rawPrefs]: the database's key under its old names, the secrets under theirs, the
/// settings that are a person's. Nothing of a profile or the lock is touched.
Future<void> deleteOldLayoutEntries(FlutterSecureStorage device, SharedPreferences rawPrefs) async {
  for (final name in await keychainNamesIn(device)) {
    if (name == KeychainNames.databaseKey ||
        name == KeychainNames.wrappedDatabaseKey ||
        name == KeychainNames.hardwareWrappedDatabaseKey ||
        name == 'vault_slots') {
      await device.delete(key: name);
    } else if (!KeychainNames.isDevice(name) && !name.startsWith('p.') && !name.startsWith('vault2_')) {
      await device.delete(key: name);
    }
  }
  for (final key in rawPrefs.getKeys().toList()) {
    if (SettingsService.isProfileKey(key) && !ProfilePreferences.layered.contains(key)) await rawPrefs.remove(key);
  }
}

/// Whether the sealed [stored], under the whole name [full], opens to [value].
Future<bool> _copyOpensTo(SecretSeal seal, String full, String? stored, String value) async {
  if (stored == null || !SecretSeal.isSealed(stored)) return false;
  try {
    return await seal.open(full, stored) == value;
  } on SecretSealBroken {
    return false;
  }
}

/// The teams with an owner in the old map ([orchard_owners_v1]), by team.
Future<Map<String, String>> readTeamOwners(FlutterSecureStorage device) async {
  try {
    final raw = await device.read(key: 'orchard_owners_v1');
    if (raw == null) return const {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const {};
    return {
      for (final e in decoded.entries)
        if (e.key is String && e.value is String) e.key as String: e.value as String,
    };
  } catch (_) {
    return const {};
  }
}

/// Moves the team database [name] (`<id>.db`) and its side files from [from]
/// to [to], side files first; what is already there stays.
Future<void> moveTeamFiles(Directory from, Directory to, String name) async {
  await to.create(recursive: true);
  for (final file in ['$name-shm', '$name-wal', '$name-journal', name]) {
    final source = File(p.join(from.path, file));
    if (!await source.exists()) continue;
    final target = File(p.join(to.path, file));
    if (await target.exists()) continue;
    await _rename(source, target.path);
  }
}

/// Moves what is directly in [folder] into a folder of the profile [id] inside
/// it. What could not be moved (a log open in an editor) stays and is tried
/// again by nothing: it is the person's, and still where it was. Folders inside
/// are other profiles' and are left.
Future<void> moveFolderContents(Directory folder, String id, {bool Function(String name)? only}) async {
  if (!await folder.exists()) return;
  final to = Directory(p.join(folder.path, id));
  for (final entry in await folder.list().toList()) {
    if (entry is! File) continue;
    final name = p.basename(entry.path);
    if (only != null && !only(name)) continue;
    try {
      await to.create(recursive: true);
      final target = File(p.join(to.path, name));
      if (!await target.exists()) await _rename(entry, target.path);
    } catch (e) {
      AppLogger.warning('Moving to profiles: a file stayed where it was (${errorKind(e)})');
    }
  }
}

/// Whether a move, under way or set aside midway, may still need what is under the old
/// names: it seals them when it finishes, and they are all it has of those secrets.
Future<bool> oldNamesStillNeeded(Directory base) async {
  if (await File(p.join(ProfilePaths.root(base).path, 'move_v1.json')).exists()) return true;
  final aside = ProfilePaths.setAside(base);
  if (!await aside.exists()) return false;
  for (final entry in await aside.list().toList()) {
    if (entry is Directory && await File(p.join(entry.path, 'move_v1.json')).exists()) return true;
  }
  return false;
}

/// What is directly in [from] goes to [to], under a name of its own there. How many
/// could not be moved, and stay where they are.
Future<int> moveFilesBetween(Directory from, Directory to) async {
  if (!await from.exists()) return 0;
  var left = 0;
  for (final entry in await from.list().toList()) {
    if (entry is! File) continue;
    try {
      await to.create(recursive: true);
      await _rename(entry, await freeNameIn(to, p.basename(entry.path)));
    } catch (e) {
      left++;
      AppLogger.warning('A file stayed where it was (${errorKind(e)})');
    }
  }
  return left;
}

/// A path in [folder] for a file called [name], with another name where that is taken.
Future<String> freeNameIn(Directory folder, String name) async {
  var path = p.join(folder.path, name);
  for (var n = 2; await File(path).exists(); n++) {
    path = p.join(folder.path, '${p.basenameWithoutExtension(name)} ($n)${p.extension(name)}');
  }
  return path;
}

/// A rename on the same disk, tried a few times: a virus scanner or an indexer
/// holds a file for a moment on Windows.
Future<void> _rename(File file, String to) async {
  for (var attempt = 0;; attempt++) {
    try {
      await file.rename(to);
      return;
    } on FileSystemException {
      if (attempt >= 4) rethrow;
      await Future<void>.delayed(Duration(milliseconds: 100 * (attempt + 1)));
    }
  }
}

/// As [_rename], for a folder.
Future<void> _renameFolder(Directory folder, String to) async {
  for (var attempt = 0;; attempt++) {
    try {
      await folder.rename(to);
      return;
    } on FileSystemException {
      if (attempt >= 4) rethrow;
      await Future<void>.delayed(Duration(milliseconds: 100 * (attempt + 1)));
    }
  }
}

/// The held teams the map [owners] names as [profile]'s account's, taken into
/// its profile.
Future<void> adoptHeldTeamsOf({
  required Directory base,
  required FlutterSecureStorage device,
  required ActiveProfile profile,
  required SecretSeal seal,
  required Map<String, String> owners,
  SecretKey? vaultKey,
  void Function(String boundary)? stop,
}) async {
  final mine = [for (final e in owners.entries) if (e.value == profile.uid) e.key];
  for (final id in mine) {
    await adoptHeldTeam(base: base, device: device, profile: profile, seal: seal, teamId: id, vaultKey: vaultKey);
    stop?.call('adopted:$id');
  }
}

/// The held team [teamId] taken into [profile]: its key sealed under the
/// profile's name and read back first, then its files, and only then the held
/// key goes. Run again it finishes what is left. A team with no held key and
/// no files is nothing to do.
Future<bool> adoptHeldTeam({
  required Directory base,
  required FlutterSecureStorage device,
  required ActiveProfile profile,
  required SecretSeal seal,
  required String teamId,
  SecretKey? vaultKey,
}) async {
  final name = 'orchard_db_key_$teamId';
  final heldFolder = ProfilePaths.heldTeams(base);
  final file = '$teamId.db';
  final held = HeldEntries(device);
  final value = await held.read(name, vaultKey: vaultKey);
  final hasFiles = await File(p.join(heldFolder.path, file)).exists();
  if (value == null && !hasFiles) return false;
  if (value != null) {
    final full = KeychainNames.full(profile.id, profile.uid, name);
    await device.write(key: full, value: await seal.seal(full, value));
    final back = await device.read(key: full);
    if (back == null || await seal.open(full, back) != value) throw const ProfileMoveFailed('team key', 'read back');
  }
  await moveTeamFiles(heldFolder, Directory(p.join(profile.dir.path, 'orchards')), file);
  await held.remove(name);
  return true;
}

/// The secrets held for the account [uid], taken into [profile]: what waited
/// for it since the move.
Future<void> claimHeldEntries({
  required FlutterSecureStorage device,
  required ActiveProfile profile,
  required SecretSeal seal,
  required String uid,
  SecretKey? vaultKey,
}) async {
  final held = HeldEntries(device);
  for (final name in await held.names()) {
    if (KeychainNames.accountOf(name) != uid) continue;
    final value = await held.read(name, vaultKey: vaultKey);
    if (value == null) continue;
    final full = KeychainNames.full(profile.id, uid, name);
    await device.write(key: full, value: await seal.seal(full, value));
    final back = await device.read(key: full);
    if (back == null || await seal.open(full, back) != value) throw const ProfileMoveFailed('held', 'read back');
    await held.remove(name);
  }
}
