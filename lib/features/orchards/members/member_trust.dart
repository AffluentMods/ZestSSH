/// How far this device trusts each member of an Orchard
/// (3.0). A member's keys only protect the team if they are
/// really that person's. So:
///
/// - A member's keys come from the Orchard's record: the member.add
///   entry that brought them in, signed by whoever confirmed them after
///   comparing their fingerprint, and each member.keys entry since, signed by
///   the new keys and vouched for by the ones before. The server holds no
///   member's signing key, so it cannot put keys there.
/// - A member's keys are pinned the first time this device sees them.
/// - People compare a member's fingerprint outside ZestSSH (on a call, in
///   person) and say so with a signed statement; "verified by N" counts the
///   statements this device can check itself.
/// - A change of keys is followed only along the record's chain of vouched
///   versions from the pinned one. Anything else (a member removed and added
///   again with other keys) is a hard stop: this device keeps the pinned
///   key, trusts nothing the new one signs and seals nothing to it, until
///   someone compares the new fingerprint and accepts it.
///
/// The limit, stated plainly: a record shown differently to different
/// people is caught when any two of them compare fingerprints, or when an
/// item names an entry the other's record does not have (the record's
/// anchors), not before. Pure Dart; the server checks the same statement
/// bytes (ZestSSH Cloud's src/lib/member_verifications.js).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

const String kMemberVerificationLabel = 'zestssh.member-verification.v1';

final Ed25519 _ed25519 = Ed25519();

/// The exact bytes a member verification's signature covers.
Uint8List memberVerificationMessage({
  required String orchardId,
  required String subjectUid,
  required int subjectKeyVersion,
  required List<int> fingerprint,
  required String verifierUid,
  required int verifierKeyVersion,
}) {
  return Uint8List.fromList([
    ..._lp(utf8.encode(kMemberVerificationLabel)),
    ..._lp(utf8.encode(orchardId)),
    ..._lp(utf8.encode(subjectUid)),
    ..._u32(subjectKeyVersion),
    ..._lp(fingerprint),
    ..._lp(utf8.encode(verifierUid)),
    ..._u32(verifierKeyVersion),
  ]);
}

/// [verifier]'s statement that [subject]'s keys are theirs, in [orchardId].
Future<Uint8List> signMemberVerification(
  AccountKeys verifier, {
  required String verifierUid,
  required String orchardId,
  required PublishedAccountKeys subject,
}) =>
    verifier.sign(memberVerificationMessage(
      orchardId: orchardId,
      subjectUid: subject.uid,
      subjectKeyVersion: subject.version,
      fingerprint: subject.fingerprint,
      verifierUid: verifierUid,
      verifierKeyVersion: verifier.version,
    ));

/// Whether [signature] is a statement by the key [verifierSigningKey].
Future<bool> verifyMemberVerification(
  List<int> verifierSigningKey,
  Uint8List signature, {
  required String orchardId,
  required String subjectUid,
  required int subjectKeyVersion,
  required List<int> fingerprint,
  required String verifierUid,
  required int verifierKeyVersion,
}) async {
  if (signature.length != 64 || verifierSigningKey.length != 32) return false;
  try {
    return await _ed25519.verify(
      memberVerificationMessage(
        orchardId: orchardId,
        subjectUid: subjectUid,
        subjectKeyVersion: subjectKeyVersion,
        fingerprint: fingerprint,
        verifierUid: verifierUid,
        verifierKeyVersion: verifierKeyVersion,
      ),
      signature: Signature(signature,
          publicKey: SimplePublicKey(verifierSigningKey, type: KeyPairType.ed25519)),
    );
  } catch (_) {
    return false;
  }
}

/// A signed "I checked this member's keys" as the server lists it.
class MemberCheck {
  const MemberCheck({
    required this.by,
    required this.byKeyVersion,
    required this.keyVersion,
    required this.signature,
  });

  /// Who checked, and the version of their keys that signed.
  final String by;
  final int byKeyVersion;

  /// The version of the member's keys that was checked.
  final int keyVersion;
  final Uint8List signature;
}

/// One member as the server lists them.
class MemberListing {
  const MemberListing({
    required this.uid,
    required this.role,
    this.status = 'active',
    this.endsAt,
    this.email,
    this.name,
    this.picture,
    this.keys,
    this.history = const [],
    this.checks = const [],
  });

