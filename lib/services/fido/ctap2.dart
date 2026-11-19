// CTAP2 (FIDO Client to Authenticator Protocol 2.0 and 2.1), the commands a
// security key is asked for an SSH key: what it is (getInfo), a new key
// (makeCredential), a signature (getAssertion) and a PIN token (clientPIN).
//
// Nothing here knows how the bytes travel: a [CtapDevice] sends one message
// and gives its answer (NFC or USB, lib/.../fido_nfc.dart and fido_hid.dart).
// Everything a key answers is read strictly: the kinds and lengths the
// protocol names, and nothing taken on trust that the caller can check.
import 'dart:typed_data';

import 'package:zestssh/services/fido/cbor.dart';
import 'package:zestssh/services/fido/pin_protocol.dart';
import 'package:zestssh/utils/type_name.dart';

/// How one CTAP2 message reaches a security key and its answer comes back:
/// [request] is the command byte and its CBOR; the answer is the status
/// byte and its CBOR. Throws [CtapTransportError] when the key cannot be
/// talked to (taken away, unplugged, a frame that makes no sense).
abstract interface class CtapDevice {
  Future<Uint8List> cbor(Uint8List request);
}

/// The key could not be talked to; [message] says what happened, for a log.
class CtapTransportError implements Exception, HasTypeName {
  const CtapTransportError(this.message);

  final String message;

  @override
  String toString() => 'Security key: $message';

  @override
  String get typeName => 'CtapTransportError';
}

/// The key answered with something the protocol does not allow.
class CtapProtocolError implements Exception, HasTypeName {
  const CtapProtocolError(this.message);

  final String message;

  @override
  String toString() => 'Security key: $message';

  @override
  String get typeName => 'CtapProtocolError';
}

/// The key refused: [status] is its CTAP2 status byte.
class CtapError implements Exception, HasTypeName {
  const CtapError(this.status);

  final int status;

  static const int invalidCommand = 0x01;
  static const int invalidParameter = 0x02;
  static const int credentialExcluded = 0x19;
  static const int unsupportedAlgorithm = 0x26;
  static const int operationDenied = 0x27;
  static const int keyStoreFull = 0x28;
  static const int unsupportedOption = 0x2b;
  static const int invalidOption = 0x2c;
  static const int keepaliveCancel = 0x2d;
  static const int noCredentials = 0x2e;
  static const int userActionTimeout = 0x2f;
  static const int notAllowed = 0x30;
  static const int pinInvalid = 0x31;
  static const int pinBlocked = 0x32;
  static const int pinAuthInvalid = 0x33;
  static const int pinAuthBlocked = 0x34;
  static const int pinNotSet = 0x35;
  static const int pinRequired = 0x36;
  static const int pinPolicyViolation = 0x37;
  static const int requestTooLarge = 0x39;
  static const int actionTimeout = 0x3a;
  static const int upRequired = 0x3b;
  static const int uvBlocked = 0x3c;
  static const int uvInvalid = 0x3f;

  @override
  String toString() => 'Security key refused: CTAP2 status 0x${status.toRadixString(16).padLeft(2, '0')}';

  @override
  String get typeName => 'CtapError';
}

/// COSE's names for the two kinds of key an SSH security key can be.
const int kCoseEs256 = -7;
const int kCoseEdDsa = -8;

/// What a security key says of itself (authenticatorGetInfo).
class AuthenticatorInfo {
  const AuthenticatorInfo({
    required this.versions,
    required this.options,
    required this.pinProtocols,
    required this.algorithms,
    this.extensions = const [],
    this.maxMsgSize,
  });

  /// "FIDO_2_0", "FIDO_2_1", "U2F_V2", ...
  final List<String> versions;

  /// "rk", "up", "uv", "clientPin", "pinUvAuthToken", ...
  final Map<String, bool> options;

  /// The PIN/UV auth protocols it speaks, its own preference first.
  final List<int> pinProtocols;

