import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/setup/setup_file.dart';
import 'package:zestssh/features/orchards/setup/setup_plan.dart';
import 'package:zestssh/features/orchards/setup/setup_snapshot.dart';

// An Orchard written as a setup file (3.0): what this account can
// read of it, in the words a file uses. Two things hold for what comes out:
//
//  - Compared with the Orchard it was written from, it changes nothing.
//  - It never says less than is there. A file's word on what a role gives
//    in Crates, or on a member's extra Crates or limits, is all of it; so
//    where one of those reaches something the file cannot name (a Crate
//    this account cannot open), that part is not written at all, and
//    applying the file leaves it as it is. What was left out, and why, is
//    said beside the file.

/// Why something of the Orchard is not in an exported file.
enum SetupLeftOutKind {
  /// [SetupLeftOut.count] Crates this account cannot open: their names,
  /// and what is in them, are closed to it.
  closedCrates,

  /// [SetupLeftOut.names]: each stands for more than one Crate, role or
  /// host (of one Crate), and a file names each thing by its name.
  sharedNames,

  /// [SetupLeftOut.count] things whose name a file cannot carry (a
  /// character that does not show, or a name too long).
  unwritableNames,

  /// [SetupLeftOut.count] hosts that are not reached at an address (a
  /// serial line, a local shell).
  otherHosts,

  /// [SetupLeftOut.count] roles whose names this device cannot read.
  unreadRoles,

  /// [SetupLeftOut.names]: roles called like one of the Orchard's own two.
  rolesLikeOwn,

  /// [SetupLeftOut.names]: roles, members and hosts that are in the file
  /// with a part not written (what a role gives in Crates, a member's role,
  /// extra Crates or limits, a host's key, group, port or tags), because
  /// that part names something the file does not hold.
  partsNotWritten,

  /// [SetupLeftOut.count] members whose address this device does not know.
  membersWithoutAddress,
}

class SetupLeftOut {
  const SetupLeftOut(this.kind, {this.count, this.names = const []});

  final SetupLeftOutKind kind;
  final int? count;
  final List<String> names;

  @override
  String toString() => [
        kind.name,
        if (count != null) '$count',
        if (names.isNotEmpty) names.join(','),
      ].join(' ');
}

/// An exported file, and what of the Orchard is not in it.
class SetupExport {
  const SetupExport({required this.file, required this.leftOut});

  final SetupFile file;
  final List<SetupLeftOut> leftOut;

  String get text => writeSetupFile(file);
}