  final String uid;
  final String role;

  /// The name and picture (an https address) their own account shows, as
  /// the server lists them for their team; null for none.
  final String? name;
  final String? picture;

  /// 'active' or 'suspended'.
  final String status;

  /// When their access ends, in seconds since the epoch; null for never.
  final int? endsAt;
  final String? email;

  /// Their published keys now, null before they have any.
  final PublishedAccountKeys? keys;

  /// The keys they replaced, oldest first.
  final List<PublishedAccountKeys> history;
  final List<MemberCheck> checks;
}

/// The keys this device holds for a member.
class PinnedMember {
  const PinnedMember({
    required this.uid,
    required this.keyVersion,
    required this.signingKey,
    required this.encryptionKey,
    this.verifiedByMe = false,
    this.replacedSinceCompared = false,
    this.pending,
  });

  final String uid;

  /// The keys this device trusts for the member.
  final int keyVersion;
  final Uint8List signingKey;
  final Uint8List encryptionKey;

  /// This device's person compared the fingerprint of these keys.
  final bool verifiedByMe;

  /// This device's person compared an earlier version of these keys; the
  /// member replaced them since, each version vouched for by the one before
  /// (3.0).
  final bool replacedSinceCompared;

  /// Keys the record shows that this device does not follow (a hard stop),
  /// waiting for someone to compare and accept them.
  final PublishedAccountKeys? pending;

  bool get hardStop => pending != null;

  /// These keys as a published bundle, for checking an endorsement: only the
  /// account, the version and the signing key count there.
  PublishedAccountKeys get asPublished => PublishedAccountKeys(
        uid: uid,
        version: keyVersion,
        createdAt: 0,
        encryptionKey: encryptionKey,
        signingKey: signingKey,
        signature: Uint8List(64),
      );

  Uint8List get fingerprint =>
      accountKeysFingerprint(signingKey: signingKey, encryptionKey: encryptionKey);

  PinnedMember copyWith({
    int? keyVersion,
    Uint8List? signingKey,
    Uint8List? encryptionKey,
    bool? verifiedByMe,
    bool? replacedSinceCompared,
    PublishedAccountKeys? pending,
    bool clearPending = false,
  }) =>
      PinnedMember(
        uid: uid,
        keyVersion: keyVersion ?? this.keyVersion,
        signingKey: signingKey ?? this.signingKey,
        encryptionKey: encryptionKey ?? this.encryptionKey,
        verifiedByMe: verifiedByMe ?? this.verifiedByMe,
        replacedSinceCompared: replacedSinceCompared ?? this.replacedSinceCompared,
        pending: clearPending ? null : (pending ?? this.pending),
      );

  static PinnedMember fromKeys(PublishedAccountKeys keys, {bool verifiedByMe = false}) => PinnedMember(
        uid: keys.uid,
        keyVersion: keys.version,
        signingKey: keys.signingKey,
        encryptionKey: keys.encryptionKey,
        verifiedByMe: verifiedByMe,
      );
}

/// What the record did to a member's pin.
enum MemberKeyChange {
  /// Nothing new, or the member has no keys yet.
  none,

  /// Seen for the first time and pinned.
  pinned,

  /// They replaced their keys and each new version was endorsed by the one
  /// before: followed.
  followed,

  /// The record shows keys this device does not follow: a hard stop.
  hardStop,
}

