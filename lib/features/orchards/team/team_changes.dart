import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/utils/logger.dart';

/// What an entry of an Orchard's record changed, as the Team page words it.
enum TeamChangeKind {
  created,
  crateAdded,
  crateSettings,
  roleAdded,
  roleChanged,
  roleDeleted,
  memberAdded,
  memberAddedAgain,
  memberRole,
  memberSteppedDown,
  memberAccess,
  memberKeys,
  memberSuspended,
  memberResumed,
  memberRemoved,
  memberLeft,
  crateKey,
  orchardKey,
  rules,

  /// Team recovery turned on or off.
  teamRecoveryOn,
  teamRecoveryOff,

  /// A member given their access back under new keys by two owners:
  /// the author, and [TeamChange.approver].
  memberRecovered,

  /// A Crate's certificate authority set up, changed or turned off.
  certificateAuthority,

  /// What the team records changed.
  tracking,

  /// A Crate's session logs turned on or off.
  sessionLogsOn,
  sessionLogsOff,

  /// A Crate's sessions watched from now on, or no longer.
  watchedOn,
  watchedOff,

  /// A Crate given an offline limit of its own ([TeamChange.hours]), or
  /// its limit taken off (3.0, the outage work).
  crateOfflineSet,
  crateOfflineOff,

  /// Who connects to a watched Crate's hosts with nobody watching while
  /// ZestSSH Cloud cannot be reached: everyone who may connect there, or
  /// owners only again (3.0, the outage work).
  unwatchedAwayOn,
  unwatchedAwayOff,

  /// A member's report of a session that ran so ([TeamChange.at] is when).
  sessionUnwatched,

  /// A Crate given to a member until a set time, ended early by
  /// someone who manages it, or given up by the member.
  accessGiven,
  accessEnded,
  accessGivenUp,

  /// A member's device approved or its approval taken back, by the
  /// member themselves or by someone above them.
  deviceApproved,
  deviceApprovedOwn,
  deviceRemoved,
  deviceRemovedOwn,

  /// The team's events sent on to a system of its own, turned on or off
  /// (event export).
  exportOn,
  exportOff,

  /// One member's access to a vault set apart from their role:
  /// a level ([TeamChange.switches]), taken away, or put back to their
  /// role.
  memberVaultSet,
  memberVaultTaken,
  memberVaultBack,

  /// The Admin role changed by an owner, or put back to all of it.
  adminChanged,
  adminReset,

  /// An owner asked to delete the team, or undid that.
  teamDeleted,
  teamRestored,
  other,
}

/// One entry of an Orchard's record, worked out against the record as it
/// stood just before it (3.0): the Overview's recent changes and
/// the Trust page's key log.
class TeamChange {
  const TeamChange({
    required this.seq,
    required this.kind,
    required this.by,
    required this.byKeyVersion,
    this.member,
    this.crateId,
    this.roleId,
    this.approver,
    this.until,
    this.hours,
    this.at,
    this.switches,
  });

  final int seq;
  final TeamChangeKind kind;

  /// Who made the change, and the version of their keys that signed it.
  final String by;
  final int byKeyVersion;

  /// The member it is about (for member.keys, the author).
  final String? member;
  final String? crateId;

  /// The role it is about, or the role a member was given.
  final String? roleId;

  /// For a recovery, the second owner whose approval it carries.
  final String? approver;

  /// For access given until a set time: when it ends, in seconds since the
  /// epoch.
  final int? until;

  /// For a Crate's own offline limit: how many hours it was set to.
  final int? hours;

  /// For a session that ran with nobody watching: when, by the clock of
  /// the device that reports it, in seconds since the epoch.
  final int? at;

  /// For a member's access to a vault set apart from their role: what they
  /// are held to there.
  final Set<String>? switches;
}

/// Every entry of [entries] (the record of [orchardId], oldest first) as a
/// change, oldest first. Entries this device checked when they arrived are
/// replayed as trusted; should one still fail, the changes before it are
/// returned.
Future<List<TeamChange>> teamChanges(String orchardId, List<RecordEntry> entries) async {
  final state = OrchardRecord(orchardId);
  final out = <TeamChange>[];
  for (final e in entries) {
    out.add(describeRecordEntry(e, state));
    try {
      await state.append(e, trusted: true);
    } catch (err) {
      AppLogger.warning('Team: the record did not replay past entry ${e.seq} ($err)');
      break;
    }
  }
  return out;
}

