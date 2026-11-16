/// Trusted devices (3.0): this device's own signing key, and the
/// bytes it signs and commits to.
///
/// An Orchard can let its members in only from devices it approved. Which
/// devices are approved is in the Orchard's signed record
/// (orchard_record.dart, device.trust and device.revoke), where every device
/// checks it for itself; a device is known there by the public half of a
/// signing key made on that device, whose private half never leaves it: it
/// is kept in the system's secure storage, is not part of any sync and is in
/// no backup. One key for each account on each install.
///
/// With that key a device: says which of the account's sign-ins is its own
/// (signing the session's id), so ZestSSH Cloud can hold the rule for it;
/// signs for the approvals it makes (the record's entries); and signs its
/// requests for a certificate, which an owner's device then signs only for
/// a device the record lists. The bytes must match the server's
/// (ZestSSH Cloud's src/lib/orchard_devices.js); shared test vectors hold
/// them together.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/teams/crypto/fingerprint_words.dart';
import 'package:zestssh/services/secret_seal.dart';

const String kSessionDeviceLabel = 'zestssh.session-device.v1';
const String kDeviceTrustLabel = 'zestssh-device-trust-v1';
const String kDeviceTrustWordsLabel = 'zestssh-device-trust-words-v1';
const String kCertDeviceLabel = 'zestssh.cert-request.device.v1';
const String kDeviceCodeLabel = 'zestssh-device-code-v1';

/// How many words both screens show when a device is approved: one guess for
/// whoever sits between the two devices, 33 bits (as when a new device is
/// approved for an account).
const int kDeviceTrustWordCount = 3;

final Ed25519 _ed25519 = Ed25519();

/// What a device signs to say that the sign-in [sessionId] is its own.
Uint8List sessionDeviceMessage(String sessionId) =>
    Uint8List.fromList([..._lp(utf8.encode(kSessionDeviceLabel)), ..._lp(utf8.encode(sessionId))]);

/// What a device that asks to be approved commits to before it sees anything
/// of the other side: SHA-256 of the label, its key (32 bytes) and a random
/// value (32 bytes). Whoever passes the request along cannot swap the key
/// later without changing the words both devices show.
Uint8List deviceTrustCommitment(List<int> deviceKey, List<int> nonce) => Uint8List.fromList(
    crypto.sha256.convert([...utf8.encode(kDeviceTrustLabel), ...deviceKey, ...nonce]).bytes);

/// The words both devices show: from the Orchard, the member whose device
/// asks, what that device committed to, the approving device's random value,
/// and then what the asking device showed (its key and its random value).
///
/// The asking device commits first and shows its key only after the other
/// side answered, and the approving device answers before it sees the key:
/// someone in between who wants another key approved has to pick it before
/// either random value is known, which leaves one guess in 2^33 at making
/// the words match. Naming the Orchard and the member means a request passed
/// off as someone else's, or as another Orchard's, shows other words too.
List<String> deviceTrustWords({
  required String orchardId,
  required String uid,
  required List<int> commitment,
  required List<int> approverNonce,
  required List<int> deviceKey,
  required List<int> nonce,
}) {
  final digest = crypto.sha256.convert([
    ...utf8.encode(kDeviceTrustWordsLabel),
    ..._lp(utf8.encode(orchardId)),
    ..._lp(utf8.encode(uid)),
    ...commitment,
    ...approverNonce,
    ...deviceKey,
    ...nonce,
  ]);
  return fingerprintWords(digest.bytes, count: kDeviceTrustWordCount);
}

/// What a device signs under a certificate request: the very bytes the
/// account signs ([requestMessage], certRequestMessage in
/// team_certificates.dart), under the device's own label.
Uint8List certDeviceMessage(List<int> requestMessage) =>
    Uint8List.fromList([..._lp(utf8.encode(kCertDeviceLabel)), ..._lp(requestMessage)]);

/// Whether [signature] is the device [deviceKey]'s (32 bytes) over [message].
Future<bool> verifyDeviceSignature(List<int> deviceKey, List<int> message, List<int> signature) async {
  try {
    return await _ed25519.verify(
      message,
      signature: Signature(signature, publicKey: SimplePublicKey(deviceKey, type: KeyPairType.ed25519)),
    );
  } catch (_) {
    return false;
  }
}

/// A device's key as the record and the server write it: standard base64 of
/// its 32 bytes.
String deviceKeyText(List<int> publicKey) => base64Encode(publicKey);

/// The 32 bytes of the device key [text], or null when it is anything but
/// the one spelling of 32 bytes.
Uint8List? deviceKeyBytes(Object? text) {
  if (text is! String) return null;
  try {
    final bytes = base64Decode(text);
    return bytes.length == 32 && base64Encode(bytes) == text ? bytes : null;
  } on FormatException {
    return null;
  }
}

