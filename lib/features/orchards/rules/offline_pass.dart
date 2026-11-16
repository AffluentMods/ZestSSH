/// An offline pass (3.0, part of the outage work
/// with the offline limit per Crate, a warning before it
/// closes, and a pass an owner signs for a member's device, over the same
/// exchange as the certificate handover).
///
/// An offline limit closes a Crate, or all of an Orchard, on a device that
/// has not reached ZestSSH Cloud for too long. Some places have no internet
/// at all, and an SSH client that works offline is the point of this one:
/// for them an owner can let one device of one member go on for a while.
/// The member's device makes a request, signed with the member's keys. An
/// owner's device, which has the record, signs a pass for exactly that
/// device, that member, that Crate (or all of the Orchard) and the moment it
/// ends. The member's device keeps it only when an owner its own record
/// names signed it, for its own key. Nothing of it goes through ZestSSH
/// Cloud: the two travel as texts (certs/cert_handover.dart), from one
/// screen to the other's camera or through whatever still works.
///
/// What a pass does not do: it opens nothing the device does not already
/// hold, gives no access the record does not give, lasts no longer than
/// [kOfflinePassMax], and works on no other device than the one that asked.
///
/// The bytes that are signed and who signs what are here; what the two
/// texts look like is in cert_handover.dart, and what a device does with
/// them in orchard_pass_handover.dart.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';

const String kPassRequestLabel = 'zestssh.pass-request.v1';
const String kOfflinePassLabel = 'zestssh.offline-pass.v1';

/// In place of a Crate's id: all of the Orchard (its own offline limit, and
/// every Crate's with it). No Crate has this id.
const String kAllOfOrchard = '*';

/// The longest a pass lasts (seven days is accepted for what an
/// outage excuses, and a pass is held to the same).
const Duration kOfflinePassMax = Duration(days: 7);

/// The lengths an owner chooses from, in hours.
const List<int> kOfflinePassChoices = [8, 24, 72, 168];

/// How long a request is good for: an owner's device signs none that is
/// older, or dated further ahead of its clock than [kPassClockSlack].
const int kPassRequestLifetimeSeconds = 86400;

/// How far the clocks of two devices may differ when a request or a pass
/// goes from one to the other.
const Duration kPassClockSlack = Duration(minutes: 10);

final Ed25519 _ed25519 = Ed25519();

/// The exact bytes a request's signature covers: in [orchardId], for
/// [crateId] ([kAllOfOrchard] for all of it), by [uid] with their keys at
/// [keyVersion], for the device [deviceKey] (32 bytes), at [askedAt] (unix
/// seconds).
Uint8List passRequestMessage({
  required String orchardId,
  required String crateId,
  required String uid,
  required int keyVersion,
  required List<int> deviceKey,
  required int askedAt,
}) =>
    Uint8List.fromList([
      ..._lp(utf8.encode(kPassRequestLabel)),
      ..._lp(utf8.encode(orchardId)),
      ..._lp(utf8.encode(crateId)),
      ..._lp(utf8.encode(uid)),
      ..._u32(keyVersion),
      ..._lp(deviceKey),
      ..._u64(askedAt),
    ]);

/// A member's request for an offline pass, as their device makes it.
class PassRequest {
  const PassRequest({
    required this.uid,
    required this.keyVersion,
    required this.deviceKey,
    required this.askedAt,
    required this.signature,
  });

  /// The member asking.
  final String uid;

  /// The version of the member's keys the request is signed with.
  final int keyVersion;

  /// The device the pass is for: its own signing key (32 bytes), which
  /// never leaves it.
  final Uint8List deviceKey;

  /// Unix seconds.
  final int askedAt;
  final Uint8List signature;

  Uint8List message({required String orchardId, required String crateId}) => passRequestMessage(
        orchardId: orchardId,
        crateId: crateId,
        uid: uid,
        keyVersion: keyVersion,
        deviceKey: deviceKey,
        askedAt: askedAt,
      );
}

/// Why an owner's device will not sign a pass for a request
/// ([passRequestRefusal]).
enum PassRequestRefusal {
  /// The Orchard has no such Crate.
  noSuchCrate('no such Crate'),

  /// Whoever asks is not in the record, or not active in it.
  notAMember('not a member'),

  /// They cannot open the Crate now.
  noAccess('no access to the Crate'),

  /// The request is signed with keys the record no longer has as theirs.
  notCurrentKeys('not their current keys'),

  /// It was made more than a day ago, or is dated ahead of this clock.
  notRecent('not asked in the last day'),

  /// The signature is not theirs for this request.
  notSignedByMember('not signed by the member'),

