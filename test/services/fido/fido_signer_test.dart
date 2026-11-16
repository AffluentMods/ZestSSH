import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/fido/ctap2.dart';
import 'package:zestssh/services/fido/fido_key_pair.dart';
import 'package:zestssh/services/fido/fido_platform.dart';
import 'package:zestssh/services/fido/fido_signer.dart';
import 'package:zestssh/services/fido/sk_ssh.dart';
import 'package:zestssh/services/hardware_token/os_agent_key_pair.dart';

import 'soft_key.dart';
import 'test_phone.dart';

/// What the sheet would do: remembers every step shown, and types the PINs
/// it was given, one for each time one is asked.
class _Person {
  _Person(this.signer, {List<String> pins = const []}) : _pins = [...pins] {
    signer.prompt.addListener(_see);
  }

  final FidoSigner signer;
  final List<String> _pins;
  final List<FidoPrompt> seen = [];

  /// Called at each step shown, after it is remembered.
  void Function(FidoPrompt prompt)? at;

  List<FidoStep> get steps => [for (final p in seen) p.step];

  void _see() {
    final p = signer.prompt.value;
    if (p == null) return;
    seen.add(p);
    at?.call(p);
    if (p.step == FidoStep.pin && _pins.isNotEmpty) {
      final pin = _pins.removeAt(0);
      scheduleMicrotask(() => signer.submitPin(pin));
    }
  }

  void leave() => signer.prompt.removeListener(_see);
}

Matcher _fails(FidoFailureKind kind) => throwsA(isA<FidoFailure>().having((f) => f.kind, 'kind', kind));

