import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/models/os_kind.dart';
import 'package:zestssh/services/os_detection_service.dart';

/// A question put to a real OpenSSH server for the app's own use: read so far
/// and for so long, with its channel closed then (from a review of
/// hostile servers). The server is the WSL test sshd on 127.0.0.1:2299, as in
/// command_line_ends_real_shell_test.dart; skips itself when it is not running.
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

  Future<T> withClient<T>(Future<T> Function(SSHClient client) body) async {
    final client = SSHClient(await SSHSocket.connect(host, port), username: user, identities: [key!]);
    try {
      await client.authenticated;
      return await body(client);
    } finally {
      client.close();
      await client.done;
    }
  }

  test('a command that never ends is read to the limit, and then it has ended on the host too', () async {
    if (!up) return markTestSkipped('test sshd not running on $host:$port');
    final mark = 'zest-capped-${Random().nextInt(1 << 32)}';
    await withClient((c) async {
      final answer = await c.runCapped('exec yes $mark', maxBytes: 100000, timeout: const Duration(seconds: 20));
      expect(answer.length, 100000);
      expect(utf8.decode(answer, allowMalformed: true), startsWith('$mark\n'));
      // With the channel closed, it has nowhere to write. (The bracket keeps
      // pgrep from finding its own command line.)
      final pattern = 'yes ${mark.substring(0, 3)}[${mark[3]}]${mark.substring(4)}';
      String left = 'not asked';
      for (var i = 0; i < 100 && left.isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        left = utf8.decode(await c.run("pgrep -f '$pattern' || true")).trim();
      }
      expect(left, isEmpty, reason: 'the program is gone from the host');
    });
  });

  test('a command that says nothing fails at the timeout, and the connection goes on', () async {
    if (!up) return markTestSkipped('test sshd not running on $host:$port');
    await withClient((c) async {
      await expectLater(
        c.runCapped('sleep 2', maxBytes: 1024, timeout: const Duration(milliseconds: 200)),
        throwsA(isA<TimeoutException>()),
      );
      expect(utf8.decode(await c.run('echo still here')).trim(), 'still here');
    });
  });

  test('an honest answer is the whole of it, and which system it is still reads', () async {
    if (!up) return markTestSkipped('test sshd not running on $host:$port');
    await withClient((c) async {
      final answer = await c.runCapped('echo one; echo two', maxBytes: 4096, timeout: const Duration(seconds: 10));
      expect(utf8.decode(answer), 'one\ntwo\n');
      expect(await OsDetectionService.detect(c), isNot(OsKind.unknown));
    });
  });

  test('a command whose errors nobody reads: what it prints is read, and no more than the limit waits', () async {
    if (!up) return markTestSkipped('test sshd not running on $host:$port');
    await withClient((c) async {
      final session = await c.execute('head -c 5000000 /dev/zero >&2; echo done');
      final out = await session.stdout.cast<List<int>>().transform(utf8.decoder).join();
      expect(out.trim(), 'done');
      var kept = 0;
      await session.stderr.forEach((chunk) => kept += chunk.length);
      expect(kept, lessThanOrEqualTo(SSHSession.maxUnreadBytes));
    });
  });
}
