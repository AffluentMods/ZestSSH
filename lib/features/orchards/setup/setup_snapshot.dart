import 'package:zestssh/features/orchards/record/orchard_record.dart';

// An Orchard as a setup file is compared with (3.0): its record,
// and what this device can add to it from the keys it holds: the names of
// the Crates and roles this account can read, who the members are by
// address, the invitations that wait, and the hosts, keys and groups in
// the Crates it can open. Plain data, with no database and no server, so a
// plan can be made from one and tested with one written by hand.

/// A Crate, with its name where this account can open it.
class SnapshotCrate {
  const SnapshotCrate({required this.id, this.name});

  final String id;

  /// Null when this account cannot open the Crate: its name is encrypted
  /// with a key this device does not hold.
  final String? name;

  bool get open => name != null;
}

/// A role the owners made, with its name where it could be read.
class SnapshotRole {
  const SnapshotRole({required this.id, this.name});

  final String id;

  /// Null when the Orchard key it was encrypted with is not on this device.
  final String? name;
}

/// A member, with what this device knows of them beyond the record.
class SnapshotMember {
  const SnapshotMember({required this.uid, this.email, this.compared = false, this.keysTrusted = true});

  final String uid;

  /// Their address, in small letters; null when this device never heard it.
  final String? email;

  /// This device's person compared the keys the record holds for them now
  /// Without it they cannot be made an owner or admin from here.
  final bool compared;

  /// This device holds the keys the record has for them now and is not
  /// stopped on a change of them: without it nothing can be sealed to them
  /// from here, so nothing they would gain can be given.
  final bool keysTrusted;
}

/// An invitation that waits.
class SnapshotInvite {
  const SnapshotInvite({
    required this.email,
    required this.role,
    this.grants = const {},
    this.endsAt,
    this.expired = false,
    this.accepted = false,
  });

  final String email;

  /// 'owner', 'admin' or a role's id.
  final String role;
  final Map<String, Set<String>> grants;
  final int? endsAt;
  final bool expired;

  /// The person accepted: someone compares their keys and confirms.
  final bool accepted;
}

/// A host in a Crate this device holds.
class SnapshotHost {
  const SnapshotHost({
    required this.id,
    required this.crateId,
    required this.name,
    required this.address,
    required this.port,
    required this.protocol,
    this.keyId,
    this.accountIds = const [],
    this.groupId,
    this.tags = const {},
  });

  final String id;
  final String crateId;
  final String name;
  final String address;
  final int port;
  final String protocol;
  final String? keyId;

  /// Its other accounts (3.0, accounts per host): the ids of the keys it
  /// can also be signed in with, in their order.
  final List<String> accountIds;
  final String? groupId;
  final Set<String> tags;
}

/// A key (a saved login) or a group of hosts: something a host names.
class SnapshotNamed {
  const SnapshotNamed({required this.id, required this.crateId, required this.name});

  final String id;
  final String crateId;
  final String name;
}

/// See the top of this file.
class OrchardSnapshot {
  const OrchardSnapshot({
    required this.orchardId,
    required this.name,
    required this.me,
    required this.record,
    required this.now,
    this.myEmail,
    this.crates = const [],
    this.roles = const [],
    this.members = const [],
    this.invites,
    this.hosts = const [],
    this.keys = const [],
    this.groups = const [],
    this.lockOn,
    this.lockMinutes,
    this.reached = true,
    this.newKindsOn = false,
    this.provenDomains = const {},
  });

  final String orchardId;
  final String name;

  /// The domains the Orchard proved, as far as they could be read: someone
  /// outside them needs an end date.
  final Set<String> provenDomains;

  /// The account that looks, and that would apply.
  final String me;
  final String? myEmail;

  /// The Orchard's record as this device has it: every member's role, extra
  /// Crates, limits and end with it.
  final OrchardRecord record;

  /// When it was taken, in seconds since the epoch.
  final int now;

  /// Every Crate of the record.
  final List<SnapshotCrate> crates;

  /// Every role of the record, highest first.
  final List<SnapshotRole> roles;

  /// Everyone the record has who was not removed.
  final List<SnapshotMember> members;

  /// The invitations that wait; null when this account may not see them
  /// (its role cannot invite) or ZestSSH Cloud could not be asked.
  final List<SnapshotInvite>? invites;

  /// The hosts, keys and groups of the Crates this device holds.
  final List<SnapshotHost> hosts;
  final List<SnapshotNamed> keys;
  final List<SnapshotNamed> groups;

  /// This device's app lock, where it could be read: whether it is on, and
  /// after how many minutes it locks (0 for never by itself).
  final bool? lockOn;
  final int? lockMinutes;

  /// Whether ZestSSH Cloud was reached just before: when it was not, this
  /// is the Orchard as this device last saw it.
  final bool reached;

  /// Whether ZestSSH Cloud takes the kinds of team record entry that older
  /// versions cannot read yet (a member's limit), as the last
  /// list of Orchards said: until it does, it refuses them. Off until one
  /// says otherwise.
  final bool newKindsOn;

  SnapshotCrate? crate(String id) => crates.where((c) => c.id == id).firstOrNull;

  SnapshotRole? role(String id) => roles.where((r) => r.id == id).firstOrNull;

  SnapshotMember? member(String uid) => members.where((m) => m.uid == uid).firstOrNull;
}