/// [e] as a change, [before] being the record just before it.
TeamChange describeRecordEntry(RecordEntry e, OrchardRecord before) {
  Map<String, Object?> body;
  try {
    body = e.body;
  } catch (_) {
    body = const {};
  }
  String? str(String k) => body[k] is String ? body[k] as String : null;
  TeamChange change(TeamChangeKind kind,
          {String? member,
          String? crate,
          String? role,
          String? approver,
          int? until,
          int? hours,
          int? at,
          Set<String>? switches}) =>
      TeamChange(
        seq: e.seq,
        kind: kind,
        by: e.by,
        byKeyVersion: e.byKeyVersion,
        member: member,
        crateId: crate,
        roleId: role,
        approver: approver,
        until: until,
        hours: hours,
        at: at,
        switches: switches,
      );
  switch (e.type) {
    case RecordTypes.create:
      return change(TeamChangeKind.created);
    case RecordTypes.crateAdd:
      return change(TeamChangeKind.crateAdded, crate: str('id'));
    case RecordTypes.crateSet:
      // Session logs are tracking: named on their own.
      if (body['session_logs'] is bool) {
        return change(body['session_logs'] == true ? TeamChangeKind.sessionLogsOn : TeamChangeKind.sessionLogsOff,
            crate: str('id'));
      }
      // So are watched sessions.
      if (body['watched'] is bool) {
        return change(body['watched'] == true ? TeamChangeKind.watchedOn : TeamChangeKind.watchedOff,
            crate: str('id'));
      }
      // And who connects there with nobody watching while ZestSSH Cloud
      // cannot be reached.
      if (body['unwatched_away'] is bool) {
        return change(
            body['unwatched_away'] == true ? TeamChangeKind.unwatchedAwayOn : TeamChangeKind.unwatchedAwayOff,
            crate: str('id'));
      }
      // And a Crate's own offline limit keeps people out of it: named, with
      // how long it is.
      final hours = body['offline_hours'];
      if (hours is int) {
        return hours > 0
            ? change(TeamChangeKind.crateOfflineSet, crate: str('id'), hours: hours)
            : change(TeamChangeKind.crateOfflineOff, crate: str('id'));
      }
      return change(TeamChangeKind.crateSettings, crate: str('id'));
    case RecordTypes.roleSet:
      final id = str('id');
      return change(
        before.roles.containsKey(id) ? TeamChangeKind.roleChanged : TeamChangeKind.roleAdded,
        role: id,
      );
    case RecordTypes.roleDrop:
      return change(TeamChangeKind.roleDeleted, role: str('id'));
    case RecordTypes.memberAdd:
      final uid = str('uid');
      final again = before.members[uid]?.status == MemberStatus.removed;
      return change(
        again ? TeamChangeKind.memberAddedAgain : TeamChangeKind.memberAdded,
        member: uid,
        role: str('role'),
      );
    case RecordTypes.memberSet:
      final uid = str('uid');
      final role = str('role');
      if (role != null && role != before.members[uid]?.role) {
        return change(
          uid == e.by ? TeamChangeKind.memberSteppedDown : TeamChangeKind.memberRole,
          member: uid,
          role: role,
        );
      }
      return change(TeamChangeKind.memberAccess, member: uid);
    case RecordTypes.memberKeys:
      return change(TeamChangeKind.memberKeys, member: e.by);
    case RecordTypes.memberSuspend:
      return change(TeamChangeKind.memberSuspended, member: str('uid'));
    case RecordTypes.memberResume:
      return change(TeamChangeKind.memberResumed, member: str('uid'));
    case RecordTypes.memberRemove:
      final uid = str('uid');
      return change(uid == e.by ? TeamChangeKind.memberLeft : TeamChangeKind.memberRemoved, member: uid);
    case RecordTypes.keyRotate:
      final crate = str('crate');
      return crate == null ? change(TeamChangeKind.orchardKey) : change(TeamChangeKind.crateKey, crate: crate);
    case RecordTypes.rulesSet:
      return change(TeamChangeKind.rules);
    case RecordTypes.recoverySet:
      return change(body['on'] == true ? TeamChangeKind.teamRecoveryOn : TeamChangeKind.teamRecoveryOff);
    case RecordTypes.memberRecover:
      return change(TeamChangeKind.memberRecovered, member: str('uid'), approver: str('approver'));
    case RecordTypes.caSet:
      return change(TeamChangeKind.certificateAuthority, crate: str('crate'));
    case RecordTypes.trackingSet:
      return change(TeamChangeKind.tracking);
    case RecordTypes.accessGrant:
      final uid = str('uid');
      final until = body['until'];
      if (until is! int) break;
      if (until != 0) return change(TeamChangeKind.accessGiven, member: uid, crate: str('crate'), until: until);
      return change(uid == e.by ? TeamChangeKind.accessGivenUp : TeamChangeKind.accessEnded,
          member: uid, crate: str('crate'));
    case RecordTypes.deviceTrust:
      final uid = str('uid');
      return change(uid == e.by ? TeamChangeKind.deviceApprovedOwn : TeamChangeKind.deviceApproved, member: uid);
    case RecordTypes.deviceRevoke:
      final uid = str('uid');
      return change(uid == e.by ? TeamChangeKind.deviceRemovedOwn : TeamChangeKind.deviceRemoved, member: uid);
    case RecordTypes.exportSet:
      return change(body['on'] == true ? TeamChangeKind.exportOn : TeamChangeKind.exportOff);
    case RecordTypes.sessionUnwatched:
      final at = body['at'];
      return change(TeamChangeKind.sessionUnwatched, crate: str('crate'), at: at is int ? at : null);
    case RecordTypes.memberLimit:
      final switches = body['switches'];
      if (switches == null) return change(TeamChangeKind.memberVaultBack, member: str('uid'), crate: str('crate'));
      if (switches is! List) break;
      if (switches.isEmpty) return change(TeamChangeKind.memberVaultTaken, member: str('uid'), crate: str('crate'));
      return change(TeamChangeKind.memberVaultSet,
          member: str('uid'), crate: str('crate'), switches: {...switches.whereType<String>()});
    case RecordTypes.adminSet:
      return change(body.containsKey('all') ? TeamChangeKind.adminReset : TeamChangeKind.adminChanged);
    case RecordTypes.teamDelete:
      return change(TeamChangeKind.teamDeleted);
    case RecordTypes.teamRestore:
      return change(TeamChangeKind.teamRestored);
  }
  return change(TeamChangeKind.other);
}
