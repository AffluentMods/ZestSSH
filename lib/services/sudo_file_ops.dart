import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/services/sudo_runner.dart';
import 'package:zestssh/utils/command_text.dart';
import 'package:zestssh/utils/file_manager.dart' show restrictFileToOwner;

/// Retry with sudo (3.4): a file action that the
/// host refused with "Permission denied", done again as root through sudo
/// ([SudoRunner]): over an exec channel, as the command that does the same
/// in a terminal, every path in single quotes ([CommandText.quoted]) and
/// only a path that may stand in any shell's command line
/// ([CommandText.standsInAnyShell]; never a Windows host's).
sealed class SudoFileOp {
  const SudoFileOp();

  /// The host's paths it names.
  List<String> get remotePaths;

  /// What it runs, as the dialog shows it ("mv /etc/a /etc/b"): the
  /// program and its paths as they are, without the quotes.
  String get shown;

  /// Whether it may be run: every path it names may stand in a command line.
  bool get runnable => remotePaths.every((p) => CommandText.standsInAnyShell(p) && !isWindowsDrivePath(p));
}

/// A move or a rename: `mv`, never over what is at [to] already.
final class SudoMove extends SudoFileOp {
  const SudoMove(this.from, this.to);
  final String from;
  final String to;

  @override
  List<String> get remotePaths => [from, to];

  @override
  String get shown => 'mv $from $to';
}

/// A copy on one host: `cp -p` for a file (over the file at [to], as the
/// person chose when asked), `cp -rp` for a [folder], which is never copied
/// over or into one that is there.
final class SudoCopy extends SudoFileOp {
  const SudoCopy(this.from, this.to, {this.folder = false});
  final String from;
  final String to;
  final bool folder;

  @override
  List<String> get remotePaths => [from, to];

  @override
  String get shown => folder ? 'cp -rp $from $to' : 'cp -p $from $to';
}

/// A delete, asked about already: `rm`, `rm -r` for a [folder].
final class SudoDelete extends SudoFileOp {
  const SudoDelete(this.path, {this.folder = false});
  final String path;
  final bool folder;

  @override
  List<String> get remotePaths => [path];

  @override
  String get shown => folder ? 'rm -r $path' : 'rm $path';
}

/// A new folder: `mkdir`.
final class SudoMkdir extends SudoFileOp {
  const SudoMkdir(this.path);
  final String path;

  @override
  List<String> get remotePaths => [path];

  @override
  String get shown => 'mkdir $path';
}

/// An upload of the file at [localPath] (on this device) to [remotePath]:
/// sent first to a file of its own in /tmp that only the login account may
/// read, then copied into place with `cp`, which keeps the owner and mode
/// of a file that is there; a new file is given mode 644.
final class SudoUpload extends SudoFileOp {
  const SudoUpload(this.localPath, this.remotePath);
  final String localPath;
  final String remotePath;

  @override
  List<String> get remotePaths => [remotePath];

  @override
  String get shown => 'cp ${p.basename(localPath)} $remotePath';
}

/// A download of [remotePath] to [localPath] (on this device): `cat`, its
/// bytes written to a file beside [localPath] that takes its name once all
/// of them came.
final class SudoDownload extends SudoFileOp {
  const SudoDownload(this.remotePath, this.localPath);
  final String remotePath;
  final String localPath;

  @override
  List<String> get remotePaths => [remotePath];

  @override
  String get shown => 'cat $remotePath';
}

/// Runs [SudoFileOp]s as root on one host.
class SudoFileOps {
  SudoFileOps({
    required SudoRunner runner,
    required Future<String> Function(String localPath) putTemp,
    required Future<void> Function(String remoteTemp) removeTemp,
  }) : _runner = runner,
       _putTemp = putTemp,
       _removeTemp = removeTemp;

  /// Over [service]'s connection.
  factory SudoFileOps.over(SftpService service) => SudoFileOps(
    runner: service.sudoRunner(),
    putTemp: service.putPrivateTempFile,
    removeTemp: service.removePrivateTempFile,
  );

  final SudoRunner _runner;
  final Future<String> Function(String localPath) _putTemp;
  final Future<void> Function(String remoteTemp) _removeTemp;

  /// What runs ahead of a move, or the copy of a folder: where something is
  /// at the second path already, it is said and nothing is done (a plain
  /// `mv` would put a folder into one of that name, or replace a file).
  @visibleForTesting
  static const String noClobber = r'if [ -e "$2" ] || [ -h "$2" ]; then echo "$2: File exists" >&2; exit 1; fi; ';

  /// What runs ahead of a write as root over a file: where the second path
  /// is a symbolic link (one that leads nowhere included, which `-e` says is
  /// not there), it is said and nothing is written. Root would otherwise
  /// write wherever the link leads, which whoever may write its folder chose
  /// (the 3.4 security review). Checked in the very command that writes.
  static const String notALink = r'if [ -h "$2" ]; then echo "$2: Is a symbolic link" >&2; exit 1; fi; ';

