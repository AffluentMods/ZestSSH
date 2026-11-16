import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/features/orchards/orchard_service.dart' show ActivityKind;
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/team/team_changes.dart';
import 'package:zestssh/features/orchards/watch/unwatched.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';

// What happened in an Orchard, in words: the Team page shows them in the
// person's language, and the device that sends the team's events on (event
// export) writes them in English beside each event. No widgets here.

/// [c] in words, the author left out (the list shows them beside it).
String teamChangeText(
  TeamChange c,
  AppLocalizations l10n, {
  required String Function(String? uid) nameOf,
  required String Function(String? id) crateName,
  required String Function(String id) roleName,
}) {
  final member = nameOf(c.member);
  final role = c.roleId == null ? '' : roleName(c.roleId!);
  return switch (c.kind) {
    TeamChangeKind.created => l10n.teamChangeCreated,
    TeamChangeKind.crateAdded => l10n.teamChangeCrateAdded(crateName(c.crateId)),
    TeamChangeKind.crateSettings => l10n.teamChangeCrateSettings(crateName(c.crateId)),
    TeamChangeKind.roleAdded => l10n.teamChangeRoleAdded(role),
    TeamChangeKind.roleChanged => l10n.teamChangeRoleChanged(role),
    TeamChangeKind.roleDeleted => l10n.teamChangeRoleDeleted,
    TeamChangeKind.memberAdded => l10n.teamChangeMemberAdded(member, role),
    TeamChangeKind.memberAddedAgain => l10n.teamChangeMemberAddedAgain(member, role),
    TeamChangeKind.memberRole => l10n.teamChangeMemberRole(member, role),
    TeamChangeKind.memberSteppedDown => l10n.teamChangeSteppedDown,
    TeamChangeKind.memberAccess => l10n.teamChangeMemberAccess(member),
    TeamChangeKind.memberKeys => l10n.teamChangeMemberKeys,
    TeamChangeKind.memberSuspended => l10n.teamChangeMemberSuspended(member),
    TeamChangeKind.memberResumed => l10n.teamChangeMemberResumed(member),
    TeamChangeKind.memberRemoved => l10n.teamChangeMemberRemoved(member),
    TeamChangeKind.memberLeft => l10n.teamChangeMemberLeft,
    TeamChangeKind.crateKey => l10n.teamChangeCrateKey(crateName(c.crateId)),
    TeamChangeKind.orchardKey => l10n.teamChangeOrchardKey,
    TeamChangeKind.rules => l10n.teamChangeRules,
    TeamChangeKind.teamRecoveryOn => l10n.teamChangeRecoveryOn,
    TeamChangeKind.teamRecoveryOff => l10n.teamChangeRecoveryOff,
    TeamChangeKind.memberRecovered => l10n.teamChangeMemberRecovered(member, nameOf(c.approver)),
    TeamChangeKind.certificateAuthority => l10n.teamChangeCertificateAuthority(crateName(c.crateId)),
    TeamChangeKind.tracking => l10n.teamChangeTracking,
    TeamChangeKind.sessionLogsOn => l10n.teamChangeSessionLogsOn(crateName(c.crateId)),
    TeamChangeKind.sessionLogsOff => l10n.teamChangeSessionLogsOff(crateName(c.crateId)),
    TeamChangeKind.watchedOn => l10n.teamChangeWatchedOn(crateName(c.crateId)),
    TeamChangeKind.watchedOff => l10n.teamChangeWatchedOff(crateName(c.crateId)),
    TeamChangeKind.crateOfflineSet =>
      l10n.teamChangeCrateOfflineSet(crateName(c.crateId), offlineSpanWords(l10n, c.hours ?? 0)),
    TeamChangeKind.crateOfflineOff => l10n.teamChangeCrateOfflineOff(crateName(c.crateId)),
    TeamChangeKind.unwatchedAwayOn => l10n.teamChangeUnwatchedAwayOn(crateName(c.crateId)),
    TeamChangeKind.unwatchedAwayOff => l10n.teamChangeUnwatchedAwayOff(crateName(c.crateId)),
    TeamChangeKind.sessionUnwatched => l10n.teamChangeSessionUnwatched(crateName(c.crateId)),
    TeamChangeKind.accessGiven => l10n.teamChangeAccessGiven(member, crateName(c.crateId)),
    TeamChangeKind.accessEnded => l10n.teamChangeAccessEnded(member, crateName(c.crateId)),
    TeamChangeKind.accessGivenUp => l10n.teamChangeAccessGivenUp(crateName(c.crateId)),
    TeamChangeKind.deviceApproved => l10n.teamChangeDeviceApproved(member),
    TeamChangeKind.deviceApprovedOwn => l10n.teamChangeDeviceApprovedOwn,
    TeamChangeKind.deviceRemoved => l10n.teamChangeDeviceRemoved(member),
    TeamChangeKind.deviceRemovedOwn => l10n.teamChangeDeviceRemovedOwn,
    TeamChangeKind.exportOn => l10n.teamChangeExportOn,
    TeamChangeKind.exportOff => l10n.teamChangeExportOff,
    TeamChangeKind.memberVaultSet =>
      l10n.teamChangeVaultSet(member, crateName(c.crateId), levelWords(c.switches ?? const {}, l10n)),
    TeamChangeKind.memberVaultTaken => l10n.teamChangeVaultTaken(member, crateName(c.crateId)),
    TeamChangeKind.memberVaultBack => l10n.teamChangeVaultBack(member, crateName(c.crateId)),
    TeamChangeKind.adminChanged => l10n.teamChangeAdminChanged,
    TeamChangeKind.adminReset => l10n.teamChangeAdminReset,
    TeamChangeKind.teamDeleted => l10n.teamChangeTeamDeleted,
    TeamChangeKind.teamRestored => l10n.teamChangeTeamRestored,
    TeamChangeKind.other => l10n.teamChangeOther,
  };
}

