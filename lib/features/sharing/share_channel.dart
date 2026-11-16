/// Session sharing (3.0): the secure channel of a live view, between the
/// person who shares a session (the host) and ONE viewer. Everything a live
/// view sends goes through the relay as frames of this channel, so the relay
/// carries bytes it can neither read nor make.
///
/// Key agreement, one per viewer and per join. Both halves are ephemeral:
///   * X25519. The host's public key is in the invitation, the viewer's in
///     its join.
///   * ML-KEM-768 (FIPS 203). The host's encapsulation key is in the
///     invitation; the viewer encapsulates to it and sends the ciphertext in
///     its join.
/// The two secrets are combined, so the channel is as strong as the STRONGER
/// of the two: a recording of the relay's traffic cannot be opened by a
/// future quantum computer that breaks X25519, nor by a break of ML-KEM
/// alone. Nothing long-lived encrypts the stream: once both sides drop the
/// ephemeral keys, a later theft of anyone's account keys opens nothing.
///
/// Who is on the other end is settled above this file (share_invitation.dart):
/// the invitation is signed by the host's account key and the join by the
/// viewer's, each checked against the key in the Orchard's signed record. The
/// hash of both signed messages, with a nonce the host makes fresh for every
/// join it accepts, is the salt of the key schedule, so a channel belongs to
/// exactly one invitation, one join and one acceptance. (The nonce is what
/// keeps a replayed join from producing the same keys twice, which would
/// reuse nonces.)
///
/// Key schedule:
///   secret = HKDF-SHA256(ikm = x25519 secret || ml-kem secret,
///                        salt = SHA-256(label || transcript || host nonce),
///                        info = label) -> 64 bytes
///   host-to-viewer key = first 32 bytes, viewer-to-host key = last 32.
///
/// Frames: ChaCha20-Poly1305. A frame is
///   counter (8 bytes, big endian) || ciphertext || tag (16 bytes)
/// with the nonce made of four zero bytes and the counter, and the label,
/// the share and the direction as associated data. Each direction has its
/// own key and its own counter from zero. A receiver takes exactly the next
/// counter and nothing else: the relay runs over an ordered, reliable
/// connection, so a gap, a repeat or a step back means someone changed the
/// stream, and the channel is finished (the viewer joins again, which makes
/// new keys and starts from a fresh picture of the screen).
///
/// Pure Dart: the `cryptography` package for X25519, HKDF and the AEAD, and
/// the ML-KEM-768 of zest_ssh_core (checked against the NIST vectors there).
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:zest_ssh_core/zest_ssh_core.dart' show MlKem768;
import 'package:zestssh/utils/type_name.dart';

/// Domain separation. Bump the suffix if the construction ever changes.
const String kShareChannelLabel = 'zestssh.share.channel.v1';

const int kShareX25519Length = 32;
const int kShareKemKeyLength = MlKem768.encapsulationKeySize; // 1184
const int kShareKemCiphertextLength = MlKem768.ciphertextSize; // 1088
const int kShareHostNonceLength = 32;

/// The most a frame may carry. The host cuts terminal output into frames of
/// at most this size; a receiver refuses a larger one before decrypting.
const int kShareFramePlainMax = 32 * 1024;

const int _counterLength = 8;
const int _tagLength = 16;

final X25519 _curve = X25519();
final Chacha20 _aead = Chacha20.poly1305Aead();

/// The channel can no longer be used: a frame was changed, repeated,
/// dropped or out of order, or the counter ran out.
class ShareChannelBroken implements Exception, HasTypeName {
  const ShareChannelBroken(this.reason);
  final String reason;

  @override
  String toString() => 'ShareChannelBroken: $reason';

  @override
  String get typeName => 'ShareChannelBroken';
}

Uint8List _randomBytes(Random random, int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = random.nextInt(256);
  }
  return out;
}

/// The host's half of the key agreement: what the invitation carries.
class ShareOffer {
  ShareOffer({required this.x25519Key, required this.kemKey}) {
    if (x25519Key.length != kShareX25519Length) {
      throw ArgumentError('the X25519 key must be 32 bytes');
    }
    if (kemKey.length != kShareKemKeyLength) {
      throw ArgumentError('the ML-KEM key must be $kShareKemKeyLength bytes');
    }
  }

  /// The host's ephemeral X25519 public key.
  final Uint8List x25519Key;

  /// The host's ephemeral ML-KEM-768 encapsulation key.
  final Uint8List kemKey;
}

/// The viewer's half: what its join carries.
class ShareJoin {
  ShareJoin({required this.x25519Key, required this.kemCiphertext}) {
    if (x25519Key.length != kShareX25519Length) {
      throw ArgumentError('the X25519 key must be 32 bytes');
    }
    if (kemCiphertext.length != kShareKemCiphertextLength) {
      throw ArgumentError(
          'the ML-KEM ciphertext must be $kShareKemCiphertextLength bytes');
    }
  }

