import 'dart:async';
import 'package:flutter/foundation.dart' show setEquals;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/features/orchards/record/local_record.dart' show kServerBehindStatus, kUnlistedStatus;
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/move/item_transfer.dart' show SavePlace, TransferKinds, TransferMode;
import 'package:zestssh/features/orchards/move/move_copy_dialog.dart' show itemTransferProvider, transferWhy;
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/rules/crate_offline.dart' show CrateClosedOffline;
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart' show accessTimeText;
import 'package:zestssh/features/orchards/team/join_readiness.dart' show readyToJoin;
import 'package:zestssh/features/orchards/team/team_sync_offer.dart' show offerTeamSync;
import 'package:zestssh/services/sync/sync_failure.dart' show cloudDeviceLimitWords;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/tree_providers.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/ui/screens/profile/account_sign_in.dart' show signInFromAnywhere;

// The words and actions of spaces (3.0), shared by the
// desktop Tree selector and the mobile switcher: your Tree is your personal
// space, an Orchard is a team space, and Crates are its shared vaults. Each
// name is paired with plain words ("Acme Orchard · Team").

/// Your Tree's name: the one you gave it, else "{first name}'s Tree", else
/// "My Tree" while signed out.
String treeDisplayName(WidgetRef ref, AppLocalizations l10n) {
  final override = ref.watch(treeNameOverrideProvider);
  if (override != null) return override;
  final profile = ref.watch(currentUserProvider);
  if (profile == null) return l10n.treeSelectorMyTree;
  final name = profile.displayName;
  if (name != null && name.isNotEmpty) {
    return l10n.treeSelectorNamedTree(name.split(' ').first);
  }
  final email = profile.email;
  if (email != null && email.isNotEmpty) {
    return l10n.treeSelectorNamedTree(email.split('@').first);
  }
  return l10n.treeSelectorMyTree;
}

/// A team's name as it is shown: "Acme" for a team named "Acme" (it was
/// "Acme Orchard"), or the words for a team with no name.
String orchardDisplayName(String? name, AppLocalizations l10n) {
  if (name == null || name.trim().isEmpty) return l10n.orchardUnnamed;
  return l10n.orchardNamed(name.trim());
}

String crateDisplayName(CrateSummary crate, AppLocalizations l10n) =>
    (crate.name == null || crate.name!.trim().isEmpty) ? l10n.crateUnnamed : crate.name!;

/// A role's name: Owner, Admin, or the name the owners gave a role they
/// made ([names], by role id), opened with the Orchard's key.
String orchardRoleLabel(String role, AppLocalizations l10n, {Map<String, String?> names = const {}}) =>
    switch (role) {
      'owner' => l10n.orchardRoleOwner,
      'admin' => l10n.orchardRoleAdmin,
      _ => names[role] ?? l10n.orchardRoleMember,
    };

/// Held back by the company's directory, as the server lists it.
const String kDirectoryHeldStatus = 'directory-removed';

/// The standings this app knows. Any other a later server sends is an
/// Orchard this account cannot open for now.
const Set<String> kKnownOrchardStatuses = {
  'active', 'suspended', 'ended', 'rules', kDirectoryHeldStatus, kRecoveryWaitStatus, kServerBehindStatus,
  kDeletingStatus, kDeletedStatus, kUnlistedStatus,
};

/// "Team · Admin", or where this account stands when it cannot sync:
/// "Team · Closed until online", "Team · Suspended", "Team · Access ended",
/// "Team · Rules not met", "Team · Not syncing".
String orchardSubtitle(OrchardSummary o, WidgetRef ref, AppLocalizations l10n) => l10n.orchardTeamRole(switch (o) {
      _ when o.closedOffline => l10n.orchardClosedOfflineShort,
      _ when o.status == kRecoveryWaitStatus => l10n.orchardWaitingRecoveryShort,
      _ when o.status == kServerBehindStatus => l10n.orchardServerBehindShort,
      _ when o.status == kUnlistedStatus => l10n.orchardUnlistedShort,
      // Being deleted, or deleted.
      _ when o.status == kDeletingStatus => l10n.orchardBeingDeletedShort,
      _ when o.status == kDeletedStatus => l10n.orchardDeletedShort,
      _ when o.status == 'suspended' => l10n.orchardMemberSuspended,
      _ when o.status == 'ended' => l10n.orchardMemberEnded,
      _ when o.status == kDirectoryHeldStatus => l10n.directoryHeld,
      _ when !kKnownOrchardStatuses.contains(o.status) => l10n.orchardNotSyncing,
      _ when unmetRulesOf(ref, o).isNotEmpty => l10n.orchardRulesNotMet,
      _ when o.recordProblem != null => l10n.orchardNotSyncing,
      // Its own offline limit is about to close all of it here: when.
      _ when o.closesAt != null => l10n.offlineClosesShort(accessTimeText(o.closesAt!, l10n)),
      _ => orchardRoleLabel(o.role, l10n, names: orchardRoleNames(ref, o.id)),
    });

