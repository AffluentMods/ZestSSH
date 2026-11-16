import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/models/os_kind.dart';
import 'package:zestssh/services/os_detection_service.dart';
import 'package:zestssh/services/server_stats_service.dart';
import 'package:zestssh/services/ssh_service.dart';

/// "Forward agent" turned on for a host, on a real OpenSSH server.
///
/// On a server that allows agent forwarding, the session started and
/// everything that ran a command on the connection after it failed: the
/// server sets the agent up once for a connection and says no to setting it
/// up again, and the SSH core gave a session up for that no. So with the
/// switch on, the host's system was never found out, and Server Monitor's
/// own connection got its first figure and none after.
///
/// On a server that allows none (`AllowAgentForwarding no`, or a key marked
/// `no-agent-forwarding`), the app could not connect at all.
///
/// The server is the WSL test sshd on 127.0.0.1:2299 (tool/test_sshd.sh
/// starts it and makes the keys); `client_noagent_ed25519` is the key it
/// gives everything but agent forwarding. Skips itself when the server is
/// not running. Override the location with ZESTSSH_TEST_SSHD_HOST / _PORT /
/// _USER / _DIR.
void main() {
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  const refusedLine = 'ssh_agent: The host refused agent forwarding - the session goes on without it';
  late bool up;
  SSHKeyPair? noAgent;
  SSHKeyPair? free;
  final services = <SshService>[];

  setUpAll(() async {
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      s.destroy();
      final noAgentFile = File('$dir/client_noagent_ed25519');
      final freeFile = File('$dir/client_ed25519');
      up = noAgentFile.existsSync() && freeFile.existsSync();
      if (up) {
        noAgent = SSHKeyPair.fromPem(noAgentFile.readAsStringSync()).single;
        free = SSHKeyPair.fromPem(freeFile.readAsStringSync()).single;
      }
    } catch (_) {
      up = false;
    }
  });

  tearDown(() async {
    for (final service in services) {
      await service.disconnect();
    }
    services.clear();
  });

  SshService service(SSHKeyPair key, {required bool forwardAgent, List<String>? log}) {
    final ssh = SshService(
      host: host,
      port: port,
      username: user,
      keyPairs: [key],
      forwardAgent: forwardAgent,
      onHostKeyVerify: (_, _, _) async => true,
      onLog: log?.add,
    );
    services.add(ssh);
    return ssh;
  }

  /// What the shell of [ssh] says once [line] is typed into it, up to [mark].
  Future<String> typed(SshService ssh, String line, String mark) async {
    final said = StringBuffer();
    final seen = Completer<void>();
    final sub = ssh.stdout.listen((data) {
      said.write(utf8.decode(data, allowMalformed: true));
      if (!seen.isCompleted && said.toString().contains(mark)) seen.complete();
    });
    ssh.write(Uint8List.fromList(utf8.encode('$line\r')));
    await seen.future.timeout(const Duration(seconds: 15));
    await sub.cancel();
    return said.toString();
  }

  Future<String> run(SshService ssh, String command) async =>
      utf8.decode(await ssh.client.run(command).timeout(const Duration(seconds: 15))).trim();

  test('on for a host that allows it: the session, and every command on the connection after it', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    final log = <String>[];
    final ssh = service(free!, forwardAgent: true, log: log);
    await ssh.connect().timeout(const Duration(seconds: 20));
    expect(ssh.isConnected, isTrue);
    // The agent is there in the terminal: the server's own tool asks it what it holds.
    expect(await typed(ssh, 'ssh-add -l', 'ED25519'), contains('ED25519'));
    // And what runs beside the terminal runs (each of these failed).
    expect(await run(ssh, 'echo beside-the-terminal'), 'beside-the-terminal');
    expect(await run(ssh, 'ssh-add -l'), contains('ED25519'));
    expect(await OsDetectionService.detect(ssh.client), isNot(OsKind.unknown), reason: 'the host\'s system is found out');
    expect(ssh.agentForwardingRefused, isFalse, reason: 'a no to setting the agent up twice is no refusal');
    expect(log, isNot(contains(refusedLine)));
  });

  test('on for a connection that only runs commands, as Server Monitor\'s is: every figure is read, time after time',
      () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    final ssh = service(free!, forwardAgent: true);
    await ssh.connectExec().timeout(const Duration(seconds: 20));
    for (var reading = 1; reading <= 2; reading++) {
      final stats = await ServerStatsService.getStats(ssh.client).timeout(const Duration(seconds: 40));
      expect(stats.cpuPercent, isNotNull, reason: 'reading $reading');
      expect(stats.ramTotalMB, greaterThan(100), reason: 'reading $reading');
      expect(stats.diskPercent, isNotNull, reason: 'reading $reading');
      expect(stats.uptimeSeconds, greaterThan(0), reason: 'reading $reading');
      expect(stats.kernel, await run(ssh, 'uname -r'), reason: 'reading $reading');
      ServerStatsService.clearCache(ssh.client);
    }
    expect(ssh.agentForwardingRefused, isFalse);
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('on for a host that refuses it: the connection is made all the same, and its log says what the host did',
      () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    final log = <String>[];
    final ssh = service(noAgent!, forwardAgent: true, log: log);
    await ssh.connect().timeout(const Duration(seconds: 20));
    expect(ssh.isConnected, isTrue);
    expect(ssh.agentForwardingRefused, isTrue);
    expect(log.where((line) => line == refusedLine), hasLength(1));
    // (The mark is put together by the shell, so that it is not found in the echo of what was typed.)
    expect(await typed(ssh, 'echo still-"here"', 'still-here'), contains('still-here'));
    // No agent is there, in the terminal or beside it; commands run.
    expect(await run(ssh, 'echo "[\$SSH_AUTH_SOCK]"'), '[]');
    expect(await OsDetectionService.detect(ssh.client), isNot(OsKind.unknown));
    expect(log.where((line) => line == refusedLine), hasLength(1), reason: 'said once for the connection');
  });

  test('off: nothing is asked of either host, and nothing is said', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    for (final key in [free!, noAgent!]) {
      final log = <String>[];
      final ssh = service(key, forwardAgent: false, log: log);
      await ssh.connect().timeout(const Duration(seconds: 20));
      expect(await run(ssh, 'echo "[\$SSH_AUTH_SOCK]"'), '[]');
      expect(ssh.agentForwardingRefused, isFalse);
      expect(log, isNot(contains(refusedLine)));
    }
  });
}
