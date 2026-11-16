import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:pointycastle/export.dart' as pc;
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/openssh_key_serializer.dart';

/// Result of key generation.
class GeneratedKeyPair {
  /// PEM-encoded private key (OpenSSH format).
  final String privatePem;

  /// OpenSSH public key string (for authorized_keys).
  final String publicOpenSSH;

  /// SHA-256 fingerprint of the public key.
  final String fingerprint;

  /// The key type that was generated.
  final KeyType keyType;

  const GeneratedKeyPair({
    required this.privatePem,
    required this.publicOpenSSH,
    required this.fingerprint,
    required this.keyType,
  });
}

/// Generates SSH key pairs.
///
/// dartssh2 only *loads* keys via `SSHKeyPair.fromPem()` - it does not
/// generate them. This service bridges the `cryptography` package
/// (Ed25519) and `pointycastle` (RSA, ECDSA) with dartssh2.
class KeyGenerationService {
  /// Generate an Ed25519 key pair (recommended).
  Future<GeneratedKeyPair> generateEd25519({
    String comment = 'zestssh-generated',
  }) async {
    AppLogger.info('Generating Ed25519 key pair');
    final algorithm = crypto.Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final privateBytes = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();

    final privatePem = OpenSSHKeySerializer.encodeEd25519Private(
      Uint8List.fromList(privateBytes),
      Uint8List.fromList(publicKey.bytes),
      comment,
    );
    final publicOpenSSH = OpenSSHKeySerializer.encodeEd25519Public(
      Uint8List.fromList(publicKey.bytes),
      comment,
    );
    final fingerprint = OpenSSHKeySerializer.fingerprintFromPublicKeyString(
      publicOpenSSH,
    );

    AppLogger.info('Ed25519 key generated: $fingerprint');
    return GeneratedKeyPair(
      privatePem: privatePem,
      publicOpenSSH: publicOpenSSH,
      fingerprint: fingerprint,
      keyType: KeyType.ed25519,
    );
  }

  /// Generate an RSA key pair of the given bit length.
  ///
  /// Key generation is CPU-intensive (especially RSA-4096) so it runs
  /// in a background isolate to avoid blocking the UI thread.
  Future<GeneratedKeyPair> generateRsa(int bits, {
    String comment = 'zestssh-generated',
  }) async {
    final keyType = bits >= 4096 ? KeyType.rsa4096 : KeyType.rsa2048;
    AppLogger.info('Generating RSA-$bits key pair (background isolate)');

    final result = await Isolate.run(() {
      final secureRandom = _createSecureRandom();
      final keyGen = pc.KeyGenerator('RSA');
      keyGen.init(pc.ParametersWithRandom(
        pc.RSAKeyGeneratorParameters(BigInt.from(65537), bits, 64),
        secureRandom,
      ));

      final pair = keyGen.generateKeyPair();
      final rsaPublic = pair.publicKey as pc.RSAPublicKey;
      final rsaPrivate = pair.privateKey as pc.RSAPrivateKey;

      final privatePem =
          OpenSSHKeySerializer.encodeRsaPrivate(rsaPublic, rsaPrivate);
      final publicOpenSSH =
          OpenSSHKeySerializer.encodeRsaPublic(rsaPublic, comment);
      final fingerprint = OpenSSHKeySerializer.fingerprintFromPublicKeyString(
        publicOpenSSH,
      );

      return (privatePem: privatePem, publicOpenSSH: publicOpenSSH, fingerprint: fingerprint);
    });

    AppLogger.info('RSA-$bits key generated: ${result.fingerprint}');
    return GeneratedKeyPair(
      privatePem: result.privatePem,
      publicOpenSSH: result.publicOpenSSH,
      fingerprint: result.fingerprint,
      keyType: keyType,
    );
  }

