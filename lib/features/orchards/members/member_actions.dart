import 'package:zestssh/features/orchards/record/orchard_record.dart';

/// What this account may change about another member under the Orchard's
/// rules (3.0): the menus offer exactly these. The rules decide
/// again when a change is made, here and on the server, so this only
/// shapes what is shown.
class MemberActions {
  const MemberActions({
    this.roles = const [],
    this.grants = false,
    this.endDate = false,
    this.makeOwner = false,
    this.suspend = false,
    this.resume = false,
    this.remove = false,
  });

  static const none = MemberActions();

  /// The roles this account may give them (their own included), highest
  /// first: Admin for an owner, then the roles below this account's rank.
  /// Making someone an owner is [makeOwner].
  final List<String> roles;

  /// Extra Crates: this account manages at least one Crate it may give.
  final bool grants;

  /// Setting or clearing the date their access ends.
  final bool endDate;
  final bool makeOwner;
  final bool suspend;
  final bool resume;
  final bool remove;

  /// A role other than the one they have.
  bool get changeRole => roles.length > 1;

  bool get any => changeRole || grants || endDate || makeOwner || suspend || resume || remove;

  /// What [me] may do about the member [uid] as [record] stands.
  static MemberActions of(OrchardRecord record, String me, String uid) {
    final target = record.members[uid];
    if (uid == me || target == null || target.status == MemberStatus.removed) return none;
    final myRank = record.rankOf(me);
    // Only people below you; owners are equals.
    if (myRank <= record.rankOfRole(target.role)) return none;
    final owner = record.isOwner(me);
    final changeRoles = owner || record.can(me, RoleCan.changeRoles);
    final fixed = target.role == FixedRoles.owner || target.role == FixedRoles.admin;
    final removes = record.can(me, RoleCan.remove);
    return MemberActions(
      roles: changeRoles
          ? [
              for (final r in [if (owner) FixedRoles.admin, ...rolesBelow(record, myRank)])
                if (r == target.role || handsOutOnlyOwn(record, me, uid, role: r)) r,
            ]
          : const [],
      grants: !fixed && manages(record, me).isNotEmpty,
      endDate: target.role != FixedRoles.owner && (target.role == FixedRoles.admin ? owner : changeRoles),
      makeOwner: owner && target.status == MemberStatus.active,
      suspend: removes && target.status == MemberStatus.active,
      resume: removes && target.status == MemberStatus.suspended,
      remove: removes,
    );
  }

  /// The roles the owners made that rank below [rank], highest first.
  static List<String> rolesBelow(OrchardRecord record, int rank) {
    final below = [
      for (final r in record.roles.values)
        if (r.rank < rank) r,
    ]..sort((a, b) => b.rank.compareTo(a.rank));
    return [for (final r in below) r.id];
  }

  /// Whether giving [uid] the role [role] (owners and admins lose their
  /// extra Crates with it) opens nothing to them that [me] does not have
  /// itself: whoever makes a change hands out only what they hold.
  static bool handsOutOnlyOwn(OrchardRecord record, String me, String uid, {required String role}) {
    final after = record.copy();
    final m = after.members[uid];
    if (m == null) return false;
    m.role = role;
    if (role == FixedRoles.owner || role == FixedRoles.admin) m.grants = {};
    for (final c in record.crates.keys) {
      final gained = after.switchesOf(uid, c).difference(record.switchesOf(uid, c));
      if (!record.switchesOf(me, c).containsAll(gained)) return false;
    }
    return true;
  }

  /// The Crates [me] may hand on: those it manages that are not
  /// owners-only (a role or a grant never reaches an owners-only Crate).
  static List<String> manages(OrchardRecord record, String me) => [
        for (final c in record.crates.values)
          if (!c.ownersOnly && record.switchesOf(me, c.id).contains(CrateSwitches.manage)) c.id,
      ];
}

/// What this account may do about its own membership: an owner steps down
/// to Admin while another owner stays; anyone but the last owner leaves.
/// Nothing once its end date has passed ([nowSeconds], this device's clock
/// unless given): ZestSSH Cloud no longer counts it a member then (one
/// counts while its end date is later than now), so there is nothing to
/// leave, and a Leave would be answered as for a stranger.
({bool stepDown, bool leave}) selfActions(OrchardRecord record, String me, {int? nowSeconds}) {
  if (!record.isActive(me)) return (stepDown: false, leave: false);
  final ends = record.members[me]!.endsAt;
  if (ends != null && ends <= (nowSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000)) {
    return (stepDown: false, leave: false);
  }
  final owners = record.owners.length;
  final owner = record.isOwner(me);
  return (stepDown: owner && owners >= 2, leave: !owner || owners >= 2);
}

/// The body of a member.set giving [uid] the role [role]: owners and admins
/// hold no extra Crates, and owners have no end date, so those are cleared
/// in the same entry.
Map<String, Object?> roleChangeBody(OrchardRecord record, String uid, String role) {
  final target = record.members[uid];
  final fixed = role == FixedRoles.owner || role == FixedRoles.admin;
  return {
    'uid': uid,
    'role': role,
    if (fixed && (target?.grants.isNotEmpty ?? false)) 'grants': const <String, Object?>{},
    if (role == FixedRoles.owner && target?.endsAt != null) 'ends_at': 0,
  };
}
