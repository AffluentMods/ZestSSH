import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/backup_service.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/type_name.dart';

/// The automatic backups' password is sealed and did not open here: the app
/// is locked, or another database sealed it.
class AutoBackupPasswordLocked implements Exception, HasTypeName {
  const AutoBackupPasswordLocked();

  @override
  String toString() => 'The automatic backups\' password is sealed and did not open';

  @override
  String get typeName => 'AutoBackupPasswordLocked';
}

/// What a run of the automatic backup did. (3.0: everything it
/// did went to the log only, so a backup that was skipped or failed for
/// days said nothing.)
enum AutoBackupStatus {
  /// Automatic backups are off, or none was due.
  idle,

  /// They are on, but have no password to encrypt one with: none was made.
  noPassword,

  /// One was made ([AutoBackupOutcome.notCopied]: the places it could not be
  /// copied to).
  made,

  /// None was made ([AutoBackupOutcome.error] says why, in the app's
  /// language; [AutoBackupOutcome.detail] is for the report).
  failed,
}

class AutoBackupOutcome {
  const AutoBackupOutcome(this.status, {this.error, this.detail, this.notCopied = const {}});

  final AutoBackupStatus status;
  final String? error;
  final String? detail;

  /// The other backup places a made backup could not be copied to: each by
  /// its name, with what it said.
  final Map<String, String> notCopied;
}

/// Copies a made backup [file] to the other places backups go (the
/// destinations set up in Settings); answers with those it could not be
/// copied to, by name, with what each said.
typedef CopyBackup = Future<Map<String, String>> Function(File file, String filename);

/// The two kinds of automatic backup, each kept apart with its own number
/// (3.4.2: one pool of three held both, and a backup was made each time the
/// app went to the background after any change, a connect included, so the
/// daily or weekly one was gone within hours).
enum AutoBackupKind {
  /// The daily or weekly one, as the setting says.
  scheduled('zestssh_auto_', 7),

  /// One made when the app goes to the background after a change, at most
  /// once an hour ([AutoBackupService.changeEvery]).
  onChange('zestssh_auto_change_', 6);

  const AutoBackupKind(this.prefix, this.keep);

  /// How its files' names begin.
  final String prefix;

  /// How many of it are kept: seven daily ones are a week, seven weekly ones
  /// seven weeks; six made on a change are at least five hours apart from
  /// first to last.
  final int keep;

  /// The kind of automatic backup the file [name] is, or null where it is
  /// none. One named before 3.4.2 (`zestssh_auto_` and its time) is taken
  /// for a scheduled one.
  static AutoBackupKind? of(String name) {
    if (!name.endsWith('.zest')) return null;
    if (name.startsWith(onChange.prefix)) return onChange;
    if (name.startsWith(scheduled.prefix)) return scheduled;
    return null;
  }
}

/// Handles automatic backups: the daily or weekly one, and one made when the
/// app goes to the background after a change ([AutoBackupKind]).
///
/// Each is an encrypted backup made with the password kept for them in
/// secure storage.
class AutoBackupService {
  /// Where the automatic backups' password is kept (secure storage), sealed
  /// while the encrypting lock is on (SecretSeal; 22 October 2026: it was
  /// kept as it was, beside backups that hold every key's secret).
  static const passwordKey = 'auto_backup_password';

  /// The least time between two backups made on a change: each runs a
  /// 128 MB key derivation as the app goes to the background, and a phone may
  /// be suspended in the middle of it.
  static const changeEvery = Duration(hours: 1);

  /// Where automatic backups are written; a test's own folder stands in.
  @visibleForTesting
  static Future<Directory> Function() folder = () => BackupService.resolveBackupDir(isAutoBackup: true);

  /// The clock; a test's own stands in.
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  /// Whether a backup is being made now: another is not begun meanwhile (the
  /// app going to the background is said twice on a phone, inactive and then
  /// paused).
  static bool _making = false;

  /// Whether the daily or weekly backup is due ([checkAndRunAutoBackup]).
  static bool scheduledDue(SettingsService settings) {
    final interval = settings.autoBackupInterval;
    if (interval == 'off') return false;
    final last = settings.lastAutoBackupTime;
    return last == null || _isBackupDue(last, clock(), interval);
  }