  /// Approved devices only, and the request names none the record lists.
  deviceNotApproved('not from an approved device');

  const PassRequestRefusal(this.words);

  /// What the log says.
  final String words;
}

/// Why an owner's device will not sign a pass for [request] in [record]'s
/// [crateId] ([kAllOfOrchard] for all of the Orchard) at [nowSeconds], or
/// null when it will: the Crate there, the member in the record with access
/// to it now, their current keys signing exactly this request, asked within
/// the last day, and, where the Orchard lets in approved devices only,
/// for a device the record lists for them.
Future<PassRequestRefusal?> passRequestRefusal(
  OrchardRecord record,
  PassRequest request, {
  required String orchardId,
  required String crateId,
  required int nowSeconds,
}) async {
  if (crateId != kAllOfOrchard && !record.crates.containsKey(crateId)) return PassRequestRefusal.noSuchCrate;
  // (In the record, active, and before any day their time in it ends.)
  final theirs = record.entitlementsAt(nowSeconds)[request.uid];
  final member = record.members[request.uid];
  if (theirs == null || member == null) return PassRequestRefusal.notAMember;
  if (crateId != kAllOfOrchard && !theirs.contains(crateId)) return PassRequestRefusal.noAccess;
  final keys = member.keys[request.keyVersion];
  if (keys == null || request.keyVersion != member.currentKeys.version) return PassRequestRefusal.notCurrentKeys;
  if (request.askedAt > nowSeconds + kPassClockSlack.inSeconds ||
      request.askedAt < nowSeconds - kPassRequestLifetimeSeconds) {
    return PassRequestRefusal.notRecent;
  }
  if (!await _signedBy(keys.signingKey, request.message(orchardId: orchardId, crateId: crateId), request.signature) ||
      request.deviceKey.length != 32) {
    return PassRequestRefusal.notSignedByMember;
  }
  if (record.rules.trustedDevices && !record.devicesOf(request.uid).contains(deviceKeyText(request.deviceKey))) {
    return PassRequestRefusal.deviceNotApproved;
  }
  return null;
}

/// The exact bytes a pass's signature covers: in [orchardId], for [crateId]
/// ([kAllOfOrchard] for all of it), the device [deviceKey] (32 bytes) of
/// [uid], until [until], made at [madeAt] (both unix seconds), by the owner
/// [by] with their keys at [byKeyVersion].
Uint8List offlinePassMessage({
  required String orchardId,
  required String crateId,
  required String uid,
  required List<int> deviceKey,
  required int until,
  required int madeAt,
  required String by,
  required int byKeyVersion,
}) =>
    Uint8List.fromList([
      ..._lp(utf8.encode(kOfflinePassLabel)),
      ..._lp(utf8.encode(orchardId)),
      ..._lp(utf8.encode(crateId)),
      ..._lp(utf8.encode(uid)),
      ..._lp(deviceKey),
      ..._u64(until),
      ..._u64(madeAt),
      ..._lp(utf8.encode(by)),
      ..._u32(byKeyVersion),
    ]);

/// An offline pass, as an owner's device signs it.
class OfflinePass {
  const OfflinePass({
    required this.uid,
    required this.deviceKey,
    required this.until,
    required this.madeAt,
    required this.by,
    required this.byKeyVersion,
    required this.signature,
  });

  /// The member it is for, and their device (its own signing key, 32 bytes).
  final String uid;
  final Uint8List deviceKey;

  /// The last second it holds, and when it was made (unix seconds).
  final int until;
  final int madeAt;

  /// The owner who signed it, and the version of their keys it is signed
  /// with.
  final String by;
  final int byKeyVersion;
  final Uint8List signature;

  Uint8List message({required String orchardId, required String crateId}) => offlinePassMessage(
        orchardId: orchardId,
        crateId: crateId,
        uid: uid,
        deviceKey: deviceKey,
        until: until,
        madeAt: madeAt,
        by: by,
        byKeyVersion: byKeyVersion,
      );
}

/// Why a device does not keep a pass handed to it ([offlinePassProblem]).
enum OfflinePassProblem {
  /// The Orchard has no such Crate.
  noSuchCrate('no such Crate'),

  /// It is for another account.
  notForThisAccount('for another account'),

  /// It is for another device: a pass works only on the device that asked.
  notForThisDevice('for another device'),

  /// Whoever signed it is no owner of the Orchard, as this device's own
  /// record has it.
  notAnOwner('not signed by an owner'),

  /// It is signed with keys the record no longer has as that owner's.
  notCurrentKeys("not the owner's current keys"),

