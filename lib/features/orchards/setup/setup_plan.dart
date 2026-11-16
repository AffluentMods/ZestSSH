import 'dart:convert';
import 'dart:typed_data';

import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart' show canonicalJson;
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/features/orchards/setup/setup_file.dart';
import 'package:zestssh/features/orchards/setup/setup_snapshot.dart';
import 'package:zestssh/models/enums.dart' show ConnectionProtocol;

// What a setup file would change in an Orchard (3.0): the steps, in
// the order they would be made; what stands in the way of them; and what
// the file leaves alone.
//
// A plan is made by rehearsing the file on a copy of the Orchard's record:
// each step that changes the record is appended to the copy as the entries
// it would really be, and the record's own rules take or refuse them. So a
// step this account may not make (only owners set the rules; a role gives
// only what its maker has) is found here, before anything is sent, and a
// later step sees what the earlier ones did (a role in a Crate the file
// adds). Where anything stands in the way, nothing of the file is applied.
//
// The file never takes anything out of the Orchard: what it does not name
// is listed, and left.

/// One thing a file would change, as it differs from the Orchard now.
sealed class SetupStep {
  const SetupStep();

  /// Whether ZestSSH Cloud takes it only with a sign-in from the last few
  /// minutes: every change to who is in the Orchard or what they may
  /// do. Adding a Crate, inviting someone and writing a host do not.
  bool get needsRecentSignIn;
}

/// A Crate is added.
final class AddCrate extends SetupStep {
  const AddCrate({required this.name, required this.ownersOnly});

  final String name;
  final bool ownersOnly;

  @override
  bool get needsRecentSignIn => false;

  @override
  String toString() => 'add crate $name${ownersOnly ? ' (owners only)' : ''}';
}

/// A Crate's settings change: [parts] is what differs.
final class CrateSettings extends SetupStep {
  const CrateSettings({required this.crate, required this.parts, required this.allowsNothingWithWatching});

  /// The Crate's name.
  final String crate;
  final CrateParts parts;

  /// Watching is turned on and the file does not say what the Crate
  /// allows: what it allowed (SFTP, port forwarding, agent forwarding) goes
  /// off in the same step, since a watched Crate allows the terminal only.
  final bool allowsNothingWithWatching;

  @override
  bool get needsRecentSignIn => true;

  @override
  String toString() => [
        'crate $crate:',
        if (parts.open) 'open to admins and roles',
        if (parts.allow != null) 'allow ${_words(parts.allow!)}',
        if (parts.askAgain != null) 'ask again ${_onOff(parts.askAgain!)}',
        if (parts.sessionLogs != null) 'session logs ${_onOff(parts.sessionLogs!)}',
        if (parts.watched != null) 'watched ${_onOff(parts.watched!)}',
        if (parts.unwatchedAway != null)
          parts.unwatchedAway! ? 'everyone with the service away' : 'owners alone with the service away',
        if (parts.offlineHours != null)
          parts.offlineHours == 0 ? 'no offline limit' : 'offline limit ${parts.offlineHours} h',
        if (allowsNothingWithWatching) '(allows nothing with it)',
      ].join(' ');
}

/// A role is added, below every other.
final class AddRole extends SetupStep {
  const AddRole({required this.name, required this.can, required this.crates});

  final String name;
  final Set<String> can;

  /// Crate name to switches.
  final Map<String, Set<String>> crates;

  @override
  bool get needsRecentSignIn => true;

  @override
  String toString() => 'add role $name: can ${_words(can)}; ${_crateWords(crates)}';
}

/// A role changes: what it may do in the Orchard, what it gives in Crates,
/// or both; whichever does not differ is null.
final class ChangeRole extends SetupStep {
  const ChangeRole({required this.roleId, required this.name, this.can, this.crates});

  final String roleId;
  final String name;
  final Set<String>? can;

  /// Crate name to switches: all the role gives after the change.
  final Map<String, Set<String>>? crates;

  @override
  bool get needsRecentSignIn => true;

  @override
  String toString() => [
        'role $name:',
        if (can != null) 'can ${_words(can!)}',
        if (crates != null) _crateWords(crates!),
      ].join(' ');
}

/// The roles the file names take its order among themselves
/// ([roleOrderFor]).
final class OrderRoles extends SetupStep {
  const OrderRoles({required this.order, required this.ids});

  /// Every role's name (its id, for one whose name cannot be read),
  /// highest first, as they stand after the step; and beside each its id
  /// where the Orchard has the role already (a role this file adds has
  /// none yet).
  final List<String> order;
  final List<String?> ids;

  @override
  bool get needsRecentSignIn => true;

  @override
  String toString() => 'order roles: ${order.join(' > ')}';
}

/// The Orchard's rules change: [parts] is what differs.
final class SetRules extends SetupStep {
  const SetRules({required this.parts, required this.rules});

  final SetupRules parts;

  /// The rules after the step.
  final RecordRules rules;

  @override
  bool get needsRecentSignIn => true;

  @override
  String toString() => 'rules: ${jsonEncode(parts.toJson())}';
}

/// What the team records about its members changes: [parts] is what
/// differs.
final class SetRecords extends SetupStep {
  const SetRecords({required this.parts, required this.tracking, required this.endsEventExport});

  final SetupRecords parts;

  /// What is recorded after the step.
  final RecordTracking tracking;

  /// Activity goes off while the team's events are sent on: sending
  /// them ends with it.
  final bool endsEventExport;

  @override
  bool get needsRecentSignIn => true;

  @override
  String toString() => 'records: ${jsonEncode(parts.toJson())}${endsEventExport ? ' (ends event export)' : ''}';
}

/// A member changes: their role, their extra Crates, when their access
/// ends; whichever does not differ is null.
final class ChangeMember extends SetupStep {
  const ChangeMember({
    required this.uid,
    required this.email,
    this.role,
    this.roleId,
    this.crates,
    this.until,
    this.dropsExtraCrates = false,
    this.dropsLimits = false,
  });

  final String uid;
  final String email;

  /// 'owner', 'admin' or a role's name, and that role's id where the
  /// Orchard has it already (a role this file adds has none yet).
  final String? role;
  final String? roleId;

  /// Crate name to switches: all their extra Crates after the change.
  final Map<String, Set<String>>? crates;

  /// Named as none, their access no longer ends.
  final Named<int?>? until;

  /// They become an owner or admin, who hold no extra Crates: the ones
  /// they had end with it.
  final bool dropsExtraCrates;

  /// They become an owner or admin, who have no limits: the
  /// record clears the ones they had in the same entry.
  final bool dropsLimits;

  @override
  bool get needsRecentSignIn => true;

  @override
  String toString() => [
        'member $email:',
        if (role != null) 'role $role',
        if (crates != null) 'extra ${_crateWords(crates!)}',
        if (until != null) until!.value == null ? 'no end' : 'until ${setupTime(until!.value!)}',
        if (dropsExtraCrates) '(extra crates end)',
        if (dropsLimits) '(limits end)',
      ].join(' ');
}

