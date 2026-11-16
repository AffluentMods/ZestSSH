import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/teams/crypto/user_keypair.dart';

/// The X25519 half of an account's keys, and the context-bound sealed box
/// and DEK wrap that Teams builds on.
void main() {
  Uint8List dek(int fill) => Uint8List.fromList(List.filled(32, fill));
  const crateA = 'crate-key|crate-a|gen-1';

  group('UserKeyPair', () {
    test('produces a 32-byte public key, distinct each time', () async {
      final a = await UserKeyPair.generate();
      final b = await UserKeyPair.generate();
      expect(a.publicKey.length, 32);
      expect(a.publicKey, isNot(equals(b.publicKey)));
    });

    test('a private seed round-trips to the same public key', () async {
      final kp = await UserKeyPair.generate();
      final seed = await kp.extractPrivateKeyBytes();
      expect(seed.length, 32);
      final restored = await UserKeyPair.fromPrivateKeyBytes(seed);
      expect(restored.publicKey, equals(kp.publicKey));
    });

    test('rejects a private seed of the wrong length', () async {
      expect(() => UserKeyPair.fromPrivateKeyBytes(List.filled(16, 0)),
          throwsArgumentError);
    });
  });

  group('sealed box', () {
    test('opens with the matching private key, for the same context',
        () async {
      final bob = await UserKeyPair.generate();
      final message = utf8.encode('crate-key-material');
      final sealed = await sealTo(bob.publicKey, message, context: crateA);
      expect(await openSealed(bob, sealed, context: crateA), message);
    });

    test('a key sealed for one Crate cannot be opened as another\'s',
        () async {
      // The server hands out a key sealed for Crate A as if it were Crate
      // B's: the context is bound, so it fails instead of confusing keys.
      final bob = await UserKeyPair.generate();
      final sealed =
          await sealTo(bob.publicKey, List.filled(32, 1), context: crateA);
      await expectLater(
        openSealed(bob, sealed, context: 'crate-key|crate-b|gen-1'),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      await expectLater(
        openSealed(bob, sealed, context: 'crate-key|crate-a|gen-2'),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('the layout is ephPublic(32) + nonce(12) + ciphertext + tag(16)',
        () async {
      final bob = await UserKeyPair.generate();
      final sealed = await sealTo(bob.publicKey, [1], context: crateA);
      expect(sealed.length, 32 + 12 + 1 + 16);
    });

    test('a different keypair cannot open the box', () async {
      final bob = await UserKeyPair.generate();
      final mallory = await UserKeyPair.generate();
      final sealed =
          await sealTo(bob.publicKey, utf8.encode('secret'), context: crateA);
      await expectLater(openSealed(mallory, sealed, context: crateA),
          throwsA(isA<SecretBoxAuthenticationError>()));
    });

    test('tampering with any byte is detected', () async {
      final bob = await UserKeyPair.generate();
      final sealed =
          await sealTo(bob.publicKey, utf8.encode('secret'), context: crateA);
      for (final i in [0, 32, sealed.length - 1]) {
        final tampered = Uint8List.fromList(sealed)..[i] ^= 0x01;
        await expectLater(
          openSealed(bob, tampered, context: crateA),
          throwsA(anyOf(
              isA<SecretBoxAuthenticationError>(), isA<ArgumentError>())),
          reason: 'flipping byte $i must not decrypt',
        );
      }
    });

    test('sealing the same plaintext twice yields different bytes', () async {
      final bob = await UserKeyPair.generate();
      final msg = utf8.encode('same-input');
      final a = await sealTo(bob.publicKey, msg, context: crateA);
      final b = await sealTo(bob.publicKey, msg, context: crateA);
      expect(a, isNot(equals(b)));
      expect(await openSealed(bob, a, context: crateA), msg);
      expect(await openSealed(bob, b, context: crateA), msg);
    });

    test('refuses a degenerate recipient key anyone could open for', () async {
      // The all-zero point makes the shared secret all zeros.
      await expectLater(
          sealTo(List.filled(32, 0), [1], context: crateA), throwsArgumentError);
    });

    test('rejects a bad recipient key or an empty context', () async {
      expect(() => sealTo(List.filled(16, 0), [1], context: crateA),
          throwsArgumentError);
      final bob = await UserKeyPair.generate();
      expect(() => sealTo(bob.publicKey, [1], context: ''),
          throwsArgumentError);
    });
  });

  group('wrapping under the DEK', () {
    test('wrap then unwrap round-trips, for the same purpose', () async {
      final secret = List.generate(32, (i) => i);
      final wrapped =
          await wrapUnderDek(secret, dek(0x11), purpose: 'crate-key|crate-a');
      expect(
          await unwrapUnderDek(wrapped, dek(0x11),
              purpose: 'crate-key|crate-a'),
          secret);
    });

    test('bytes wrapped for one purpose do not unwrap as another', () async {
      // The v1 flaw: one fixed label, so a wrapped private key and a wrapped
      // Crate key of the same size were interchangeable.
      final wrapped = await wrapUnderDek(List.filled(32, 5), dek(0x11),
          purpose: 'crate-key|crate-a');
      await expectLater(
        unwrapUnderDek(wrapped, dek(0x11), purpose: 'crate-key|crate-b'),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      await expectLater(
        unwrapUnderDek(wrapped, dek(0x11), purpose: 'account-private-key'),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('a wrong DEK or tampered bytes are refused', () async {
      final wrapped =
          await wrapUnderDek([1, 2, 3], dek(0x11), purpose: 'p');
      await expectLater(unwrapUnderDek(wrapped, dek(0x22), purpose: 'p'),
          throwsA(isA<SecretBoxAuthenticationError>()));
      final tampered = Uint8List.fromList(wrapped)..[wrapped.length - 1] ^= 1;
      await expectLater(unwrapUnderDek(tampered, dek(0x11), purpose: 'p'),
          throwsA(isA<SecretBoxAuthenticationError>()));
    });

    test('rejects a DEK that is not 32 bytes and an empty purpose', () async {
      expect(() => wrapUnderDek([1], List.filled(16, 0), purpose: 'p'),
          throwsArgumentError);
      expect(() => wrapUnderDek([1], dek(1), purpose: ''), throwsArgumentError);
    });

    test('wrapping is non-deterministic (fresh nonce per call)', () async {
      final a = await wrapUnderDek([1, 2], dek(0x11), purpose: 'p');
      final b = await wrapUnderDek([1, 2], dek(0x11), purpose: 'p');
      expect(a, isNot(equals(b)));
    });
  });

  test('end to end: Alice seals a Crate key to Bob, and only Bob opens it',
      () async {
    final bob = await UserKeyPair.generate();
    final crateKey = Uint8List.fromList(List.generate(32, (i) => i));
    final sealed = await sealTo(bob.publicKey, crateKey, context: crateA);

    // Bob, on another device, rebuilt from his synced private seed.
    final restored =
        await UserKeyPair.fromPrivateKeyBytes(await bob.extractPrivateKeyBytes());
    expect(await openSealed(restored, sealed, context: crateA), crateKey);
  });
}
