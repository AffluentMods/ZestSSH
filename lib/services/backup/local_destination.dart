import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:zestssh/services/backup/backup_destination.dart';
import 'package:zestssh/utils/android_save_folder.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/profiles/active_profile.dart';

/// Backup destination that stores `.zest` files on the local filesystem.
///
/// - Android: `/storage/emulated/0/Download`
/// - iOS: Application Documents (accessible via Files app)
/// - Desktop: `Documents/ZestSSH/backups`
///
/// [survivesUninstall] is `false` because app-scoped storage on mobile
/// is wiped on uninstall. On desktop the Documents folder persists, but
/// we conservatively report `false` to encourage cloud destinations.
class LocalBackupDestination extends BackupDestination {
  LocalBackupDestination({Future<Directory> Function()? folder, Future<File> Function(File from, String to)? copy})
      : _folder = folder,
        _copy = copy ?? ((from, to) => from.copy(to));

  /// The folder backups are kept in, for a test; the platform's own otherwise.
  final Future<Directory> Function()? _folder;

  /// How a file is copied (a test breaks it off half way).
  final Future<File> Function(File from, String to) _copy;

  @override
  String get id => 'local';

  @override
  String get name => 'local';

  @override
  // In the person's language (it said "Local Storage" in English).
  String get displayName => gl10n.backupLocalStorage;

  @override
  bool get survivesUninstall => false;

  @override
  Future<bool> isAuthenticated() async => true;

  @override
  Future<void> authenticate() async {
    // Local storage is always accessible - no auth required.
  }

  /// Resolves the backup directory for the current platform.
  Future<Directory> _backupDir() async {
    final given = _folder;
    if (given != null) return given();
    final Directory dir;
    if (Platform.isAndroid) {
      // The Download folder where Android lets the app write there, else
      // the app's own folder (androidSaveFolder: Android 8 to 10).
      dir = await androidSaveFolder();
    } else if (Platform.isIOS) {
      final docs = await getApplicationDocumentsDirectory();
      dir = docs;
    } else {
      final docs = await getApplicationDocumentsDirectory();
      // Each profile's own on a computer: its backups are nobody else's.
      dir = ProfilePaths.forCurrent(Directory('${docs.path}/ZestSSH/backups'));
    }
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  @override
  Future<void> uploadBackup(File file, String filename) async {
    final dir = await _backupDir();
    final target = File('${dir.path}/$filename');
    if (target.path != file.path) {
      // Copied beside its name and put under it only when all of it is
      // there: a copy that broke off (the app ended, the disk filled) left a
      // short file under the backup's own name, listed and offered to restore
      // from as any other. What is beside the name is no backup ([listBackups]
      // takes names that end in .zest), and one left there goes with the next.
      final part = File('${target.path}$_partSuffix');
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      try {
        await _copy(file, part.path);
        final sent = await file.length();
        final has = await part.length();
        if (has != sent) throw FileSystemException('The copy of the backup holds $has of $sent bytes', target.path);
        await part.rename(target.path);
      } catch (_) {
        try {
          if (await part.exists()) await part.delete();
        } catch (_) {}
        rethrow;
      }
    }
    AppLogger.info('Local backup saved: ${target.path}');
  }

  /// What a copy on its way is named after the backup's own name.
  static const _partSuffix = '.part';

  @override
  Future<List<BackupFileInfo>> listBackups() async {
    final dir = await _backupDir();
    if (!dir.existsSync()) return [];

    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.zest'))
        .toList();

    // Sort newest first.
    files.sort(
        (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));

    return files.map((f) {
      final stat = f.statSync();
      return BackupFileInfo(
        filename: f.uri.pathSegments.last,
        createdAt: stat.modified,
        sizeBytes: stat.size,
        destinationId: id,
      );
    }).toList();
  }

  @override
  Future<File> downloadBackup(String filename, String localPath) async {
    final dir = await _backupDir();
    final source = File('${dir.path}/$filename');
    if (!source.existsSync()) {
      throw FileSystemException('Backup not found', source.path);
    }
    if (source.path == localPath) return source;
    return source.copy(localPath);
  }

  @override
  Future<void> deleteBackup(String filename) async {
    final dir = await _backupDir();
    final file = File('${dir.path}/$filename');
    if (file.existsSync()) {
      await file.delete();
      AppLogger.info('Local backup deleted: ${file.path}');
    }
  }

  @override
  Map<String, dynamic> toJson() => {
        'name': name,
        'id': id,
      };

  factory LocalBackupDestination.fromJson(Map<String, dynamic> json) {
    return LocalBackupDestination();
  }
}