/// What [switches] in a vault come to, in words: one of the levels (agent
/// forwarding aside, which no level holds), None, or Custom.
String levelWords(Set<String> switches, AppLocalizations l10n) {
  if (switches.isEmpty) return l10n.crateLevelNone;
  final core = {...switches}..remove(CrateSwitches.agent);
  for (final level in CrateLevel.values) {
    final s = levelSwitches(level);
    if (s.length == core.length && s.containsAll(core)) {
      return switch (level) {
        CrateLevel.connect => l10n.crateLevelConnect,
        CrateLevel.use => l10n.crateLevelUse,
        CrateLevel.edit => l10n.crateLevelEdit,
        CrateLevel.manage => l10n.crateLevelManage,
      };
    }
  }
  return l10n.crateLevelCustom;
}

/// How ZestSSH Cloud stood when a session went on with nobody watching, as
/// its report says it ([written]), in a few words with the code Astryx can
/// look up, and the HTTP status where the service answered with a fault.
/// What this app does not know the name of is shown as it was written.
String unwatchedReachWords(String written, AppLocalizations l10n) {
  final state = unwatchedReachRead(written);
  final failure = state == null ? null : cloudFailureOfReach(state);
  if (failure == null) return written;
  final label = failure.label(l10n);
  return ErrorCodes.withCode(failure.status == null ? label : '$label, HTTP ${failure.status}', failure.code);
}

/// A length of time for an offline limit, in words: whole days as days,
/// anything else as hours ("1 day", "8 hours").
String offlineSpanWords(AppLocalizations l10n, int hours) =>
    hours % 24 == 0 ? l10n.orchardRulesOfflineDays(hours ~/ 24) : l10n.orchardRulesOfflineHours(hours);

/// How often members sign in again, in words: off for 0, whole days as
/// days, anything else as hours ("Every 30 days", "Every 8 hours").
String reauthSpanWords(AppLocalizations l10n, int hours) => hours == 0
    ? l10n.orchardRulesReauthOff
    : hours % 24 == 0
        ? l10n.orchardRulesReauthDays(hours ~/ 24)
        : l10n.orchardRulesReauthHours(hours);

/// Under a choice of the team rule Sign-in lasts: what it costs where that shows
/// in a working day of eight hours, and the one recommended;
/// null for the rest.
String? reauthChoiceNote(AppLocalizations l10n, int hours) {
  if (hours == 30 * 24) return l10n.orchardRulesReauthRecommended;
  if (hours <= 0 || hours > 8) return null;
  return hours == 8 ? l10n.orchardRulesReauthCostOne : l10n.orchardRulesReauthCostMany('${8 ~/ hours}');
}

/// What a member did with a Crate's item (activity) in words: [who]
/// did [kind] with [item].
String teamActivityText(ActivityKind kind, AppLocalizations l10n, {required String who, required String item}) =>
    switch (kind) {
      ActivityKind.reveal => l10n.activityRevealed(who, item),
      ActivityKind.copy => l10n.activityCopied(who, item),
      ActivityKind.export => l10n.activityExported(who, item),
      ActivityKind.connect => l10n.activityConnected(who, item),
    };