  /// The COSE algorithms it says it makes keys for; empty where it does not
  /// say (CTAP 2.0), which is not "none".
  final List<int> algorithms;

  /// The extensions it says it supports ("credProtect", "hmac-secret", ...).
  final List<String> extensions;

  final int? maxMsgSize;

  /// Whether a PIN is set on it (false: it can have one and has none; null:
  /// it has no PIN at all).
  bool? get pinSet => options['clientPin'];

  /// Whether it gives PIN tokens with permissions (CTAP 2.1).
  bool get pinTokenWithPermissions => options['pinUvAuthToken'] == true;

  /// The newest PIN/UV auth protocol both sides speak, or null: two where
  /// the key names it, else one where it names one or names none (a CTAP
  /// 2.0 key that takes a PIN speaks one).
  int? get pinProtocol {
    if (pinProtocols.contains(2)) return 2;
    if (pinProtocols.contains(1) || (pinProtocols.isEmpty && options.containsKey('clientPin'))) return 1;
    return null;
  }

  /// Whether it says it can make a key of [alg]; unknown (true) where it
  /// lists none.
  bool makes(int alg) => algorithms.isEmpty || algorithms.contains(alg);

  /// Whether it can be told to sign with a key only after user
  /// verification (CTAP 2.1's credProtect extension).
  bool get credProtect => extensions.contains('credProtect');
}

/// The data a key signs over and returns (WebAuthn's authenticator data):
/// who it is for, what happened, and the key's counter.
class AuthenticatorData {
  const AuthenticatorData({required this.rpIdHash, required this.flags, required this.counter, required this.rest, required this.raw});

  static const int flagUserPresent = 0x01;
  static const int flagUserVerified = 0x04;
  static const int flagAttested = 0x40;
  static const int flagExtensions = 0x80;

  final Uint8List rpIdHash;
  final int flags;
  final int counter;

  /// What follows the counter: attested credential data and extensions.
  final Uint8List rest;

  /// The whole of it, as signed.
  final Uint8List raw;

  bool get userPresent => flags & flagUserPresent != 0;
  bool get userVerified => flags & flagUserVerified != 0;

  static AuthenticatorData parse(Uint8List raw) {
    if (raw.length < 37) throw const CtapProtocolError('authenticator data shorter than 37 bytes');
    return AuthenticatorData(
      rpIdHash: Uint8List.fromList(raw.sublist(0, 32)),
      flags: raw[32],
      counter: (raw[33] << 24) | (raw[34] << 16) | (raw[35] << 8) | raw[36],
      rest: Uint8List.fromList(raw.sublist(37)),
      raw: raw,
    );
  }
}

/// A public key as a security key gives it (COSE): P-256 ([x] and [y]) or
/// Ed25519 ([x] alone).
class CosePublicKey {
  const CosePublicKey.es256(this.x, Uint8List this.y) : alg = kCoseEs256;
  const CosePublicKey.edDsa(this.x)
      : alg = kCoseEdDsa,
        y = null;

  final int alg;
  final Uint8List x;
  final Uint8List? y;

  /// From a COSE_Key map. Only the two kinds above, with the lengths they
  /// have; a P-256 point has to be on the curve.
  static CosePublicKey parse(Object? cose) {
    if (cose is! Map) throw const CtapProtocolError('a public key that is not a map');
    final kty = cose[1], alg = cose[3], crv = cose[-1], x = cose[-2], y = cose[-3];
    if (x is! Uint8List || x.length != 32) throw const CtapProtocolError('a public key whose x is not 32 bytes');
    if (kty == 2 && alg == kCoseEs256 && crv == 1) {
      if (y is! Uint8List || y.length != 32) throw const CtapProtocolError('a P-256 key whose y is not 32 bytes');
      if (!isOnP256(_big(x), _big(y))) throw const CtapProtocolError('a P-256 key that is not on the curve');
      return CosePublicKey.es256(x, y);
    }
    if (kty == 1 && alg == kCoseEdDsa && crv == 6) return CosePublicKey.edDsa(x);
    throw const CtapProtocolError('a public key of a kind that is neither P-256 nor Ed25519');
  }
}

