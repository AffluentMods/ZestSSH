import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:zestssh/features/password_managers/password_manager_ref.dart';
import 'package:zestssh/utils/type_name.dart';

// Password managers' command line tools (3.0): 1Password's `op`,
// Bitwarden's `bw` and KeePassXC's `keepassxc-cli`, on desktop. A tool is
// always run by an absolute path this code found (never looked up in the
// current folder), with a list of arguments (never through a shell: on
// Windows a `.cmd` or `.bat` would go through cmd.exe, which re-reads its
// arguments, so only `.exe` files are run), and what it prints is never
// logged: it is a password.

/// What running a tool gave back.
class PmProcessResult {
  const PmProcessResult(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// Runs a tool: the real one, or a stand-in in tests.
abstract class PmProcessRunner {
  /// Runs [executable] with [args]; [stdin] is written and closed; stops it
  /// after [timeout] ([PasswordManagerException] with
  /// [PmFailure.timedOut]).
  Future<PmProcessResult> run(
    String executable,
    List<String> args, {
    Map<String, String> environment = const {},
    String? stdin,
    required Duration timeout,
  });
}

class SystemPmProcessRunner implements PmProcessRunner {
  const SystemPmProcessRunner();

  @override
  Future<PmProcessResult> run(
    String executable,
    List<String> args, {
    Map<String, String> environment = const {},
    String? stdin,
    required Duration timeout,
  }) async {
    final Process process;
    try {
      process = await Process.start(executable, args, environment: environment, runInShell: false);
    } on ProcessException {
      throw const PasswordManagerException(PmFailure.notInstalled);
    }
    final out = process.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
    final err = process.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
    try {
      if (stdin != null) process.stdin.write(stdin);
      await process.stdin.close();
    } catch (_) {
      // The tool may exit before reading what it was given.
    }
    final int code;
    try {
      code = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill();
      throw const PasswordManagerException(PmFailure.timedOut);
    }
    return PmProcessResult(code, await out, await err);
  }
}

/// Why a password could not be fetched.
enum PmFailure {
  /// The tool is not installed where ZestSSH looks (or cannot be run).
  notInstalled,

  /// Signed out of the tool (`op signin`, `bw login` once, in a terminal).
  notSignedIn,

  /// Locked: Bitwarden needs its master password, KeePassXC its database
  /// password.
  locked,

  /// The password given to unlock was wrong.
  wrongPassword,

  /// No such item, field or entry.
  notFound,

  /// The person said no in the password manager, or closed its prompt.
  cancelled,

  /// No answer in time (a prompt left open).
  timedOut,

  /// KeePassXC: no database set on this device.
  noDatabase,

  /// Anything else; [PasswordManagerException.details] says what the tool
  /// said.
  failed,
}

class PasswordManagerException implements Exception, HasTypeName {
  const PasswordManagerException(this.failure, {this.details});

  final PmFailure failure;

  /// What the tool printed as its error (never what it printed as its
  /// answer), for the copyable error details.
  final String? details;

  @override
  String toString() => 'PasswordManagerException(${failure.name}${details == null ? '' : ': $details'})';

  @override
  String get typeName => 'PasswordManagerException';
}

/// Where this device keeps KeePassXC's database (set once, never synced).
class KeePassXcDatabase {
  const KeePassXcDatabase({required this.path, this.keyFile, this.noPassword = false});

  final String path;
  final String? keyFile;

  /// The database opens with its key file alone.
  final bool noPassword;
}

/// Whether [path] is a tool ZestSSH would run: an absolute path, an `.exe`
/// on Windows (a `.cmd` or `.bat` would go through cmd.exe), and there. The
/// one check for a path found, and for a path the person chose.
bool passwordManagerToolRunnable(String path, {required bool Function(String path) exists, required bool isWindows}) {
  if (!_absolute(path, isWindows)) return false;
  if (isWindows && !path.toLowerCase().endsWith('.exe')) return false;
  return exists(path);
}

/// Finds a tool: the path this device was set to use, else the usual
/// install places, else the PATH (absolute folders only). Null when none is
/// there. Pure (given [exists], [listDir], [environment] and the platform)
/// for tests.
///
/// The usual places are where each tool's own installs put it, which a
/// window app often cannot see on its PATH: a package installed after
/// ZestSSH started is not on the PATH ZestSSH was given, and on macOS an app
/// is never given the shell's. [listDir] names what is in a folder (none
/// when it is not there): it finds a winget package's folder, whose name
/// carries its source, and the versions of Node that nvm keeps.
String? findPasswordManagerCli(
  PasswordManagerKind kind, {
  String? configured,
  required Map<String, String> environment,
  required bool Function(String path) exists,
  required bool isWindows,
  required bool isMacOS,
  List<String> Function(String dir)? listDir,
}) {
  final sep = isWindows ? r'\' : '/';
  bool runnable(String path) => passwordManagerToolRunnable(path, exists: exists, isWindows: isWindows);

  if (configured != null && configured.trim().isNotEmpty) {
    final c = configured.trim();
    return runnable(c) ? c : null;
  }
  final name = switch (kind) {
    PasswordManagerKind.onePassword => 'op',
    PasswordManagerKind.bitwarden => 'bw',
    PasswordManagerKind.keePassXc => 'keepassxc-cli',
  };
  final file = isWindows ? '$name.exe' : name;
  final home = isWindows ? environment['USERPROFILE'] : environment['HOME'];
  final local = environment['LOCALAPPDATA'];
  final programFiles = environment['ProgramFiles'];

  /// The folders in [dir] whose names [keep] takes, newest name first; a
  /// name that could step out of [dir] is never one.
  List<String> foldersIn(String dir, bool Function(String name) keep) {
    final names = [
      for (final n in listDir?.call(dir) ?? const <String>[])
        if (n.isNotEmpty && !n.contains('/') && !n.contains(r'\') && !n.contains('..') && keep(n)) n,
    ]..sort((a, b) => b.compareTo(a));
    return [for (final n in names) '$dir$sep$n'];
  }

  // A winget package's own folder (its link in WinGet\Links is made only
  // where links are on): AgileBits.1Password.CLI_<source>.
  final wingetPackage = switch (kind) {
    PasswordManagerKind.onePassword => 'AgileBits.1Password.CLI_',
    PasswordManagerKind.bitwarden => 'Bitwarden.CLI_',
    PasswordManagerKind.keePassXc => null,
  };
  // Where npm puts a global package's command on macOS and Linux (only
  // Bitwarden's tool comes from npm): its own prefix, a prefix of the
  // person's, Volta's and nvm's.
  final npmBins = <String>[
    if (!isWindows && kind == PasswordManagerKind.bitwarden) ...[
      if (environment['NPM_CONFIG_PREFIX'] case final prefix?) '$prefix/bin',
    ],
    if (!isWindows && kind == PasswordManagerKind.bitwarden && home != null) ...[
      '$home/.npm-global/bin',
      '$home/.volta/bin',
      ...[for (final v in foldersIn('$home/.nvm/versions/node', (n) => RegExp(r'^v\d[\w.-]*$').hasMatch(n))) '$v/bin'],
    ],
  ];
  final candidates = <String>[
    if (isWindows) ...[
      if (local != null) '$local${sep}Microsoft${sep}WinGet${sep}Links$sep$file',
      if (local != null && wingetPackage != null)
        for (final dir in foldersIn('$local${sep}Microsoft${sep}WinGet${sep}Packages', (n) => n.startsWith(wingetPackage)))
          '$dir$sep$file',
      // The folder 1Password's guide has its tool unzipped into.
      if (kind == PasswordManagerKind.onePassword && programFiles != null) '$programFiles${sep}1Password CLI$sep$file',
      if (kind == PasswordManagerKind.keePassXc) ...[
        if (programFiles != null) '$programFiles${sep}KeePassXC$sep$file',
        if (local != null) '$local${sep}Programs${sep}KeePassXC$sep$file',
      ],
      if (environment['SCOOP'] case final scoop?) '$scoop${sep}shims$sep$file',
      if (home != null) '$home${sep}scoop${sep}shims$sep$file',
      // Scoop's KeePassXC names only the app in its shims.
      if (kind == PasswordManagerKind.keePassXc && home != null)
        '$home${sep}scoop${sep}apps${sep}keepassxc${sep}current$sep$file',
      if (environment['ProgramData'] case final pd?) '$pd${sep}chocolatey${sep}bin$sep$file',
    ] else if (isMacOS) ...[
      if (kind == PasswordManagerKind.keePassXc) ...[
        '/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli',
        if (home != null) '$home/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli',
      ],
      '/opt/homebrew/bin/$file',
      '/usr/local/bin/$file',
      if (kind == PasswordManagerKind.bitwarden) for (final bin in npmBins) '$bin/$file',
      if (home != null) '$home/.local/bin/$file',
    ] else ...[
      '/usr/bin/$file',
      '/usr/local/bin/$file',
      if (kind == PasswordManagerKind.bitwarden) '/snap/bin/bw',
      if (kind == PasswordManagerKind.keePassXc) '/snap/bin/keepassxc.cli',
      if (kind == PasswordManagerKind.bitwarden) for (final bin in npmBins) '$bin/$file',
      if (home != null) ...['$home/.local/bin/$file', '$home/.nix-profile/bin/$file'],
      '/run/current-system/sw/bin/$file',
      '/home/linuxbrew/.linuxbrew/bin/$file',
    ],
  ];
  for (final c in candidates) {
    if (runnable(c)) return c;
  }
  final path = environment[isWindows ? 'Path' : 'PATH'] ?? environment['PATH'] ?? '';
  for (final dir in path.split(isWindows ? ';' : ':')) {
    final d = dir.trim();
    // A relative folder (or '.') would find a tool dropped wherever ZestSSH
    // was started.
    if (d.isEmpty || !_absolute(d, isWindows)) continue;
    final c = d.endsWith(sep) ? '$d$file' : '$d$sep$file';
    if (runnable(c)) return c;
  }
  return null;
}

bool _absolute(String path, bool isWindows) =>
    isWindows ? RegExp(r'^[A-Za-z]:\\').hasMatch(path) : path.startsWith('/');

/// The arguments that fetch [ref]'s password. Everything after `--` is read
/// as a name, never as an option.
List<String> fetchArgs(PasswordRef ref, {KeePassXcDatabase? database}) => switch (ref.kind) {
      PasswordManagerKind.onePassword => ['read', '--no-newline', '--', ref.target],
      // A Bitwarden id is a UUID (checked), so it can never read as an option.
      PasswordManagerKind.bitwarden => ['get', 'password', ref.target],
      PasswordManagerKind.keePassXc => [
          'show',
          '--quiet',
          '--show-protected',
          '--attributes',
          ref.attribute,
          if (database?.keyFile case final key?) ...['--key-file', key],
          if (database?.noPassword ?? false) '--no-password',
          '--',
          database?.path ?? '',
          ref.target,
        ],
    };

/// The tool's answer as the password: its one trailing line end taken off.
String passwordFromOutput(String stdout) {
  if (stdout.endsWith('\r\n')) return stdout.substring(0, stdout.length - 2);
  if (stdout.endsWith('\n')) return stdout.substring(0, stdout.length - 1);
  return stdout;
}

/// What a tool's error means, from what it printed.
PmFailure classifyFailure(PasswordManagerKind kind, String stderr) {
  final e = stderr.toLowerCase();
  switch (kind) {
    case PasswordManagerKind.onePassword:
      if (e.contains('dismissed') || e.contains('denied') || e.contains('cancel')) return PmFailure.cancelled;
      if (e.contains('not signed in') || e.contains('no accounts configured') || e.contains('sign in')) {
        return PmFailure.notSignedIn;
      }
      if (e.contains("isn't an item") || e.contains('not found') || e.contains("isn't a vault") ||
          e.contains('no item') || e.contains('does not have a field')) {
        return PmFailure.notFound;
      }
    case PasswordManagerKind.bitwarden:
      if (e.contains('not logged in')) return PmFailure.notSignedIn;
      if (e.contains('vault is locked') || e.contains('session')) return PmFailure.locked;
      if (e.contains('invalid master password')) return PmFailure.wrongPassword;
      if (e.contains('not found')) return PmFailure.notFound;
    case PasswordManagerKind.keePassXc:
      if (e.contains('invalid credentials') || e.contains('wrong key') || e.contains('invalid password')) {
        return PmFailure.wrongPassword;
      }
      if (e.contains('could not find entry') || e.contains('not found') || e.contains("doesn't have")) {
        return PmFailure.notFound;
      }
      if (e.contains('failed to open') || e.contains('no such file')) return PmFailure.noDatabase;
  }
  return PmFailure.failed;
}
