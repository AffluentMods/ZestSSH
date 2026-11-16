import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
// ignore: implementation_imports
import 'package:zest_ssh_core/src/ssh_hostkey.dart' as core_hk;
import 'package:zestssh/services/ssh_cert/ssh_cert_signer.dart';
import 'package:zestssh/services/ssh_cert/ssh_certificate.dart';
import 'package:zestssh/services/ssh_cert/ssh_certificate_keypair.dart';
import 'package:zestssh/services/ssh_cert/ssh_wire.dart';

/// Stub SSHKeyPair used as both the subject (the user's key) and the
/// CA in round-trip tests. Has a deterministic public-key blob so we
/// can assert on it; signs by returning a fixed signature regardless
/// of the input (we're not testing the signature crypto here, just the
/// cert envelope round-trip).
class _StubKey extends SSHKeyPair {
  _StubKey({required this.algorithm, required this.publicBytes});
  final String algorithm;
  final Uint8List publicBytes;

  @override
  String get name => algorithm;
  @override
  String get type => algorithm;

  @override
  core_hk.SSHHostKey toPublicKey() {
    final w = SshWireWriter()
      ..writeUtf8String(algorithm)
      ..writeString(publicBytes);
    return _StubHostKey(w.takeBytes());
  }

  @override
  SSHSignature sign(Uint8List data) {
    final w = SshWireWriter()
      ..writeUtf8String(algorithm)
      ..writeString(Uint8List.fromList(List.filled(64, 0xAA)));
    return _StubSig(w.takeBytes());
  }

  @override
  String toPem() => 'STUB-PEM';
}

class _StubHostKey implements core_hk.SSHHostKey {
  _StubHostKey(this._bytes);
  final Uint8List _bytes;
  @override
  Uint8List encode() => _bytes;
}

class _StubSig implements SSHSignature {
  _StubSig(this._bytes);
  final Uint8List _bytes;
  @override
  Uint8List encode() => _bytes;
}