  /// The viewer's ephemeral X25519 public key.
  final Uint8List x25519Key;

  /// The ML-KEM-768 ciphertext for the host's encapsulation key.
  final Uint8List kemCiphertext;
}

/// The host's side of the key agreement with one viewer. Made when the
/// viewer is invited; its private halves never leave memory and are dropped
/// with it when the share ends.
class ShareHostKeys {
  ShareHostKeys._(this._keyPair, this._kemSecret, this.offer);

  final SimpleKeyPair _keyPair;
  final Uint8List _kemSecret;

  /// What goes into the invitation.
  final ShareOffer offer;

  static Future<ShareHostKeys> generate({Random? random}) async {
    final rng = random ?? Random.secure();
    final x = await _curve.newKeyPairFromSeed(_randomBytes(rng, 32));
    final public = await x.extractPublicKey();
    final kem = MlKem768.keyGen((n) => _randomBytes(rng, n));
    return ShareHostKeys._(
      x,
      kem.dk,
      ShareOffer(
          x25519Key: Uint8List.fromList(public.bytes), kemKey: kem.ek),
    );
  }

  /// A nonce for one acceptance of a join. Never use one twice.
  static Uint8List newNonce({Random? random}) =>
      _randomBytes(random ?? Random.secure(), kShareHostNonceLength);

  /// The channel with the viewer who sent [join]. [transcript] is the hash
  /// of the signed invitation and the signed join; [hostNonce] is fresh for
  /// this acceptance and is sent to the viewer in the clear.
  ///
  /// A join that was not made for this invitation still yields a channel,
  /// with keys the other side does not have: nothing it sends will open.
  Future<ShareChannel> accept(
    ShareJoin join, {
    required String shareId,
    required List<int> transcript,
    required List<int> hostNonce,
  }) async {
    final classical = await _curve.sharedSecretKey(
      keyPair: _keyPair,
      remotePublicKey:
          SimplePublicKey(join.x25519Key, type: KeyPairType.x25519),
    );
    final postQuantum = MlKem768.decaps(_kemSecret, join.kemCiphertext);
    return ShareChannel._derive(
      classical: await classical.extractBytes(),
      postQuantum: postQuantum,
      shareId: shareId,
      transcript: transcript,
      hostNonce: hostNonce,
      host: true,
    );
  }
}

/// The viewer's side of the key agreement: made when it joins, from the
/// offer in the invitation.
class ShareViewerKeys {
  ShareViewerKeys._(this._classical, this._postQuantum, this.join);

  final List<int> _classical;
  final Uint8List _postQuantum;

  /// What the viewer sends to the host.
  final ShareJoin join;

  /// Throws [ArgumentError] when the offer's ML-KEM key is not a valid key,
  /// or its X25519 key is a point no honest host would send.
  static Future<ShareViewerKeys> generate(ShareOffer offer,
      {Random? random}) async {
    final rng = random ?? Random.secure();
    final x = await _curve.newKeyPairFromSeed(_randomBytes(rng, 32));
    final public = await x.extractPublicKey();
    final classical = await _curve.sharedSecretKey(
      keyPair: x,
      remotePublicKey:
          SimplePublicKey(offer.x25519Key, type: KeyPairType.x25519),
    );
    final secret = await classical.extractBytes();
    // Refused here, before anything is sent: see ShareChannel._derive.
    if (secret.every((b) => b == 0)) {
      throw ArgumentError('the X25519 key is not a valid public key');
    }
    final kem = MlKem768.encaps(offer.kemKey, (n) => _randomBytes(rng, n));
    return ShareViewerKeys._(
      secret,
      kem.sharedSecret,
      ShareJoin(
          x25519Key: Uint8List.fromList(public.bytes),
          kemCiphertext: kem.ciphertext),
    );
  }

  /// The channel, once the host has accepted with [hostNonce].
  Future<ShareChannel> complete({
    required String shareId,
    required List<int> transcript,
    required List<int> hostNonce,
  }) =>
      ShareChannel._derive(
        classical: _classical,
        postQuantum: _postQuantum,
        shareId: shareId,
        transcript: transcript,
        hostNonce: hostNonce,
        host: false,
      );
}

/// One end of the channel. [seal] makes the next frame to send; [open]
/// takes the next frame received.
class ShareChannel {
  ShareChannel._(this._sendKey, this._receiveKey, this._sendAad, this._receiveAad);

  final SecretKey _sendKey;
  final SecretKey _receiveKey;
  final List<int> _sendAad;
  final List<int> _receiveAad;

  int _sent = 0;
  int _received = 0;
  bool _broken = false;

  /// Frames sent and taken so far.
  int get sent => _sent;
  int get received => _received;
  bool get isBroken => _broken;

