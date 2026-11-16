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
  LocalBackupDestination();

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
      await file.copy(target.path);
    }
    AppLogger.info('Local backup saved: ${target.path}');
  }

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
