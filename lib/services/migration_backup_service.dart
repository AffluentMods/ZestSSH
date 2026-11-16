import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:zestssh/database/database.dart' show MigrationIntegrityException;
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/profile_boot.dart' show dataStaysAsItIs;
import 'package:zestssh/utils/logger.dart';

/// Manages pre-migration database backups.
///
/// Before any schema migration, the raw database file is copied into a
/// dedicated `migration_backups/` directory. If the migration fails, the
/// backup can be restored so the user keeps their data on the previous
/// schema version.
///
/// A copy is made only where opening the database will upgrade it
/// ([backupBeforeUpgrade]): where it last opened at another schema version
/// than this app's, or it is not known at which ([openedSchema]). Every start
/// made one (`pre_v0_to_v0_<time>.db`, a whole copy of the database), and only
/// the start with the lock off ever cleared any, keeping every one from the
/// last 30 days (3.3).
///
/// Retention: the [_maxBackups] newest, cut each time a database opens
/// ([noteOpened]).
class MigrationBackupService {
  /// How many copies are kept: each is a whole copy of the database.
  static const int _maxBackups = 3;

  /// The file in a database's `migration_backups` that says at which schema
  /// version it last opened, its migrations passed.
  static const openedFileName = 'opened_schema';

  /// The copies made in this run, by the database they are of: what a restore
  /// after a failed upgrade may put back. One from an earlier run would put back
  /// a database as it was then, and lose all that was done since.
  static final _madeThisRun = <String, String>{};

  /// Whether a restore must not run now (ProfileManager): a move to profiles is
  /// under way, and what it sealed depends on a key the copy has no row for, or the
  /// database passed its migrations, and whatever failed after that is no fault of
  /// the upgrade. A copy put back then would lose every secret sealed since.
  static Future<bool> Function()? restoreHeld;

