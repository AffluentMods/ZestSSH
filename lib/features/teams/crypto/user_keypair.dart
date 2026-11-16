/// The X25519 half of an account's keys, and the two constructions Teams
/// builds on it (see the 2.0 Teams architecture memo, the design of record,
/// and account_keys.dart for the signing half and publishing):
///
///   * Sharing a key with a member is sealing it to that member's public key
///     with an anonymous sealed box (ephemeral X25519, HKDF-SHA256, then
///     AES-256-GCM). Adding a member is a single write that re-wraps nothing.
///   * Keeping a key under the account's own Data Encryption Key (the DEK) is
///     wrapping it with AES-256-GCM, so it inherits both of the DEK's recovery
///     paths, the sync password and the recovery key.
///
/// Every seal and every wrap is bound to what it is for. A seal names its
/// context (for example the Crate and generation a sealed key belongs to) and
/// a wrap names its purpose; both are authenticated, and the seal's context
/// also goes into the key derivation. Without that, two things sealed or
/// wrapped the same way would be interchangeable: a server holding both
/// could hand one out as the other and the decryption would still succeed.
/// The v1 constructions had exactly that flaw (one fixed label for anything
/// wrapped under the DEK) and never shipped.
///
/// Pure Dart on the `cryptography` package the sync layer already uses, with
/// no Flutter or app imports, so the constructions are testable in isolation.
///
/// Wire formats (all lengths in bytes):
///   sealed box: ephPublic(32) || nonce(12) || ciphertext || tag(16)
///   wrapped:    nonce(12) || ciphertext || tag(16)
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Domain-separation labels. Bump the version suffix if a construction ever
/// changes so old and new bytes can never be confused.
const String _sealLabel = 'zestssh.teams.sealedbox.v2';
const String _wrapLabel = 'zestssh.teams.dekwrap.v2';

const int _pubLen = 32;
const int _gcmNonceLen = 12;
const int _gcmMacLen = 16;
const int _maxLabelLen = 256;

final X25519 _x25519 = X25519();
final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
final AesGcm _aead = AesGcm.with256bits();

/// An X25519 keypair. Hold instances only transiently in memory; the private
/// half is persisted only as part of an account's keys (account_keys.dart).
class UserKeyPair {
  UserKeyPair._(this._keyPair, this.publicKey);

  final SimpleKeyPair _keyPair;

  /// The 32-byte X25519 public key. Safe to publish.
  final Uint8List publicKey;

  /// Generate a fresh keypair using the platform CSPRNG.
  static Future<UserKeyPair> generate() async {
    final kp = await _x25519.newKeyPair();
    final pub = await kp.extractPublicKey();
    return UserKeyPair._(kp, Uint8List.fromList(pub.bytes));
  }

  /// Reconstruct a keypair from its 32-byte private seed, as returned by
  /// [extractPrivateKeyBytes].
  static Future<UserKeyPair> fromPrivateKeyBytes(List<int> seed) async {
    if (seed.length != 32) {
      throw ArgumentError('X25519 private seed must be 32 bytes');
    }
    final kp = await _x25519.newKeyPairFromSeed(seed);
    final pub = await kp.extractPublicKey();
    return UserKeyPair._(kp, Uint8List.fromList(pub.bytes));
  }

  /// The raw 32-byte private seed: the value that must be protected.
  Future<Uint8List> extractPrivateKeyBytes() async {
    final data = await _keyPair.extractPrivateKeyBytes();
    return Uint8List.fromList(data);
  }
}

/// Seal [plaintext] to [recipientPublicKey] (a 32-byte X25519 public key) for
/// [context], so that only the holder of the matching private key can open
/// it, and only as that context. The sender is anonymous: a fresh ephemeral
/// keypair is used per call, so sealing the same bytes twice yields different
/// output and never reuses a key or nonce.
Future<Uint8List> sealTo(
  List<int> recipientPublicKey,
  List<int> plaintext, {
  required String context,
}) async {
  if (recipientPublicKey.length != _pubLen) {
    throw ArgumentError('recipient public key must be 32 bytes');
  }
  final contextBytes = _label(context, 'context');
  final ephemeral = await _x25519.newKeyPair();
  final ephemeralPublic = await ephemeral.extractPublicKey();
  final key = await _deriveSealKey(
    keyPair: ephemeral,
    remotePublicKey: recipientPublicKey,
    ephemeralPublic: ephemeralPublic.bytes,
    recipientPublic: recipientPublicKey,
    context: contextBytes,
  );
  final box = await _aead.encrypt(
    plaintext,
    secretKey: key,
    aad: _sealAad(contextBytes, recipientPublicKey),
  );
  return Uint8List.fromList([...ephemeralPublic.bytes, ...box.concatenation()]);
}