/// The rules of [o] this account or this device falls short of (3.0):
/// the server's while it holds the account back, then this device's
/// (its app lock). [watch] rebuilds the caller when they change (in build).
List<UnmetRule> unmetRulesOf(WidgetRef ref, OrchardSummary o, {bool watch = true}) {
  final lock = (watch ? ref.watch(deviceLockProvider) : ref.read(deviceLockProvider)).valueOrNull;
  return [
    if (o.status == 'rules')
      for (final name in o.rulesUnmet) ?UnmetRule.fromServer(name),
    if (lock != null) ...deviceUnmet(o.rules, lockOn: lock.on, lockMinutes: lock.minutes),
  ];
}

/// Rules as the server names them ('two_step', 'email_domain', 'reauth'),
/// in words, joined: "two-step sign-in and a recent sign-in".
String orchardRuleNames(List<String> names, AppLocalizations l10n) {
  final words = [
    for (final n in names)
      switch (UnmetRule.fromServer(n)) {
        UnmetRule.twoStep => l10n.orchardRuleNameTwoStep,
        UnmetRule.emailDomain => l10n.orchardRuleNameEmailDomain,
        UnmetRule.reauth => l10n.orchardRuleNameReauth,
        UnmetRule.sso => l10n.orchardRuleNameSso,
        UnmetRule.trustedDevice => l10n.orchardRuleNameTrustedDevice,
        _ => n,
      },
  ];
  return words.join(', ');
}

/// The names of an Orchard's roles by id, as far as they are on this device.
Map<String, String?> orchardRoleNames(WidgetRef ref, String orchardId) => {
      for (final r in ref.watch(orchardRolesProvider(orchardId)).valueOrNull ?? const <OrchardRoleView>[])
        r.id: r.name,
    };

/// What is said of an Orchard that its offline limit closed on this device.
/// It opens again when the device reaches ZestSSH Cloud. Where the service
/// is the one that cannot be reached ([reach]: down, not responding, or
/// answering with a fault), "connect to the internet" would send the person
/// looking for a fault that is not theirs: they are told that nothing needs
/// doing and that it opens again by itself.
String orchardClosedOfflineText(AppLocalizations l10n, CloudReach? reach) => switch (reach) {
      CloudReach.down || CloudReach.notResponding || CloudReach.fault => l10n.orchardClosedOfflineCloud,
      _ => l10n.orchardClosedOfflineError,
    };

/// What went wrong, in words a person can act on.
String orchardErrorMessage(Object error, AppLocalizations l10n) {
  if (error is AccountKeysNotReady) return l10n.orchardErrorKeysNotReady;
  if (error is OrchardClosedOffline) return orchardClosedOfflineText(l10n, currentCloudReach?.state.value.reach);
  // A Crate closed on this device by its own offline limit says so itself.
  if (error is CrateClosedOffline) return error.message;
  if (error is DeviceCannotBeNamed) return l10n.deviceAskCannot;
  if (error is DeviceRequestGone) return l10n.deviceRequestGone;
  if (error is OrchardServerException) {
    if (error.status == 401) return l10n.orchardErrorSignedOut;
    if (error.deviceNotApproved || error.code == 'device-not-approved') return l10n.deviceErrorNotApproved;
    if (error.rulesUnmet) return l10n.orchardErrorRulesUnmet;
    // No keys yet, or this device's are behind the account's: sync brings
    // them, then trying again works.
    if (error.code == 'no-keys' || error.code == 'stale-account-keys') {
      return l10n.orchardErrorKeysNotReady;
    }
    if (error.code == 'orchard-limit' || error.code == 'crate-limit') {
      return l10n.orchardErrorLimit;
    }
    // ZestSSH Cloud syncs a team's vaults on up to 7 devices for each seat.
    if (error.code == 'cloud-device-limit') return cloudDeviceLimitWords(l10n);
    // Seats and Business.
    if (error.code == 'seats-full') return l10n.orchardSeatsFull;
    if (error.code == 'seats-needed') {
      return error.reason == 'storage'
          ? ErrorCodes.withCode(l10n.orchardVaultsFull, ErrorCodes.teamVaultsFull)
          : l10n.orchardSeatsNeeded;
    }
    // What a team keeps on ZestSSH Cloud follows its seats.
    if (error.code == 'record-full') return ErrorCodes.withCode(l10n.orchardRecordFull, ErrorCodes.teamRecordFull);
    if (error.code == 'record-entry-too-large') {
      return ErrorCodes.withCode(l10n.orchardRecordEntryTooLarge, ErrorCodes.teamRecordEntryTooLarge);
    }
    if (error.code == 'session-logs-team-full') return l10n.orchardSessionLogsFullBody;
    if (error.code == 'business-services-required') return l10n.orchardServicesRequired;
    // Too many requests from this account for now (the team routes allow so
    // many an hour): said as sync says it, where it was a status the app did
    // not expect.
    if (error.status == 429) return l10n.syncCloudTooMany;
    // The route is there and what it was asked about is not (removed, or
    // lost when ZestSSH Cloud was restored from a backup); a 404 without
    // the code is a server with teams switched off.
    if (error.status == 404 && error.code == 'not-found') return l10n.orchardErrorGone;
    if (error.status == 404) return l10n.orchardErrorUnavailable;
  }
  // ZestSSH Cloud, or the way to it: the device offline, the service not
  // responding, a connection that could not be made secure, a fault of the
  // service's own. Each is said as what it is, with its code (until this
  // was held the first three were one "couldn't be reached", and the last
  // was "Something went wrong" followed by the name of a class).
  final cloud = cloudFailureOf(error, status: error is OrchardServerException ? error.status : null);
  if (cloud != null) return cloud.message(l10n);
  // (It was "Something went wrong:" and the error as the program writes it.
  // What failed goes to the log, and to Copy details where a notice has it.)
  if (error is OrchardServerException) return l10n.syncCloudAnswerUnknown(error.status);
  return l10n.orchardErrorNotDone;
}

