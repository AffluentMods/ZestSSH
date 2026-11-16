/// An account's own keys (3.0): one X25519 key to receive
/// keys sealed to it, one Ed25519 key to sign with. Generated on a device,
/// kept in the OS secure storage there, and carried to the account's other
/// devices inside the end-to-end-encrypted sync payload, exactly like SSH
/// private keys, so they are protected by the account's Data Encryption Key
/// and recoverable through both of its recovery paths.
///
/// The public halves are published to ZestSSH Cloud in a self-signed bundle
/// (see [PublishedAccountKeys]): the Ed25519 key signs the account id, the key
/// version, the creation time and both public keys, which binds the X25519
/// key to the signing key and the pair to the account. Whether the signing
/// key really belongs to that person is what member fingerprints settle;
/// the signature alone only proves one holder made the bundle.
///
/// Pure Dart on the `cryptography` package, no Flutter or app imports.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:zestssh/features/teams/crypto/user_keypair.dart';

/// Labels of the signed bundle and of the fingerprint. The server checks the
/// same bytes (ZestSSH Cloud's src/lib/account_keys.js).
const String kAccountKeysLabel = 'zestssh.account-keys.v1';
const String kAccountKeysFingerprintLabel =
    'zestssh.account-keys.fingerprint.v1';

/// Label of an endorsement: an account's key vouching for its next keys when
/// they replace it (3.0; teammates check it).
const String kAccountKeysEndorseLabel = 'zestssh.account-keys.endorse.v1';

final Ed25519 _ed25519 = Ed25519();

/// Both of an account's private keys. Hold instances only transiently.
class AccountKeys {
  AccountKeys._({
    required this.encryption,
    required SimpleKeyPair signing,
    required this.signingPublicKey,
    required this.version,
    required this.createdAt,
  }) : _signing = signing;

  /// Receives keys sealed to this account.
  final UserKeyPair encryption;

  final SimpleKeyPair _signing;

  /// The 32-byte Ed25519 public key.
  final Uint8List signingPublicKey;

  /// 1 for an account's first keys, one more for each replacement.
  final int version;

  /// When the keys were made, in whole seconds since the epoch. Signed.
  final int createdAt;

  /// Fresh keys from the platform CSPRNG.
  static Future<AccountKeys> generate({int version = 1, DateTime? now}) async {
    final encryption = await UserKeyPair.generate();
    final signing = await _ed25519.newKeyPair();
    final signingPublic = await signing.extractPublicKey();
    return AccountKeys._(
      encryption: encryption,
      signing: signing,
      signingPublicKey: Uint8List.fromList(signingPublic.bytes),
      version: version,
      createdAt: (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000,
    );
  }

  /// Keys rebuilt from their two 32-byte private seeds.
  static Future<AccountKeys> fromSeeds({
    required List<int> encryptionSeed,
    required List<int> signingSeed,
    required int version,
    required int createdAt,
  }) async {
    if (signingSeed.length != 32) {
      throw ArgumentError('Ed25519 seed must be 32 bytes');
    }
    if (version < 1 || createdAt < 0) {
      throw ArgumentError('invalid key version or creation time');
    }
    final encryption = await UserKeyPair.fromPrivateKeyBytes(encryptionSeed);
    final signing = await _ed25519.newKeyPairFromSeed(signingSeed);
    final signingPublic = await signing.extractPublicKey();
    return AccountKeys._(
      encryption: encryption,
      signing: signing,
      signingPublicKey: Uint8List.fromList(signingPublic.bytes),
      version: version,
      createdAt: createdAt,
    );
  }

  /// The private form kept in secure storage and in the sync payload.
  Future<Map<String, dynamic>> toSecretJson() async => {
        'format': 1,
        'version': version,
        'created_at': createdAt,
        'x25519_seed': base64Encode(await encryption.extractPrivateKeyBytes()),
        'ed25519_seed':
            base64Encode(await _signing.extractPrivateKeyBytes()),
      };

  /// Reverse [toSecretJson]. Throws FormatException on anything malformed.
  static Future<AccountKeys> fromSecretJson(Map<String, dynamic> json) async {
    final format = json['format'];
    final version = json['version'];
    final createdAt = json['created_at'];
    final x = json['x25519_seed'];
    final ed = json['ed25519_seed'];
    if (format != 1 ||
        version is! int ||
        createdAt is! int ||
        x is! String ||
        ed is! String) {
      throw const FormatException('Not a stored set of account keys');
    }
    try {
      return await fromSeeds(
        encryptionSeed: base64Decode(x),
        signingSeed: base64Decode(ed),
        version: version,
        createdAt: createdAt,
      );
    } on ArgumentError catch (e) {
      throw FormatException('Stored account keys are invalid: ${e.message}');
    }
  }

  /// An Ed25519 signature (64 bytes) over [message].
  Future<Uint8List> sign(List<int> message) async {
    final signature = await _ed25519.sign(message, keyPair: _signing);
    return Uint8List.fromList(signature.bytes);
  }

  /// This key's endorsement of [next], the same account's next keys: what
  /// tells a teammate who trusted this key that the new one is genuine.
  Future<Uint8List> endorse(PublishedAccountKeys next) {
    if (next.version != version + 1) {
      throw ArgumentError('Only the next version of the keys can be endorsed');
    }
    return sign(accountKeysEndorsementMessage(version, next));
  }

  /// The self-signed public bundle for the account [uid].
  Future<PublishedAccountKeys> publish(String uid) async {
    final message = accountKeysMessage(
      uid: uid,
      version: version,
      createdAt: createdAt,
      encryptionKey: encryption.publicKey,
      signingKey: signingPublicKey,
    );
    return PublishedAccountKeys(
      uid: uid,
      version: version,
      createdAt: createdAt,
      encryptionKey: encryption.publicKey,
      signingKey: signingPublicKey,
      signature: await sign(message),
    );
  }
}

/// The public, self-signed form of an account's keys, as ZestSSH Cloud
/// stores and serves it.
class PublishedAccountKeys {
  const PublishedAccountKeys({
    required this.uid,
    required this.version,
    required this.createdAt,
    required this.encryptionKey,
    required this.signingKey,
    required this.signature,
    this.endorsement,
  });