BigInt _big(Uint8List bytes) => bytes.fold(BigInt.zero, (n, b) => (n << 8) | BigInt.from(b));

/// credProtect's highest level (CTAP 2.1, userVerificationRequired): the
/// security key uses the key only after user verification (its PIN or a
/// fingerprint), whatever a request asks.
const int kCredProtectUvRequired = 3;

/// A key a security key made (authenticatorMakeCredential).
class MadeCredential {
  const MadeCredential({required this.credentialId, required this.publicKey, required this.authData, this.credProtect});

  /// What the key is asked for again by (OpenSSH's key handle).
  final Uint8List credentialId;
  final CosePublicKey publicKey;
  final AuthenticatorData authData;

  /// The credProtect level the security key says it made the key with, or
  /// null where it said none.
  final int? credProtect;
}

/// A signature a security key made (authenticatorGetAssertion).
class Assertion {
  const Assertion({required this.authData, required this.signature, this.credentialId});

  final AuthenticatorData authData;

  /// As the key gives it: ASN.1 DER for P-256, 64 raw bytes for Ed25519.
  final Uint8List signature;

  /// The credential that signed, where the key says.
  final Uint8List? credentialId;
}

/// A PIN token: what requests are authenticated with, under the agreement
/// it was given in. Held for one operation and dropped.
class PinToken {
  const PinToken(this.protocol, this._token);

  final PinProtocol protocol;
  final Uint8List _token;

  /// The parameter that shows a request for [clientDataHash] comes from
  /// whoever gave the PIN.
  Uint8List authParam(Uint8List clientDataHash) => protocol.authenticateWith(_token, clientDataHash);
}

/// CTAP2's permissions of a PIN token (CTAP 2.1).
const int kPinPermissionMakeCredential = 0x01;
const int kPinPermissionGetAssertion = 0x02;

/// The commands, over a [CtapDevice].
class Ctap2 {
  Ctap2(this.device);

  final CtapDevice device;

  static const int _cmdMakeCredential = 0x01;
  static const int _cmdGetAssertion = 0x02;
  static const int _cmdGetInfo = 0x04;
  static const int _cmdClientPin = 0x06;

  /// The largest answer taken from a key (its attestation certificates are
  /// the long part; none is a megabyte).
  static const int maxAnswer = 64 * 1024;

  /// Sends [command] with [parameters] and reads the answer's map (empty
  /// where the key sends none). Throws [CtapError] where the key refuses.
  Future<Map<Object, Object?>> _send(int command, Map<int, Object?>? parameters) async {
    final request = Uint8List.fromList([command, if (parameters != null) ...cborEncode(parameters)]);
    final answer = await device.cbor(request);
    if (answer.isEmpty) throw const CtapProtocolError('an empty answer');
    if (answer.length > maxAnswer) throw const CtapProtocolError('an answer longer than a key gives');
    if (answer[0] != 0) throw CtapError(answer[0]);
    if (answer.length == 1) return const {};
    final Object? value;
    try {
      value = cborDecode(Uint8List.sublistView(answer, 1));
    } on CborError catch (e) {
      throw CtapProtocolError('an answer that is not CBOR (${e.message})');
    }
    if (value is! Map<Object, Object?>) throw const CtapProtocolError('an answer that is not a map');
    return value;
  }