void main() {
  final data = Uint8List.fromList('the session and the request'.codeUnits);

  /// A key made on [soft], as an identity holds it.
  Future<OpenSSHSkKeyPair> keyOn(SoftKey soft, {bool ed25519 = true, int flags = kSkUserPresenceRequired, String? pin}) async {
    final ctap = Ctap2(soft);
    PinToken? token;
    if (pin != null) {
      token = await ctap.pinToken(await ctap.getInfo(), pin.codeUnits, permissions: kPinPermissionMakeCredential, rpId: 'ssh:');
    }
    final made = await ctap.makeCredential(
      clientDataHash: Uint8List(32),
      rpId: 'ssh:',
      userId: Uint8List(32),
      userName: 'openssh',
      alg: ed25519 ? kCoseEdDsa : kCoseEs256,
      pin: token,
    );
    final sk = SkKey.made(made, application: 'ssh:', flags: flags);
    return OpenSSHSkKeyPair(
      type: sk.algorithm,
      publicKey: sk.publicKey,
      application: 'ssh:',
      flags: flags,
      keyHandle: sk.keyHandle,
    );
  }

  group('signing in', () {
    test('over NFC with no PIN: hold the key, and the signature comes back, the sheet gone', () async {
      final soft = SoftKey();
      final key = await keyOn(soft);
      final phone = TestPhone(waysNow: const FidoWays(nfc: true, nfcOn: true, usb: false))..cards.add(SoftNfcCard(soft));
      final signer = FidoSigner(platform: phone);
      final person = _Person(signer);
      final blob = await signer.sign(key, data, label: 'web-01');
      expect(blob.sublist(4, 4 + key.type.length), key.type.codeUnits);
      expect(person.steps, [FidoStep.present, FidoStep.working]);
      expect(person.seen.first.label, 'web-01');
      expect(person.seen.first.again, isFalse);
      expect(signer.prompt.value, isNull);
      expect(phone.nfcEnded, [null], reason: 'the field is given back, with no error said');
    });

    test('a key that asks for its PIN: the PIN first, then the key; a wrong PIN is asked again with the tries left',
        () async {
      final soft = SoftKey(pin: '1234');
      final key = await keyOn(soft, flags: kSkUserPresenceRequired | kSkUserVerificationRequired, pin: '1234');
      final phone = TestPhone()..cards.add(SoftNfcCard(soft));
      final signer = FidoSigner(platform: phone);
      final person = _Person(signer, pins: ['0000', '1234']);
      final blob = await signer.sign(key, data, label: 'web-01');
      expect(blob, isNotEmpty);
      expect(person.steps, [FidoStep.pin, FidoStep.present, FidoStep.working, FidoStep.working, FidoStep.pin, FidoStep.working]);
      final second = person.seen.where((p) => p.step == FidoStep.pin).last;
      expect(second.pinWrong, isTrue);
      expect(second.pinTriesLeft, 7);
      expect(soft.pinRetries, 8, reason: 'the right PIN gives the tries back');
    });

    test('the key leaves the field before it is done: hold it again, and the PIN is not typed twice', () async {
      final soft = SoftKey(pin: '1234');
      final key = await keyOn(soft, flags: kSkUserPresenceRequired | kSkUserVerificationRequired, pin: '1234');
      final phone = TestPhone()
        ..cards.addAll([SoftNfcCard(soft, chunk: 20, leavesAfter: 4), SoftNfcCard(soft)]);
      final signer = FidoSigner(platform: phone);
      final person = _Person(signer, pins: ['1234']);
      expect(await signer.sign(key, data, label: 'web-01'), isNotEmpty);
      expect(person.steps.where((s) => s == FidoStep.pin), hasLength(1));
      final presents = person.seen.where((p) => p.step == FidoStep.present).toList();
      expect(presents.map((p) => p.again), [false, true]);
      expect(phone.nfcBegun, 2);
    });

    test('a key that keeps leaving is given up on', () async {
      final soft = SoftKey();
      final key = await keyOn(soft);
      final phone = TestPhone()..cards.addAll([for (var i = 0; i < 8; i++) SoftNfcCard(soft, leavesAfter: 1)]);
      await expectLater(FidoSigner(platform: phone).sign(key, data, label: 'x'), _fails(FidoFailureKind.keyLeft));
      expect(phone.nfcBegun, 5);
    });

    test('Cancel while the key is waited for ends it, and the field is given back', () async {
      final key = await keyOn(SoftKey());
      final phone = TestPhone(waysNow: const FidoWays(nfc: true, nfcOn: true, usb: false));
      final signer = FidoSigner(platform: phone);
      final person = _Person(signer)..at = (p) {
          if (p.step == FidoStep.present) scheduleMicrotask(signer.cancel);
        };
      await expectLater(signer.sign(key, data, label: 'x'), _fails(FidoFailureKind.cancelled));
      expect(phone.nfcCancelled, greaterThan(0));
      expect(signer.prompt.value, isNull);
      person.leave();
    });

    test('Cancel at the PIN ends it before any key is asked for', () async {
      final soft = SoftKey(pin: '1234');
      final key = await keyOn(soft, flags: kSkUserPresenceRequired | kSkUserVerificationRequired, pin: '1234');
      final phone = TestPhone()..cards.add(SoftNfcCard(soft));
      final signer = FidoSigner(platform: phone);
      _Person(signer).at = (p) {
        if (p.step == FidoStep.pin) scheduleMicrotask(signer.cancel);
      };
      await expectLater(signer.sign(key, data, label: 'x'), _fails(FidoFailureKind.cancelled));
      expect(phone.nfcBegun, 0);
    });

    test('what goes wrong is said by its kind', () async {
      final soft = SoftKey();
      final key = await keyOn(soft);
      Future<void> expectKind(FidoFailureKind kind, TestPhone phone, [OpenSSHSkKeyPair? other]) =>
          expectLater(FidoSigner(platform: phone).sign(other ?? key, data, label: 'x'), _fails(kind));

      await expectKind(FidoFailureKind.noWay, TestPhone(waysNow: FidoWays.none));
      await expectKind(FidoFailureKind.nfcOff, TestPhone(waysNow: const FidoWays(nfc: true, nfcOn: false, usb: false)));
      await expectKind(FidoFailureKind.wrongKey, TestPhone()..cards.add(SoftNfcCard(SoftKey(seed: 99))));
      await expectKind(FidoFailureKind.notASecurityKey, TestPhone()..cards.add(SoftNfcCard(soft, isFido: false)));
      await expectKind(FidoFailureKind.denied, TestPhone()..usbDenied = true);
      final liar = SoftKey(seed: 3);
      final liarsKey = await keyOn(liar);
      liar.lie = SoftKeyLie.otherKeySigns;
      await expectKind(FidoFailureKind.misbehaved, TestPhone()..cards.add(SoftNfcCard(liar)), liarsKey);
      liar.lie = SoftKeyLie.garbageAnswer;
      await expectKind(FidoFailureKind.misbehaved, TestPhone()..cards.add(SoftNfcCard(liar)), liarsKey);
    });

    test('a PIN that is blocked, and a key that asks for a PIN it does not have', () async {
      final soft = SoftKey(pin: '1234');
      final key = await keyOn(soft, flags: kSkUserPresenceRequired | kSkUserVerificationRequired, pin: '1234');
      soft.pinRetries = 1;
      final phone = TestPhone()..cards.add(SoftNfcCard(soft));
      final signer = FidoSigner(platform: phone);
      _Person(signer, pins: ['0000']);
      await expectLater(signer.sign(key, data, label: 'x'), _fails(FidoFailureKind.pinBlocked));

      final noPin = SoftKey(seed: 5);
      final asks = OpenSSHSkKeyPair(
        type: OpenSSHSkKeyPair.ed25519Type,
        publicKey: (await keyOn(noPin)).publicKey,
        application: 'ssh:',
        flags: kSkUserPresenceRequired | kSkUserVerificationRequired,
        keyHandle: Uint8List(8),
      );
      final signer2 = FidoSigner(platform: TestPhone()..cards.add(SoftNfcCard(noPin)));
      _Person(signer2, pins: ['1234']);
      await expectLater(signer2.sign(asks, data, label: 'x'), _fails(FidoFailureKind.pinNotSet));
    });
  });

  group('a plugged-in key', () {
    test('is used at once, with no NFC, and the sheet says to touch it when it blinks', () async {
      final soft = SoftKey();
      final key = await keyOn(soft, ed25519: false);
      final phone = TestPhone()..plugged = SoftHid(soft, keepalives: const [1, 2]);
      final signer = FidoSigner(platform: phone);
      final person = _Person(signer);
      expect(await signer.sign(key, data, label: 'web-01'), isNotEmpty);
      expect(phone.nfcBegun, 0);
      expect(person.steps, contains(FidoStep.touch));
      expect(phone.usbClosed, 1);
    });

    test('plugged in while the phone waits for NFC: NFC is let go, and the plugged-in key signs', () async {
      final soft = SoftKey();
      final key = await keyOn(soft);
      final phone = TestPhone();
      final signer = FidoSigner(platform: phone)..plugPoll = const Duration(milliseconds: 5);
      _Person(signer).at = (p) {
        // (A little later: the phone is already waiting for NFC.)
        if (p.step == FidoStep.present) {
          Future<void>.delayed(const Duration(milliseconds: 20), () => phone.plugged = SoftHid(soft));
        }
      };
      expect(await signer.sign(key, data, label: 'x'), isNotEmpty);
      expect(phone.nfcBegun, 1);
      expect(phone.nfcCancelled, greaterThan(0));
    });

    test('with USB alone, a key that is never plugged in is given up on', () async {
      final key = await keyOn(SoftKey());
      final signer = FidoSigner(platform: TestPhone(waysNow: const FidoWays(nfc: false, nfcOn: false, usb: true)))
        ..plugPoll = const Duration(milliseconds: 2)
        ..plugWait = const Duration(milliseconds: 20);
      await expectLater(signer.sign(key, data, label: 'x'), _fails(FidoFailureKind.timedOut));
    });
  });

  group('making a key', () {
    test('Ed25519 on a key with no PIN: its key file\'s parts, which then sign', () async {
      final soft = SoftKey();
      final phone = TestPhone()..cards.addAll([SoftNfcCard(soft), SoftNfcCard(soft)]);
      final signer = FidoSigner(platform: phone);
      final made = await signer.makeKey(ed25519: true, verifyRequired: false, label: 'My key', comment: 'made on a phone');
      expect(made.type, OpenSSHSkKeyPair.ed25519Type);
      expect(made.application, 'ssh:');
      expect(made.flags, kSkUserPresenceRequired);
      expect(made.comment, 'made on a phone');
      final again = SSHKeyPair.fromPem(made.toPem()).single as OpenSSHSkKeyPair;
      expect(again.keyHandle, made.keyHandle);
      expect(await signer.sign(again, data, label: 'web-01'), isNotEmpty);
    });

    test('on a key with a PIN the PIN is asked once the key is there, and the new key can ask for it each time',
        () async {
      final soft = SoftKey(pin: '1234');
      final phone = TestPhone()..cards.add(SoftNfcCard(soft));
      final signer = FidoSigner(platform: phone);
      final person = _Person(signer, pins: ['1234']);
      final made = await signer.makeKey(ed25519: false, verifyRequired: true, label: 'My key');
      expect(made.type, OpenSSHSkKeyPair.ecdsaType);
      expect(made.verifyRequired, isTrue);
      expect(person.steps, [FidoStep.present, FidoStep.working, FidoStep.pin, FidoStep.working]);
    });

    test('a key that makes no Ed25519, and asking for a PIN each time of a key that has none', () async {
      await expectLater(
        FidoSigner(platform: TestPhone()..cards.add(SoftNfcCard(SoftKey(makesEd25519: false))))
            .makeKey(ed25519: true, verifyRequired: false, label: 'x'),
        _fails(FidoFailureKind.cannotMakeKind),
      );
      await expectLater(
        FidoSigner(platform: TestPhone()..cards.add(SoftNfcCard(SoftKey()))).makeKey(ed25519: true, verifyRequired: true, label: 'x'),
        _fails(FidoFailureKind.pinNotSet),
      );
    });
  });

  test('one conversation at a time: a second waits for the first to end', () async {
    final soft = SoftKey();
    final key = await keyOn(soft);
    final phone = TestPhone(waysNow: const FidoWays(nfc: true, nfcOn: true, usb: false));
    final signer = FidoSigner(platform: phone);
    final labels = <String>[];
    signer.prompt.addListener(() {
      final p = signer.prompt.value;
      if (p != null && p.step == FidoStep.present) labels.add(p.label);
    });
    final first = signer.sign(key, data, label: 'first');
    final second = signer.sign(key, data, label: 'second');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(labels, ['first']);
    phone.cards.add(SoftNfcCard(soft));
    signer.cancel();
    await expectLater(first, _fails(FidoFailureKind.cancelled));
    expect(await second, isNotEmpty);
    expect(labels, ['first', 'second']);
  });

  group('as SSH signs in', () {
    tearDown(() => debugSpeaksToSecurityKeys = null);

    test('on a phone a security key\'s key file signs through the phone; a failure ends the sign-in for good', () async {
      debugSpeaksToSecurityKeys = true;
      final soft = SoftKey();
      final key = await keyOn(soft);
      final phone = TestPhone()..cards.add(SoftNfcCard(soft));
      final signer = FidoSigner(platform: phone);
      final pair = withSecurityKeySigners([key], label: 'web-01', signer: signer).single;
      expect(pair, isA<FidoKeyPair>());
      expect(pair.type, key.type);
      expect(pair.toPublicKey().encode(), key.toPublicKey().encode());
      expect(() => pair.sign(data), throwsUnsupportedError);
      expect((await pair.signAsync(data)).encode(), isNotEmpty);
      // No key held to the phone, and the person cancels.
      final waiting = pair.signAsync(data);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      signer.cancel();
      await expectLater(
        waiting,
        throwsA(isA<FidoSignInAborted>()
            .having((e) => e.failure.kind, 'kind', FidoFailureKind.cancelled)
            .having((e) => e, 'ends the sign-in', isA<SSHAuthAbortError>())),
      );
    });

    test('on a computer it is left to the system\'s SSH agent, and every other key is itself', () {
      debugSpeaksToSecurityKeys = false;
      final sk = OpenSSHSkKeyPair(
        type: OpenSSHSkKeyPair.ed25519Type,
        publicKey: Uint8List(32),
        application: 'ssh:',
        flags: 1,
        keyHandle: Uint8List(8),
      );
      final other = OsAgentKeyPair(publicKeyBlob: Uint8List(8), algorithm: 'ssh-ed25519');
      final pairs = withSecurityKeySigners([sk, other], label: 'web-01');
      expect(pairs.first, isA<OsAgentKeyPair>());
      expect((pairs.first as OsAgentKeyPair).algorithm, OpenSSHSkKeyPair.ed25519Type);
      expect((pairs.first as OsAgentKeyPair).publicKeyBlob, sk.toPublicKey().encode());
      expect(pairs.last, same(other));
    });
  });
}
