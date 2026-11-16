import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/services/sftp_service.dart';

/// SFTP on a host that has none, on a real OpenSSH server (3.0, the SSH
/// core's audit: requests that waited for ever). Opening it used to succeed:
/// the SSH core did not look at the host's answer to "start SFTP", and
/// handed back a client on which nothing ever answered, so a file pane
/// showed that it was loading for as long as it stayed open. Opening it now
/// fails at once, and the app has words for that.
///
/// The server is the WSL test sshd on 127.0.0.1:2299 (tool/test_sshd.sh
/// starts it, with no SFTP subsystem); its own client key logs in. Skips
/// itself when the server is not running. Override the location with
/// ZESTSSH_TEST_SSHD_HOST / _PORT / _USER / _DIR.
void main() {
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  late bool up;

  setUpAll(() async {
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      s.destroy();
      up = File('$dir/client_ed25519').existsSync();
    } catch (_) {
      up = false;
    }
  });

  test('SFTP on a host that has none: opening it fails at once, in the words the app has for it', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    final key = SSHKeyPair.fromPem(File('$dir/client_ed25519').readAsStringSync()).single;
    final client = SSHClient(await SSHSocket.connect(host, port), username: user, identities: [key]);
    addTearDown(() async {
      client.close();
      await client.done.catchError((_) {});
    });
    await client.authenticated;

    final sftp = SftpService(client);
    Object? failure;
    try {
      await sftp.open().timeout(const Duration(seconds: 10));
    } catch (e) {
      failure = e;
    }
    expect(failure, isA<SSHChannelRequestError>(), reason: 'refused, where it was taken for started');
    expect(sftp.isOpen, isFalse);
    expect(
      sftpStartFailure(failure!, l10n: lookupAppLocalizations(const Locale('en'))),
      'The host did not start SFTP. Its server may not offer SFTP, or may allow no more sessions.',
    );

    // The refusal was the request's: the connection goes on, and nothing of
    // the try is left open on the host (asked for more often than the host
    // allows a connection sessions, a command still runs).
    for (var i = 0; i < 14; i++) {
      await expectLater(sftp.open().timeout(const Duration(seconds: 10)), throwsA(isA<SSHChannelRequestError>()));
    }
    final answer = await client.run('echo still-here').timeout(const Duration(seconds: 10));
    expect(String.fromCharCodes(answer), contains('still-here'));
  });
}