  Future<AuthenticatorInfo> getInfo() async {
    final m = await _send(_cmdGetInfo, null);
    final versions = m[1];
    if (versions is! List || versions.any((v) => v is! String)) {
      throw const CtapProtocolError('getInfo without its versions');
    }
    final options = <String, bool>{};
    if (m[4] case final Map<Object?, Object?> o) {
      for (final e in o.entries) {
        if (e.key is String && e.value is bool) options[e.key! as String] = e.value! as bool;
      }
    }
    final extensions = <String>[
      if (m[2] case final List<Object?> list)
        for (final e in list)
          if (e is String) e,
    ];
    final algorithms = <int>[];
    if (m[10] case final List<Object?> list) {
      for (final a in list) {
        if (a is Map && a['type'] == 'public-key' && a['alg'] is int) algorithms.add(a['alg'] as int);
      }
    }
    return AuthenticatorInfo(
      versions: versions.cast<String>(),
      options: options,
      pinProtocols: [
        if (m[6] case final List<Object?> p)
          for (final v in p)
            if (v is int) v,
      ],
      algorithms: algorithms,
      extensions: extensions,
      maxMsgSize: m[5] is int ? m[5] as int : null,
    );
  }

  /// How many tries of the PIN are left before the key blocks it.
  Future<int> pinRetries({int protocol = 1}) async {
    final m = await _send(_cmdClientPin, {1: protocol, 2: 0x01});
    final n = m[3];
    if (n is! int || n < 0 || n > 255) throw const CtapProtocolError('no count of PIN tries');
    return n;
  }

  /// Agrees a secret with the key and gets a token for [pinUtf8]. Where the
  /// key gives tokens with permissions ([info]), the token is good only for
  /// [permissions] and [rpId]; an older key's token is good for anything
  /// until the key is taken away. Throws [CtapError] ([CtapError.pinInvalid],
  /// [CtapError.pinBlocked], [CtapError.pinAuthBlocked], [CtapError.pinNotSet]).
  Future<PinToken> pinToken(
    AuthenticatorInfo info,
    List<int> pinUtf8, {
    required int permissions,
    required String rpId,
    PinProtocol Function(int version, P256Point authenticator)? agree,
  }) async {
    final version = info.pinProtocol;
    if (version == null) throw const CtapProtocolError('the key speaks no PIN protocol this app does');
    final agreement = await _send(_cmdClientPin, {1: version, 2: 0x02});
    final key = agreement[1];
    if (key is! Map || key[1] != 2 || key[-1] != 1) throw const CtapProtocolError('a key agreement that is not P-256');
    final x = key[-2], y = key[-3];
    if (x is! Uint8List || y is! Uint8List || x.length != 32 || y.length != 32) {
      throw const CtapProtocolError('a key agreement point of the wrong size');
    }
    final PinProtocol protocol;
    try {
      protocol = (agree ?? (v, p) => PinProtocol.agree(v, p))(version, (x: x, y: y));
    } on ArgumentError {
      throw const CtapProtocolError('a key agreement point that is not on the curve');
    }
    final withPermissions = info.pinTokenWithPermissions;
    final answer = await _send(_cmdClientPin, {
      1: version,
      2: withPermissions ? 0x09 : 0x05,
      3: {1: 2, 3: -25, -1: 1, -2: protocol.platformPoint.x, -3: protocol.platformPoint.y},
      6: protocol.pinHashEnc(pinUtf8),
      if (withPermissions) 9: permissions,
      if (withPermissions) 10: rpId,
    });
    final encrypted = answer[2];
    // 16 or 32 bytes of token; protocol two puts 16 of IV in front.
    final lengths = version == 1 ? const [16, 32] : const [32, 48];
    if (encrypted is! Uint8List || !lengths.contains(encrypted.length)) {
      throw const CtapProtocolError('a PIN token of the wrong size');
    }
    return PinToken(protocol, protocol.decrypt(encrypted));
  }