  /// Whether a backup on a change may be begun now: automatic backups are on,
  /// and none was begun in the last [changeEvery] ([backupIfDirty]).
  static bool changeBackupAllowed(SettingsService settings) {
    if (settings.autoBackupInterval == 'off') return false;
    final last = settings.lastChangeBackupTime;
    if (last == null) return true;
    final since = clock().difference(last);
    // (A clock set back makes the last one look to be in the future: one is
    // allowed, not none for as long as the clock is behind.)
    return since >= changeEvery || since.isNegative;
  }

  /// The automatic backups' password as kept in [storage], opened with
  /// [tree]'s seal where it is sealed; null where none is kept. Throws
  /// [AutoBackupPasswordLocked] where it is sealed and does not open (the
  /// app is locked, or it was sealed by another database).
  static Future<String?> readPassword(FlutterSecureStorage storage, AppDatabase? tree) =>
      _readPassword(storage, () => tree);

  /// [readPassword], the database asked for only where the password is
  /// sealed.
  static Future<String?> _readPassword(FlutterSecureStorage storage, AppDatabase? Function() tree) async {
    final stored = await storage.read(key: passwordKey);
    if (stored == null || !SecretSeal.isSealed(stored)) return stored;
    try {
      return await openKeptOrThrow(tree(), passwordKey, stored);
    } catch (_) {
      // Not opened: a closed database throws as a broken seal does.
      throw const AutoBackupPasswordLocked();
    }
  }

  /// Keeps [password] as the automatic backups' password: sealed with
  /// [tree]'s seal while the encrypting lock is on.
  static Future<void> keepPassword(FlutterSecureStorage storage, AppDatabase? tree, String password) async =>
      storage.write(key: passwordKey, value: await keepSealed(tree, passwordKey, password));

  /// The password, or the outcome that says why there is none to use.
  static Future<({String? password, AutoBackupOutcome? stop})> _password(
      FlutterSecureStorage storage, BackupService backupService) async {
    try {
      final password = await _readPassword(storage, () => backupService.sealedBy);
      if (password == null || password.isEmpty) {
        return (password: null, stop: const AutoBackupOutcome(AutoBackupStatus.noPassword));
      }
      return (password: password, stop: null);
    } on AutoBackupPasswordLocked catch (e) {
      AppLogger.warning('Auto-backup skipped - its password is sealed and did not open.');
      return (
        password: null,
        stop: AutoBackupOutcome(AutoBackupStatus.failed, error: gl10n.backupSealedPasswordLocked, detail: '$e'),
      );
    }
  }

  /// The daily or weekly backup, where it is due ([scheduledDue]).
  ///
  /// This is safe to call on every app launch, and each time the app goes to
  /// the background - it returns quickly if no backup is needed.
  static Future<AutoBackupOutcome> checkAndRunAutoBackup({
    required BackupService backupService,
    required SettingsService settings,
    required FlutterSecureStorage secureStorage,
    CopyBackup? copyTo,
  }) async {
    if (_making) return const AutoBackupOutcome(AutoBackupStatus.idle);
    _making = true;
    try {
      final interval = settings.autoBackupInterval;
      if (!scheduledDue(settings)) {
        AppLogger.debug('Auto-backup not yet due');
        return const AutoBackupOutcome(AutoBackupStatus.idle);
      }
      final now = clock();

      // Use the user-provided auto-backup password
      final (:password, :stop) = await _password(secureStorage, backupService);
      if (password == null) {
        AppLogger.warning('Auto-backup skipped - no password to use.');
        return stop!;
      }

      // Run backup
      AppLogger.info('Running scheduled auto-backup (interval: $interval)');
      final result = await backupService.exportBackup(password, filenamePrefix: AutoBackupKind.scheduled.prefix);

      if (result.success) {
        await settings.setLastAutoBackupTime(now);
        AppLogger.info(
          'Auto-backup complete: ${result.filePath} '
          '(${result.recordCount} records)',
        );
        final notCopied = await _copy(result, copyTo);

        // The oldest scheduled ones beyond those kept go, and only now that a
        // newer one is made.
        await _prune(AutoBackupKind.scheduled);
        return AutoBackupOutcome(AutoBackupStatus.made, notCopied: notCopied);
      }
      AppLogger.error('Auto-backup failed: ${result.error}');
      return AutoBackupOutcome(AutoBackupStatus.failed, error: result.error, detail: result.detail);
    } catch (e, stack) {
      AppLogger.error('Auto-backup error', e, stack);
      return AutoBackupOutcome(AutoBackupStatus.failed, error: gl10n.backupSvcCouldNotWrite, detail: '$e');
    } finally {
      _making = false;
    }
  }

