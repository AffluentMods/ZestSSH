part of 'orchard_service.dart';

// Changing an Orchard part by part (3.0, setup as code). A setup
// file names some of what a Crate, a role, a member, the rules or what the
// team records should be; each change here puts what is named over the
// record as it stands when the change is made, and leaves the rest as it
// is. Where nothing differs, nothing is sent.
//
// The entries are built by the functions at the top, from a record and what
// is named, with no keys and no server: a plan rehearses a file with the
// very same functions on a copy of the record (setup_plan.dart), so what it
// shows is what would be written.

/// What is named of a Crate's settings.
class CrateParts {
  const CrateParts({
    this.open = false,
    this.allow,
    this.askAgain,
    this.sessionLogs,
    this.watched,
    this.unwatchedAway,
    this.offlineHours,
  });

  /// An owners-only Crate is opened to admins and to the roles given it.
  final bool open;

  /// Which of SFTP, port forwarding and agent forwarding it allows at all.
  final Set<String>? allow;

  /// Showing or copying a secret from it asks for the device PIN or a
  /// fingerprint first.
  final bool? askAgain;

  /// Sessions to its hosts are logged.
  final bool? sessionLogs;

  /// Sessions to its hosts are watched.
  final bool? watched;

  /// While ZestSSH Cloud cannot be reached, everyone who may connect to its
  /// hosts may do so with nobody watching, after giving a reason, and not
  /// owners alone.
  final bool? unwatchedAway;

  /// How many hours a device may go without reaching ZestSSH Cloud before
  /// the Crate closes on it; 0 for no limit of its own.
  final int? offlineHours;
}

/// The crate.set that makes [crateId] what [parts] names, as [latest]
/// stands: only what differs is in it, and there is none when nothing does.
/// A watched Crate allows the terminal only, so a Crate that is watched
/// after the change and whose [CrateParts.allow] is not named allows
/// nothing in the same entry; one named as allowing something then is for
/// the record to refuse.
List<RecordChange> crateSettingsChange(OrchardRecord latest, String crateId, CrateParts parts) {
  final crate = latest.crates[crateId];
  if (crate == null) throw const OrchardRecordRefused('no such Crate');
  final watched = parts.watched ?? crate.watched;
  final allow = parts.allow ?? (watched ? const <String>{} : crate.allow);
  final body = <String, Object?>{
    'id': crateId,
    if (parts.open && crate.ownersOnly) 'owners_only': false,
    if (!_sameSwitches(allow, crate.allow)) 'allow': switchList(allow),
    if (parts.askAgain != null && parts.askAgain != crate.confirmReveal) 'confirm_reveal': parts.askAgain,
    if (parts.sessionLogs != null && parts.sessionLogs != crate.sessionLogs) 'session_logs': parts.sessionLogs,
    if (parts.watched != null && parts.watched != crate.watched) 'watched': parts.watched,
    if (parts.unwatchedAway != null && parts.unwatchedAway != crate.unwatchedAway)
      'unwatched_away': parts.unwatchedAway,
    if (parts.offlineHours != null && parts.offlineHours != crate.offlineHours) 'offline_hours': parts.offlineHours,
  };
  return body.length == 1 ? const [] : [(type: RecordTypes.crateSet, body: body)];
}

/// The role.set that gives the role [roleId] what is named of [can] (what
/// it may do in the Orchard) and [crates] (Crate id to switches: named, it
/// is all the role gives), as [latest] stands; none when nothing differs.
/// Its name and its place among the roles stay.
List<RecordChange> rolePartsChange(
  OrchardRecord latest,
  String roleId, {
  Set<String>? can,
  Map<String, Set<String>>? crates,
}) {
  final role = latest.roles[roleId];
  if (role == null) throw const OrchardRecordRefused('no such role');
  final nextCan = can ?? role.can;
  final nextCrates = crates ?? role.crates;
  if (_sameSwitches(nextCan, role.can) && _sameCrateMap(nextCrates, role.crates)) return const [];
  return [
    (
      type: RecordTypes.roleSet,
      body: {
        ...roleBody(role),
        'can': switchList(nextCan),
        'crates': {for (final c in nextCrates.entries) c.key: switchList(c.value)},
      },
    ),
  ];
}

/// [current] (role ids, highest first) with the roles of [named] in the
/// order [named] has them, in the places those roles hold now: a role that
/// is not named keeps its place, whatever moves around it. Ids in [named]
/// that [current] does not have are skipped.
List<String> roleOrderWith(List<String> current, List<String> named) {
  final places = [
    for (var i = 0; i < current.length; i++)
      if (named.contains(current[i])) i,
  ];
  final inOrder = [
    for (final id in named)
      if (current.contains(id)) id,
  ];
  final out = [...current];
  for (var i = 0; i < places.length; i++) {
    out[places[i]] = inOrder[i];
  }
  return out;
}

