import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;
import 'package:zestssh/utils/openssh_key_serializer.dart';
import 'package:zestssh/utils/type_name.dart';

/// A PuTTY key that has a passphrase and was given none ([missing]), or the
/// wrong one: its integrity check, made with a key derived from the
/// passphrase, did not match (a damaged file fails the same way).
class PpkPassphraseError implements Exception, HasTypeName {
  const PpkPassphraseError({required this.missing});

  final bool missing;

  @override
  String toString() => missing
      ? 'PpkPassphraseError: this PuTTY key has a passphrase and none was given'
      : 'PpkPassphraseError: wrong passphrase for this PuTTY key (or the file is damaged)';

  @override
  String get typeName => 'PpkPassphraseError';
}

/// Converts PuTTY .ppk (v2/v3) format to OpenSSH PEM format.
///
/// Supports PPK v2 and v3 files for RSA and Ed25519 keys, with or without a
/// passphrase (AES-256-CBC; the key from SHA-1 in v2 and from Argon2 in v3).
class PpkConverter {
  /// Whether [ppkContent] is a PuTTY key that has a passphrase.
  static bool isEncrypted(String ppkContent) {
    for (final line in ppkContent.split('\n')) {
      final l = line.trim();
      if (l.startsWith('Encryption:')) return l.substring('Encryption:'.length).trim() != 'none';
      if (l.startsWith('Public-Lines:')) break;
    }
    return false;
  }

  /// The most memory (in KiB) and passes a key file may ask Argon2 for: a
  /// file is not trusted to make this device spend more than a real key
  /// would (PuTTYgen writes 8192 KiB and a few dozen passes at most).
  static const int maxArgon2MemoryKiB = 1024 * 1024;
  static const int maxArgon2Passes = 1000;
  static const int maxArgon2Parallelism = 64;

  /// Convert a PuTTY .ppk file to OpenSSH PEM format.
  ///
  /// Returns a PEM-formatted private key string compatible with
  /// `SSHKeyPair.fromPem()` from dartssh2.
  ///
  /// Throws [FormatException] if the format is invalid.
  /// Throws [PpkPassphraseError] if the key has a passphrase and [passphrase]
  /// is missing or wrong.
  static String toPem(String ppkContent, [String? passphrase]) {
    final lines = ppkContent.split('\n').map((l) => l.trim()).toList();

    // Parse header
    if (lines.isEmpty || !lines[0].startsWith('PuTTY-User-Key-File-')) {
      throw const FormatException('Not a valid PuTTY key file');
    }

    final version = lines[0].contains('-3:') ? 3 : 2;
    final keyType = lines[0].split(': ').last.trim();

    // Find encryption type
    final encLine = lines.firstWhere(
      (l) => l.startsWith('Encryption:'),
      orElse: () => 'Encryption: none',
    );
    final encryption = encLine.split(': ').last.trim();

    final encrypted = encryption != 'none';
    if (encrypted && encryption != 'aes256-cbc') {
      throw FormatException('Unsupported PPK encryption: $encryption');
    }
    if (encrypted && (passphrase == null || passphrase.isEmpty)) {
      throw const PpkPassphraseError(missing: true);
    }

    // Extract comment (used for Ed25519 PEM encoding)
    final commentLine = lines.firstWhere(
      (l) => l.startsWith('Comment:'),
      orElse: () => 'Comment: imported-ppk',
    );
    final comment = commentLine.substring('Comment:'.length).trim();

    // Extract public key blob
    final publicBlob = _extractSection(lines, 'Public-Lines');
    // Extract private key blob (still encrypted when the key has a passphrase)
    final storedPrivate = _extractSection(lines, 'Private-Lines');

    // Reject unsupported key types up front - before MAC verification - so an
    // unsupported .ppk yields a precise "unsupported type" message instead of
    // a generic integrity error. This is only a dispatch decision on an
    // as-yet-unverified header field: the MAC below still binds the key type
    // (any supported→supported or unsupported→supported tamper fails the MAC),
    // so gating the actual key MATERIAL on the MAC is unaffected.
    if (keyType != 'ssh-rsa' && keyType != 'ssh-ed25519') {
      throw FormatException(
        'Unsupported PPK key type: $keyType. '
        'Only ssh-rsa and ssh-ed25519 are supported.',
      );
    }

    // Verify the Private-MAC integrity field BEFORE trusting any of the key
    // material. Without this, an attacker who can tamper with a .ppk file (or
    // a corrupt file) could substitute a private key of their choosing; the
    // MAC binds algorithm/encryption/comment/public-blob/private-blob
    // together under a fixed key so any modification is detected.
    // A key with a passphrase: derive its cipher and MAC keys and decrypt the
    // private blob. The MAC is over the DECRYPTED blob, with a key that comes
    // from the passphrase, so a wrong passphrase fails it.
    final Uint8List privateBlob;
    Uint8List? macKey;
    if (encrypted) {
      final keys = version >= 3 ? _deriveV3(lines, passphrase!) : _deriveV2(passphrase!);
      if (storedPrivate.isEmpty || storedPrivate.length % 16 != 0) {
        throw const FormatException('The encrypted private key of this PPK file is not whole blocks');
      }
      privateBlob = _aesCbcDecrypt(keys.cipherKey, keys.iv, storedPrivate);
      macKey = keys.macKey;
    } else {
      privateBlob = storedPrivate;
    }
    try {
      _verifyMac(
        lines: lines,
        version: version,
        keyType: keyType,
        encryption: encryption,
        comment: comment,
        publicBlob: publicBlob,
        privateBlob: privateBlob,
        macKey: macKey,
      );
    } on FormatException {
      if (encrypted) throw const PpkPassphraseError(missing: false);
      rethrow;
    }

    // Convert based on key type
    switch (keyType) {
      case 'ssh-rsa':
        return _convertRsa(publicBlob, privateBlob);
      case 'ssh-ed25519':
        return _convertEd25519(publicBlob, privateBlob, comment);
      default:
        throw FormatException(
          'Unsupported PPK key type: $keyType. '
          'Only ssh-rsa and ssh-ed25519 are supported.',
        );
    }
  }

