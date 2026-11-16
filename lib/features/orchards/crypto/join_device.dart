/// The device someone joins a team on, offered for approval as they are let
/// in (found in a security UX review).
///
/// In a team that lets in approved devices only, the person joining
/// compared fingerprint words to get in and then three more words to have
/// their device approved, most often with the same person on the same call.
/// Now the device that accepts an invitation (to an address, or an invite
/// code) sends its own key with a statement signed by the joining account's
/// signing key (Ed25519, AccountKeys.sign in account_keys.dart) over:
///
///   lp("zestssh.join-device.v2") | lp(team id) | lp(account uid) | lp(device key) | lp(invitation id)
///
/// each field length-prefixed (uint32 big-endian), the device key its 32
/// bytes, the invitation the one it was accepted with (the code's own for a
/// code, a team code's uses included). Whoever lets them in checks it with the keys the fingerprint
/// comparison (or the code's check) covers, the very keys the member.add
/// names: so the device is the account's own word, and ZestSSH Cloud, which
/// passes it along, cannot put another device in its place without that
/// account's key. Only then is the device offered, ticked, beside "Let them
/// in", with its code and platform, so a borrowed computer can be unticked.
///
/// It names the team, the account and the invitation, so a statement made
/// for one team, for another account or with another invitation approves
/// nothing elsewhere (found in a security review: an
/// old statement, of a device since lost and taken back, was replayed by
/// ZestSSH Cloud when its account was invited again). The server hands out
/// an invitation's id, though, and keeps nothing that would let a time be
/// signed with it (the key and the signature, 32 and 64 bytes): so whoever
/// lets someone in also refuses a device the team's record ever approved or
/// took back for that account (OrchardService.joinDeviceOffer).
///
/// Pure Dart on the `cryptography` package, no Flutter or app imports.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// The label the statement starts with.
const String kJoinDeviceLabel = 'zestssh.join-device.v2';

/// The bytes the joining account [uid] signs to offer the device whose key is
/// [deviceKey] (32 bytes) in the team [orchardId], with the invitation
/// [inviteId].
Uint8List joinDeviceMessage(
        {required String orchardId, required String uid, required List<int> deviceKey, required String inviteId}) =>
    Uint8List.fromList([
      ..._lp(utf8.encode(kJoinDeviceLabel)),
      ..._lp(utf8.encode(orchardId)),
      ..._lp(utf8.encode(uid)),
      ..._lp(deviceKey),
      ..._lp(utf8.encode(inviteId)),
    ]);

/// Whether [signature] (64 bytes) is the account signing key [signingKey]'s
/// (32 bytes) over [joinDeviceMessage]: the account [uid] offered the device
/// [deviceKey] (32 bytes) in [orchardId] with the invitation [inviteId]. False
/// for anything malformed.
Future<bool> verifyJoinDevice({
  required List<int> signingKey,
  required String orchardId,
  required String uid,
  required List<int> deviceKey,
  required String inviteId,
  required List<int> signature,
}) async {
  if (signingKey.length != 32 || deviceKey.length != 32 || signature.length != 64) return false;
  try {
    return await Ed25519().verify(
      joinDeviceMessage(orchardId: orchardId, uid: uid, deviceKey: deviceKey, inviteId: inviteId),
      signature: Signature(signature, publicKey: SimplePublicKey(signingKey, type: KeyPairType.ed25519)),
    );
  } catch (_) {
    return false;
  }
}

List<int> _lp(List<int> bytes) {
  final out = Uint8List(4 + bytes.length);
  ByteData.sublistView(out, 0, 4).setUint32(0, bytes.length);
  out.setRange(4, out.length, bytes);
  return out;
}
