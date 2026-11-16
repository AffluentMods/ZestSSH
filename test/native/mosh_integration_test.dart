import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/mosh.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/mosh/builtin_mosh_service.dart';
import 'package:zestssh/services/mosh/mosh_bootstrap.dart';

/// The built-in Mosh client (4.0) against a real mosh-server, on the path the
/// app takes: mosh-server started over SSH (startMoshServer through an SSH
/// exec channel), the Rust client (RustMoshNative, the library the build hook
/// made), the session's terminal output and typing through
/// BuiltinMoshService.
///
/// The SSH server is the WSL test sshd on 127.0.0.1:2299 (tool/test_sshd.sh)
/// with its client key; mosh-server must be installed in WSL (`sudo apt
/// install mosh`). WSL forwards TCP from 127.0.0.1 and not UDP, so mosh-server
/// is started unbound (as through a jump host) and UDP goes to WSL's own
/// address (`wsl hostname -I`, or ZESTSSH_TEST_MOSH_UDP_HOST). Elsewhere (a
/// Linux machine running the servers itself) UDP goes to 127.0.0.1. Skips
/// itself when any of that is missing.
void main() {
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  String? skip;
  SSHKeyPair? key;
  String? udpHost;

  setUpAll(() async {
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      s.destroy();
    } catch (_) {
      skip = 'the test sshd on $host:$port is not running (tool/test_sshd.sh)';
      return;
    }
    final file = File('$dir/client_ed25519');
    if (!file.existsSync()) {
      skip = 'no client key at ${file.path}';
      return;
    }
    key = SSHKeyPair.fromPem(file.readAsStringSync()).single;
    udpHost = env['ZESTSSH_TEST_MOSH_UDP_HOST'];
    if (udpHost == null && Platform.isWindows) {
      final r = await Process.run('wsl.exe', ['-d', 'Ubuntu', '--', 'hostname', '-I']);
      final words = '${r.stdout}'.trim().split(RegExp(r'\s+'));
      udpHost = words.isEmpty || words.first.isEmpty ? null : words.first;
    }
    udpHost ??= '127.0.0.1';
  });

  /// mosh-server started over the test sshd, as the app starts it.
  Future<MoshServerReady> bootstrap({List<String>? addresses}) async {
    final client = SSHClient(await SSHSocket.connect(host, port), username: user, identities: [key!]);
    try {
      await client.authenticated;
      final start = await startMoshServer((command) async {
        final session = await client.execute(command);
        return collectMoshCommand(
          stdout: session.stdout,
          stderr: session.stderr,
          done: session.done,
          exitCode: () => session.exitCode,
        );
      }, bindToSsh: false);
      return (start: start, addresses: addresses ?? [udpHost!]);
    } finally {
      client.close();
    }
  }

  Future<bool> moshServerThere() async {
    final client = SSHClient(await SSHSocket.connect(host, port), username: user, identities: [key!]);
    try {
      await client.authenticated;
      final r = await client.runWithResult('command -v mosh-server');
      return r.exitCode == 0;
    } finally {
      client.close();
    }
  }

  test('a shell on the host through mosh-server: output, typing, the size, and the end', () async {
    if (skip != null) return markTestSkipped(skip!);
    if (!await moshServerThere()) return markTestSkipped('mosh-server is not installed on the test host');
    final m = BuiltinMoshService(bootstrap: bootstrap, native: RustMoshNative());
    final out = StringBuffer();
    m.stdout.listen((b) => out.write(utf8.decode(b, allowMalformed: true)));
    m.resize(97, 31);
    await m.connect();
    expect(m.isConnected, isTrue);
    Future<void> until(String text) async {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (!out.toString().contains(text)) {
        if (DateTime.now().isAfter(deadline)) fail('"$text" never came; got: ${jsonEncode(out.toString())}');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    m.write(Uint8List.fromList(utf8.encode('echo zest-\$((6*7))\r')));
    await until('zest-42');
    m.write(Uint8List.fromList(utf8.encode('stty size\r')));
    await until('31 97');
    m.resize(120, 40);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    m.write(Uint8List.fromList(utf8.encode('stty size\r')));
    await until('40 120');
    expect(m.moshLink.value.quiet, isFalse);
    final states = <bool>[];
    m.connectionState.listen(states.add);
    m.write(Uint8List.fromList(utf8.encode('exit\r')));
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (m.isConnected && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(m.isConnected, isFalse, reason: 'the shell ended, and the session with it');
    expect(m.exitedCleanly, isTrue);
    expect(states, [false]);
    await m.disconnect();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('closing the session ends mosh-server on the host', () async {
    if (skip != null) return markTestSkipped(skip!);
    if (!await moshServerThere()) return markTestSkipped('mosh-server is not installed on the test host');
    final m = BuiltinMoshService(bootstrap: bootstrap, native: RustMoshNative());
    await m.connect();
    final started = DateTime.now();
    await m.disconnect();
    expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 2)),
        reason: 'the server acknowledged the close');
    expect(m.exitedCleanly, isTrue);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('nothing answering over UDP is ZS-1007, with the port', () async {
    if (skip != null) return markTestSkipped(skip!);
    if (!await moshServerThere()) return markTestSkipped('mosh-server is not installed on the test host');
    // An address nothing answers on (TEST-NET-1): mosh-server waits in vain and ends by itself after 60 s.
    final m = BuiltinMoshService(
      bootstrap: () => bootstrap(addresses: ['192.0.2.1']),
      native: RustMoshNative(),
      firstAnswer: const Duration(seconds: 2),
    );
    try {
      await m.connect();
      fail('connected to nothing');
    } on MoshSessionFailure catch (e) {
      expect(e.problem, MoshSessionProblem.noAnswer);
      expect(e.port, inInclusiveRange(60000, 61000));
      expect(e.detail, contains('UDP port ${e.port}'));
    }
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('the SSH socket says the address it reached: where a direct Mosh session sends its UDP', () async {
    if (skip != null) return markTestSkipped(skip!);
    final socket = await SSHSocket.connect(host, port);
    try {
      expect(socket, isA<SSHSocketPeer>());
      expect((socket as SSHSocketPeer).remoteAddress, anyOf('127.0.0.1', '::1'));
    } finally {
      socket.destroy();
    }
  });

  test('the library has the Mosh client', () {
    // Any call loads it; a handle of 0 for a request that is no request.
    expect(RustMoshNative().open('not json', (_, _, _) {}), 0);
  });
}