/// What went wrong reading a team page ([TeamLoadProblem]), in words a
/// person can act on and with a code at the end: the service's own where it
/// was ZestSSH Cloud or the way to it (ZS-1101 to ZS-1107), and
/// [ErrorCodes.teamPageNotLoaded] for anything else.
String teamLoadErrorMessage(Object error, AppLocalizations l10n) {
  final said = orchardErrorMessage(error, l10n);
  return ErrorCodes.codeIn(said) == null ? ErrorCodes.withCode(said, ErrorCodes.teamPageNotLoaded) : said;
}

/// A team page that could not load what it shows, said the app's way: what
/// could not be loaded ([title]), why with its code, Retry and Copy details
/// (the report of the failure, scrubbed). With [stale] it is the notice above
/// what this device holds, which the page shows in its place. As wide as
/// its place: the page around it gives the padding. (Before, the
/// Members page said "The members could not be loaded." alone, at the edge
/// of the page, with the error only in the log.)
class TeamLoadProblem extends StatelessWidget {
  const TeamLoadProblem({
    super.key,
    required this.title,
    required this.error,
    required this.where,
    this.stack,
    this.onRetry,
    this.stale = false,
  });

  /// What could not be loaded, or (with [stale]) what is shown instead.
  final String title;
  final Object error;
  final StackTrace? stack;

  /// What the page was loading, in English, for the report.
  final String where;

  /// Loads it again; no button while that runs (null).
  final VoidCallback? onRetry;

