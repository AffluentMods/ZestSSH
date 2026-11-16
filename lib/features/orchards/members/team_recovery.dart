/// Team recovery (3.0): when an Orchard's owners turned it on, two
/// owners together can give a member who lost every device, and with them
/// their account keys, their access back under new keys, instead of the
/// member being removed and invited again.
///
/// The first owner signs a statement over the member's new keys after
/// comparing their fingerprint with the member; the second owner, after
/// comparing too, writes the record's member.recover entry carrying that
/// statement, and every member's app checks both signatures. The statement
/// is its own kind, never a member verification: an ordinary "I compared
/// these keys" can never be used as an approval nobody meant to give.
/// These bytes must match the server's (ZestSSH Cloud's
/// src/lib/team_recovery.js); a shared test vector holds them together.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

const String kTeamRecoveryLabel = 'zestssh.team-recovery.v1';

final Ed25519 _ed25519 = Ed25519();

/// The exact bytes a team recovery approval's signature covers: in
/// [orchardId], [subjectUid]'s new keys at [subjectKeyVersion] with
/// [fingerprint], approved by [approverUid] with their keys at
/// [approverKeyVersion].
Uint8List teamRecoveryMessage({
  required String orchardId,
  required String subjectUid,
  required int subjectKeyVersion,
  required List<int> fingerprint,
  required String approverUid,
  required int approverKeyVersion,
}) {
  return Uint8List.fromList([
    ..._lp(utf8.encode(kTeamRecoveryLabel)),
    ..._lp(utf8.encode(orchardId)),
    ..._lp(utf8.encode(subjectUid)),
    ..._u32(subjectKeyVersion),
    ..._lp(fingerprint),
    ..._lp(utf8.encode(approverUid)),
    ..._u32(approverKeyVersion),
  ]);
}

/// [approver]'s approval of [subject]'s new keys, in [orchardId].
Future<Uint8List> signTeamRecovery(
  AccountKeys approver, {
  required String approverUid,
  required String orchardId,
  required PublishedAccountKeys subject,
}) =>
    approver.sign(teamRecoveryMessage(
      orchardId: orchardId,
      subjectUid: subject.uid,
      subjectKeyVersion: subject.version,
      fingerprint: subject.fingerprint,
      approverUid: approverUid,
      approverKeyVersion: approver.version,
    ));

/// Whether [signature] is an approval by the key [approverSigningKey].
Future<bool> verifyTeamRecovery(
  List<int> approverSigningKey,
  Uint8List signature, {
  required String orchardId,
  required String subjectUid,
  required int subjectKeyVersion,
  required List<int> fingerprint,
  required String approverUid,
  required int approverKeyVersion,
}) async {
  if (signature.length != 64 || approverSigningKey.length != 32) return false;
  try {
    return await _ed25519.verify(
      teamRecoveryMessage(
        orchardId: orchardId,
        subjectUid: subjectUid,
        subjectKeyVersion: subjectKeyVersion,
        fingerprint: fingerprint,
        approverUid: approverUid,
        approverKeyVersion: approverKeyVersion,
      ),
      signature: Signature(signature, publicKey: SimplePublicKey(approverSigningKey, type: KeyPairType.ed25519)),
    );
  } catch (_) {
    return false;
  }
}

/// Length-prefixed (uint32 big-endian), so fields never run together.
List<int> _lp(List<int> bytes) => [..._u32(bytes.length), ...bytes];

List<int> _u32(int value) =>
    [(value >> 24) & 0xff, (value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff];

/// One owner's approval of a waiting member's new keys, as the server keeps
/// it until the recovery goes into the record.
class RecoveryApproval {
  const RecoveryApproval({required this.uid, required this.keyVersion, this.signature});

  /// The owner who approved.
  final String uid;

  /// The version of that owner's keys the approval is signed with.
  final int keyVersion;

  /// The signed approval: owners get it (the owner who completes carries it
  /// into the record); the member only learns it was given.
  final Uint8List? signature;
}

/// A member who started over with new keys after losing the old ones with
/// every device, waiting in an Orchard for two owners to recover them.
class RecoveryWait {
  const RecoveryWait({
    required this.uid,
    required this.keys,
    required this.recordKeyVersion,
    this.email,
    this.approvals = const [],
  });

  final String uid;

  /// Their address (owners only).
  final String? email;

  /// The keys they published after the loss: what the owners compare with
  /// them before approving.
  final PublishedAccountKeys keys;

  /// The version of their keys the record still holds: the lost ones.
  final int recordKeyVersion;
  final List<RecoveryApproval> approvals;
}

/// Team recovery in one Orchard.
class TeamRecoveryStatus {
  const TeamRecoveryStatus({required this.on, required this.owners, this.waiting = const []});

  /// Whether the owners turned it on.
  final bool on;

  /// How many owners the Orchard has: team recovery needs two.
  final int owners;

  /// Who waits: everyone, for an owner; only this account, otherwise.
  final List<RecoveryWait> waiting;
}
