import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/ssh_service.dart';

/// ZestSSH offers AES-GCM, in both of its modes, after the ciphers it
/// offered before.
///
/// Its SSH core has spoken the two AES-GCM ciphers for a long time, and the
/// app offered neither: a server set to those two alone, as some that are
/// set up strictly are, could not be connected to with Compatibility mode
/// or without ("Could not agree on a cipher algorithm").
///
/// They come last among what was offered before, and before what
/// Compatibility mode adds. The first cipher of the app's list that a
/// server has too is the one agreed on, so every server the app connected
/// to before is connected to under the same cipher as before.
///
/// The real server is the seventh of the SSH core's tool/test_sshd.sh
/// (127.0.0.1:2289), an OpenSSH whose ciphers are the two AES-GCM ones and
/// no other; the first (2299) has what a current OpenSSH has. The tests of
/// them skip themselves where they are not running.
void main() {
  const offeredBefore = ['chacha20-poly1305@openssh.com', 'aes256-ctr', 'aes128-ctr'];
  const gcm = ['aes256-gcm@openssh.com', 'aes128-gcm@openssh.com'];
  const ofTheMode = ['aes128-cbc', 'aes192-cbc', 'aes256-cbc'];

  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final plainPort = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final gcmPort = int.tryParse(env['ZESTSSH_TEST_GCM_SSHD_PORT'] ?? '') ?? 2289;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  SSHKeyPair? key;
  final up = <int, bool>{};

  setUpAll(() async {
    final file = File('$dir/client_ed25519');
    if (file.existsSync()) key = SSHKeyPair.fromPem(file.readAsStringSync()).single;
    for (final port in [plainPort, gcmPort]) {
      try {
        final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
        socket.destroy();
        up[port] = key != null;
      } catch (_) {
        up[port] = false;
      }
    }
  });

  List<String> ciphers({required bool compatibility}) =>
      [for (final cipher in SshService.buildAlgorithms(compatibility: compatibility).cipher) cipher.name];

  test('what the app offers: the three ciphers of before, then the two AES-GCM ones, and with Compatibility mode '
      'the three it adds after those', () {
    expect(ciphers(compatibility: false), [...offeredBefore, ...gcm]);
    expect(ciphers(compatibility: true), [...offeredBefore, ...gcm, ...ofTheMode]);
    // The mode adds, and takes nothing away: its list begins with the list without it.
    expect(ciphers(compatibility: true).sublist(0, 5), ciphers(compatibility: false));
  });

  /// The app's own service, signed in to the test server on [port].
  Future<SshService> connected(int port, {required bool compatibility}) async {
    final ssh = SshService(
      host: host,
      port: port,
      username: user,
      keyPairs: [key!],
      keepAliveSeconds: 0,
      compatibilityMode: compatibility,
      onHostKeyVerify: (_, _, _) async => true,
    );
    addTearDown(ssh.disconnect);
    await ssh.connect();
    return ssh;
  }

  test('a server whose ciphers are the two AES-GCM ones alone is connected to, with Compatibility mode off and '
      'on: under aes256-gcm, with no MAC to show, and a command runs', () async {
    if (up[gcmPort] != true) return markTestSkipped('no AES-GCM test sshd at $host:$gcmPort');
    for (final compatibility in [false, true]) {
      final why = 'Compatibility mode: $compatibility';
      final ssh = await connected(gcmPort, compatibility: compatibility);
      expect(ssh.isConnected, isTrue, reason: why);
      expect(ssh.negotiatedCipher, 'aes256-gcm@openssh.com', reason: why);
      // What the session details show a MAC row by: none for a cipher that checks its packets itself.
      expect(ssh.negotiatedMac, '', reason: why);
      expect(String.fromCharCodes(await ssh.client.run('echo under-gcm')), 'under-gcm\n', reason: why);
      await ssh.disconnect();
    }
  });

  test('a server that has what a current OpenSSH has is connected to under the cipher of before', () async {
    if (up[plainPort] != true) return markTestSkipped('no test sshd at $host:$plainPort');
    for (final compatibility in [false, true]) {
      final ssh = await connected(plainPort, compatibility: compatibility);
      expect(ssh.negotiatedCipher, 'chacha20-poly1305@openssh.com', reason: 'Compatibility mode: $compatibility');
      await ssh.disconnect();
    }
  });
}
