import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/automation_service.dart';

/// How a command that a task ran came out, from how it ended (3.0, from
/// the SSH core's audit). A command with no exit status counted as one that
/// succeeded whatever had happened to it: a task whose command a signal
/// ended, or whose connection dropped half way, was recorded as done.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  const took = Duration(milliseconds: 120);

  /// What the SSH library says ended a connection that was closed with
  /// nothing more said of it.
  final closed = SSHStateError('Connection closed before the request was answered');

  AutomationResult result({
    int? exitCode,
    String? signal,
    Object? cutOffBy,
    bool stillRunning = false,
    String stdout = '',
    String stderr = '',
    AppLocalizations? l10n,
  }) =>
      commandResult(
        l10n ?? en,
        stdout: stdout,
        stderr: stderr,
        exitCode: exitCode,
        signal: signal,
        cutOffBy: cutOffBy,
        stillRunning: stillRunning,
        elapsed: took,
      );

  test('with an exit status, the status says, and what the command printed is kept as it came', () {
    final done = result(exitCode: 0, stdout: 'built\n', stderr: 'warning: slow\n');
    expect(done.success, isTrue);
    expect(done.exitCode, 0);
    expect(done.output, 'built\n');
    expect(done.error, 'warning: slow\n');
    expect(done.elapsed, took);

    for (final status in [1, 3, 127, 255]) {
      final failed = result(exitCode: status, stdout: 'half\n', stderr: 'no such file\n');
      expect(failed.success, isFalse, reason: '$status');
      expect(failed.exitCode, status);
      expect(failed.output, 'half\n');
      expect(failed.error, 'no such file\n');
    }
    // The status says, whatever else is told with it.
    expect(result(exitCode: 0, signal: 'TERM', cutOffBy: closed).success, isTrue);
    expect(result(exitCode: 0, signal: 'TERM', cutOffBy: closed).error, '');
    expect(result(exitCode: 2, cutOffBy: closed).error, '');
  });

  test('ended by a signal: no success, and it says which, behind what the command printed as errors', () {
    final killed = result(signal: 'TERM', stdout: 'started\n');
    expect(killed.success, isFalse);
    expect(killed.exitCode, isNull);
    expect(killed.output, 'started\n');
    expect(killed.error, 'The command was ended by a signal (TERM) before it finished.');

    expect(result(signal: 'KILL', stderr: 'Killed\n').error,
        'Killed\nThe command was ended by a signal (KILL) before it finished.');
    expect(result(signal: 'KILL', stderr: ' \n').error, 'The command was ended by a signal (KILL) before it finished.');
    // The name is the host's to write: shown as text and nothing else.
    final esc = String.fromCharCode(0x1b);
    expect(result(signal: 'TE$esc[2JRM\r\n').error, 'The command was ended by a signal (TE [2JRM) before it finished.');
    // A signal says more than that the connection ended as well.
    expect(result(signal: 'HUP', cutOffBy: closed).error, 'The command was ended by a signal (HUP) before it finished.');
  });

  test('its connection ended under it: no success, and it says so, with why where the host said', () {
    const sentence = 'The connection ended before the command did, so it is not known how the command ended.';
    final cut = result(cutOffBy: closed, stdout: 'half way\n', stderr: 'warn\n');
    expect(cut.success, isFalse);
    expect(cut.exitCode, isNull);
    expect(cut.output, 'half way\n');
    expect(cut.error, 'warn\n$sentence');
    expect(result(cutOffBy: closed).error, sentence);

    // The host ended the connection itself, and said why.
    final ended = SSHDisconnectError(11, 'Idle timeout', authentic: true);
    expect(result(cutOffBy: ended).error, '$sentence\nThe host ended the connection. Its reason: Idle timeout');
    expect(result(cutOffBy: ended, stderr: 'warn\n').error,
        'warn\n$sentence\nThe host ended the connection. Its reason: Idle timeout');
    // Anything else that ended it is not put into words here.
    final reset = SSHSocketError(const SocketException('Connection reset by peer'));
    expect(result(cutOffBy: reset).success, isFalse);
    expect(result(cutOffBy: reset).error, sentence);
    expect(result(cutOffBy: SSHDisconnectError(11, '', authentic: true)).error, sentence);
  });

  test('not ended when the time allowed for it was up: no success, and it says so, with what it had printed', () {
    const sentence = 'The command had not ended when the time allowed for it was up.';
    final running = result(stillRunning: true, stdout: 'step 1\n', stderr: 'slow\n');
    expect(running.success, isFalse);
    expect(running.exitCode, isNull);
    expect(running.output, 'step 1\n');
    expect(running.error, 'slow\n$sentence');
    expect(result(stillRunning: true).error, sentence);
    // What is known of its end says more.
    expect(result(stillRunning: true, exitCode: 0).success, isTrue);
    expect(result(stillRunning: true, signal: 'TERM').error, isNot(contains(sentence)));
    expect(result(stillRunning: true, cutOffBy: closed).error, isNot(contains(sentence)));
  });

  test('no exit status on a connection that stands (a host that reports none): taken to have run, as before', () {
    final quiet = result(stdout: 'show version\n', stderr: 'note\n');
    expect(quiet.success, isTrue);
    expect(quiet.exitCode, isNull);
    expect(quiet.output, 'show version\n');
    expect(quiet.error, 'note\n');
  });

  test('in every language the app speaks', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      final killed = result(signal: 'TERM', l10n: l10n).error;
      final cut = result(cutOffBy: closed, l10n: l10n).error;
      final running = result(stillRunning: true, l10n: l10n).error;
      expect({killed, cut, running}, hasLength(3), reason: '$locale');
      expect(killed, contains('TERM'), reason: '$locale');
      expect(killed, isNot(cut), reason: '$locale');
      if (locale.languageCode == 'en') continue;
      expect(killed, isNot(result(signal: 'TERM').error), reason: '$locale');
      expect(cut, isNot(result(cutOffBy: closed).error), reason: '$locale');
      expect(running, isNot(result(stillRunning: true).error), reason: '$locale');
    }
  });

  test('what is said of a command whose time was up before it ran, in every language, with how long that was', () {
    const allowed = Duration(seconds: 45);
    expect(timeUpBeforeItRan(en, TaskStage.connecting, allowed),
        'No connection to the host had been made when the time allowed was up (45s).');
    expect(timeUpBeforeItRan(en, TaskStage.signingIn, allowed),
        'The sign-in had not finished when the time allowed was up (45s).');
    expect(timeUpBeforeItRan(en, TaskStage.starting, allowed),
        'The host had not started the command when the time allowed was up (45s).');
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      final each = [
        for (final stage in [TaskStage.connecting, TaskStage.signingIn, TaskStage.starting])
          timeUpBeforeItRan(l, stage, allowed),
      ];
      expect(each.toSet(), hasLength(3), reason: '$locale: each its own');
      for (final said in each) {
        expect(said, contains(l.autoWizTimeoutSeconds(45)), reason: '$locale');
      }
      final keys = [l.automationSvcHostKeyUnknown, l.automationSvcHostKeyChanged];
      expect(keys.toSet(), hasLength(2), reason: '$locale');
      if (locale.languageCode == 'en') continue;
      for (final (i, stage) in [TaskStage.connecting, TaskStage.signingIn, TaskStage.starting].indexed) {
        expect(each[i], isNot(timeUpBeforeItRan(en, stage, allowed)), reason: '$locale');
      }
      expect(keys[0], isNot(en.automationSvcHostKeyUnknown), reason: '$locale');
      expect(keys[1], isNot(en.automationSvcHostKeyChanged), reason: '$locale');
    }
  });

  test('what is said of a command that could not be run: the sentence a session is given, and under it what was '
      'thrown where the sentence says no more than that something unexpected happened', () {
    expect(couldNotRunText(const SocketException('Connection refused'), host: 'web-01', port: 2222),
        'web-01 is not accepting connections on port 2222.');
    expect(couldNotRunText(TimeoutException('Connection timed out'), host: 'web-01', port: 22),
        en.errTimeoutDesc('web-01'));
    final odd = StateError('nothing anybody expected');
    expect(couldNotRunText(odd, host: 'web-01', port: 22), '${en.errUnknownDesc('web-01')}\n$odd');
    final protocol = SSHHandshakeError('no matching cipher');
    expect(couldNotRunText(protocol, host: 'web-01', port: 22), '${en.errSshProtocolDesc('web-01')}\n$protocol');
  });
}