  // ── Keys with a passphrase ────────────────────────────────────────

  /// PPK v2: the cipher key is the first 32 bytes of SHA-1(0 ‖ passphrase)
  /// ‖ SHA-1(1 ‖ passphrase) with a zero IV; the MAC key is
  /// SHA-1("putty-private-key-file-mac-key" ‖ passphrase).
  static ({Uint8List cipherKey, Uint8List iv, Uint8List macKey}) _deriveV2(String passphrase) {
    final pass = Uint8List.fromList(utf8.encode(passphrase));
    Uint8List sha1(List<int> head) {
      final d = pc.SHA1Digest();
      final input = Uint8List.fromList([...head, ...pass]);
      d.update(input, 0, input.length);
      final out = Uint8List(d.digestSize);
      d.doFinal(out, 0);
      return out;
    }

    final cipherKey = Uint8List.fromList([...sha1(const [0, 0, 0, 0]), ...sha1(const [0, 0, 0, 1])].sublist(0, 32));
    return (
      cipherKey: cipherKey,
      iv: Uint8List(16),
      macKey: sha1(utf8.encode('putty-private-key-file-mac-key')),
    );
  }

  /// PPK v3: Argon2 (the flavour, memory, passes, parallelism and salt the
  /// file names) makes 80 bytes: the cipher key, the IV and the MAC key.
  static ({Uint8List cipherKey, Uint8List iv, Uint8List macKey}) _deriveV3(List<String> lines, String passphrase) {
    String field(String name) {
      final line = lines.firstWhere((l) => l.startsWith('$name:'), orElse: () => '');
      if (line.isEmpty) throw FormatException('PPK file is missing its $name field');
      return line.substring(name.length + 1).trim();
    }

    int number(String name, int most) {
      final n = int.tryParse(field(name));
      if (n == null || n < 1 || n > most) {
        throw FormatException('PPK file asks for an $name this device will not give: ${field(name)}');
      }
      return n;
    }

    final type = switch (field('Key-Derivation')) {
      'Argon2id' => pc.Argon2Parameters.ARGON2_id,
      'Argon2i' => pc.Argon2Parameters.ARGON2_i,
      'Argon2d' => pc.Argon2Parameters.ARGON2_d,
      final other => throw FormatException('Unsupported PPK key derivation: $other'),
    };
    final saltHex = field('Argon2-Salt');
    if (saltHex.isEmpty || saltHex.length.isOdd || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(saltHex)) {
      throw const FormatException('PPK file has a salt that is not hexadecimal');
    }
    final salt = Uint8List.fromList([
      for (var i = 0; i < saltHex.length; i += 2) int.parse(saltHex.substring(i, i + 2), radix: 16),
    ]);
    final generator = pc.Argon2BytesGenerator()
      ..init(pc.Argon2Parameters(
        type,
        salt,
        desiredKeyLength: 80,
        iterations: number('Argon2-Passes', maxArgon2Passes),
        memory: number('Argon2-Memory', maxArgon2MemoryKiB),
        lanes: number('Argon2-Parallelism', maxArgon2Parallelism),
        version: pc.Argon2Parameters.ARGON2_VERSION_13,
      ));
    final out = Uint8List(80);
    generator.deriveKey(Uint8List.fromList(utf8.encode(passphrase)), 0, out, 0);
    return (
      cipherKey: Uint8List.sublistView(out, 0, 32),
      iv: Uint8List.sublistView(out, 32, 48),
      macKey: Uint8List.sublistView(out, 48, 80),
    );
  }

