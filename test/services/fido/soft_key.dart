// A security key in software, for tests: it answers CTAP2 as the
// specification says a key does (getInfo, clientPIN with PIN/UV auth
// protocols one and two, makeCredential, getAssertion), with P-256 and
// Ed25519 keys, a PIN with its tries, and a counter.
//
// Its PIN protocols are written here a second time, from the specification
// and with the primitives called directly (HKDF by hand from HMAC), not
// with the app's PinProtocol: where the two disagree a test fails. That is
// two readings of one text by one author, not a real key: a real key must
// be tried by hand.
//
// [SoftNfcCard] and [SoftHid] put it behind the two transports' raw sides
// (ISO 7816-4 commands; 64 byte reports), each able to misbehave as real
// ones do: answers in pieces, "still working", packets of another program.
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as c;
import 'package:zestssh/services/fido/cbor.dart';
import 'package:zestssh/services/fido/ctap2.dart';
import 'package:zestssh/services/fido/fido_hid.dart';
import 'package:zestssh/services/fido/fido_nfc.dart';
import 'package:pointycastle/export.dart';

final ECDomainParameters _p256 = ECCurve_secp256r1();

Uint8List sha256(List<int> data) => SHA256Digest().process(Uint8List.fromList(data));

Uint8List hmacSha256(List<int> key, List<int> data) =>
    (HMac(SHA256Digest(), 64)..init(KeyParameter(Uint8List.fromList(key)))).process(Uint8List.fromList(data));

Uint8List _aes(bool encrypt, List<int> key, List<int> iv, List<int> data) {
  final cipher = CBCBlockCipher(AESEngine())
    ..init(encrypt, ParametersWithIV(KeyParameter(Uint8List.fromList(key)), Uint8List.fromList(iv)));
  final input = Uint8List.fromList(data), out = Uint8List(data.length);
  for (var at = 0; at < data.length; at += 16) {
    cipher.processBlock(input, at, out, at);
  }
  return out;
}

Uint8List _fixed32(BigInt n) {
  final out = Uint8List(32);
  var v = n;
  for (var i = 31; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v >>= 8;
  }
  return out;
}

BigInt _big(List<int> bytes) => bytes.fold(BigInt.zero, (n, b) => (n << 8) | BigInt.from(b));

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

class _Credential {
  _Credential(this.rpId, this.alg, {this.ec, this.ed});

  final String rpId;
  final int alg;
  final ECPrivateKey? ec;
  final c.SimpleKeyPair? ed;
}

/// How a soft key may be made to lie, to see the app refuse it.
enum SoftKeyLie { none, otherApplication, noTouch, extensions, badSignature, otherKeySigns, garbageAnswer }

class SoftKey implements CtapDevice {
  SoftKey({
    this.pin,
    this.pinProtocols = const [2, 1],
    this.tokensWithPermissions = true,
    this.makesEd25519 = true,
    this.listsAlgorithms = true,
    int seed = 7,
  }) : _random = Random(seed);

  /// The PIN set on it, or null for a key with none.
  String? pin;
  final List<int> pinProtocols;

  /// CTAP 2.1's tokens with permissions; false is a CTAP 2.0 key.
  final bool tokensWithPermissions;
  final bool makesEd25519;
  final bool listsAlgorithms;

  final Random _random;
  final Map<String, _Credential> _credentials = {};

  int pinRetries = 8;
  int counter = 0;
  SoftKeyLie lie = SoftKeyLie.none;

  /// Every command byte it was sent, in order.
  final List<int> commands = [];

  /// The last getAssertion's and makeCredential's requests, as read.
  Map<Object, Object?>? lastRequest;

  ECPrivateKey? _agreement;
  Uint8List? _token;
  int _tokenProtocol = 0;
  int? _tokenPermissions;
  String? _tokenRpId;

  Uint8List _bytes(int n) => Uint8List.fromList(List.generate(n, (_) => _random.nextInt(256)));

  ECPrivateKey _newEcKey() {
    // A private key from the test's own chance: any number below the order.
    final d = _big(_bytes(32)) % (_p256.n - BigInt.one) + BigInt.one;
    return ECPrivateKey(d, _p256);
  }