/// A member's limit in one Crate changes (vault access per member, design
/// 66): they are held to [switches] there at most, whatever their role and
/// extra Crates give (an empty set is No access, which takes the Crate away
/// from them); or, with [switches] null, the limit there is lifted and what
/// their role and extra Crates give counts again. Each Crate is a step of
/// its own, after what else changes of the member, as the member panel
/// writes them.
final class LimitMember extends SetupStep {
  const LimitMember({required this.uid, required this.email, required this.crate, this.crateId, this.switches});

  final String uid;
  final String email;

  /// The Crate's name, and its id where the Orchard has the Crate already
  /// (one this file adds has none yet, and is found by its name).
  final String crate;
  final String? crateId;

  final Set<String>? switches;

  @override
  bool get needsRecentSignIn => true;

  @override
  String toString() => switches == null
      ? 'member $email: no limit in $crate'
      : 'member $email: limit $crate=${jsonEncode(limitJson(switches!))}';
}

/// Someone is invited, or an invitation that waits is changed to this
/// offer.
final class Invite extends SetupStep {
  const Invite({
    required this.email,
    required this.role,
    this.roleId,
    required this.crates,
    this.until,
    required this.again,
  });

  final String email;
  final String role;
  final String? roleId;
  final Map<String, Set<String>> crates;
  final int? until;

  /// An invitation to that address is there already (with another offer,
  /// or run out): this replaces it, and no second email goes out while the
  /// first still stands.
  final bool again;

  @override
  bool get needsRecentSignIn => false;

  @override
  String toString() => [
        again ? 'invite again' : 'invite',
        '$email as $role',
        if (crates.isNotEmpty) 'extra ${_crateWords(crates)}',
        if (until != null) 'until ${setupTime(until!)}',
      ].join(' ');
}

/// A group of hosts is added in a Crate.
final class AddGroup extends SetupStep {
  const AddGroup({required this.crate, required this.name});

  final String crate;
  final String name;

  @override
  bool get needsRecentSignIn => false;

  @override
  String toString() => 'add group $name in $crate';
}

/// A host is added in a Crate.
final class AddHost extends SetupStep {
  const AddHost({
    required this.crate,
    required this.name,
    required this.address,
    required this.port,
    required this.protocol,
    this.key,
    this.keyId,
    this.accounts = const [],
    this.accountIds = const [],
    this.group,
    this.tags = const {},
  });

  final String crate;
  final String name;
  final String address;
  final int port;

  /// As a file says it (one of [kSetupProtocols]); stored as
  /// [setupStoredProtocol] makes it.
  final String protocol;

  /// The key it signs in with, by name, and that key's id.
  final String? key;
  final String? keyId;

  /// Its other accounts by name, and their keys' ids, in their order.
  final List<String> accounts;
  final List<String> accountIds;

  /// The group it is shown in, by name (in [crate], or the one group of
  /// that name in the Orchard; added first when there is none).
  final String? group;
  final Set<String> tags;

  @override
  bool get needsRecentSignIn => false;

  @override
  String toString() => [
        'add host $name in $crate: $protocol $address:$port',
        if (key != null) 'key $key',
        if (accounts.isNotEmpty) 'accounts ${accounts.join('+')}',
        if (group != null) 'group $group',
        if (tags.isNotEmpty) 'tags ${_words(tags)}',
      ].join(' ');
}

/// A host changes; whatever does not differ is null.
final class ChangeHost extends SetupStep {
  const ChangeHost({
    required this.crate,
    required this.hostId,
    required this.name,
    this.address,
    this.port,
    this.protocol,
    this.key,
    this.keyId,
    this.accounts,
    this.accountIds,
    this.group,
    this.tags,
  });

  final String crate;
  final String hostId;
  final String name;
  final String? address;
  final int? port;

  /// As a file says it, like [AddHost.protocol].
  final String? protocol;

  /// Named as none, it no longer has a key (it asks when connecting).
  final Named<String?>? key;
  final String? keyId;

  /// Its other accounts by name, and their keys' ids, in their order;
  /// empty, it has none.
  final List<String>? accounts;
  final List<String>? accountIds;

  /// Named as none, it is in no group.
  final Named<String?>? group;
  final Set<String>? tags;

  @override
  bool get needsRecentSignIn => false;

  @override
  String toString() => [
        'host $name in $crate:',
        if (address != null) 'address $address',
        if (port != null) 'port $port',
        if (protocol != null) 'protocol $protocol',
        if (key != null) key!.value == null ? 'no key' : 'key ${key!.value}',
        if (accounts != null) accounts!.isEmpty ? 'no accounts' : 'accounts ${accounts!.join('+')}',
        if (group != null) group!.value == null ? 'no group' : 'group ${group!.value}',
        if (tags != null) 'tags ${_words(tags!)}',
      ].join(' ');
}

String _onOff(bool on) => on ? 'on' : 'off';

String _words(Set<String> words) => words.isEmpty ? 'nothing' : (words.toList()..sort()).join('+');

String _crateWords(Map<String, Set<String>> crates) => crates.isEmpty
    ? 'no crates'
    : [for (final c in crates.entries) '${c.key}=${jsonEncode(switchesJson(c.value))}'].join(' ');

/// What stands in the way of a file.
enum SetupProblemKind {
  /// The file is for the Orchard [SetupProblem.subject]; this one is
  /// [SetupProblem.other].
  otherOrchard,

  /// More than one Crate here is called that: which one is meant?
  ambiguousCrate,

  /// No Crate here is called that as far as this account can read, and it
  /// cannot open [SetupProblem.count] Crates: one of them may be the one.
  crateMayExist,

  /// A Crate is owners-only from when it is added, or never.
  cannotCloseCrate,

  /// An Orchard holds [SetupProblem.count] Crates at most.
  tooManyCrates,

  /// [SetupProblem.other] (a role or a member) names a Crate the Orchard
  /// does not have and the file does not add.
  noSuchCrate,

  /// More than one role here is called that.
  ambiguousRole,

  /// No role here is called that as far as this device can read, and it
  /// cannot read [SetupProblem.count] roles' names.
  roleMayExist,

  /// An Orchard holds [SetupProblem.count] roles at most.
  tooManyRoles,

  /// The member [SetupProblem.other] is given a role the Orchard does not
  /// have and the file does not add.
  noSuchRole,

  /// More than one host in the Crate [SetupProblem.other] is called that.
  ambiguousHost,

  /// A host that is not there yet needs an address.
  hostNeedsAddress,

  /// The host [SetupProblem.subject] in the Crate [SetupProblem.other] is
  /// FTPS (3.4), and the file gives it another protocol: a team's host never
  /// turns from FTPS into another kind, or back
  /// (AppDatabase.createOrchardTriggers).
  ftpsHost,

  /// The host [SetupProblem.subject] in the Crate [SetupProblem.other] is
  /// not FTPS, and the file makes it FTPS (3.4.1), which [ftpsHost] says of
  /// the other way.
  notFtpsHost,

  /// The host [SetupProblem.subject] in the Crate [SetupProblem.other] is a
  /// remote screen (4.0, VNC), which a setup file does not hold yet: the file
  /// may not change it, nor make it another kind of host.
  screenHost,

  /// This account may not add hosts to that Crate.
  cannotAddHosts,

  /// This account may not change hosts in that Crate.
  cannotEditHosts,

