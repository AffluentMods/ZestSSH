import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/certs/team_certificates.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/services/ssh_cert/ssh_cert_signer.dart';
import 'package:zestssh/services/ssh_cert/ssh_certificate.dart';

/// Certificates from a Crate's authority (3.0): the exact bytes a
/// request covers (the server holds the same vector: ZestSSH Cloud's
/// test/team_certificates_lib.test.js), a request signature that checks only
/// for that request, and certificates an owner's device issues that the
/// member's device reads back only when they are the authority's, for its
/// own key.
/// Length-prefixed, as SSH writes a string.
List<int> lp(List<int> b) => [(b.length >> 24) & 0xff, (b.length >> 16) & 0xff, (b.length >> 8) & 0xff, b.length & 0xff, ...b];

void main() {
  const vector = '000000177a6573747373682e636572742d726571756573742e76310000002431313131313131312d313131312d343131312d38'
      '3131312d3131313131313131313131310000002432323232323232322d323232322d343232322d383232322d323232323232323232'
      '3232320000002433333333333333332d333333332d343333332d383333332d333333333333333333333333000000097569642d616c'
      '6963650000000200000020000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f000000006ab13b80';
  const orchardId = '11111111-1111-4111-8111-111111111111';
  const crateId = '22222222-2222-4222-8222-222222222222';
  final key = Uint8List.fromList(List.generate(32, (i) => i));

  CertRequest request({String id = '33333333-3333-4333-8333-333333333333', Uint8List? signature, Uint8List? ssh}) =>
      CertRequest(
        id: id,
        uid: 'uid-alice',
        keyVersion: 2,
        sshPublicKey: ssh ?? key,
        requestedAt: 1790000000,
        signature: signature ?? Uint8List(64),
      );

  test('the bytes a certificate request covers', () {
    final bytes = request().message(orchardId: orchardId, crateId: crateId);
    expect(bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(), vector);
  });

  test('a request signature checks for that request only', () async {
    final pair = await Ed25519().newKeyPair();
    final public = (await pair.extractPublicKey()).bytes;
    final signature = Uint8List.fromList(
        (await Ed25519().sign(request().message(orchardId: orchardId, crateId: crateId), keyPair: pair)).bytes);
    final signed = request(signature: signature);
    expect(await verifyCertRequest(public, signed, orchardId: orchardId, crateId: crateId), isTrue);
    expect(await verifyCertRequest(public, signed, orchardId: crateId, crateId: crateId), isFalse);
    expect(await verifyCertRequest(public, signed, orchardId: orchardId, crateId: orchardId), isFalse);
    expect(
        await verifyCertRequest(public, request(id: '44444444-4444-4444-8444-444444444444', signature: signature),
            orchardId: orchardId, crateId: crateId),
        isFalse);
    expect(
        await verifyCertRequest(public, request(ssh: Uint8List(32), signature: signature),
            orchardId: orchardId, crateId: crateId),
        isFalse);
    final other = (await (await Ed25519().newKeyPair()).extractPublicKey()).bytes;
    expect(await verifyCertRequest(other, signed, orchardId: orchardId, crateId: crateId), isFalse);
    expect(
        await verifyCertRequest(public, request(signature: signature.sublist(0, 63)),
            orchardId: orchardId, crateId: crateId),
        isFalse);
    // Carried as the server lists it and as the device sends it.
    final json = signed.toJson();
    expect(json.keys.toSet(), {'id', 'ssh_public_key', 'requested_at', 'key_version', 'signature'});
    final back = CertRequest.fromJson({...json, 'uid': 'uid-alice'})!;
    expect(await verifyCertRequest(public, back, orchardId: orchardId, crateId: crateId), isTrue);
    expect(CertRequest.fromJson({...json}), isNull, reason: 'no uid');
    expect(CertRequest.fromJson({...json, 'uid': 'uid-alice', 'ssh_public_key': '%%'}), isNull);
  });

  group('certificates', () {
    late TeamDeviceKey ca;
    late TeamDeviceKey device;
    setUpAll(() async {
      ca = await TeamDeviceKey.generate();
      device = await TeamDeviceKey.generate();
    });

    Uint8List issue({TeamDeviceKey? by, TeamDeviceKey? forKey, Set<String> switches = const {}}) => issueTeamCertificate(
          ca: (by ?? ca).keyPair,
          request: request(ssh: (forKey ?? device).publicKey),
          principals: const ['deploy', 'www'],
          extensions: certExtensions(switches),
          ttlMinutes: 60,
          nowSeconds: 1790000000,
          keyId: 'alice@example.com (zestssh 3333)',
        );

    test('ends with the access it rests on when that is sooner, never later than the authority allows', () {
      int lasts(int? notAfter) => SshCertificate.parse(issueTeamCertificate(
            ca: ca.keyPair,
            request: request(ssh: device.publicKey),
            principals: const ['deploy'],
            extensions: const {},
            ttlMinutes: 60,
            nowSeconds: 1790000000,
            keyId: 'k',
            notAfter: notAfter,
          )).validBefore;
      expect(lasts(null), 1790000000 + 3600);
      expect(lasts(1790000000 + 7200), 1790000000 + 3600);
      expect(lasts(1790000000 + 3600), 1790000000 + 3600);
      expect(lasts(1790000000 + 3599), 1790000000 + 3599);
      expect(lasts(1790000000 + 60), 1790000000 + 60);
    });

    test("issued by the authority, read back only as the authority's, for this device's key", () async {
      final blob = issue();
      final cert = (await readTeamCertificate(blob, caPublicKey: ca.publicKey, subject: device.publicKey))!;
      expect(cert.principals, ['deploy', 'www']);
      expect(cert.type, SshCertType.user);
      expect(cert.validAfter, 1790000000 - kCertBackdateSeconds);
      expect(cert.validBefore, 1790000000 + 3600);
      expect(cert.keyId, 'alice@example.com (zestssh 3333)');
      expect(cert.extensions.keys.toSet(), {'permit-pty', 'permit-user-rc'});

      final other = await TeamDeviceKey.generate();
      expect(await readTeamCertificate(blob, caPublicKey: other.publicKey, subject: device.publicKey), isNull,
          reason: 'another authority');
      expect(await readTeamCertificate(blob, caPublicKey: ca.publicKey, subject: other.publicKey), isNull,
          reason: 'another key');
      expect(await readTeamCertificate(issue(by: other), caPublicKey: ca.publicKey, subject: device.publicKey), isNull,
          reason: 'signed by someone else, naming the authority');
      // A byte flipped inside the nonce: it still reads, and the signature
      // no longer checks.
      final flipped = Uint8List.fromList(blob)..[50] ^= 1;
      expect(SshCertificate.parse(flipped).nonce, isNot(SshCertificate.parse(blob).nonce));
      expect(await readTeamCertificate(flipped, caPublicKey: ca.publicKey, subject: device.publicKey), isNull);
      // Signed by the authority but naming another key as its signer: hosts
      // would check it against that key, so it is not the authority's.
      final parsed = SshCertificate.parse(blob);
      final tbs = parsed.toBeSigned;
      final renamed = Uint8List.fromList([
        ...tbs.sublist(0, tbs.length - 4 - parsed.signatureKey.length),
        ...lp(ed25519PublicBlob(other.publicKey)),
      ]);
      final resigned = Uint8List.fromList([...renamed, ...lp(ca.keyPair.sign(renamed).encode())]);
      expect(SshCertificate.parse(resigned).signatureKey, ed25519PublicBlob(other.publicKey));
      expect(await readTeamCertificate(resigned, caPublicKey: ca.publicKey, subject: device.publicKey), isNull);
      expect(
          await readTeamCertificate(Uint8List.fromList([...blob, 0]), caPublicKey: ca.publicKey, subject: device.publicKey),
          isNull);
      expect(await readTeamCertificate(Uint8List.fromList(utf8.encode('nope')), caPublicKey: ca.publicKey, subject: device.publicKey),
          isNull);
      // A host certificate from the same authority.
      final host = SshCertSigner.issue(
        params: SshCertIssueParams(
          subjectPublicKeyBlob: ed25519PublicBlob(device.publicKey),
          subjectAlgorithm: SshCertAlgorithm.ed25519,
          serial: 1,
          type: SshCertType.host,
          keyId: 'h',
          principals: const ['deploy'],
          validAfter: DateTime.utc(2026),
          validBefore: DateTime.utc(2027),
        ),
        caKey: ca.keyPair,
      );
      expect(await readTeamCertificate(host, caPublicKey: ca.publicKey, subject: device.publicKey), isNull);
    });

    test("forwarding only with the Crate's switches for it", () async {
      Future<Set<String>> extensions(Set<String> switches) async =>
          (await readTeamCertificate(issue(switches: switches), caPublicKey: ca.publicKey, subject: device.publicKey))!
              .extensions
              .keys
              .toSet();
      expect(await extensions({CrateSwitches.forward}), {'permit-pty', 'permit-user-rc', 'permit-port-forwarding'});
      expect(await extensions({CrateSwitches.agent}), {'permit-pty', 'permit-user-rc', 'permit-agent-forwarding'});
      expect(await extensions({CrateSwitches.connect, CrateSwitches.sftp}), {'permit-pty', 'permit-user-rc'});
    });

    test('a device key signs as the key it says it is', () async {
      final again = await TeamDeviceKey.fromSeed(device.seed);
      expect(again.publicKey, device.publicKey);
      final message = Uint8List.fromList(utf8.encode('login'));
      final signature = device.keyPair.sign(message).encode();
      expect(signature, again.keyPair.sign(message).encode());
      expect(() => TeamDeviceKey.fromSeed(Uint8List(31)), throwsFormatException);
      expect(randomCertSerial(), isNonNegative);
    });
  });
}