void main() {
  // The cert signer hits crypto-secure RNG inside the OpenSSH
  // PEM-loading path indirectly via dartssh - skip on platforms
  // that don't have it (web).
  setUpAll(() {
    if (!Platform.isLinux && !Platform.isMacOS && !Platform.isWindows) {
      throw StateError('Cert tests assume native dart:io platform');
    }
  });

  final subjectKey = _StubKey(
    algorithm: 'ssh-ed25519',
    publicBytes: Uint8List.fromList(List.generate(32, (i) => i)),
  );
  final caKey = _StubKey(
    algorithm: 'ssh-ed25519',
    publicBytes: Uint8List.fromList(List.generate(32, (i) => 0x80 | i)),
  );

  group('SshCertSigner.issue / SshCertificate.parse round-trip', () {
    test('issues a parseable Ed25519 user cert', () {
      final blob = SshCertSigner.issue(
        params: SshCertIssueParams(
          subjectPublicKeyBlob: subjectKey.toPublicKey().encode(),
          subjectAlgorithm: SshCertAlgorithm.ed25519,
          serial: 0xDEADBEEF,
          type: SshCertType.user,
          keyId: 'test-key-id',
          principals: const ['alice', 'bob'],
          validAfter: DateTime.utc(2026, 1, 1),
          validBefore: DateTime.utc(2027, 1, 1),
        ),
        caKey: caKey,
      );
      final parsed = SshCertificate.parse(blob);
      expect(parsed.algorithm, SshCertAlgorithm.ed25519);
      expect(parsed.serial, 0xDEADBEEF);
      expect(parsed.keyId, 'test-key-id');
      expect(parsed.principals, ['alice', 'bob']);
      expect(parsed.type, SshCertType.user);
      expect(parsed.validAfter,
          DateTime.utc(2026, 1, 1).millisecondsSinceEpoch ~/ 1000);
      expect(parsed.validBefore,
          DateTime.utc(2027, 1, 1).millisecondsSinceEpoch ~/ 1000);
      expect(parsed.signatureKey, caKey.toPublicKey().encode());
      expect(parsed.signature.length, greaterThan(0));
    });

    test('null validBefore encodes as the OpenSSH "never expires" sentinel',
        () {
      final blob = SshCertSigner.issue(
        params: SshCertIssueParams(
          subjectPublicKeyBlob: subjectKey.toPublicKey().encode(),
          subjectAlgorithm: SshCertAlgorithm.ed25519,
          serial: 1,
          type: SshCertType.user,
          keyId: 'forever',
          principals: const ['root'],
          validAfter: DateTime.utc(2026, 1, 1),
          validBefore: null,
        ),
        caKey: caKey,
      );
      final parsed = SshCertificate.parse(blob);
      expect(parsed.validBefore, -1, reason: 'wire 0xFFFFFFFFFFFFFFFF');
      expect(parsed.validBeforeOrNull, isNull);
    });

    test('default extensions emitted when not overridden', () {
      final blob = SshCertSigner.issue(
        params: SshCertIssueParams(
          subjectPublicKeyBlob: subjectKey.toPublicKey().encode(),
          subjectAlgorithm: SshCertAlgorithm.ed25519,
          serial: 1,
          type: SshCertType.user,
          keyId: 'k',
          principals: const ['user'],
          validAfter: DateTime.utc(2026, 1, 1),
        ),
        caKey: caKey,
      );
      final parsed = SshCertificate.parse(blob);
      expect(parsed.extensions.keys, containsAll(const [
        'permit-X11-forwarding',
        'permit-agent-forwarding',
        'permit-port-forwarding',
        'permit-pty',
        'permit-user-rc',
      ]));
    });

    test('explicit empty extension map produces a locked-down cert', () {
      final blob = SshCertSigner.issue(
        params: SshCertIssueParams(
          subjectPublicKeyBlob: subjectKey.toPublicKey().encode(),
          subjectAlgorithm: SshCertAlgorithm.ed25519,
          serial: 1,
          type: SshCertType.user,
          keyId: 'locked',
          principals: const ['user'],
          validAfter: DateTime.utc(2026, 1, 1),
          extensions: const {},
        ),
        caKey: caKey,
      );
      final parsed = SshCertificate.parse(blob);
      expect(parsed.extensions, isEmpty);
    });

    test('refuses validBefore that is not strictly after validAfter', () {
      expect(
        () => SshCertSigner.issue(
          params: SshCertIssueParams(
            subjectPublicKeyBlob: subjectKey.toPublicKey().encode(),
            subjectAlgorithm: SshCertAlgorithm.ed25519,
            serial: 1,
            type: SshCertType.user,
            keyId: 'k',
            principals: const ['user'],
            validAfter: DateTime.utc(2026, 1, 1),
            validBefore: DateTime.utc(2026, 1, 1),
          ),
          caKey: caKey,
        ),
        throwsArgumentError,
      );
    });

    test('refuses negative serials', () {
      expect(
        () => SshCertSigner.issue(
          params: SshCertIssueParams(
            subjectPublicKeyBlob: subjectKey.toPublicKey().encode(),
            subjectAlgorithm: SshCertAlgorithm.ed25519,
            serial: -1,
            type: SshCertType.user,
            keyId: 'k',
            principals: const ['user'],
            validAfter: DateTime.utc(2026, 1, 1),
          ),
          caKey: caKey,
        ),
        throwsArgumentError,
      );
    });

    test('refuses empty / oversize principals', () {
      expect(
        () => SshCertSigner.issue(
          params: SshCertIssueParams(
            subjectPublicKeyBlob: subjectKey.toPublicKey().encode(),
            subjectAlgorithm: SshCertAlgorithm.ed25519,
            serial: 1,
            type: SshCertType.user,
            keyId: 'k',
            principals: const [''],
            validAfter: DateTime.utc(2026, 1, 1),
          ),
          caKey: caKey,
        ),
        throwsArgumentError,
      );
    });

    test('subject algorithm mismatch with bare key throws', () {
      // Issue an Ed25519 cert against an RSA-shaped subject blob.
      final rsaSubjectBlob = (SshWireWriter()
            ..writeUtf8String('ssh-rsa')
            ..writeString([1, 2, 3]) // mpint e
            ..writeString([4, 5, 6])) // mpint n
          .takeBytes();
      expect(
        () => SshCertSigner.issue(
          params: SshCertIssueParams(
            subjectPublicKeyBlob: rsaSubjectBlob,
            subjectAlgorithm: SshCertAlgorithm.ed25519,
            serial: 1,
            type: SshCertType.user,
            keyId: 'k',
            principals: const ['user'],
            validAfter: DateTime.utc(2026, 1, 1),
          ),
          caKey: caKey,
        ),
        throwsArgumentError,
      );
    });
  });

  group('SshCertificate validity helpers', () {
    test('isValidAt is true between validAfter and validBefore', () {
      final blob = SshCertSigner.issue(
        params: SshCertIssueParams(
          subjectPublicKeyBlob: subjectKey.toPublicKey().encode(),
          subjectAlgorithm: SshCertAlgorithm.ed25519,
          serial: 1,
          type: SshCertType.user,
          keyId: 'k',
          principals: const ['u'],
          validAfter: DateTime.utc(2026, 1, 1),
          validBefore: DateTime.utc(2026, 12, 31),
        ),
        caKey: caKey,
      );
      final cert = SshCertificate.parse(blob);
      expect(cert.isValidAt(DateTime.utc(2026, 6, 1)), isTrue);
      expect(cert.isValidAt(DateTime.utc(2025, 12, 31)), isFalse);
      expect(cert.isValidAt(DateTime.utc(2027, 1, 2)), isFalse);
    });

    test('caFingerprint format is SHA256:base64', () {
      final blob = SshCertSigner.issue(
        params: SshCertIssueParams(
          subjectPublicKeyBlob: subjectKey.toPublicKey().encode(),
          subjectAlgorithm: SshCertAlgorithm.ed25519,
          serial: 1,
          type: SshCertType.user,
          keyId: 'k',
          principals: const ['u'],
          validAfter: DateTime.utc(2026, 1, 1),
        ),
        caKey: caKey,
      );
      final cert = SshCertificate.parse(blob);
      expect(cert.caFingerprint, startsWith('SHA256:'));
      expect(cert.caFingerprint.length, greaterThan(7 + 30));
    });
  });

  group('SshCertificate.parseFromOpenSSH', () {
    test('refuses base64 garbage', () {
      expect(() => SshCertificate.parseFromOpenSSH('ssh-ed25519-cert-v01@openssh.com !!!notbase64!!!'),
          throwsFormatException);
    });

    test('refuses an empty input', () {
      expect(() => SshCertificate.parseFromOpenSSH('   '),
          throwsFormatException);
    });

    test('refuses unknown algorithms', () {
      expect(
          () => SshCertificate.parseFromOpenSSH('foo-cert-v99@openssh.com AAAA'),
          throwsFormatException);
    });

    test('refuses algorithm-header / body mismatch', () {
      // Issue an ed25519 cert, then prepend an RSA algorithm header.
      final blob = SshCertSigner.issue(
        params: SshCertIssueParams(
          subjectPublicKeyBlob: subjectKey.toPublicKey().encode(),
          subjectAlgorithm: SshCertAlgorithm.ed25519,
          serial: 1,
          type: SshCertType.user,
          keyId: 'k',
          principals: const ['u'],
          validAfter: DateTime.utc(2026, 1, 1),
        ),
        caKey: caKey,
      );
      final encoded = SshCertSigner.toOpenSshLine(blob);
      // Replace the leading algorithm with a different one.
      final fake = encoded.replaceFirst(
        'ssh-ed25519-cert-v01@openssh.com',
        'ssh-rsa-cert-v01@openssh.com',
      );
      expect(() => SshCertificate.parseFromOpenSSH(fake),
          throwsFormatException);
    });
  });

  group('SshCertificateKeyPair', () {
    test('refuses to construct when cert subject != inner key', () {
      final blob = SshCertSigner.issue(
        params: SshCertIssueParams(
          subjectPublicKeyBlob: subjectKey.toPublicKey().encode(),
          subjectAlgorithm: SshCertAlgorithm.ed25519,
          serial: 1,
          type: SshCertType.user,
          keyId: 'mismatch',
          principals: const ['u'],
          validAfter: DateTime.utc(2026, 1, 1),
        ),
        caKey: caKey,
      );
      final parsed = SshCertificate.parse(blob);
      // Build a different inner key - different public bytes.
      final wrongKey = _StubKey(
        algorithm: 'ssh-ed25519',
        publicBytes: Uint8List.fromList(List.filled(32, 0xFF)),
      );
      expect(
        () => SshCertificateKeyPair(innerKey: wrongKey, certificate: parsed),
        throwsArgumentError,
      );
    });

    test('refuses host certificates', () {
      final blob = SshCertSigner.issue(
        params: SshCertIssueParams(
          subjectPublicKeyBlob: subjectKey.toPublicKey().encode(),
          subjectAlgorithm: SshCertAlgorithm.ed25519,
          serial: 1,
          type: SshCertType.host,
          keyId: 'h',
          principals: const ['host.example.com'],
          validAfter: DateTime.utc(2026, 1, 1),
        ),
        caKey: caKey,
      );
      final parsed = SshCertificate.parse(blob);
      expect(
        () => SshCertificateKeyPair(
            innerKey: subjectKey, certificate: parsed),
        throwsArgumentError,
      );
    });

    test('happy path - type advertises cert algorithm', () {
      final blob = SshCertSigner.issue(
        params: SshCertIssueParams(
          subjectPublicKeyBlob: subjectKey.toPublicKey().encode(),
          subjectAlgorithm: SshCertAlgorithm.ed25519,
          serial: 1,
          type: SshCertType.user,
          keyId: 'k',
          principals: const ['u'],
          validAfter: DateTime.utc(2026, 1, 1),
        ),
        caKey: caKey,
      );
      final parsed = SshCertificate.parse(blob);
      final pair = SshCertificateKeyPair(
          innerKey: subjectKey, certificate: parsed);
      expect(pair.type, 'ssh-ed25519-cert-v01@openssh.com');
      expect(pair.toPublicKey().encode(), parsed.fullBlob);
    });
  });
}