  final String uid;
  final int version;
  final int createdAt;

  /// The previous keys' endorsement of these, when they replaced keys that a
  /// device still held; null for an account's first keys or when none could
  /// be made.
  final Uint8List? endorsement;

  /// The X25519 public key (32 bytes).
  final Uint8List encryptionKey;

  /// The Ed25519 public key (32 bytes).
  final Uint8List signingKey;

  /// The Ed25519 signature (64 bytes) over [signedMessage].
  final Uint8List signature;

  Uint8List signedMessage() => accountKeysMessage(
        uid: uid,
        version: version,
        createdAt: createdAt,
        encryptionKey: encryptionKey,
        signingKey: signingKey,
      );

  /// Whether [signature] is a valid signature by [signingKey].
  Future<bool> verify() async {
    if (signingKey.length != 32 ||
        encryptionKey.length != 32 ||
        signature.length != 64) {
      return false;
    }
    return _ed25519.verify(
      signedMessage(),
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(signingKey, type: KeyPairType.ed25519),
      ),
    );
  }

  /// Whether [endorsement] is [previous]'s signature over these keys, which
  /// must be the same account's very next version.
  Future<bool> endorsedBy(PublishedAccountKeys previous) async {
    final e = endorsement;
    if (e == null ||
        e.length != 64 ||
        previous.uid != uid ||
        version != previous.version + 1 ||
        previous.signingKey.length != 32) {
      return false;
    }
    return _ed25519.verify(
      accountKeysEndorsementMessage(previous.version, this),
      signature: Signature(
        e,
        publicKey: SimplePublicKey(previous.signingKey, type: KeyPairType.ed25519),
      ),
    );
  }

  /// SHA-256 over both public keys: what a person compares with a teammate
  /// to know the keys are really theirs.
  Uint8List get fingerprint =>
      accountKeysFingerprint(signingKey: signingKey, encryptionKey: encryptionKey);

  /// Whether [keys] are the private halves of these public keys.
  bool matches(AccountKeys keys) =>
      _equal(keys.encryption.publicKey, encryptionKey) &&
      _equal(keys.signingPublicKey, signingKey) &&
      keys.version == version;

  Map<String, dynamic> toJson() => {
        'key_version': version,
        'created_at': createdAt,
        'x25519_pub': base64Encode(encryptionKey),
        'ed25519_pub': base64Encode(signingKey),
        'self_sig': base64Encode(signature),
      };

  /// The server's answer for the account [uid]. Throws FormatException.
  static PublishedAccountKeys fromJson(String uid, Map<String, dynamic> json) {
    final version = json['key_version'];
    final createdAt = json['created_at'];
    final x = json['x25519_pub'];
    final ed = json['ed25519_pub'];
    final sig = json['self_sig'];
    final endorsement = json['endorsement'];
    if (version is! int ||
        createdAt is! int ||
        x is! String ||
        ed is! String ||
        sig is! String) {
      throw const FormatException('Not a published set of account keys');
    }
    return PublishedAccountKeys(
      uid: uid,
      version: version,
      createdAt: createdAt,
      encryptionKey: base64Decode(x),
      signingKey: base64Decode(ed),
      signature: base64Decode(sig),
      endorsement: endorsement is String ? base64Decode(endorsement) : null,
    );
  }
}

/// The exact bytes the self-signature covers. Every field is length-prefixed
/// or fixed-width, so no two different bundles encode the same way.
Uint8List accountKeysMessage({
  required String uid,
  required int version,
  required int createdAt,
  required List<int> encryptionKey,
  required List<int> signingKey,
}) {
  final fixed = ByteData(12)
    ..setUint32(0, version)
    ..setUint64(4, createdAt);
  return Uint8List.fromList([
    ..._lp(utf8.encode(kAccountKeysLabel)),
    ..._lp(utf8.encode(uid)),
    ...fixed.buffer.asUint8List(),
    ..._lp(encryptionKey),
    ..._lp(signingKey),
  ]);
}

/// The exact bytes an endorsement covers: the key at [oldVersion] vouching
/// for [next]. The new keys' own signed message is inside, so it names the
/// account, the new version, its creation time and both new public keys. The
/// server checks the same bytes (ZestSSH Cloud's src/lib/account_keys.js).
Uint8List accountKeysEndorsementMessage(int oldVersion, PublishedAccountKeys next) {
  final version = ByteData(4)..setUint32(0, oldVersion);
  return Uint8List.fromList([
    ..._lp(utf8.encode(kAccountKeysEndorseLabel)),
    ...version.buffer.asUint8List(),
    ..._lp(next.signedMessage()),
  ]);
}

/// SHA-256 over the fingerprint label and both public keys.
Uint8List accountKeysFingerprint({
  required List<int> signingKey,
  required List<int> encryptionKey,
}) {
  final digest = hash.sha256.convert([
    ..._lp(utf8.encode(kAccountKeysFingerprintLabel)),
    ..._lp(signingKey),
    ..._lp(encryptionKey),
  ]);
  return Uint8List.fromList(digest.bytes);
}

List<int> _lp(List<int> bytes) {
  final out = Uint8List(4 + bytes.length);
  ByteData.sublistView(out, 0, 4).setUint32(0, bytes.length);
  out.setRange(4, out.length, bytes);
  return out;
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