/// Applies what the Orchard's record says of [member]'s keys to the pin this
/// device holds. The record keeps every version it took through member.keys
/// (each vouched for by the one before, which the record's rules check); a
/// member added again after leaving starts over with only the keys they
/// were added with. So the pinned keys are followed to the member's current
/// ones only when the record still holds the pinned version as pinned.
/// Returns the pin to keep and what changed.
(PinnedMember?, MemberKeyChange) applyRecordKeys(PinnedMember? pin, RecordMember member) {
  final current = member.currentKeys.published(member.uid);
  if (pin == null) return (PinnedMember.fromKeys(current), MemberKeyChange.pinned);
  if (current.version == pin.keyVersion && _same(current, pin)) {
    return (pin.copyWith(clearPending: true), MemberKeyChange.none);
  }
  final atPin = member.keys[pin.keyVersion];
  if (current.version > pin.keyVersion && atPin != null && _same(atPin.published(member.uid), pin)) {
    // Followed without stopping anyone, but what was compared were the old
    // keys: "verified by you" no longer holds, and says so in amber until
    // someone compares the new ones (3.0).
    return (
      pin.copyWith(
        keyVersion: current.version,
        signingKey: current.signingKey,
        encryptionKey: current.encryptionKey,
        verifiedByMe: false,
        replacedSinceCompared: pin.verifiedByMe || pin.replacedSinceCompared,
        clearPending: true,
      ),
      MemberKeyChange.followed,
    );
  }
  if (pin.pending != null && _sameBundle(pin.pending!, current)) {
    return (pin, MemberKeyChange.none); // the same hard stop, still waiting
  }
  return (pin.copyWith(pending: current), MemberKeyChange.hardStop);
}

/// Accepting keys that caused a hard stop, after comparing their fingerprint
/// with the member: they become the pin, verified by this device's person.
PinnedMember acceptPending(PinnedMember pin) {
  final next = pin.pending;
  if (next == null) return pin;
  return PinnedMember.fromKeys(next, verifiedByMe: true);
}

/// Who, among the members this device trusts, has a statement that checks
/// out for [subject]'s pinned keys. [pins] are this device's pins by uid,
/// [me] the signed-in account's own current keys.
Future<List<String>> verifiedBy({
  required String orchardId,
  required PinnedMember subject,
  required List<MemberCheck> checks,
  required Map<String, PinnedMember> pins,
  required String myUid,
  required AccountKeys myKeys,
}) async {
  final out = <String>[];
  for (final c in checks) {
    if (c.keyVersion != subject.keyVersion || c.by == subject.uid) continue;
    final List<int> signingKey;
    if (c.by == myUid) {
      if (c.byKeyVersion != myKeys.version) continue;
      signingKey = myKeys.signingPublicKey;
    } else {
      final verifier = pins[c.by];
      if (verifier == null || verifier.hardStop || verifier.keyVersion != c.byKeyVersion) continue;
      signingKey = verifier.signingKey;
    }
    final ok = await verifyMemberVerification(
      signingKey,
      c.signature,
      orchardId: orchardId,
      subjectUid: subject.uid,
      subjectKeyVersion: subject.keyVersion,
      fingerprint: subject.fingerprint,
      verifierUid: c.by,
      verifierKeyVersion: c.byKeyVersion,
    );
    if (ok && !out.contains(c.by)) out.add(c.by);
  }
  return out;
}

/// A fingerprint as 12 groups of 5 digits, easy to read out on a call: the
/// fingerprint as one number, its last 60 digits (about 199 bits).
String formatFingerprint(List<int> fingerprint) {
  var n = BigInt.zero;
  for (final b in fingerprint) {
    n = (n << 8) | BigInt.from(b);
  }
  final digits = (n % BigInt.from(10).pow(60)).toString().padLeft(60, '0');
  return [for (var i = 0; i < 60; i += 5) digits.substring(i, i + 5)].join(' ');
}

bool _same(PublishedAccountKeys keys, PinnedMember pin) =>
    _equal(keys.signingKey, pin.signingKey) && _equal(keys.encryptionKey, pin.encryptionKey);

bool _sameBundle(PublishedAccountKeys a, PublishedAccountKeys b) =>
    a.version == b.version &&
    _equal(a.signingKey, b.signingKey) &&
    _equal(a.encryptionKey, b.encryptionKey);

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

List<int> _lp(List<int> bytes) {
  final out = Uint8List(4 + bytes.length);
  ByteData.sublistView(out, 0, 4).setUint32(0, bytes.length);
  out.setRange(4, out.length, bytes);
  return out;
}

List<int> _u32(int value) {
  final out = Uint8List(4);
  ByteData.sublistView(out).setUint32(0, value);
  return out;
}

/// An Orchard's members as the server lists them, and the accounts the
/// record still names that were deleted since.
class MemberList {
  const MemberList(this.members, {this.deleted = const {}});

  final List<MemberListing> members;
  final Set<String> deleted;
}