  static (Uint8List, Uint8List) _point(ECPrivateKey key) {
    final q = _p256.G * key.d!;
    return (_fixed32(q!.x!.toBigInteger()!), _fixed32(q.y!.toBigInteger()!));
  }

  Uint8List _status(int status) => Uint8List.fromList([status]);

  Uint8List _ok([Map<int, Object?>? answer]) => Uint8List.fromList([0, if (answer != null) ...cborEncode(answer)]);

  @override
  Future<Uint8List> cbor(Uint8List request) async {
    commands.add(request[0]);
    final Map<Object, Object?> p;
    try {
      p = request.length > 1 ? cborDecode(Uint8List.sublistView(request, 1))! as Map<Object, Object?> : const {};
    } catch (_) {
      return _status(0x12); // CTAP2_ERR_INVALID_CBOR
    }
    if (lie == SoftKeyLie.garbageAnswer) return Uint8List.fromList([0, 0xff, 0xff, 0xff]);
    switch (request[0]) {
      case 0x04:
        return _getInfo();
      case 0x06:
        return _clientPin(p);
      case 0x01:
        lastRequest = p;
        return _makeCredential(p);
      case 0x02:
        lastRequest = p;
        return _getAssertion(p);
      default:
        return _status(CtapError.invalidCommand);
    }
  }

  Uint8List _getInfo() => _ok({
        1: tokensWithPermissions ? ['U2F_V2', 'FIDO_2_0', 'FIDO_2_1'] : ['U2F_V2', 'FIDO_2_0'],
        3: Uint8List(16),
        4: {
          'rk': true,
          'up': true,
          if (pin != null || pinProtocols.isNotEmpty) 'clientPin': pin != null,
          if (tokensWithPermissions) 'pinUvAuthToken': true,
        },
        5: 1200,
        if (pinProtocols.isNotEmpty && tokensWithPermissions) 6: pinProtocols,
        if (pinProtocols.isNotEmpty && !tokensWithPermissions) 6: [1],
        if (listsAlgorithms)
          10: [
            {'alg': kCoseEs256, 'type': 'public-key'},
            if (makesEd25519) {'alg': kCoseEdDsa, 'type': 'public-key'},
          ],
      });

  /// The shared secret of [protocol] with the platform's point: (HMAC key,
  /// AES key). Protocol one uses one key for both.
  (Uint8List, Uint8List) _shared(int protocol, Map<Object?, Object?> platform) {
    final x = platform[-2]! as Uint8List, y = platform[-3]! as Uint8List;
    final theirs = _p256.curve.createPoint(_big(x), _big(y));
    final z = _fixed32((theirs * _agreement!.d!)!.x!.toBigInteger()!);
    if (protocol == 1) {
      final key = sha256(z);
      return (key, key);
    }
    // HKDF-SHA-256 with a salt of 32 zero bytes, one block of output.
    final prk = hmacSha256(Uint8List(32), z);
    Uint8List expand(String info) => hmacSha256(prk, [...info.codeUnits, 0x01]);
    return (expand('CTAP2 HMAC key'), expand('CTAP2 AES key'));
  }

  Uint8List _decrypt(int protocol, Uint8List aesKey, Uint8List data) =>
      protocol == 1 ? _aes(false, aesKey, Uint8List(16), data) : _aes(false, aesKey, data.sublist(0, 16), data.sublist(16));

  Uint8List _encrypt(int protocol, Uint8List aesKey, Uint8List data) {
    if (protocol == 1) return _aes(true, aesKey, Uint8List(16), data);
    final iv = _bytes(16);
    return Uint8List.fromList([...iv, ..._aes(true, aesKey, iv, data)]);
  }