  final bool stale;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final why = teamLoadErrorMessage(error, l10n);
    final tone = zestStatusColor(stale ? ZestStatusKind.warning : ZestStatusKind.critical);
    return Container(
      key: ValueKey(stale ? 'team-load-stale' : 'team-load-failed'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: tone.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(stale ? LucideIcons.cloudOff : LucideIcons.alertCircle, size: 16, color: tone),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.4, color: ZestTokens.textPrimary)),
                const SizedBox(height: 2),
                Text(why,
                    key: const ValueKey('team-load-why'),
                    style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    vaultButton(context,
                        key: const ValueKey('team-load-retry'),
                        label: l10n.retry,
                        icon: LucideIcons.refreshCw,
                        onPressed: onRetry),
                    CopyDetailsButton(
                      key: const ValueKey('team-load-details'),
                      detail: ErrorReport.build(what: '$title $why', where: where, error: error, stack: stack),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// What went wrong with a change to an Orchard (a member, a role, a Crate),
/// in words a person can act on. [nameOf] names a member by account id.
String orchardChangeErrorMessage(Object error, AppLocalizations l10n, {String Function(String uid)? nameOf}) {
  if (error is OutsideSettleStopped) {
    return l10n.orchardOutsideStopped(error.done, error.total, orchardChangeErrorMessage(error.cause, l10n, nameOf: nameOf));
  }
  if (error is OrchardRecordRefused) {
    // Approved devices: what the record refuses has a way out, said.
    return switch (error.reason) {
      'would leave no owner with an approved device' => l10n.deviceErrorLastOwner,
      'two approved devices among the owners first' => l10n.deviceErrorTwoOwners,
      'too many devices' => l10n.deviceErrorTooMany(kMaxMemberDevices),
      'not from an approved device' => l10n.deviceErrorNotApproved,
      // Event export rests on activity being recorded.
      'event export needs activity recorded' => l10n.exportErrorNeedsActivity,
      // Deleting a team: nothing else goes in meanwhile.
      'the team is being deleted' => l10n.orchardErrorBeingDeleted,
      'only owners delete the team' || 'only owners and admins undo deleting the team' => l10n.orchardErrorRefused,
      'not being deleted' => l10n.orchardErrorNotBeingDeleted,
      _ => l10n.orchardErrorRefused,
    };
  }
  if (error is OrchardRoleLimit) return l10n.orchardRoleLimit(kMaxOrchardRoles);
  if (error is MemberKeysNotTrusted) return l10n.orchardErrorKeysNotTrusted(nameOf?.call(error.uid) ?? error.uid);
  if (error is MemberNotCompared) return l10n.orchardPromoteCompareTitle(nameOf?.call(error.uid) ?? error.uid);
  if (error is OrchardInviteError && error.problem == OrchardInviteProblem.missingKeys) {
    return l10n.orchardErrorMissingKeys;
  }
  if (error is OrchardServerException) {
    switch (error.code) {
      case 'record-refused':
      case 'forbidden':
        return l10n.orchardErrorRefused;
      case 'record-moved':
      case 'copies-changed':
      case 'generation-moved':
        return l10n.orchardErrorChanged;
      case 'recipient-keys-changed':
        return l10n.orchardInviteKeysChanged;
      case 'role-limit':
        return l10n.orchardRoleLimit(kMaxOrchardRoles);
      // A new kind of record entry, before it is on.
      case 'feature-not-yet':
        return l10n.orchardErrorFeatureNotYet(kNewRecordKindsVersion);
      // Its first in a team is an owner's.
      case 'first-change-needs-owner':
        return l10n.orchardErrorFirstChangeNeedsOwner;
      case 'rules-unmet-by-you':
        // Company sign-in alone: they sign in through it first.
        final unmet = error.unmet ?? const <String>[];
        if (unmet.length == 1 && unmet.single == 'sso') return l10n.orchardRulesSsoUnmetByYou;
        // Approved devices only: turned on from an approved device.
        if (unmet.length == 1 && unmet.single == kTrustedDeviceRule) return l10n.deviceErrorNotApproved;
        return l10n.orchardRulesUnmetByYou(orchardRuleNames(unmet, l10n));
      case 'invitee-rules-unmet':
        return l10n.orchardInviteeRulesUnmet(orchardRuleNames(error.unmet ?? const [], l10n));
      // Guests: someone outside the Orchard's proven domains.
      case 'guest-owners-only':
        return l10n.orchardGuestOwnersOnly;
      case 'guest-needs-end':
        return l10n.orchardGuestNeedsEnd;
      case 'end-too-far':
        return l10n.orchardEndTooFar;
      // Team recovery: refused, or the member's keys moved on meanwhile.
      case 'team-recovery-off':
      case 'owners-only':
      case 'not-for-yourself':
        return l10n.orchardErrorRefused;
      case 'not-waiting':
        return l10n.orchardErrorChanged;
      // Event export: set up just as activity was turned off.
      case 'activity-off':
        return l10n.exportErrorNeedsActivity;
      // Deleting a team.
      case 'team-being-deleted':
        return l10n.orchardErrorBeingDeleted;
      case 'undo-too-late':
        return l10n.orchardErrorUndoTooLate;
      // An undo that would leave the team with no owner.
      case 'restore-no-owner':
        return l10n.orchardErrorRestoreNoOwner;
      case 'team-not-being-deleted':
        return l10n.orchardErrorNotBeingDeleted;
    }
  }
  return orchardErrorMessage(error, l10n);
}

/// Switches the whole app to [space]. Opening an Orchard's database can
/// fail (a damaged file); the person is told and stays where they were.
Future<void> switchToSpace(BuildContext context, WidgetRef ref, Space space) async {
  try {
    await ref.read(spaceControllerProvider).switchTo(space);
  } catch (e) {
    AppLogger.warning('Spaces: could not open the space ($e)');
    if (context.mounted) {
      showTopSnackBar(context, orchardErrorMessage(e, AppLocalizations.of(context)!), isError: true, details: '$e');
    }
  }
}

/// "Create an Orchard (team)": makes this account's team keys where it has
/// none (sync on or not), asks for the team's name, makes the Orchard with a
/// first Crate, switches to it, and, unless [offerSync] is false, says how
/// sync comes on where it is off. [note] is a line of its own above the
/// seats note (a code that gives the new team seats says so). Returns the
/// new Orchard's id, or null where none was made.
Future<String?> showCreateOrchardDialog(BuildContext context, WidgetRef ref,
    {String? note, bool offerSync = true}) async {
  final l10n = AppLocalizations.of(context)!;
  // A guest signs in first, from here (it said "Sign in to use teams." and
  // nothing more), and goes on to make the team once signed in.
  if (ref.read(currentUserProvider) == null && (!await signInFromAnywhere(context, ref) || !context.mounted)) {
    return null;
  }
  // The team keys first: made here when the account has none, so a new
  // person is never sent to set up sync before they can make a team.
  if (!await readyToJoin(context, ref) || !context.mounted) return null;
  String? createdId;
  final name = await showZestInputDialog(
    context: context,
    title: l10n.orchardCreateTitle,
    // No team is free: each person holds a seat (the first comes with the Bundle).
    subtitle: [l10n.orchardCreateExplainer, ?note, l10n.orchardCreateSeatsNote].join('\n\n'),
    icon: LucideIcons.users,
    fieldLabel: l10n.orchardCreateNameLabel,
    hintText: l10n.orchardCreateNameHint,
    confirmLabel: l10n.orchardCreateButton,
    maxLength: kSpaceNameMaxChars,
    validator: (v) => v.trim().isEmpty ? l10n.manageTreeEnterAName : null,
    onConfirm: (value) async {
      try {
        createdId = await ref
            .read(orchardServiceProvider)
            .createOrchard(value.trim(),
                firstCrateName: l10n.orchardCreateCrateDefault, memberRoleName: l10n.orchardRoleMember);
        return null;
      } catch (e) {
        AppLogger.warning('Orchards: creating an Orchard failed ($e)');
        return orchardErrorMessage(e, l10n);
      }
    },
  );
  final id = createdId;
  if (id == null) return null;
  ref.read(orchardListVersionProvider.notifier).state++;
  if (name == null || !context.mounted) return id;
  await switchToSpace(context, ref, OrchardSpace(id));
  if (!context.mounted) return id;
  showTopSnackBar(context, l10n.orchardCreated(orchardDisplayName(name, l10n)));
  if (offerSync) await offerTeamSync(context, ref, id, owner: true);
  return id;
}

/// "New Crate": adds a Crate to the Orchard. An owner may make it
/// owners-only: no admin or role ever reaches it.
Future<void> showNewCrateDialog(BuildContext context, WidgetRef ref, String orchardId) async {
  final l10n = AppLocalizations.of(context)!;
  final owner = ref.read(orchardSummariesProvider).valueOrNull?.where((o) => o.id == orchardId).firstOrNull?.isOwner ??
      false;
  final name = await showZestModal<String>(
    context: context,
    size: ZestModalSize.compact,
    child: _NewCrateDialog(orchardId: orchardId, ownersOnlyChoice: owner),
  );
  if (name == null || !context.mounted) return;
  ref.read(orchardListVersionProvider.notifier).state++;
  showTopSnackBar(context, l10n.crateCreated(name));
}

class _NewCrateDialog extends ConsumerStatefulWidget {
  const _NewCrateDialog({required this.orchardId, required this.ownersOnlyChoice});

  final String orchardId;
  final bool ownersOnlyChoice;

  @override
  ConsumerState<_NewCrateDialog> createState() => _NewCrateDialogState();
}

class _NewCrateDialogState extends ConsumerState<_NewCrateDialog> {
  final _name = TextEditingController();
  bool _ownersOnly = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final l10n = AppLocalizations.of(context)!;
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = l10n.manageTreeEnterAName);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(orchardServiceProvider).createCrate(widget.orchardId, name, ownersOnly: _ownersOnly);
      if (mounted) Navigator.of(context).pop(name);
    } catch (e) {
      AppLogger.warning('Orchards: creating a Crate failed ($e)');
      if (mounted) {
        setState(() {
          _busy = false;
          _error = orchardChangeErrorMessage(e, l10n);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.package,
      title: l10n.crateNewTitle,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZestTextField(
            key: const ValueKey('crate-name'),
            controller: _name,
            label: l10n.crateNewNameLabel,
            hintText: l10n.crateNewNameHint,
            errorText: _error,
            maxLength: kSpaceNameMaxChars,
            autofocus: true,
            onSubmit: _busy ? null : _create,
          ),
          if (widget.ownersOnlyChoice)
            CheckboxListTile(
              key: const ValueKey('crate-owners-only'),
              value: _ownersOnly,
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(l10n.crateNewOwnersOnly, style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary)),
              subtitle: Text(l10n.crateNewOwnersOnlyHelp,
                  style: TextStyle(fontSize: 11.5, height: 1.35, color: AppColors.v3TextTertiary)),
              onChanged: _busy ? null : (v) => setState(() => _ownersOnly = v ?? false),
            ),
        ],
      ),
      primaryAction: (label: l10n.crateNewButton, onPressed: _busy ? null : _create, icon: LucideIcons.plus),
      secondaryAction: (label: l10n.cancel, onPressed: _busy ? null : () => Navigator.of(context).pop()),
    );
  }
}

