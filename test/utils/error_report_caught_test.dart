import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart' show OrchardServerException;
import 'package:zestssh/services/jump_host_failure.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/report_scrub.dart';

/// What a report says of the thing that was caught, beyond its own text
/// (3.0; the SSH core's audit, the step it names for the kinds of error).
///
/// A report carried the error as it prints itself and nothing else of it.
/// Two things were missing from that. Many of the app's own errors print a
/// sentence, and not what they are: "Orchards: HTTP 403 forbidden" does not
/// say that an OrchardServerException was caught, and a report from a
/// released app has no stack to say it either. And a sign-in that was cut
/// off prints "Connection closed before authentication" and not what closed
/// the connection, which the error knows: one report (Server Monitor's)
/// added that by hand, and about thirty others did not.
void main() {
  final at = DateTime.utc(2026, 10, 11, 9, 30);

  setUp(() {
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
    Redactor.instance.clearNames();
    ErrorReport.app = 'ZestSSH';
    ErrorReport.system = ErrorReport.systemLabel;
  });

  /// A jump host on the way that failed with [cause] at [stage].
  JumpHostFailure jump(JumpStage stage, Object cause) =>
      JumpHostFailure(label: 'gateway', host: '192.0.2.10', port: 22, stage: stage, cause: cause);

  /// The lines of the report of [error] that are about the error: from
  /// "Error:" up to the line that names the app.
  List<String> saidOf(Object? error) {
    final lines = ErrorReport.build(what: 'It failed.', where: 'A test', error: error, now: at).split('\n');
    return lines.sublist(lines.indexOf('Where: A test') + 1, lines.indexOf('App: ZestSSH 3.0.0 (build 256)'));
  }

  group('What kind of thing was caught', () {
    test('an error whose own text names its kind: the text, and nothing after it', () {
      expect(saidOf(const FormatException('file is not a database')),
          ['Error: FormatException: file is not a database']);
      expect(saidOf(SSHAuthFailError('All authentication methods failed')),
          ['Error: SSHAuthFailError(All authentication methods failed)']);
      expect(saidOf(Exception('no')), ['Error: Exception: no']);
    });

    test('an error whose text does not say what it is: the name of its type, on a line of its own after it', () {
      expect(saidOf(const OrchardServerException(403, 'forbidden')),
          ['Error: Orchards: HTTP 403 forbidden', 'Error type: OrchardServerException']);
      expect(saidOf(StateError('the queue is closed')),
          ['Error: Bad state: the queue is closed', 'Error type: StateError']);
      expect(saidOf(jump(JumpStage.reach, 'no answer')),
          ['Error: Jump host gateway (reach): no answer', 'Error type: JumpHostFailure']);
    });

    test('after everything the error says, where it says it in several lines', () {
      expect(saidOf(StateError('first\nsecond')), ['Error: Bad state: first', '  second', 'Error type: StateError']);
    });

    test('a text that was given as the error has no type, and neither has a thing that is no error', () {
      expect(saidOf('Bad state: the queue is closed'), ['Error: Bad state: the queue is closed']);
      expect(saidOf(404), ['Error: 404']);
      expect(saidOf(null), isEmpty);
    });

    test('an error that prints nothing is still named', () {
      expect(saidOf(_Silent()), ['Error type: Exception']);
    });
  });

  group('A sign-in that was cut off', () {
    const closed = 'Connection closed before authentication';

    test('says what cut it off, on a line of its own behind the error', () {
      final group = SSHKexGroupError('The server named a group of 1024 bits', bits: 1024, shortestTaken: 2048);
      expect(saidOf(SSHAuthAbortError(closed, group)), [
        'Error: SSHAuthAbortError($closed)',
        '  What cut it off: SSHKexGroupError(The server named a group of 1024 bits)',
      ]);
      expect(
        saidOf(SSHAuthAbortError(closed, SSHSocketError(const SocketException('Connection reset by peer')))),
        [
          'Error: SSHAuthAbortError($closed)',
          '  What cut it off: SSHSocketError(SocketException: Connection reset by peer)',
        ],
      );
    });

    test('also where it was a jump host on the way that was being signed in to, which is named by its type then',
        () {
      final cut = SSHAuthAbortError(closed, SSHHandshakeError('No matching cipher algorithm'));
      expect(saidOf(jump(JumpStage.signIn, cut)), [
        'Error: Jump host gateway (signIn): SSHAuthAbortError($closed)',
        '  What cut it off: SSHHandshakeError(No matching cipher algorithm)',
        'Error type: JumpHostFailure',
      ]);
    });

    test('one that nothing is known to have cut off has no such line, and neither has another kind of error', () {
      expect(saidOf(SSHAuthAbortError(closed)), ['Error: SSHAuthAbortError($closed)']);
      expect(saidOf(SSHAuthFailError('All authentication methods failed')).join('\n'),
          isNot(contains('What cut it off')));
      expect(saidOf(jump(JumpStage.reach, const SocketException('refused'))).join('\n'),
          isNot(contains('What cut it off')));
    });

    test('what cut it off is scrubbed as the rest of the report is', () {
      Redactor.instance.registerNames(['web-01']);
      final said = saidOf(SSHAuthAbortError(
        closed,
        SSHSocketError(SocketException('Connection reset by web-01', address: InternetAddress('10.50.0.11'), port: 22)),
      ));
      expect(said, hasLength(2));
      expect(said[1], startsWith('  What cut it off: SSHSocketError(SocketException: Connection reset by '));
      for (final leak in ['web-01', '10.50.0.11']) {
        expect(said.join('\n'), isNot(contains(leak)), reason: leak);
      }
      // And so is the error it stands under: the name of a jump host, here.
      Redactor.instance.registerNames(['gateway']);
      final behind = saidOf(jump(JumpStage.signIn, SSHAuthAbortError(closed, SSHHandshakeError('No matching MAC'))));
      expect(behind, hasLength(3));
      expect(behind[1], '  What cut it off: SSHHandshakeError(No matching MAC)');
      expect(behind.join('\n'), isNot(contains('gateway')));
    });

    test('what cut it off in several lines stays under the error', () {
      final said = saidOf(SSHAuthAbortError(closed, SSHHandshakeError('first\nsecond')));
      expect(said, ['Error: SSHAuthAbortError($closed)', '  What cut it off: SSHHandshakeError(first', '  second)']);
    });
  });
}

class _Silent implements Exception {
  @override
  String toString() => '';
}
