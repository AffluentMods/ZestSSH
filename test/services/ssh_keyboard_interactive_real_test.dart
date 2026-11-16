import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/ssh_auth_prompts.dart';
import 'package:zestssh/services/ssh_service.dart';

/// Keyboard-interactive (2FA) sign-in against a real SSH server.
///
/// Talks to the scripted server in tool/ssh_test_servers/kbdint_sshd.py
/// (python tool/ssh_test_servers/kbdint_sshd.py) and skips itself when it is
/// not running. Override its port and log with ZESTSSH_TEST_KBDINT_PORT and
/// ZESTSSH_TEST_KBDINT_LOG. The server logs every answer it receives, so
/// these tests check what actually reached it, not only what the app meant
/// to send.
void main() {
  final port =
      int.parse(Platform.environment['ZESTSSH_TEST_KBDINT_PORT'] ?? '2298');
  final logFile = File(Platform.environment['ZESTSSH_TEST_KBDINT_LOG'] ??
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'kbdint-sshd.jsonl');

  var serverUp = false;
  setUpAll(() async {
    try {
      final s = await Socket.connect('127.0.0.1', port,
          timeout: const Duration(seconds: 1));
      s.destroy();
      serverUp = true;
    } catch (_) {
      serverUp = false;
    }
  });

  setUp(() {
    if (logFile.existsSync()) logFile.writeAsStringSync('');
  });

  /// What the server received for [user], in order.
  List<List<String>> received(String user) => [
        for (final line in logFile.existsSync()
            ? logFile.readAsLinesSync()
            : const <String>[])
          if (line.trim().isNotEmpty)
            if (jsonDecode(line) case {'user': final String u, 'responses': final List r}
                when u == user)
              r.cast<String>(),
      ];

  SshService service(
    String user, {
    String? password,
    ServerQuestionAsker? ask,
    List<SSHKeyPair>? keys,
  }) =>
      SshService(
        host: '127.0.0.1',
        port: port,
        username: user,
        password: password,
        keyPairs: keys,
        onHostKeyVerify: (_, _, _) async => true,
        onServerQuestion: ask,
      );

  String skip() => 'kbdint test server not running on 127.0.0.1:$port';

  test('password then code: the saved password answers the password prompt '
      'and the person answers the code', () async {
    if (!serverUp) return markTestSkipped(skip());
    final asked = <ServerQuestion>[];
    final s = service('pwotp', password: 'pw', ask: (q) async {
      asked.add(q);
      return ['123456'];
    });
    await s.connectExec();
    await s.disconnect();

    expect(asked.map((q) => q.prompts.map((p) => p.text).toList()), [
      ['Verification code:']
    ]);
    expect(asked.single.prompts.single.echo, isFalse);
    expect(received('pwotp'), [
      ['pw'],
      ['123456'],
    ]);
  });

  test('nobody watching: the code is answered empty and the password never '
      'reaches the code prompt', () async {
    if (!serverUp) return markTestSkipped(skip());
    final s = service('pwotp', password: 'pw');
    await expectLater(s.connectExec(), throwsA(isA<SSHAuthError>()));
    final got = received('pwotp');
    expect(got.first, ['pw']);
    expect(got[1], [''], reason: 'the code prompt got nothing');
    expect(got.skip(1).expand((r) => r), isNot(contains('pw')));
  });

  test('cancelling the code ends the sign-in as a cancel', () async {
    if (!serverUp) return markTestSkipped(skip());
    final s = service('pwotp', password: 'pw', ask: (_) async => null);
    await expectLater(s.connectExec(), throwsA(isA<SshPromptCancelled>()));
    expect(received('pwotp'), [
      ['pw']
    ], reason: 'nothing was sent for the code');
  });

  test('both questions in one round: only the code goes to the person',
      () async {
    if (!serverUp) return markTestSkipped(skip());
    final asked = <ServerQuestion>[];
    final s = service('both', password: 'pw', ask: (q) async {
      asked.add(q);
      return ['123456'];
    });
    await s.connectExec();
    await s.disconnect();
    expect(asked.single.prompts.map((p) => p.text), ['Verification code:']);
    expect(received('both'), [
      ['pw', '123456']
    ]);
  });

  test('key then code: keyboard-interactive is offered with no saved '
      'password because someone can answer', () async {
    if (!serverUp) return markTestSkipped(skip());
    final key = SSHKeyPair.fromPem(File(
            'packages/zest_ssh_core/test/fixtures/ssh-ed25519/id_ed25519')
        .readAsStringSync());
    final s = service('keyotp', keys: key, ask: (_) async => ['123456']);
    await s.connectExec();
    await s.disconnect();
    expect(received('keyotp'), [
      ['123456']
    ]);
  });

  test('a push approval: a message, then 20 s of silence, still signs in',
      () async {
    if (!serverUp) return markTestSkipped(skip());
    var asked = 0;
    final s = service('push', ask: (_) async {
      asked++;
      return const [];
    });
    await s.connectExec();
    await s.disconnect();
    expect(asked, 0, reason: 'a message alone is not a question');
    expect(received('push'), [<String>[]]);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a wrong saved password is sent once, then the person is asked',
      () async {
    if (!serverUp) return markTestSkipped(skip());
    final asked = <ServerQuestion>[];
    final s = service('retry', password: 'wrong', ask: (q) async {
      asked.add(q);
      return ['pw'];
    });
    await s.connectExec();
    await s.disconnect();
    expect(received('retry'), [
      ['wrong'],
      ['pw'],
    ]);
    expect(asked.single.instruction, 'Wrong password, try again.');
    expect(asked.single.round, 2);
  });

  test('an echoed menu prompt is shown as visible text', () async {
    if (!serverUp) return markTestSkipped(skip());
    final asked = <ServerQuestion>[];
    final s = service('echo', ask: (q) async {
      asked.add(q);
      return ['1'];
    });
    await s.connectExec();
    await s.disconnect();
    expect(asked.single.prompts.single.echo, isTrue);
    expect(asked.single.instruction, 'Choose 1 for a push or 2 for a call.');
  });
}