/// "Rename the Orchard" (owners and admins): its new name, encrypted with
/// its key, for every member.
Future<void> showRenameOrchardDialog(BuildContext context, WidgetRef ref, OrchardSummary orchard) async {
  final l10n = AppLocalizations.of(context)!;
  final name = await showZestInputDialog(
    context: context,
    title: l10n.orchardRenameTitle(orchardDisplayName(orchard.name, l10n)),
    icon: LucideIcons.pencil,
    fieldLabel: l10n.orchardCreateNameLabel,
    initialValue: orchard.name ?? '',
    confirmLabel: l10n.orchardRenameConfirm,
    maxLength: kSpaceNameMaxChars,
    validator: (v) => v.trim().isEmpty ? l10n.manageTreeEnterAName : null,
    onConfirm: (value) async {
      try {
        await ref.read(orchardServiceProvider).renameOrchard(orchard.id, value.trim());
        return null;
      } catch (e) {
        AppLogger.warning('Orchards: renaming an Orchard failed ($e)');
        return orchardChangeErrorMessage(e, l10n);
      }
    },
  );
  if (name == null || !context.mounted) return;
  ref.read(orchardListVersionProvider.notifier).state++;
  showTopSnackBar(context, l10n.orchardRenamed(orchardDisplayName(name.trim(), l10n)));
}

