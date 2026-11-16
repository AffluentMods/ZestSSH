import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/ftps.dart' show FtpsErrorKind, FtpsException;
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/terminal_providers.dart' show connectionFailureText;
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/error_translator.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/report_scrub.dart';

/// What a connection test of the host editor says of a failure, and what it
/// keeps behind "Copy details" (3.0; the SSH core's audit, the last part of
/// its step for the kinds of error).
///
/// The editor had words of its own for most failures of its tests, apart
/// from what a failed connection says of the same thing: "Auth rejected by
/// server: All authentication methods failed" of every sign-in a host
/// refused, "Auth aborted: Connection closed before authentication" of
/// whatever cut a sign-in off that it had no sentence for, and the
/// system's own words, in the system's language, of a port that nothing
/// listens on. Behind "Copy details" it kept one line, or nothing. (The
/// editor's widget tests press the buttons: connection_edit_full_test_test.dart.)
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  setUp(() {
    L10nGlobal.update(en);
    AppLogger.forget();
    ReportScrub.clearFolders();
    Redactor.instance
      ..clearNames()
      ..salt = 'a test'
      ..enabled = false;
    ErrorReport.app = 'ZestSSH 3.0.0 (build 256)';
    ErrorReport.system = () => 'windows 11';
  });

  tearDown(() {
    ErrorReport.app = 'ZestSSH';
    ErrorReport.system = ErrorReport.systemLabel;
  });

  /// What a failed connection says of [e]: what went wrong and, after it,
  /// what to try.
  String asAFailedConnection(Object e, {String? host, int? port, String? username}) {
    final shown = ConnectionError.translate(connectionFailureText(e), host: host, port: port, username: username);
    return shown.tip == null ? shown.description : '${shown.description}\n\n${shown.tip}';
  }

  test('it says what a failed connection says, for the host, the port and the user it was given', () {
    final refusedKey = SSHAuthFailError('All authentication methods failed',
        methodsTried: const ['publickey'], serverTakes: const ['publickey']);
    final said = connectionTestFailed(en, refusedKey, host: 'web-01.example.com', port: 2222, username: 'deploy');
    expect(said.message, '${en.errKeyAuthFailedDesc} (deploy@web-01.example.com)\n\n${en.errKeyAuthFailedTip}');
    expect(said.message, asAFailedConnection(refusedKey, host: 'web-01.example.com', port: 2222, username: 'deploy'));

    const closedPort = SocketException('Connection refused');
    expect(connectionTestFailed(en, closedPort, host: 'web-01.example.com', port: 2222).message,
        '${en.errRefusedDesc('web-01.example.com', 2222)}\n\n${en.errRefusedTip}');

    // A sentence with no tip is said by itself.
    final ended = SSHAuthAbortError('Connection closed before authentication',
        SSHDisconnectError(2, 'Too many authentication failures', authentic: true));
    final endedSaid = connectionTestFailed(en, ended, host: 'web-01.example.com').message;
    expect(endedSaid, isNot(contains('\n')));
    expect(endedSaid, asAFailedConnection(ended, host: 'web-01.example.com'));
  });

  test('behind "Copy details": the report of the failure, with what was said, where, the error and what cut it off, '
      'and the kind it is shown as', () {
    final cutOff = SSHAuthAbortError(
        'Connection closed before authentication', SSHHandshakeError('No matching client cipher algorithm'));
    final said = connectionTestFailed(en, cutOff, host: 'web-01.example.com', port: 22, onAComputer: true);
    final report = said.report!.split('\n');
    expect(report.first, 'ZestSSH error details');
    // (One line for what was said: its tip follows on the same line.)
    expect(report[1], startsWith('What: Could not agree on a cipher algorithm with '));
    expect(report[1], endsWith(en.errAlgorithmMismatchTip('Auth / Show advanced options').split(' ').last));
    expect(report[2], 'Where: Testing a connection from the host editor');
    expect(report[3], 'Error: SSHAuthAbortError(Connection closed before authentication)');
    expect(report[4], '  What cut it off: SSHHandshakeError(No matching client cipher algorithm)');
    expect(report.sublist(5, 7), ['Details:', '  Kind: algorithmMismatch']);
    // The host's name is taken out of what is copied, as out of every report.
    expect(said.report, isNot(contains('web-01.example.com')));
    expect(said.message, contains('web-01.example.com'));
  });

  test('what the app itself said of what stopped a test is shown as it said it, with what was caught behind it', () {
    const words = 'Your certificate is waiting for an owner\'s device to sign it.';
    final said = connectionTestFailed(en, ConnectionTestSaid(words, StateError('no certificate yet')));
    expect(said.message, words);
    final report = said.report!.split('\n');
    expect(report[1], 'What: $words');
    expect(report.where((line) => line.startsWith('Error')),
        ['Error: Bad state: no certificate yet', 'Error type: StateError']);
    expect(report, contains('  Kind: saidByApp'));
    expect('${const ConnectionTestSaid(words, 'x')}', saidByApp(words));
  });

  test('an FTPS host\'s failure is said in FTPS\'s words, as its failed connection says it, with the error behind '
      'Copy details', () {
    const refused = FtpsException(FtpsErrorKind.login, '530 Login incorrect.', code: 530);
    final said = connectionTestFailed(en, refused, host: 'files.example.com', port: 21, username: 'demo');
    expect(said.message, en.ftpsLoginRefused);
    expect(said.message, asAFailedConnection(refused, host: 'files.example.com', port: 21, username: 'demo'));
    expect(said.report, contains('530 Login incorrect.'));
    const broke = FtpsException(FtpsErrorKind.protocol, 'unexpected reply: 999 what');
    final other = connectionTestFailed(en, broke, host: 'files.example.com', port: 21);
    expect(other.message, isNot(contains('999 what')), reason: 'the error\'s own words go to Copy details');
    expect(other.report, contains('999 what'));
  });

  test('where the test\'s own check of the host\'s key said no, it says that the key is not trusted yet, and there '
      'is no report: nothing failed', () {
    final stopped =
        SSHAuthAbortError('Connection closed before authentication', SSHHostkeyError('Hostkey verification failed'));
    final said = connectionTestFailed(en, stopped, host: 'web-01.example.com', port: 22);
    expect(said.message, en.connectionEditHostKeyUntrusted);
    expect(said.report, isNull);
  });

  test('every failure of the two tests is said by that one function, and their timeouts are their own (read from '
      'the editor\'s file)', () {
    final source =
        File('lib/features/hosts/host_tester.dart').readAsStringSync().replaceAll('\r\n', '\n');
    // The reachability test; the four kinds the full test tells apart (a refused sign-in,
    // a socket, a sign-in that ran out of time, and the rest); and an FTPS host's test,
    // both its buttons, whatever stopped it.
    expect('      return _failed(l10n, e, cfg);\n'.allMatches(source), hasLength(6));
    // And a remote screen's test, past what it says itself (not VNC, turned away): the same function, with an
    // RDP host's failure said as an RDP host's.
    expect(source, contains('      return _failed(l10n, screenRdp && e is ScreenFailure ? e.asRdp() : e, cfg);\n'));
    expect(
      source,
      contains('      // Cancelling the server\'s question ends the test without a verdict.\n'
          '      return answerer?.cancelled == true ? null : _failed(l10n, e, cfg);\n'),
    );
    // Whatever else the full test is stopped by, but for a key its own check did not take.
    expect(
      source,
      contains('      if (hostKeyUntrusted) {\n'
          '        return HostTestResult(success: false, message: l10n.connectionEditHostKeyUntrusted);\n'
          '      }\n'
          '      return _failed(l10n, e, cfg);\n'),
    );
    // Seven in that form (the six, and the one a cancelled question guards) and the remote screen's: eight calls.
    expect('_failed(l10n, e, cfg)'.allMatches(source), hasLength(7));
    expect('_failed(l10n, '.allMatches(source), hasLength(8));
    // The timeouts are their own: the socket's clock of the reachability test, of an FTPS host's
    // and of a remote screen's, and the full test's own words for where it ran out of time.
    expect('      return HostTestResult(success: false, message: l10n.connectionTimedOut);\n'.allMatches(source),
        hasLength(3));
    expect(source, contains('      return HostTestResult(success: false, message: e.message ?? l10n.connectionTimedOut);\n'));
    // An FTPS host's test keeps no report of its own: the one function makes it.
    expect(source, isNot(contains('ErrorReport.build(what: said, where: \'Testing an FTPS host\'')));
    // And nothing of the system's own words for a socket that could not connect is shown any more.
    expect(source, isNot(contains('e.osError?.message ?? e.message')));
  });
}
