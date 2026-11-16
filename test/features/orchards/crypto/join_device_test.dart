import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/crypto/join_device.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

// The device someone joins on (from a security UX review): the statement
// the joining account signs over the team, itself and the device's key, and
// its check by whoever lets them in. It holds only for that account's key,
// that team, that account and that device: a server that passes it along
// cannot make it approve anything else.

String hex(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

void main() {
  test('the bytes signed: the label, the team, the account, the device key and the invitation, each length-prefixed',
      () {
    final message =
        joinDeviceMessage(orchardId: 'o-1', uid: 'uid-joiner', deviceKey: List.filled(32, 0x55), inviteId: 'inv-1');
    expect(
        hex(message),
        '00000016${hex('zestssh.join-device.v2'.codeUnits)}'
        '00000003${hex('o-1'.codeUnits)}'
        '0000000a${hex('uid-joiner'.codeUnits)}'
        '00000020${'55' * 32}'
        '00000005${hex('inv-1'.codeUnits)}');
    // Fields never run together: moving a byte from one to the next is
    // another message.
    expect(
        hex(joinDeviceMessage(orchardId: 'o-1u', uid: 'id-joiner', deviceKey: List.filled(32, 0x55), inviteId: 'inv-1')),
        isNot(hex(message)));
  });

  test("it verifies with the joining account's key, and with nothing else", () async {
    final joiner = await AccountKeys.generate();
    final stranger = await AccountKeys.generate();
    final device = Uint8List.fromList(List.generate(32, (i) => i + 1));
    final other = Uint8List.fromList(List.generate(32, (i) => 200 - i));
    final signature =
        await joiner.sign(joinDeviceMessage(orchardId: 'team-a', uid: 'uid-joiner', deviceKey: device, inviteId: 'inv-1'));

    Future<bool> holds({
      List<int>? signingKey,
      String orchardId = 'team-a',
      String uid = 'uid-joiner',
      List<int>? deviceKey,
      String inviteId = 'inv-1',
      List<int>? sig,
    }) =>
        verifyJoinDevice(
          signingKey: signingKey ?? joiner.signingPublicKey,
          orchardId: orchardId,
          uid: uid,
          deviceKey: deviceKey ?? device,
          inviteId: inviteId,
          signature: sig ?? signature,
        );

    expect(await holds(), isTrue);
    expect(await holds(signingKey: stranger.signingPublicKey), isFalse, reason: 'another account key');
    expect(await holds(orchardId: 'team-b'), isFalse, reason: 'another team');
    expect(await holds(uid: 'uid-someone-else'), isFalse, reason: 'another account');
    expect(await holds(deviceKey: other), isFalse, reason: 'another device');
    expect(await holds(inviteId: 'inv-2'), isFalse, reason: 'another invitation');
    // Signed by another account for the same device: not the joiner's word.
    final theirs =
        await stranger.sign(joinDeviceMessage(orchardId: 'team-a', uid: 'uid-joiner', deviceKey: device, inviteId: 'inv-1'));
    expect(await holds(sig: theirs), isFalse);
    // A flipped bit anywhere in the signature.
    expect(await holds(sig: Uint8List.fromList([...signature]..[10] ^= 1)), isFalse);
  });

  test('anything malformed does not verify, and does not throw', () async {
    final joiner = await AccountKeys.generate();
    final device = Uint8List(32);
    final signature = await joiner.sign(joinDeviceMessage(orchardId: 't', uid: 'u', deviceKey: device, inviteId: 'i'));
    for (final (key, dev, sig) in [
      (joiner.signingPublicKey.sublist(1), device, signature),
      (joiner.signingPublicKey, device.sublist(1), signature),
      (joiner.signingPublicKey, Uint8List(33), signature),
      (joiner.signingPublicKey, device, signature.sublist(1)),
      (Uint8List(0), device, signature),
      (joiner.signingPublicKey, device, Uint8List(64)),
    ]) {
      expect(await verifyJoinDevice(signingKey: key, orchardId: 't', uid: 'u', deviceKey: dev, inviteId: 'i', signature: sig),
          isFalse);
    }
  });
}
