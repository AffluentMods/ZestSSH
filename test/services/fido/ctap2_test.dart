import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as c;
import 'package:zestssh/services/fido/ctap2.dart';
import 'package:zestssh/services/fido/fido_hid.dart';
import 'package:zestssh/services/fido/fido_nfc.dart';
import 'package:zestssh/services/fido/sk_ssh.dart';
import 'package:pointycastle/export.dart';
import 'package:flutter_test/flutter_test.dart';

import 'soft_key.dart';

final Uint8List _user = Uint8List.fromList(List.generate(32, (i) => i));
final Uint8List _challenge = sha256('a new key'.codeUnits);

Future<SkKey> _make(Ctap2 ctap, int alg, {int flags = kSkUserPresenceRequired, PinToken? pin, String application = 'ssh:'}) async {
  final made = await ctap.makeCredential(
    clientDataHash: _challenge,
    rpId: application,
    userId: _user,
    userName: 'openssh',
    alg: alg,
    pin: pin,
  );
  return SkKey.made(made, application: application, flags: flags);
}

Future<Uint8List> _sign(Ctap2 ctap, SkKey key, Uint8List data, {PinToken? pin}) async => skSignature(
      key,
      data,
      await ctap.getAssertion(
        rpId: key.application,
        clientDataHash: sha256(data),
        credentialId: key.keyHandle,
        userPresence: key.touchRequired,
        pin: pin,
      ),
    );

/// Reads an sk signature as a server does and checks it over [data] with
/// nothing of the app's: the fields by hand, the check by the libraries.
Future<bool> _serverAccepts(SkKey key, Uint8List data, Uint8List blob) async {
  var at = 0;
  Uint8List string() {
    final n = (blob[at] << 24) | (blob[at + 1] << 16) | (blob[at + 2] << 8) | blob[at + 3];
    at += 4;
    final out = blob.sublist(at, at + n);
    at += n;
    return out;
  }

  if (utf8.decode(string()) != key.algorithm) return false;
  final signature = string();
  final flags = blob[at++];
  final counter = (blob[at] << 24) | (blob[at + 1] << 16) | (blob[at + 2] << 8) | blob[at + 3];
  at += 4;
  if (at != blob.length) return false;
  final signed = skSignedMessage(key.application, flags, counter, data);
  if (key.algorithm == kSkEd25519) {
    return c.Ed25519().verify(signed,
        signature: c.Signature(signature, publicKey: c.SimplePublicKey(key.publicKey, type: c.KeyPairType.ed25519)));
  }
  // string(mpint r, mpint s)
  var p = 0;
  BigInt mpint() {
    final n = (signature[p] << 24) | (signature[p + 1] << 16) | (signature[p + 2] << 8) | signature[p + 3];
    p += 4;
    final v = signature.sublist(p, p + n).fold(BigInt.zero, (a, b) => (a << 8) | BigInt.from(b));
    p += n;
    return v;
  }

  final r = mpint(), s = mpint();
  final domain = ECCurve_secp256r1();
  final verifier = ECDSASigner(SHA256Digest())
    ..init(false, PublicKeyParameter<ECPublicKey>(ECPublicKey(domain.curve.decodePoint(key.publicKey), domain)));
  return verifier.verifySignature(signed, ECSignature(r, s));
}

