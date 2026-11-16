import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:cryptography/cryptography.dart';
import 'package:zestssh/services/passkeys/passkey_platform.dart';

/// A WebAuthn authenticator in software, for tests (as ZestSSH Cloud's
/// test/helpers/soft_authenticator.js): it answers the options ZestSSH Cloud
/// makes with the JSON a phone's Credential Manager or Windows Hello hands
/// over, signed with Ed25519 keys made here (COSE EdDSA, -8), so the
/// server's checks run on real signatures. [bend] turns a response the ways
/// a broken or hostile client would.
class SoftPasskeys implements PasskeyPlatform {
  SoftPasskeys({
    this.available = true,
    this.origin = 'https://zestssh.com',
    this.synced = true,
    this.counter = 0,
  });

  bool available;
  final String origin;
  final bool synced;
  int counter;

  /// What the next ceremony does instead of answering: PasskeyCancelled, a
  /// PasskeyError.
  Object? failNext;

  final credentials = <_Credential>[];

  /// The options each ceremony was given.
  final created = <Map<String, Object?>>[];
  final used = <Map<String, Object?>>[];

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<Map<String, Object?>> create(Map<String, Object?> options) async {
    created.add(options);
    final fail = failNext;
    failNext = null;
    if (fail != null) throw fail;
    final rp = options['rp'] as Map<String, Object?>;
    final user = options['user'] as Map<String, Object?>;
    final keyPair = await Ed25519().newKeyPair();
    final publicKey = (await keyPair.extractPublicKey()).bytes;
    final random = Random.secure();
    final id = Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256)));
    final cose = _cbor({1: 1, 3: -8, -1: 6, -2: Uint8List.fromList(publicKey)});
    final authData = BytesBuilder()
      ..add(_sha256(utf8.encode(rp['id'] as String)))
      ..addByte(_flags(attested: true))
      ..add(_u32(counter))
      ..add(Uint8List(16))
      ..add([id.length >> 8, id.length & 0xff])
      ..add(id)
      ..add(cose);
    final clientData = utf8.encode(jsonEncode({
      'type': 'webauthn.create',
      'challenge': options['challenge'],
      'origin': origin,
      'crossOrigin': false,
    }));
    final attestation = _cbor({'fmt': 'none', 'attStmt': <Object, Object>{}, 'authData': authData.toBytes()});
    credentials.add(_Credential(id, keyPair, user['id'] as String, counter));
    return {
      'id': _b64u(id),
      'rawId': _b64u(id),
      'type': 'public-key',
      'response': {
        'clientDataJSON': _b64u(clientData),
        'attestationObject': _b64u(attestation),
        'transports': ['internal', 'hybrid'],
      },
      'authenticatorAttachment': 'platform',
      'clientExtensionResults': {
        'credProps': {'rk': true},
      },
    };
  }

  /// How the next assertion is bent: 'origin' (another site's), 'signature'
  /// (a wrong one), 'counter-back' (a counter that went back).
  String? bend;

  @override
  Future<Map<String, Object?>> get(Map<String, Object?> options) async {
    used.add(options);
    final fail = failNext;
    failNext = null;
    if (fail != null) throw fail;
    final allowed = {
      for (final a in (options['allowCredentials'] as List? ?? const [])) (a as Map)['id'] as String,
    };
    final credential = credentials.lastWhere(
      (cr) => allowed.isEmpty || allowed.contains(_b64u(cr.id)),
      orElse: () => throw const PasskeyError('no-credential'),
    );
    final how = bend;
    bend = null;
    if (how == 'counter-back') {
      credential.counter = 0;
    } else if (credential.counter > 0) {
      credential.counter += 1;
    }
    final authData = BytesBuilder()
      ..add(_sha256(utf8.encode(options['rpId'] as String)))
      ..addByte(_flags())
      ..add(_u32(credential.counter));
    final clientData = utf8.encode(jsonEncode({
      'type': 'webauthn.get',
      'challenge': options['challenge'],
      'origin': how == 'origin' ? 'https://zestssh.example' : origin,
      'crossOrigin': false,
    }));
    final signed = BytesBuilder()
      ..add(authData.toBytes())
      ..add(_sha256(clientData));
    var signature = (await Ed25519().sign(signed.toBytes(), keyPair: credential.keyPair)).bytes;
    if (how == 'signature') signature = List<int>.from(signature)..[0] ^= 0xff;
    return {
      'id': _b64u(credential.id),
      'rawId': _b64u(credential.id),
      'type': 'public-key',
      'response': {
        'clientDataJSON': _b64u(clientData),
        'authenticatorData': _b64u(authData.toBytes()),
        'signature': _b64u(signature),
        'userHandle': credential.userHandle,
      },
      'authenticatorAttachment': 'platform',
      'clientExtensionResults': <String, Object?>{},
    };
  }

  int _flags({bool attested = false}) => 0x01 | 0x04 | (synced ? 0x08 | 0x10 : 0) | (attested ? 0x40 : 0);
}

class _Credential {
  _Credential(this.id, this.keyPair, this.userHandle, this.counter);

  final Uint8List id;
  final SimpleKeyPair keyPair;
  final String userHandle;
  int counter;
}

String _b64u(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

List<int> _sha256(List<int> data) => c.sha256.convert(data).bytes;

List<int> _u32(int n) => [(n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff];

/// The little CBOR WebAuthn needs: maps, integers, byte and text strings.
Uint8List _cbor(Object value) {
  final out = BytesBuilder();
  void head(int major, int n) {
    if (n < 24) {
      out.addByte((major << 5) | n);
    } else if (n < 0x100) {
      out
        ..addByte((major << 5) | 24)
        ..addByte(n);
    } else if (n < 0x10000) {
      out
        ..addByte((major << 5) | 25)
        ..add([n >> 8, n & 0xff]);
    } else {
      out
        ..addByte((major << 5) | 26)
        ..add(_u32(n));
    }
  }

  void write(Object v) {
    switch (v) {
      case int i when i >= 0:
        head(0, i);
      case int i:
        head(1, -1 - i);
      case Uint8List b:
        head(2, b.length);
        out.add(b);
      case String s:
        final bytes = utf8.encode(s);
        head(3, bytes.length);
        out.add(bytes);
      case Map m:
        head(5, m.length);
        for (final e in m.entries) {
          write(e.key as Object);
          write(e.value as Object);
        }
      default:
        throw ArgumentError('no CBOR for ${v.runtimeType}');
    }
  }

  write(value);
  return out.toBytes();
}

/// A passkey ceremony that answers as it is told, for the screens' tests:
/// [onCreate] and [onGet] give the response or throw.
class ScriptedPasskeys implements PasskeyPlatform {
  ScriptedPasskeys({this.available = true, this.onCreate, this.onGet});

  bool available;
  Future<Map<String, Object?>> Function(Map<String, Object?> options)? onCreate;
  Future<Map<String, Object?>> Function(Map<String, Object?> options)? onGet;

  final created = <Map<String, Object?>>[];
  final used = <Map<String, Object?>>[];

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<Map<String, Object?>> create(Map<String, Object?> options) async {
    created.add(options);
    final make = onCreate;
    if (make == null) return {'id': 'made', 'rawId': 'made', 'type': 'public-key', 'response': <String, Object?>{}};
    return make(options);
  }

  @override
  Future<Map<String, Object?>> get(Map<String, Object?> options) async {
    used.add(options);
    final use = onGet;
    if (use == null) return {'id': 'used', 'rawId': 'used', 'type': 'public-key', 'response': <String, Object?>{}};
    return use(options);
  }
}
