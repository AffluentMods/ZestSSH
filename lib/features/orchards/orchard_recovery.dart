part of 'orchard_service.dart';

// Team recovery (3.0): with the owners' switch on, two owners
// together give a member who lost every device, and with them their account
// keys, their access back under the new keys the member started over with.
// One owner compares the member's new fingerprint and approves it; a second
// owner compares it too and completes: the record's member.recover entry,
// carrying the first owner's approval, and every key the member holds,
// sealed to the new keys, in one step. The Tree is never part of it.

/// orchard_info's status while this account waits in an Orchard for team
/// recovery: its keys are past the ones the record holds for it.
const String kRecoveryWaitStatus = 'recovery';

extension OrchardTeamRecovery on OrchardService {
  /// Turns team recovery on or off: owners only, and on needs two owners
  /// (the record's rules). Every member's app tells its person.
  Future<void> setTeamRecovery(String orchardId, bool on) =>
      change(orchardId, RecordTypes.recoverySet, {'on': on});

  /// Team recovery in [orchardId] as this device can stand behind it: on or
  /// off and the number of owners from the record, and whoever the server
  /// says waits, kept only when their new keys are signed for the account
  /// they name and are past the ones the record holds for them. Approvals
  /// count only from an owner, signed with the keys the record holds for
  /// them now, over exactly those keys (checked here when the server gives
  /// the signature, as it does for owners).
  Future<TeamRecoveryStatus> teamRecovery(String orchardId) async {
    final record = await _latestRecord(orchardId);
    final listed = await server.teamRecovery(orchardId);
    final waiting = <RecoveryWait>[];
    for (final w in listed.waiting) {
      final member = record.members[w.uid];
      if (member == null || member.status == MemberStatus.removed) continue;
      if (w.keys.uid != w.uid || w.keys.version <= member.currentKeys.version || !await w.keys.verify()) continue;
      final approvals = <RecoveryApproval>[];
      for (final a in w.approvals) {
        if (!record.isOwner(a.uid) || a.uid == w.uid) continue;
        final approverKeys = record.members[a.uid]!.currentKeys;
        if (a.keyVersion != approverKeys.version) continue;
        final signature = a.signature;
        if (signature != null &&
            !await verifyTeamRecovery(
              approverKeys.signingKey,
              signature,
              orchardId: orchardId,
              subjectUid: w.uid,
              subjectKeyVersion: w.keys.version,
              fingerprint: w.keys.fingerprint,
              approverUid: a.uid,
              approverKeyVersion: a.keyVersion,
            )) {
          continue;
        }
        approvals.add(a);
      }
      waiting.add(RecoveryWait(
        uid: w.uid,
        email: w.email,
        keys: w.keys,
        recordKeyVersion: member.currentKeys.version,
        approvals: approvals,
      ));
    }
    return TeamRecoveryStatus(on: record.teamRecovery, owners: record.owners.length, waiting: waiting);
  }

  /// This device's person, an owner, compared [wait]'s new fingerprint with
  /// the member and approves those keys: the signed approval goes to the
  /// server, for a second owner to carry into the record.
  Future<void> approveRecovery(String orchardId, RecoveryWait wait) async {
    final me = await _me();
    final record = await _latestRecord(orchardId);
    _checkRecoverable(record, me, wait);
    if (!await wait.keys.verify()) throw const OrchardRecordRefused('the keys are not signed for this account');
    await server.approveRecovery(
      orchardId,
      subjectUid: wait.uid,
      keyVersion: wait.keys.version,
      approverKeyVersion: me.keys.version,
      approval: await signTeamRecovery(me.keys, approverUid: me.uid, orchardId: orchardId, subject: wait.keys),
    );
  }

  /// Takes back this account's approval of [uid]'s new keys.
  Future<void> withdrawRecoveryApproval(String orchardId, String uid) =>
      server.withdrawRecoveryApproval(orchardId, uid);