  /// The host [SetupProblem.other] names a key this device does not have.
  noSuchKey,

  /// More than one key is called that.
  ambiguousKey,

  /// The key is in a watched Crate, and the host [SetupProblem.other] is
  /// in another: such a key signs in only to its own Crate's hosts.
  watchedKeyElsewhere,

  /// More than one group is called that.
  ambiguousGroup,

  /// The file would change the membership of the account that applies it.
  ownMembership,

  /// Someone is made an owner or admin, and this device's person has not
  /// compared their keys.
  compareFirst,

  /// Access would end at a time that has passed.
  untilPassed,

  /// Access would end further ahead than an end date may be.
  untilTooFar,

  /// Someone outside the Orchard's domains would have no end date: the server
  /// refuses it, or it holds them back.
  guestNeedsEnd,

  /// Only owners invite someone from outside the domains the Orchard proved, or
  /// move the end date of someone outside its domains: the server refuses
  /// anyone else.
  guestOwnersOnly,

  /// Someone the file names is not a member, and this account cannot
  /// invite (or see who is invited).
  cannotInvite,

  /// Someone who is not a member yet is named without a role.
  inviteNeedsRole,

  /// Their address is outside the Orchard's domains: they could never
  /// join.
  inviteeOutsideDomains,

  /// Someone who is not a member yet is named with limits: a
  /// limit is a member's, and an invitation carries none, so what the file
  /// holds them to could not be set when they join.
  limitsNeedMember,

  /// The address domains leave out this account's own
  /// ([SetupProblem.subject]): it would hold itself back.
  rulesLeaveYouOut,

  /// Someone who would gain a key has keys this device does not trust yet
  /// (a change of them it has not seen compared).
  keysNotTrusted,

  /// The step writes a kind of team record entry that ZestSSH Cloud does
  /// not take yet (a member's limit): it waits until the version
  /// that reads it is out on every platform. The record itself would take
  /// it.
  notYet,

  /// The Orchard's record refuses the step ([SetupProblem.reason], in the
  /// record's own words).
  refused,
}

class SetupProblem {
  const SetupProblem(this.kind, {this.subject, this.other, this.count, this.reason, this.step});

  final SetupProblemKind kind;

  /// What it is about: a name, an address.
  final String? subject;
  final String? other;
  final int? count;
  final String? reason;

  /// The step it stands in the way of, where it is one.
  final SetupStep? step;

  @override
  String toString() => [
        kind.name,
        if (subject != null) subject,
        if (other != null) '[$other]',
        if (count != null) '$count',
        if (reason != null) '($reason)',
        if (step != null) '<$step>',
      ].join(' ');
}

/// What a file leaves alone, or what a person should know before applying.
enum SetupNoteKind {
  /// A Crate, a role, a member or an invitation the Orchard has and the
  /// file does not name: left as it is.
  crateNotInFile,
  roleNotInFile,
  memberNotInFile,
  invitationNotInFile,

  /// [SetupNote.names]: hosts of the Crate [SetupNote.subject] the file
  /// does not name.
  hostsNotInFile,

  /// [SetupNote.count] Crates this account cannot open were not compared.
  cratesClosed,

  /// Already invited with this very offer; nothing to do until they accept.
  invited,

  /// They accepted: someone compares their keys and confirms them.
  acceptedWaiting,

  /// More invitations than ZestSSH Cloud takes from one account in an
  /// hour ([SetupNote.count] of them): the rest go with a later run.
  manyInvitations,

  /// This device does not meet the rules the file sets (its app lock): the
  /// Orchard stops syncing here until it does.
  thisDeviceRules,

  /// [SetupNote.names]: members the address domains the file sets leave out,
  /// held back once it is applied.
  outsideDomains,

  /// [SetupNote.names]: members they leave out who stay in on an end date no
  /// owner gave.
  outsideDomainsUnseen,

  /// ZestSSH Cloud could not be reached: this is the Orchard as this
  /// device last saw it.
  notReached,
}

class SetupNote {
  const SetupNote(this.kind, {this.subject, this.count, this.names = const []});

  final SetupNoteKind kind;
  final String? subject;
  final int? count;
  final List<String> names;

  @override
  String toString() => [
        kind.name,
        if (subject != null) subject,
        if (count != null) '$count',
        if (names.isNotEmpty) names.join(','),
      ].join(' ');
}

/// What ZestSSH Cloud takes of invitations from one account in an hour.
const int kInvitationsPerHour = 30;

/// See the top of this file.
class SetupPlan {
  const SetupPlan({
    required this.steps,
    required this.problems,
    required this.notes,
    required this.after,
    this.added = const {},
  });

  final List<SetupStep> steps;
  final List<SetupProblem> problems;
  final List<SetupNote> notes;

  /// The record as the rehearsal left it: with every step the record took.
  final OrchardRecord after;

  /// The Crates and roles the steps add, by the id each has in [after]
  /// (one made up for the rehearsal; the real one comes when it is made),
  /// with its name.
  final Map<String, String> added;

  /// Nothing stands in the way.
  bool get canApply => problems.isEmpty;

  /// The Orchard is what the file says already.
  bool get nothingToDo => steps.isEmpty && problems.isEmpty;

  bool get needsRecentSignIn => steps.any((s) => s.needsRecentSignIn);

  /// Whether a step writes a kind of team record entry that older versions
  /// cannot read (a member's limit). The first of them in a team
  /// is an owner's, after the question of what older versions do then,
  /// which only the app asks.
  bool get writesNewKinds => steps.any((s) => s is LimitMember);
}

/// What [file] would change in the Orchard [now]. See the top of this file.
Future<SetupPlan> planSetup(SetupFile file, OrchardSnapshot now) async {
  final planner = _Planner(file, now);
  await planner.run();
  return SetupPlan(
    steps: planner.steps,
    problems: planner.problems,
    notes: planner.notes,
    after: planner.state,
    added: planner.added,
  );
}

/// Why [by] may not offer [role] with the extra Crates [grants] until
/// [endsAt] under [record], in the record's words, or null: the rules an
/// invitation's member.add will meet when someone confirms it, the keys
/// aside. ZestSSH Cloud checks every invitation the same way (offerProblem
/// in its orchard_record.js).
String? offerProblem(OrchardRecord record, String by, String role, Map<String, Set<String>> grants, int? endsAt) {
  final fixed = role == FixedRoles.owner || role == FixedRoles.admin;
  if (!fixed && !record.roles.containsKey(role)) return 'no such role';
  for (final id in grants.keys) {
    final crate = record.crates[id];
    if (crate == null || crate.ownersOnly) return 'no such Crate, or owners-only';
  }
  if (fixed) {
    if (!record.isOwner(by)) return 'only owners add owners and admins';
    if (grants.isNotEmpty) return 'owners and admins need no extra Crate';
  } else if (!record.can(by, RoleCan.invite) || record.rankOf(by) <= record.rankOfRole(role)) {
    return 'not allowed to add someone in that role';
  }
  if (role == FixedRoles.owner && endsAt != null) return 'owners do not end';
  const probeUid = '-offer-';
  final probe = record.copy();
  probe.members[probeUid] = RecordMember(
    uid: probeUid,
    role: role,
    keys: const {},
    since: record.seq + 1,
    grants: {for (final g in grants.entries) g.key: {...g.value}},
    endsAt: endsAt,
  );
  for (final c in probe.crates.keys) {
    if (!probe.switchesOf(by, c).containsAll(probe.switchesOf(probeUid, c))) return 'hands out more than they have';
  }
  return null;
}

