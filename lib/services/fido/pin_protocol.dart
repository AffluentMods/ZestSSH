// CTAP2's PIN/UV auth protocols one and two (CTAP 2.1, section 6.5): how a
// PIN reaches a security key without being sent, and how a request is then
// shown to come from whoever knew it.
//
// The platform and the key agree on a secret (ECDH on P-256, a fresh key
// pair of the platform's each time). The PIN's hash goes to the key
// encrypted under it; the key answers with a token, encrypted the same way,
// and a request that needs the PIN carries an HMAC made with that token.
// Neither the PIN nor its hash is kept here: both are the caller's to
// forget, and the token lives as long as the object the caller holds.
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

final ECDomainParameters _p256 = ECCurve_secp256r1();

SecureRandom _secureRandom() {
  final seed = Random.secure();
  return FortunaRandom()..seed(KeyParameter(Uint8List.fromList(List.generate(32, (_) => seed.nextInt(256)))));
}

Uint8List _sha256(List<int> data) => SHA256Digest().process(Uint8List.fromList(data));

Uint8List _hmac(Uint8List key, List<int> data) =>
    (HMac(SHA256Digest(), 64)..init(KeyParameter(key))).process(Uint8List.fromList(data));

Uint8List _aesCbc(bool encrypt, Uint8List key, Uint8List iv, Uint8List data) {
  if (data.length % 16 != 0) throw ArgumentError('not whole AES blocks');
  final cipher = CBCBlockCipher(AESEngine())..init(encrypt, ParametersWithIV(KeyParameter(key), iv));
  final out = Uint8List(data.length);
  for (var at = 0; at < data.length; at += 16) {
    cipher.processBlock(data, at, out, at);
  }
  return out;
}

Uint8List _fixed(BigInt n, int length) {
  final out = Uint8List(length);
  var v = n;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v >>= 8;
  }
  if (v != BigInt.zero) throw ArgumentError('a number longer than $length bytes');
  return out;
}

BigInt _big(Uint8List bytes) => bytes.fold(BigInt.zero, (n, b) => (n << 8) | BigInt.from(b));

/// A point of P-256 as CTAP2 writes one: its two coordinates, 32 bytes each.
typedef P256Point = ({Uint8List x, Uint8List y});

// P-256 (FIPS 186-4, D.1.2.3): the field's prime and the curve's b; a is p - 3.
final BigInt _p = BigInt.parse('ffffffff00000001000000000000000000000000ffffffffffffffffffffffff', radix: 16);
final BigInt _b = BigInt.parse('5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b', radix: 16);

/// Whether ([x], [y]) is a point of P-256: both inside the field, and on
/// y^2 = x^3 - 3x + b. (The point at infinity has no coordinates to give.)
bool isOnP256(BigInt x, BigInt y) {
  if (x < BigInt.zero || y < BigInt.zero || x >= _p || y >= _p) return false;
  return (y * y - (x * x * x - BigInt.from(3) * x + _b)) % _p == BigInt.zero;
}

/// The key's point as a public key, or an [ArgumentError] where it is not a
/// point of the curve (a key that sends another must not be agreed with).
ECPublicKey _publicKey(P256Point point) {
  if (point.x.length != 32 || point.y.length != 32) throw ArgumentError('a P-256 coordinate is 32 bytes');
  final x = _big(point.x), y = _big(point.y);
  if (!isOnP256(x, y)) throw ArgumentError('not a point of P-256');
  return ECPublicKey(_p256.curve.createPoint(x, y), _p256);
}

/// One agreement with a security key under PIN/UV auth protocol [version]
/// (1 or 2): made from the key's public point, it holds the platform's own
/// point to send and what encrypts and authenticates under the shared secret.
class PinProtocol {
  PinProtocol._(this.version, this.platformPoint, this._aesKey, this._hmacKey, this._random);

  /// Agrees with the key whose key agreement point is [authenticator].
  /// [random] and [platformPrivate] stand in for chance, in tests.
  factory PinProtocol.agree(int version, P256Point authenticator, {SecureRandom? random, BigInt? platformPrivate}) {
    if (version != 1 && version != 2) throw ArgumentError('PIN/UV auth protocol $version is not known');
    final rng = random ?? _secureRandom();
    final theirs = _publicKey(authenticator);
    final ECPrivateKey mine;
    final ECPublicKey minePublic;
    if (platformPrivate != null) {
      mine = ECPrivateKey(platformPrivate, _p256);
      minePublic = ECPublicKey(_p256.G * platformPrivate, _p256);
    } else {
      final pair = (ECKeyGenerator()..init(ParametersWithRandom(ECKeyGeneratorParameters(_p256), rng))).generateKeyPair();
      mine = pair.privateKey;
      minePublic = pair.publicKey;
    }
    final z = _fixed((ECDHBasicAgreement()..init(mine)).calculateAgreement(theirs), 32);
    final q = minePublic.Q!;
    final point = (x: _fixed(q.x!.toBigInteger()!, 32), y: _fixed(q.y!.toBigInteger()!, 32));
    if (version == 1) {
      // One key for both: SHA-256 of the shared x.
      final secret = _sha256(z);
      return PinProtocol._(1, point, secret, secret, rng);
    }
    Uint8List hkdf(String info) {
      final out = Uint8List(32);
      (HKDFKeyDerivator(SHA256Digest())..init(HkdfParameters(z, 32, Uint8List(32), Uint8List.fromList(info.codeUnits))))
          .deriveKey(null, 0, out, 0);
      return out;
    }

    return PinProtocol._(2, point, hkdf('CTAP2 AES key'), hkdf('CTAP2 HMAC key'), rng);
  }

  final int version;

  /// The platform's point of this agreement, sent to the key.
  final P256Point platformPoint;

  final Uint8List _aesKey;
  final Uint8List _hmacKey;
  final SecureRandom _random;

  /// [plain] (whole AES blocks) under the shared secret: with a zero IV in
  /// protocol one, with a random IV in front in protocol two.
  Uint8List encrypt(Uint8List plain) {
    if (version == 1) return _aesCbc(true, _aesKey, Uint8List(16), plain);
    final iv = _random.nextBytes(16);
    return Uint8List.fromList([...iv, ..._aesCbc(true, _aesKey, iv, plain)]);
  }

  /// What the key encrypted under the shared secret.
  Uint8List decrypt(Uint8List cipher) {
    if (version == 1) return _aesCbc(false, _aesKey, Uint8List(16), cipher);
    if (cipher.length < 32) throw ArgumentError('too short to hold an IV and a block');
    return _aesCbc(false, _aesKey, Uint8List.sublistView(cipher, 0, 16), Uint8List.sublistView(cipher, 16));
  }

  /// The HMAC of [message] under the shared secret (changing a PIN).
  Uint8List authenticate(List<int> message) => authenticateWith(_hmacKey, message);

  /// The HMAC of [message] under [key] (a PIN token, for a request): the
  /// first 16 bytes in protocol one, all 32 in protocol two.
  Uint8List authenticateWith(Uint8List key, List<int> message) {
    final mac = _hmac(key, message);
    return version == 1 ? Uint8List.sublistView(mac, 0, 16) : mac;
  }

  /// The PIN as it is sent to get a token: the first 16 bytes of its
  /// SHA-256, encrypted. The PIN is UTF-8, as the person typed it.
  Uint8List pinHashEnc(List<int> pinUtf8) => encrypt(Uint8List.sublistView(_sha256(pinUtf8), 0, 16));
}