/// The Orchard [now] as a setup file. See the top of this file.
SetupExport exportSetup(OrchardSnapshot now) {
  final record = now.record;
  final shared = <String>[];
  final partial = <String>[];
  final likeOwn = <String>[];
  var unwritable = 0, otherHosts = 0, withoutAddress = 0;

  int byName(String a, String b) {
    final c = setupNameKey(a).compareTo(setupNameKey(b));
    return c != 0 ? c : a.compareTo(b);
  }

  // The Crates a file can name: open to this account, called what no other
  // Crate here is, in a name a file carries.
  final cratesCalled = <String, int>{};
  for (final c in now.crates) {
    final name = c.name;
    if (name != null) cratesCalled.update(setupNameKey(name), (n) => n + 1, ifAbsent: () => 1);
  }
  final crateNames = <String, String>{};
  for (final c in now.crates) {
    final name = c.name?.trim();
    if (name == null) continue;
    if (cratesCalled[setupNameKey(name)]! > 1) {
      if (!shared.contains(name)) shared.add(name);
    } else if (!isSetupName(name, max: kSetupMaxSpaceName)) {
      unwritable++;
    } else {
      crateNames[c.id] = name;
    }
  }

  /// [byId] under the Crates' names; null when one of them has none here.
  Map<String, Set<String>>? named(Map<String, Set<String>> byId) {
    if (byId.keys.any((id) => !crateNames.containsKey(id))) return null;
    return {for (final e in byId.entries) crateNames[e.key]!: {...e.value}};
  }

  /// The name a host of [crateId] can call [id] by (a key, or a group);
  /// null when its name would not lead back to it.
  String? nameOf(List<SnapshotNamed> all, String id, String crateId) {
    final it = all.where((x) => x.id == id).firstOrNull;
    final name = it?.name.trim();
    if (name == null || !isSetupName(name, max: kSetupMaxItemName)) return null;
    final found = calledIn(all, name, crateId);
    return found.length == 1 && found.single.id == id ? name : null;
  }

  final crates = <SetupCrate>[];
  final written = now.crates.where((c) => crateNames.containsKey(c.id)).toList()
    ..sort((a, b) => byName(crateNames[a.id]!, crateNames[b.id]!));
  for (final c in written) {
    final crate = record.crates[c.id];
    if (crate == null) continue;
    final here = now.hosts.where((h) => h.crateId == c.id).toList()..sort((a, b) => byName(a.name, b.name));
    final hostsCalled = <String, int>{};
    for (final h in here) {
      hostsCalled.update(setupNameKey(h.name), (n) => n + 1, ifAbsent: () => 1);
    }
    final hosts = <SetupHost>[];
    for (final h in here) {
      final name = h.name.trim();
      final address = h.address.trim();
      // FTPS hosts as well (3.4.1): a file that names one is written as the
      // version that knows them (SetupFile.version).
      final protocol = setupProtocolWord(h.protocol);
      if (protocol == null) {
        otherHosts++;
        continue;
      }
      if (hostsCalled[setupNameKey(name)]! > 1) {
        if (!shared.contains(name)) shared.add(name);
        continue;
      }
      if (!isSetupName(name, max: kSetupMaxItemName) ||
          !isSetupName(address, max: kSetupMaxItemName) ||
          address.contains(RegExp(r'\s'))) {
        unwritable++;
        continue;
      }
      var whole = true;
      Named<String?>? called(List<SnapshotNamed> all, String? id) {
        if (id == null) return const Named(null);
        final name = nameOf(all, id, c.id);
        if (name == null) whole = false;
        return name == null ? null : Named(name);
      }

      final key = called(now.keys, h.keyId);
      // Its other accounts by their keys' names (3.0, accounts per host).
      final accounts = <String>[
        for (final id in h.accountIds.take(kSetupMaxAccounts))
          if (called(now.keys, id) case final name? when name.value != null) name.value!,
      ];
      if (h.accountIds.length > kSetupMaxAccounts) whole = false;
      final group = called(now.groups, h.groupId);
      final port = h.port >= 1 && h.port <= 65535 ? h.port : null;
      final tags = h.tags.length <= kSetupMaxTags &&
              h.tags.every((t) => isSetupName(t, max: kSetupMaxTag) && t == t.toLowerCase())
          ? {...h.tags}
          : null;
      if (port == null || tags == null) whole = false;
      if (!whole) partial.add(name);
      hosts.add(SetupHost(
        name: name,
        address: address,
        port: port,
        protocol: protocol,
        key: key,
        accounts: accounts.isEmpty ? null : accounts,
        group: group,
        tags: tags,
      ));
    }
    crates.add(SetupCrate(
      name: crateNames[c.id]!,
      ownersOnly: crate.ownersOnly,
      allow: {...crate.allow},
      askAgain: crate.confirmReveal,
      sessionLogs: crate.sessionLogs,
      watched: crate.watched,
      unwatchedAway: crate.unwatchedAway,
      offlineHours: crate.offlineHours,
      hosts: hosts,
    ));
  }

  // The roles a file can name, highest first.
  final rolesCalled = <String, int>{};
  for (final r in now.roles) {
    final name = r.name;
    if (name != null) rolesCalled.update(setupNameKey(name), (n) => n + 1, ifAbsent: () => 1);
  }
  final roleNames = <String, String>{};
  final roles = <SetupRole>[];
  for (final r in now.roles) {
    final name = r.name?.trim();
    final role = record.roles[r.id];
    if (name == null || role == null) continue;
    if (rolesCalled[setupNameKey(name)]! > 1) {
      if (!shared.contains(name)) shared.add(name);
      continue;
    }
    if (isFixedRoleName(name)) {
      likeOwn.add(name);
      continue;
    }
    if (!isSetupName(name, max: kSetupMaxSpaceName)) {
      unwritable++;
      continue;
    }
    roleNames[r.id] = name;
    final gives = named(role.crates);
    if (gives == null) partial.add(name);
    roles.add(SetupRole(name: name, can: {...role.can}, crates: gives));
  }

  // The members, most senior first, then by address.
  final members = <SetupMember>[];
  final listed = [
    for (final m in now.members)
      if (record.members[m.uid] != null && record.members[m.uid]!.status != MemberStatus.removed) m,
  ]..sort((a, b) {
      final rank = record.rankOfRole(record.members[b.uid]!.role).compareTo(record.rankOfRole(record.members[a.uid]!.role));
      return rank != 0 ? rank : (a.email ?? a.uid).compareTo(b.email ?? b.uid);
    });
  for (final m in listed) {
    final member = record.members[m.uid]!;
    final email = m.email?.trim().toLowerCase();
    if (email == null || !isSetupAddress(email)) {
      withoutAddress++;
      continue;
    }
    final fixed = member.role == FixedRoles.owner || member.role == FixedRoles.admin;
    final role = fixed ? member.role : roleNames[member.role];
    // No extra Crates, no limits and no end are not said: a file that says
    // them holds a member to them.
    final extra = member.grants.isEmpty ? null : named(member.grants);
    // Their limits beside their extra Crates, by the Crates'
    // names in the order names stand everywhere in the file. (Owners and
    // admins have none.)
    final held = member.limits.isEmpty ? null : named(member.limits);
    final limits = held == null ? null : {for (final name in held.keys.toList()..sort(byName)) name: held[name]!};
    if (role == null ||
        (member.grants.isNotEmpty && extra == null) ||
        (member.limits.isNotEmpty && limits == null)) {
      partial.add(email);
    }
    members.add(SetupMember(
      email: email,
      role: role,
      crates: extra,
      limits: limits,
      until: member.endsAt == null ? null : Named(member.endsAt),
    ));
  }

  final orchard = now.name.trim();
  final file = SetupFile(
    orchard: isSetupName(orchard, max: kSetupMaxSpaceName) ? orchard : null,
    rules: SetupRules.of(record.rules),
    records: SetupRecords.of(record.tracking),
    crates: crates,
    roles: roles,
    members: members,
  );
  // What is written must read: a file nobody could check is worth nothing.
  final read = readSetupFile(writeSetupFile(file));
  if (!read.ok) throw StateError('The exported file does not read: ${read.problems.join('; ')}');

  final closed = now.crates.where((c) => !c.open).length;
  final unread = now.roles.where((r) => r.name == null).length;
  return SetupExport(file: file, leftOut: [
    if (closed > 0) SetupLeftOut(SetupLeftOutKind.closedCrates, count: closed),
    if (shared.isNotEmpty) SetupLeftOut(SetupLeftOutKind.sharedNames, names: shared),
    if (unwritable > 0) SetupLeftOut(SetupLeftOutKind.unwritableNames, count: unwritable),
    if (otherHosts > 0) SetupLeftOut(SetupLeftOutKind.otherHosts, count: otherHosts),
    if (unread > 0) SetupLeftOut(SetupLeftOutKind.unreadRoles, count: unread),
    if (likeOwn.isNotEmpty) SetupLeftOut(SetupLeftOutKind.rolesLikeOwn, names: likeOwn),
    if (partial.isNotEmpty) SetupLeftOut(SetupLeftOutKind.partsNotWritten, names: partial),
    if (withoutAddress > 0) SetupLeftOut(SetupLeftOutKind.membersWithoutAddress, count: withoutAddress),
  ]);
}