/// The domain of an address, in small letters; empty when it has none.
String addressDomainOf(String? email) {
  final at = email?.lastIndexOf('@') ?? -1;
  return at < 0 ? '' : email!.substring(at + 1).trim().toLowerCase();
}

class _Planner {
  _Planner(this.file, this.now) : state = now.record.copy();

  final SetupFile file;
  final OrchardSnapshot now;

  /// The record as rehearsed so far.
  OrchardRecord state;

  final steps = <SetupStep>[];
  final problems = <SetupProblem>[];
  final notes = <SetupNote>[];

  /// The file changed the address domains (see [_noteOutsideDomains]).
  var _setDomains = false;

  String get me => now.me;

  /// Crates and roles by how their names are told apart: the ids of each
  /// name this account can read (more than one where a name is shared).
  final _crates = <String, List<String>>{};
  final _roles = <String, List<String>>{};

  /// Each Crate's and role's name as shown, by id.
  final _crateNames = <String, String>{};
  final _roleNames = <String, String>{};

  /// Names the file gives a Crate or a role that could not be added: what
  /// names them is passed over, the reason being said once already.
  final _blockedCrates = <String>{};
  final _blockedRoles = <String>{};

  /// The Crate ids the file's Crates turned out to be, by the file's name.
  final _fileCrates = <String, String>{};

  /// Groups this plan adds, by Crate id and name.
  final _newGroups = <String>{};

  /// What the plan adds, by the id made up for it, with its name.
  final added = <String, String>{};

  /// An id for the Crate or role called [name] that the plan adds: of the
  /// form the record takes, and replaced by a real one when the step is
  /// made.
  String _placeholder(String kind, String name) {
    final id = 'setup-$kind-${added.length + 1}';
    added[id] = name;
    return id;
  }

  static final _zeros32 = base64Encode(Uint8List(32));
  static final _zeros64 = base64Encode(Uint8List(64));

  void _problem(SetupProblemKind kind, {String? subject, String? other, int? count, String? reason, SetupStep? step}) =>
      problems.add(SetupProblem(kind, subject: subject, other: other, count: count, reason: reason, step: step));

  /// Appends [changes] to the rehearsed record as this account's entries,
  /// and keeps [step] when the record takes them all. A refusal is said
  /// with the step, the record stays as it was, and nothing is kept.
  Future<bool> _rehearse(SetupStep step, List<RecordChange> changes) async {
    final before = state;
    final next = state.copy();
    final version = next.members[me]?.currentKeys.version ?? 0;
    try {
      for (final c in changes) {
        await next.append(
          RecordEntry(
            seq: next.seq + 1,
            prev: next.head,
            type: c.type,
            bodyJson: canonicalJson(c.body),
            by: me,
            byKeyVersion: version,
            signature: Uint8List(64),
          ),
          trusted: true,
        );
      }
    } on RecordRejected catch (e) {
      _problem(SetupProblemKind.refused, reason: e.reason, step: step);
      return false;
    }
    // A kind of entry older versions cannot read: the record
    // takes it, and ZestSSH Cloud refuses it until it is turned on.
    if (!now.newKindsOn && changes.any((c) => RecordTypes.newKinds.contains(c.type))) {
      _problem(SetupProblemKind.notYet, step: step);
      return false;
    }
    // Whoever gains a key gets it sealed to their keys by this device: keys
    // it does not trust, it seals nothing to.
    var trusted = true;
    for (final uid in entitlementsGained(before, next, nowSeconds: now.now).keys) {
      if (uid == me) continue;
      final member = now.member(uid);
      if (member == null || !member.keysTrusted) {
        _problem(SetupProblemKind.keysNotTrusted, subject: member?.email ?? uid, step: step);
        trusted = false;
      }
    }
    if (!trusted) return false;
    state = next;
    steps.add(step);
    return true;
  }

  Future<void> run() async {
    final named = file.orchard;
    if (named != null && setupNameKey(named) != setupNameKey(now.name)) {
      _problem(SetupProblemKind.otherOrchard, subject: named, other: now.name);
      return;
    }
    if (!now.reached) notes.add(const SetupNote(SetupNoteKind.notReached));
    for (final c in now.crates) {
      final name = c.name;
      if (name == null) continue;
      _crates.putIfAbsent(setupNameKey(name), () => []).add(c.id);
      _crateNames[c.id] = name;
    }
    for (final r in now.roles) {
      final name = r.name;
      if (name == null) continue;
      _roles.putIfAbsent(setupNameKey(name), () => []).add(r.id);
      _roleNames[r.id] = name;
    }
    await _planCrates();
    await _planRoles();
    await _planRules();
    await _planRecords();
    await _planMembers();
    _noteOutsideDomains();
    _planHosts();
  }

  /// Who the server holds back under the address domains the file set, as
  /// the rest of the file leaves them: an end date the file gives counts, and
  /// makes a guest of them (domainRuleHolds). And who it lets in from outside
  /// them on an end date no owner gave: nobody who may decide has seen that.
  void _noteOutsideDomains() {
    if (!_setDomains) return;
    final domains = state.rules.emailDomains;
    if (domains.isEmpty) return;
    final held = <String>[];
    final unseen = <String>[];
    for (final m in now.members) {
      final member = state.members[m.uid];
      if (m.email == null || member == null || member.status != MemberStatus.active) continue;
      final email = m.email!.trim().toLowerCase();
      final ends = member.endsAt;
      if (domainRuleHolds(domains, m.email, endsAt: ends)) {
        held.add(email);
      } else if (ends != null && ends > now.now && !member.endsFromOwner && !domains.contains(addressDomain(m.email))) {
        unseen.add(email);
      }
    }
    if (held.isNotEmpty) notes.add(SetupNote(SetupNoteKind.outsideDomains, names: held..sort()));
    if (unseen.isNotEmpty) notes.add(SetupNote(SetupNoteKind.outsideDomainsUnseen, names: unseen..sort()));
  }

  // ── Crates ──