void main() {
  final data = Uint8List.fromList(utf8.encode('what SSH asks to be signed: the session id and the request'));

  group('what a key says of itself', () {
    test('a CTAP 2.1 key: its versions, PIN protocols (two preferred), and the kinds of key it makes', () async {
      final info = await Ctap2(SoftKey(pin: '1234')).getInfo();
      expect(info.versions, contains('FIDO_2_1'));
      expect(info.pinSet, isTrue);
      expect(info.pinProtocol, 2);
      expect(info.pinTokenWithPermissions, isTrue);
      expect(info.makes(kCoseEdDsa), isTrue);
      expect(info.maxMsgSize, 1200);
    });

    test('a CTAP 2.0 key speaks protocol one, lists no kinds (which is not none), and may have no PIN set', () async {
      final info = await Ctap2(SoftKey(tokensWithPermissions: false, listsAlgorithms: false)).getInfo();
      expect(info.pinProtocol, 1);
      expect(info.pinTokenWithPermissions, isFalse);
      expect(info.pinSet, isFalse);
      expect(info.makes(kCoseEdDsa), isTrue);
      final p256Only = await Ctap2(SoftKey(makesEd25519: false)).getInfo();
      expect(p256Only.makes(kCoseEdDsa), isFalse);
      expect(p256Only.makes(kCoseEs256), isTrue);
    });
  });

  for (final (name, alg, algorithm) in [('Ed25519', kCoseEdDsa, kSkEd25519), ('P-256', kCoseEs256, kSkEcdsa)]) {
    group('an $name key', () {
      test('is made on the key, and its signature is one a server takes', () async {
        final soft = SoftKey();
        final ctap = Ctap2(soft);
        final key = await _make(ctap, alg);
        expect(key.algorithm, algorithm);
        expect(key.keyHandle, hasLength(48));
        expect(key.authorizedKey('alex@laptop'), startsWith('$algorithm AAAA'));
        final blob = await _sign(ctap, key, data);
        expect(await _serverAccepts(key, data, blob), isTrue);
        expect(await _serverAccepts(key, Uint8List.fromList([...data, 1]), blob), isFalse, reason: 'other data');
        // The request named the application, the hash of the data and this key's handle alone.
        expect(soft.lastRequest![1], 'ssh:');
        expect(soft.lastRequest![2], sha256(data));
        expect(soft.lastRequest![3], [
          {'id': key.keyHandle, 'type': 'public-key'}
        ]);
        expect(soft.lastRequest!.containsKey(5), isFalse, reason: 'a touch is the default');
      });

      test('made no-touch-required asks the key for no touch', () async {
        final soft = SoftKey();
        final ctap = Ctap2(soft);
        final key = await _make(ctap, alg, flags: 0);
        final blob = await _sign(ctap, key, data);
        expect(soft.lastRequest![5], {'up': false});
        expect(await _serverAccepts(key, data, blob), isTrue);
      });

      test('a key that lies is refused before anything is sent to a server', () async {
        for (final lie in [
          SoftKeyLie.otherApplication,
          SoftKeyLie.noTouch,
          SoftKeyLie.extensions,
          SoftKeyLie.badSignature,
          SoftKeyLie.otherKeySigns,
        ]) {
          final soft = SoftKey();
          final ctap = Ctap2(soft);
          final key = await _make(ctap, alg);
          soft.lie = lie;
          await expectLater(_sign(ctap, key, data), throwsA(isA<SkSignatureError>()), reason: '$lie');
        }
      });

      test('another key held to the phone has no such credential', () async {
        final key = await _make(Ctap2(SoftKey(seed: 1)), alg);
        await expectLater(
          _sign(Ctap2(SoftKey(seed: 2)), key, data),
          throwsA(isA<CtapError>().having((e) => e.status, 'status', CtapError.noCredentials)),
        );
      });
    });
  }

  group('a key with a PIN', () {
    for (final (name, soft) in [
      ('CTAP 2.1, protocol two, a token with permissions', () => SoftKey(pin: '1234')),
      ('CTAP 2.1 speaking protocol one only', () => SoftKey(pin: '1234', pinProtocols: const [1])),
      ('CTAP 2.0, protocol one, a token for anything', () => SoftKey(pin: '1234', tokensWithPermissions: false)),
    ]) {
      test('$name: the PIN makes a key and a verified signature', () async {
        final key0 = soft();
        final ctap = Ctap2(key0);
        final info = await ctap.getInfo();
        await expectLater(
          _make(ctap, kCoseEdDsa),
          throwsA(isA<CtapError>().having((e) => e.status, 'status', CtapError.pinRequired)),
        );
        final forMaking = await ctap.pinToken(info, utf8.encode('1234'), permissions: kPinPermissionMakeCredential, rpId: 'ssh:');
        final key = await _make(ctap, kCoseEdDsa, flags: kSkUserPresenceRequired | kSkUserVerificationRequired, pin: forMaking);
        // A verify-required key is not signed for without the PIN.
        await expectLater(_sign(ctap, key, data), throwsA(isA<SkSignatureError>()));
        final forSigning = await ctap.pinToken(info, utf8.encode('1234'), permissions: kPinPermissionGetAssertion, rpId: 'ssh:');
        final blob = await _sign(ctap, key, data, pin: forSigning);
        expect(await _serverAccepts(key, data, blob), isTrue);
        // (flags: touch and verified)
        expect(blob[blob.length - 5] & 0x05, 0x05);
      });
    }

    test('a token for signing does not make a key, and one for another application signs nothing (CTAP 2.1)', () async {
      final ctap = Ctap2(SoftKey(pin: '1234'));
      final info = await ctap.getInfo();
      final forSigning = await ctap.pinToken(info, utf8.encode('1234'), permissions: kPinPermissionGetAssertion, rpId: 'ssh:');
      await expectLater(
        _make(ctap, kCoseEdDsa, pin: forSigning),
        throwsA(isA<CtapError>().having((e) => e.status, 'status', CtapError.pinAuthInvalid)),
      );
    });

    test('a wrong PIN is said as wrong, the tries left go down, and the last one blocks it', () async {
      final soft = SoftKey(pin: '1234')..pinRetries = 3;
      final ctap = Ctap2(soft);
      final info = await ctap.getInfo();
      Future<void> wrong(int status) => expectLater(
            ctap.pinToken(info, utf8.encode('0000'), permissions: kPinPermissionGetAssertion, rpId: 'ssh:'),
            throwsA(isA<CtapError>().having((e) => e.status, 'status', status)),
          );
      await wrong(CtapError.pinInvalid);
      expect(await ctap.pinRetries(), 2);
      await wrong(CtapError.pinInvalid);
      await wrong(CtapError.pinBlocked);
      expect(await ctap.pinRetries(), 0);
      // The right PIN no longer opens it.
      await expectLater(
        ctap.pinToken(info, utf8.encode('1234'), permissions: kPinPermissionGetAssertion, rpId: 'ssh:'),
        throwsA(isA<CtapError>().having((e) => e.status, 'status', CtapError.pinBlocked)),
      );
    });

    test('a key with no PIN set says so', () async {
      final ctap = Ctap2(SoftKey());
      await expectLater(
        ctap.pinToken(await ctap.getInfo(), utf8.encode('1234'), permissions: kPinPermissionGetAssertion, rpId: 'ssh:'),
        throwsA(isA<CtapError>().having((e) => e.status, 'status', CtapError.pinNotSet)),
      );
    });

    test('a PIN that is not ASCII is sent as UTF-8', () async {
      final ctap = Ctap2(SoftKey(pin: String.fromCharCodes(utf8.encode('päss✓'))));
      final token = await ctap.pinToken(await ctap.getInfo(), utf8.encode('päss✓'),
          permissions: kPinPermissionGetAssertion, rpId: 'ssh:');
      expect(token.authParam(Uint8List(32)), hasLength(32));
    });
  });

  group('answers that are not what the protocol allows', () {
    test('an answer that is not CBOR, and one that is empty', () async {
      final soft = SoftKey()..lie = SoftKeyLie.garbageAnswer;
      await expectLater(Ctap2(soft).getInfo(), throwsA(isA<CtapProtocolError>()));
      await expectLater(Ctap2(_Fixed(Uint8List(0))).getInfo(), throwsA(isA<CtapProtocolError>()));
      await expectLater(Ctap2(_Fixed(Uint8List.fromList([0, 0x01]))).getInfo(), throwsA(isA<CtapProtocolError>()),
          reason: 'a number, not a map');
    });

    test('a status that is not success is a refusal with that status', () async {
      await expectLater(
        Ctap2(_Fixed(Uint8List.fromList([0x2f]))).getInfo(),
        throwsA(isA<CtapError>().having((e) => e.status, 'status', CtapError.userActionTimeout)),
      );
    });

    test('a key agreement point that is not on the curve is not agreed with', () async {
      final soft = SoftKey(pin: '1234');
      final ctap = Ctap2(_OffCurve(soft));
      await expectLater(
        ctap.pinToken(await ctap.getInfo(), utf8.encode('1234'), permissions: kPinPermissionGetAssertion, rpId: 'ssh:'),
        throwsA(isA<CtapProtocolError>()),
      );
      expect(soft.commands.where((c) => c == 0x06), hasLength(1), reason: 'the PIN was not sent after it');
    });

    test('an ECDSA signature that is not strict DER', () {
      final good = derOf(BigInt.from(0x1234), BigInt.parse('ff' * 32, radix: 16));
      expect(ecdsaNumbersOfDer(good).$1, [0x12, 0x34]);
      expect(ecdsaNumbersOfDer(good).$2, [0, ...List.filled(32, 0xff)]);
      for (final bad in <List<int>>[
        [],
        [0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01], // cut short
        [0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01, 0x00], // a byte after
        [0x31, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01], // not a sequence
        [0x30, 0x81, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01], // a long-form length
        [0x30, 0x06, 0x02, 0x01, 0x81, 0x02, 0x01, 0x01], // a negative number
        [0x30, 0x07, 0x02, 0x02, 0x00, 0x01, 0x02, 0x01, 0x01], // a zero too many
        [0x30, 0x06, 0x02, 0x00, 0x02, 0x02, 0x01, 0x01], // an empty number
        [0x30, 0x06, 0x04, 0x01, 0x01, 0x02, 0x01, 0x01], // not an integer
      ]) {
        expect(() => ecdsaNumbersOfDer(Uint8List.fromList(bad)), throwsA(isA<SkSignatureError>()), reason: '$bad');
      }
    });
  });

  group('over NFC', () {
    test('a message longer than one command goes in chained pieces, and an answer in pieces is collected', () async {
      final soft = SoftKey();
      final card = SoftNfcCard(soft, chunk: 40);
      final nfc = NfcCtapDevice(card, pause: () async {});
      final ctap = Ctap2(nfc);
      final made = await ctap.makeCredential(
        clientDataHash: _challenge,
        rpId: 'ssh:',
        userId: _user,
        userName: 'a name long enough that the message does not fit one command: ${'x' * 220}',
        alg: kCoseEs256,
      );
      expect(nfc.appletVersion, 'FIDO_2_0');
      final key = SkKey.made(made, application: 'ssh:', flags: kSkUserPresenceRequired);
      expect(await _serverAccepts(key, data, await _sign(ctap, key, data)), isTrue);
      final chained = card.seen.where((apdu) => apdu[0] == 0x90).toList();
      expect(chained, isNotEmpty);
      expect(chained.every((apdu) => apdu[4] == 240 && apdu.length == 245), isTrue);
      expect(card.seen.where((apdu) => apdu[1] == 0xc0), isNotEmpty, reason: 'GET RESPONSE for the rest');
      // The applet is selected once.
      expect(card.seen.where((apdu) => apdu[1] == 0xa4), hasLength(1));
    });

    test('a key that is still working is asked again until it answers', () async {
      var waited = 0;
      final card = SoftNfcCard(SoftKey(), working: 3);
      final ctap = Ctap2(NfcCtapDevice(card, onWaiting: () => waited++, pause: () async {}));
      expect((await ctap.getInfo()).versions, contains('FIDO_2_0'));
      expect(waited, 3);
      expect(card.seen.where((apdu) => apdu[0] == 0x80 && apdu[1] == 0x11), hasLength(3));
    });

    test('a card that is not a security key, and a key taken away too soon', () async {
      await expectLater(
        Ctap2(NfcCtapDevice(SoftNfcCard(SoftKey(), isFido: false))).getInfo(),
        throwsA(isA<CtapTransportError>().having((e) => e.message, 'message', contains('not a FIDO security key'))),
      );
      await expectLater(
        Ctap2(NfcCtapDevice(SoftNfcCard(SoftKey(), chunk: 10, leavesAfter: 3))).getInfo(),
        throwsA(isA<CtapTransportError>().having((e) => e.message, 'message', contains('left the NFC field'))),
      );
    });

    test('a key that never finishes is given up on', () async {
      await expectLater(
        Ctap2(NfcCtapDevice(SoftNfcCard(SoftKey(), working: 1 << 20), pause: () async {})).getInfo(),
        throwsA(isA<CtapTransportError>()),
      );
    });
  });

  group('over USB', () {
    test('a channel is opened once, a long message and its answer go in packets, and another program\'s are passed over',
        () async {
      final hid = SoftHid(SoftKey(), noise: true);
      final usb = HidCtapDevice(hid);
      final ctap = Ctap2(usb);
      final made = await ctap.makeCredential(
        clientDataHash: _challenge,
        rpId: 'ssh:',
        userId: _user,
        userName: 'a name long enough that the message needs several packets: ${'y' * 150}',
        alg: kCoseEdDsa,
      );
      final key = SkKey.made(made, application: 'ssh:', flags: kSkUserPresenceRequired);
      expect(await _serverAccepts(key, data, await _sign(ctap, key, data)), isTrue);
      expect(usb.capabilities & 0x04, 0x04);
      expect(hid.written.every((r) => r.length == 64), isTrue);
      // One INIT on the broadcast channel, everything else on the channel it gave.
      final inits = hid.written.where((r) => r[4] == 0x86).toList();
      expect(inits, hasLength(1));
      expect(inits.single.sublist(0, 4), [0xff, 0xff, 0xff, 0xff]);
      expect(hid.written.where((r) => r[4] != 0x86).every((r) => r[0] == 0x00 && r[1] == 0xc0 && r[2] == 0xff && r[3] == 0xee),
          isTrue);
      // Continuation packets are numbered from nought.
      expect(hid.written.where((r) => r[4] & 0x80 == 0).map((r) => r[4]).take(2), [0, 1]);
    });

    test('while the key waits for a touch the app is told so', () async {
      final said = <bool>[];
      final ctap = Ctap2(HidCtapDevice(SoftHid(SoftKey(), keepalives: const [1, 2, 2]),
          onWaiting: ({required touchNeeded}) => said.add(touchNeeded)));
      await ctap.getInfo();
      expect(said, [false, true, true]);
    });

    test('unplugged, or silent: a transport error, not a hang', () async {
      await expectLater(
        Ctap2(HidCtapDevice(SoftHid(SoftKey(), unpluggedAfter: 1))).getInfo(),
        throwsA(isA<CtapTransportError>().having((e) => e.message, 'message', contains('unplugged'))),
      );
      await expectLater(Ctap2(HidCtapDevice(_Silent())).getInfo(), throwsA(isA<CtapTransportError>()));
    });

    test('Cancel tells the key to stop waiting', () async {
      final hid = SoftHid(SoftKey());
      final usb = HidCtapDevice(hid);
      await Ctap2(usb).getInfo();
      await usb.cancel();
      expect(hid.cancelled, isTrue);
    });

    test('a message longer than USB carries is not sent', () async {
      final hid = SoftHid(SoftKey());
      await expectLater(HidCtapDevice(hid).cbor(Uint8List(HidCtapDevice.maxMessage + 1)), throwsA(isA<CtapTransportError>()));
    });
  });

  group('OpenSSH itself', () {
    final sshKeygen = _which('ssh-keygen');

    for (final (name, alg) in [('Ed25519', kCoseEdDsa), ('P-256', kCoseEs256)]) {
      test('ssh-keygen -Y verify takes an $name signature made through this code', () async {
        final ctap = Ctap2(SoftKey());
        final key = await _make(ctap, alg);
        final message = utf8.encode('signed by a security key that is software\n');
        // PROTOCOL.sshsig: what is signed, then the armoured signature.
        const namespace = 'file';
        final toSign = _ssh([
          'SSHSIG'.codeUnits,
          _str(utf8.encode(namespace)),
          _str(const []),
          _str('sha512'.codeUnits),
          _str(SHA512Digest().process(Uint8List.fromList(message))),
        ]);
        final signature = await _sign(ctap, key, toSign);
        final blob = _ssh([
          'SSHSIG'.codeUnits,
          [0, 0, 0, 1],
          _str(key.publicBlob),
          _str(utf8.encode(namespace)),
          _str(const []),
          _str('sha512'.codeUnits),
          _str(signature),
        ]);
        final dir = Directory.systemTemp.createTempSync('sk-sshsig-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final body = base64.encode(blob).replaceAllMapped(RegExp('.{1,70}'), (m) => '${m[0]}\n');
        File('${dir.path}/message.sig')
            .writeAsStringSync('-----BEGIN SSH SIGNATURE-----\n$body-----END SSH SIGNATURE-----\n');
        File('${dir.path}/allowed').writeAsStringSync('alex@example.com ${key.authorizedKey()}\n');
        final verify = await Process.start(sshKeygen!, [
          '-Y', 'verify', '-f', '${dir.path}/allowed', '-I', 'alex@example.com', '-n', namespace, '-s', '${dir.path}/message.sig', //
        ]);
        verify.stdin.add(message);
        await verify.stdin.close();
        final out = await verify.stdout.transform(utf8.decoder).join();
        final err = await verify.stderr.transform(utf8.decoder).join();
        expect(await verify.exitCode, 0, reason: '$out\n$err');
        expect(out, contains('Good "file" signature for alex@example.com'));
      }, skip: sshKeygen == null ? 'no ssh-keygen on this computer' : null);
    }
  });
}

String? _which(String program) {
  try {
    final r = Process.runSync(Platform.isWindows ? 'where' : 'which', [program]);
    final first = '${r.stdout}'.trim().split('\n').first.trim();
    return r.exitCode == 0 && first.isNotEmpty ? first : null;
  } catch (_) {
    return null;
  }
}

List<int> _str(List<int> bytes) =>
    [(bytes.length >> 24) & 0xff, (bytes.length >> 16) & 0xff, (bytes.length >> 8) & 0xff, bytes.length & 0xff, ...bytes];

Uint8List _ssh(List<List<int>> parts) => Uint8List.fromList([for (final p in parts) ...p]);

class _Fixed implements CtapDevice {
  _Fixed(this.answer);

  final Uint8List answer;

  @override
  Future<Uint8List> cbor(Uint8List request) async => answer;
}

/// A key whose key agreement point is not on P-256.
class _OffCurve implements CtapDevice {
  _OffCurve(this.inner);

  final SoftKey inner;

  @override
  Future<Uint8List> cbor(Uint8List request) async {
    if (request[0] == 0x06 && request.length > 4 && request[4] == 0x02) {
      await inner.cbor(request);
      // {1: {1: 2, 3: -25, -1: 1, -2: x, -3: y}} with x = 1, y = 1.
      final one = Uint8List(32)..[31] = 1;
      return Uint8List.fromList([
        0,
        0xa1, 0x01, 0xa5, 0x01, 0x02, 0x03, 0x38, 0x18, 0x20, 0x01, 0x21, 0x58, 0x20, ...one, 0x22, 0x58, 0x20, ...one,
      ]);
    }
    return inner.cbor(request);
  }
}

class _Silent implements HidChannel {
  @override
  Future<void> write(Uint8List report) async {}

  @override
  Future<Uint8List> read(Duration timeout) async => throw StateError('nothing came in $timeout');
}