/// Moves a host to [crate] of the team on screen (a host dropped on a
/// vault's chip) and says where it went: as Move to... moves it, its port
/// forwards with it.
Future<void> moveHostToCrate(
    BuildContext context, WidgetRef ref, String hostId, CrateSummary crate) async {
  final l10n = AppLocalizations.of(context)!;
  final space = ref.read(activeSpaceProvider);
  if (space is! OrchardSpace) return;
  try {
    final transfer = ref.read(itemTransferProvider);
    final plan = await transfer.plan(
      from: space,
      kind: TransferKinds.host,
      keys: [hostId],
      to: SavePlace.vault(space.orchardId, crate.id),
      mode: TransferMode.move,
    );
    final result = await transfer.run(plan);
    if (!context.mounted) return;
    if (result.failed.isNotEmpty) {
      showTopSnackBar(context, transferWhy(l10n, result.failed.first.reason, link: result.failed.first.link), isError: true);
    } else if (result.done > 0) {
      showTopSnackBar(context, l10n.crateMoved(crateDisplayName(crate, l10n)));
    }
  } catch (e) {
    AppLogger.warning('Orchards: moving a host failed (${errorKind(e)})');
    if (context.mounted) {
      showTopSnackBar(context, orchardErrorMessage(e, l10n), isError: true, details: '$e');
    }
  }
}

/// Syncs every Orchard now and says how it went.
Future<void> syncOrchardsNow(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  try {
    await ref.read(orchardSyncProvider).syncAll();
    if (context.mounted) showTopSnackBar(context, l10n.orchardSynced);
  } catch (e) {
    if (context.mounted) {
      showTopSnackBar(context, orchardErrorMessage(e, l10n), isError: true, details: '$e');
    }
  } finally {
    ref.read(orchardListVersionProvider.notifier).state++;
  }
}

/// The longest Orchard or Crate name the dialogs take: 50 characters of up
/// to 4 bytes each stay within the 200 bytes a name may have.
const int kSpaceNameMaxChars = kMaxSpaceNameBytes ~/ 4;

// ── A window that steps aside for the window it opens ────────────────────
//
// A dialog opened from a dialog (a vault's question, its certificate
// settings, a pass) was drawn over it at the same width, the one below
// peeking out at the edges, and on a phone a sheet sat on a sheet. A window
// made with [CoverableWindow] is hidden (kept, not rebuilt) while one opened
// through [overWindow] from inside it is up, and comes back when it closes.

/// Hides [child] while a window opened from inside it by [overWindow] is up.
class CoverableWindow extends StatefulWidget {
  const CoverableWindow({super.key, required this.child});

  final Widget child;

  @override
  State<CoverableWindow> createState() => _CoverableWindowState();
}

class _CoverableWindowState extends State<CoverableWindow> {
  final _covers = _Covers();

  @override
  void dispose() {
    _covers.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _CoverScope(
        covers: _covers,
        child: ValueListenableBuilder<int>(
          valueListenable: _covers,
          builder: (context, covers, child) => Visibility(
            visible: covers == 0,
            maintainState: true,
            maintainAnimation: true,
            child: child!,
          ),
          child: widget.child,
        ),
      );
}

/// How many windows opened from inside a [CoverableWindow] are up, and
/// whether that window is gone: a window opened from it can close after it
/// did (the sheet under it pulled down, the page left), and is then counted
/// by nothing.
class _Covers extends ValueNotifier<int> {
  _Covers() : super(0);

  bool disposed = false;

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

class _CoverScope extends InheritedWidget {
  const _CoverScope({required this.covers, required super.child});

  final _Covers covers;

  @override
  bool updateShouldNotify(_CoverScope old) => old.covers != covers;
}

/// Runs [open] (a dialog, a question, a flow of them) with the nearest
/// [CoverableWindow] above [context] hidden until it is done. Without one,
/// it only runs [open]. Where that window was closed while [open] ran, there
/// is nothing to show again (its count was used after it was gone, which
/// threw where [open] had ended well).
Future<T> overWindow<T>(BuildContext context, Future<T> Function() open) async {
  final covers = context.getInheritedWidgetOfExactType<_CoverScope>()?.covers;
  if (covers == null || covers.disposed) return open();
  covers.value++;
  try {
    return await open();
  } finally {
    if (!covers.disposed) covers.value--;
  }
}

// ── A vault's settings on its card ───────────────────────────────────────
//
// Each of a vault's settings is a row: what it is and a line of help on the
// left, its one control on the right (under the words where there is no
// room, or where the control is a set of chips), the rows of one subject
// under a section header, 12 between rows and 24 between groups.

/// Whether [context] is on a phone: every tap target there is at least 44
/// high.
bool vaultOnPhone(BuildContext context) => zestUsesSheets(context);

/// How a vault's settings are laid out below it: in the Vaults window (4.0),
/// each row's help is one line,
/// with More beside its name for the rest, and the group named by the tab it
/// is in has no header of its own. Elsewhere (Team, Vaults' pane) as before.
class VaultSettingsLayout extends InheritedWidget {
  const VaultSettingsLayout({super.key, this.oneLine = true, this.hiddenTitles = const {}, required super.child});

  /// Each row's help on one line, with More.
  final bool oneLine;

  /// The groups whose header the tab above them already says.
  final Set<String> hiddenTitles;

  static VaultSettingsLayout? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<VaultSettingsLayout>();

