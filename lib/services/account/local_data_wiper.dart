import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/backup_service.dart';
import 'package:zestssh/services/migration_backup_service.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/session_log_service.dart';
import 'package:zestssh/services/session_transcript_service.dart';
import 'package:zestssh/services/store_handover.dart';
import 'package:zestssh/services/vault_slot_service.dart';
import 'package:zestssh/utils/error_kind.dart' show errorKind;
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';

/// Files ZestSSH wrote on its own outside the database.
class WipeTargets {
  const WipeTargets({
    this.ownedDirectories = const [],
    this.ownedFiles = const [],
  });

  /// Folders only ZestSSH writes to, deleted with everything inside.
  final List<Directory> ownedDirectories;

  /// Files ZestSSH wrote into a folder it shares with the person (their
  /// Documents, the Downloads folder), matched by name so nothing else in
  /// that folder is touched.
  final List<({Directory directory, bool Function(String name) matches})>
      ownedFiles;

  /// Where they are on this device. Backups the person exported themselves
  /// are theirs and are not listed. [everything]: every profile here goes
  /// (Delete all local data's Everything), and not only the one open.
  /// [handover] stands in for this Windows account's folders of the
  /// Microsoft Store hand-over, in tests.
  static Future<WipeTargets> onThisDevice({bool everything = false, StoreHandover? handover}) async {
    // With no profile open there is no "this profile's", and the folders below
    // would be everyone's.
    if (Profiles.on && Profiles.current == null) return const WipeTargets();
    final directories = <Directory>[];
    final files =
        <({Directory directory, bool Function(String name) matches})>[];
    try {
      final docs = await getApplicationDocumentsDirectory();
      // On a computer each is the profile's own folder inside these, and only
      // that goes: nothing of another profile is touched.
      directories
        ..add(ProfilePaths.forCurrent(Directory(p.join(docs.path, SessionLogService.defaultSubdir))))
        ..add(ProfilePaths.forCurrent(Directory(
            p.join(docs.path, SessionTranscriptService.defaultSubdir))));
      // The local backup destination's copies are automatic backups, a folder
      // of the profile's own (its Documents folder holds what the person
      // exported as well, which is theirs and stays). On a phone they are where
      // they always were.
      if (Profiles.on) {
        directories.add(ProfilePaths.forCurrent(Directory(p.join(docs.path, 'ZestSSH', 'backups'))));
      }
      // The cached profile photo lives in `profile/`, a folder name too
      // generic to delete whole in someone's Documents.
      files.add((
        directory: ProfilePaths.forCurrent(Directory(p.join(docs.path, 'profile'))),
        matches: (n) => n.startsWith('avatar_') && n.endsWith('.png'),
      ));
    } catch (e) {
      AppLogger.warning('Wipe: no documents folder: $e');
    }
    try {
      files.add((
        directory: await BackupService.resolveBackupDir(isAutoBackup: true),
        // (And one whose writing never finished: it is a backup all the same.)
        matches: (n) =>
            n.startsWith('zestssh_auto_') &&
            (n.endsWith('.zest') || n.endsWith('.zest${BackupService.unfinishedSuffix}')),
      ));
    } catch (e) {
      AppLogger.warning('Wipe: no auto-backup folder: $e');
    }
    // On Windows, what the move to the Microsoft Store's copy left: a hand-over
    // still waiting, and the data set aside of what the person did not keep
    // (store_handover.dart). Each is a full copy of hosts, keys and passwords,
    // which goes with the data it copied (found in a security
    // review). Each copies every profile on the PC:
    // a wipe of the one open takes that profile's part, and a copy whole only
    // where no one else's is in it (found in a code review).
    final h = handover ?? (Platform.isWindows ? StoreHandover.here() : null);
    if (h != null) {
      try {
        final one = Profiles.on && !everything ? Profiles.current : null;
        directories.addAll(one == null ? h.leftovers() : h.leftoversOfProfile(one.id));
      } catch (e) {
        AppLogger.warning('Wipe: what the hand-over left was not looked at (${errorKind(e)})');
      }
    }
    // The app's own log files are the device's: they go with everything on it.
    if (!Profiles.on) {
      try {
        files.add((
          directory: await getApplicationSupportDirectory(),
          matches: (n) => n.startsWith('zestssh_logs_') && n.endsWith('.txt'),
        ));
      } catch (e) {
        AppLogger.warning('Wipe: no app support folder: $e');
      }
    }
    return WipeTargets(ownedDirectories: directories, ownedFiles: files);
  }
}