  Uint8List _clientPin(Map<Object, Object?> p) {
    final protocol = p[1], sub = p[2];
    if (protocol is! int || !pinProtocols.contains(protocol)) return _status(CtapError.invalidParameter);
    switch (sub) {
      case 0x01:
        return _ok({3: pinRetries});
      case 0x02:
        _agreement = _newEcKey();
        final (x, y) = _point(_agreement!);
        return _ok({
          1: {1: 2, 3: -25, -1: 1, -2: x, -3: y}
        });
      case 0x05 || 0x09:
        if (sub == 0x09 && !tokensWithPermissions) return _status(CtapError.invalidCommand);
        if (pin == null) return _status(CtapError.pinNotSet);
        if (pinRetries == 0) return _status(CtapError.pinBlocked);
        final platform = p[3], enc = p[6];
        if (_agreement == null || platform is! Map || enc is! Uint8List) return _status(CtapError.invalidParameter);
        final (_, aesKey) = _shared(protocol, platform);
        final hash = _decrypt(protocol, aesKey, enc);
        pinRetries--;
        final right = sha256(pin!.codeUnits).sublist(0, 16);
        if (hash.length != 16 || _hex(hash) != _hex(right)) {
          _agreement = null; // a new agreement for the next try, as the specification asks
          return _status(pinRetries == 0 ? CtapError.pinBlocked : CtapError.pinInvalid);
        }
        pinRetries = 8;
        _token = _bytes(32);
        _tokenProtocol = protocol;
        _tokenPermissions = sub == 0x09 ? p[9] as int? : null;
        _tokenRpId = sub == 0x09 ? p[10] as String? : null;
        return _ok({2: _encrypt(protocol, aesKey, _token!)});
      default:
        return _status(CtapError.invalidCommand);
    }
  }

  /// Whether [param] shows the PIN token for [clientDataHash], with
  /// [permission] for [rpId]; null where no parameter came.
  bool? _pinVerified(Object? param, Object? protocol, Uint8List clientDataHash, int permission, String rpId) {
    if (param == null) return null;
    if (param is! Uint8List || _token == null || protocol != _tokenProtocol) return false;
    final mac = hmacSha256(_token!, clientDataHash);
    final expected = _tokenProtocol == 1 ? mac.sublist(0, 16) : mac;
    if (_hex(param) != _hex(expected)) return false;
    if (_tokenPermissions != null && _tokenPermissions! & permission == 0) return false;
    if (_tokenRpId != null && _tokenRpId != rpId) return false;
    return true;
  }

  Future<Uint8List> _makeCredential(Map<Object, Object?> p) async {
    final hash = p[1]! as Uint8List;
    final rpId = (p[2]! as Map)['id'] as String;
    final verified = _pinVerified(p[8], p[9], hash, kPinPermissionMakeCredential, rpId);
    if (verified == false) return _status(CtapError.pinAuthInvalid);
    if (verified == null && pin != null) return _status(CtapError.pinRequired);
    int? alg;
    for (final param in p[4]! as List) {
      final a = (param as Map)['alg'];
      if (a == kCoseEs256 || (a == kCoseEdDsa && makesEd25519)) {
        alg = a as int;
        break;
      }
    }
    if (alg == null) return _status(CtapError.unsupportedAlgorithm);
    final id = _bytes(48);
    final Map<int, Object?> cose;
    if (alg == kCoseEs256) {
      final key = _newEcKey();
      _credentials[_hex(id)] = _Credential(rpId, alg, ec: key);
      final (x, y) = _point(key);
      cose = {1: 2, 3: kCoseEs256, -1: 1, -2: x, -3: y};
    } else {
      final pair = await c.Ed25519().newKeyPairFromSeed(_bytes(32));
      _credentials[_hex(id)] = _Credential(rpId, alg, ed: pair);
      cose = {1: 1, 3: kCoseEdDsa, -1: 6, -2: Uint8List.fromList((await pair.extractPublicKey()).bytes)};
    }
    final flags = 0x01 | 0x40 | (verified == true ? 0x04 : 0);
    final authData = Uint8List.fromList([
      ...sha256(rpId.codeUnits),
      flags,
      0, 0, 0, 0,
      ...Uint8List(16),
      id.length >> 8, id.length & 0xff,
      ...id,
      ...cborEncode(cose),
    ]);
    return _ok({1: 'none', 2: authData, 3: <Object?, Object?>{}});
  }