  Future<void> _planCrates() async {
    final crates = file.crates;
    if (crates == null) return;
    final closed = [
      for (final c in now.crates)
        if (!c.open) c,
    ];
    for (final fc in crates) {
      final key = setupNameKey(fc.name);
      final ids = _crates[key] ?? const [];
      if (ids.length > 1) {
        _problem(SetupProblemKind.ambiguousCrate, subject: fc.name);
        _blockedCrates.add(key);
        continue;
      }
      final String id;
      if (ids.length == 1) {
        id = ids.single;
        if (fc.ownersOnly == true && !state.crates[id]!.ownersOnly) {
          _problem(SetupProblemKind.cannotCloseCrate, subject: fc.name);
        }
      } else {
        final ownersOnly = fc.ownersOnly ?? false;
        // A Crate this account cannot open has a name it cannot read: one
        // of them may be the Crate the file means. (An owners-only Crate is
        // closed to everyone but owners, who open every Crate.)
        final maybe = closed.where((c) => (state.crates[c.id]?.ownersOnly ?? false) == ownersOnly).length;
        if (maybe > 0) {
          _problem(SetupProblemKind.crateMayExist, subject: fc.name, count: maybe);
          _blockedCrates.add(key);
          continue;
        }
        if (state.crates.length >= kSetupMaxCrates) {
          _problem(SetupProblemKind.tooManyCrates, subject: fc.name, count: kSetupMaxCrates);
          _blockedCrates.add(key);
          continue;
        }
        id = _placeholder('crate', fc.name);
        final took = await _rehearse(AddCrate(name: fc.name, ownersOnly: ownersOnly), [
          (
            type: RecordTypes.crateAdd,
            body: {
              'id': id,
              'owners_only': ownersOnly,
              'allow': switchList(kDefaultCrateAllow),
              'key_commit': _zeros32,
            },
          ),
        ]);
        if (!took) {
          added.remove(id);
          _blockedCrates.add(key);
          continue;
        }
        _crates[key] = [id];
        _crateNames[id] = fc.name;
      }
      _fileCrates[key] = id;
      final crate = state.crates[id]!;
      final parts = CrateParts(
        open: fc.ownersOnly == false && crate.ownersOnly,
        allow: fc.allow != null && !_sameSet(fc.allow!, crate.allow) ? fc.allow : null,
        askAgain: fc.askAgain != null && fc.askAgain != crate.confirmReveal ? fc.askAgain : null,
        sessionLogs: fc.sessionLogs != null && fc.sessionLogs != crate.sessionLogs ? fc.sessionLogs : null,
        watched: fc.watched != null && fc.watched != crate.watched ? fc.watched : null,
        unwatchedAway:
            fc.unwatchedAway != null && fc.unwatchedAway != crate.unwatchedAway ? fc.unwatchedAway : null,
        offlineHours: fc.offlineHours != null && fc.offlineHours != crate.offlineHours ? fc.offlineHours : null,
      );
      final changes = crateSettingsChange(state, id, parts);
      if (changes.isEmpty) continue;
      await _rehearse(
        CrateSettings(
          crate: _crateNames[id]!,
          parts: parts,
          allowsNothingWithWatching: parts.allow == null && changes.single.body.containsKey('allow'),
        ),
        changes,
      );
    }
    final inFile = {for (final fc in crates) setupNameKey(fc.name)};
    for (final c in now.crates) {
      final name = c.name;
      if (name != null && !inFile.contains(setupNameKey(name))) {
        notes.add(SetupNote(SetupNoteKind.crateNotInFile, subject: name));
      }
    }
    if (closed.isNotEmpty) notes.add(SetupNote(SetupNoteKind.cratesClosed, count: closed.length));
  }

  /// The id of the Crate called [name], for [where] (the role or member
  /// that names it); null when there is none to tell, which is said (once,
  /// where the Crate itself could not be added).
  String? _crateFor(String name, String where) {
    final key = setupNameKey(name);
    if (_blockedCrates.contains(key)) return null;
    final ids = _crates[key] ?? const [];
    if (ids.length == 1) return ids.single;
    _problem(ids.isEmpty ? SetupProblemKind.noSuchCrate : SetupProblemKind.ambiguousCrate,
        subject: name, other: where);
    return null;
  }

  /// [named] (Crate name to switches) by Crate id; null when one of its
  /// Crates could not be told.
  Map<String, Set<String>>? _byCrateId(Map<String, Set<String>> named, String where) {
    final out = <String, Set<String>>{};
    var ok = true;
    for (final e in named.entries) {
      final id = _crateFor(e.key, where);
      if (id == null) {
        ok = false;
      } else {
        out[id] = e.value;
      }
    }
    return ok ? out : null;
  }

  /// [byId] (Crate id to switches) under the names its Crates are shown by.
  Map<String, Set<String>> _byCrateName(Map<String, Set<String>> byId) =>
      {for (final e in byId.entries) _crateNames[e.key] ?? e.key: e.value};

  // ── Roles ──

  Future<void> _planRoles() async {
    final roles = file.roles;
    if (roles == null) return;
    final unread = now.roles.where((r) => r.name == null).length;
    final inOrder = <String>[];
    for (final fr in roles) {
      final key = setupNameKey(fr.name);
      final ids = _roles[key] ?? const [];
      if (ids.length > 1) {
        _problem(SetupProblemKind.ambiguousRole, subject: fr.name);
        _blockedRoles.add(key);
        continue;
      }
      final crates = fr.crates == null ? null : _byCrateId(fr.crates!, fr.name);
      if (ids.length == 1) {
        final id = ids.single;
        inOrder.add(id);
        if (fr.crates != null && crates == null) continue;
        final role = state.roles[id]!;
        final can = fr.can != null && !_sameSet(fr.can!, role.can) ? fr.can : null;
        final gives = crates != null && !_sameCrates(crates, role.crates) ? crates : null;
        final changes = rolePartsChange(state, id, can: can, crates: gives);
        if (changes.isEmpty) continue;
        await _rehearse(
          ChangeRole(roleId: id, name: _roleNames[id]!, can: can, crates: gives == null ? null : _byCrateName(gives)),
          changes,
        );
        continue;
      }
      if (unread > 0) {
        _problem(SetupProblemKind.roleMayExist, subject: fr.name, count: unread);
        _blockedRoles.add(key);
        continue;
      }
      if (state.roles.length >= kMaxOrchardRoles) {
        _problem(SetupProblemKind.tooManyRoles, subject: fr.name, count: kMaxOrchardRoles);
        _blockedRoles.add(key);
        continue;
      }
      if (fr.crates != null && crates == null) {
        _blockedRoles.add(key);
        continue;
      }
      final id = _placeholder('role', fr.name);
      final can = fr.can ?? const <String>{};
      final gives = crates ?? const <String, Set<String>>{};
      Map<String, Object?> body(int rank) => {
            'id': id,
            'rank': rank,
            'name_enc': 'setup',
            'name_gen': state.generationOf(kOrchardScope),
            'can': switchList(can),
            'crates': {for (final c in gives.entries) c.key: switchList(c.value)},
          };
      final took = await _rehearse(
        AddRole(name: fr.name, can: can, crates: _byCrateName(gives)),
        reorderRoles(state, [...rolesHighestFirst(state), id], id, body),
      );
      if (!took) {
        added.remove(id);
        _blockedRoles.add(key);
        continue;
      }
      _roles[key] = [id];
      _roleNames[id] = fr.name;
      inOrder.add(id);
    }
    final order = roleOrderFor(rolesHighestFirst(state), inOrder, added.keys.toSet());
    final changes = roleOrderChange(state, order);
    if (changes.isNotEmpty) {
      await _rehearse(
        OrderRoles(
          order: [for (final id in order) _roleNames[id] ?? id],
          ids: [for (final id in order) _knownRoleId(id)],
        ),
        changes,
      );
    }
    final inFile = {for (final fr in roles) setupNameKey(fr.name)};
    for (final r in now.roles) {
      final name = r.name;
      if (name != null && !inFile.contains(setupNameKey(name))) {
        notes.add(SetupNote(SetupNoteKind.roleNotInFile, subject: name));
      }
    }
  }

