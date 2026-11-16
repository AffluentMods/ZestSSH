import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/services/ssh_service.dart' show shownHostText;
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/type_name.dart';

/// Running a command as root on a host with sudo (3.4): the file editor's
/// Save as root, and the files' Retry with sudo (a
/// move, copy, delete, rename, new folder, upload or download that
/// the host refused with "Permission denied").
///
/// The sudo password is typed each time and kept nowhere: it goes to sudo on
/// its standard input (`-S`, one line), never on a command line, and is in
/// no log line. sudo is asked for it every time (`-k`, so a password typed
/// wrong is never let through by an earlier sudo), prints no prompt (`-p
/// ''`), and speaks English (`LC_ALL=C`) so that what it says can be read.
/// With its input closed after that one line, sudo cannot wait for more: a
/// wrong password, an account that may not use sudo, a host where sudo
/// wants a terminal or has none, each ends at once and is said with a code.

/// What one exec channel did: the program's exit status (null where the
/// host sent none) and the start of what it wrote on its error stream.
typedef SudoExecResult = ({int? exitCode, Uint8List stderr});

/// Runs [command] on the host over one exec channel: [stdin] is written,
/// then closed; what the program writes on its standard output goes into
/// [stdoutTo] (and is read and dropped where that is null); the first 8 KB
/// of its error stream is kept. No byte from the host for [idle] ends the
/// channel and throws [SudoTimeoutException]. A host that runs no commands
/// (SFTP only) throws [SudoUnavailableException].
typedef SudoExec =
    Future<SudoExecResult> Function(
      String command, {
      required Uint8List stdin,
      StreamConsumer<List<int>>? stdoutTo,
      required Duration idle,
    });

/// [SudoExec] over [client]'s connection.
SudoExec sshSudoExec(SSHClient client) => (command, {required stdin, stdoutTo, required idle}) async {
  final SSHSession session;
  try {
    session = await client.execute(command);
  } on SSHChannelOpenError catch (e) {
    throw SudoUnavailableException(shownHostText(e.description));
  }
  final errors = BytesBuilder(copy: false);
  final quiet = Completer<void>();
  Timer? timer;
  void heard() {
    timer?.cancel();
    timer = Timer(idle, () {
      if (!quiet.isCompleted) quiet.complete();
    });
  }

  heard();
  final errDone = session.stderr.listen((chunk) {
    heard();
    if (errors.length < 8192) errors.add(chunk);
  }).asFuture<void>();
  final out = session.stdout.map((chunk) {
    heard();
    return chunk;
  });
  final outDone = stdoutTo == null ? out.drain<void>() : out.cast<List<int>>().pipe(stdoutTo);
  session.stdin.add(stdin);
  await session.stdin.close();
  try {
    await Future.any<void>([
      Future.wait<void>([session.done, outDone, errDone]),
      quiet.future.then<void>((_) => throw const SudoTimeoutException()),
    ]);
  } on SudoTimeoutException {
    session.destroy();
    rethrow;
  } finally {
    timer?.cancel();
  }
  return (exitCode: session.exitCode, stderr: errors.takeBytes());
};

/// The ways sudo can refuse, each said with its code.
sealed class SudoRefusedException implements Exception, HasTypeName {
  const SudoRefusedException();

  /// The code the person is shown with it.
  ErrorCode get code;

  @override
  String toString() => 'SudoRefusedException: $code';

  @override
  String get typeName => 'SudoRefusedException';
}

/// sudo said the password was wrong: nothing was done.
class SudoPasswordException extends SudoRefusedException {
  const SudoPasswordException();

  @override
  ErrorCode get code => ErrorCodes.sudoWrongPassword;

  @override
  String toString() => 'SudoPasswordException: sudo did not take the password';

  @override
  String get typeName => 'SudoPasswordException';
}

/// The login account may not use sudo for this; [said] is what sudo said.
class SudoNotAllowedException extends SudoRefusedException {
  const SudoNotAllowedException(this.said);
  final String said;

  @override
  ErrorCode get code => ErrorCodes.sudoNotAllowed;

  @override
  String toString() => 'SudoNotAllowedException: $said';

  @override
  String get typeName => 'SudoNotAllowedException';
}