  /// Copies a made backup to the other backup places, if any; the places it
  /// could not be copied to. (3.0: nothing copied it, though
  /// Settings said backups went to "this device and N more".)
  static Future<Map<String, String>> _copy(BackupResult result, CopyBackup? copyTo) async {
    final path = result.filePath;
    if (copyTo == null || path == null) return const {};
    final file = File(path);
    return copyTo(file, file.uri.pathSegments.last);
  }

  /// Whether a backup is due based on interval and last backup time.
  static bool _isBackupDue(
    DateTime lastBackup,
    DateTime now,
    String interval,
  ) {
    final elapsed = now.difference(lastBackup);
    switch (interval) {
      case 'daily':
        return elapsed.inHours >= 24;
      case 'weekly':
        return elapsed.inDays >= 7;
      default:
        return false;
    }
  }

  /// A backup of a change: called when the app goes to the background and
  /// what a backup holds changed since the last one. Made only where
  /// automatic backups are on and none was begun in the last [changeEvery]
  /// ([changeBackupAllowed]; idle otherwise, and the change waits for the
  /// next time). It is kept apart from the daily or weekly ones
  /// ([AutoBackupKind.onChange]) and never moves their schedule.
  static Future<AutoBackupOutcome> backupIfDirty({
    required BackupService backupService,
    required SettingsService settings,
    required FlutterSecureStorage secureStorage,
    CopyBackup? copyTo,
  }) async {
    if (_making || !changeBackupAllowed(settings)) return const AutoBackupOutcome(AutoBackupStatus.idle);
    _making = true;
    try {
      final (:password, :stop) = await _password(secureStorage, backupService);
      if (password == null) return stop!;

      // Begun counts, made or not: the key derivation is not run again
      // before the hour is out.
      await settings.setLastChangeBackupTime(clock());
      AppLogger.info('Running on-change auto-backup');
      final result = await backupService.exportBackup(
        password,
        filenamePrefix: AutoBackupKind.onChange.prefix,
      );

      if (result.success) {
        AppLogger.info(
          'On-change backup complete: ${result.filePath} '
          '(${result.recordCount} records)',
        );
        final notCopied = await _copy(result, copyTo);
        await _prune(AutoBackupKind.onChange);
        return AutoBackupOutcome(AutoBackupStatus.made, notCopied: notCopied);
      }
      AppLogger.error('On-change backup failed: ${result.error}');
      return AutoBackupOutcome(AutoBackupStatus.failed, error: result.error, detail: result.detail);
    } catch (e, stack) {
      AppLogger.error('On-change backup error', e, stack);
      return AutoBackupOutcome(AutoBackupStatus.failed, error: gl10n.backupSvcCouldNotWrite, detail: '$e');
    } finally {
      _making = false;
    }
  }

  /// When the daily or weekly backup was last tried as the app went to the
  /// background ([onLeaving]): one that fails is tried again there at most
  /// once in [changeEvery], not at every switch of windows.
  static DateTime? _scheduledTriedOnLeaving;

  /// What is done as the app goes to the background (3.4.2): the daily or
  /// weekly backup where it is due (it was looked at only as the app started,
  /// so a computer left running for a week made none), or else a backup of a
  /// change where [changed] and one may be begun now ([changeBackupAllowed]).
  /// [taken] is called as a backup that holds the changes so far is begun:
  /// the app forgets them then, and keeps them for the next time otherwise.
  static Future<AutoBackupOutcome> onLeaving({
    required bool changed,
    required void Function() taken,
    required BackupService backupService,
    required SettingsService settings,
    required FlutterSecureStorage secureStorage,
    CopyBackup? copyTo,
  }) async {
    if (_making) return const AutoBackupOutcome(AutoBackupStatus.idle);
    final now = clock();
    final tried = _scheduledTriedOnLeaving;
    if (scheduledDue(settings) && (tried == null || now.difference(tried).abs() >= changeEvery)) {
      _scheduledTriedOnLeaving = now;
      taken();
      return checkAndRunAutoBackup(
          backupService: backupService, settings: settings, secureStorage: secureStorage, copyTo: copyTo);
    }
    if (!changed || !changeBackupAllowed(settings)) return const AutoBackupOutcome(AutoBackupStatus.idle);
    taken();
    return backupIfDirty(backupService: backupService, settings: settings, secureStorage: secureStorage, copyTo: copyTo);
  }