  /// The signature is not that owner's for this pass.
  notSignedByOwner('the signature does not check out'),

  /// It has run out.
  expired('run out'),

  /// It lasts longer than a pass may, or ends further from this device's
  /// clock than one could.
  tooLong('lasts longer than a pass may');

  const OfflinePassProblem(this.words);

  /// What the log says.
  final String words;
}

/// Why this device does not keep [pass] for [crateId] ([kAllOfOrchard] for
/// all of the Orchard) of [orchardId] at [nowSeconds], or null when it
/// does: for this account ([uid]) and this device's own key ([deviceKey]),
/// signed by an owner [record] names, with their current keys, not run out,
/// and no longer than a pass may last, by its own word and by this device's
/// clock. [record] is this device's own copy: a pass is checked against
/// nothing it brings along itself.
Future<OfflinePassProblem?> offlinePassProblem(
  OrchardRecord record,
  OfflinePass pass, {
  required String orchardId,
  required String crateId,
  required String uid,
  required List<int> deviceKey,
  required int nowSeconds,
}) async {
  if (crateId != kAllOfOrchard && !record.crates.containsKey(crateId)) return OfflinePassProblem.noSuchCrate;
  if (pass.uid != uid) return OfflinePassProblem.notForThisAccount;
  if (!_same(pass.deviceKey, deviceKey)) return OfflinePassProblem.notForThisDevice;
  if (!record.isOwner(pass.by)) return OfflinePassProblem.notAnOwner;
  final owner = record.members[pass.by]!;
  final keys = owner.keys[pass.byKeyVersion];
  if (keys == null || pass.byKeyVersion != owner.currentKeys.version) return OfflinePassProblem.notCurrentKeys;
  if (!await _signedBy(keys.signingKey, pass.message(orchardId: orchardId, crateId: crateId), pass.signature)) {
    return OfflinePassProblem.notSignedByOwner;
  }
  if (pass.until <= nowSeconds) return OfflinePassProblem.expired;
  final most = kOfflinePassMax.inSeconds;
  if (pass.until - pass.madeAt > most || pass.until > nowSeconds + most + kPassClockSlack.inSeconds) {
    return OfflinePassProblem.tooLong;
  }
  return null;
}

/// An offline pass a device holds, as it kept it when it took it in (it
/// was checked then against the device's own record,
/// orchard_pass_handover.dart): the last second it holds, when it was made,
/// and the owner who signed it.
class HeldPass {
  const HeldPass({required this.until, required this.madeAt, required this.by});

  final int until;
  final int madeAt;
  final String by;

  /// Whether it holds on a device whose clock reads [nowSeconds] and has
  /// read [latest] at the furthest: a clock turned back does not bring a
  /// pass back.
  bool holdsAt(int nowSeconds, int latest) => math.max(nowSeconds, latest) <= until;

  /// How long before it ends a device says so: its last quarter, and a day
  /// at the most (as for a limit, offlineWarningBefore).
  Duration get warningBefore {
    final quarter = Duration(seconds: math.max(until - madeAt, 0) ~/ 4);
    return quarter > const Duration(days: 1) ? const Duration(days: 1) : quarter;
  }

  /// Whether it holds and is about to end, on a device whose clock reads
  /// [nowSeconds] and has read [latest] at the furthest.
  bool endsSoonAt(int nowSeconds, int latest) =>
      holdsAt(nowSeconds, latest) && until - math.max(nowSeconds, latest) <= warningBefore.inSeconds;

  /// What is kept of it.
  String toStored() => jsonEncode({'until': until, 'made': madeAt, 'by': by});

  /// The pass kept as [raw], or null where that is none.
  static HeldPass? fromStored(String? raw) {
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final until = map['until'], made = map['made'], by = map['by'];
      if (until is! int || made is! int || by is! String) return null;
      return HeldPass(until: until, madeAt: made, by: by);
    } on FormatException {
      return null;
    }
  }
}

Future<bool> _signedBy(List<int> signingKey, List<int> message, List<int> signature) async {
  if (signature.length != 64 || signingKey.length != 32) return false;
  try {
    return await _ed25519.verify(
      message,
      signature: Signature(signature, publicKey: SimplePublicKey(signingKey, type: KeyPairType.ed25519)),
    );
  } catch (_) {
    return false;
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

List<int> _lp(List<int> bytes) => [..._u32(bytes.length), ...bytes];

List<int> _u32(int value) => [(value >> 24) & 0xff, (value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff];

List<int> _u64(int value) => [..._u32(value ~/ 0x100000000), ..._u32(value % 0x100000000)];
