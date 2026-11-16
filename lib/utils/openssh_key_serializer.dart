import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart' as pc;

/// Serialises cryptographic keys to OpenSSH format.
///
/// This is the bridge between the key generation libraries (which
/// output raw bytes or pointycastle objects) and dartssh2 (which
/// loads keys via `SSHKeyPair.fromPem()`).
class OpenSSHKeySerializer {
  // ── Ed25519 ──────────────────────────────────────────────────────

  /// Encode an Ed25519 private key to OpenSSH PEM format.
  static String encodeEd25519Private(
      Uint8List privateBytes, Uint8List publicBytes,
      [String comment = 'zestssh-generated']) {
    // OpenSSH private key format:
    // "openssh-key-v1\0" magic
    // string ciphername = "none"
    // string kdfname = "none"
    // string kdfoptions = ""
    // uint32 number of keys = 1
    // string public key
    // string private key section (with checkints)

    final pubBlob = _buildEd25519PublicBlob(publicBytes);
    final privBlob =
        _buildEd25519PrivateBlob(privateBytes, publicBytes, comment);

    final buf = BytesBuilder();
    buf.add(utf8.encode('openssh-key-v1'));
    buf.addByte(0); // null terminator

    _writeString(buf, 'none'); // cipher
    _writeString(buf, 'none'); // kdf
    _writeString(buf, ''); // kdf options
    _writeUint32(buf, 1); // number of keys
    _writeBytes(buf, pubBlob); // public key
    _writeBytes(buf, privBlob); // private section

    return _wrapPem('OPENSSH PRIVATE KEY', base64Encode(buf.toBytes()), 70);
  }

  /// Encode an Ed25519 public key to OpenSSH authorized_keys format.
  static String encodeEd25519Public(Uint8List publicBytes,
      [String comment = 'zestssh-generated']) {
    final blob = _buildEd25519PublicBlob(publicBytes);
    return 'ssh-ed25519 ${base64Encode(blob)} $comment';
  }

  static Uint8List _buildEd25519PublicBlob(Uint8List publicBytes) {
    final buf = BytesBuilder();
    _writeString(buf, 'ssh-ed25519');
    _writeBytes(buf, publicBytes);
    return buf.toBytes();
  }

  static Uint8List _buildEd25519PrivateBlob(
      Uint8List privateBytes, Uint8List publicBytes,
      [String comment = 'zestssh-generated']) {
    final buf = BytesBuilder();

    // Two identical random check ints (for passphrase verification)
    final checkInt = Random.secure().nextInt(0x7FFFFFFF);
    _writeUint32(buf, checkInt);
    _writeUint32(buf, checkInt);

    _writeString(buf, 'ssh-ed25519');
    _writeBytes(buf, publicBytes);

    // Ed25519 private key is 64 bytes: 32 private + 32 public
    final fullPrivate = Uint8List(64);
    fullPrivate.setRange(0, 32, privateBytes);
    fullPrivate.setRange(32, 64, publicBytes);
    _writeBytes(buf, fullPrivate);

    _writeString(buf, comment); // comment

    // Pad to block size (8 bytes for "none" cipher)
    final padLength = 8 - (buf.length % 8);
    if (padLength < 8) {
      for (var i = 1; i <= padLength; i++) {
        buf.addByte(i);
      }
    }

    return buf.toBytes();
  }

  // ── RSA ──────────────────────────────────────────────────────────