  static Uint8List _aesCbcDecrypt(Uint8List key, Uint8List iv, Uint8List data) {
    final cipher = pc.CBCBlockCipher(pc.AESEngine())..init(false, pc.ParametersWithIV(pc.KeyParameter(key), iv));
    final out = Uint8List(data.length);
    for (var offset = 0; offset < data.length; offset += 16) {
      cipher.processBlock(data, offset, out, offset);
    }
    return out;
  }

  // ── Section parsing ──────────────────────────────────────────────

  /// Extract and decode a base64 section from PPK lines.
  ///
  /// PPK format uses e.g. "Public-Lines: 6" followed by 6 lines of
  /// base64-encoded data. This reads the line count, collects the
  /// subsequent lines, concatenates them, and base64-decodes.
  static Uint8List _extractSection(List<String> lines, String sectionName) {
    final headerPrefix = '$sectionName:';
    final headerIndex = lines.indexWhere((l) => l.startsWith(headerPrefix));
    if (headerIndex == -1) {
      throw FormatException('Missing $sectionName section in PPK file');
    }

    final lineCountStr = lines[headerIndex].substring(headerPrefix.length).trim();
    final lineCount = int.tryParse(lineCountStr);
    if (lineCount == null || lineCount <= 0) {
      throw FormatException('Invalid line count for $sectionName: $lineCountStr');
    }

    if (headerIndex + lineCount >= lines.length) {
      throw FormatException(
        'PPK file truncated: expected $lineCount lines after $sectionName header',
      );
    }

    final b64 = StringBuffer();
    for (var i = 1; i <= lineCount; i++) {
      b64.write(lines[headerIndex + i]);
    }

    try {
      return base64Decode(b64.toString());
    } catch (e) {
      throw FormatException('Invalid base64 in $sectionName section: $e');
    }
  }

  // ── MAC verification ─────────────────────────────────────────────

