import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/features/orchards/certs/team_certificates.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/services/ssh_cert/ssh_certificate.dart';
import 'package:zestssh/services/ssh_cert/ssh_certificate_keypair.dart';

/// Team certificates (3.0) against a REAL OpenSSH 10 server: a
/// device's own key with a certificate issued the way an owner's device
/// issues it logs in; user names the certificate does not carry, and
/// certificates from an authority the host does not trust, do not; and the
/// host holds the member to the Crate's switches (port forwarding only when
/// the certificate permits it).
///
/// The server is the WSL test sshd on 127.0.0.1:2299 (started by
/// tool/test_sshd.sh: TrustedUserCAKeys names its test CA, which stands in
/// for a Crate's authority here). Skips itself when it
/// is not running. Override the location with ZESTSSH_TEST_SSHD_HOST /
/// _PORT / _USER / _DIR.
void main() {
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  late bool up;
  late SSHKeyPair authority;
  late TeamDeviceKey device;

  setUpAll(() async {
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      s.destroy();
      up = File('$dir/user_ca').existsSync();
    } catch (_) {
      up = false;
    }
    if (up) authority = SSHKeyPair.fromPem(File('$dir/user_ca').readAsStringSync()).single;
    device = await TeamDeviceKey.generate();
  });

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  SshCertificateKeyPair certified({
    SSHKeyPair? by,
    List<String>? principals,
    Set<String> switches = const {CrateSwitches.connect},
  }) {
    final blob = issueTeamCertificate(
      ca: by ?? authority,
      request: CertRequest(
        id: 'r1',
        uid: 'alice',
        keyVersion: 1,
        sshPublicKey: device.publicKey,
        requestedAt: now(),
        signature: Uint8List(64),
      ),
      principals: principals ?? [user],
      extensions: certExtensions(switches),
      ttlMinutes: 60,
      nowSeconds: now(),
      keyId: 'alice@example.com (zestssh r1)',
    );
    return SshCertificateKeyPair(innerKey: device.keyPair, certificate: SshCertificate.parse(blob));
  }

  Future<T> withClient<T>(SSHKeyPair identity, Future<T> Function(SSHClient client) body) async {
    final client = SSHClient(await SSHSocket.connect(host, port), username: user, identities: [identity]);
    try {
      await client.authenticated;
      return await body(client);
    } finally {
      client.close();
      await client.done;
    }
  }

  test("a device's own key with the authority's certificate logs in", () async {
    if (!up) return markTestSkipped('test sshd not running on $host:$port');
    final out = await withClient(certified(), (c) async => String.fromCharCodes(await c.run('echo TEAM-CERT-OK')));
    expect(out.trim(), 'TEAM-CERT-OK');
  });

  test('a user name the certificate does not carry, or another authority, is refused', () async {
    if (!up) return markTestSkipped('test sshd not running on $host:$port');
    await expectLater(withClient(certified(principals: ['deploy-someone-else']), (c) async => null),
        throwsA(isA<SSHAuthFailError>()));
    final impostor = await TeamDeviceKey.generate();
    await expectLater(withClient(certified(by: impostor.keyPair), (c) async => null), throwsA(isA<SSHAuthFailError>()));
    // The device's bare key, without a certificate, is not in authorized_keys.
    await expectLater(withClient(device.keyPair, (c) async => null), throwsA(isA<SSHAuthFailError>()));
  });

  test("the host holds the member to the Crate's switches: port forwarding only when permitted", () async {
    if (!up) return markTestSkipped('test sshd not running on $host:$port');
    Future<String> banner(SSHClient c) async {
      final channel = await c.forwardLocal('127.0.0.1', port);
      final first = await channel.stream.first.timeout(const Duration(seconds: 5));
      channel.close();
      return String.fromCharCodes(first);
    }

    expect(await withClient(certified(switches: {CrateSwitches.connect, CrateSwitches.forward}), banner),
        startsWith('SSH-2.0-OpenSSH'));
    await expectLater(withClient(certified(), banner), throwsA(isA<SSHChannelOpenError>()));
  });
}