/// What people call the device whose key is [key] (as the record writes
/// it): eight characters made from the key, the same on every screen, so
/// that two people can tell which device they mean. It protects nothing:
/// what is approved or removed is always the whole key.
String deviceCode(String key) {
  final bytes = deviceKeyBytes(key) ?? utf8.encode(key);
  final digest = crypto.sha256.convert([...utf8.encode(kDeviceCodeLabel), ...bytes]).bytes;
  final hex = [for (final b in digest.take(4)) b.toRadixString(16).padLeft(2, '0')].join().toUpperCase();
  return '${hex.substring(0, 4)}-${hex.substring(4)}';
}

/// This device's signing key for one account.
class DeviceIdentity {
  DeviceIdentity._(this._pair, this.seed, this.publicKey);

  final SimpleKeyPair _pair;

  /// The 32-byte private seed: what the secure storage keeps.
  final Uint8List seed;

  /// The 32-byte public key: what the record lists.
  final Uint8List publicKey;

  /// [publicKey] as the record and the server write it.
  String get key => deviceKeyText(publicKey);

  static Future<DeviceIdentity> generate() async {
    final pair = await _ed25519.newKeyPair();
    return DeviceIdentity._(
      pair,
      Uint8List.fromList(await pair.extractPrivateKeyBytes()),
      Uint8List.fromList((await pair.extractPublicKey()).bytes),
    );
  }

  /// The key from its [seed], its public half worked out again.
  static Future<DeviceIdentity> fromSeed(List<int> seed) async {
    if (seed.length != 32) throw const FormatException('Not a device key');
    final pair = await _ed25519.newKeyPairFromSeed(seed);
    return DeviceIdentity._(pair, Uint8List.fromList(seed), Uint8List.fromList((await pair.extractPublicKey()).bytes));
  }

  Future<Uint8List> sign(List<int> message) async =>
      Uint8List.fromList((await _ed25519.sign(message, keyPair: _pair)).bytes);
}

/// Where a device keeps its key for each account: the system's secure
/// storage, under a name of its own for each account.
///
/// Sealed while the encrypting lock is on (SecretSeal; before, it
/// was kept as it was, so whatever read that storage could sign as this
/// device without the PIN).
class DeviceIdentityStore {
  DeviceIdentityStore(this._storage, {AppDatabase? Function()? tree}) : _tree = tree ?? (() => SecretSeal.openTree);

  final FlutterSecureStorage _storage;

  /// Your Tree's database, whose seal keeps the key; none while the app is
  /// locked.
  final AppDatabase? Function() _tree;

  /// The entry that holds the key of the account [uid].
  static String storageKey(String uid) => 'orchard_device_key_v1.$uid';

  final _loading = <String, Future<DeviceIdentity>>{};

  /// This device's key for [uid]: the one kept, or a new one, made and kept
  /// now. Asked twice at once, it is made once. A kept entry that does not
  /// read as a key is replaced: the device is then one nobody approved.
  Future<DeviceIdentity> forAccount(String uid) => _loading[uid] ??= _load(uid).whenComplete(() {
        // (Not `=> _loading.remove(uid)`: that hands back this very future,
        // which would then wait for itself.)
        _loading.remove(uid);
      });

  Future<DeviceIdentity> _load(String uid) async {
    final kept = await read(uid);
    if (kept != null) return kept;
    final made = await DeviceIdentity.generate();
    final slot = storageKey(uid);
    await _storage.write(key: slot, value: await keepSealed(_tree(), slot, base64Encode(made.seed)));
    return made;
  }

  /// The key kept for [uid], or null when there is none that reads as one.
  /// A sealed key while the app is locked throws [SecretSealBroken]: it is
  /// never taken for none and replaced. One that does not open with the
  /// database open (another database sealed it) is none, as one that does
  /// not read as a key.
  Future<DeviceIdentity?> read(String uid) async {
    final slot = storageKey(uid);
    final tree = _tree();
    final kept = await _storage.read(key: slot);
    final raw = tree == null ? await openKeptOrThrow(null, slot, kept) : await openKept(tree, slot, kept);
    if (raw == null) return null;
    try {
      return await DeviceIdentity.fromSeed(base64Decode(raw));
    } on FormatException {
      return null;
    }
  }

  /// Forgets the key of [uid]: this device is then a new one to every
  /// Orchard, and has to be approved again.
  Future<void> forget(String uid) => _storage.delete(key: storageKey(uid));
}

/// Length-prefixed (uint32 big-endian), so fields never run together.
List<int> _lp(List<int> bytes) => [
      (bytes.length >> 24) & 0xff,
      (bytes.length >> 16) & 0xff,
      (bytes.length >> 8) & 0xff,
      bytes.length & 0xff,
      ...bytes,
    ];
