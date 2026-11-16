import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:zest_ssh_core/dartssh2.dart' show SSHDisconnectError;
import 'package:zestssh/providers/terminal_providers.dart' show endedAtOwnHand, kOwnExitWindow, lastRows;
import 'package:zestssh/services/ssh_service.dart';

/// A shell that ended by itself, and whose doing that was (3.0, from the
/// SSH core's audit). A shell that ends was taken for one its person ended,
/// and its tab was closed at once: an account that prints a notice and
/// leaves was never read, and a session a host ended (a limit on idle
/// time, someone there, a host going down) was just gone. A shell that
/// ended at its person's hand is still closed with its tab; any other
/// stays, with how it ended and what the host said last. These are the
/// parts that decide and that keep what is shown.
void main() {
  test('at its person\'s hand: something was sent into it in the ten seconds before it ended', () {
    final ended = DateTime(2026, 10, 10, 12, 0, 30);
    expect(kOwnExitWindow, const Duration(seconds: 10));
    // Never typed into: an account that prints a notice and leaves.
    expect(endedAtOwnHand(lastInput: null, endedAt: ended), isFalse);
    // `exit` and Enter, and the shell is gone.
    expect(endedAtOwnHand(lastInput: ended, endedAt: ended), isTrue);
    expect(endedAtOwnHand(lastInput: ended.subtract(const Duration(milliseconds: 400)), endedAt: ended), isTrue);
    expect(endedAtOwnHand(lastInput: ended.subtract(const Duration(seconds: 10)), endedAt: ended), isTrue);
    // Typed a while ago, and ended since: a limit on idle time, someone there.
    expect(endedAtOwnHand(lastInput: ended.subtract(const Duration(seconds: 10, milliseconds: 1)), endedAt: ended),
        isFalse);
    expect(endedAtOwnHand(lastInput: ended.subtract(const Duration(minutes: 15)), endedAt: ended), isFalse);
  });

  test('why a session ended, as it keeps it: how the shell ended, and what the host said last', () {
    final withStatus = sessionEndedCause(exitCode: 1, said: 'This account is currently not available.');
    expect(withStatus, 'The host ended the session (exit status 1):\nThis account is currently not available.');
    expect(sessionEnded(withStatus),
        (exitCode: 1, signal: null, said: 'This account is currently not available.'));

    final quiet = sessionEndedCause(exitCode: 0);
    expect(quiet, 'The host ended the session (exit status 0)');
    expect(sessionEnded(quiet), (exitCode: 0, signal: null, said: ''));

    final killed = sessionEndedCause(signal: 'HUP', said: 'Broadcast message from root\nThe system will reboot now!');
    expect(killed, 'The host ended the session (signal HUP):\nBroadcast message from root\nThe system will reboot now!');
    expect(sessionEnded(killed),
        (exitCode: null, signal: 'HUP', said: 'Broadcast message from root\nThe system will reboot now!'));

    // A host that says nothing of how its sessions end.
    final unsaid = sessionEndedCause(said: 'Connection closed.');
    expect(unsaid, 'The host ended the session:\nConnection closed.');
    expect(sessionEnded(unsaid), (exitCode: null, signal: null, said: 'Connection closed.'));
    expect(sessionEnded(sessionEndedCause()), (exitCode: null, signal: null, said: ''));

    // A signal says more than a status that came with it.
    expect(sessionEnded(sessionEndedCause(exitCode: 1, signal: 'TERM')), (exitCode: null, signal: 'TERM', said: ''));
    // What the host said may look like the rest of it: it is what was said.
    final tricky = sessionEndedCause(exitCode: 2, said: 'done (exit status 0):\nfine');
    expect(sessionEnded(tricky), (exitCode: 2, signal: null, said: 'done (exit status 0):\nfine'));
  });

  test('the name of a signal is the host\'s to write: its letters, digits and marks, and nothing else', () {
    final esc = String.fromCharCode(0x1b);
    final cause = sessionEndedCause(signal: 'TE)RM$esc[2J\r\n (exit status 0)');
    expect(cause, 'The host ended the session (signal TERM2Jexitstatus0)');
    expect(sessionEnded(cause)!.signal, 'TERM2Jexitstatus0');
    expect(sessionEnded(sessionEndedCause(signal: 'RTMIN+1'))!.signal, 'RTMIN+1');
    expect(sessionEnded(sessionEndedCause(signal: 'INFO@openssh.com'))!.signal, 'INFO@openssh.com');
  });

  test('what is no such end is none', () {
    for (final other in [
      null,
      '',
      hostClosedConnection,
      hostStoppedAnswering,
      endReasonOf(SSHDisconnectError(11, 'Idle timeout', authentic: true)),
      'the host ended the session',
      'The host ended the session (exit status one)',
      'The host ended the session (exit status 1',
      'The host ended the session (exit code 1)',
      'The host ended the session (exit status 1) and more',
      'The host ended the session: on one line',
      'The host ended the sessions',
    ]) {
      expect(sessionEnded(other), isNull, reason: '$other');
    }
  });

  test('the last a host said: the last six rows that are not empty, each as text and nothing else', () {
    expect(lastWords(const []), '');
    expect(lastWords(const ['', '   ', '']), '');
    expect(lastWords(const ['Hi deploy! You have no shell here.', '', '']), 'Hi deploy! You have no shell here.');
    expect(lastWords(const ['one', '', 'two  ', '   three', '']), 'one\ntwo\nthree');
    expect(lastWords([for (var i = 1; i <= 9; i++) 'row $i', '']), 'row 4\nrow 5\nrow 6\nrow 7\nrow 8\nrow 9');
    expect(lastWords([for (var i = 1; i <= 9; i++) 'row $i'], most: 2), 'row 8\nrow 9');
    // A row is cut as anything a host wrote is, and holds nothing that steers a terminal.
    final bell = String.fromCharCode(0x07);
    expect(lastWords(['ring$bell the bell', 'x' * 300]), 'ring the bell\n${'x' * 197}...');
  });

  test('the rows of a terminal, as they are read back for that', () {
    final terminal = Terminal(maxLines: 1000);
    terminal.write('Last login: Sat Oct 10\r\n');
    terminal.write('Hi deploy! You have successfully authenticated, but this host gives no shell.\r\n');
    final rows = lastRows(terminal).toList();
    expect(lastWords(rows),
        'Last login: Sat Oct 10\nHi deploy! You have successfully authenticated, but this host gives no shell.');
    // Only the last of a long screenful is looked at.
    for (var i = 0; i < 200; i++) {
      terminal.write('line $i\r\n');
    }
    expect(lastRows(terminal, 10).length, 10);
    expect(lastWords(lastRows(terminal)), 'line 194\nline 195\nline 196\nline 197\nline 198\nline 199');
    // What a program drew with colours and moves comes back as the text on screen.
    final esc = String.fromCharCode(0x1b);
    terminal.write('$esc[31mAccess denied$esc[0m for deploy\r\n');
    expect(lastWords(lastRows(terminal), most: 1), 'Access denied for deploy');
  });
}