  /// Verify the PPK `Private-MAC` field over the canonical field encoding.
  ///
  /// PPK v2 uses HMAC-SHA-1 with a key of
  /// `SHA1("putty-private-key-file-mac-key")` (no passphrase appended for
  /// unencrypted keys). PPK v3 uses HMAC-SHA-256; for an *unencrypted* key
  /// the MAC key is empty. In both versions the MAC covers, in order, the
  /// SSH-string encodings of: algorithm name, encryption, comment, public
  /// blob, private blob.
  ///
  /// Only unencrypted keys reach here (encrypted keys are rejected earlier),
  /// so the private blob is already plaintext.
  static void _verifyMac({
    required List<String> lines,
    required int version,
    required String keyType,
    required String encryption,
    required String comment,
    required Uint8List publicBlob,
    required Uint8List privateBlob,
    Uint8List? macKey,
  }) {
    final macLine = lines.firstWhere(
      (l) => l.startsWith('Private-MAC:'),
      orElse: () => '',
    );
    if (macLine.isEmpty) {
      throw const FormatException(
        'PPK file is missing the Private-MAC integrity field',
      );
    }
    final expectedHex =
        macLine.substring('Private-MAC:'.length).trim().toLowerCase();

    // Canonical MAC data: five SSH strings (uint32-length-prefixed).
    final builder = BytesBuilder();
    void putString(Uint8List bytes) {
      builder.add([
        (bytes.length >> 24) & 0xff,
        (bytes.length >> 16) & 0xff,
        (bytes.length >> 8) & 0xff,
        bytes.length & 0xff,
      ]);
      builder.add(bytes);
    }

    putString(Uint8List.fromList(utf8.encode(keyType)));
    putString(Uint8List.fromList(utf8.encode(encryption)));
    putString(Uint8List.fromList(utf8.encode(comment)));
    putString(publicBlob);
    putString(privateBlob);
    final macData = builder.toBytes();

    final pc.Digest digest;
    final Uint8List key;
    if (version >= 3) {
      // v3: HMAC-SHA-256, with an empty key when the file has no passphrase.
      digest = pc.SHA256Digest();
      key = macKey ?? Uint8List(0);
    } else if (macKey != null) {
      // v2 with a passphrase: the key derived from it, HMAC-SHA-1.
      digest = pc.SHA1Digest();
      key = macKey;
    } else {
      // v2: key = SHA1("putty-private-key-file-mac-key"), HMAC-SHA-1.
      final sha1 = pc.SHA1Digest();
      final magic = utf8.encode('putty-private-key-file-mac-key');
      sha1.update(Uint8List.fromList(magic), 0, magic.length);
      key = Uint8List(sha1.digestSize);
      sha1.doFinal(key, 0);
      digest = pc.SHA1Digest();
    }

    final hmac = pc.HMac(digest, 64)..init(pc.KeyParameter(key));
    hmac.update(macData, 0, macData.length);
    final computed = Uint8List(hmac.macSize);
    hmac.doFinal(computed, 0);
    final computedHex = _toHex(computed);

    if (!_constantTimeHexEquals(computedHex, expectedHex)) {
      throw const FormatException(
        'PPK Private-MAC verification failed - the key file is corrupt or '
        'has been tampered with. Import aborted.',
      );
    }
  }

  static String _toHex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static bool _constantTimeHexEquals(String a, String b) {
    final ca = a.codeUnits;
    final cb = b.codeUnits;
    var diff = ca.length ^ cb.length;
    final n = ca.length < cb.length ? ca.length : cb.length;
    for (var i = 0; i < n; i++) {
      diff |= ca[i] ^ cb[i];
    }
    return diff == 0;
  }

  // ── RSA conversion ───────────────────────────────────────────────

  /// Convert RSA public + private blobs to PKCS#1 PEM.
  ///
  /// Public blob wire format:  string "ssh-rsa", mpint e, mpint n
  /// Private blob wire format: mpint d, mpint p, mpint q, mpint iqmp
  static String _convertRsa(Uint8List publicBlob, Uint8List privateBlob) {
    final pubReader = _SshWireReader(publicBlob);

    // Read and verify key type string
    final pubKeyType = pubReader.readString();
    if (pubKeyType != 'ssh-rsa') {
      throw FormatException(
        'Public key type mismatch: expected ssh-rsa, got $pubKeyType',
      );
    }

    final e = pubReader.readMpint();
    final n = pubReader.readMpint();

    final privReader = _SshWireReader(privateBlob);
    final d = privReader.readMpint();
    final p = privReader.readMpint();
    final q = privReader.readMpint();
    // iqmp is present in PPK but we recompute dp, dq, qi for PKCS#1
    privReader.readMpint(); // iqmp - read but not used directly

    // Cross-check that the private factors actually reproduce the public
    // modulus (cheap derived-public-key check for RSA). The MAC already
    // guards tampering, but this catches an internally inconsistent file.
    if (p * q != n) {
      throw const FormatException(
        'PPK RSA key is inconsistent: modulus n != p * q',
      );
    }

    // Reconstruct pointycastle RSA key objects
    final publicKey = pc.RSAPublicKey(n, e);
    final privateKey = pc.RSAPrivateKey(n, d, p, q);

    // Use OpenSSHKeySerializer to produce PKCS#1 PEM
    return OpenSSHKeySerializer.encodeRsaPrivate(publicKey, privateKey);
  }

  // ── Ed25519 conversion ───────────────────────────────────────────

