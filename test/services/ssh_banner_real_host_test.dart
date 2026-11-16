import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/ssh_service.dart';

/// A host whose notice before sign-in (the "authorised users only" text many
/// hosts show) is in an older encoding, on a real OpenSSH server: one byte
/// in it that is no UTF-8 was taken for a packet that cannot be read, and
/// the app could not connect to such a host at all ("Malformed packet").
/// It connects now, and the notice is shown ahead of the first prompt as far
/// as it reads, with a mark where a byte could not be read.
///
/// The server is the third one tool/test_sshd.sh starts (127.0.0.1:2295),
/// whose notice is "Zugang nur f?r Befugte." with the single byte 0xFC, as
/// ISO 8859-1 writes the u with two dots, where the question mark stands.
/// Skips itself when that server is not running. Override the location with
/// ZESTSSH_TEST_SSHD_HOST / ZESTSSH_TEST_BANNER_SSHD_PORT / _USER / _DIR.
void main() {
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(env['ZESTSSH_TEST_BANNER_SSHD_PORT'] ?? '') ?? 2295;
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

  test('a host whose notice is not UTF-8 is connected to, and its notice shown ahead of the prompt as far as it reads',
      () async {
    if (!up) {
      markTestSkipped('no test sshd with a notice at $host:$port');
      return;
    }
    final log = <String>[];
    final ssh = SshService(
      host: host,
      port: port,
      username: user,
      keyPairs: [key!],
      onHostKeyVerify: (_, _, _) async => true,
      onLog: log.add,
    );
    final said = StringBuffer();
    final seen = Completer<void>();
    final sub = ssh.stdout.listen((data) {
      said.write(utf8.decode(data, allowMalformed: true));
      if (!seen.isCompleted && said.toString().contains('still-here')) seen.complete();
    });
    await ssh.connect().timeout(const Duration(seconds: 20));
    expect(ssh.isConnected, isTrue);
    expect(log, contains('ssh_auth: Server sent a login banner'));
    // (The mark is put together by the shell, so that it is not found in the echo of what was typed.)
    ssh.write(Uint8List.fromList(utf8.encode('echo still-"here"\r')));
    await seen.future.timeout(const Duration(seconds: 15));
    await sub.cancel();
    final mark = String.fromCharCode(0xfffd);
    final shown = said.toString();
    expect(shown, contains('Zugang nur f${mark}r Befugte.'));
    expect(shown.indexOf('Zugang nur f'), lessThan(shown.indexOf('still-here')), reason: 'ahead of what the shell says');
    await ssh.disconnect();
  });
}
