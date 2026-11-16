import 'package:intl/intl.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/setup/setup_apply.dart';
import 'package:zestssh/features/orchards/setup/setup_export.dart';
import 'package:zestssh/features/orchards/setup/setup_file.dart';
import 'package:zestssh/features/orchards/setup/setup_plan.dart';
import 'package:zestssh/features/orchards/setup/setup_reader.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/team/team_words.dart' show offlineSpanWords, reauthSpanWords;
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/l10n/time_text.dart';

// A setup file's plan in words (3.0): each step, what stands in
// its way, what it leaves alone, what is wrong with a file and what an
// exported one leaves out. One place for the Team page and the command
// line, so both say the same.

/// How the names in a plan are shown: as they are (in a terminal, in what
/// is saved), or as a screen shows names, which masks them while the screen
/// is recorded.
class SetupShow {
  const SetupShow.asIs()
      : _screen = false,
        _localTime = false;
  const SetupShow.onScreen()
      : _screen = true,
        _localTime = true;

  /// What is copied from a screen (Copy details): names as the screen shows
  /// them, masked while it is recorded, and every time as a setup file writes
  /// it. Copied text goes to a log or a support ticket, where a date in the
  /// person's language and on their clock cannot be read back or compared.
  const SetupShow.copied()
      : _screen = true,
        _localTime = false;

  final bool _screen;
  final bool _localTime;

  String _of(String v, Redactable Function(String) kind) => _screen ? kind(v).display : v;

  String orchard(String v) => _of(v, Redactable.account);
  String crate(String v) => _of(v, Redactable.account);
  String person(String v) => _of(v, Redactable.account);
  String host(String v) => _of(v, Redactable.host);
  String address(String v) => _of(v, Redactable.address);
  String key(String v) => _of(v, Redactable.keyName);
  String group(String v) => _of(v, Redactable.group);

  /// Text that may hold any of those: a place in a file, a list of names.
  String any(String v) => _of(v, Redactable.freeText);

  /// A moment ([seconds] since the epoch): on a screen in the person's
  /// language and on this device's clock, with the year (an access may end
  /// years away); as it is written in a setup file everywhere else (a
  /// terminal, what is copied), which a file can take back.
  String time(int seconds, AppLocalizations l10n) {
    if (!_localTime) return setupTime(seconds);
    final at = secondsAsDate(seconds);
    try {
      return DateFormat.yMMMd(l10n.localeName).add_jm().formatPlain(at);
    } catch (_) {
      // This language's dates are not loaded yet: the one way of writing a
      // time that is always there.
      return DateFormat.yMMMd('en_US').add_jm().formatPlain(at);
    }
  }
}

/// A step as it reads: one line that says what, and under it what exactly.
class SetupStepWords {
  const SetupStepWords(this.title, [this.details = const []]);

  final String title;
  final List<String> details;

  /// On lines of its own, the details indented: for a terminal and for
  /// what is copied.
  String get text => [title, for (final d in details) '    $d'].join('\n');
}

String _onOff(bool on, AppLocalizations l10n) => on ? l10n.setupOn : l10n.setupOff;

String _list(Iterable<String> things, AppLocalizations l10n) => things.join(l10n.listSeparator);

String _sorted(Set<String> things, AppLocalizations l10n) => _list(things.toList()..sort(), l10n);

/// A host's other accounts, by their keys' names, in their order (masked
/// while recording, as a key's name is).
String _accounts(List<String> names, AppLocalizations l10n, SetupShow show) =>
    _list([for (final n in names) show.key(n)], l10n);