  /// What puts an uploaded file from /tmp into place: never through a
  /// symbolic link ([notALink]); not over a folder; over a file that is
  /// there with its owner and mode kept; else a new file, mode 644.
  ///
  /// It is written beside the file, as a part, and takes the file's place in
  /// one step (a rename in the same folder) only once all of it is there, as
  /// every other upload does (SftpService's `.zestpart`). Where the write
  /// stops halfway, a full disk, a quota, the session gone, the part is
  /// removed and the file holds what it held. (It was `cp` onto the file
  /// itself, which empties the file first: a save of /etc/ssh/sshd_config on
  /// a full disk left it cut short, the old content gone. Found in a code
  /// audit.)
  ///
  /// The part's name is made as the part is (`mktemp`:
  /// `<file>.zestpart.XXXXXX`, created only where nothing has that name), so
  /// nobody can tell it beforehand. Under the one name `<file>.zestpart`,
  /// removed and then written by name as root, a symbolic link put there in
  /// between, in a folder others may write (/tmp), sent the write wherever it
  /// led: the very thing [notALink] is there to stop, one name further on
  /// (found in a code review). A host with no `mktemp` gets the
  /// one name, made by the shell only where nothing has it (`set -C`). A
  /// `<file>.zestpart` an earlier try left is removed, never written.
  ///
  /// Over a file that is there the part is made a copy of it (`cp -p`:
  /// owner, mode and, where the system has them, its ACL), is given the
  /// file's SELinux label where there is `chcon`, and is then filled with
  /// the new content. The file's hard links, if it has any, keep the old
  /// content: the name gets a new file.
  static const String uploadScript =
      '$notALink'
      r'if [ -d "$2" ]; then echo "$2: Is a directory" >&2; exit 1; fi; '
      r'rm -f -- "$2.zestpart"; '
      r'p=$(mktemp -- "$2.zestpart.XXXXXX" 2>/dev/null) || { p="$2.zestpart"; ( set -C; : > "$p" ) || exit 1; }; '
      r'trap "rm -f -- \"\$p\"; exit 1" HUP INT TERM; '
      r'if [ -e "$2" ]; then '
      r'cp -p -- "$2" "$p" && { chcon --reference="$2" -- "$p" 2>/dev/null || :; } '
      r'&& cat -- "$1" > "$p" && mv -f -- "$p" "$2"; '
      r'else cp -- "$1" "$p" && chmod 644 -- "$p" && mv -f -- "$p" "$2"; fi; '
      r's=$?; if [ "$s" -ne 0 ]; then rm -f -- "$p"; fi; exit "$s"';

  static String _q(String s) => CommandText.quoted(s);

  /// The program [op] runs as root ([SudoRunner.commandFor] puts sudo before
  /// it); [temp] is the upload's file in /tmp.
  @visibleForTesting
  static String program(SudoFileOp op, {String? temp}) => switch (op) {
    SudoMove(:final from, :final to) => "sh -c '${noClobber}exec mv -- \"\$1\" \"\$2\"' sh ${_q(from)} ${_q(to)}",
    SudoCopy(:final from, :final to, folder: true) =>
      "sh -c '${noClobber}exec cp -rp -- \"\$1\" \"\$2\"' sh ${_q(from)} ${_q(to)}",
    SudoCopy(:final from, :final to) => "sh -c '${notALink}exec cp -p -- \"\$1\" \"\$2\"' sh ${_q(from)} ${_q(to)}",
    SudoDelete(:final path, folder: true) => 'rm -r -- ${_q(path)}',
    SudoDelete(:final path) => 'rm -- ${_q(path)}',
    SudoMkdir(:final path) => 'mkdir -- ${_q(path)}',
    SudoUpload(:final remotePath) => "sh -c '$uploadScript' sh ${_q(temp!)} ${_q(remotePath)}",
    SudoDownload(:final remotePath) => 'cat -- ${_q(remotePath)}',
  };

  /// How long the host may send nothing before [op] is given up: a whole
  /// folder may take a while.
  static Duration _idle(SudoFileOp op) => switch (op) {
    SudoCopy(folder: true) || SudoDelete(folder: true) => const Duration(minutes: 10),
    _ => const Duration(minutes: 2),
  };

  /// Runs [op] as root, [password] given to sudo. Throws
  /// [SftpNameNotInCommandException] for a path that may not stand in a
  /// command line (nothing is sent), else what [SudoRunner.run] throws.
  Future<void> run(SudoFileOp op, String password) async {
    if (!op.runnable) {
      throw SftpNameNotInCommandException(
        op.remotePaths.firstWhere((p) => !CommandText.standsInAnyShell(p) || isWindowsDrivePath(p)),
      );
    }
    switch (op) {
      case SudoUpload(:final localPath):
        final temp = await _putTemp(localPath);
        try {
          await _runner.run(program(op, temp: temp), password, idle: _idle(op));
        } finally {
          await _removeTemp(temp);
        }
      case SudoDownload(:final localPath):
        final part = File('$localPath.zestpart');
        try {
          // A file only root may read (a key, /etc/shadow) is made readable
          // by this account alone before a byte of it is written: with the
          // process's umask, other accounts on this computer could read it
          // (the 3.4 security review). It keeps that as it is renamed.
          await part.writeAsBytes(const [], flush: true);
          await restrictFileToOwner(part);
          await _runner.run(program(op), password, stdoutTo: part.openWrite(), idle: _idle(op));
          await part.rename(localPath);
        } catch (_) {
          try {
            if (await part.exists()) await part.delete();
          } catch (_) {
            /* best effort */
          }
          rethrow;
        }
      default:
        await _runner.run(program(op), password, idle: _idle(op));
    }
  }
}
