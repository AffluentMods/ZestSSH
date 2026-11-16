import 'dart:io';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:zestssh/utils/windows_programs.dart';

/// [path] as the system writes it: on Windows every separator a backslash (a
/// backup's path mixed `C:\Users\...\Documents/ZestSSH/backups/...`, the
/// dialog rules of 3.4, rule 6). Elsewhere it is left as it is: a backslash
/// there is part of a name, not a separator.
String systemPath(String path) =>
    defaultTargetPlatform == TargetPlatform.windows ? path.replaceAll('/', r'\') : path;

/// [path] in the system's style ([systemPath]) as its file name and the
/// folder it is in, to show the name first and the folder under it. The
/// folder is empty for a bare name.
({String name, String folder}) splitSystemPath(String path) {
  final shown = systemPath(path);
  final sep = defaultTargetPlatform == TargetPlatform.windows ? r'\' : '/';
  final at = shown.lastIndexOf(sep);
  if (at < 0) return (name: shown, folder: '');
  // The folder of a file at the top of a drive or of the system keeps its
  // separator (C:\, /).
  final folder = shown.substring(0, at);
  return (
    name: shown.substring(at + 1),
    folder: folder.isEmpty || folder.endsWith(':') ? '$folder$sep' : folder,
  );
}

/// Show [path] (a folder) in the OS file manager. Desktop only; a failure is
/// swallowed because opening a folder is a convenience, never a step a
/// workflow depends on.
Future<void> openFolderInFileManager(String path) async {
  try {
    if (Platform.isWindows) {
      // Explorer returns a non-zero exit code even on success; ignore it.
      await Process.run(windowsExplorer, [path.replaceAll('/', r'\')]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [path]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [path]);
    }
  } catch (_) {
    // Nothing to recover: the folder simply did not open.
  }
}

/// Show the file [path] in the desktop file manager, selected where the
/// platform can (Explorer on Windows, Finder on macOS), else its folder
/// (Linux). Best effort, like [openFolderInFileManager].
Future<void> revealFileInFileManager(String path) async {
  try {
    if (Platform.isWindows) {
      // Explorer wants backslashes and returns a non-zero exit code even on
      // success.
      await Process.run(windowsExplorer, ['/select,', path.replaceAll('/', r'\')]);
    } else if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [File(path).parent.path]);
    }
  } catch (_) {
    // Nothing to recover: the file simply was not shown.
  }
}

/// Makes [file] readable and writable by the person signed in to this
/// computer alone (icacls on Windows, chmod 600 elsewhere); false when it
/// could not. A file holding a secret (a recovery kit, recovery codes) is
/// written with the folder's defaults, which another account may read.
Future<bool> restrictFileToOwner(File file) async {
  final instead = debugRestrictFileToOwner;
  if (instead != null) return instead(file);
  try {
    final ProcessResult r;
    if (Platform.isWindows) {
      final user = Platform.environment['USERNAME'] ?? Platform.environment['USER'];
      if (user == null || user.isEmpty) return false;
      r = await Process.run(windowsSystemProgram('icacls.exe'), [file.path, '/inheritance:r', '/grant:r', '$user:(R,W)']);
    } else {
      r = await Process.run('chmod', ['600', file.path]);
    }
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Stands in for [restrictFileToOwner] in tests (a file that cannot be kept
/// private is not something a test can make the system do).
@visibleForTesting
Future<bool> Function(File file)? debugRestrictFileToOwner;