  /// Create a backup of the database file before migration.
  ///
  /// The backup is stored at:
  ///   `{app_data}/migration_backups/pre_v{from}_to_v{to}_{timestamp}.db`
  ///
  /// with the write-ahead file beside it where there is one: the window closes
  /// without merging it, so the newest changes are often in that file alone.
  ///
  /// Returns the absolute path to the backup file.
  ///
  /// [folder]: the database in that folder, and not the one open now (a profile
  /// about to open at a sign-in).
  static Future<String> createPreMigrationBackup({
    required int fromVersion,
    required int toVersion,
    Directory? folder,
  }) async {
    final dbPath = folder == null ? await databasePath : p.join(folder.path, 'zestssh.db');
    final source = File(dbPath);

    if (!await source.exists()) {
      throw StateError(
        'Cannot create pre-migration backup: database file does not exist '
        'at $dbPath',
      );
    }

    final backupDir = folder == null ? await _backupDirectory() : Directory(p.join(folder.path, 'migration_backups'));
    if (!await backupDir.exists()) {
      await backupDir.create(recursive: true);
    }

    // A database that keeps failing to open was copied at every start: the
    // copies kept could all be copies of the broken file, the good one cut
    // (found in a code audit). Where the newest copy holds exactly what is
    // there now (and no write-ahead file is beside either), it is used again.
    final same = await _sameAsNewestCopy(source, backupDir);
    if (same != null) {
      _madeThisRun[p.canonicalize(dbPath)] = same;
      AppLogger.info('Pre-migration backup ready: the newest copy holds the same database');
      return same;
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final backupName = 'pre_v${fromVersion}_to_v${toVersion}_$timestamp.db';
    final backupFile = File(p.join(backupDir.path, backupName));

    await source.copy(backupFile.path);
    final journal = File('$dbPath-wal');
    if (await journal.exists()) await journal.copy('${backupFile.path}-wal');
    _madeThisRun[p.canonicalize(dbPath)] = backupFile.path;

    final sizeKb = (await backupFile.length()) ~/ 1024;
    AppLogger.info(
      'Pre-migration backup created: $backupName (${sizeKb}KB)',
    );

    return backupFile.path;
  }

  /// The newest copy in [backupDir] when it holds byte for byte what
  /// [source] holds, and neither has a write-ahead file beside it; else null.
  static Future<String?> _sameAsNewestCopy(File source, Directory backupDir) async {
    try {
      if (await File('${source.path}-wal').exists()) return null;
      final copies = [
        for (final e in backupDir.listSync())
          if (e is File && e.path.endsWith('.db') && p.basename(e.path).startsWith('pre_v')) e,
      ]..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      if (copies.isEmpty) return null;
      final newest = copies.first;
      if (await File('${newest.path}-wal').exists()) return null;
      if (await newest.length() != await source.length()) return null;
      final a = await sha256.bind(source.openRead()).first;
      final b = await sha256.bind(newest.openRead()).first;
      return a == b ? newest.path : null;
    } catch (_) {
      return null;
    }
  }

  /// Restore database from a pre-migration backup.
  ///
  /// Copies the backup file over the current database file, with the write-ahead
  /// file it was taken with, and removes any other WAL/SHM journal files so the
  /// restored database opens cleanly. Refused while [restoreHeld] says so.
  ///
  /// Security: validates that [backupPath] resolves to a file within the
  /// expected backup directory to prevent path traversal attacks.
  ///
  /// [folder]: the database in that folder, whose opening has just failed (the caller
  /// has seen to what [restoreHeld] looks after).
  static Future<void> restoreFromBackup(String backupPath, {Directory? folder}) async {
    if (folder == null && (await restoreHeld?.call() ?? false)) {
      throw StateError('Cannot restore: the data here depends on what the copy does not hold');
    }

    // Path traversal guard: ensure the resolved backup path is inside
    // the backup directory. This prevents restoring from arbitrary
    // filesystem locations via crafted paths like "../../etc/passwd".
    final backupDir = folder == null ? await _backupDirectory() : Directory(p.join(folder.path, 'migration_backups'));
    final canonicalBackupDir = p.canonicalize(backupDir.path);
    final canonicalBackupPath = p.canonicalize(backupPath);
    if (!canonicalBackupPath.startsWith(canonicalBackupDir)) {
      throw StateError(
        'Cannot restore: backup path is outside the backup directory. '
        'Expected a file within $canonicalBackupDir',
      );
    }

    final backup = File(backupPath);
    if (!await backup.exists()) {
      throw StateError(
        'Cannot restore: backup file does not exist at $backupPath',
      );
    }

    final dbPath = folder == null ? await databasePath : p.join(folder.path, 'zestssh.db');

    // The copy is put beside the database whole first, then in its place in
    // one step: copied straight over it, a stop in the middle left neither
    // the database nor the copy where it opens (found in a code audit).
    final staged = File('$dbPath.restoring');
    final stagedWal = File('$dbPath.restoring-wal');
    final copyWal = File('$backupPath-wal');
    await backup.copy(staged.path);
    if (await copyWal.exists()) await copyWal.copy(stagedWal.path);

    // Remove WAL and SHM files - they belong to the failed migration's
    // database state and must not be replayed on the restored copy.
    for (final suffix in ['-wal', '-shm', '-journal']) {
      final journal = File('$dbPath$suffix');
      if (await journal.exists()) {
        await journal.delete();
      }
    }

    await staged.rename(dbPath);
    if (await stagedWal.exists()) await stagedWal.rename('$dbPath-wal');
    // What is there now opened at an older version: the next open is an
    // upgrade again, with a copy before it.
    await _forgetOpened(folder: folder);

    final sizeKb = (await backup.length()) ~/ 1024;
    AppLogger.info(
      'Database restored from backup: $backupPath (${sizeKb}KB)',
    );
  }

  /// Whether [error], which stopped a database opening, looks like an update of it
  /// that failed, for which the copy from before is what there is to go back to.
  ///
  /// Never for data from a newer ZestSSH, nor for a failure of the moment ("database
  /// is locked" while another process holds the file, a full disk): any SQLite error
  /// read as a failed update, and the copy was put back over a file another process
  /// may have had open (found in a code audit).
  static bool looksLikeMigrationFailure(Object error) {
    if (error is MigrationIntegrityException) return true;
    if (dataStaysAsItIs(error)) return false;
    final s = error.toString().toLowerCase();
    return s.contains('migration') || s.contains('table') || s.contains('column') || s.contains('sql');
  }

  /// Cut the copies in the `migration_backups` of the database in [folder] (the
  /// open profile's where null) to the [_maxBackups] newest, with the
  /// write-ahead file of each that goes. Never throws.
  static Future<void> cleanupOldBackups({Directory? folder}) async {
    try {
      final backupDir = folder == null ? await _backupDirectory() : Directory(p.join(folder.path, 'migration_backups'));
      if (!await backupDir.exists()) return;
      final entries = await backupDir.list().where((e) => e is File && e.path.endsWith('.db')).cast<File>().toList();
      if (entries.length <= _maxBackups) return;
      entries.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      final toDelete = entries.skip(_maxBackups).toList();
      for (final file in toDelete) {
        try {
          await file.delete();
          final journal = File('${file.path}-wal');
          if (await journal.exists()) await journal.delete();
          AppLogger.info('Deleted old migration backup: ${p.basename(file.path)}');
        } catch (e) {
          AppLogger.warning('Failed to delete old backup ${p.basename(file.path)}: $e');
        }
      }
      AppLogger.info('Migration backup cleanup: deleted ${toDelete.length}, kept $_maxBackups');
    } catch (e) {
      AppLogger.warning('Migration backup cleanup failed: $e');
    }
  }

  /// The schema version the database in [folder] (the open profile's where
  /// null) last opened at, as [noteOpened] wrote it; null where none is
  /// written (a database from before 3.3, one moved into a profile, one put
  /// back from a copy), which counts as an upgrade ahead.
  static Future<int?> openedSchema({Directory? folder}) async {
    try {
      final file = await _openedFile(folder);
      if (!await file.exists()) return null;
      return int.tryParse((await file.readAsString()).trim());
    } catch (_) {
      return null;
    }
  }

  /// A database that has just opened at [schemaVersion], its migrations passed
  /// (AppDatabase's beforeOpen): that version is written down, and the copies
  /// kept are cut to the newest few. Every way a database opens goes through
  /// it: a start with the lock off, an unlock, a profile opened at a sign-in.
  /// Never throws: an open is never stopped by it.
  static Future<void> noteOpened(int schemaVersion, {Directory? folder}) async {
    try {
      // Its upgrade passed: the copy from before it is no longer one to put back
      // in this run (it would lose all done since).
      final dbPath = folder == null ? await databasePath : p.join(folder.path, 'zestssh.db');
      _madeThisRun.remove(p.canonicalize(dbPath));
    } catch (_) {/* no folder open: nothing was made for it */}
    try {
      final file = await _openedFile(folder);
      await file.parent.create(recursive: true);
      await file.writeAsString('$schemaVersion');
    } catch (e) {
      AppLogger.warning('The schema version opened was not written: $e');
    }
    await cleanupOldBackups(folder: folder);
  }

  /// A copy of the database in [folder] (the open profile's where null) made
  /// before it opens, where opening it will upgrade it to [schemaVersion]: it
  /// last opened at another version, or at one not known ([openedSchema]).
  /// Named with the two (`pre_v53_to_v54_<time>.db`; `v0` where the one before
  /// is not known). Null where there is no database yet, or nothing will
  /// upgrade it.
  static Future<String?> backupBeforeUpgrade({required int schemaVersion, Directory? folder}) async {
    final dbPath = folder == null ? await databasePath : p.join(folder.path, 'zestssh.db');
    if (!await File(dbPath).exists()) return null;
    final opened = await openedSchema(folder: folder);
    if (opened == schemaVersion) return null;
    return createPreMigrationBackup(fromVersion: opened ?? 0, toVersion: schemaVersion, folder: folder);
  }

  /// The copy made in this run of the database in [folder] (the open
  /// profile's where null), if one was: the one copy a restore after a failed
  /// upgrade may put back.
  static Future<String?> madeThisRun({Directory? folder}) async {
    final dbPath = folder == null ? await databasePath : p.join(folder.path, 'zestssh.db');
    return _madeThisRun[p.canonicalize(dbPath)];
  }

  /// Forgets the copies made in this run, for tests.
  @visibleForTesting
  static void debugForgetThisRun() => _madeThisRun.clear();

  static Future<File> _openedFile(Directory? folder) async {
    final backupDir = folder == null ? await _backupDirectory() : Directory(p.join(folder.path, 'migration_backups'));
    return File(p.join(backupDir.path, openedFileName));
  }

  static Future<void> _forgetOpened({Directory? folder}) async {
    try {
      final file = await _openedFile(folder);
      if (await file.exists()) await file.delete();
    } catch (_) {/* not known is an upgrade ahead: the safe side */}
  }

  /// List all available migration backup files, newest first.
  static Future<List<File>> listBackups() async {
    final backupDir = await _backupDirectory();
    if (!await backupDir.exists()) return [];

    final entries = await backupDir
        .list()
        .where((e) => e is File && e.path.endsWith('.db'))
        .cast<File>()
        .toList();

    entries.sort((a, b) {
      final aStat = a.statSync();
      final bStat = b.statSync();
      return bStat.modified.compareTo(aStat.modified);
    });

    return entries;
  }

  /// Get the database file path (mirrors [AppDatabase._databaseDirectory]).
  static Future<String> get databasePath async {
    final dir = await _databaseDirectory();
    return p.join(dir.path, 'zestssh.db');
  }

  /// Returns the directory for the database file: the same one the database
  /// uses, so backups target the correct file.
  static Future<Directory> _databaseDirectory() => ProfilePaths.databaseDirectory();

  /// Returns the directory where migration backups are stored.
  static Future<Directory> _backupDirectory() async {
    final dbDir = await _databaseDirectory();
    return Directory(p.join(dbDir.path, 'migration_backups'));
  }
}
