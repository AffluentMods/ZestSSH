import 'dart:ui' show Locale;

import 'package:intl/intl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/setup/setup_apply.dart';
import 'package:zestssh/features/orchards/setup/setup_export.dart';
import 'package:zestssh/features/orchards/setup/setup_file.dart';
import 'package:zestssh/features/orchards/setup/setup_plan.dart';
import 'package:zestssh/features/orchards/setup/setup_reader.dart';
import 'package:zestssh/features/orchards/setup/setup_words.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/l10n/time_text.dart';

// A setup file's plan in words (3.0): every step, everything that
// can stand in its way, everything it leaves alone, everything wrong with a
// file and everything an exported one leaves out, each said as itself; in
// every language; and with names masked where a screen shows them while it
// is recorded.

const _until = 1909069200; // 2030-06-30T17:00:00Z

/// One of each kind of step, with every detail it can have.
const _steps = <SetupStep>[
  AddCrate(name: 'Lab', ownersOnly: false),
  AddCrate(name: 'Vault', ownersOnly: true),
  CrateSettings(
    crate: 'Production',
    parts: CrateParts(
      open: true,
      allow: {CrateSwitches.agent, CrateSwitches.sftp, CrateSwitches.forward},
      askAgain: true,
      sessionLogs: false,
      watched: false,
    ),
    allowsNothingWithWatching: false,
  ),
  CrateSettings(
      crate: 'Staging',
      parts: CrateParts(watched: true, unwatchedAway: true, offlineHours: 24),
      allowsNothingWithWatching: true),
  CrateSettings(
      crate: 'Depot',
      parts: CrateParts(allow: {}, askAgain: false, sessionLogs: true, unwatchedAway: false, offlineHours: 0),
      allowsNothingWithWatching: false),
  AddRole(name: 'Operators', can: {RoleCan.invite, RoleCan.remove, RoleCan.changeRoles, RoleCan.createCrates}, crates: {
    'Production': {CrateSwitches.connect, CrateSwitches.sftp, CrateSwitches.forward, CrateSwitches.reveal},
    'Lab': {
      CrateSwitches.connect,
      CrateSwitches.sftp,
      CrateSwitches.forward,
      CrateSwitches.reveal,
      CrateSwitches.add,
      CrateSwitches.edit,
      CrateSwitches.delete,
      CrateSwitches.manage,
      CrateSwitches.agent,
    },
    'Depot': {CrateSwitches.connect, CrateSwitches.reveal},
  }),
  AddRole(name: 'Guests', can: {}, crates: {}),
  ChangeRole(roleId: 'r-1', name: 'Members', can: {RoleCan.invite}),
  ChangeRole(roleId: 'r-1', name: 'Members', crates: {
    'Production': {CrateSwitches.connect, CrateSwitches.sftp, CrateSwitches.forward},
  }),
  ChangeRole(roleId: 'r-1', name: 'Members', can: {}, crates: {}),
  OrderRoles(order: ['Operators', 'Members', 'Guests'], ids: [null, 'r-1', null]),
  SetRules(
    parts: SetupRules(
      require2fa: true,
      emailDomains: {'ops.northwind.example', 'northwind.example'},
      requireAppLock: true,
      maxLockMinutes: 15,
      noExport: false,
      offlineHours: 72,
      reauthDays: 30,
      requireSso: false,
      trustedDevices: true,
    ),
    rules: RecordRules.none,
  ),
  SetRules(
    parts: SetupRules(emailDomains: {}, maxLockMinutes: 0, offlineHours: 0, reauthDays: 0),
    rules: RecordRules.none,
  ),
  SetRules(parts: SetupRules(maxLockMinutes: 120, offlineHours: 5), rules: RecordRules.none),
  SetRecords(
    parts: SetupRecords(history: true, activity: false, devices: true, ips: false),
    tracking: RecordTracking.none,
    endsEventExport: true,
  ),
  SetRecords(parts: SetupRecords(activity: true), tracking: RecordTracking.none, endsEventExport: false),
  ChangeMember(
    uid: 'u-ada',
    email: 'ada@northwind.example',
    role: 'Operators',
    crates: {
      'Staging': {CrateSwitches.connect, CrateSwitches.sftp, CrateSwitches.forward, CrateSwitches.reveal},
    },
    until: Named(_until),
  ),
  ChangeMember(uid: 'u-ada', email: 'ada@northwind.example', role: 'admin', dropsExtraCrates: true),
  ChangeMember(uid: 'u-ada', email: 'ada@northwind.example', role: 'owner', crates: {}, until: Named<int?>(null)),
  Invite(email: 'lin@northwind.example', role: 'Members', crates: {}, again: false),
  Invite(
    email: 'lin@northwind.example',
    role: 'admin',
    crates: {
      'Staging': {CrateSwitches.connect, CrateSwitches.sftp, CrateSwitches.forward},
    },
    until: _until,
    again: true,
  ),
  AddGroup(crate: 'Production', name: 'Web'),
  AddHost(
    crate: 'Production',
    name: 'web-1',
    address: '10.50.0.11',
    port: 2222,
    protocol: 'mosh',
    key: 'deploy',
    group: 'Web',
    tags: {'web', 'prod'},
  ),
  AddHost(crate: 'Production', name: 'db-1', address: 'db-1.northwind.example', port: 22, protocol: 'ssh'),
  ChangeHost(
    crate: 'Production',
    hostId: 'h-1',
    name: 'web-1',
    address: '10.50.0.99',
    port: 22,
    protocol: 'et',
    key: Named<String?>('backup'),
    group: Named<String?>('Edge'),
    tags: {'b', 'a'},
  ),
  ChangeHost(
    crate: 'Production',
    hostId: 'h-1',
    name: 'web-1',
    key: Named<String?>(null),
    group: Named<String?>(null),
    tags: {},
  ),
  // A member's limits: held to a level, to switches no level
  // is, taken away, lifted; and made an admin, which ends them.
  LimitMember(
    uid: 'u-ada',
    email: 'ada@northwind.example',
    crate: 'Production',
    crateId: 'c-1',
    switches: {CrateSwitches.connect, CrateSwitches.sftp, CrateSwitches.forward},
  ),
  LimitMember(
      uid: 'u-ada', email: 'ada@northwind.example', crate: 'Staging', switches: {CrateSwitches.connect, CrateSwitches.reveal}),
  LimitMember(uid: 'u-ada', email: 'ada@northwind.example', crate: 'Staging', switches: {}),
  LimitMember(uid: 'u-ada', email: 'ada@northwind.example', crate: 'Production', crateId: 'c-1'),
  ChangeMember(uid: 'u-ada', email: 'ada@northwind.example', role: 'admin', dropsLimits: true),
];

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  tearDown(() {
    Redactor.instance.enabled = false;
  });

  test('every step says what it does, with what exactly under it', () {
    expect([for (final s in _steps) setupStepWords(s, l10n).text], [
      'Add the vault Lab',
      'Add the vault Vault, for owners only',
      'Vault Production\n'
          '    Open to admins and to the roles given it (no longer for owners only)\n'
          '    Allowed here: SFTP, Port forwarding, Agent forwarding\n'
          '    Ask again before revealing: on\n'
          '    Session logs: off\n'
          '    Watched sessions: off',
      'Vault Staging\n'
          '    Watched sessions: on\n'
          '    ZestSSH Cloud unreachable: Everyone connects, with a reason\n'
          '    Offline limit: 1 day\n'
          '    SFTP, port forwarding and agent forwarding go off with it: a watched vault allows the terminal only',
      'Vault Depot\n'
          '    Allowed here: the terminal only\n'
          '    Ask again before revealing: off\n'
          '    Session logs: on\n'
          '    ZestSSH Cloud unreachable: Owners connect, with a reason\n'
          '    Offline limit: No limit',
      'Add the role Operators\n'
          '    Invite people into roles below theirs\n'
          '    Suspend and remove people below them\n'
          '    Change the roles and end dates of people below them\n'
          '    Add vaults (they manage the ones they add)\n'
          '    Production: Use\n'
          '    Lab: Manage, with agent forwarding\n'
          '    Depot: connect, reveal',
      'Add the role Guests\n'
          '    May do nothing in the team itself\n'
          '    Gives nothing in any vault',
      'Role Members\n'
          '    Invite people into roles below theirs',
      'Role Members\n'
          '    Production: Connect',
      'Role Members\n'
          '    May do nothing in the team itself\n'
          '    Gives nothing in any vault',
      'Put the roles in this order, highest first\n'
          '    Operators, Members, Guests',
      'Change the rules\n'
          '    Two-step sign-in: on\n'
          '    Allowed email domains: northwind.example, ops.northwind.example\n'
          '    App lock: on\n'
          '    Longest auto-lock time: 15 minutes\n'
          '    No export: off\n'
          '    Offline limit: 3 days\n'
          '    Sign-in lasts: 30 days\n'
          '    Company sign-in required: off\n'
          '    Approved devices only: on',
      'Change the rules\n'
          '    Allowed email domains: any address\n'
          '    Longest auto-lock time: Any\n'
          '    Offline limit: No limit\n'
          '    Sign-in lasts: Not required',
      'Change the rules\n'
          '    Longest auto-lock time: 2 hours\n'
          '    Offline limit: 5 hours',
      'Change what the team records\n'
          '    Version history: on\n'
          '    Activity: off\n'
          '    Devices: on\n'
          '    Sign-in addresses: off\n'
          "    Sending the team's events on ends with it",
      'Change what the team records\n'
          '    Activity: on',
      'Member ada@northwind.example\n'
          '    Role: Operators\n'
          '    Extra vault Staging: Use\n'
          '    Access ends: 2030-06-30T17:00:00Z',
      'Member ada@northwind.example\n'
          '    Role: Admin\n'
          '    Their extra vaults end with it: owners and admins open every vault they may',
      'Member ada@northwind.example\n'
          '    Role: Owner\n'
          '    No extra vaults\n'
          '    Access does not end',
      'Invite lin@northwind.example as Members',
      'Change the invitation of lin@northwind.example: now as Admin\n'
          '    Extra vault Staging: Connect\n'
          '    Access ends: 2030-06-30T17:00:00Z',
      'Add the group Web in Production',
      'Add the host web-1 in Production\n'
          '    mosh 10.50.0.11:2222\n'
          '    Key: deploy\n'
          '    Group: Web\n'
          '    Tags: prod, web',
      'Add the host db-1 in Production\n'
          '    ssh db-1.northwind.example:22',
      'Host web-1 in Production\n'
          '    Address: 10.50.0.99\n'
          '    Port: 22\n'
          '    Protocol: et\n'
          '    Key: backup\n'
          '    Group: Edge\n'
          '    Tags: a, b',
      'Host web-1 in Production\n'
          '    No key: it asks when connecting\n'
          '    In no group\n'
          '    No tags',
      'Limit ada@northwind.example in Production to Connect',
      'Limit ada@northwind.example in Staging to connect, reveal',
      'Take Staging away from ada@northwind.example',
      'Lift the limit on ada@northwind.example in Production',
      'Member ada@northwind.example\n'
          '    Role: Admin\n'
          '    Their limits end with it: owners and admins are never limited',
    ]);
    // A step with nothing under it is its one line.
    expect(const SetupStepWords('Only this').text, 'Only this');
    expect(const SetupStepWords('Only this').details, isEmpty);
  });

  test('a level is said by its name where the switches are exactly one, else as the file writes them', () {
    for (final (level, name) in [
      (CrateLevel.connect, 'Connect'),
      (CrateLevel.use, 'Use'),
      (CrateLevel.edit, 'Edit'),
      (CrateLevel.manage, 'Manage'),
    ]) {
      expect(setupLevelWords(levelSwitches(level), l10n), name);
      expect(setupLevelWords({...levelSwitches(level), CrateSwitches.agent}, l10n), '$name, with agent forwarding');
    }
    expect(setupLevelWords({CrateSwitches.connect}, l10n), 'connect');
    expect(setupLevelWords({CrateSwitches.connect, CrateSwitches.agent}, l10n), 'agent, connect');
    expect(setupLevelWords({...levelSwitches(CrateLevel.use), CrateSwitches.add}, l10n),
        'add, connect, forward, reveal, sftp');
    expect(setupRoleWords('owner', l10n), 'Owner');
    expect(setupRoleWords('admin', l10n), 'Admin');
    expect(setupRoleWords('Operators', l10n), 'Operators');
  });

  test('everything that can stand in the way is said as itself', () {
    const step = CrateSettings(
        crate: 'Production', parts: CrateParts(sessionLogs: true), allowsNothingWithWatching: false);
    String words(SetupProblemKind kind, {String? subject, String? other, int? count, String? reason, SetupStep? at}) =>
        setupProblemWords(SetupProblem(kind, subject: subject, other: other, count: count, reason: reason, step: at), l10n);
    expect(words(SetupProblemKind.otherOrchard, subject: 'Acme', other: 'Northwind Ops'),
        'This file is for the team Acme. This one is Northwind Ops.');
    expect(words(SetupProblemKind.ambiguousCrate, subject: 'Production'),
        'More than one vault here is called Production, so the file cannot say which it means. Rename one of them first.');
    expect(words(SetupProblemKind.ambiguousCrate, subject: 'Production', other: 'Operators'),
        'Operators names the vault Production, and more than one vault here is called that.');
    expect(
        words(SetupProblemKind.crateMayExist, subject: 'Lab', count: 2),
        'No vault this account can open is called Lab, and 2 here are closed to it: one of them may be it. '
        'Apply the file from an account that opens every vault.');
    expect(words(SetupProblemKind.cannotCloseCrate, subject: 'Production'),
        'Production is open to more than its owners. A vault is for owners only from when it is added, or never.');
    expect(words(SetupProblemKind.tooManyCrates, subject: 'Lab', count: 200),
        'A team holds 200 vaults at most, so Lab cannot be added.');
    expect(words(SetupProblemKind.noSuchCrate, subject: 'Nowhere', other: 'ada@northwind.example'),
        'ada@northwind.example names the vault Nowhere, which this team does not have and the file does not add.');
    expect(words(SetupProblemKind.ambiguousRole, subject: 'Members'),
        'More than one role here is called Members. Rename one of them first.');
    expect(words(SetupProblemKind.ambiguousRole, subject: 'Members', other: 'ada@northwind.example'),
        'ada@northwind.example is given the role Members, and more than one role here is called that.');
    expect(words(SetupProblemKind.roleMayExist, subject: 'Operators', count: 3),
        'No role this device can read is called Operators, and it cannot read 3 role names here: one of them may be it.');
    expect(words(SetupProblemKind.tooManyRoles, subject: 'Operators', count: 30),
        'A team holds 30 roles at most, so Operators cannot be added.');
    expect(
        words(SetupProblemKind.noSuchRole, subject: 'Nobodies', other: 'ada@northwind.example'),
        'ada@northwind.example is given the role Nobodies, which this team does not have and the file does not add.');
    expect(words(SetupProblemKind.ambiguousHost, subject: 'web-1', other: 'Production'),
        'More than one host in Production is called web-1.');
    expect(words(SetupProblemKind.hostNeedsAddress, subject: 'web-9', other: 'Production'),
        'web-9 is not a host of Production yet, and a new host needs an address.');
    expect(words(SetupProblemKind.cannotAddHosts, subject: 'Production'),
        'This account may not add hosts to Production.');
    expect(words(SetupProblemKind.cannotEditHosts, subject: 'Production'),
        'This account may not change hosts in Production.');
    expect(
        words(SetupProblemKind.noSuchKey, subject: 'deploy', other: 'web-1'),
        'The host web-1 names the key deploy, which this device does not have. '
        'Add the key in the app first: a file never carries one.');
    expect(words(SetupProblemKind.ambiguousKey, subject: 'deploy', other: 'web-1'),
        'The host web-1 names the key deploy, and more than one key is called that.');
    expect(
        words(SetupProblemKind.watchedKeyElsewhere, subject: 'deploy', other: 'web-1'),
        'The host web-1 names the key deploy, which is in a watched vault: '
        'such a key signs in only to hosts of its own vault.');
    expect(words(SetupProblemKind.ambiguousGroup, subject: 'Web', other: 'web-1'),
        'The host web-1 names the group Web, and more than one group is called that.');
    expect(
        words(SetupProblemKind.ownMembership, subject: 'ada@northwind.example'),
        'ada@northwind.example is the account applying this file. '
        'Nobody changes their own role, extra vaults or end date by a file.');
    expect(
        words(SetupProblemKind.compareFirst, subject: 'ada@northwind.example'),
        'ada@northwind.example would become an owner or admin. '
        'Compare their keys with them first, on the Members page, then apply the file.');
    expect(words(SetupProblemKind.untilPassed, subject: 'ada@northwind.example'),
        'ada@northwind.example: the time their access would end has passed.');
    expect(words(SetupProblemKind.untilTooFar, subject: 'ada@northwind.example'),
        'ada@northwind.example: an end date can be at most five years away.');
    expect(words(SetupProblemKind.guestNeedsEnd, subject: 'ada@partner.example'),
        "ada@partner.example: someone outside this team's domains needs an end date.");
    expect(words(SetupProblemKind.guestOwnersOnly, subject: 'ada@partner.example'),
        "ada@partner.example: Only owners can invite or change people outside your company's domains.");
    expect(words(SetupProblemKind.cannotInvite, subject: 'ada@northwind.example'),
        'ada@northwind.example is not a member, and this account cannot invite people.');
    expect(words(SetupProblemKind.inviteNeedsRole, subject: 'ada@northwind.example'),
        'ada@northwind.example is not a member yet, and an invitation needs a role.');
    expect(words(SetupProblemKind.inviteeOutsideDomains, subject: 'kai@elsewhere.example'),
        "kai@elsewhere.example is outside this team's address domains and could never join.");
    expect(words(SetupProblemKind.rulesLeaveYouOut, subject: 'northwind.example'),
        l10n.orchardRulesOwnDomain('northwind.example'));
    expect(words(SetupProblemKind.rulesLeaveYouOut), l10n.orchardRulesOwnDomain('?'));
    expect(
        words(SetupProblemKind.keysNotTrusted, subject: 'ada@northwind.example', at: step),
        'ada@northwind.example would gain a key, and their keys changed since this device last saw them compared. '
        'Compare their keys with them first, on the Members page.');
    expect(words(SetupProblemKind.refused, reason: 'only owners set session logs', at: step),
        'Vault Production: Only owners turn session logs on or off.');
    expect(words(SetupProblemKind.refused, reason: 'only owners set session logs'),
        ': Only owners turn session logs on or off.');
    // A member's limits.
    const limit = LimitMember(
        uid: 'u-ada',
        email: 'ada@northwind.example',
        crate: 'Vault',
        switches: {CrateSwitches.connect, CrateSwitches.sftp, CrateSwitches.forward});
    expect(
        words(SetupProblemKind.limitsNeedMember, subject: 'sam@northwind.example'),
        'sam@northwind.example is not a member yet, and limits are set only for members. '
        'Leave their limits out of the file until they have joined, then put them back and apply it.');
    expect(
        words(SetupProblemKind.notYet, at: limit),
        "Limit ada@northwind.example in Vault to Connect: Lowering access below someone's role turns on once "
        'ZestSSH $kNewRecordKindsVersion is out on computers and phones alike.');
    expect(words(SetupProblemKind.notYet, at: limit), endsWith(l10n.vaultAccessNotYet(kNewRecordKindsVersion)));
    expect(words(SetupProblemKind.refused, reason: 'no such Crate, or owners-only', at: limit),
        'Limit ada@northwind.example in Vault to Connect: An owners-only vault takes no limits: only owners open it.');
    // The same reason about another kind of step keeps its own words.
    expect(words(SetupProblemKind.refused, reason: 'no such Crate, or owners-only', at: step),
        'Vault Production: A role or an extra vault never reaches an owners-only vault.');
    expect(
        words(SetupProblemKind.refused, reason: 'owners and admins have no limits', at: limit),
        'Limit ada@northwind.example in Vault to Connect: '
        'Owners and admins have no limits: their role alone says what they may do.');
    // Each kind has words of its own.
    final all = {
      for (final kind in SetupProblemKind.values)
        words(kind, subject: 's', other: 'o', count: 1, reason: 'only owners change roles', at: step),
    };
    expect(all, hasLength(SetupProblemKind.values.length + 0));
  });

  test('every reason the record gives for refusing a step has words of its own', () {
    const reasons = {
      'not allowed to add that Crate': 'This account may not add that vault. Only owners add one for owners only.',
      'only owners mark a Crate owners-only': 'Only owners open an owners-only vault.',
      'changing a Crate needs manage': 'Changing a vault takes managing it.',
      'only owners set session logs': 'Only owners turn session logs on or off.',
      'only owners set watched sessions': 'Only owners turn watched sessions on or off.',
      "only owners set a Crate's offline limit": "Only owners set a vault's offline limit.",
      'a lock timeout needs the app lock': 'An auto-lock time needs the app lock rule as well.',
      'only owners set what the team records': 'Only owners change what the team records.',
      'only owners change roles': 'Only owners change roles.',
      'no such Crate, or owners-only': 'A role or an extra vault never reaches an owners-only vault.',
      'only people below you': 'You change only people below you. Owners are equals.',
      'only owners make owners and admins': 'Only owners make someone an owner or admin.',
      'only owners add owners and admins': 'Only owners make someone an owner or admin.',
      'not allowed to give that role': 'This account may not give that role.',
      'not allowed to add someone in that role': 'This account may not give that role.',
      'giving a Crate needs manage on it': 'Giving someone a vault takes managing that vault.',
      'owners and admins need no extra Crate': 'Owners and admins have no extra vaults: they open every vault they may.',
      'owners do not end': "An owner's access does not end.",
      'hands out more than they have': 'This would give more than this account has itself.',
      'owners and admins have no limits': 'Owners and admins have no limits: their role alone says what they may do.',
      'limiting a Crate needs manage on it': 'Limiting someone in a vault takes managing that vault.',
    };
    for (final r in reasons.entries) {
      expect(setupRefusalWords(r.key, l10n), r.value, reason: r.key);
    }
    expect(setupRefusalWords('a watched Crate allows the terminal only', l10n), l10n.crateWatchedTerminalOnly);
    expect(setupRefusalWords('only owners set the rules', l10n), l10n.orchardRulesOwnersOnly);
    expect(setupRefusalWords('two approved devices among the owners first', l10n), l10n.deviceErrorTwoOwners);
    expect(setupRefusalWords('not from an approved device', l10n), l10n.deviceErrorNotApproved);
    // One nobody put into words is said as the record said it.
    expect(setupRefusalWords('something new', l10n), "The team's record does not take this (something new).");
  });

  test('everything a file leaves alone, and what to know before applying, is said as itself', () {
    String words(SetupNoteKind kind, {String? subject, int? count, List<String> names = const []}) =>
        setupNoteWords(SetupNote(kind, subject: subject, count: count, names: names), l10n);
    expect(words(SetupNoteKind.crateNotInFile, subject: 'Staging'),
        'The vault Staging is not in the file. It stays as it is.');
    expect(words(SetupNoteKind.roleNotInFile, subject: 'Members'),
        'The role Members is not in the file. It stays as it is.');
    expect(words(SetupNoteKind.memberNotInFile, subject: 'ada@northwind.example'),
        'ada@northwind.example is a member and not in the file. They stay as they are.');
    expect(words(SetupNoteKind.invitationNotInFile, subject: 'ada@northwind.example'),
        'ada@northwind.example is invited and not in the file. The invitation stays.');
    expect(words(SetupNoteKind.hostsNotInFile, subject: 'Production', names: ['a', 'b']),
        'Hosts of Production that are not in the file, and stay: a, b');
    expect(words(SetupNoteKind.cratesClosed, count: 2), 'Vaults this account cannot open, not compared: 2');
    expect(words(SetupNoteKind.invited, subject: 'ada@northwind.example'),
        'ada@northwind.example is invited with this offer already.');
    expect(words(SetupNoteKind.acceptedWaiting, subject: 'ada@northwind.example'),
        'ada@northwind.example accepted. Compare their keys with them and confirm, on the Members page.');
    expect(
        words(SetupNoteKind.manyInvitations, count: 31),
        '31 invitations: ZestSSH Cloud takes 30 an hour from one account. '
        'Apply the file again later for the rest.');
    expect(
        words(SetupNoteKind.thisDeviceRules),
        'This device does not meet these rules yet (its app lock). '
        'The team stops syncing here until it does.');
    expect(words(SetupNoteKind.notReached),
        'ZestSSH Cloud could not be reached: this is the team as this device last saw it.');
    expect(
        words(SetupNoteKind.outsideDomainsUnseen, names: ['sam@partner.example']),
        'Not on these domains, and let in by an end date no owner gave: sam@partner.example. '
        'On the Members page, keep the date, change it or remove them.');
    expect(
        words(SetupNoteKind.outsideDomains, names: ['ada@partner.example', 'sam@partner.example']),
        'Not on these domains, and held back once this is applied: ada@partner.example, sam@partner.example. '
        'On the Members page, keep them as guests or remove them.');
    expect({for (final kind in SetupNoteKind.values) words(kind, subject: 's', count: 1, names: ['n'])},
        hasLength(SetupNoteKind.values.length));
  });

  test('everything wrong with a file is said with its place', () {
    String words(SetupFileFault fault,
            {String path = 'crates[0].name',
            SetupKind? kind,
            int? min,
            int? max,
            List<String> allowed = const [],
            String? value,
            int? line,
            int? column}) =>
        setupFileProblemWords(
            SetupFileProblem(fault, path,
                kind: kind, min: min, max: max, allowed: allowed, value: value, line: line, column: column),
            l10n);
    expect(words(SetupFileFault.tooBig, path: ''), 'The file is larger than a setup file can be.');
    expect(words(SetupFileFault.notJson, path: ''), 'It is not JSON.');
    expect(words(SetupFileFault.notJson, path: '', line: 3), 'It is not JSON.');
    expect(words(SetupFileFault.notJson, path: '', line: 3, column: 14),
        'It is not JSON: something is wrong at line 3, column 14.');
    expect(words(SetupFileFault.notSetupFile, path: ''),
        'It is JSON, and not a setup file: one starts with the field zestssh_setup.');
    expect(words(SetupFileFault.newerVersion, value: '2'),
        'It was written for a newer ZestSSH (setup file version 2). Update the app to use it.');
    expect(words(SetupFileFault.unknownField), 'crates[0].name: a setup file has no such field. Check its spelling.');
    expect(
        words(SetupFileFault.secretField),
        'crates[0].name: a setup file never carries a password, a key or another secret. '
        "Take it out: a host names its key by the key's name.");
    expect(words(SetupFileFault.duplicateField), 'crates[0].name: this field is there twice.');
    expect(words(SetupFileFault.wrongKind, kind: SetupKind.text), 'crates[0].name: text goes here.');
    expect(words(SetupFileFault.wrongKind), 'crates[0].name: text goes here.');
    expect(words(SetupFileFault.wrongKind, kind: SetupKind.number), 'crates[0].name: a whole number goes here.');
    expect(words(SetupFileFault.wrongKind, kind: SetupKind.yesNo), 'crates[0].name: true or false goes here.');
    expect(words(SetupFileFault.wrongKind, kind: SetupKind.list), 'crates[0].name: a list goes here.');
    expect(words(SetupFileFault.wrongKind, kind: SetupKind.object), 'crates[0].name: a group of fields goes here.');
    expect(words(SetupFileFault.wrongKind, kind: SetupKind.textOrNothing),
        'crates[0].name: text goes here, or null for none.');
    expect(words(SetupFileFault.wrongKind, kind: SetupKind.level),
        'crates[0].name: an access level (connect, use, edit or manage) or a list of switches goes here.');
    expect(
        words(SetupFileFault.wrongKind, kind: SetupKind.limit),
        'crates[0].name: an access level (connect, use, edit or manage), none for no access, '
        'or a list of switches goes here.');
    expect(words(SetupFileFault.missing), 'crates[0].name: this field is needed.');
    expect(words(SetupFileFault.empty), 'crates[0].name: this is empty.');
    expect(words(SetupFileFault.tooLong, max: 50), 'crates[0].name: longer than 50 characters.');
    expect(words(SetupFileFault.tooMany, max: 200), 'crates[0].name: more than 200 of them.');
    expect(words(SetupFileFault.outOfRange, min: 1, max: 65535), 'crates[0].name: a number from 1 to 65535 goes here.');
    expect(words(SetupFileFault.notOneOf, allowed: ['a', 'b']), 'crates[0].name: this is not one of a, b.');
    expect(words(SetupFileFault.duplicate, value: 'Production'), 'crates[0].name: Production is named twice.');
    expect(
        words(SetupFileFault.reservedRole),
        "crates[0].name: Owner and Admin are the team's own roles. "
        'A role of yours needs another name.');
    expect(words(SetupFileFault.notADomain), 'crates[0].name: this is not a domain such as example.com.');
    expect(words(SetupFileFault.notAnAddress), 'crates[0].name: this is not an email address.');
    expect(
        words(SetupFileFault.notATime),
        'crates[0].name: a time goes here as 2027-01-31T17:00:00Z, with Z or an offset, or null for no end.');
    expect(words(SetupFileFault.needsConnect),
        'crates[0].name: these switches leave out connect, and nothing else works without it.');
    expect(
        words(SetupFileFault.oddCharacters),
        'crates[0].name: this holds a character that does not show, '
        'or one that turns the reading direction around.');
    expect(
        words(SetupFileFault.watchedAllows),
        'crates[0].name: a watched vault allows the terminal only. '
        'Leave this list empty, or do not watch the vault.');
    expect({for (final fault in SetupFileFault.values) words(fault, value: 'v', min: 1, max: 2, line: 1, column: 1)},
        hasLength(SetupFileFault.values.length));
    // A real file's problems read through.
    final read = readSetupFile('{"zestssh_setup": 1, "crates": [{"name": "A", "port": 1}], "orchard": 7}');
    expect([for (final p in read.problems) setupFileProblemWords(p, l10n)], [
      'orchard: text goes here.',
      'crates[0].port: a setup file has no such field. Check its spelling.',
    ]);
  });

  test('everything an exported file leaves out is said as itself', () {
    String words(SetupLeftOutKind kind, {int? count, List<String> names = const []}) =>
        setupLeftOutWords(SetupLeftOut(kind, count: count, names: names), l10n);
    expect(words(SetupLeftOutKind.closedCrates, count: 2), 'Vaults this account cannot open: 2');
    expect(words(SetupLeftOutKind.sharedNames, names: ['Production', 'web-1']),
        'Names that stand for more than one thing here, so a file cannot say which: Production, web-1');
    expect(words(SetupLeftOutKind.unwritableNames, count: 3),
        'Names a file cannot carry (a character that does not show, or too long): 3');
    expect(words(SetupLeftOutKind.otherHosts, count: 4),
        'Hosts that are not reached at an address (a serial line, a local shell): 4');
    expect(words(SetupLeftOutKind.unreadRoles, count: 5), 'Roles whose names this device cannot read: 5');
    expect(words(SetupLeftOutKind.rolesLikeOwn, names: ['Admin']),
        "Roles called like the team's own Owner and Admin: Admin");
    expect(
        words(SetupLeftOutKind.partsNotWritten, names: ['Wide', 'ada@northwind.example']),
        'In the file with one part left unsaid, because that part names something the file does not hold. '
        'Applying the file leaves that part as it is: Wide, ada@northwind.example');
    expect(words(SetupLeftOutKind.membersWithoutAddress, count: 6),
        'Members whose address this device does not know: 6');
    expect({for (final kind in SetupLeftOutKind.values) words(kind, count: 1, names: ['n'])},
        hasLength(SetupLeftOutKind.values.length));
  });

  test('why reading or applying failed is said: a name that is gone, an Orchard that is not open, the rest as ever',
      () {
    expect(setupErrorWords(const SetupNameGone('Lab'), l10n),
        'Nothing here is called Lab any more. Check the file again.');
    expect(setupErrorWords(const SetupNotOpen('suspended'), l10n),
        'This team cannot be read from this account right now.');
    expect(setupErrorWords(const OrchardRecordRefused('only owners change roles'), l10n), l10n.orchardErrorRefused);
    expect(setupErrorWords(const MemberNotCompared('ada'), l10n), l10n.orchardPromoteCompareTitle('ada'));
    expect(setupErrorWords(const OrchardServerException(409, 'role-limit'), l10n),
        l10n.orchardRoleLimit(kMaxOrchardRoles));
    // A change the server takes only after a recent sign-in, where nobody
    // signed in again: in words, not as the server's code.
    expect(setupErrorWords(const OrchardServerException(403, 'recent-sign-in-required'), l10n),
        'ZestSSH Cloud takes this change only after a sign-in from the last two hours.');
    expect(setupErrorWords(const OrchardServerException(403, 'forbidden'), l10n),
        isNot(l10n.setupErrorNeedsSignIn));
  });

  test('a whole plan as text: what is in the way first, then the changes, then what to know', () {
    final plan = SetupPlan(
      steps: const [
        AddCrate(name: 'Lab', ownersOnly: false),
        CrateSettings(crate: 'Lab', parts: CrateParts(askAgain: true), allowsNothingWithWatching: false),
      ],
      problems: const [SetupProblem(SetupProblemKind.cannotCloseCrate, subject: 'Production')],
      notes: const [SetupNote(SetupNoteKind.crateNotInFile, subject: 'Staging')],
      after: OrchardRecord('o'),
    );
    expect(setupPlanText(plan, l10n), '''
In the way: 1
  ! Production is open to more than its owners. A vault is for owners only from when it is added, or never.
2 changes
  + Add the vault Lab
  + Vault Lab
      Ask again before revealing: on
Good to know
  - The vault Staging is not in the file. It stays as it is.'''
        .trimLeft());
    final nothing = SetupPlan(steps: const [], problems: const [], notes: const [], after: OrchardRecord('o'));
    expect(setupPlanText(nothing, l10n), 'This team is what the file says already. There is nothing to change.');
    final one = SetupPlan(
        steps: const [AddCrate(name: 'Lab', ownersOnly: false)],
        problems: const [],
        notes: const [],
        after: OrchardRecord('o'));
    expect(setupPlanText(one, l10n), '1 change\n  + Add the vault Lab');
    // Only something in the way: no line that says there is nothing to change.
    final blocked = SetupPlan(
        steps: const [],
        problems: const [SetupProblem(SetupProblemKind.untilPassed, subject: 'ada@northwind.example')],
        notes: const [],
        after: OrchardRecord('o'));
    expect(setupPlanText(blocked, l10n),
        'In the way: 1\n  ! ada@northwind.example: the time their access would end has passed.');
  });

  test('on a screen that is recorded, names are masked; in a terminal and in what is copied they are not', () {
    const names = [
      'ada@northwind.example',
      'lin@northwind.example',
      'web-1',
      'db-1',
      '10.50.0.11',
      '10.50.0.99',
      'db-1.northwind.example',
      'Production',
      'Staging',
      'deploy',
      'backup',
      'northwind.example',
    ];
    String all(SetupShow show) => [
          for (final s in _steps) setupStepWords(s, l10n, show: show).text,
          setupProblemWords(
              const SetupProblem(SetupProblemKind.noSuchKey, subject: 'deploy', other: 'web-1'), l10n,
              show: show),
          setupProblemWords(
              const SetupProblem(SetupProblemKind.otherOrchard, subject: 'Production', other: 'Staging'), l10n,
              show: show),
          setupProblemWords(
              const SetupProblem(SetupProblemKind.rulesLeaveYouOut, subject: 'northwind.example'), l10n,
              show: show),
          setupNoteWords(const SetupNote(SetupNoteKind.memberNotInFile, subject: 'ada@northwind.example'), l10n,
              show: show),
          setupNoteWords(const SetupNote(SetupNoteKind.outsideDomains, names: ['ada@northwind.example']), l10n, show: show),
          setupNoteWords(const SetupNote(SetupNoteKind.hostsNotInFile, subject: 'Production', names: ['web-1', 'db-1']),
              l10n, show: show),
        ].join('\n');

    // Not recording: a screen shows names as they are, and a time in words
    // on this device's clock, with the year, where a terminal has the file's.
    final plain = all(const SetupShow.asIs());
    final local = DateFormat.yMMMd('en_US').add_jm().formatPlain(DateTime.fromMillisecondsSinceEpoch(_until * 1000));
    expect(all(const SetupShow.onScreen()), plain.replaceAll(setupTime(_until), local));
    for (final n in names) {
      expect(plain, contains(n), reason: n);
    }
    Redactor.instance
      ..salt = 'a test'
      ..level = RedactLevel.layout
      ..enabled = true;
    final masked = all(const SetupShow.onScreen());
    for (final n in names) {
      expect(masked, isNot(contains(n)), reason: n);
    }
    // What is not a name stays.
    expect(masked, contains('Watched sessions: on'));
    expect(masked, contains('Access ends: $local'));
    expect(masked, contains('Role: Operators'));
    // A terminal, and what is saved, has them as they are.
    expect(all(const SetupShow.asIs()), plain);
    // What is copied from a screen masks the names as it does, and keeps
    // the file's own time (for a log or support).
    final copied = all(const SetupShow.copied());
    for (final n in names) {
      expect(copied, isNot(contains(n)), reason: n);
    }
    expect(copied, contains('Access ends: ${setupTime(_until)}'));
    expect(copied, isNot(contains(local)));
    Redactor.instance.enabled = false;
    expect(all(const SetupShow.copied()), plain, reason: 'not recording: as it is');
  });

  test('each kind of name is masked by its own rule while a screen is recorded', () {
    const show = SetupShow.onScreen();
    Redactor.instance
      ..salt = 'a test'
      ..level = RedactLevel.layout
      ..enabled = true;
    // An address keeps the shape of one, a key is called a key: neither is
    // masked the way a name is.
    // (A host reached by a name of one word, with its port: the rule for
    // names would take the whole of it for a name, port and all.)
    const address = 'bastion:22';
    expect(show.address(address), Redactable.address(address).display);
    expect(show.address(address), isNot(Redactable.host(address).display));
    expect(show.address(address), isNot(contains('bastion')));
    expect(show.address(address), endsWith(':22'));
    expect(show.address('10.50.0.11:22'), Redactable.address('10.50.0.11:22').display);
    expect(show.address('10.50.0.11:22'), isNot(contains('10.50.0.11')));
    const key = 'deploy';
    expect(show.key(key), Redactable.keyName(key).display);
    expect(show.key(key), isNot(Redactable.group(key).display));
    expect(show.key(key), isNot(contains(key)));
    // A group, a host, a Crate, a person and the Orchard are names.
    for (final name in ['Edge', 'web-1', 'Production', 'ada@northwind.example', 'Northwind Ops']) {
      for (final masked in [show.group(name), show.host(name), show.crate(name), show.person(name), show.orchard(name)]) {
        expect(masked, isNot(contains(name)), reason: name);
        expect(masked, Redactable.host(name).display, reason: name);
      }
    }
    // In the words of a step: the group a host goes into, and the group added for it.
    final host = setupStepWords(
        const AddHost(
            crate: 'Production', name: 'web-1', address: '10.50.0.11', port: 22, protocol: 'ssh', key: 'deploy', group: 'Edge'),
        l10n,
        show: show);
    expect(host.text, isNot(contains('Edge')));
    expect(host.text, contains(Redactable.address('10.50.0.11:22').display));
    expect(host.text, contains(Redactable.keyName('deploy').display));
    expect(setupStepWords(const AddGroup(crate: 'Production', name: 'Edge'), l10n, show: show).title,
        isNot(contains('Edge')));
    // Not on a screen, nothing is masked.
    const asIs = SetupShow.asIs();
    expect([asIs.address(address), asIs.key(key), asIs.group('Edge'), asIs.host('web-1')],
        [address, key, 'Edge', 'web-1']);
  });

  test('the two rules about remote screens are said by the names the team\'s rules give them, in every language',
      () {
    const step = SetRules(
        parts: SetupRules(screensSshOnly: true, screensLockRedirections: false),
        rules: RecordRules(screensSshOnly: true));
    expect(setupStepWords(step, l10n).details, [
      'Remote screens through SSH only: ${l10n.setupOn}',
      'No clipboard or drive sharing with remote screens: ${l10n.setupOff}',
    ]);
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      expect(setupStepWords(step, l).details, [
        l.setupPair(l.orchardRulesScreensSshOnly, l.setupOn),
        l.setupPair(l.orchardRulesScreensNoSharing, l.setupOff),
      ]);
      expect(l.orchardRulesScreensSshOnly, contains('SSH'), reason: '$locale');
      expect(l.orchardRulesScreensSshOnly, isNot(l.orchardRulesScreensNoSharing), reason: '$locale');
    }
  });

  test('how long a device may stay unlocked is said in hours only where it is whole hours', () {
    String lock(int minutes) => setupStepWords(
            SetRules(parts: SetupRules(maxLockMinutes: minutes), rules: RecordRules(maxLockMinutes: minutes)), l10n)
        .details
        .single;
    expect(lock(15), 'Longest auto-lock time: 15 minutes');
    expect(lock(59), 'Longest auto-lock time: 59 minutes');
    expect(lock(60), 'Longest auto-lock time: 1 hour');
    expect(lock(61), 'Longest auto-lock time: 61 minutes');
    expect(lock(90), 'Longest auto-lock time: 90 minutes');
    expect(lock(120), 'Longest auto-lock time: 2 hours');
    expect(lock(150), 'Longest auto-lock time: 150 minutes');
    expect(lock(0), isNot(contains('0')));
    String offline(int hours) => setupStepWords(
            SetRules(parts: SetupRules(offlineHours: hours), rules: RecordRules(offlineHours: hours)), l10n)
        .details
        .single;
    expect(offline(5), 'Offline limit: 5 hours');
    expect(offline(24), 'Offline limit: 1 day');
    expect(offline(36), 'Offline limit: 36 hours');
    expect(offline(72), 'Offline limit: 3 days');
  });

  test('every language says every step, problem, note, fault and thing left out, with the names in it', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      for (final s in _steps) {
        final words = setupStepWords(s, l);
        expect(words.title.trim(), isNotEmpty, reason: '$locale $s');
        for (final d in words.details) {
          expect(d.trim(), isNotEmpty, reason: '$locale $s');
        }
      }
      expect(setupStepWords(_steps[0], l).title, contains('Lab'), reason: '$locale');
      expect(setupStepWords(_steps[16], l).title, contains('ada@northwind.example'), reason: '$locale');
      expect(setupStepWords(_steps[22], l).title, allOf(contains('web-1'), contains('Production')), reason: '$locale');
      // Each limit says whom and where, and the level where it has one.
      final limits = _steps.whereType<LimitMember>().toList();
      expect(limits, hasLength(4));
      for (final s in limits) {
        expect(setupStepWords(s, l).title, allOf(contains('ada@northwind.example'), contains(s.crate)),
            reason: '$locale $s');
      }
      expect(setupStepWords(limits.first, l).title, contains(l.crateLevelConnect), reason: '$locale');
      expect({for (final s in limits) setupStepWords(s, l).title}, hasLength(4), reason: '$locale');
      expect(setupStepWords(_steps.last, l).details, contains(l.setupDetailDropsLimits), reason: '$locale');
      for (final kind in SetupProblemKind.values) {
        final text = setupProblemWords(
            SetupProblem(kind, subject: 'SUBJECT', other: 'OTHER', count: 7, reason: 'only owners change roles', step: _steps[0]),
            l);
        expect(text.trim(), isNotEmpty, reason: '$locale $kind');
        // (What the record refuses and what waits for a version are said
        // with the step's own words.)
        if (kind != SetupProblemKind.refused && kind != SetupProblemKind.notYet) {
          expect(text, contains('SUBJECT'), reason: '$locale $kind');
        }
      }
      expect(
          setupProblemWords(SetupProblem(SetupProblemKind.notYet, step: limits.first), l),
          allOf(contains(setupStepWords(limits.first, l).title), contains(kNewRecordKindsVersion)),
          reason: '$locale');
      for (final kind in SetupNoteKind.values) {
        expect(setupNoteWords(SetupNote(kind, subject: 'SUBJECT', count: 7, names: const ['NAME']), l).trim(), isNotEmpty,
            reason: '$locale $kind');
      }
      for (final fault in SetupFileFault.values) {
        final text = setupFileProblemWords(
            SetupFileProblem(fault, 'PLACE', min: 1, max: 9, allowed: const ['ONE'], value: 'VALUE', line: 2, column: 3), l);
        expect(text.trim(), isNotEmpty, reason: '$locale $fault');
      }
      for (final kind in SetupKind.values) {
        expect(setupFileProblemWords(SetupFileProblem(SetupFileFault.wrongKind, 'PLACE', kind: kind), l), contains('PLACE'),
            reason: '$locale $kind');
      }
      for (final kind in SetupLeftOutKind.values) {
        expect(setupLeftOutWords(SetupLeftOut(kind, count: 7, names: const ['NAME']), l).trim(), isNotEmpty,
            reason: '$locale $kind');
      }
      // Counts read in every language's own plural (one and two are words
      // of their own in Arabic, with no figure in them).
      for (final n in [0, 1, 2, 3, 5, 11, 21, 100]) {
        expect(l.setupPlanChanges(n).trim(), isNotEmpty, reason: '$locale $n');
        if (locale.languageCode != 'ar' || n > 2) {
          expect(l.setupPlanChanges(n), contains('$n'), reason: '$locale $n');
        }
        expect(l.setupApplyButton(n).trim(), isNotEmpty, reason: '$locale $n');
        expect(l.setupDone(n).trim(), isNotEmpty, reason: '$locale $n');
      }
    }
  });
}
