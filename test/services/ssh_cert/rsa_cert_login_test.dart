import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
// SSHHostKey is hidden by the dartssh2.dart barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/ssh_hostkey.dart' as core_hk;
import 'package:zestssh/services/ssh_cert/ssh_cert_signer.dart';
import 'package:zestssh/services/ssh_cert/ssh_certificate.dart';
import 'package:zestssh/services/ssh_cert/ssh_certificate_keypair.dart';

/// Logging in with an SSH user certificate.
///
/// The unit tests always run. The login tests talk to a REAL OpenSSH 10.2
/// server in WSL on 127.0.0.1:2299 (started by tool/test_sshd.sh, which
/// has it trust a test CA and issues an RSA certificate with ssh-keygen)
/// and skip themselves when it is not running.
/// Override the location with ZESTSSH_TEST_SSHD_HOST / _PORT / _USER / _DIR.

const _fixtures = 'packages/zest_ssh_core/test/fixtures';

SSHKeyPair _loadKey(String path) =>
    SSHKeyPair.fromPem(File(path).readAsStringSync()).single;

SshCertificateKeyPair _issue(
  SSHKeyPair subject,
  SSHKeyPair ca,
  SshCertAlgorithm algorithm, {
  List<String> principals = const ['tester'],
}) {
  final blob = SshCertSigner.issue(
    params: SshCertIssueParams(
      subjectPublicKeyBlob: subject.toPublicKey().encode(),
      subjectAlgorithm: algorithm,
      serial: 7,
      type: SshCertType.user,
      keyId: 'rsa-cert-login-test',
      principals: principals,
      validAfter: DateTime.now().subtract(const Duration(minutes: 5)),
      validBefore: DateTime.now().add(const Duration(hours: 1)),
    ),
    caKey: ca,
  );
  return SshCertificateKeyPair(
    innerKey: subject,
    certificate: SshCertificate.parse(blob),
  );
}

/// The algorithm name at the front of an encoded SSH signature
/// (`string name || string blob`).
String _signatureAlgorithm(SSHSignature signature) {
  final bytes = signature.encode();
  final length = ByteData.sublistView(bytes, 0, 4).getUint32(0);
  return String.fromCharCodes(bytes.sublist(4, 4 + length));
}

/// A key that, like a hardware token or an agent, can only sign
/// asynchronously.
class _AsyncOnlyKey extends SSHKeyPair {
  _AsyncOnlyKey(this._real);
  final SSHKeyPair _real;
  @override
  String get name => _real.name;
  @override
  String get type => _real.type;
  @override
  core_hk.SSHHostKey toPublicKey() => _real.toPublicKey();
  @override
  SSHSignature sign(Uint8List data) =>
      throw UnsupportedError('this key only signs asynchronously');
  @override
  Future<SSHSignature> signAsync(Uint8List data) async => _real.sign(data);
  @override
  String toPem() => throw UnsupportedError('no PEM for a token key');
}