  @override
  bool updateShouldNotify(VaultSettingsLayout old) =>
      old.oneLine != oneLine || !setEquals(old.hiddenTitles, hiddenTitles);
}

/// A section of a vault's card: its header, then its rows 12 apart, 24 under
/// the section above it ([first]: 16 under the card's divider).
class VaultSettingGroup extends StatelessWidget {
  const VaultSettingGroup(
      {super.key, required this.title, required this.rows, this.more = const [], this.first = false, this.trailing});

  final String title;
  final List<Widget> rows;

  /// At the end of its header (a link to where it is changed).
  final Widget? trailing;

  /// Rows of a part that decides for itself whether it has any (each puts
  /// its own 12 above it), after [rows].
  final List<Widget> more;
  final bool first;

  @override
  Widget build(BuildContext context) {
    // In a tab of its own name: no header (its link, where it has one, at
    // the end of the first row's place).
    final hidden = VaultSettingsLayout.of(context)?.hiddenTitles.contains(title) ?? false;
    final trailing = this.trailing;
    return Padding(
      padding: EdgeInsets.only(top: hidden ? 4 : (first ? 16 : 24)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!hidden)
            ZestSectionHeader(label: title, trailing: trailing)
          else if (trailing != null)
            Align(alignment: AlignmentDirectional.centerEnd, child: trailing),
          if (hidden && trailing != null) const SizedBox(height: 8),
          for (final (i, row) in rows.indexed) ...[
            if (i > 0) const SizedBox(height: 12),
            row,
          ],
          ...more,
        ],
      ),
    );
  }
}

/// One setting of a vault: [label] and [helper] on the left, [control] on
/// the right, or under them where [below] is set or the row is narrow. In
/// the Vaults window ([VaultSettingsLayout]) the helper is one line, with
/// More beside the label where there is more of it; [full] keeps it whole
/// (what a danger does is never cut).
class VaultSettingRow extends StatefulWidget {
  const VaultSettingRow({
    super.key,
    required this.label,
    this.helper,
    this.helperKey,
    this.helperColor,
    this.control,
    this.below = false,
    this.tooltip,
    this.details = const [],
    this.compact = false,
    this.full = false,
  });

  /// The control is small (a switch, a status): it stays at the end of the
  /// row on a narrow card too.
  final bool compact;

  final String label;
  final String? helper;
  final Key? helperKey;

  /// More lines under the helper (who this account signs in as, a warning).
  final List<Widget> details;

  /// The helper's colour where it says a state (a warning, say).
  final Color? helperColor;
  final Widget? control;
  final bool below;

  /// More about it, on the label.
  final String? tooltip;

  /// The helper whole, in the Vaults window too.
  final bool full;

  @override
  State<VaultSettingRow> createState() => _VaultSettingRowState();
}

class _VaultSettingRowState extends State<VaultSettingRow> {
  bool _more = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final oneLine = !widget.full && (VaultSettingsLayout.of(context)?.oneLine ?? false);
    final helper = widget.helper;
    final helperStyle = TextStyle(fontSize: 12, height: 1.4, color: widget.helperColor ?? ZestTokens.textSecondary);
    final labelText = Text(widget.label,
        style: TextStyle(fontSize: 13, height: 1.35, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary));
    Widget words(double width) {
      // Whether the helper takes more than its one line at [width].
      var longer = false;
      if (oneLine && helper != null && width.isFinite) {
        final painter = TextPainter(
          text: TextSpan(text: helper, style: DefaultTextStyle.of(context).style.merge(helperStyle)),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: width);
        longer = painter.didExceedMaxLines;
        painter.dispose();
      }
      final cut = oneLine && longer && !_more;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (oneLine && longer)
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                labelText,
                _MoreToggle(
                  key: widget.helperKey == null ? null : ValueKey('${(widget.helperKey as ValueKey).value}-more'),
                  open: _more,
                  label: _more ? l10n.vaultRowLess : l10n.vaultRowMore,
                  onTap: () => setState(() => _more = !_more),
                ),
              ],
            )
          else
            labelText,
          if (helper != null) ...[
            const SizedBox(height: 2),
            Text(helper,
                key: widget.helperKey,
                maxLines: cut ? 1 : null,
                overflow: cut ? TextOverflow.ellipsis : null,
                style: helperStyle),
          ],
          for (final d in widget.details) Padding(padding: const EdgeInsets.only(top: 4), child: d),
        ],
      );
    }

    Widget shown(double width) {
      final w = words(width);
      return widget.tooltip == null ? w : Tooltip(message: widget.tooltip!, child: w);
    }

    final control = widget.control;
    return LayoutBuilder(builder: (context, box) {
      if (control == null) return shown(box.maxWidth);
      if (widget.below || (!widget.compact && box.maxWidth < 400)) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [shown(box.maxWidth), const SizedBox(height: 8), control],
        );
      }
      return Row(
        children: [
          // The words' width: the row's, less the control's and the gap's
          // (a guess at the control's, as it is laid out after them).
          Expanded(child: LayoutBuilder(builder: (context, inner) => shown(inner.maxWidth))),
          const SizedBox(width: 16),
          control,
        ],
      );
    });
  }
}