/// Open a sealed box produced by [sealTo] using the [recipient]'s keypair,
/// for the same [context] it was sealed for. Throws
/// [SecretBoxAuthenticationError] if the box was tampered with, was sealed to
/// a different key, or was sealed for a different context.
Future<Uint8List> openSealed(
  UserKeyPair recipient,
  List<int> sealed, {
  required String context,
}) async {
  final minLen = _pubLen + _gcmNonceLen + _gcmMacLen;
  if (sealed.length < minLen) {
    throw ArgumentError('sealed box is too short to be valid');
  }
  final contextBytes = _label(context, 'context');
  final ephemeralPublic = sealed.sublist(0, _pubLen);
  final boxBytes = sealed.sublist(_pubLen);
  final key = await _deriveSealKey(
    keyPair: recipient._keyPair,
    remotePublicKey: ephemeralPublic,
    ephemeralPublic: ephemeralPublic,
    recipientPublic: recipient.publicKey,
    context: contextBytes,
  );
  final box = SecretBox.fromConcatenation(
    boxBytes,
    nonceLength: _gcmNonceLen,
    macLength: _gcmMacLen,
  );
  final clear = await _aead.decrypt(
    box,
    secretKey: key,
    aad: _sealAad(contextBytes, recipient.publicKey),
  );
  return Uint8List.fromList(clear);
}

/// Encrypt [plaintext] under a raw 32-byte [dek] with AES-256-GCM, for
/// [purpose] (what the bytes are, for example a Crate key and its id). Output
/// layout is nonce(12) || ciphertext || tag(16).
Future<Uint8List> wrapUnderDek(
  List<int> plaintext,
  List<int> dek, {
  required String purpose,
}) async {
  _requireDek(dek);
  final box = await _aead.encrypt(
    plaintext,
    secretKey: SecretKey(dek),
    aad: _wrapAad(_label(purpose, 'purpose')),
  );
  return Uint8List.fromList(box.concatenation());
}

/// Reverse [wrapUnderDek] for the same [purpose]. Throws
/// [SecretBoxAuthenticationError] on a wrong DEK, a different purpose or
/// tampered bytes.
Future<Uint8List> unwrapUnderDek(
  List<int> wrapped,
  List<int> dek, {
  required String purpose,
}) async {
  _requireDek(dek);
  if (wrapped.length < _gcmNonceLen + _gcmMacLen) {
    throw ArgumentError('wrapped bytes are too short to be valid');
  }
  final box = SecretBox.fromConcatenation(
    wrapped,
    nonceLength: _gcmNonceLen,
    macLength: _gcmMacLen,
  );
  final clear = await _aead.decrypt(
    box,
    secretKey: SecretKey(dek),
    aad: _wrapAad(_label(purpose, 'purpose')),
  );
  return Uint8List.fromList(clear);
}

/// Derive the sealed-box key from an X25519 shared secret. Both public keys
/// go into the HKDF salt and the context into its info, so none of the three
/// can be swapped without changing the key.
Future<SecretKey> _deriveSealKey({
  required SimpleKeyPair keyPair,
  required List<int> remotePublicKey,
  required List<int> ephemeralPublic,
  required List<int> recipientPublic,
  required List<int> context,
}) async {
  final shared = await _x25519.sharedSecretKey(
    keyPair: keyPair,
    remotePublicKey: SimplePublicKey(remotePublicKey, type: KeyPairType.x25519),
  );
  // A degenerate public key (a low-order point) yields an all-zero shared
  // secret, which anyone could compute: sealing to it would protect nothing.
  final sharedBytes = await shared.extractBytes();
  if (sharedBytes.every((b) => b == 0)) {
    throw ArgumentError('not a usable X25519 public key');
  }
  return _hkdf.deriveKey(
    secretKey: shared,
    nonce: <int>[...ephemeralPublic, ...recipientPublic], // HKDF salt
    info: [..._lp(utf8.encode(_sealLabel)), ..._lp(context)],
  );
}

List<int> _sealAad(List<int> context, List<int> recipientPublic) => [
      ..._lp(utf8.encode(_sealLabel)),
      ..._lp(context),
      ..._lp(recipientPublic),
    ];

List<int> _wrapAad(List<int> purpose) => [
      ..._lp(utf8.encode(_wrapLabel)),
      ..._lp(purpose),
    ];

/// A non-empty, bounded label as UTF-8.
List<int> _label(String value, String what) {
  final bytes = utf8.encode(value);
  if (bytes.isEmpty || bytes.length > _maxLabelLen) {
    throw ArgumentError('$what must be 1 to $_maxLabelLen bytes');
  }
  return bytes;
}

/// Length-prefixed (uint32 big-endian) so adjacent fields can never run
/// into each other.
List<int> _lp(List<int> bytes) {
  final out = Uint8List(4 + bytes.length);
  ByteData.sublistView(out, 0, 4).setUint32(0, bytes.length);
  out.setRange(4, out.length, bytes);
  return out;
}

void _requireDek(List<int> dek) {
  if (dek.length != 32) {
    throw ArgumentError('DEK must be 32 bytes (256-bit)');
  }
}