  /// The role a member's [named] role is ('owner', 'admin' or a role's
  /// id); null when there is none to tell, which is said.
  String? _roleFor(String named, String email) {
    if (named == FixedRoles.owner || named == FixedRoles.admin) return named;
    final key = setupNameKey(named);
    if (_blockedRoles.contains(key)) return null;
    final ids = _roles[key] ?? const [];
    if (ids.length == 1) return ids.single;
    _problem(ids.isEmpty ? SetupProblemKind.noSuchRole : SetupProblemKind.ambiguousRole, subject: named, other: email);
    return null;
  }

  /// A role's name as shown: the Orchard's own two as they are written.
  String _roleName(String role) => _roleNames[role] ?? role;

  /// A role's id as a step carries it: the Orchard's own two as they are
  /// written, a role the Orchard has by its id, and none for a role this
  /// plan adds (it gets its id when it is made, and is found by its name).
  String? _knownRoleId(String role) => role.startsWith('setup-') ? null : role;

  // ── Rules and what the team records ──

  Future<void> _planRules() async {
    final named = file.rules;
    if (named == null) return;
    final rules = state.rules;
    // Sign in again is one rule in days or hours: what a file names of it
    // replaces both, the one left out at 0 (SetupRules.over), and the step
    // names what it sets.
    final reauthDays = named.reauthDays ?? 0;
    final reauthHours = named.reauthHours ?? 0;
    final reauthChanged = (named.reauthDays != null || named.reauthHours != null) &&
        (reauthDays != rules.reauthDays || reauthHours != rules.reauthHours);
    final parts = SetupRules(
      require2fa: named.require2fa != null && named.require2fa != rules.require2fa ? named.require2fa : null,
      emailDomains: named.emailDomains != null && !_sameSet(named.emailDomains!, rules.emailDomains)
          ? named.emailDomains
          : null,
      requireAppLock:
          named.requireAppLock != null && named.requireAppLock != rules.requireAppLock ? named.requireAppLock : null,
      maxLockMinutes:
          named.maxLockMinutes != null && named.maxLockMinutes != rules.maxLockMinutes ? named.maxLockMinutes : null,
      noExport: named.noExport != null && named.noExport != rules.noExport ? named.noExport : null,
      offlineHours: named.offlineHours != null && named.offlineHours != rules.offlineHours ? named.offlineHours : null,
      reauthDays: reauthChanged && (reauthDays > 0 || reauthHours == 0) ? reauthDays : null,
      reauthHours: reauthChanged && reauthHours > 0 ? reauthHours : null,
      requireSso: named.requireSso != null && named.requireSso != rules.requireSso ? named.requireSso : null,
      trustedDevices:
          named.trustedDevices != null && named.trustedDevices != rules.trustedDevices ? named.trustedDevices : null,
      screensSshOnly:
          named.screensSshOnly != null && named.screensSshOnly != rules.screensSshOnly ? named.screensSshOnly : null,
      screensLockRedirections:
          named.screensLockRedirections != null && named.screensLockRedirections != rules.screensLockRedirections
              ? named.screensLockRedirections
              : null,
    );
    final changes = rulesPartsChange(state, parts);
    if (changes.isEmpty) return;
    final next = parts.over(rules);
    final step = SetRules(parts: parts, rules: next);
    // Their own address must be allowed, or they would hold themselves back.
    final mine = addressDomainOf(now.myEmail);
    if (parts.emailDomains != null && next.emailDomains.isNotEmpty && !next.emailDomains.contains(mine)) {
      _problem(SetupProblemKind.rulesLeaveYouOut, subject: mine.isEmpty ? null : mine, step: step);
      return;
    }
    if (!await _rehearse(step, changes)) return;
    _setDomains = parts.emailDomains != null;
    final lockOn = now.lockOn;
    if (lockOn != null && deviceUnmet(next, lockOn: lockOn, lockMinutes: now.lockMinutes ?? 0).isNotEmpty) {
      notes.add(const SetupNote(SetupNoteKind.thisDeviceRules));
    }
  }

  Future<void> _planRecords() async {
    final named = file.records;
    if (named == null) return;
    final tracking = state.tracking;
    final parts = SetupRecords(
      history: named.history != null && named.history != tracking.history ? named.history : null,
      activity: named.activity != null && named.activity != tracking.activity ? named.activity : null,
      devices: named.devices != null && named.devices != tracking.devices ? named.devices : null,
      ips: named.ips != null && named.ips != tracking.ips ? named.ips : null,
    );
    final changes = recordsPartsChange(state, parts);
    if (changes.isEmpty) return;
    await _rehearse(
      SetRecords(
        parts: parts,
        tracking: parts.over(tracking),
        endsEventExport: state.eventExport != null && parts.activity == false,
      ),
      changes,
    );
  }

  // ── Members ──

