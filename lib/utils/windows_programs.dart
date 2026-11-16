import 'dart:io';

/// Windows' own programs by their full paths (found 16 October 2026 in the
/// client's security review). Started by its name alone, a program is looked
/// for in the app's own folder, then in the app's current folder (the one it
/// was started in, a Downloads folder for one started from there), and only
/// then in System32: a file of that name in the current folder was run in
/// its stead. These are the places Windows keeps them.
///
/// %SystemRoot%; C:\Windows where it is not set.
String get windowsRoot {
  final root = Platform.environment['SystemRoot'];
  return root == null || root.trim().isEmpty ? r'C:\Windows' : root;
}

/// [exe] (icacls.exe, reg.exe, sc.exe, cmd.exe, where.exe, wsl.exe) in System32.
String windowsSystemProgram(String exe) => '$windowsRoot\\System32\\$exe';

/// Windows PowerShell 5.1, which every Windows has at this place.
String get windowsPowerShell => '$windowsRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';

/// Explorer, which is in %SystemRoot% itself.
String get windowsExplorer => '$windowsRoot\\explorer.exe';

/// [exe] in a folder of [path] (PATH by default), by its full path; null
/// where none has it. The current folder is never looked in, nor a folder of
/// PATH given as a relative one (which would be the current folder's).
String? findOnPath(String exe, {String? path, bool? windows}) {
  final isWindows = windows ?? Platform.isWindows;
  final dirs = (path ?? Platform.environment['PATH'] ?? '').split(isWindows ? ';' : ':');
  final sep = isWindows ? r'\' : '/';
  for (final raw in dirs) {
    final dir = raw.trim();
    if (dir.isEmpty || !_absolute(dir, isWindows)) continue;
    final candidate = dir.endsWith(sep) ? '$dir$exe' : '$dir$sep$exe';
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

bool _absolute(String dir, bool isWindows) => isWindows
    ? RegExp(r'^[A-Za-z]:[\\/]').hasMatch(dir) || dir.startsWith(r'\\')
    : dir.startsWith('/');

/// wsl.exe's arguments that run [program] in WSL with [arguments] as they
/// are. `--exec` starts it directly. Without it wsl.exe hands the whole line
/// to the Linux account's shell, which reads it again: a space, a quote, a
/// `$` or a `;` in a value (a key's path, a host) changed what ran (found 23
/// October 2026 in the whitepaper check: Eternal Terminal and Mosh started
/// that way).
List<String> wslExecArguments(String program, List<String> arguments) => ['--exec', program, ...arguments];