  /// Forgets what [onLeaving] remembers of this run; for tests.
  @visibleForTesting
  static void resetForTest() {
    _scheduledTriedOnLeaving = null;
    _making = false;
    clock = DateTime.now;
    folder = () => BackupService.resolveBackupDir(isAutoBackup: true);
  }

  static Future<void> _prune(AutoBackupKind kind) async {
    try {
      // The folder exportBackup writes them to (a past desktop mismatch meant
      // this clean-up never ran and encrypted backups piled up).
      await prune(await folder(), kind);
    } catch (e) {
      AppLogger.error('Failed to clean up old backups', e);
    }
  }

  /// Deletes the oldest automatic backups of [kind] in [dir] beyond the
  /// number of them kept ([AutoBackupKind.keep]); answers with the names of
  /// those deleted. The other kind is never touched. Nothing is deleted
  /// unless a whole backup ([looksWhole]) is among those kept, so the only
  /// good backup is never the one that goes.
  @visibleForTesting
  static Future<List<String>> prune(Directory dir, AutoBackupKind kind) async {
    if (!dir.existsSync()) return const [];
    final files = [
      for (final f in dir.listSync().whereType<File>())
        if (AutoBackupKind.of(f.uri.pathSegments.last) == kind) f,
    ];
    if (files.length <= kind.keep) return const [];
    // Newest first: the names carry the time they were made, which a copy of
    // the folder (a profile moved, a disk restored) keeps where a file's own
    // time may not.
    files.sort((a, b) => b.uri.pathSegments.last.compareTo(a.uri.pathSegments.last));
    final kept = files.take(kind.keep);
    if (!(await Future.wait(kept.map(looksWhole))).contains(true)) {
      AppLogger.warning('Auto-backup clean-up skipped: none of the newest ${kind.keep} looks whole');
      return const [];
    }
    // A backup much smaller than one before it (the data emptied, or most of
    // it gone) is no reason to lose the one before: where every backup kept
    // is less than half the size of the largest older whole one, the newest
    // older one at least half that size stays as well. Rotating by count
    // alone, a week of backups made after the data was emptied pushed out
    // every one that held it (found in a code audit).
    final older = files.skip(kind.keep).toList();
    final spare = await _spareFrom(kept.toList(), older);
    final deleted = <String>[];
    for (final old in older) {
      if (old.path == spare?.path) {
        AppLogger.info('Keeping an older auto-backup, much larger than those after it: ${old.path}');
        continue;
      }
      AppLogger.info('Deleting old auto-backup: ${old.path}');
      await old.delete();
      deleted.add(old.uri.pathSegments.last);
    }
    return deleted;
  }

  /// The older backup that stays beside those [kept] (see [prune]), or null.
  static Future<File?> _spareFrom(List<File> kept, List<File> older) async {
    Future<int> wholeSize(File f) async => await looksWhole(f) ? f.lengthSync() : 0;
    var largestKept = 0;
    for (final f in kept) {
      final n = await wholeSize(f);
      if (n > largestKept) largestKept = n;
    }
    final sizes = [for (final f in older) await wholeSize(f)];
    final largestOld = sizes.fold<int>(0, (a, b) => a > b ? a : b);
    if (largestOld == 0 || largestKept * 2 >= largestOld) return null;
    // Newest first, as [older] is.
    for (var i = 0; i < older.length; i++) {
      if (sizes[i] * 2 >= largestOld) return older[i];
    }
    return null;
  }

  /// Whether [file] reads as a whole encrypted backup as far as can be told
  /// without its password: it begins as one, and is at least as long as its
  /// header with the least a sealed backup holds after it. (Cut short past
  /// that, only its password tells.)
  @visibleForTesting
  static Future<bool> looksWhole(File file) async {
    try {
      final raf = await file.open();
      try {
        final length = await raf.length();
        final head = await raf.read(7);
        if (head.length < 7 || !BackupService.isBackupFile(head) || head[4] != 3) return false;
        final headerLength = (head[5] << 8) | head[6];
        return length >= 7 + headerLength + BackupService.leastSealed;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }
}