  /// This device's person, a second owner, compared [wait]'s new fingerprint
  /// with the member too and completes the recovery: the record's
  /// member.recover entry, carrying another owner's approval of the same
  /// keys, and every generation of each key the member holds, sealed to the
  /// new keys and signed with this account's, in one step. Their keys are
  /// then pinned here as compared, and the check is signed for the rest of
  /// the Orchard. Throws [OrchardRecordRefused] before anything is sent when
  /// no other owner's approval counts, or the rules refuse the entry.
  Future<void> completeRecovery(String orchardId, RecoveryWait wait) async {
    final me = await _me();
    final approval = wait.approvals.where((a) => a.uid != me.uid && a.signature != null).firstOrNull;
    if (approval == null) throw const OrchardRecordRefused('two different owners');
    final db = await databases.open(orchardId);
    await _serial(orchardId, () async {
      for (var attempt = 0;; attempt++) {
        final record = await pullRecord(db, orchardId, server);
        _checkRecoverable(record.latest, me, wait);
        final entry = await OrchardService._sign(me, record, RecordTypes.memberRecover, {
          'uid': wait.uid,
          'keys': recordKeysBody(wait.keys),
          'approver': approval.uid,
          'approver_key_version': approval.keyVersion,
          'approval': base64Encode(approval.signature!),
        });
        final after = await OrchardService._probe(record, entry);
        final recovered = after.members[wait.uid]!.currentKeys;
        final copies = await _sealEvery(
          db,
          orchardId,
          me,
          after,
          wait.uid,
          (version: recovered.version, encryptionKey: recovered.encryptionKey),
          after.entitlementsAt(OrchardService._nowSeconds())[wait.uid] ?? const <String>{},
        );
        try {
          await server.completeRecovery(orchardId, entry, copies: copies);
        } on OrchardServerException catch (e) {
          // Another entry, or a new key generation, came first: once more on
          // top of it.
          if ((e.recordMoved || e.code == 'copies-changed') && attempt < 2) continue;
          rethrow;
        }
        await record.extend(db, [entry]);
        break;
      }
      await _refreshOrchard(orchardId, me);
      // Compared here: the keys the record now holds for them are verified
      // by this device's person.
      await MemberDirectory(db).markVerified(wait.uid);
    });
    try {
      await server.verifyMember(
        orchardId,
        subjectUid: wait.uid,
        subjectKeyVersion: wait.keys.version,
        keyVersion: me.keys.version,
        signature: await signMemberVerification(me.keys, verifierUid: me.uid, orchardId: orchardId, subject: wait.keys),
      );
    } catch (e) {
      // Recovered; only the "verified by" note for the others is missing.
      AppLogger.warning('Orchards: the check of a recovered member was not saved ($e)');
    }
  }

  /// The Orchard's record brought up to date, in its turn with the other
  /// work on it (a sync pulling at the same time would store the same
  /// entries twice).
  Future<OrchardRecord> _latestRecord(String orchardId) async {
    final db = await databases.open(orchardId);
    return _serial(orchardId, () => _namingDevice(() async => (await pullRecord(db, orchardId, server)).latest));
  }

  /// Refuses, before anything is signed, what the record's rules would: team
  /// recovery off, this account no owner, a member recovering themselves, a
  /// member who left, keys that are not past the record's.
  static void _checkRecoverable(OrchardRecord record, CrateAuthor me, RecoveryWait wait) {
    if (!record.teamRecovery) throw const OrchardRecordRefused('team recovery is off');
    if (!record.isOwner(me.uid)) throw const OrchardRecordRefused('only owners recover a member');
    if (wait.uid == me.uid) throw const OrchardRecordRefused('nobody recovers themselves');
    final member = record.members[wait.uid];
    if (member == null || member.status == MemberStatus.removed) throw const OrchardRecordRefused('not a member');
    if (wait.keys.uid != wait.uid || wait.keys.version <= member.currentKeys.version) {
      throw const OrchardRecordRefused('keys must be a later version');
    }
  }
}