/// The order a file means for the roles ([current]: ids, highest first, the
/// ones the file [added] at the bottom where a new role goes): the roles it
/// names that were there already take its order among themselves, in the
/// places they hold ([roleOrderWith]); a role it added stands just above
/// the role the file names after it, and the last one it names stays below
/// every role. So a role the file does not name loses its place to no role
/// that was there, and a new role is no higher than the file says.
List<String> roleOrderFor(List<String> current, List<String> named, Set<String> added) {
  final out = roleOrderWith(
    [
      for (final id in current)
        if (!added.contains(id)) id,
    ],
    [
      for (final id in named)
        if (!added.contains(id)) id,
    ],
  );
  // The last one named first: the one before it may stand just above it.
  for (var i = named.length - 1; i >= 0; i--) {
    final id = named[i];
    if (!added.contains(id) || !current.contains(id)) continue;
    final below = i + 1 < named.length ? out.indexOf(named[i + 1]) : -1;
    if (below < 0) {
      out.add(id);
    } else {
      out.insert(below, id);
    }
  }
  // (A role added that the file's order leaves out stays at the bottom.)
  for (final id in current) {
    if (!out.contains(id)) out.add(id);
  }
  return out;
}

/// The role.set entries that put the roles of [named] in that order among
/// themselves ([roleOrderWith]), as [latest] stands; none when they stand
/// so already. One role that moved goes as [reorderRoles] moves it; more
/// than one, and every role is numbered again, first to ranks no role holds
/// or will hold, so no two roles share a rank at any entry.
List<RecordChange> roleOrderChange(OrchardRecord latest, List<String> named) {
  final current = rolesHighestFirst(latest);
  final target = roleOrderWith(current, named);
  if (_sameList(current, target)) return const [];
  for (final id in target) {
    if (_sameList([...current]..remove(id), [...target]..remove(id))) {
      final role = latest.roles[id]!;
      return reorderRoles(latest, target, id, (rank) => roleBody(role, rank: rank));
    }
  }
  final n = target.length;
  final step = math.min(1000, maxCustomRank ~/ (n + 1));
  final targets = {for (var i = 0; i < n; i++) target[i]: (n - i) * step};
  final taken = {...latest.roles.values.map((r) => r.rank), ...targets.values};
  final spare = <int>[];
  for (var r = maxCustomRank; spare.length < n; r--) {
    if (!taken.contains(r)) spare.add(r);
  }
  return [
    for (var i = 0; i < n; i++) (type: RecordTypes.roleSet, body: roleBody(latest.roles[target[i]]!, rank: spare[i])),
    for (final id in target) (type: RecordTypes.roleSet, body: roleBody(latest.roles[id]!, rank: targets[id])),
  ];
}

/// The body of the member.set that makes [uid] what is named of [role]
/// ('owner', 'admin' or a role's id), [grants] (their extra Crates, Crate
/// id to switches: named, it is all of them) and [endsAt] (named as none,
/// their access does not end), as [latest] stands; null when nothing
/// differs. An owner or admin holds no extra Crates and an owner has no end
/// date, so a role that makes someone one clears what is not named with it
/// ([roleChangeBody]).
Map<String, Object?>? memberPartsBody(
  OrchardRecord latest,
  String uid, {
  String? role,
  Map<String, Set<String>>? grants,
  Named<int?>? endsAt,
}) {
  final member = latest.members[uid];
  if (member == null || member.status == MemberStatus.removed) throw const OrchardRecordRefused('not a member');
  final nextRole = role ?? member.role;
  final fixed = nextRole == FixedRoles.owner || nextRole == FixedRoles.admin;
  final nextGrants = grants ?? (fixed ? const <String, Set<String>>{} : member.grants);
  final nextEnds = endsAt == null ? (nextRole == FixedRoles.owner ? null : member.endsAt) : endsAt.value;
  final body = <String, Object?>{
    'uid': uid,
    if (nextRole != member.role) 'role': nextRole,
    if (!_sameCrateMap(nextGrants, member.grants))
      'grants': {for (final g in nextGrants.entries) g.key: switchList(g.value)},
    if (nextEnds != member.endsAt) 'ends_at': nextEnds ?? 0,
  };
  return body.length == 1 ? null : body;
}