/// sudo could not be run: the host has no sudo, or runs no commands (SFTP
/// only). [said] is what the host said.
class SudoUnavailableException extends SudoRefusedException {
  const SudoUnavailableException(this.said);
  final String said;

  @override
  ErrorCode get code => ErrorCodes.sudoUnavailable;

  @override
  String toString() => 'SudoUnavailableException: $said';

  @override
  String get typeName => 'SudoUnavailableException';
}

/// sudo on this host runs only from a terminal (`requiretty`).
class SudoNeedsTerminalException extends SudoRefusedException {
  const SudoNeedsTerminalException();

  @override
  ErrorCode get code => ErrorCodes.sudoNeedsTerminal;

  @override
  String toString() => 'SudoNeedsTerminalException: sudo wants a terminal on this host';

  @override
  String get typeName => 'SudoNeedsTerminalException';
}

/// Nothing came from the host for too long, and the channel was ended.
class SudoTimeoutException extends SudoRefusedException {
  const SudoTimeoutException();

  @override
  ErrorCode get code => ErrorCodes.sudoNoAnswer;

  @override
  String toString() => 'SudoTimeoutException: the host did not answer';

  @override
  String get typeName => 'SudoTimeoutException';
}

/// sudo let the command run, and the command failed (or sudo failed
/// otherwise); [said] is what the host said.
class SudoFailedException implements Exception, HasTypeName {
  const SudoFailedException(this.said);
  final String said;

  @override
  String toString() => 'SudoFailedException: $said';

  @override
  String get typeName => 'SudoFailedException';
}

/// Runs the app's own commands as root through sudo (see the top of this
/// file), over [SudoExec].
class SudoRunner {
  SudoRunner(this._exec);

  final SudoExec _exec;

  /// The command line for [program] as root. [program] is built by the app,
  /// every path in it quoted ([CommandText.quoted]); the password is not in
  /// it.
  static String commandFor(String program) => "env LC_ALL=C sudo -k -S -p '' -- $program";

  /// Runs [program] as root, [password] on sudo's standard input. What the
  /// program writes on its standard output goes into [stdoutTo]. Throws a
  /// [SudoRefusedException] where sudo refused, [SudoFailedException] where
  /// the program failed.
  Future<void> run(
    String program,
    String password, {
    StreamConsumer<List<int>>? stdoutTo,
    Duration idle = const Duration(minutes: 2),
  }) async {
    // One line is what sudo reads: a line end in it would be taken for the
    // end of the password and the rest given to the program.
    if (password.contains('\n') || password.contains('\r')) throw const SudoPasswordException();
    final name = program.split(' ').first;
    AppLogger.info('Running $name as root through sudo');
    final result = await _exec(
      commandFor(program),
      stdin: Uint8List.fromList(utf8.encode('$password\n')),
      stdoutTo: stdoutTo,
      idle: idle,
    );
    if (result.exitCode == 0) return;
    final e = refusal(utf8.decode(result.stderr, allowMalformed: true), exitCode: result.exitCode);
    AppLogger.warning('Running $name as root did not work: ${errorKind(e)}');
    throw e;
  }

  /// Why the command did not run, from what sudo or the program said on its
  /// error stream and its exit status (127: there was no sudo to run).
  static Exception refusal(String said, {int? exitCode}) {
    final s = said.toLowerCase();
    if (s.contains('incorrect password') ||
        s.contains('sorry, try again') ||
        s.contains('authentication failure') ||
        s.contains('no password was provided')) {
      return const SudoPasswordException();
    }
    if (s.contains('must have a tty') || s.contains('a terminal is required') || s.contains('no tty present')) {
      return const SudoNeedsTerminalException();
    }
    if (s.contains('not in the sudoers') ||
        s.contains('is not allowed to') ||
        s.contains('may not run sudo') ||
        s.contains('not allowed to execute')) {
      return SudoNotAllowedException(shownHostText(said));
    }
    if (exitCode == 127 || s.contains('sudo: not found') || s.contains('sudo: command not found')) {
      return SudoUnavailableException(shownHostText(said));
    }
    return SudoFailedException(shownHostText(said));
  }
}
