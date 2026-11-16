import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/ssh_service.dart';

/// How long a round trip takes on a session's own connection, on a REAL
/// OpenSSH server (the WSL test sshd on 127.0.0.1:2299; the test skips
/// itself when it is not running; ZESTSSH_TEST_SSHD_HOST / _PORT / _USER /
/// _DIR say where it is).
///
/// What it is for (a reported case): the latency shown for
/// a session's host was the time a separate connection to the host's SSH
/// port took, opened every 20 seconds and closed without signing in. It is
/// timed on the session itself now, and nothing connects for it.
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

  SessionState sessionOf(ShellService shell) => SessionState.connected(
        TerminalSession(id: 's1', connectionId: 'web', terminal: Terminal(), shell: shell, startedAt: DateTime(2026, 10, 9)),
      );

  test('a session\'s round trip is timed on its own connection, with nothing connecting for it; once its '
      'connection is gone there is none', () async {
    if (!up) return markTestSkipped('no test sshd at $host:$port');
    final ssh = SshService(
      host: host,
      port: port,
      username: user,
      keyPairs: [key!],
      onHostKeyVerify: (_, _, _) async => true,
    );
    await ssh.connect();
    addTearDown(ssh.disconnect);
    final session = sessionOf(ssh);

    final dialled = <String>[];
    final ms = await IOOverrides.runZoned(
      () => sshSessionRoundTrip(session),
      socketConnect: (address, port, {sourceAddress, int sourcePort = 0, Duration? timeout}) {
        dialled.add('$address:$port');
        throw const SocketException('a round trip connects nowhere');
      },
      socketStartConnect: (address, port, {sourceAddress, int sourcePort = 0}) {
        dialled.add('$address:$port');
        throw const SocketException('a round trip connects nowhere');
      },
    );
    expect(dialled, isEmpty);
    expect(ms, inInclusiveRange(0, 2000), reason: 'a host on this machine');
    // Asked again and again, the session is as good as before.
    for (var i = 0; i < 5; i++) {
      expect(await sshSessionRoundTrip(session), isNotNull);
    }
    expect(ssh.isConnected, isTrue);

    await ssh.disconnect();
    final asked = Stopwatch()..start();
    expect(await sshSessionRoundTrip(session), isNull);
    expect(asked.elapsed, lessThan(const Duration(seconds: 1)), reason: 'not asked, and not waited for');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a session that is not an SSH session, or has no connection yet, has none to time', () async {
    expect(await sshSessionRoundTrip(const SessionState(status: SessionStatus.connected, connectionId: 'web')), isNull,
        reason: 'no session behind it');
    expect(await sshSessionRoundTrip(sessionOf(_OtherShell())), isNull, reason: 'telnet, a serial port, a local shell');
    // An SSH session that never connected.
    final never = SshService(host: host, port: port, username: 'deploy', onHostKeyVerify: (_, _, _) async => true);
    expect(await sshSessionRoundTrip(sessionOf(never)), isNull);
  });
}

/// A shell that is connected and is no SSH session.
class _OtherShell extends ShellService {
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