  Future<Uint8List> _getAssertion(Map<Object, Object?> p) async {
    final rpId = p[1]! as String;
    final hash = p[2]! as Uint8List;
    final verified = _pinVerified(p[6], p[7], hash, kPinPermissionGetAssertion, rpId);
    if (verified == false) return _status(CtapError.pinAuthInvalid);
    _Credential? credential;
    Uint8List? id;
    for (final allowed in (p[3] as List?) ?? const []) {
      final candidate = (allowed as Map)['id'] as Uint8List;
      final found = _credentials[_hex(candidate)];
      if (found != null && found.rpId == rpId) {
        credential = found;
        id = candidate;
        break;
      }
    }
    if (credential == null) return _status(CtapError.noCredentials);
    final up = (p[5] as Map?)?['up'] != false;
    counter++;
    var flags = (up ? 0x01 : 0) | (verified == true ? 0x04 : 0);
    var application = rpId;
    var extra = <int>[];
    if (lie == SoftKeyLie.otherApplication) application = 'not-$rpId';
    if (lie == SoftKeyLie.noTouch) flags &= ~0x01;
    if (lie == SoftKeyLie.extensions) {
      flags |= 0x80;
      extra = cborEncode({'hmac-secret': true});
    }
    final authData = Uint8List.fromList([
      ...sha256(application.codeUnits),
      flags,
      (counter >> 24) & 0xff, (counter >> 16) & 0xff, (counter >> 8) & 0xff, counter & 0xff,
      ...extra,
    ]);
    final signed = Uint8List.fromList([...authData, ...hash]);
    Uint8List signature;
    if (credential.alg == kCoseEs256) {
      final key = lie == SoftKeyLie.otherKeySigns ? _newEcKey() : credential.ec!;
      final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))..init(true, PrivateKeyParameter<ECPrivateKey>(key));
      final sig = signer.generateSignature(signed) as ECSignature;
      signature = derOf(sig.r, sig.s);
    } else {
      final pair = lie == SoftKeyLie.otherKeySigns ? await c.Ed25519().newKeyPairFromSeed(_bytes(32)) : credential.ed!;
      signature = Uint8List.fromList((await c.Ed25519().sign(signed, keyPair: pair)).bytes);
    }
    if (lie == SoftKeyLie.badSignature) signature[signature.length - 1] ^= 0x01;
    return _ok({
      1: {'id': id, 'type': 'public-key'},
      2: authData,
      3: signature,
    });
  }
}

/// (r, s) as ASN.1 DER.
Uint8List derOf(BigInt r, BigInt s) {
  List<int> integer(BigInt n) {
    var bytes = _fixed32(n).toList();
    while (bytes.length > 1 && bytes[0] == 0) {
      bytes = bytes.sublist(1);
    }
    if (bytes[0] & 0x80 != 0) bytes = [0, ...bytes];
    return [0x02, bytes.length, ...bytes];
  }

  final body = [...integer(r), ...integer(s)];
  return Uint8List.fromList([0x30, body.length, ...body]);
}

/// A [CtapDevice] behind NFC's raw side: an ISO 7816-4 card with the FIDO
/// applet. [chunk] is how much of an answer it gives at a time (the rest by
/// GET RESPONSE); [working] how many times it says "still working" first.
class SoftNfcCard implements ApduChannel {
  SoftNfcCard(this.key, {this.chunk = 255, this.working = 0, this.isFido = true, this.leavesAfter});

  final CtapDevice key;
  final int chunk;
  int working;
  final bool isFido;

  /// The card leaves the field after this many commands.
  int? leavesAfter;

  final List<Uint8List> seen = [];
  final BytesBuilder _message = BytesBuilder();
  Uint8List? _answer;
  int _given = 0;

  Uint8List _sw(int sw, [List<int> data = const []]) => Uint8List.fromList([...data, sw >> 8, sw & 0xff]);

  Uint8List _next() {
    final answer = _answer!;
    final end = _given + chunk < answer.length ? _given + chunk : answer.length;
    final part = answer.sublist(_given, end);
    _given = end;
    final left = answer.length - end;
    if (left == 0) {
      _answer = null;
      return _sw(0x9000, part);
    }
    return _sw(0x6100 | (left > 255 ? 0 : left), part);
  }

  @override
  Future<Uint8List> transceive(Uint8List command) async {
    seen.add(command);
    if (leavesAfter != null && seen.length > leavesAfter!) throw StateError('Tag was lost.');
    final cla = command[0], ins = command[1];
    if (cla == 0x00 && ins == 0xa4) {
      if (!isFido) return _sw(0x6a82);
      return _sw(0x9000, 'FIDO_2_0'.codeUnits);
    }
    if (ins == 0x10 && (cla == 0x80 || cla == 0x90)) {
      final length = command[4];
      _message.add(command.sublist(5, 5 + length));
      if (cla == 0x90) return _sw(0x9000);
      final request = _message.takeBytes();
      _answer = await key.cbor(request);
      _given = 0;
      if (working > 0 && command[2] & 0x80 != 0) {
        working--;
        return _sw(0x9100, [0x01]);
      }
      return _next();
    }
    if (cla == 0x80 && ins == 0x11) {
      if (working > 0) {
        working--;
        return _sw(0x9100, [0x02]);
      }
      return _next();
    }
    if (cla == 0x00 && ins == 0xc0) return _next();
    return _sw(0x6d00);
  }
}