  Future<void> _planMembers() async {
    final members = file.members;
    if (members == null) return;
    final byEmail = <String, String>{
      for (final m in now.members)
        if (m.email != null) m.email!.trim().toLowerCase(): m.uid,
    };
    final invites = now.invites;
    var invitations = 0;
    for (final fm in members) {
      final role = fm.role == null ? null : _roleFor(fm.role!, fm.email);
      final grants = fm.crates == null ? null : _byCrateId(fm.crates!, fm.email);
      final limits = fm.limits == null ? null : _byCrateId(fm.limits!, fm.email);
      if ((fm.role != null && role == null) ||
          (fm.crates != null && grants == null) ||
          (fm.limits != null && limits == null)) {
        continue;
      }
      final until = fm.until;
      final uid = byEmail[fm.email];
      final member = uid == null ? null : state.members[uid];
      if (uid != null && member != null && member.status != MemberStatus.removed) {
        final newRole = role != null && role != member.role ? role : null;
        final newGrants = grants != null && !_sameCrates(grants, member.grants) ? grants : null;
        final newUntil = until != null && until.value != member.endsAt ? until : null;
        final body = memberPartsBody(state, uid, role: newRole, grants: newGrants, endsAt: newUntil);
        final limitsDiffer = limits != null && !_sameCrates(limits, member.limits);
        if (body == null && !limitsDiffer) continue;
        if (uid == me) {
          _problem(SetupProblemKind.ownMembership, subject: fm.email);
          continue;
        }
        if (body != null) {
          final ends = newUntil?.value;
          if (ends != null && ends <= now.now) {
            _problem(SetupProblemKind.untilPassed, subject: fm.email);
            continue;
          }
          if (memberEndTooFar(ends, now.now)) {
            _problem(SetupProblemKind.untilTooFar, subject: fm.email);
            continue;
          }
          if (newUntil != null && !state.isOwner(me) && _outsideDomains(fm.email)) {
            _problem(SetupProblemKind.guestOwnersOnly, subject: fm.email);
            continue;
          }
          if (newUntil != null && ends == null && _outsideDomains(fm.email)) {
            _problem(SetupProblemKind.guestNeedsEnd, subject: fm.email);
            continue;
          }
          final makes = makesOwnerOrAdmin(member.role, newRole ?? member.role);
          final step = ChangeMember(
            uid: uid,
            email: fm.email,
            role: newRole == null ? null : _roleName(newRole),
            roleId: newRole == null ? null : _knownRoleId(newRole),
            crates: newGrants == null ? null : _byCrateName(newGrants),
            until: newUntil,
            dropsExtraCrates: newGrants == null && body.containsKey('grants'),
            dropsLimits: makes && member.limits.isNotEmpty,
          );
          if (makes && !(now.member(uid)?.compared ?? false)) {
            _problem(SetupProblemKind.compareFirst, subject: fm.email, step: step);
            continue;
          }
          // Their limits are judged with the rest of them as the file means
          // it: where that is not taken, neither are they.
          final took = await _rehearse(step, [
            (type: RecordTypes.memberSet, body: makes ? {...body, 'verified': _zeros64} : body),
          ]);
          if (!took) continue;
        }
        if (limits != null) await _planLimits(uid, fm.email, limits);
        continue;
      }
      // Not a member: an invitation.
      if (invites == null || !state.can(me, RoleCan.invite)) {
        _problem(SetupProblemKind.cannotInvite, subject: fm.email);
        continue;
      }
      if (role == null) {
        _problem(SetupProblemKind.inviteNeedsRole, subject: fm.email);
        continue;
      }
      // An invitation carries no limits, and whoever joins on it would have
      // all their role gives until the file was applied again: not made.
      if (limits != null && limits.isNotEmpty) {
        _problem(SetupProblemKind.limitsNeedMember, subject: fm.email);
        continue;
      }
      final ends = until?.value;
      if (ends != null && ends <= now.now) {
        _problem(SetupProblemKind.untilPassed, subject: fm.email);
        continue;
      }
      if (memberEndTooFar(ends, now.now)) {
        _problem(SetupProblemKind.untilTooFar, subject: fm.email);
        continue;
      }
      if (now.provenDomains.isNotEmpty && !now.provenDomains.contains(addressDomainOf(fm.email))) {
        if (!state.isOwner(me)) {
          _problem(SetupProblemKind.guestOwnersOnly, subject: fm.email);
          continue;
        }
        if (ends == null) {
          _problem(SetupProblemKind.guestNeedsEnd, subject: fm.email);
          continue;
        }
      }
      final offered = grants ?? const <String, Set<String>>{};
      final step = Invite(
        email: fm.email,
        role: _roleName(role),
        roleId: _knownRoleId(role),
        crates: _byCrateName(offered),
        until: ends,
        again: invites.any((i) => i.email.trim().toLowerCase() == fm.email),
      );
      final refused = offerProblem(state, me, role, offered, ends);
      if (refused != null) {
        _problem(SetupProblemKind.refused, reason: refused, step: step);
        continue;
      }
      final domains = state.rules.emailDomains;
      if (domains.isNotEmpty && !domains.contains(addressDomainOf(fm.email))) {
        _problem(SetupProblemKind.inviteeOutsideDomains, subject: fm.email, step: step);
        continue;
      }
      final waiting = invites.where((i) => i.email.trim().toLowerCase() == fm.email).firstOrNull;
      if (waiting != null &&
          !waiting.expired &&
          waiting.role == role &&
          _sameCrates(waiting.grants, offered) &&
          waiting.endsAt == ends) {
        notes.add(SetupNote(waiting.accepted ? SetupNoteKind.acceptedWaiting : SetupNoteKind.invited,
            subject: fm.email));
        continue;
      }
      steps.add(step);
      invitations++;
    }
    if (invitations > kInvitationsPerHour) {
      notes.add(SetupNote(SetupNoteKind.manyInvitations, count: invitations));
    }
    final inFile = {for (final fm in members) fm.email};
    for (final m in now.members) {
      final email = m.email?.trim().toLowerCase();
      if (email != null && !inFile.contains(email)) {
        notes.add(SetupNote(SetupNoteKind.memberNotInFile, subject: email));
      }
    }
    for (final i in invites ?? const <SnapshotInvite>[]) {
      final email = i.email.trim().toLowerCase();
      if (!inFile.contains(email) && !i.expired) {
        notes.add(SetupNote(SetupNoteKind.invitationNotInFile, subject: email));
      }
    }
  }

  /// Whether [email] is outside the domains the rules allow, as the file leaves
  /// them, or the domains the Orchard proved.
  bool _outsideDomains(String email) {
    final domain = addressDomainOf(email);
    final ruled = state.rules.emailDomains;
    return (ruled.isNotEmpty && !ruled.contains(domain)) ||
        (now.provenDomains.isNotEmpty && !now.provenDomains.contains(domain));
  }

  /// The member [uid]'s limits made what [named] (Crate id to switches) says
  /// of all of them, as the rehearsed record stands after the
  /// rest of their change (one that made them an owner or admin cleared
  /// theirs): a step for each Crate whose limit differs, in the file's
  /// order, then one for each limit the file leaves out, which is lifted.
  /// The record says which it takes: never one for an owner or admin, nor
  /// in an owners-only Crate.
  Future<void> _planLimits(String uid, String email, Map<String, Set<String>> named) async {
    final had = {...state.members[uid]!.limits};
    final changes = <String, Set<String>?>{
      for (final e in named.entries)
        if (had[e.key] == null || !_sameSet(had[e.key]!, e.value)) e.key: e.value,
      for (final id in had.keys)
        if (!named.containsKey(id)) id: null,
    };
    for (final c in changes.entries) {
      await _rehearse(
        LimitMember(
          uid: uid,
          email: email,
          crate: _crateNames[c.key] ?? c.key,
          crateId: added.containsKey(c.key) ? null : c.key,
          switches: c.value,
        ),
        memberLimitChange(state, uid, c.key, c.value),
      );
    }
  }

  // ── Hosts ──