void main() {
  final rsa = _loadKey('$_fixtures/ssh-rsa/id_rsa');
  final ed25519 = _loadKey('$_fixtures/ssh-ed25519/id_ed25519');
  final ca = _loadKey('$_fixtures/ssh-ed25519/ssh_host_ed25519_key');
  final challenge = Uint8List.fromList(List.generate(64, (i) => i));

  group('the algorithm a certificate announces', () {
    for (final algorithm in [
      SshCertAlgorithm.rsaSha1,
      SshCertAlgorithm.rsaSha2_256,
      SshCertAlgorithm.rsaSha2_512,
    ]) {
      test('an RSA certificate named ${algorithm.name} announces the hash '
          'its signature really uses', () {
        final pair = _issue(rsa, ca, algorithm);
        final signed = _signatureAlgorithm(pair.sign(challenge));
        // OpenSSH refuses a signature whose hash differs from the one the
        // announced algorithm names ("unexpected signature type").
        expect(pair.type, '$signed-cert-v01@openssh.com');
        // The announced name is never the SHA-1 one OpenSSH 8.8+ refuses.
        expect(pair.type, isNot(SshCertAlgorithm.rsaSha1.name));
        // The blob is presented exactly as issued.
        expect(pair.toPublicKey().encode(), pair.certificate.fullBlob);
      });
    }

    test('any other certificate announces its own name', () {
      final pair = _issue(ed25519, ca, SshCertAlgorithm.ed25519);
      expect(pair.type, 'ssh-ed25519-cert-v01@openssh.com');
      expect(pair.sign(challenge), isA<SSHSignature>());
    });

    test('new RSA certificates carry the name OpenSSH itself writes', () {
      expect(
        SshCertAlgorithm.forSubjectKey('ssh-rsa'),
        SshCertAlgorithm.rsaSha1,
      );
      expect(
        SshCertAlgorithm.forSubjectKey('ssh-ed25519'),
        SshCertAlgorithm.ed25519,
      );
      expect(SshCertAlgorithm.forSubjectKey('ssh-dss'), isNull);
      final pair = _issue(rsa, ca, SshCertAlgorithm.forSubjectKey('ssh-rsa')!);
      expect(pair.certificate.algorithm.name, 'ssh-rsa-cert-v01@openssh.com');
    });
  });

  test('a certificate on an RSA key signs in the three ways an RSA key signs, each announced under the '
      'certificate\'s name for it; one on a key of another kind makes no RSA signature', () {
    final pair = _issue(rsa, ca, SshCertAlgorithm.rsaSha1);
    expect(pair, isA<SSHRsaSignatureChoice>());
    expect(pair.rsaSignatureTypes, ['rsa-sha2-512', 'rsa-sha2-256', 'ssh-rsa']);
    for (final (kind, announced) in [
      ('rsa-sha2-512', 'rsa-sha2-512-cert-v01@openssh.com'),
      ('rsa-sha2-256', 'rsa-sha2-256-cert-v01@openssh.com'),
      ('ssh-rsa', 'ssh-rsa-cert-v01@openssh.com'),
    ]) {
      final signing = pair.signingAsRsa(kind);
      expect(signing, isA<SshCertificateKeyPair>());
      expect(signing.type, announced);
      expect(signing.name, pair.name);
      expect(signing.toPublicKey().encode(), pair.toPublicKey().encode());
      expect(_signatureAlgorithm(signing.sign(challenge)), kind);
    }
    // The pair it was made of signs as it did.
    expect(pair.type, 'rsa-sha2-256-cert-v01@openssh.com');
    expect(_issue(ed25519, ca, SshCertAlgorithm.ed25519).rsaSignatureTypes, isEmpty);
    // A key that signs somewhere else and says nothing of RSA signatures: the certificate makes none either.
    expect(_issue(_AsyncOnlyKey(rsa), ca, SshCertAlgorithm.rsaSha1).rsaSignatureTypes, isEmpty);
  });

  test(
    'a certificate on a key that only signs asynchronously can sign',
    () async {
      final token = _AsyncOnlyKey(ed25519);
      final pair = _issue(token, ca, SshCertAlgorithm.ed25519);
      final signature = await pair.signAsync(challenge);
      expect(signature.encode(), (await ed25519.signAsync(challenge)).encode());
    },
  );

  group('logging in to OpenSSH 10 with an RSA certificate', () {
    final env = Platform.environment;
    final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
    final port = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
    final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
    final dir =
        env['ZESTSSH_TEST_SSHD_DIR'] ??
        '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
    late bool up;

    setUpAll(() async {
      try {
        final s = await Socket.connect(
          host,
          port,
          timeout: const Duration(seconds: 2),
        );
        s.destroy();
        up = File('$dir/client_rsa-cert.pub').existsSync();
      } catch (_) {
        up = false;
      }
    });

    Future<String> loginWith(
      SSHKeyPair identity, {
      int? at,
      SSHAlgorithms algorithms = const SSHAlgorithms(),
    }) async {
      final socket = await SSHSocket.connect(host, at ?? port);
      final client = SSHClient(socket, username: user, algorithms: algorithms, identities: [identity]);
      try {
        await client.authenticated;
        return String.fromCharCodes(await client.run('echo CERT-OK')).trim();
      } finally {
        client.close();
        await client.done;
      }
    }

    test('issued by ssh-keygen (ssh-rsa-cert-v01 in the blob)', () async {
      if (!up) return markTestSkipped('test sshd not running on $host:$port');
      final key = _loadKey('$dir/client_rsa');
      final cert = SshCertificate.parseFromOpenSSH(
        File('$dir/client_rsa-cert.pub').readAsStringSync(),
      );
      final pair = SshCertificateKeyPair(innerKey: key, certificate: cert);
      expect(await loginWith(pair), 'CERT-OK');
    });

    // The two servers that take one kind of signature from an RSA key each (tool/test_sshd.sh): with SHA-512,
    // and the first kind, with SHA-1. A certificate signs with the kind the server takes, as the key alone does.
    SshCertificateKeyPair fromSshKeygen() => SshCertificateKeyPair(
          innerKey: _loadKey('$dir/client_rsa'),
          certificate: SshCertificate.parseFromOpenSSH(File('$dir/client_rsa-cert.pub').readAsStringSync()),
        );

    Future<bool> listening(int at) async {
      try {
        (await Socket.connect(host, at, timeout: const Duration(seconds: 2))).destroy();
        return true;
      } catch (_) {
        return false;
      }
    }

    test('at a server that takes only SHA-512 from an RSA key: the certificate signs in', () async {
      final at = int.tryParse(env['ZESTSSH_TEST_SHA512_SSHD_PORT'] ?? '') ?? 2291;
      if (!up || !await listening(at)) return markTestSkipped('test sshd not running on $host:$at');
      expect(await loginWith(fromSshKeygen(), at: at), 'CERT-OK');
    });

    test('at a server that takes only the first kind, with SHA-1: the certificate is not offered by a client that '
        'may not make it, and signs in with one that may', () async {
      final at = int.tryParse(env['ZESTSSH_TEST_SHA1_SSHD_PORT'] ?? '') ?? 2285;
      if (!up || !await listening(at)) return markTestSkipped('test sshd not running on $host:$at');
      Object? refused;
      try {
        await loginWith(fromSshKeygen(), at: at);
      } catch (e) {
        refused = e;
      }
      expect(refused, isA<SSHAuthFailError>());
      final failed = refused! as SSHAuthFailError;
      expect(failed.keysPassedOver, ['ssh-rsa-cert-v01@openssh.com']);
      expect(failed.methodsTried, isEmpty);
      expect(
        await loginWith(
          fromSshKeygen(),
          at: at,
          algorithms: const SSHAlgorithms(rsaSignatures: ['rsa-sha2-512', 'rsa-sha2-256', 'ssh-rsa']),
        ),
        'CERT-OK',
      );
    });

    for (final algorithm in [
      SshCertAlgorithm.rsaSha2_512, // what builds up to 2.1.1 issued
      SshCertAlgorithm.rsaSha1, // what builds issue from now on
    ]) {
      test('issued by the app (${algorithm.name} in the blob)', () async {
        if (!up) return markTestSkipped('test sshd not running on $host:$port');
        final key = _loadKey('$dir/client_rsa');
        final testCa = _loadKey('$dir/user_ca');
        final pair = _issue(key, testCa, algorithm, principals: [user]);
        expect(await loginWith(pair), 'CERT-OK');
      });
    }
  });
}