/// "More" beside a setting's name, which shows the rest of its help, and
/// "Less" once it is shown. A button to the keyboard and a screen reader.
class _MoreToggle extends StatelessWidget {
  const _MoreToggle({super.key, required this.open, required this.label, required this.onTap});

  final bool open;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final phone = vaultOnPhone(context);
    return Semantics(
      button: true,
      expanded: open,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(5),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: phone ? 44 : 20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary)),
                const SizedBox(width: 2),
                Icon(open ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 12, color: ZestTokens.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A button on a vault's card or in its windows: as wide as its words, 32
/// high on a computer and 44 on a phone.
Widget vaultButton(
  BuildContext context, {
  Key? key,
  required String label,
  IconData? icon,
  VoidCallback? onPressed,
  ZestButtonVariant variant = ZestButtonVariant.secondary,
  bool isLoading = false,
}) =>
    ConstrainedBox(
      constraints: BoxConstraints(minHeight: vaultOnPhone(context) ? 44 : 32),
      child: IntrinsicWidth(
        child: ZestButton(
          key: key,
          label: label,
          icon: icon,
          onPressed: onPressed,
          variant: variant,
          isLoading: isLoading,
        ),
      ),
    );

/// One explanation under a vault's header, in the tone of its status: what
/// closed it, when it closes, until when a pass holds it open.
class VaultCallout extends StatelessWidget {
  const VaultCallout({super.key, required this.kind, required this.icon, required this.text, this.textKey});

  final ZestStatusKind kind;
  final IconData icon;
  final String text;
  final Key? textKey;

  @override
  Widget build(BuildContext context) {
    final tone = zestStatusColor(kind);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: tone.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 15, color: tone)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                key: textKey, style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textPrimary)),
          ),
        ],
      ),
    );
  }
}

/// A chip of what a vault allows, as everyone reads it: chosen is a brand
/// tint with a check and the words at full contrast; not chosen is a plain
/// outline. [onSelected] null: shown as it is, not to be changed.
class VaultChoiceChip extends StatelessWidget {
  const VaultChoiceChip({super.key, required this.label, required this.selected, this.onSelected, this.avatar});

  final String label;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final Widget? avatar;

  @override
  Widget build(BuildContext context) {
    final phone = vaultOnPhone(context);
    final brand = ZestTokens.brand;
    return FilterChip(
      label: Text(label),
      // The check of a chosen one, at the size of the app's icons (the
      // chip's own checkmark is drawn at the label's height).
      avatar: avatar ?? (selected ? Icon(LucideIcons.check, size: 14, color: ZestTokens.brandInk) : null),
      selected: selected,
      onSelected: onSelected,
      showCheckmark: false,
      labelStyle: TextStyle(
        fontSize: 12,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        color: selected ? ZestTokens.textPrimary : ZestTokens.textSecondary,
      ),
      backgroundColor: Colors.transparent,
      selectedColor: brand.withValues(alpha: 0.12),
      disabledColor: selected ? brand.withValues(alpha: 0.06) : Colors.transparent,
      side: BorderSide(color: selected ? brand.withValues(alpha: 0.6) : ZestTokens.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      visualDensity: VisualDensity.compact,
      // A phone's thumb gets 48 around a chip drawn 32 high.
      materialTapTargetSize: phone ? MaterialTapTargetSize.padded : MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 6),
    );
  }
}

/// What a vault allows, as a member who cannot change it reads it: the
/// allowed ones as plain labels at full contrast.
class VaultStaticChip extends StatelessWidget {
  const VaultStaticChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: ZestTokens.surfaceChip,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: ZestTokens.borderSubtle),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.check, size: 13, color: ZestTokens.textSecondary),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary)),
          ],
        ),
      );
}

/// A link at the end of a section's header: where what it shows is changed
/// ("Settings", "Edit in Roles"), in the accent's ink.
class VaultHeaderLink extends StatelessWidget {
  const VaultHeaderLink({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        link: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: ZestTokens.brandInk)),
          ),
        ),
      );
}

/// The least room a Team page's list keeps beside the panel of what was
/// clicked in it (a member's panel, a vault's pane).
const double kTeamListMinBesidePanel = 300;

/// Whether a panel [panelWidth] wide stands beside the list on a Team page
/// [pageWidth] wide; where it would not, it takes the list's place.
bool teamPanelBeside(double pageWidth, double panelWidth) => pageWidth >= panelWidth + kTeamListMinBesidePanel;

/// A Team page's list and the panel of what was clicked in it: beside the
/// list where the page keeps [kTeamListMinBesidePanel] for it, in the list's
/// place where it would not (at the app's least window, its rail, the Team
/// pages' own list and a pane 420 wide left the list nothing, and the pane
/// ran past the window); the panel's close brings the list back.
class TeamListAndPanel extends StatelessWidget {
  const TeamListAndPanel({super.key, required this.list, required this.panel, required this.panelWidth});

  final Widget list;
  final Widget panel;
  final double panelWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) => teamPanelBeside(box.maxWidth, panelWidth)
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [Expanded(child: list), SizedBox(width: panelWidth, child: panel)],
              )
            : panel,
      );
}