  /// Makes a key on the security key for [rpId] (an SSH key's application,
  /// "ssh:" unless the person chose another), of kind [alg]. [resident]
  /// keeps it on the security key itself; [pin] is needed where the key has
  /// a PIN. [credProtect] asks for that credProtect level (only of a key
  /// whose getInfo lists the extension); what the key says it used is in
  /// the answer. The person touches the key.
  Future<MadeCredential> makeCredential({
    required Uint8List clientDataHash,
    required String rpId,
    required Uint8List userId,
    required String userName,
    required int alg,
    bool resident = false,
    PinToken? pin,
    int? credProtect,
  }) async {
    _hash(clientDataHash);
    final m = await _send(_cmdMakeCredential, {
      1: clientDataHash,
      2: {'id': rpId, 'name': rpId},
      3: {'id': userId, 'name': userName, 'displayName': userName},
      4: [
        {'alg': alg, 'type': 'public-key'},
      ],
      if (credProtect != null) 6: {'credProtect': credProtect},
      if (resident) 7: {'rk': true},
      if (pin != null) 8: pin.authParam(clientDataHash),
      if (pin != null) 9: pin.protocol.version,
    });
    final raw = m[2];
    if (raw is! Uint8List) throw const CtapProtocolError('makeCredential without authenticator data');
    final data = AuthenticatorData.parse(raw);
    if (data.flags & AuthenticatorData.flagAttested == 0) {
      throw const CtapProtocolError('makeCredential without the new key');
    }
    final rest = data.rest;
    if (rest.length < 18) throw const CtapProtocolError('attested data cut short');
    final idLength = (rest[16] << 8) | rest[17];
    if (idLength == 0 || idLength > 1023 || rest.length < 18 + idLength) {
      throw const CtapProtocolError('a credential id of an impossible length');
    }
    final credentialId = Uint8List.fromList(rest.sublist(18, 18 + idLength));
    final Object? cose;
    final int coseEnd;
    try {
      (cose, coseEnd) = cborDecodeFirst(rest, 18 + idLength);
    } on CborError catch (e) {
      throw CtapProtocolError('a public key that is not CBOR (${e.message})');
    }
    final publicKey = CosePublicKey.parse(cose);
    if (publicKey.alg != alg) throw const CtapProtocolError('a key of another kind than was asked for');
    // The extensions' answers follow the public key where the key says it
    // has some. Only credProtect's is read; one that cannot be read counts
    // as no level said, the cautious reading.
    int? level;
    if (data.flags & AuthenticatorData.flagExtensions != 0 && coseEnd < rest.length) {
      try {
        final (extensions, _) = cborDecodeFirst(rest, coseEnd);
        if (extensions case {'credProtect': final int n}) level = n;
      } on CborError {
        level = null;
      }
    }
    return MadeCredential(credentialId: credentialId, publicKey: publicKey, authData: data, credProtect: level);
  }

  /// Asks the key to sign [clientDataHash] for [rpId] with the credential
  /// [credentialId]. [userPresence] false asks for no touch (a key made
  /// "no-touch-required"); [pin] where the key needs it. The person touches
  /// the key unless told otherwise.
  Future<Assertion> getAssertion({
    required String rpId,
    required Uint8List clientDataHash,
    required Uint8List credentialId,
    bool userPresence = true,
    PinToken? pin,
  }) async {
    _hash(clientDataHash);
    final m = await _send(_cmdGetAssertion, {
      1: rpId,
      2: clientDataHash,
      3: [
        {'id': credentialId, 'type': 'public-key'},
      ],
      if (!userPresence) 5: {'up': false},
      if (pin != null) 6: pin.authParam(clientDataHash),
      if (pin != null) 7: pin.protocol.version,
    });
    final raw = m[2], signature = m[3];
    if (raw is! Uint8List) throw const CtapProtocolError('getAssertion without authenticator data');
    if (signature is! Uint8List || signature.isEmpty || signature.length > 256) {
      throw const CtapProtocolError('getAssertion without a signature');
    }
    Uint8List? id;
    if (m[1] case final Map<Object?, Object?> credential) {
      if (credential['id'] case final Uint8List bytes) id = bytes;
    }
    return Assertion(authData: AuthenticatorData.parse(raw), signature: signature, credentialId: id);
  }

  static void _hash(Uint8List clientDataHash) {
    if (clientDataHash.length != 32) throw ArgumentError('the client data hash is 32 bytes');
  }
}
