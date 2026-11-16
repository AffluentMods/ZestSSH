import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/certs/team_certificates.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart';

/// Trusted devices (3.0): what a device signs and commits to, and
/// where it keeps its key.
///
/// The numbers below were worked out by hand, apart from the code here and
/// on the server, whose test holds the same ones (ZestSSH Cloud's
/// test/orchard_devices_lib.test.js): a label or a field that changed on one
/// side fails on that side. The three words are worked out only in the app,
/// on both devices of an approval, so two versions of the app must give the
/// same words for ever: that vector is pinned here.

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

List<int> lp(List<int> b) => [b.length >> 24 & 255, b.length >> 16 & 255, b.length >> 8 & 255, b.length & 255, ...b];

void main() {
  // The secure storage is reached through a platform channel.
  TestWidgetsFlutterBinding.ensureInitialized();
  const orchard = '11111111-1111-4111-8111-111111111111';
  const session = '33333333-3333-4333-8333-333333333333';
  final key = List<int>.generate(32, (i) => i);
  final nonce = List<int>.filled(32, 0xaa);
  final approverNonce = List<int>.filled(32, 0x55);

  test('what a device signs to say a sign-in is its own: the label and the session', () {
    final message = sessionDeviceMessage(session);
    expect(message, [...lp(utf8.encode('zestssh.session-device.v1')), ...lp(utf8.encode(session))]);
    expect(message.length, 69);
    expect(hex(sha256.convert(message).bytes), 'cbe654cd36eb431d14ea25292820aa2ddcb6eed546023ef3c6bfd9a647fd93f0');
    expect(sessionDeviceMessage('44444444-4444-4444-8444-444444444444'), isNot(message));
  });

  test('what a device that asks to be approved commits to: its key and its random value', () {
    final commitment = deviceTrustCommitment(key, nonce);
    expect(commitment, sha256.convert([...utf8.encode('zestssh-device-trust-v1'), ...key, ...nonce]).bytes);
    expect(hex(commitment), '1f6e57cb930da249466fdad49ffa0639ce9ef89b63a646e650b60ea9bd438a46');
    expect(deviceTrustCommitment(nonce, nonce), isNot(commitment));
    expect(deviceTrustCommitment(key, key), isNot(commitment));
    expect(deviceTrustCommitment(nonce, key), isNot(commitment), reason: 'the two are not interchangeable');
  });

  test('what people call a device: eight characters from its key, the same everywhere', () {
    // SHA-256('zestssh-device-code-v1' || the 32 key bytes), its first four
    // bytes in hex, worked out by hand.
    expect(deviceCode(deviceKeyText(key)), '1404-8DAF');
    expect(deviceCode(deviceKeyText(List<int>.filled(32, 0x11))), '68E0-EDCA');
    expect(deviceCode(deviceKeyText(key)), matches(RegExp(r'^[0-9A-F]{4}-[0-9A-F]{4}$')));
    // Anything that is not a key still gets a name, and never throws.
    expect(deviceCode('not a key'), matches(RegExp(r'^[0-9A-F]{4}-[0-9A-F]{4}$')));
    expect(deviceCode('not a key'), isNot(deviceCode('another')));
  });

  test('the three words both devices show, and every part of what they come from', () {
    final commitment = deviceTrustCommitment(key, nonce);
    List<String> words({
      String orchardId = orchard,
      String uid = 'uid-alice',
      List<int>? commit,
      List<int>? approver,
      List<int>? device,
      List<int>? value,
    }) =>
        deviceTrustWords(
          orchardId: orchardId,
          uid: uid,
          commitment: commit ?? commitment,
          approverNonce: approver ?? approverNonce,
          deviceKey: device ?? key,
          nonce: value ?? nonce,
        );
    expect(words(), ['dry', 'keep', 'middle']);
    expect(kDeviceTrustWordCount, 3);
    // Another Orchard, another member, another commitment, another answer,
    // another key or another value: other words (each of these vectors
    // differs in its first 33 bits).
    final others = [
      words(orchardId: '22222222-2222-4222-8222-222222222222'),
      words(uid: 'uid-bob'),
      words(commit: List<int>.filled(32, 1)),
      words(approver: List<int>.filled(32, 0x56)),
      words(device: List<int>.filled(32, 2)),
      words(value: List<int>.filled(32, 0xab)),
    ];
    for (final o in others) {
      expect(o, hasLength(3));
      expect(o, isNot(['dry', 'keep', 'middle']));
    }
    expect({for (final o in [words(), ...others]) o.join(' ')}, hasLength(7));
    // The Orchard and the member do not run together.
    expect(words(orchardId: '${orchard}u', uid: 'id-alice'), isNot(words(orchardId: orchard, uid: 'uid-alice')));
  });

  test('what a device signs under a certificate request: the request the account signs, under its own label', () {
    final request = certRequestMessage(
      orchardId: orchard,
      crateId: '22222222-2222-4222-8222-222222222222',
      requestId: '33333333-3333-4333-8333-333333333333',
      uid: 'uid-alice',
      keyVersion: 2,
      sshPublicKey: key,
      requestedAt: 1790000000,
    );
    final message = certDeviceMessage(request);
    expect(message, [...lp(utf8.encode('zestssh.cert-request.device.v1')), ...lp(request)]);
    expect(message.length, 246);
    expect(hex(sha256.convert(message).bytes), '55ac7dc98265c91a78a21ae6142dfacd81c1424089bb7861158b20bc77ad3a95');
    expect(message, isNot(request), reason: 'the account and the device sign different bytes');
  });

  test('a device signs with its own key, and a signature counts for that key, that message and nothing else', () async {
    final device = await DeviceIdentity.fromSeed(List<int>.filled(32, 7));
    final other = await DeviceIdentity.fromSeed(List<int>.filled(32, 8));
    expect(device.publicKey, hasLength(32));
    expect(device.key, base64Encode(device.publicKey));
    expect((await DeviceIdentity.fromSeed(List<int>.filled(32, 7))).key, device.key, reason: 'the same seed, the same key');
    expect(other.key, isNot(device.key));
    final message = sessionDeviceMessage(session);
    final signature = await device.sign(message);
    expect(signature, hasLength(64));
    expect(await verifyDeviceSignature(device.publicKey, message, signature), isTrue);
    expect(await verifyDeviceSignature(other.publicKey, message, signature), isFalse);
    expect(await verifyDeviceSignature(device.publicKey, sessionDeviceMessage('another'), signature), isFalse);
    expect(await verifyDeviceSignature(device.publicKey, message, await other.sign(message)), isFalse);
    expect(await verifyDeviceSignature(device.publicKey, message, signature.sublist(0, 63)), isFalse);
    expect(await verifyDeviceSignature(device.publicKey.sublist(0, 31), message, signature), isFalse);
    expect(await verifyDeviceSignature(List<int>.filled(32, 0), message, signature), isFalse);
    // A new key is a new one every time.
    expect((await DeviceIdentity.generate()).key, isNot((await DeviceIdentity.generate()).key));
    await expectLater(DeviceIdentity.fromSeed(List<int>.filled(31, 7)), throwsFormatException);
  });

  test('a device key is 32 bytes in the one spelling base64 gives them', () {
    final text = base64Encode(key);
    expect(deviceKeyText(key), text);
    expect(deviceKeyBytes(text), key);
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    final i = text.indexOf('=') - 1;
    final stray = text.replaceRange(i, i + 1, alphabet[alphabet.indexOf(text[i]) | 1]);
    expect(stray, isNot(text));
    for (final bad in <Object?>[
      stray,
      text.replaceAll('=', ''),
      '$text ',
      base64Encode(List<int>.filled(31, 1)),
      base64Encode(List<int>.filled(33, 1)),
      base64Url.encode(List<int>.filled(32, 0xff)),
      '',
      null,
      7,
      Uint8List.fromList(key),
    ]) {
      expect(deviceKeyBytes(bad), isNull, reason: '$bad');
    }
    expect(deviceKeyBytes(base64Encode(List<int>.filled(32, 0xff))), List<int>.filled(32, 0xff));
  });

  group('where the key is kept', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('made once for an account and kept in the secure storage; another account has another', () async {
      const storage = FlutterSecureStorage();
      final store = DeviceIdentityStore(storage);
      expect(await store.read('uid-alice'), isNull);
      final made = await store.forAccount('uid-alice');
      expect((await store.forAccount('uid-alice')).key, made.key);
      expect((await store.read('uid-alice'))!.key, made.key);
      // A store opened later (the app started again) reads the same key.
      expect((await DeviceIdentityStore(storage).forAccount('uid-alice')).key, made.key);
      final bob = await store.forAccount('uid-bob');
      expect(bob.key, isNot(made.key));
      // What is kept is the seed, under a name of its own for each account.
      final all = await storage.readAll();
      expect(all.keys, unorderedEquals(['orchard_device_key_v1.uid-alice', 'orchard_device_key_v1.uid-bob']));
      expect(base64Decode(all['orchard_device_key_v1.uid-alice']!), made.seed);
      expect(DeviceIdentityStore.storageKey('uid-alice'), 'orchard_device_key_v1.uid-alice');
    });

    test('asked twice at once, the key is made once', () async {
      final store = DeviceIdentityStore(const FlutterSecureStorage());
      final both = await Future.wait([store.forAccount('uid-alice'), store.forAccount('uid-alice')]);
      expect(both[0].key, both[1].key);
      expect((await store.forAccount('uid-alice')).key, both[0].key);
    });

    test('forgotten, the device has a new key: one nobody approved', () async {
      final store = DeviceIdentityStore(const FlutterSecureStorage());
      final first = await store.forAccount('uid-alice');
      final bob = await store.forAccount('uid-bob');
      await store.forget('uid-alice');
      expect(await store.read('uid-alice'), isNull);
      expect((await store.forAccount('uid-alice')).key, isNot(first.key));
      expect((await store.forAccount('uid-bob')).key, bob.key, reason: 'the other account keeps its own');
    });

    test('an entry that is not a key is replaced by a new key', () async {
      for (final junk in ['not base64!', base64Encode(List<int>.filled(31, 1)), '']) {
        FlutterSecureStorage.setMockInitialValues({'orchard_device_key_v1.uid-alice': junk});
        const storage = FlutterSecureStorage();
        final store = DeviceIdentityStore(storage);
        expect(await store.read('uid-alice'), isNull, reason: junk);
        final made = await store.forAccount('uid-alice');
        expect(base64Decode((await storage.read(key: 'orchard_device_key_v1.uid-alice'))!), made.seed, reason: junk);
      }
    });
  });
}
