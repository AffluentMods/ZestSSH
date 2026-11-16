import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

/// Lower-case hex, both ways, for the fixed vectors below.
const hex = _Hex();

class _Hex {
  const _Hex();

  String encode(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  List<int> decode(String text) => [
        for (var i = 0; i < text.length; i += 2)
          int.parse(text.substring(i, i + 2), radix: 16),
      ];
}

/// Computed with Node's own Ed25519 and X25519 (the server's crypto), so the
/// app and the server provably agree on the keys, the signed bytes and the
/// fingerprint. Regenerate with scratchpad account_keys_vector.js.
const _edSeed =
    '0707070707070707070707070707070707070707070707070707070707070707';
const _xSeed =
    '0909090909090909090909090909090909090909090909090909090909090909';
const _edPub =
    'ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c';
const _xPub =
    '57db4b359f23ae5e146e4e2512056704722506348c150c14753d0c933d04d421';
const _message = '000000177a6573747373682e6163636f756e742d6b6579732e7631'
    '0000000a7569642d766563746f7200000001000000006ab13b800000002057db4b35'
    '9f23ae5e146e4e2512056704722506348c150c14753d0c933d04d42100000020ea4a'
    '6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c';
const _signature = 'a94b9450c694ef4446ca00eb5dec8f7eeeca2dc7be7cf45f7cc0b2e0'
    '3aa9f04abb157e38b256e0785ed210987228e2591b03e2630e84d44aaabac39759f40707';
const _fingerprint =
    'bbe0005b60b16b90496f5d840d45f821d0ee48bbd01afb27ecd211612d3bd356';

void main() {
  Future<AccountKeys> vectorKeys() => AccountKeys.fromSeeds(
        encryptionSeed: hex.decode(_xSeed),
        signingSeed: hex.decode(_edSeed),
        version: 1,
        createdAt: 1790000000,
      );

  group('matches the server byte for byte', () {
    test('the same seeds give the same public keys', () async {
      final keys = await vectorKeys();
      expect(hex.encode(keys.signingPublicKey), _edPub);
      expect(hex.encode(keys.encryption.publicKey), _xPub);
    });

    test('the signed bytes, the signature and the fingerprint', () async {
      final published = await (await vectorKeys()).publish('uid-vector');
      expect(hex.encode(published.signedMessage()), _message);
      // Ed25519 is deterministic, so the same key and bytes sign identically.
      expect(hex.encode(published.signature), _signature);
      expect(hex.encode(published.fingerprint), _fingerprint);
      expect(await published.verify(), isTrue);
    });
  });

  group('replacing keys (plan 7b item 3)', () {
    // Version 2 of the vector account: seeds 0x0b (Ed25519) / 0x0d (X25519),
    // created 1790000600. The server suite pins the same bytes
    // (ZestSSH Cloud's test/db/key_replacement_routes.test.js).
    Future<AccountKeys> nextKeys() => AccountKeys.fromSeeds(
          encryptionSeed: List.filled(32, 0x0d),
          signingSeed: List.filled(32, 0x0b),
          version: 2,
          createdAt: 1790000600,
        );

    test('the endorsement matches the server byte for byte', () async {
      final next = await (await nextKeys()).publish('uid-vector');
      expect(base64Encode(next.encryptionKey), 'sweuhmDvrtTWpl9mQIlokupKHwB1VVxInRMSouFnfCg=');
      expect(base64Encode(next.signingKey), 'Zr5+Myx6RTMyvZ0Kf32wVfXF7xoGraZtmLOftoEMRzo=');
      final message = accountKeysEndorsementMessage(1, next);
      expect(message.length, 168);
      expect(sha256.convert(message).toString(),
          '73285eb59a1efc3b484e8bffb057188c9f4f29faa3385a7895a1d81e27202f8e');
      final endorsement = await (await vectorKeys()).endorse(next);
      expect(base64Encode(endorsement),
          'VAAIyCmGvLtg+mqa1lOhCvwFU9KOrxHyqb3DNkmnIsvddNDW/qlSNhyWnlcBYcK5tjxh/twX7gnspeJG1pDvDw==');
    });

    test('a teammate accepts the change only when the previous key endorsed it', () async {
      final previous = await (await vectorKeys()).publish('uid-vector');
      final next = await (await nextKeys()).publish('uid-vector');
      final endorsement = await (await vectorKeys()).endorse(next);
      PublishedAccountKeys withEndorsement(Uint8List? e) => PublishedAccountKeys.fromJson(
          'uid-vector', {...next.toJson(), 'endorsement': e == null ? null : base64Encode(e)});

      expect(await withEndorsement(endorsement).endorsedBy(previous), isTrue);
      expect(await withEndorsement(null).endorsedBy(previous), isFalse,
          reason: 'no endorsement (every old copy of the key lost)');
      final forged = Uint8List.fromList(endorsement)..[0] ^= 1;
      expect(await withEndorsement(forged).endorsedBy(previous), isFalse);
      // Signed by the NEW key instead of the old one.
      final selfEndorsed = await (await nextKeys()).sign(accountKeysEndorsementMessage(1, next));
      expect(await withEndorsement(selfEndorsed).endorsedBy(previous), isFalse);
      // Another account's keys, or a skipped version, are never endorsed.
      final stranger = await (await vectorKeys()).publish('uid-other');
      expect(await withEndorsement(endorsement).endorsedBy(stranger), isFalse);
    });

    test('only the very next version can be endorsed', () async {
      final v3 = await (await AccountKeys.generate(version: 3)).publish('uid-vector');
      expect(() async => (await vectorKeys()).endorse(v3), throwsArgumentError);
    });
  });

  group('the self-signed bundle', () {
    test('fresh keys publish a bundle that verifies and matches them',
        () async {
      final keys = await AccountKeys.generate();
      final published = await keys.publish('uid-1');
      expect(await published.verify(), isTrue);
      expect(published.matches(keys), isTrue);
      expect(published.matches(await AccountKeys.generate()), isFalse);
    });

    test('changing any signed field breaks the signature', () async {
      final p = await (await AccountKeys.generate()).publish('uid-1');
      final other = await AccountKeys.generate();
      final variants = [
        PublishedAccountKeys(uid: 'uid-2', version: p.version,
            createdAt: p.createdAt, encryptionKey: p.encryptionKey,
            signingKey: p.signingKey, signature: p.signature),
        PublishedAccountKeys(uid: p.uid, version: p.version + 1,
            createdAt: p.createdAt, encryptionKey: p.encryptionKey,
            signingKey: p.signingKey, signature: p.signature),
        PublishedAccountKeys(uid: p.uid, version: p.version,
            createdAt: p.createdAt + 1, encryptionKey: p.encryptionKey,
            signingKey: p.signingKey, signature: p.signature),
        // A server swapping in someone else's encryption key.
        PublishedAccountKeys(uid: p.uid, version: p.version,
            createdAt: p.createdAt, encryptionKey: other.encryption.publicKey,
            signingKey: p.signingKey, signature: p.signature),
      ];
      for (final v in variants) {
        expect(await v.verify(), isFalse);
      }
    });

    test('the JSON the server stores round-trips', () async {
      final p = await (await AccountKeys.generate()).publish('uid-1');
      final back = PublishedAccountKeys.fromJson(
          'uid-1', jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(await back.verify(), isTrue);
      expect(back.fingerprint, p.fingerprint);
      expect(() => PublishedAccountKeys.fromJson('uid-1', {'key_version': 1}),
          throwsFormatException);
    });

    test('a malformed bundle does not verify instead of throwing', () async {
      final p = PublishedAccountKeys(
        uid: 'u',
        version: 1,
        createdAt: 0,
        encryptionKey: Uint8List(31),
        signingKey: Uint8List(32),
        signature: Uint8List(64),
      );
      expect(await p.verify(), isFalse);
    });
  });

  group('the private form', () {
    test('secret JSON round-trips to the same keys and signatures', () async {
      final keys = await AccountKeys.generate(version: 3);
      final json = jsonDecode(jsonEncode(await keys.toSecretJson()))
          as Map<String, dynamic>;
      final back = await AccountKeys.fromSecretJson(json);
      expect(back.version, 3);
      expect(back.createdAt, keys.createdAt);
      expect(back.signingPublicKey, keys.signingPublicKey);
      expect(back.encryption.publicKey, keys.encryption.publicKey);
      expect(await back.sign([1, 2, 3]), await keys.sign([1, 2, 3]));
    });

    test('malformed secret JSON is a FormatException', () async {
      for (final bad in <Map<String, dynamic>>[
        {},
        {'format': 2, 'version': 1, 'created_at': 1, 'x25519_seed': '', 'ed25519_seed': ''},
        {'format': 1, 'version': 1, 'created_at': 1, 'x25519_seed': base64Encode([1]), 'ed25519_seed': base64Encode(List.filled(32, 1))},
      ]) {
        await expectLater(
            AccountKeys.fromSecretJson(bad), throwsFormatException);
      }
    });
  });
}
