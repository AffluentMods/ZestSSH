import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:zestssh/utils/logger.dart';

/// A lock on a file in the app's own folder that a running ZestSSH holds for
/// as long as it runs, so that `zestssh admin ...` can tell the app is open.
///
/// The command skips the one-instance check on purpose and started a whole
/// second app on the same data: beside the open app it ran sync and the team
/// rounds a second time on the same database (found in a code audit).
/// Now the command, finding the lock held, says to close ZestSSH first
/// and ends. The app itself never refuses to start for it: where the lock
/// cannot be taken (held by such a command, or a folder that takes no locks)
/// it starts as before. The system lets the lock go when the process ends,
/// however it ends.
class AppInstanceLock {
  AppInstanceLock._();

  static RandomAccessFile? _held;

  /// The name of the lock's file in the app's folder.
  static const fileName = 'zestssh.instance.lock';

  /// Where the lock's file is; for tests.
  @visibleForTesting
  static Future<Directory> Function() folder = getApplicationSupportDirectory;

  /// Takes the lock for this process. True when it is held now (taken here,
  /// or earlier in this run); false when another process holds it, or it
  /// could not be taken. Never throws.
  static Future<bool> take() async {
    if (_held != null) return true;
    RandomAccessFile? file;
    try {
      final dir = await folder();
      if (!dir.existsSync()) dir.createSync(recursive: true);
      file = await File('${dir.path}${Platform.pathSeparator}$fileName').open(mode: FileMode.append);
      await file.lock(FileLock.exclusive);
      _held = file;
      return true;
    } catch (e) {
      AppLogger.info('The instance lock is not held by this process ($e)');
      try {
        await file?.close();
      } catch (_) {}
      return false;
    }
  }

  /// Lets the lock go; for tests (a process lets it go as it ends).
  @visibleForTesting
  static Future<void> release() async {
    final file = _held;
    _held = null;
    if (file == null) return;
    try {
      await file.unlock();
    } catch (_) {}
    await file.close();
  }
}
