import 'package:zestssh/features/orchards/certs/crate_authorities.dart';
import 'package:zestssh/features/orchards/members/team_recovery.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';

/// Something about an Orchard's people that needs this account (3.0),
/// most pressing first. Where this account itself stands
/// (suspended, a rule not met, keys to replace) is the status banner's.
enum TeamAttentionKind {
  /// A member's keys changed and their old keys did not vouch for the new
  /// ones: nothing new is sealed to them until someone compares.
  keysChanged,

  /// A Crate's certificate authority needs a new key (shown to
  /// owners): someone who could open its key no longer can, and hosts trust
  /// what that key signs until it is replaced.
  authorityNewKey,

  /// A member lost every device and waits for two owners to give their
  /// access back (shown to owners).
  recoveryWaiting,

  /// People accepted an invitation and wait for this account to add them.
  invitesWaiting,

  /// A member deleted their ZestSSH account.
  accountDeleted,

  /// A member's access ends soon, and this account may change the date.
  accessEnding,

  /// Members who replaced their keys since this account compared them, and
  /// nobody compared the new ones yet (3.0).
  keysReplaced,

  /// Members nobody compared fingerprints with yet (shown to owners and
  /// admins).
  notVerified,
}

class TeamAttention {
  const TeamAttention(this.kind, {this.uid, this.crateId, this.count = 0, this.endsAt, this.approvedBy = const []});

  final TeamAttentionKind kind;

  /// The member it is about.
  final String? uid;

  /// The Crate it is about.
  final String? crateId;

  /// How many (invitations waiting, members not verified).
  final int count;

  /// When the member's access ends, in seconds since the epoch.
  final int? endsAt;

  /// For a member waiting for recovery: the owners who approved so far.
  final List<String> approvedBy;
}

/// How soon an end date shows as needing attention.
const kAccessEndingSoon = Duration(days: 14);

/// What about [orchard]'s people needs this account, most pressing first.
/// [people] is null while the member list is not read (or could not be);
/// only the invitations waiting show then. [recovery] is who waits for team
/// recovery, as an owner sees it; [authorities] the Crates' certificate
/// authorities.
List<TeamAttention> teamAttention({
  required OrchardSummary orchard,
  required OrchardPeople? people,
  required int nowSeconds,
  List<RecoveryWait> recovery = const [],
  Map<String, CrateAuthorityView> authorities = const {},
}) {
  final others = [
    for (final m in people?.members ?? const <OrchardPerson>[])
      if (!m.isMe && m.status != MemberStatus.removed) m,
  ];
  final soon = nowSeconds + kAccessEndingSoon.inSeconds;
  final runsTeam = orchard.isOwner || orchard.role == FixedRoles.admin;
  bool unchecked(OrchardPerson m) =>
      m.status == MemberStatus.active &&
      !m.accountDeleted &&
      m.trust?.fingerprint != null &&
      !m.trust!.hardStop &&
      !m.trust!.verifiedByMe &&
      m.trust!.verifiedBy.isEmpty;
  final replaced = others.where((m) => unchecked(m) && m.trust!.replacedSinceCompared).length;
  final notVerified = others.where((m) => unchecked(m) && !m.trust!.replacedSinceCompared).length;
  return [
    for (final m in others)
      if (m.trust?.hardStop ?? false) TeamAttention(TeamAttentionKind.keysChanged, uid: m.uid),
    if (orchard.isOwner)
      for (final a in authorities.values)
        if (a.newKeyNeeded) TeamAttention(TeamAttentionKind.authorityNewKey, crateId: a.crateId),
    if (orchard.isOwner)
      for (final w in recovery)
        TeamAttention(TeamAttentionKind.recoveryWaiting,
            uid: w.uid, approvedBy: [for (final a in w.approvals) a.uid]),
    if (orchard.canInvite && orchard.invitesWaiting > 0)
      TeamAttention(TeamAttentionKind.invitesWaiting, count: orchard.invitesWaiting),
    for (final m in others)
      if (m.accountDeleted) TeamAttention(TeamAttentionKind.accountDeleted, uid: m.uid),
    for (final m in others)
      if (m.status == MemberStatus.active &&
          !m.accountDeleted &&
          m.actions.endDate &&
          m.endsAt != null &&
          m.endsAt! > nowSeconds &&
          m.endsAt! <= soon)
        TeamAttention(TeamAttentionKind.accessEnding, uid: m.uid, endsAt: m.endsAt),
    // Whoever compared them before, whatever their role.
    if (replaced > 0) TeamAttention(TeamAttentionKind.keysReplaced, count: replaced),
    if (runsTeam && notVerified > 0) TeamAttention(TeamAttentionKind.notVerified, count: notVerified),
  ];
}
