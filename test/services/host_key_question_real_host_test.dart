import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/serial_service.dart';
import 'package:zestssh/services/ssh_auth_prompts.dart';
import 'package:zestssh/services/ssh_service.dart';

/// The question about a host's key against the time a sign-in is given, on
/// a REAL OpenSSH server (the WSL test sshd on 127.0.0.1:2299; the tests
/// skip themselves when it is not running; ZESTSSH_TEST_SSHD_HOST / _PORT /
/// _USER / _DIR say where it is).
///
/// What it is for (found through a reported case): a server
/// is given 15 seconds to answer during sign-in, and that clock ran while
/// the person was asked whether to trust the host's key. Whoever read the
/// fingerprint for longer got "Authentication timed out", and the host got
/// a connection that ended before sign-in, which it logs and may ban an
/// address for. The clock stops for the question now, as it did for a
/// server's own questions.
void main() {
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  late bool up;
  SSHKeyPair? key;

  setUpAll(() async {
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      s.destroy();
      final file = File('$dir/client_ed25519');
      up = file.existsSync();
      if (up) key = SSHKeyPair.fromPem(file.readAsStringSync()).single;
    } catch (_) {
      up = false;
    }
  });

  tearDown(() => AuthDeadline.debugPatience = null);

  /// A session whose person takes [answerAfter] to answer the question
  /// about the host's key.
  SshService session({required Duration answerAfter, bool trust = true}) => SshService(
        host: host,
        port: port,
        username: user,
        keyPairs: [key!],
        onHostKeyVerify: (_, _, _) async {
          await Future<void>.delayed(answerAfter);
          return trust;
        },
      );

  test('a person who takes longer over the host\'s key than a server is given to answer is signed in all the same',
      () async {
    if (!up) return markTestSkipped('no test sshd at $host:$port');
    // The server gets one second; the person takes three.
    AuthDeadline.debugPatience = const Duration(seconds: 1);
    final ssh = session(answerAfter: const Duration(seconds: 3));
    final asked = Stopwatch()..start();
    await ssh.connect();
    expect(ssh.isConnected, isTrue);
    expect(asked.elapsed, greaterThan(const Duration(seconds: 3)), reason: 'the question was waited for');
    await ssh.disconnect();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('the clock still runs for the server: one that does not answer in time is given up on', () async {
    // A listener that takes the connection and says nothing.
    final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final taken = <Socket>[];
    silent.listen(taken.add);
    addTearDown(() async {
      for (final s in taken) {
        s.destroy();
      }
      await silent.close();
    });
    AuthDeadline.debugPatience = const Duration(seconds: 1);
    final ssh = SshService(
      host: '127.0.0.1',
      port: silent.port,
      username: 'deploy',
      onHostKeyVerify: (_, _, _) async => true,
    );
    final waited = Stopwatch()..start();
    await expectLater(ssh.connect(), throwsA(isA<Object>()));
    expect(waited.elapsed, lessThan(const Duration(seconds: 10)));
    expect(ssh.isConnected, isFalse);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('the same for a host a session is reached through (read from its file: no test connects through one)', () {
    final source = File('lib/providers/terminal_providers.dart').readAsStringSync();
    expect(source, contains('return hopDeadline.whileAsking(() => hostKeyVerifier(hop.host, hop.port, sshHostKey, hostId: hop.id));'));
    final own = File('lib/services/ssh_service.dart').readAsStringSync();
    expect(own, contains('await deadline.whileAsking(() => onHostKeyVerify(host, port, sshHostKey));'));
  });

  test('a console server\'s key: the clock stops for the question there too', () async {
    if (!up) return markTestSkipped('no test sshd at $host:$port');
    AuthDeadline.debugPatience = const Duration(seconds: 1);
    final serial = SerialOverSshService(
      host: host,
      port: port,
      username: user,
      keyPairs: [key!],
      serialConfig: const SerialConfig(portName: 'ttyS0'),
      onHostKeyVerify: (_, _, _) async {
        await Future<void>.delayed(const Duration(seconds: 3));
        return true;
      },
    );
    await serial.connect();
    expect(serial.isConnected, isTrue);
    await serial.disconnect();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a check that says why the key was not accepted: the sign-in ends with that very reason, and the log has '
      'it, of a host and of a console server', () async {
    if (!up) return markTestSkipped('no test sshd at $host:$port');
    for (final console in [false, true]) {
      final why = HostKeyNotAccepted(HostKeyRefusal.declinedNew, host: host, port: port);
      final log = <String>[];
      Future<bool> check(String _, int _, SSHHostKey _) async => throw why;
      final ShellService ssh = console
          ? SerialOverSshService(
              host: host,
              port: port,
              username: user,
              keyPairs: [key!],
              serialConfig: const SerialConfig(portName: 'ttyS0'),
              onHostKeyVerify: check,
              onLog: log.add,
            )
          : SshService(host: host, port: port, username: user, keyPairs: [key!], onHostKeyVerify: check, onLog: log.add);
      Object? e;
      try {
        await ssh.connect();
      } catch (error) {
        e = error;
      }
      expect(e, isA<SSHAuthAbortError>(), reason: 'console: $console');
      expect((e! as SSHAuthAbortError).reason, same(why), reason: 'console: $console');
      expect(ssh.isConnected, isFalse);
      expect(log, contains('ssh_hostkey: Host key REJECTED (declinedNew)'), reason: 'console: $console');
      expect(log.where((line) => line.contains('Host key accepted')), isEmpty);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a key its person does not trust ends the sign-in, however long they took', () async {
    if (!up) return markTestSkipped('no test sshd at $host:$port');
    AuthDeadline.debugPatience = const Duration(seconds: 1);
    final ssh = session(answerAfter: const Duration(seconds: 2), trust: false);
    await expectLater(ssh.connect(), throwsA(isA<Object>()));
    expect(ssh.isConnected, isFalse);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