bool _same(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

/// What someone may do in a Crate: the access level by its name where the
/// switches are exactly one (with agent forwarding on top said so), else
/// the switches as a file writes them.
String setupLevelWords(Set<String> switches, AppLocalizations l10n) {
  for (final level in CrateLevel.values) {
    final name = switch (level) {
      CrateLevel.connect => l10n.crateLevelConnect,
      CrateLevel.use => l10n.crateLevelUse,
      CrateLevel.edit => l10n.crateLevelEdit,
      CrateLevel.manage => l10n.crateLevelManage,
    };
    final base = levelSwitches(level);
    if (_same(switches, base)) return name;
    if (_same(switches, {...base, CrateSwitches.agent})) return l10n.setupLevelWithAgent(name);
  }
  return _sorted(switches, l10n);
}

/// 'owner' and 'admin' as the app calls them; a role the owners made by
/// its own name.
String setupRoleWords(String role, AppLocalizations l10n) => switch (role) {
      FixedRoles.owner => l10n.orchardRoleOwner,
      FixedRoles.admin => l10n.orchardRoleAdmin,
      _ => role,
    };

List<String> _allowWords(Set<String> allow, AppLocalizations l10n) => [
      if (allow.contains(CrateSwitches.sftp)) l10n.crateAllowSftp,
      if (allow.contains(CrateSwitches.forward)) l10n.crateAllowForward,
      if (allow.contains(CrateSwitches.agent)) l10n.crateAllowAgent,
    ];

List<String> _canWords(Set<String> can, AppLocalizations l10n) => can.isEmpty
    ? [l10n.setupDetailRoleCanNothing]
    : [
        if (can.contains(RoleCan.invite)) l10n.orchardRoleCanInvite,
        if (can.contains(RoleCan.remove)) l10n.orchardRoleCanRemove,
        if (can.contains(RoleCan.changeRoles)) l10n.orchardRoleCanChangeRoles,
        if (can.contains(RoleCan.createCrates)) l10n.orchardRoleCanCreateCrates,
      ];

List<String> _givesWords(Map<String, Set<String>> crates, AppLocalizations l10n, SetupShow show) => crates.isEmpty
    ? [l10n.setupDetailNoCrates]
    : [for (final c in crates.entries) l10n.setupPair(show.crate(c.key), setupLevelWords(c.value, l10n))];

List<String> _extraWords(Map<String, Set<String>> crates, AppLocalizations l10n, SetupShow show) => crates.isEmpty
    ? [l10n.setupDetailNoExtraCrates]
    : [
        for (final c in crates.entries)
          l10n.setupDetailExtraCrate(show.crate(c.key), setupLevelWords(c.value, l10n)),
      ];

String _lockWords(int minutes, AppLocalizations l10n) => minutes == 0
    ? l10n.orchardRulesLockAny
    : minutes % 60 == 0
        ? l10n.orchardRulesLockHours(minutes ~/ 60)
        : l10n.orchardRulesLockMinutes(minutes);

String _offlineWords(int hours, AppLocalizations l10n) =>
    hours == 0 ? l10n.orchardRulesOfflineOff : offlineSpanWords(l10n, hours);

/// [step] in words.
SetupStepWords setupStepWords(SetupStep step, AppLocalizations l10n, {SetupShow show = const SetupShow.asIs()}) {
  switch (step) {
    case AddCrate():
      final name = show.crate(step.name);
      return SetupStepWords(step.ownersOnly ? l10n.setupStepAddCrateOwners(name) : l10n.setupStepAddCrate(name));
    case CrateSettings():
      final parts = step.parts;
      final allow = parts.allow;
      return SetupStepWords(l10n.setupStepCrate(show.crate(step.crate)), [
        if (parts.open) l10n.setupDetailOpenCrate,
        if (allow != null)
          allow.isEmpty ? l10n.setupDetailAllowNothing : l10n.setupDetailAllow(_list(_allowWords(allow, l10n), l10n)),
        if (parts.askAgain != null) l10n.setupPair(l10n.crateConfirmReveal, _onOff(parts.askAgain!, l10n)),
        if (parts.sessionLogs != null) l10n.setupPair(l10n.crateSessionLogs, _onOff(parts.sessionLogs!, l10n)),
        if (parts.watched != null) l10n.setupPair(l10n.crateWatched, _onOff(parts.watched!, l10n)),
        if (parts.unwatchedAway != null)
          l10n.setupPair(l10n.crateUnwatchedAwayLabel,
              parts.unwatchedAway! ? l10n.crateUnwatchedAwayEveryoneChoice : l10n.crateUnwatchedAwayOwnersChoice),
        if (parts.offlineHours != null)
          l10n.setupPair(l10n.orchardRulesOffline, _offlineWords(parts.offlineHours!, l10n)),
        if (step.allowsNothingWithWatching) l10n.setupDetailWatchedTakes,
      ]);
    case AddRole():
      return SetupStepWords(
          l10n.setupStepAddRole(step.name), [..._canWords(step.can, l10n), ..._givesWords(step.crates, l10n, show)]);
    case ChangeRole():
      return SetupStepWords(l10n.setupStepRole(step.name), [
        if (step.can != null) ..._canWords(step.can!, l10n),
        if (step.crates != null) ..._givesWords(step.crates!, l10n, show),
      ]);
    case OrderRoles():
      return SetupStepWords(l10n.setupStepOrderRoles, [_list(step.order, l10n)]);
    case SetRules():
      final parts = step.parts;
      final domains = parts.emailDomains;
      return SetupStepWords(l10n.orchardRulesChange, [
        if (parts.require2fa != null) l10n.setupPair(l10n.orchardRulesTwoStep, _onOff(parts.require2fa!, l10n)),
        if (domains != null)
          l10n.setupPair(
              l10n.orchardRulesDomains,
              domains.isEmpty
                  ? l10n.setupRuleAnyAddress
                  : _list([for (final d in domains.toList()..sort()) show.address(d)], l10n)),
        if (parts.requireAppLock != null) l10n.setupPair(l10n.orchardRulesAppLock, _onOff(parts.requireAppLock!, l10n)),
        if (parts.maxLockMinutes != null)
          l10n.setupPair(l10n.orchardRulesLockWithin, _lockWords(parts.maxLockMinutes!, l10n)),
        if (parts.noExport != null) l10n.setupPair(l10n.orchardRulesNoExport, _onOff(parts.noExport!, l10n)),
        if (parts.offlineHours != null) l10n.setupPair(l10n.orchardRulesOffline, _offlineWords(parts.offlineHours!, l10n)),
        if (parts.reauthDays != null || parts.reauthHours != null)
          l10n.setupPair(
              l10n.orchardRulesReauth,
              reauthSpanWords(
                  l10n, RecordRules.reauthWindow(parts.reauthDays ?? 0, parts.reauthHours ?? 0) ~/ 3600)),
        if (parts.requireSso != null) l10n.setupPair(l10n.orchardRulesRequireSso, _onOff(parts.requireSso!, l10n)),
        if (parts.trustedDevices != null)
          l10n.setupPair(l10n.orchardRulesDevices, _onOff(parts.trustedDevices!, l10n)),
        if (parts.screensSshOnly != null)
          l10n.setupPair(l10n.orchardRulesScreensSshOnly, _onOff(parts.screensSshOnly!, l10n)),
        if (parts.screensLockRedirections != null)
          l10n.setupPair(l10n.orchardRulesScreensNoSharing, _onOff(parts.screensLockRedirections!, l10n)),
      ]);
    case SetRecords():
      final parts = step.parts;
      return SetupStepWords(l10n.setupStepRecords, [
        if (parts.history != null) l10n.setupPair(l10n.trackingHistoryTitle, _onOff(parts.history!, l10n)),
        if (parts.activity != null) l10n.setupPair(l10n.trackingActivityTitle, _onOff(parts.activity!, l10n)),
        if (parts.devices != null) l10n.setupPair(l10n.trackingDevicesTitle, _onOff(parts.devices!, l10n)),
        if (parts.ips != null) l10n.setupPair(l10n.trackingIpsTitle, _onOff(parts.ips!, l10n)),
        if (step.endsEventExport) l10n.setupDetailEndsExport,
      ]);
    case ChangeMember():
      final until = step.until;
      return SetupStepWords(l10n.setupStepMember(show.person(step.email)), [
        if (step.role != null) l10n.setupDetailRole(setupRoleWords(step.role!, l10n)),
        if (step.crates != null) ..._extraWords(step.crates!, l10n, show),
        if (until != null) until.value == null ? l10n.setupDetailNoEnd : l10n.setupDetailUntil(show.time(until.value!, l10n)),
        if (step.dropsExtraCrates) l10n.setupDetailDropsExtra,
        if (step.dropsLimits) l10n.setupDetailDropsLimits,
      ]);
    case LimitMember():
      // Held to a level, the Crate taken away, or the limit lifted.
      final email = show.person(step.email);
      final crate = show.crate(step.crate);
      final switches = step.switches;
      return SetupStepWords(switches == null
          ? l10n.setupStepLimitLift(email, crate)
          : switches.isEmpty
              ? l10n.setupStepLimitNone(crate, email)
              : l10n.setupStepLimit(email, crate, setupLevelWords(switches, l10n)));
    case Invite():
      final role = setupRoleWords(step.role, l10n);
      final email = show.person(step.email);
      return SetupStepWords(
        step.again ? l10n.setupStepInviteAgain(email, role) : l10n.setupStepInvite(email, role),
        [
          if (step.crates.isNotEmpty) ..._extraWords(step.crates, l10n, show),
          if (step.until != null) l10n.setupDetailUntil(show.time(step.until!, l10n)),
        ],
      );
    case AddGroup():
      return SetupStepWords(l10n.setupStepAddGroup(show.group(step.name), show.crate(step.crate)));
    case AddHost():
      return SetupStepWords(l10n.setupStepAddHost(show.host(step.name), show.crate(step.crate)), [
        '${step.protocol} ${show.address('${step.address}:${step.port}')}',
        if (step.key != null) l10n.setupDetailKey(show.key(step.key!)),
        if (step.accounts.isNotEmpty) l10n.setupDetailAccounts(_accounts(step.accounts, l10n, show)),
        if (step.group != null) l10n.setupDetailGroup(show.group(step.group!)),
        if (step.tags.isNotEmpty) l10n.setupDetailTags(_sorted(step.tags, l10n)),
      ]);
    case ChangeHost():
      final key = step.key, accounts = step.accounts, group = step.group, tags = step.tags;
      return SetupStepWords(l10n.setupStepHost(show.host(step.name), show.crate(step.crate)), [
        if (step.address != null) l10n.setupPair(l10n.zestHostFieldAddress, show.address(step.address!)),
        if (step.port != null) l10n.setupPair(l10n.zestHostFieldPort, '${step.port}'),
        if (step.protocol != null) l10n.setupPair(l10n.zestHostFieldProtocol, step.protocol!),
        if (key != null) key.value == null ? l10n.setupDetailNoKey : l10n.setupDetailKey(show.key(key.value!)),
        if (accounts != null)
          accounts.isEmpty ? l10n.setupDetailNoAccounts : l10n.setupDetailAccounts(_accounts(accounts, l10n, show)),
        if (group != null)
          group.value == null ? l10n.setupDetailNoGroup : l10n.setupDetailGroup(show.group(group.value!)),
        if (tags != null) tags.isEmpty ? l10n.setupDetailNoTags : l10n.setupDetailTags(_sorted(tags, l10n)),
      ]);
  }
}

/// Why the Orchard's record refuses a step: [reason] is the record's own
/// word for it.
String setupRefusalWords(String reason, AppLocalizations l10n) => switch (reason) {
      'not allowed to add that Crate' => l10n.setupRefusedAddCrate,
      'only owners mark a Crate owners-only' => l10n.setupRefusedOwnersOpen,
      'changing a Crate needs manage' => l10n.setupRefusedNeedsManage,
      'only owners set session logs' => l10n.setupRefusedLogsOwners,
      'only owners set watched sessions' => l10n.setupRefusedWatchedOwners,
      "only owners set a Crate's offline limit" => l10n.setupRefusedCrateOfflineOwners,
      'a watched Crate allows the terminal only' => l10n.crateWatchedTerminalOnly,
      'only owners set the rules' => l10n.orchardRulesOwnersOnly,
      'a lock timeout needs the app lock' => l10n.setupRefusedLockNeedsAppLock,
      'two approved devices among the owners first' => l10n.deviceErrorTwoOwners,
      'not from an approved device' => l10n.deviceErrorNotApproved,
      'only owners set what the team records' => l10n.setupRefusedRecordsOwners,
      'only owners change roles' => l10n.setupRefusedRolesOwners,
      'no such Crate, or owners-only' => l10n.setupRefusedOwnersOnlyCrate,
      'only people below you' => l10n.setupRefusedBelowYou,
      'only owners make owners and admins' || 'only owners add owners and admins' => l10n.setupRefusedMakeOwners,
      'not allowed to give that role' || 'not allowed to add someone in that role' => l10n.setupRefusedThatRole,
      'giving a Crate needs manage on it' => l10n.setupRefusedGiveNeedsManage,
      'owners and admins need no extra Crate' => l10n.setupRefusedAdminNoExtra,
      'owners do not end' => l10n.setupRefusedOwnersNoEnd,
      'hands out more than they have' => l10n.setupRefusedMoreThanOwn,
      'owners and admins have no limits' => l10n.setupRefusedAdminNoLimits,
      'limiting a Crate needs manage on it' => l10n.setupRefusedLimitNeedsManage,
      _ => l10n.setupRefusedOther(reason),
    };

/// Why the record refuses a member's limit: as for any step, in the words
/// of a limit where the record gives the same reason for other entries (a
/// Crate that is owners-only).
String _limitRefusalWords(String reason, AppLocalizations l10n) =>
    reason == 'no such Crate, or owners-only' ? l10n.setupRefusedLimitOwnersOnly : setupRefusalWords(reason, l10n);

/// What stands in the way, in words.
String setupProblemWords(SetupProblem p, AppLocalizations l10n, {SetupShow show = const SetupShow.asIs()}) {
  final subject = p.subject ?? '';
  final other = p.other ?? '';
  final count = p.count ?? 0;
  return switch (p.kind) {
    SetupProblemKind.otherOrchard => l10n.setupProblemOtherOrchard(show.orchard(subject), show.orchard(other)),
    SetupProblemKind.ambiguousCrate => p.other == null
        ? l10n.setupProblemAmbiguousCrate(show.crate(subject))
        : l10n.setupProblemAmbiguousCrateBy(show.crate(subject), show.any(other)),
    SetupProblemKind.crateMayExist => l10n.setupProblemCrateMayExist(show.crate(subject), count),
    SetupProblemKind.cannotCloseCrate => l10n.setupProblemCannotCloseCrate(show.crate(subject)),
    SetupProblemKind.tooManyCrates => l10n.setupProblemTooManyCrates(show.crate(subject), count),
    SetupProblemKind.noSuchCrate => l10n.setupProblemNoSuchCrate(show.crate(subject), show.any(other)),
    SetupProblemKind.ambiguousRole => p.other == null
        ? l10n.setupProblemAmbiguousRole(subject)
        : l10n.setupProblemAmbiguousRoleBy(subject, show.person(other)),
    SetupProblemKind.roleMayExist => l10n.setupProblemRoleMayExist(subject, count),
    SetupProblemKind.tooManyRoles => l10n.setupProblemTooManyRoles(subject, count),
    SetupProblemKind.noSuchRole => l10n.setupProblemNoSuchRole(subject, show.person(other)),
    SetupProblemKind.ambiguousHost => l10n.setupProblemAmbiguousHost(show.host(subject), show.crate(other)),
    SetupProblemKind.hostNeedsAddress => l10n.setupProblemHostNeedsAddress(show.host(subject), show.crate(other)),
    SetupProblemKind.ftpsHost => l10n.setupProblemFtpsHost(show.host(subject), show.crate(other)),
    SetupProblemKind.notFtpsHost => l10n.setupProblemNotFtpsHost(show.host(subject), show.crate(other)),
    SetupProblemKind.screenHost => l10n.setupProblemScreenHost(show.host(subject), show.crate(other)),
    SetupProblemKind.cannotAddHosts => l10n.setupProblemCannotAddHosts(show.crate(subject)),
    SetupProblemKind.cannotEditHosts => l10n.setupProblemCannotEditHosts(show.crate(subject)),
    SetupProblemKind.noSuchKey => l10n.setupProblemNoSuchKey(show.key(subject), show.host(other)),
    SetupProblemKind.ambiguousKey => l10n.setupProblemAmbiguousKey(show.key(subject), show.host(other)),
    SetupProblemKind.watchedKeyElsewhere => l10n.setupProblemWatchedKey(show.key(subject), show.host(other)),
    SetupProblemKind.ambiguousGroup => l10n.setupProblemAmbiguousGroup(show.group(subject), show.host(other)),
    SetupProblemKind.ownMembership => l10n.setupProblemOwnMembership(show.person(subject)),
    SetupProblemKind.compareFirst => l10n.setupProblemCompareFirst(show.person(subject)),
    SetupProblemKind.untilPassed => l10n.setupProblemUntilPassed(show.person(subject)),
    SetupProblemKind.untilTooFar => l10n.setupProblemUntilTooFar(show.person(subject)),
    SetupProblemKind.guestNeedsEnd => l10n.setupProblemGuestNeedsEnd(show.person(subject)),
    SetupProblemKind.guestOwnersOnly => '${show.person(subject)}: ${l10n.orchardGuestOwnersOnly}',
    SetupProblemKind.cannotInvite => l10n.setupProblemCannotInvite(show.person(subject)),
    SetupProblemKind.inviteNeedsRole => l10n.setupProblemInviteNeedsRole(show.person(subject)),
    SetupProblemKind.inviteeOutsideDomains => l10n.setupProblemOutsideDomains(show.person(subject)),
    SetupProblemKind.limitsNeedMember => l10n.setupProblemLimitsNeedMember(show.person(subject)),
    SetupProblemKind.rulesLeaveYouOut => l10n.orchardRulesOwnDomain(subject.isEmpty ? '?' : show.address(subject)),
    SetupProblemKind.keysNotTrusted => l10n.setupProblemKeysNotTrusted(show.person(subject)),
    // The step, and that it waits for the version that reads it everywhere.
    SetupProblemKind.notYet => l10n.setupPair(p.step == null ? '' : setupStepWords(p.step!, l10n, show: show).title,
        l10n.vaultAccessNotYet(kNewRecordKindsVersion)),
    SetupProblemKind.refused => l10n.setupPair(
        p.step == null ? '' : setupStepWords(p.step!, l10n, show: show).title,
        p.step is LimitMember ? _limitRefusalWords(p.reason ?? '', l10n) : setupRefusalWords(p.reason ?? '', l10n)),
  };
}

/// What a file leaves alone, or what to know before applying it.
String setupNoteWords(SetupNote n, AppLocalizations l10n, {SetupShow show = const SetupShow.asIs()}) {
  final subject = n.subject ?? '';
  return switch (n.kind) {
    SetupNoteKind.crateNotInFile => l10n.setupNoteCrate(show.crate(subject)),
    SetupNoteKind.roleNotInFile => l10n.setupNoteRole(subject),
    SetupNoteKind.memberNotInFile => l10n.setupNoteMember(show.person(subject)),
    SetupNoteKind.invitationNotInFile => l10n.setupNoteInvitation(show.person(subject)),
    SetupNoteKind.hostsNotInFile =>
      l10n.setupNoteHosts(show.crate(subject), _list([for (final h in n.names) show.host(h)], l10n)),
    SetupNoteKind.cratesClosed => l10n.setupNoteClosed(n.count ?? 0),
    SetupNoteKind.invited => l10n.setupNoteInvited(show.person(subject)),
    SetupNoteKind.acceptedWaiting => l10n.setupNoteAccepted(show.person(subject)),
    SetupNoteKind.manyInvitations => l10n.setupNoteManyInvitations(n.count ?? 0, kInvitationsPerHour),
    SetupNoteKind.thisDeviceRules => l10n.setupNoteThisDevice,
    SetupNoteKind.outsideDomains => l10n.setupNoteOutsideDomains(_list([for (final e in n.names) show.person(e)], l10n)),
    SetupNoteKind.outsideDomainsUnseen =>
      l10n.setupNoteOutsideUnseen(_list([for (final e in n.names) show.person(e)], l10n)),
    SetupNoteKind.notReached => l10n.setupNoteNotReached,
  };
}

/// What is wrong with a file, with the place it is at.
String setupFileProblemWords(SetupFileProblem p, AppLocalizations l10n,
    {SetupShow show = const SetupShow.asIs()}) {
  final place = show.any(p.path);
  return switch (p.fault) {
    SetupFileFault.tooBig => l10n.setupFileTooBig,
    SetupFileFault.notJson => p.line == null || p.column == null
        ? l10n.setupFileNotJson
        : l10n.setupFileNotJsonAt(p.line!, p.column!),
    SetupFileFault.notSetupFile => l10n.setupFileNotSetup,
    SetupFileFault.newerVersion => l10n.setupFileNewer(p.value ?? ''),
    SetupFileFault.unknownField => l10n.setupFileUnknownField(place),
    SetupFileFault.secretField => l10n.setupFileSecretField(place),
    SetupFileFault.duplicateField => l10n.setupFileDuplicateField(place),
    SetupFileFault.wrongKind => switch (p.kind) {
        SetupKind.number => l10n.setupFileWrongNumber(place),
        SetupKind.yesNo => l10n.setupFileWrongYesNo(place),
        SetupKind.list => l10n.setupFileWrongList(place),
        SetupKind.object => l10n.setupFileWrongObject(place),
        SetupKind.textOrNothing => l10n.setupFileWrongTextOrNothing(place),
        SetupKind.level => l10n.setupFileWrongLevel(place),
        SetupKind.limit => l10n.setupFileWrongLimit(place),
        SetupKind.text || null => l10n.setupFileWrongText(place),
      },
    SetupFileFault.missing => l10n.setupFileMissing(place),
    SetupFileFault.empty => l10n.setupFileEmpty(place),
    SetupFileFault.tooLong => l10n.setupFileTooLong(place, p.max ?? 0),
    SetupFileFault.tooMany => l10n.setupFileTooMany(place, p.max ?? 0),
    SetupFileFault.outOfRange => l10n.setupFileOutOfRange(place, p.min ?? 0, p.max ?? 0),
    SetupFileFault.notOneOf => l10n.setupFileNotOneOf(place, _list(p.allowed, l10n)),
    SetupFileFault.duplicate => l10n.setupFileDuplicate(place, show.any(p.value ?? '')),
    SetupFileFault.reservedRole => l10n.setupFileReservedRole(place),
    SetupFileFault.notADomain => l10n.setupFileNotADomain(place),
    SetupFileFault.notAnAddress => l10n.setupFileNotAnAddress(place),
    SetupFileFault.notATime => l10n.setupFileNotATime(place),
    SetupFileFault.needsConnect => l10n.setupFileNeedsConnect(place),
    SetupFileFault.oddCharacters => l10n.setupFileOddCharacters(place),
    SetupFileFault.watchedAllows => l10n.setupFileWatchedAllows(place),
  };
}

/// What an exported file leaves out, and why.
String setupLeftOutWords(SetupLeftOut x, AppLocalizations l10n, {SetupShow show = const SetupShow.asIs()}) {
  final count = x.count ?? 0;
  final names = _list([for (final n in x.names) show.any(n)], l10n);
  return switch (x.kind) {
    SetupLeftOutKind.closedCrates => l10n.setupLeftOutClosedCrates(count),
    SetupLeftOutKind.sharedNames => l10n.setupLeftOutSharedNames(names),
    SetupLeftOutKind.unwritableNames => l10n.setupLeftOutUnwritable(count),
    SetupLeftOutKind.otherHosts => l10n.setupLeftOutOtherHosts(count),
    SetupLeftOutKind.unreadRoles => l10n.setupLeftOutUnreadRoles(count),
    SetupLeftOutKind.rolesLikeOwn => l10n.setupLeftOutRolesLikeOwn(names),
    SetupLeftOutKind.partsNotWritten => l10n.setupLeftOutParts(names),
    SetupLeftOutKind.membersWithoutAddress => l10n.setupLeftOutNoAddress(count),
  };
}

/// Why reading the Orchard or applying a step failed, in words.
String setupErrorWords(Object error, AppLocalizations l10n) => switch (error) {
      SetupNameGone() => l10n.setupNameGone(error.name),
      SetupNotOpen() => l10n.setupNotOpen,
      // (Where someone backed out of signing in again, or cannot be asked
      // to: a terminal.)
      OrchardServerException(recentSignInRequired: true) => l10n.setupErrorNeedsSignIn,
      _ => orchardChangeErrorMessage(error, l10n),
    };

/// A whole plan as text: for a terminal, and for what "Copy" copies.
String setupPlanText(SetupPlan plan, AppLocalizations l10n, {SetupShow show = const SetupShow.asIs()}) {
  final lines = <String>[];
  if (plan.problems.isNotEmpty) {
    lines.add(l10n.setupPlanInTheWay(plan.problems.length));
    for (final p in plan.problems) {
      lines.add('  ! ${setupProblemWords(p, l10n, show: show)}');
    }
  }
  if (plan.steps.isEmpty && plan.problems.isEmpty) {
    lines.add(l10n.setupPlanNothing);
  } else if (plan.steps.isNotEmpty) {
    lines.add(l10n.setupPlanChanges(plan.steps.length));
    for (final s in plan.steps) {
      final words = setupStepWords(s, l10n, show: show);
      lines.add('  + ${words.title}');
      for (final d in words.details) {
        lines.add('      $d');
      }
    }
  }
  if (plan.notes.isNotEmpty) {
    lines.add(l10n.setupPlanNotesTitle);
    for (final n in plan.notes) {
      lines.add('  - ${setupNoteWords(n, l10n, show: show)}');
    }
  }
  return lines.join('\n');
}
