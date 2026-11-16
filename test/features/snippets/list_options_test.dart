// A snippet's list of the host's own ($[DOCKER], $[TMUX]) is read on the
// session the snippet goes to, on every device (found while
// comparing the five versions): a computer's palette, Inspector and library
// had nothing to read it with, and said there was no session.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/features/snippets/run_snippet.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';

class _Shell extends ShellService {
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<Uint8List> get stdout => const Stream.empty();
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  void write(Uint8List data) {}
  @override
  void resize(int width, int height) {}
  @override
  bool get isConnected => true;
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  bool get exitedCleanly => false;
}

/// A shell that runs one command beside it: an SSH session's.
class _OneOffShell extends _Shell implements ShellOneOff {
  final asked = <String>[];

  @override
  Future<String?> runOnce(String command, {Duration timeout = const Duration(seconds: 10)}) async {
    asked.add(command);
    return 'web';
  }
}

SessionState _session(ShellService shell) => SessionState(
      status: SessionStatus.connected,
      connectionId: 'c1',
      connectionLabel: 'web-01',
      host: '192.0.2.21',
      port: 22,
      username: 'deploy',
      session: TerminalSession(
        id: 's1',
        connectionId: 'c1',
        terminal: Terminal(),
        shell: shell,
        startedAt: DateTime(2026, 10, 16),
      ),
    );

void main() {
  test('read on a session whose shell can run a command beside it; on no other, nor with no session', () async {
    final shell = _OneOffShell();
    final read = listOptionsFrom(_session(shell));
    expect(read, isNotNull);
    expect(await read!("docker ps --format '{{.Names}}'"), 'web');
    expect(shell.asked, ["docker ps --format '{{.Names}}'"]);
    expect(listOptionsFrom(_session(_Shell())), isNull, reason: 'a shell that cannot (a local one, Telnet)');
    expect(listOptionsFrom(SessionState.connecting('c1', connectionLabel: 'web-01')), isNull, reason: 'not open yet');
    expect(listOptionsFrom(null), isNull);
  });

  test("a computer's palette and a phone's terminal read it on the session the snippet goes to", () {
    final palette = File('lib/ui/widgets/command_palette.dart').readAsStringSync();
    expect(palette, contains('listOptions: listOptionsFrom(session)'));
    final phone = File('lib/ui/screens/terminal/terminal_screen.dart').readAsStringSync();
    expect(phone, contains('executeCommand: listOptionsFrom(sessionState),'));
  });
}