  /// Encode an RSA private key to PEM (PKCS#1) format.
  static String encodeRsaPrivate(
      pc.RSAPublicKey publicKey, pc.RSAPrivateKey privateKey) {
    // Use PKCS#1 RSAPrivateKey ASN.1 structure
    final asn1 = ASN1Sequence();
    asn1.add(ASN1Integer(BigInt.zero)); // version
    asn1.add(ASN1Integer(privateKey.modulus!)); // n
    asn1.add(ASN1Integer(publicKey.publicExponent!)); // e
    asn1.add(ASN1Integer(privateKey.privateExponent!)); // d
    asn1.add(ASN1Integer(privateKey.p!)); // p
    asn1.add(ASN1Integer(privateKey.q!)); // q
    asn1.add(ASN1Integer(
        privateKey.privateExponent! % (privateKey.p! - BigInt.one))); // dp
    asn1.add(ASN1Integer(
        privateKey.privateExponent! % (privateKey.q! - BigInt.one))); // dq
    asn1.add(ASN1Integer(privateKey.q!.modInverse(privateKey.p!))); // qi

    return _wrapPem('RSA PRIVATE KEY', base64Encode(asn1.encode()));
  }

  /// Encode an RSA public key to OpenSSH authorized_keys format.
  static String encodeRsaPublic(pc.RSAPublicKey key,
      [String comment = 'zestssh-generated']) {
    final buf = BytesBuilder();
    _writeString(buf, 'ssh-rsa');
    _writeBigInt(buf, key.publicExponent!);
    _writeBigInt(buf, key.modulus!);
    return 'ssh-rsa ${base64Encode(buf.toBytes())} $comment';
  }

  // ── ECDSA ────────────────────────────────────────────────────────

  /// Map of curve name → SSH key type identifier.
  static const _ecdsaCurveNames = {
    'secp256r1': 'nistp256',
    'prime256v1': 'nistp256',
    'secp384r1': 'nistp384',
    'secp521r1': 'nistp521',
  };

  /// Encode an ECDSA private key to SEC1 PEM (for dartssh2 compatibility).
  ///
  /// dartssh2 can load ECDSA keys from SEC1 PEM format (-----BEGIN EC PRIVATE KEY-----).
  static String encodeEcdsaPrivate(
    pc.ECPublicKey publicKey,
    pc.ECPrivateKey privateKey,
    String curveName,
  ) {
    // SEC1 ECPrivateKey ASN.1:
    // SEQUENCE {
    //   INTEGER 1 (version)
    //   OCTET STRING (private key d)
    //   [0] OID (curve)
    //   [1] BIT STRING (public key Q)
    // }
    final curveOid = _curveOid(curveName);
    final point = publicKey.Q!;
    final qBytes = point.getEncoded(false); // uncompressed: 04 || x || y

    final dBytes = _bigIntToFixedBytes(
      privateKey.d!,
      _curveKeyLength(curveName),
    );

    final asn1 = ASN1Sequence();
    asn1.add(ASN1Integer(BigInt.one)); // version 1
    asn1.add(ASN1OctetString(octets: Uint8List.fromList(dBytes)));

    // [0] EXPLICIT tagged OID
    final oidSeq = ASN1Sequence(tag: 0xA0);
    oidSeq.add(ASN1ObjectIdentifier(curveOid));
    asn1.add(oidSeq);

    // [1] EXPLICIT tagged BIT STRING for public key
    final pubSeq = ASN1Sequence(tag: 0xA1);
    pubSeq.add(ASN1BitString(stringValues: Uint8List.fromList(qBytes)));
    asn1.add(pubSeq);

    return _wrapPem('EC PRIVATE KEY', base64Encode(asn1.encode()));
  }

  /// Encode an ECDSA public key to OpenSSH authorized_keys format.
  static String encodeEcdsaPublic(pc.ECPublicKey publicKey, String curveName,
      [String comment = 'zestssh-generated']) {
    final sshCurve = _ecdsaCurveNames[curveName] ?? curveName;
    final keyType = 'ecdsa-sha2-$sshCurve';
    final point = publicKey.Q!;
    final qBytes = point.getEncoded(false); // uncompressed

    final buf = BytesBuilder();
    _writeString(buf, keyType);
    _writeString(buf, sshCurve);
    _writeBytes(buf, Uint8List.fromList(qBytes));

    return '$keyType ${base64Encode(buf.toBytes())} $comment';
  }

