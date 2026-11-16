import 'dart:io';

import 'package:zestssh/utils/windows_programs.dart';

/// Where package managers put programs, which an app started from a Mac's
/// Finder or Dock does not have on its PATH (it has /usr/bin:/bin:/usr/sbin:
/// /sbin): Homebrew on Apple silicon, Homebrew on Intel and many a Linux's
/// own installs, MacPorts. Mosh and Eternal Terminal installed with Homebrew
/// were not found (found 16 October 2026 while comparing the five versions).
const kPackageManagerFolders = ['/opt/homebrew/bin', '/usr/local/bin', '/opt/local/bin'];

/// The PATH a program of the person's (mosh, et) is looked for on and runs
/// with, on macOS and Linux: the app's own, then the [folders] of package
/// managers it lacks. Mosh needs it to run: it starts mosh-client by name.
String toolPath([String? path, List<String> folders = kPackageManagerFolders]) {
  final own = (path ?? Platform.environment['PATH'] ?? '').split(':').where((d) => d.isNotEmpty).toList();
  return [...own, for (final d in folders) if (!own.contains(d)) d].join(':');
}

/// [name] (mosh, et) by its full path on [toolPath], or null where it is not
/// installed.
String? findTool(String name, {String? path, List<String> folders = kPackageManagerFolders}) =>
    findOnPath(name, path: toolPath(path, folders), windows: false);
