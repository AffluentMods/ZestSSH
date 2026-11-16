// SPDX-License-Identifier: MIT
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zest_ssh_core/dartssh2.dart';

/// A security key's key file (OpenSSH's PROTOCOL.u2f: id_ed25519_sk,
/// id_ecdsa_sk). It holds the public key, the application, the flags and
/// the key handle, and no private key. Read and written here, sealed under
/// a passphrase or not, and held to OpenSSH's own reading: where there is
/// an ssh-keygen on this computer, it reads what is written here and gives
/// the same public key. (A file ssh-keygen itself wrote cannot be made for
/// a test without a security key to touch.)
void main() {
  final edPublic = Uint8List.fromList(List.generate(32, (i) => 0xa0 + i));
  // A point of P-256: its base point, uncompressed.
  final ecPublic = Uint8List.fromList([
    0x04,
    ..._hex('6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296'),
    ..._hex('4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5'),
  ]);
  final handle = Uint8List.fromList(List.generate(96, (i) => i));

  OpenSSHSkKeyPair ed({int flags = OpenSSHSkKeyPair.flagUserPresenceRequired, String application = 'ssh:'}) =>
      OpenSSHSkKeyPair(
        type: OpenSSHSkKeyPair.ed25519Type,
        publicKey: edPublic,
        application: application,
        flags: flags,
        keyHandle: handle,
        comment: 'alex@phone',
      );
  OpenSSHSkKeyPair ec() => OpenSSHSkKeyPair(
        type: OpenSSHSkKeyPair.ecdsaType,
        publicKey: ecPublic,
        application: 'ssh:work',
        flags: OpenSSHSkKeyPair.flagUserPresenceRequired | OpenSSHSkKeyPair.flagUserVerificationRequired,
        keyHandle: handle,
        comment: '',
      );

  group('a security key\'s key file', () {
    for (final (name, make) in [('Ed25519', ed), ('P-256', ec)]) {
      test('$name: written and read again, it is the same key, with everything a signer needs', () {
        final key = make();
        final pem = key.toPem();
        expect(pem, startsWith('-----BEGIN OPENSSH PRIVATE KEY-----'));
        final read = SSHKeyPair.fromPem(pem).single as OpenSSHSkKeyPair;
        expect(read.type, key.type);
        expect(read.name, key.type);
        expect(read.publicKey, key.publicKey);
        expect(read.application, key.application);
        expect(read.flags, key.flags);
        expect(read.keyHandle, handle);
        expect(read.reserved, isEmpty);
        expect(read.comment, key.comment);
        expect(read.touchRequired, isTrue);
        expect(read.verifyRequired, name == 'P-256');
        expect(read.toPublicKey().encode(), key.toPublicKey().encode());
      });

      test('$name: sealed under a passphrase, it opens with it and with nothing else', () {
        final pem = OpenSSHKeyFile.seal(OpenSSHKeyFile.open(make().toPem()), passphrase: 'correct horse', rounds: 4);
        expect(OpenSSHKeyPairs.decode(SSHPem.decode(pem).content).isEncrypted, isTrue);
        final read = SSHKeyPair.fromPem(pem, 'correct horse').single as OpenSSHSkKeyPair;
        expect(read.keyHandle, handle);
        expect(() => SSHKeyPair.fromPem(pem, 'wrong'), throwsA(isA<SSHKeyDecryptError>()));
        expect(() => SSHKeyPair.fromPem(pem), throwsA(isA<SSHKeyDecryptError>()));
      });
    }

    test('the public key is laid out as authorized_keys holds one', () {
      Uint8List str(List<int> b) => Uint8List.fromList([0, 0, 0, b.length, ...b]);
      expect(
        ed().toPublicKey().encode(),
        [...str('sk-ssh-ed25519@openssh.com'.codeUnits), ...str(edPublic), ...str('ssh:'.codeUnits)],
      );
      expect(
        ec().toPublicKey().encode(),
        [
          ...str('sk-ecdsa-sha2-nistp256@openssh.com'.codeUnits),
          ...str('nistp256'.codeUnits),
          ...str(ecPublic),
          ...str('ssh:work'.codeUnits),
        ],
      );
    });

    test('it cannot sign by itself, and says why', () async {
      expect(() => ed().sign(Uint8List(8)), throwsA(isA<SSHKeyOnSecurityKeyError>()));
      await expectLater(ed().signAsync(Uint8List(8)), throwsA(isA<SSHKeyOnSecurityKeyError>()));
      expect('${SSHKeyOnSecurityKeyError(OpenSSHSkKeyPair.ed25519Type)}', contains('security key'));
    });

    test('what is not a security key\'s key is refused', () {
      OpenSSHSkKeyPair bad({String? type, Uint8List? publicKey, String application = 'ssh:', Uint8List? keyHandle}) =>
          OpenSSHSkKeyPair(
            type: type ?? OpenSSHSkKeyPair.ed25519Type,
            publicKey: publicKey ?? edPublic,
            application: application,
            flags: 1,
            keyHandle: keyHandle ?? handle,
          );
      expect(() => bad(type: 'ssh-ed25519'), throwsA(isA<SSHKeyDecodeError>()));
      expect(() => bad(publicKey: Uint8List(31)), throwsA(isA<SSHKeyDecodeError>()));
      expect(() => bad(type: OpenSSHSkKeyPair.ecdsaType), throwsA(isA<SSHKeyDecodeError>()), reason: '32 bytes is no point');
      expect(() => bad(application: ''), throwsA(isA<SSHKeyDecodeError>()));
      expect(() => bad(keyHandle: Uint8List(0)), throwsA(isA<SSHKeyDecodeError>()));
      expect(OpenSSHSkKeyPair.isSkType('sk-ssh-ed25519@openssh.com'), isTrue);
      expect(OpenSSHSkKeyPair.isSkType('ssh-ed25519'), isFalse);
    });
  });

  group('OpenSSH itself', () {
    final sshKeygen = _which('ssh-keygen');

    for (final (name, make, passphrase) in [
      ('Ed25519', ed, null),
      ('P-256', ec, null),
      ('Ed25519 under a passphrase', ed, 'correct horse'),
    ]) {
      test('ssh-keygen reads the $name file written here and gives the same public key', () {
        final key = make();
        var pem = key.toPem();
        if (passphrase != null) pem = OpenSSHKeyFile.seal(OpenSSHKeyFile.open(pem), passphrase: passphrase);
        final dir = Directory.systemTemp.createTempSync('sk-key-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final file = File('${dir.path}/id_sk')..writeAsStringSync(pem);
        if (!Platform.isWindows) Process.runSync('chmod', ['600', file.path]);
        final r = Process.runSync(sshKeygen!, ['-y', '-P', passphrase ?? '', '-f', file.path]);
        expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
        final printed = '${r.stdout}'.trim().split(RegExp(r'\s+'));
        expect(printed[0], key.type);
        expect(printed[1], base64.encode(key.toPublicKey().encode()));
      }, skip: sshKeygen == null ? 'no ssh-keygen on this computer' : null);
    }
  });
}

List<int> _hex(String s) => [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

String? _which(String program) {
  try {
    final r = Process.runSync(Platform.isWindows ? 'where' : 'which', [program]);
    final first = '${r.stdout}'.trim().split('\n').first.trim();
    return r.exitCode == 0 && first.isNotEmpty ? first : null;
  } catch (_) {
    return null;
  }
}