  static Future<ShareChannel> _derive({
    required List<int> classical,
    required List<int> postQuantum,
    required String shareId,
    required List<int> transcript,
    required List<int> hostNonce,
    required bool host,
  }) async {
    if (hostNonce.length != kShareHostNonceLength) {
      throw ArgumentError('the host nonce must be $kShareHostNonceLength bytes');
    }
    // An all-zero X25519 secret is what a low-order point gives: refuse it,
    // so the channel never rests on ML-KEM alone without anyone knowing.
    if (classical.every((b) => b == 0)) {
      throw ArgumentError('the X25519 key is not a valid public key');
    }
    final label = utf8.encode(kShareChannelLabel);
    final salt = hash.sha256.convert([
      ..._lp(label),
      ..._lp(utf8.encode(shareId)),
      ..._lp(transcript),
      ..._lp(hostNonce),
    ]).bytes;
    final okm = await Hkdf(hmac: Hmac.sha256(), outputLength: 64).deriveKey(
      secretKey: SecretKey([...classical, ...postQuantum]),
      nonce: salt,
      info: label,
    );
    final bytes = await okm.extractBytes();
    final hostToViewer = SecretKey(bytes.sublist(0, 32));
    final viewerToHost = SecretKey(bytes.sublist(32, 64));
    final share = utf8.encode(shareId);
    final down = [..._lp(label), ..._lp(share), 0x01];
    final up = [..._lp(label), ..._lp(share), 0x02];
    return host
        ? ShareChannel._(hostToViewer, viewerToHost, down, up)
        : ShareChannel._(viewerToHost, hostToViewer, up, down);
  }

  /// The next frame carrying [plaintext] (at most [kShareFramePlainMax]
  /// bytes).
  Future<Uint8List> seal(List<int> plaintext) async {
    if (_broken) throw const ShareChannelBroken('the channel is finished');
    if (plaintext.length > kShareFramePlainMax) {
      throw ArgumentError('a frame carries at most $kShareFramePlainMax bytes');
    }
    final counter = _sent;
    // Far beyond any session; a counter must never wrap under one key.
    if (counter >= 0x7fffffffffff) {
      _broken = true;
      throw const ShareChannelBroken('the counter ran out');
    }
    _sent = counter + 1;
    final box = await _aead.encrypt(
      plaintext,
      secretKey: _sendKey,
      nonce: _nonce(counter),
      aad: _sendAad,
    );
    final out = Uint8List(_counterLength + box.cipherText.length + _tagLength);
    ByteData.sublistView(out).setUint64(0, counter);
    out.setRange(_counterLength, _counterLength + box.cipherText.length,
        box.cipherText);
    out.setRange(_counterLength + box.cipherText.length, out.length,
        box.mac.bytes);
    return out;
  }

  /// The plaintext of [frame], which must be the next one. Anything else
  /// (a changed, repeated, skipped or oversized frame) finishes the channel
  /// and throws [ShareChannelBroken].
  Future<Uint8List> open(List<int> frame) async {
    if (_broken) throw const ShareChannelBroken('the channel is finished');
    if (frame.length < _counterLength + _tagLength ||
        frame.length > _counterLength + kShareFramePlainMax + _tagLength) {
      _broken = true;
      throw const ShareChannelBroken('a frame of the wrong size');
    }
    final bytes = frame is Uint8List ? frame : Uint8List.fromList(frame);
    final counter = ByteData.sublistView(bytes).getUint64(0);
    if (counter != _received) {
      _broken = true;
      throw const ShareChannelBroken('a frame out of order');
    }
    try {
      final clear = await _aead.decrypt(
        SecretBox(
          bytes.sublist(_counterLength, bytes.length - _tagLength),
          nonce: _nonce(counter),
          mac: Mac(bytes.sublist(bytes.length - _tagLength)),
        ),
        secretKey: _receiveKey,
        aad: _receiveAad,
      );
      _received = counter + 1;
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      _broken = true;
      throw const ShareChannelBroken('a frame that does not open');
    }
  }

  static List<int> _nonce(int counter) {
    final nonce = Uint8List(12);
    ByteData.sublistView(nonce).setUint64(4, counter);
    return nonce;
  }
}

/// [bytes] with its length in front (4 bytes, big endian), so fields put
/// side by side cannot run into each other.
List<int> _lp(List<int> bytes) {
  final length = ByteData(4)..setUint32(0, bytes.length);
  return [...length.buffer.asUint8List(), ...bytes];
}

/// The transcript of one key agreement: the hash of the signed invitation
/// and the signed join, exactly as they travelled.
Uint8List shareTranscript(List<int> signedInvitation, List<int> signedJoin) =>
    Uint8List.fromList(hash.sha256.convert([
      ..._lp(utf8.encode('zestssh.share.transcript.v1')),
      ..._lp(signedInvitation),
      ..._lp(signedJoin),
    ]).bytes);
