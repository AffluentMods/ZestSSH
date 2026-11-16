// An OpenSSH security key ("sk") key and its signatures (OpenSSH's
// PROTOCOL.u2f): sk-ssh-ed25519@openssh.com and
// sk-ecdsa-sha2-nistp256@openssh.com.
//
// The private half never leaves the security key. What a device keeps is
// the public key, the application it was made for ("ssh:" unless the
// person chose another), the key handle the security key is asked by, and
// the flags it was made with. A signature is the security key's own, with
// the flags and counter it reported, and it is checked here before it is
// sent to a server: for the right application, with a touch where the key
// asks for one, over the data that was to be signed, and by the public key
// this identity holds.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as c;
import 'package:pointycastle/export.dart';

import 'package:zestssh/services/fido/ctap2.dart';
import 'package:zestssh/utils/type_name.dart';

const String kSkEd25519 = 'sk-ssh-ed25519@openssh.com';
const String kSkEcdsa = 'sk-ecdsa-sha2-nistp256@openssh.com';

/// The flags an sk key is made with (OpenSSH's sk-api.h).
const int kSkUserPresenceRequired = 0x01;
const int kSkUserVerificationRequired = 0x04;
const int kSkResidentKey = 0x20;

/// The signature could not be used: [message] says why, for a log.
class SkSignatureError implements Exception, HasTypeName {
  const SkSignatureError(this.message);

  final String message;

  @override
  String toString() => 'Security key signature: $message';

  @override
  String get typeName => 'SkSignatureError';
}

Uint8List _sha256(List<int> data) => SHA256Digest().process(Uint8List.fromList(data));

/// SHA-256 of [data]: what a security key is given of what SSH asks to be
/// signed.
Uint8List sha256Of(List<int> data) => _sha256(data);

class _Writer {
  final BytesBuilder _out = BytesBuilder(copy: false);

  void u32(int n) => _out.add([(n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff]);

  void byte(int b) => _out.addByte(b);

  void string(List<int> bytes) {
    u32(bytes.length);
    _out.add(bytes);
  }

  /// A positive whole number as SSH writes one: no more leading zeros than
  /// the one that keeps it positive.
  void mpint(Uint8List magnitude) {
    var start = 0;
    while (start < magnitude.length && magnitude[start] == 0) {
      start++;
    }
    final body = magnitude.sublist(start);
    string(body.isNotEmpty && body[0] & 0x80 != 0 ? [0, ...body] : body);
  }

  Uint8List done() => _out.toBytes();
}

/// An sk key as a device holds it.
class SkKey {
  SkKey({
    required this.algorithm,
    required Uint8List publicKey,
    required this.application,
    required Uint8List keyHandle,
    required this.flags,
  })  : publicKey = Uint8List.fromList(publicKey),
        keyHandle = Uint8List.fromList(keyHandle) {
    if (algorithm == kSkEd25519) {
      if (publicKey.length != 32) throw ArgumentError('an Ed25519 public key is 32 bytes');
    } else if (algorithm == kSkEcdsa) {
      if (publicKey.length != 65 || publicKey[0] != 0x04) throw ArgumentError('a P-256 public key is 04, x, y');
    } else {
      throw ArgumentError('not a security key algorithm: $algorithm');
    }
    if (application.isEmpty) throw ArgumentError('an sk key has an application');
    if (keyHandle.isEmpty) throw ArgumentError('an sk key has a key handle');
  }

  /// From what a security key made ([made]) for [application], with [flags].
  factory SkKey.made(MadeCredential made, {required String application, required int flags}) {
    final key = made.publicKey;
    return SkKey(
      algorithm: key.alg == kCoseEdDsa ? kSkEd25519 : kSkEcdsa,
      publicKey: key.alg == kCoseEdDsa ? key.x : Uint8List.fromList([0x04, ...key.x, ...key.y!]),
      application: application,
      keyHandle: made.credentialId,
      flags: flags,
    );
  }

  final String algorithm;

  /// Ed25519: the 32 bytes. P-256: the point, uncompressed (04, x, y).
  final Uint8List publicKey;
  final String application;
  final Uint8List keyHandle;
  final int flags;

  bool get touchRequired => flags & kSkUserPresenceRequired != 0;
  bool get verifyRequired => flags & kSkUserVerificationRequired != 0;

  /// The public key as a server's authorized_keys holds it.
  Uint8List get publicBlob {
    final w = _Writer()..string(utf8.encode(algorithm));
    if (algorithm == kSkEcdsa) w.string(utf8.encode('nistp256'));
    w
      ..string(publicKey)
      ..string(utf8.encode(application));
    return w.done();
  }