  /// Convert Ed25519 public + private blobs to OpenSSH PEM.
  ///
  /// Public blob wire format:  string "ssh-ed25519", string pubkey(32)
  /// Private blob wire format: string privkey(64), string comment
  ///   (where privkey is 32-byte seed ∥ 32-byte public key)
  ///
  /// Note: PPK v2 Ed25519 private blob contains:
  ///   string pubkey_bytes(32), string privkey_bytes(64), string comment
  /// But some implementations just store the raw 64-byte key.
  /// We handle both by extracting the 32-byte seed.
  static String _convertEd25519(
    Uint8List publicBlob,
    Uint8List privateBlob,
    String comment,
  ) {
    final pubReader = _SshWireReader(publicBlob);

    // Read and verify key type string
    final pubKeyType = pubReader.readString();
    if (pubKeyType != 'ssh-ed25519') {
      throw FormatException(
        'Public key type mismatch: expected ssh-ed25519, got $pubKeyType',
      );
    }

    final publicKeyBytes = pubReader.readBytes();
    if (publicKeyBytes.length != 32) {
      throw FormatException(
        'Invalid Ed25519 public key length: ${publicKeyBytes.length} (expected 32)',
      );
    }

    // Parse private blob
    // PPK Ed25519 private blob is just the raw 64-byte private key
    // (32 seed + 32 public) without SSH wire framing, OR it may be
    // wire-formatted with length prefix.
    Uint8List privateKeyBytes;
    if (privateBlob.length == 64) {
      // Raw 64-byte key: first 32 bytes are the seed
      privateKeyBytes = Uint8List.sublistView(privateBlob, 0, 32);
    } else {
      // SSH wire format: read as string/bytes
      final privReader = _SshWireReader(privateBlob);
      final privData = privReader.readBytes();
      if (privData.length == 64) {
        // 64 bytes: seed(32) + pubkey(32)
        privateKeyBytes = Uint8List.sublistView(privData, 0, 32);
      } else if (privData.length == 32) {
        // Just the seed
        privateKeyBytes = privData;
      } else {
        throw FormatException(
          'Invalid Ed25519 private key length: ${privData.length}',
        );
      }
    }

    // Use OpenSSHKeySerializer to produce OpenSSH PEM
    return OpenSSHKeySerializer.encodeEd25519Private(
      privateKeyBytes,
      publicKeyBytes,
    );
  }
}

// ── SSH wire format reader ───────────────────────────────────────────

/// Reads values from SSH wire-format binary data.
///
/// SSH wire format uses big-endian uint32 length prefixes for strings
/// and byte arrays. MPInts are stored as length-prefixed big-endian
/// byte arrays with an optional leading zero byte for positive numbers
/// with the high bit set.
class _SshWireReader {
  final Uint8List _data;
  int _offset = 0;

  _SshWireReader(this._data);

  /// Read a uint32 (big-endian).
  int readUint32() {
    if (_offset + 4 > _data.length) {
      throw const FormatException('Unexpected end of SSH wire data (uint32)');
    }
    final value = (_data[_offset] << 24) |
        (_data[_offset + 1] << 16) |
        (_data[_offset + 2] << 8) |
        _data[_offset + 3];
    _offset += 4;
    return value;
  }

  /// Read a length-prefixed string.
  String readString() {
    final bytes = readBytes();
    return utf8.decode(bytes);
  }

  /// Read a length-prefixed byte array.
  Uint8List readBytes() {
    final length = readUint32();
    if (length < 0 || _offset + length > _data.length) {
      throw FormatException(
        'Unexpected end of SSH wire data (bytes: length=$length, '
        'offset=$_offset, total=${_data.length})',
      );
    }
    final bytes = Uint8List.sublistView(_data, _offset, _offset + length);
    _offset += length;
    return bytes;
  }

  /// Read a length-prefixed mpint as a [BigInt].
  ///
  /// SSH mpints are stored as big-endian byte arrays. A leading zero byte
  /// is used to indicate a positive number when the high bit would
  /// otherwise be set.
  BigInt readMpint() {
    final bytes = readBytes();
    if (bytes.isEmpty) return BigInt.zero;

    // Convert big-endian bytes to BigInt
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }

  /// Whether there is more data to read.
  bool get hasMore => _offset < _data.length;
}