  void _planHosts() {
    for (final fc in file.crates ?? const <SetupCrate>[]) {
      final hosts = fc.hosts;
      final crateId = _fileCrates[setupNameKey(fc.name)];
      if (hosts == null || crateId == null) continue;
      final crate = _crateNames[crateId]!;
      final mine = state.switchesAt(me, crateId, now.now);
      final here = <String, List<SnapshotHost>>{};
      for (final h in now.hosts) {
        if (h.crateId == crateId) here.putIfAbsent(setupNameKey(h.name), () => []).add(h);
      }
      var saidAdd = false, saidEdit = false;
      bool may(String what) {
        if (mine.contains(what)) return true;
        if (what == CrateSwitches.add && !saidAdd) {
          saidAdd = true;
          _problem(SetupProblemKind.cannotAddHosts, subject: crate);
        }
        if (what == CrateSwitches.edit && !saidEdit) {
          saidEdit = true;
          _problem(SetupProblemKind.cannotEditHosts, subject: crate);
        }
        return false;
      }

      for (final fh in hosts) {
        final found = here[setupNameKey(fh.name)] ?? const [];
        if (found.length > 1) {
          _problem(SetupProblemKind.ambiguousHost, subject: fh.name, other: crate);
          continue;
        }
        // The key and the group it names, where it names them.
        String? keyId;
        final keyName = fh.key?.value;
        if (keyName != null) {
          final key = _named(now.keys, keyName, crateId, SetupProblemKind.ambiguousKey, fh.name);
          if (key == null) continue;
          if (key.isEmpty) {
            _problem(SetupProblemKind.noSuchKey, subject: keyName, other: fh.name);
            continue;
          }
          final keyCrate = key.single.crateId;
          if (keyCrate != crateId && (state.crates[keyCrate]?.watched ?? false)) {
            _problem(SetupProblemKind.watchedKeyElsewhere, subject: keyName, other: fh.name);
            continue;
          }
          keyId = key.single.id;
        }
        // Its other accounts (3.0, accounts per host): each a key's name,
        // found as its key is; the host's own key is no other account.
        List<String>? accountIds;
        List<String>? accountNames;
        final named = fh.accounts;
        if (named != null) {
          final defaultId = fh.key != null ? keyId : (found.length == 1 ? found.single.keyId : null);
          final ids = <String>[], names = <String>[];
          var known = true;
          for (final accountName in named) {
            final account = _named(now.keys, accountName, crateId, SetupProblemKind.ambiguousKey, fh.name);
            if (account == null) {
              known = false;
              break;
            }
            if (account.isEmpty) {
              _problem(SetupProblemKind.noSuchKey, subject: accountName, other: fh.name);
              known = false;
              break;
            }
            final accountCrate = account.single.crateId;
            if (accountCrate != crateId && (state.crates[accountCrate]?.watched ?? false)) {
              _problem(SetupProblemKind.watchedKeyElsewhere, subject: accountName, other: fh.name);
              known = false;
              break;
            }
            final id = account.single.id;
            if (id == defaultId || ids.contains(id)) continue;
            ids.add(id);
            names.add(accountName);
          }
          if (!known) continue;
          accountIds = ids;
          accountNames = names;
        }
        String? groupId;
        var addGroup = false;
        final groupName = fh.group?.value;
        if (groupName != null) {
          final group = _named(now.groups, groupName, crateId, SetupProblemKind.ambiguousGroup, fh.name);
          if (group == null) continue;
          if (group.isEmpty) {
            addGroup = !_newGroups.contains('$crateId ${setupNameKey(groupName)}');
          } else {
            groupId = group.single.id;
          }
        }
        void groupFirst() {
          if (!addGroup) return;
          _newGroups.add('$crateId ${setupNameKey(groupName!)}');
          steps.add(AddGroup(crate: crate, name: groupName));
        }

        if (found.isEmpty) {
          final address = fh.address;
          if (address == null) {
            _problem(SetupProblemKind.hostNeedsAddress, subject: fh.name, other: crate);
            continue;
          }
          if (!may(CrateSwitches.add)) continue;
          groupFirst();
          steps.add(AddHost(
            crate: crate,
            name: fh.name,
            address: address,
            port: fh.port ?? setupDefaultPort(fh.protocol ?? 'ssh'),
            protocol: fh.protocol ?? 'ssh',
            key: keyName,
            keyId: keyId,
            accounts: accountNames ?? const [],
            accountIds: accountIds ?? const [],
            group: groupName,
            tags: fh.tags ?? const {},
          ));
          continue;
        }
        final h = found.single;
        // A remote screen (4.0) is not a setup file's to change: the file has
        // no word for one, and what it names would make it another kind.
        if (ConnectionProtocol.storedIsScreen(h.protocol)) {
          _problem(SetupProblemKind.screenHost, subject: h.name, other: crate);
          continue;
        }
        // A team's host stays FTPS, or stays another kind (3.4): a file that
        // names FTPS for an SSH host, or another protocol for an FTPS one,
        // would change its kind, which the team's database refuses. Between
        // explicit and implicit FTPS it may change.
        final protocol = fh.protocol == null ? null : setupStoredProtocol(fh.protocol!);
        if (protocol != null && ConnectionProtocol.storedIsFtps(h.protocol) != ConnectionProtocol.storedIsFtps(protocol)) {
          _problem(ConnectionProtocol.storedIsFtps(h.protocol) ? SetupProblemKind.ftpsHost : SetupProblemKind.notFtpsHost,
              subject: h.name, other: crate);
          continue;
        }
        final newGroup = fh.group != null && (groupName == null ? h.groupId != null : groupId == null || groupId != h.groupId);
        final step = ChangeHost(
          crate: crate,
          hostId: h.id,
          name: h.name,
          address: fh.address != null && fh.address != h.address ? fh.address : null,
          port: fh.port != null && fh.port != h.port ? fh.port : null,
          protocol: protocol != null && protocol != h.protocol ? fh.protocol : null,
          key: fh.key != null && keyId != h.keyId ? fh.key : null,
          keyId: fh.key != null && keyId != h.keyId ? keyId : null,
          accounts: accountIds != null && !_sameList(accountIds, h.accountIds) ? accountNames : null,
          accountIds: accountIds != null && !_sameList(accountIds, h.accountIds) ? accountIds : null,
          group: newGroup ? fh.group : null,
          tags: fh.tags != null && !_sameSet(fh.tags!, h.tags) ? fh.tags : null,
        );
        if (step.address == null &&
            step.port == null &&
            step.protocol == null &&
            step.key == null &&
            step.accounts == null &&
            step.group == null &&
            step.tags == null) {
          continue;
        }
        if (!may(CrateSwitches.edit)) continue;
        if (newGroup && addGroup && !may(CrateSwitches.add)) continue;
        if (newGroup) groupFirst();
        steps.add(step);
      }
      final inFile = {for (final fh in hosts) setupNameKey(fh.name)};
      final left = [
        for (final h in now.hosts)
          if (h.crateId == crateId && !inFile.contains(setupNameKey(h.name))) h.name,
      ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      if (left.isNotEmpty) notes.add(SetupNote(SetupNoteKind.hostsNotInFile, subject: crate, names: left));
    }
  }

  /// What is called [name] among [all] ([calledIn]): one, or none at all;
  /// null when more than one is called that where it was looked for, which
  /// is said (as [ambiguous], for the host [host]).
  List<SnapshotNamed>? _named(
      List<SnapshotNamed> all, String name, String crateId, SetupProblemKind ambiguous, String host) {
    final found = calledIn(all, name, crateId);
    if (found.length > 1) {
      _problem(ambiguous, subject: name, other: host);
      return null;
    }
    return found;
  }
}

/// What a host of the Crate [crateId] means by [name] among [all] (the
/// Orchard's keys, or its groups): what is called that in its own Crate,
/// and only where nothing there is, what is called that anywhere in the
/// Orchard. More than one is a name that does not tell.
List<SnapshotNamed> calledIn(List<SnapshotNamed> all, String name, String crateId) {
  final key = setupNameKey(name);
  final called = [
    for (final x in all)
      if (setupNameKey(x.name) == key) x,
  ];
  final here = [
    for (final x in called)
      if (x.crateId == crateId) x,
  ];
  return here.isNotEmpty ? here : called;
}

bool _sameSet(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

bool _sameCrates(Map<String, Set<String>> a, Map<String, Set<String>> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] != null && _sameSet(e.value, b[e.key]!));

/// Whether [a] and [b] hold the same, in the same order.
bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