  /// The line for authorized_keys.
  String authorizedKey([String comment = '']) =>
      '$algorithm ${base64.encode(publicBlob)}${comment.isEmpty ? '' : ' $comment'}';
}

/// The two numbers of an ECDSA signature in ASN.1 DER (a SEQUENCE of two
/// INTEGERs), as a security key gives one. Strict: definite short lengths,
/// nothing after, each number positive and at most 33 bytes.
(Uint8List r, Uint8List s) ecdsaNumbersOfDer(Uint8List der) {
  Never bad(String why) => throw SkSignatureError('an ECDSA signature that is not DER ($why)');
  if (der.length < 8 || der.length > 72) bad('its length');
  if (der[0] != 0x30) bad('no sequence');
  if (der[1] & 0x80 != 0 || der[1] != der.length - 2) bad('the sequence\'s length');
  var at = 2;
  Uint8List number() {
    if (at + 2 > der.length || der[at] != 0x02) bad('no integer');
    final length = der[at + 1];
    if (length == 0 || length > 33 || at + 2 + length > der.length) bad('an integer\'s length');
    final body = der.sublist(at + 2, at + 2 + length);
    if (body[0] & 0x80 != 0) bad('a negative number');
    if (length > 1 && body[0] == 0 && body[1] & 0x80 == 0) bad('a number with a zero too many');
    at += 2 + length;
    return body;
  }

  final r = number(), s = number();
  if (at != der.length) bad('bytes after the two numbers');
  return (r, s);
}

/// Checks what a security key answered ([assertion]) when asked to sign
/// [data] with [key], and gives the signature as SSH sends it. Throws
/// [SkSignatureError] where it is not this key's signature over this data
/// for this application: a wrong key held to the phone, a key that did not
/// wait for the touch it must, or anything a server would refuse.
Future<Uint8List> skSignature(SkKey key, Uint8List data, Assertion assertion) async {
  final auth = assertion.authData;
  final application = _sha256(utf8.encode(key.application));
  for (var i = 0; i < 32; i++) {
    if (auth.rpIdHash[i] != application[i]) throw const SkSignatureError('made for another application');
  }
  if (key.touchRequired && !auth.userPresent) throw const SkSignatureError('made without the touch this key asks for');
  if (key.verifyRequired && !auth.userVerified) {
    throw const SkSignatureError('made without the PIN or fingerprint this key asks for');
  }
  // OpenSSH signs over nothing more than the hash, the flags and the
  // counter: extensions or attested data in a signature are not for SSH.
  if (auth.rest.isNotEmpty || auth.flags & (AuthenticatorData.flagExtensions | AuthenticatorData.flagAttested) != 0) {
    throw const SkSignatureError('carries data SSH does not sign over');
  }
  final signed = Uint8List.fromList([...auth.raw, ..._sha256(data)]);
  final w = _Writer()..string(utf8.encode(key.algorithm));
  if (key.algorithm == kSkEd25519) {
    if (assertion.signature.length != 64) throw const SkSignatureError('an Ed25519 signature that is not 64 bytes');
    final ok = await c.Ed25519().verify(
      signed,
      signature: c.Signature(assertion.signature, publicKey: c.SimplePublicKey(key.publicKey, type: c.KeyPairType.ed25519)),
    );
    if (!ok) throw const SkSignatureError('does not verify with this identity\'s public key');
    w.string(assertion.signature);
  } else {
    final (r, s) = ecdsaNumbersOfDer(assertion.signature);
    final domain = ECCurve_secp256r1();
    final verifier = ECDSASigner(SHA256Digest())
      ..init(false, PublicKeyParameter<ECPublicKey>(ECPublicKey(domain.curve.decodePoint(key.publicKey), domain)));
    BigInt big(Uint8List b) => b.fold(BigInt.zero, (n, x) => (n << 8) | BigInt.from(x));
    if (!verifier.verifySignature(signed, ECSignature(big(r), big(s)))) {
      throw const SkSignatureError('does not verify with this identity\'s public key');
    }
    final inner = _Writer()
      ..mpint(r)
      ..mpint(s);
    w.string(inner.done());
  }
  w
    ..byte(auth.flags)
    ..u32(auth.counter);
  return w.done();
}

/// What a server checks an sk signature over ([data] is what SSH asked to
/// be signed): the application's hash, the flags, the counter, the data's
/// hash. For tests and for the software key that stands in for a real one.
Uint8List skSignedMessage(String application, int flags, int counter, Uint8List data) => Uint8List.fromList([
      ..._sha256(utf8.encode(application)),
      flags,
      (counter >> 24) & 0xff,
      (counter >> 16) & 0xff,
      (counter >> 8) & 0xff,
      counter & 0xff,
      ..._sha256(data),
    ]);