  /// OID components for named curves.
  static List<int> _curveOid(String curveName) {
    switch (curveName) {
      case 'secp256r1':
      case 'prime256v1':
        return [1, 2, 840, 10045, 3, 1, 7]; // P-256
      case 'secp384r1':
        return [1, 3, 132, 0, 34]; // P-384
      case 'secp521r1':
        return [1, 3, 132, 0, 35]; // P-521
      default:
        throw ArgumentError('Unsupported curve: $curveName');
    }
  }

  /// Fixed byte length for curve private keys.
  static int _curveKeyLength(String curveName) {
    switch (curveName) {
      case 'secp256r1':
      case 'prime256v1':
        return 32;
      case 'secp384r1':
        return 48;
      case 'secp521r1':
        return 66;
      default:
        return 32;
    }
  }

  /// Convert BigInt to fixed-length byte array (left-pad with zeros).
  static Uint8List _bigIntToFixedBytes(BigInt value, int length) {
    final bytes = _bigIntToBytes(value);
    // Remove leading zero if present (SSH encoding adds one)
    final trimmed =
        (bytes.isNotEmpty && bytes[0] == 0) ? bytes.sublist(1) : bytes;
    if (trimmed.length >= length) return Uint8List.fromList(trimmed);
    // Left-pad with zeros
    final result = Uint8List(length);
    result.setRange(length - trimmed.length, length, trimmed);
    return result;
  }

  // ── Fingerprinting ───────────────────────────────────────────────

  /// Compute SHA-256 fingerprint from an OpenSSH public key string.
  static String fingerprintFromPublicKeyString(String publicKeyLine) {
    final parts = publicKeyLine.split(' ');
    if (parts.length < 2) return 'invalid';
    final blob = base64Decode(parts[1]);
    return fingerprintFromBlob(blob);
  }

  /// Compute SHA-256 fingerprint from raw public key blob bytes.
  static String fingerprintFromBlob(Uint8List blob) {
    final digest = pc.Digest('SHA-256');
    final hash = digest.process(blob);
    return 'SHA256:${base64Encode(hash).replaceAll('=', '')}';
  }

  // ── PEM helpers ─────────────────────────────────────────────────

  /// Wraps base64-encoded data in PEM armour with the given [label].
  ///
  /// [lineLength] defaults to 64 (PKCS standard); OpenSSH uses 70.
  static String _wrapPem(String label, String base64Data,
      [int lineLength = 64]) {
    final lines = <String>[];
    for (var i = 0; i < base64Data.length; i += lineLength) {
      final end = i + lineLength;
      lines.add(base64Data.substring(
          i, end > base64Data.length ? base64Data.length : end));
    }
    return '-----BEGIN $label-----\n'
        '${lines.join('\n')}\n'
        '-----END $label-----\n';
  }

  // ── Wire format helpers ──────────────────────────────────────────

  static void _writeUint32(BytesBuilder buf, int value) {
    buf.add([
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ]);
  }

  static void _writeString(BytesBuilder buf, String s) {
    final bytes = utf8.encode(s);
    _writeUint32(buf, bytes.length);
    buf.add(bytes);
  }

  static void _writeBytes(BytesBuilder buf, Uint8List bytes) {
    _writeUint32(buf, bytes.length);
    buf.add(bytes);
  }

  static void _writeBigInt(BytesBuilder buf, BigInt value) {
    final bytes = _bigIntToBytes(value);
    _writeBytes(buf, bytes);
  }

  static Uint8List _bigIntToBytes(BigInt value) {
    var hex = value.toRadixString(16);
    if (hex.length % 2 != 0) hex = '0$hex';
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    // Add leading zero if high bit is set (SSH encoding convention)
    if (bytes.isNotEmpty && bytes[0] > 127) {
      bytes.insert(0, 0);
    }
    return Uint8List.fromList(bytes);
  }
}