/// The member.limit that holds [uid] to [switches] in the Crate [crateId]
/// (vault access per member: an empty set is No access), or with
/// [switches] null lifts their limit there, as [latest] stands; none when
/// that is their limit there already. It is written as the member panel
/// writes one ([memberLimitBody]); the record decides whether it may be.
List<RecordChange> memberLimitChange(OrchardRecord latest, String uid, String crateId, Set<String>? switches) {
  final member = latest.members[uid];
  if (member == null || member.status == MemberStatus.removed) throw const OrchardRecordRefused('not a member');
  final was = member.limits[crateId];
  if (switches == null ? was == null : was != null && _sameSwitches(was, switches)) return const [];
  return [(type: RecordTypes.memberLimit, body: memberLimitBody(uid, crateId, switches))];
}

/// The rules.set that puts what [parts] names over the rules of [latest];
/// none when nothing differs.
List<RecordChange> rulesPartsChange(OrchardRecord latest, SetupRules parts) {
  final next = parts.over(latest.rules);
  return jsonEncode(next.toBody()) == jsonEncode(latest.rules.toBody())
      ? const []
      : [(type: RecordTypes.rulesSet, body: next.toSetBody())];
}

/// The tracking.set that puts what [parts] names over what the team
/// records in [latest]; none when nothing differs.
List<RecordChange> recordsPartsChange(OrchardRecord latest, SetupRecords parts) {
  final next = parts.over(latest.tracking);
  return next == latest.tracking ? const [] : [(type: RecordTypes.trackingSet, body: next.toBody())];
}

bool _sameSwitches(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

bool _sameCrateMap(Map<String, Set<String>> a, Map<String, Set<String>> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] != null && _sameSwitches(e.value, b[e.key]!));

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

extension OrchardSetupChanges on OrchardService {
  /// Makes the Crate [crateId] what [parts] names ([crateSettingsChange]).
  Future<void> setCrateParts(String orchardId, String crateId, CrateParts parts) =>
      _changeWith(orchardId, (latest) async => crateSettingsChange(latest, crateId, parts));

  /// Gives the role [roleId] what is named of [can] and [crates]
  /// ([rolePartsChange]). Members who gain a Crate get its keys in the
  /// same step.
  Future<void> setRoleParts(String orchardId, String roleId, {Set<String>? can, Map<String, Set<String>>? crates}) =>
      _changeWith(orchardId, (latest) async => rolePartsChange(latest, roleId, can: can, crates: crates));

  /// Puts the roles of [named] (ids, highest first) in that order among
  /// themselves ([roleOrderChange]).
  Future<void> orderRoles(String orchardId, List<String> named) =>
      _changeWith(orchardId, (latest) async => roleOrderChange(latest, named));

  /// Makes the member [uid] what is named of [role], [grants] and [endsAt]
  /// ([memberPartsBody]), in one entry. Making someone an owner or admin
  /// carries this account's comparison of their keys: throws
  /// [MemberNotCompared] when this device's person has not compared them.
  Future<void> setMemberParts(
    String orchardId,
    String uid, {
    String? role,
    Map<String, Set<String>>? grants,
    Named<int?>? endsAt,
  }) =>
      _changeWith(orchardId, (latest) async {
        final body = memberPartsBody(latest, uid, role: role, grants: grants, endsAt: endsAt);
        if (body == null) return const [];
        final from = latest.members[uid]!.role;
        final to = body['role'] as String? ?? from;
        return [
          (
            type: RecordTypes.memberSet,
            body: makesOwnerOrAdmin(from, to) ? await _withComparison(orchardId, latest, uid, body) : body,
          ),
        ];
      });

  /// Holds the member [uid] to [switches] in the Crate [crateId], or lifts
  /// their limit there ([memberLimitChange]). A limit taken off gives
  /// access back, with the keys that go with it.
  Future<void> setMemberLimit(String orchardId, String uid, String crateId, Set<String>? switches) =>
      _changeWith(orchardId, (latest) async => memberLimitChange(latest, uid, crateId, switches));

  /// Puts what [parts] names over the Orchard's rules ([rulesPartsChange]).
  /// Owners only; the server refuses rules the owner does not meet
  /// themselves.
  Future<void> setRuleParts(String orchardId, SetupRules parts) =>
      _changeWith(orchardId, (latest) async => rulesPartsChange(latest, parts));

  /// Puts what [parts] names over what the team records about its members
  /// ([recordsPartsChange]). Owners only; every member's device tells its
  /// person.
  Future<void> setRecordParts(String orchardId, SetupRecords parts) =>
      _changeWith(orchardId, (latest) async => recordsPartsChange(latest, parts));
}