/// Deletes everything ZestSSH keeps on this device, for "Delete all local
/// data" and the last step of deleting an account.
///
/// "Everything" means: every database row (then VACUUM, so freed pages stop
/// holding the old data), every full copy of the database made before a
/// migration, every secret in the OS secure storage (identity keys and
/// passwords, certificates, sync keys, sign-in sessions, app lock), the
/// files ZestSSH wrote on its own ([WipeTargets]) and the preferences. The
/// one secret kept is the key of the database that is still open; the
/// database it unlocks is empty by then.
///
/// On a phone or tablet with Encrypt data at rest on, that key is in the
/// storage only wrapped behind the PIN, beside the slots that unwrap it. The
/// wipe turns the lock off first, as its description says the app lock goes:
/// the key is written back as it is with the lock off ([lockedKeyHex], the key
/// the open database was opened by), and only then do the wrapped key and its
/// slots go, so a wipe stopped halfway never leaves a database nothing opens.
/// (It spared the plain key by name alone, which is not there while the lock
/// is on, and deleted the only copies of the key of a database that stayed
/// open and in use: the next start found a file and no key, offered Reset,
/// and what had been added since the wipe could never be read again. Found
/// in a code audit; the lock going was chosen over the lock
/// staying.) Where the lock is on and no key was given, the
/// wrapped key and its slots are left as they are instead: the lock stays,
/// and the database still opens with the PIN.
///
/// On a computer it is one profile's: its database, its entries (the keychain
/// shows it no other's), its files and its settings, wiped while it is still
/// open; the caller then removes it. Nothing of another profile, the app lock or
/// the list of profiles is touched.
///
/// Callers turn sync off first, so the wipe is never uploaded anywhere.
class LocalDataWiper {
  LocalDataWiper({
    required this.database,
    required this.secureStorage,
    required this.preferences,
    required this.targets,
    this.lockedKeyHex,
    Future<void> Function()? deleteDatabaseCopies,
    Future<List<File>> Function()? listMigrationBackups,
  })  : _deleteDatabaseCopies =
            deleteDatabaseCopies ?? AppDatabase.deleteBackupCopies,
        _listMigrationBackups =
            listMigrationBackups ?? MigrationBackupService.listBackups;

  final AppDatabase database;
  final FlutterSecureStorage secureStorage;
  final SharedPreferences preferences;
  final WipeTargets targets;

  /// The key [database] was opened by, where Encrypt data at rest is on (a
  /// phone or tablet; DatabaseSessionNotifier.lockedKeyHex). Null with the
  /// lock off, and on a computer.
  final String? lockedKeyHex;
  final Future<void> Function() _deleteDatabaseCopies;
  final Future<List<File>> Function() _listMigrationBackups;

  /// Whether [wipe] turned Encrypt data at rest off: the caller then drops
  /// what it holds of the lock outside the storage (the hardware key, the key
  /// in memory).
  bool get turnedLockOff => _turnedLockOff;
  bool _turnedLockOff = false;

  /// The storage entries that hold the database's key while the lock is on.
  static const _lockEntries = {
    VaultSlotService.wrappedDbKeyId,
    VaultSlotService.hwWrappedDbKeyId,
    VaultSlotService.slotsId,
  };

  Future<void> wipe() async {
    // The lock first, while everything is still there. On a computer the lock
    // is the profiles' and stays as it is.
    var lockStays = false;
    if (!Profiles.on) {
      final vault = VaultSlotService(secureStorage);
      if (await vault.isEnabled()) {
        final keyHex = lockedKeyHex;
        if (keyHex != null) {
          // The plain key first, then the wrapped one and its slots.
          await vault.disableLock(keyHex);
          // What is written from now on is kept as it is: the database's key
          // is in the same storage again (SecretSeal).
          await SecretSeal.setActive(database, false);
          _turnedLockOff = true;
        } else {
          lockStays = true;
          AppLogger.warning('Wipe: the lock is on and its key was not given, so the lock stays');
        }
      }
    }

    await database.wipeAllData();
    try {
      await database.customStatement('VACUUM');
    } catch (e) {
      AppLogger.warning('Wipe: VACUUM failed: $e');
    }

    await _deleteDatabaseCopies();
    for (final copy in await _listMigrationBackups()) {
      await _deleteQuietly(copy);
      await _deleteQuietly(File('${copy.path}-wal'));
    }

    // A copy of the key list: some implementations hand back their live map,
    // which deleting would change mid-loop.
    final secrets = await keychainStoreNames(secureStorage);
    await keychainBatch(() async {
      for (final key in secrets) {
        if (key == AppDatabase.encryptionKeyStorageKey) continue;
        if (lockStays && _lockEntries.contains(key)) continue;
        await secureStorage.delete(key: key);
      }
    });

    for (final directory in targets.ownedDirectories) {
      try {
        if (await directory.exists()) await directory.delete(recursive: true);
      } catch (e) {
        AppLogger.warning('Wipe: could not delete a folder: $e');
      }
    }
    for (final set in targets.ownedFiles) {
      try {
        if (!await set.directory.exists()) continue;
        // List first, then delete: not every platform lists a folder
        // reliably while its entries are being removed.
        final entries = await set.directory.list().toList();
        for (final entry in entries) {
          if (entry is File && set.matches(p.basename(entry.path))) {
            await _deleteQuietly(entry);
          }
        }
      } catch (e) {
        AppLogger.warning('Wipe: could not clear a folder: $e');
      }
    }

    await preferences.clear();
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      AppLogger.warning('Wipe: could not delete a file: $e');
    }
  }
}