  /// Generate an ECDSA key pair for the given curve.
  ///
  /// Runs in a background isolate to avoid blocking the UI thread.
  Future<GeneratedKeyPair> generateEcdsa(
      String curveName, KeyType keyType, {
    String comment = 'zestssh-generated',
  }) async {
    AppLogger.info('Generating ${keyType.displayName} key pair (background isolate)');

    final result = await Isolate.run(() {
      final secureRandom = _createSecureRandom();
      final domainParams = pc.ECDomainParameters(curveName);

      final keyGen = pc.KeyGenerator('EC');
      keyGen.init(pc.ParametersWithRandom(
        pc.ECKeyGeneratorParameters(domainParams),
        secureRandom,
      ));

      final pair = keyGen.generateKeyPair();
      final ecPublic = pair.publicKey as pc.ECPublicKey;
      final ecPrivate = pair.privateKey as pc.ECPrivateKey;

      final privatePem = OpenSSHKeySerializer.encodeEcdsaPrivate(
        ecPublic,
        ecPrivate,
        curveName,
      );
      final publicOpenSSH = OpenSSHKeySerializer.encodeEcdsaPublic(
        ecPublic,
        curveName,
        comment,
      );
      final fingerprint = OpenSSHKeySerializer.fingerprintFromPublicKeyString(
        publicOpenSSH,
      );

      return (privatePem: privatePem, publicOpenSSH: publicOpenSSH, fingerprint: fingerprint);
    });

    AppLogger.info('${keyType.displayName} key generated: ${result.fingerprint}');
    return GeneratedKeyPair(
      privatePem: result.privatePem,
      publicOpenSSH: result.publicOpenSSH,
      fingerprint: result.fingerprint,
      keyType: keyType,
    );
  }

  /// Generate key pair of the specified type.
  Future<GeneratedKeyPair> generate(KeyType type, {
    String comment = 'zestssh-generated',
  }) async {
    switch (type) {
      case KeyType.ed25519:
        return generateEd25519(comment: comment);
      case KeyType.rsa2048:
        return generateRsa(2048, comment: comment);
      case KeyType.rsa4096:
        return generateRsa(4096, comment: comment);
      case KeyType.ecdsaP256:
        return generateEcdsa('secp256r1', type, comment: comment);
      case KeyType.ecdsaP384:
        return generateEcdsa('secp384r1', type, comment: comment);
      case KeyType.ecdsaP521:
        return generateEcdsa('secp521r1', type, comment: comment);
      case KeyType.skEd25519:
      case KeyType.skEcdsaP256:
        // FIDO2 / hardware-token keys (sk-*) are *generated on the
        // hardware device itself*, not in software. The flow is:
        //   1. Plug in / pair the FIDO2 authenticator.
        //   2. Run `ssh-keygen -t ed25519-sk` (or use the
        //      "Connect via ssh-agent" flow), which talks CTAP2 to
        //      the device.
        //   3. Add the resulting key to the OS ssh-agent.
        //   4. Attach it as a ZestSSH identity from the keys view.
        // Trying to generate one in software would defeat the
        // hardware-binding guarantee, so we refuse here.
        throw UnsupportedError(
          'Hardware-token-resident keys (${type.sshName}) cannot be '
          'generated in software - they are created by the FIDO2 '
          'authenticator itself. Use `ssh-keygen -t ${type == KeyType.skEd25519 ? "ed25519-sk" : "ecdsa-sk"} '
          '-O resident -O application=ssh:` (or your hardware token\'s '
          'companion app), add the resulting key to the OS ssh-agent, '
          'then attach it via "Connect via ssh-agent" in the keys view.',
        );
    }
  }

}

/// Creates a cryptographically secure random number generator.
///
/// Top-level function so it can be called inside [Isolate.run] closures
/// (which cannot capture instance methods).
pc.SecureRandom _createSecureRandom() {
  final random = pc.FortunaRandom();
  final seed = Uint8List(32);
  final rng = Random.secure();
  for (var i = 0; i < 32; i++) {
    seed[i] = rng.nextInt(256);
  }
  random.seed(pc.KeyParameter(seed));
  return random;
}
