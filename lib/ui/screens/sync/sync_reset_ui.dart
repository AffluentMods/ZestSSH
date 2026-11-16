import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/account/sync_reset_flow.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// What the person sees of resetting cloud sync (3.0), and of a device
/// finding the cloud copy gone: the question, the typed confirmation, the
/// progress line and how it ended. The account page puts them together
/// around [SyncResetFlow].

/// Asks whether to reset cloud sync, saying what goes and what stays. With
/// [keysElsewhere], this device does not hold the account's keys for teams,
/// and the question says what that means for where sync is set up again.
Future<bool> askToResetCloudSync(BuildContext context, {required bool keysElsewhere}) async {
  final l10n = AppLocalizations.of(context)!;
  final go = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.destructive,
    title: l10n.syncResetAskTitle,
    body: l10n.syncResetAskBody,
    bullets: [
      l10n.syncResetAskStays,
      l10n.syncResetAskOff,
      l10n.syncResetAskKept,
      if (keysElsewhere) l10n.syncResetAskTeamKeys,
    ],
    confirmLabel: l10n.profileContinue,
  );
  return go == true;
}

/// Has the person type the account's [email] before the reset, as deleting
/// the account does. An account without an email has answered the question
/// already and is not asked again. False when they back out.
Future<bool> confirmSyncResetByEmail(BuildContext context, WidgetRef ref, String? email) async {
  if (email == null || email.isEmpty) return true;
  // The phrase shows the real email and it is typed back: with recording
  // mode on, that is only done once the person turned it off.
  if (!await confirmRevealWhileRecording(context, ref)) return false;
  if (!context.mounted) return false;
  final l10n = AppLocalizations.of(context)!;
  final typed = await showZestInputDialog(
    context: context,
    title: l10n.syncResetTitle,
    subtitle: l10n.syncResetConfirmSubtitle(email),
    icon: LucideIcons.rotateCcw,
    tone: ZestDialogTone.destructive,
    fieldLabel: l10n.accountEmailLabel,
    hintText: email,
    confirmLabel: l10n.syncResetRowAction,
    validator: (v) => v.trim().toLowerCase() == email.toLowerCase() ? null : l10n.accountDeleteEmailMismatch,
  );
  return typed != null;
}

/// The progress line for [stage]. [inBrowser]: the sign-in happens in the
/// browser (a computer without a sign-in of its own).
String syncResetStageText(AppLocalizations l10n, SyncResetStage stage, {required bool inBrowser}) {
  switch (stage) {
    case SyncResetStage.signingIn:
      return inBrowser ? l10n.accountDeleteStepSignInBrowser : l10n.accountDeleteStepSignIn;
    case SyncResetStage.stoppingSync:
      return l10n.accountDeleteStepStoppingSync;
    case SyncResetStage.resetting:
      return l10n.syncResetStepResetting;
    case SyncResetStage.turningOffHere:
      return l10n.syncResetStepTurningOff;
  }
}

/// Why nothing was reset, for [code] of a [SyncResetFailed]. Where ZestSSH
/// Cloud or the way to it was what stopped the request ([cause], see
/// SyncResetFailed.cause), how it stands is said, with its code, after the
/// one thing that matters most here: that nothing was changed.
String syncResetFailureText(AppLocalizations l10n, String code, {Object? cause}) {
  String? stopped() => cause == null ? null : cloudStopped(l10n, cause, lead: l10n.syncResetNothingChanged);
  switch (code) {
    case 'sign-in-failed':
    case 'recent-sign-in-required':
      return l10n.syncResetFailedSignIn;
    case 'account-mismatch':
      return l10n.syncResetWrongAccount;
    case 'server-outdated':
      return l10n.syncResetFailedOutdated;
    case 'network':
      return stopped() ?? l10n.syncResetFailedNetwork;
    default:
      return stopped() ?? l10n.syncResetFailedServer;
  }
}

/// Says how a reset ended. Returns true when sync was reset and the person
/// chose to set it up again now.
Future<bool> showSyncResetOutcome(BuildContext context, SyncResetOutcome outcome, {DateTime? now}) async {
  final l10n = AppLocalizations.of(context)!;
  switch (outcome) {
    case SyncResetCancelled():
      showTopSnackBar(context, l10n.syncResetNothingChanged);
      return false;
    case SyncResetWrongAccount():
      showTopSnackBar(context, l10n.syncResetWrongAccount, isError: true);
      return false;
    case SyncResetFailed(:final code, :final detail, :final cause):
      showTopSnackBar(context, syncResetFailureText(l10n, code, cause: cause), isError: true, details: detail);
      return false;
    case SyncResetDone(:final hadData, :final keptDays):
      final until = (now ?? DateTime.now()).add(Duration(days: keptDays));
      final again = await ZestConfirmDialog.show(
        context,
        // Done: the green tick (3.4).
        tone: ZestDialogTone.success,
        title: l10n.syncResetDoneTitle,
        body: hadData ? l10n.syncResetDoneBody : l10n.syncResetDoneNothing,
        bullets: [
          if (hadData && keptDays > 0)
            l10n.syncResetDoneKept(DateFormat.yMMMd(l10n.localeName).format(until)),
          l10n.syncResetDoneNext,
        ],
        confirmLabel: l10n.accountSyncSetUp,
        cancelLabel: l10n.notNow,
      );
      return again == true;
  }
}

/// A device that thinks sync is set up finds no vault in the store: cloud
/// sync was reset from another device, or the store was emptied. Says so and
/// asks whether to set sync up again here. True when the person chose to.
Future<bool> askToSetUpSyncAgain(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final again = await ZestConfirmDialog.show(
    context,
    // A question, with what happened said plainly: nothing amber (3.4).
    tone: ZestDialogTone.neutral,
    icon: LucideIcons.cloudOff,
    title: l10n.syncGoneTitle,
    body: l10n.syncGoneBody,
    bullets: [l10n.syncGoneHere, l10n.syncGoneOthers],
    confirmLabel: l10n.syncSetUpAgain,
    cancelLabel: l10n.notNow,
  );
  return again == true;
}

/// Why the account was not deleted while a cloud copy Reset cloud sync set
/// aside is kept: until when, the day from which it can be deleted (the
/// server keeps that copy so that a reset made by someone else can be
/// undone, and deleting the account would delete it with it). Without a date
/// (an answer that gave none), the thirty days are said.
String accountDeleteResetKeptText(AppLocalizations l10n, DateTime? keptUntil) => keptUntil == null
    ? l10n.accountDeleteResetKeptNoDate
    : l10n.accountDeleteResetKept(DateFormat.yMMMd(l10n.localeName).format(keptUntil.toLocal()));

/// Why the account was not deleted while [teams], which it alone owns, is
/// being deleted and its admins can still undo that: until when, the day the
/// team goes (found in a security review: an
/// undo would otherwise bring the team back with no owner). Without a date,
/// it is said without one.
String accountDeleteTeamBeingDeletedText(AppLocalizations l10n, String teams, DateTime? keptUntil) => keptUntil == null
    ? l10n.accountDeleteTeamBeingDeletedNoDate(teams)
    : l10n.accountDeleteTeamBeingDeleted(teams, DateFormat.yMMMd(l10n.localeName).format(keptUntil.toLocal()));