/// A [CtapDevice] behind USB's raw side: 64 byte reports. [keepalives] are
/// the statuses it sends before an answer (1 working, 2 touch needed);
/// [noise] puts a packet of another channel before each of its own.
class SoftHid implements HidChannel {
  SoftHid(this.key, {this.keepalives = const [], this.noise = false, this.unpluggedAfter});

  final CtapDevice key;
  final List<int> keepalives;
  final bool noise;

  /// It is unplugged after this many reports written to it.
  int? unpluggedAfter;

  static const int channelId = 0x00c0ffee;
  final Queue<Uint8List> _out = Queue();
  final List<Uint8List> written = [];

  int? _cid;
  int _command = 0;
  int _length = 0;
  final BytesBuilder _payload = BytesBuilder();
  bool cancelled = false;

  void _queue(int cid, int command, List<int> payload) {
    void put(Uint8List report) {
      if (noise) {
        _out.add(Uint8List(64)
          ..[0] = 0x11
          ..[1] = 0x22
          ..[2] = 0x33
          ..[3] = 0x44
          ..[4] = 0x80 | 0x10
          ..[6] = 3);
      }
      _out.add(report);
    }

    final first = Uint8List(64)
      ..[0] = (cid >> 24) & 0xff
      ..[1] = (cid >> 16) & 0xff
      ..[2] = (cid >> 8) & 0xff
      ..[3] = cid & 0xff
      ..[4] = 0x80 | command
      ..[5] = payload.length >> 8
      ..[6] = payload.length & 0xff;
    var at = min(57, payload.length);
    first.setRange(7, 7 + at, payload);
    put(first);
    for (var seq = 0; at < payload.length; seq++) {
      final take = min(59, payload.length - at);
      put(Uint8List(64)
        ..[0] = (cid >> 24) & 0xff
        ..[1] = (cid >> 16) & 0xff
        ..[2] = (cid >> 8) & 0xff
        ..[3] = cid & 0xff
        ..[4] = seq
        ..setRange(5, 5 + take, payload, at));
      at += take;
    }
  }

  @override
  Future<void> write(Uint8List report) async {
    written.add(report);
    if (unpluggedAfter != null && written.length > unpluggedAfter!) throw StateError('device detached');
    if (report.length != 64) throw StateError('a report of ${report.length} bytes');
    final cid = (report[0] << 24) | (report[1] << 16) | (report[2] << 8) | report[3];
    if (report[4] & 0x80 != 0) {
      _cid = cid;
      _command = report[4] & 0x7f;
      _length = (report[5] << 8) | report[6];
      _payload.clear();
      _payload.add(report.sublist(7, 7 + min(57, _length)));
    } else {
      _payload.add(report.sublist(5, 5 + min(59, _length - _payload.length)));
    }
    if (_payload.length < _length) return;
    final payload = _payload.takeBytes();
    switch (_command) {
      case 0x06:
        _queue(0xffffffff, 0x06, [
          ...payload,
          (channelId >> 24) & 0xff, (channelId >> 16) & 0xff, (channelId >> 8) & 0xff, channelId & 0xff,
          2, 5, 4, 3, 0x04,
        ]);
      case 0x10:
        if (_cid != channelId) {
          _queue(_cid!, 0x3f, [0x0b]);
          return;
        }
        for (final status in keepalives) {
          _queue(channelId, 0x3b, [status]);
        }
        _queue(channelId, 0x10, await key.cbor(payload));
      case 0x11:
        cancelled = true;
      default:
        _queue(_cid!, 0x3f, [0x01]);
    }
  }

  @override
  Future<Uint8List> read(Duration timeout) async {
    if (_out.isEmpty) throw StateError('no report in $timeout');
    return _out.removeFirst();
  }
}
