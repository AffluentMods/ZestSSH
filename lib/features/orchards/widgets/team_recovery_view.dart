import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/members/team_recovery.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/team/team_overview.dart' show OneLineParts, shortMemberId;
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/widgets/fingerprint_qr.dart';
import 'package:zestssh/features/orchards/widgets/fingerprint_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/logger.dart';

// Team recovery (3.0) on screen: the owners' switch and who waits
// for it (the Rules page), an owner comparing a waiting member's new words
// before approving or completing, and the member's own words while they
// wait. Both owners compare: the one who completes too, or a single owner
// could approve for someone who is not the member.

/// A waiting member's name as this device shows it.
String recoveryName(WidgetRef ref, RecoveryWait w) =>
    Redactable.account(w.email ?? shortMemberId(w.uid)).displayIn(ref);

/// The Team recovery section: what it does, on or off, the owners' switch,
/// and (for owners) who waits for it.
class TeamRecoveryPanel extends ConsumerStatefulWidget {
  const TeamRecoveryPanel({super.key, required this.orchard, this.onAddOwner});

  final OrchardSummary orchard;

  /// Opens the Members page, where a second owner is made.
  final VoidCallback? onAddOwner;

  @override
  ConsumerState<TeamRecoveryPanel> createState() => _TeamRecoveryPanelState();
}

class _TeamRecoveryPanelState extends ConsumerState<TeamRecoveryPanel> {
  bool _busy = false;

  Future<void> _set(bool on) async {
    final l10n = AppLocalizations.of(context)!;
    final name = orchardDisplayName(widget.orchard.name, l10n);
    final go = await ZestConfirmDialog.show(
      context,
      tone: on ? ZestDialogTone.info : ZestDialogTone.neutral,
      title: on ? l10n.teamRecoveryTurnOnTitle : l10n.teamRecoveryTurnOffTitle,
      body: on ? l10n.teamRecoveryTurnOnBody(name) : l10n.teamRecoveryTurnOffBody(name),
      confirmLabel: on ? l10n.teamRecoveryTurnOn : l10n.teamRecoveryTurnOff,
    );
    if (go != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final done = await withRecentSignIn(
        context,
        ref,
        () => ref.read(orchardServiceProvider).setTeamRecovery(widget.orchard.id, on),
        summary: (what: on ? l10n.stepUpTeamRecoveryOn(name) : l10n.stepUpTeamRecoveryOff(name), effects: const []),
      );
      if (!done || !mounted) return;
      ref.read(orchardListVersionProvider.notifier).state++;
      showTopSnackBar(context, on ? l10n.teamRecoveryTurnedOn : l10n.teamRecoveryTurnedOff, isSuccess: true);
    } catch (e) {
      AppLogger.warning('Team recovery: not changed ($e)');
      if (mounted) showTopSnackBar(context, orchardChangeErrorMessage(e, l10n), isError: true, details: '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final o = widget.orchard;
    final rule = ref.watch(teamRecoveryRuleProvider(o.id)).valueOrNull;
    final on = rule?.on ?? false;
    final owners = rule?.owners ?? 0;
    final waiting = o.isOwner && on
        ? ref.watch(teamRecoveryStatusProvider(o.id)).valueOrNull?.waiting ?? const <RecoveryWait>[]
        : const <RecoveryWait>[];
    final me = ref.watch(teamPeopleProvider(o.id)).valueOrNull?.me;
    // The team pages' card, as the rules beside it: its state in its words
    // and an outlined button at its end, Set up while it is off (turning it
    // on asks, then signs in again: a switch would promise a flip). It had a
    // pill of its own for the state and Turn on at its foot.
    // Then what stops it, and who waits.
    final state = on ? l10n.teamRecoveryStateOn : l10n.teamRecoveryStateOff;
    return TeamCard(
      key: const ValueKey('team-recovery'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TeamCardHeader(
            icon: LucideIcons.lifeBuoy,
            title: l10n.teamRecoveryTitle,
            body: rule == null ? l10n.teamRecoveryBody : '$state${OneLineParts.gap}${l10n.teamRecoveryBody}',
            bodyKey: rule == null ? null : ValueKey('team-recovery-state-${on ? 'on' : 'off'}'),
            trailing: rule == null || !o.isOwner
                ? null
                : teamButton(
                    key: ValueKey('team-recovery-${on ? 'off' : 'on'}'),
                    // Turning it off ends something: in red.
                    kind: on ? TeamButtonKind.danger : TeamButtonKind.secondary,
                    // On needs two owners (the record's rule); off always goes.
                    onPressed: !on && owners < 2 ? null : () => _set(!on),
                    busy: _busy,
                    icon: on ? LucideIcons.powerOff : null,
                    label: on ? l10n.teamRecoveryTurnOff : l10n.teamRecoverySetUp,
                  ),
          ),
          // One owner: off, it cannot be turned on; on (an owner left since),
          // it cannot finish, as a second owner approves it (found in a
          // docs check: nothing said so).
          if (rule != null && owners < 2) ...[
            const SizedBox(height: 16),
            TeamCallout(
              key: ValueKey(on ? 'team-recovery-one-owner-on' : 'team-recovery-needs-owner'),
              tone: TeamTone.warning,
              icon: LucideIcons.crown,
              title: on ? l10n.teamRecoveryOneOwnerOn : l10n.teamRecoveryNeedsTwoOwners,
              action: o.isOwner && widget.onAddOwner != null
                  ? teamButton(
                      key: const ValueKey('team-recovery-add-owner'),
                      label: l10n.teamAddSecondOwner,
                      onPressed: widget.onAddOwner,
                    )
                  : null,
            ),
          ],
          if (waiting.isNotEmpty) ...[
            const SizedBox(height: 20),
            ZestSectionHeader(label: l10n.teamRecoveryWaitingTitle),
            for (final w in waiting)
              _WaitRow(
                key: ValueKey('team-recovery-wait-${w.uid}'),
                name: recoveryName(ref, w),
                state: w.approvals.isEmpty
                    ? l10n.teamRecoveryRowNone
                    : w.approvals.any((a) => a.uid == me)
                        ? l10n.teamRecoveryRowApprovedByYou
                        : l10n.teamRecoveryRowApprovedBy(_approverName(ref, o.id, w.approvals.first.uid)),
                onReview: () => showRecoveryReview(context, ref, o, w),
              ),
          ],
          if (!o.isOwner) ...[
            const SizedBox(height: 16),
            Text(l10n.teamRecoveryOwnersOnly, style: TextStyle(fontSize: 12.5, color: ZestTokens.textSecondary)),
          ],
        ],
      ),
    );
  }
}

/// An owner's name as the Orchard's member list on this device has it.
String _approverName(WidgetRef ref, String orchardId, String uid) {
  final emails = ref.watch(teamRecordProvider(orchardId)).valueOrNull?.emails ?? const <String, String?>{};
  return Redactable.account(emails[uid] ?? shortMemberId(uid)).displayIn(ref);
}

class _WaitRow extends StatelessWidget {
  const _WaitRow({super.key, required this.name, required this.state, required this.onReview});

  final String name;
  final String state;
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          const TeamIconTile(icon: LucideIcons.userCog, tone: TeamTone.warning),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary)),
                Text(state, style: TextStyle(fontSize: 12.5, color: ZestTokens.textSecondary)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          teamButton(label: l10n.teamReview, onPressed: onReview),
        ],
      ),
    );
  }
}

/// What an owner can do about [wait] now: approve (nobody has, or only
/// someone who no longer counts), complete (another owner approved), or
/// take back their own approval.
enum RecoveryStep { approve, complete, withdraw }

/// [wait]'s next step for the owner [me].
RecoveryStep recoveryStepFor(RecoveryWait wait, String? me) {
  if (wait.approvals.any((a) => a.uid != me && a.signature != null)) return RecoveryStep.complete;
  if (wait.approvals.any((a) => a.uid == me)) return RecoveryStep.withdraw;
  return RecoveryStep.approve;
}

/// An owner compares [wait]'s new words with the member, then approves, or
/// completes when another owner approved, or takes back their approval.
Future<void> showRecoveryReview(BuildContext context, WidgetRef ref, OrchardSummary orchard, RecoveryWait wait) async {
  final l10n = AppLocalizations.of(context)!;
  final people = ref.read(teamPeopleProvider(orchard.id)).valueOrNull;
  final me = people?.me;
  final mine = people?.members.where((m) => m.isMe).firstOrNull?.trust?.fingerprint;
  final name = recoveryName(ref, wait);
  final orchardName = orchardDisplayName(orchard.name, l10n);
  final step = recoveryStepFor(wait, me);
  final approver = wait.approvals.where((a) => a.uid != me && a.signature != null).firstOrNull;
  final go = await ZestDialogShell.showModal<bool>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.neutral,
    icon: LucideIcons.lifeBuoy,
    title: l10n.recoveryReviewTitle(name),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.recoveryReviewIntro(name),
            style: TextStyle(fontSize: 13, height: 1.45, color: AppColors.v3TextPrimary)),
        const SizedBox(height: 12),
        CompareCodes(
          key: const ValueKey('recovery-compare'),
          theirs: wait.keys.fingerprint,
          name: name,
          mine: mine,
          // A scanned code that matches is as good as saying so.
          onScanMatch: step == RecoveryStep.withdraw ? null : () => Navigator.of(context).pop(true),
        ),
        const SizedBox(height: 12),
        Text(
          switch (step) {
            RecoveryStep.approve => l10n.recoveryReviewApproveBody,
            RecoveryStep.complete => l10n.recoveryReviewCompleteBody(_approverName(ref, orchard.id, approver!.uid), name),
            RecoveryStep.withdraw => l10n.recoveryReviewYouApproved,
          },
          key: const ValueKey('recovery-step'),
          style: TextStyle(fontSize: 12.5, height: 1.45, color: AppColors.v3TextSecondary),
        ),
        const SizedBox(height: 6),
        Text(l10n.recoveryReviewNoMatch(name),
            style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.statusWarning)),
      ],
    ),
    primaryAction: (
      label: switch (step) {
        RecoveryStep.approve => l10n.recoveryApprove,
        RecoveryStep.complete => l10n.recoveryComplete,
        RecoveryStep.withdraw => l10n.recoveryWithdraw,
      },
      onPressed: () => Navigator.of(context).pop(true),
      icon: step == RecoveryStep.withdraw ? LucideIcons.undo2 : LucideIcons.check,
    ),
    secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop(false)),
  );
  if (go != true || !context.mounted) return;
  final service = ref.read(orchardServiceProvider);
  try {
    switch (step) {
      case RecoveryStep.approve:
        final done = await withRecentSignIn(context, ref, () => service.approveRecovery(orchard.id, wait),
            summary: (what: l10n.stepUpRecoveryApprove(name), effects: const []));
        if (!done || !context.mounted) return;
        showTopSnackBar(context, l10n.recoveryApproved(name), isSuccess: true);
      case RecoveryStep.complete:
        final done = await withRecentSignIn(context, ref, () => service.completeRecovery(orchard.id, wait),
            summary: (what: l10n.stepUpRecoveryComplete(name, orchardName), effects: const []));
        if (!done || !context.mounted) return;
        showTopSnackBar(context, l10n.recoveryCompleted(name), isSuccess: true);
      case RecoveryStep.withdraw:
        await service.withdrawRecoveryApproval(orchard.id, wait.uid);
        if (!context.mounted) return;
        showTopSnackBar(context, l10n.recoveryWithdrawn, isSuccess: true);
    }
  } catch (e) {
    AppLogger.warning('Team recovery: $step did not go through ($e)');
    if (context.mounted) showTopSnackBar(context, orchardChangeErrorMessage(e, l10n), isError: true, details: '$e');
  } finally {
    ref.read(orchardListVersionProvider.notifier).state++;
  }
}

/// The member who waits: their new words to read to two owners (or show as
/// a code), and how far the owners got.
Future<void> showRecoveryWait(BuildContext context, WidgetRef ref, OrchardSummary orchard) async {
  final l10n = AppLocalizations.of(context)!;
  final me = await ref.read(orchardAuthorProvider).call();
  if (me == null || !context.mounted) return;
  final mine = (await me.keys.publish(me.uid)).fingerprint;
  if (!context.mounted) return;
  await ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.info,
    icon: LucideIcons.fingerprint,
    title: l10n.recoveryWaitTitle,
    body: _RecoveryWaitBody(orchard: orchard, fingerprint: mine),
    primaryAction: (label: l10n.close, onPressed: () => Navigator.of(context).pop(), icon: null),
  );
}

class _RecoveryWaitBody extends ConsumerStatefulWidget {
  const _RecoveryWaitBody({required this.orchard, required this.fingerprint});

  final OrchardSummary orchard;
  final Uint8List fingerprint;

  @override
  ConsumerState<_RecoveryWaitBody> createState() => _RecoveryWaitBodyState();
}

class _RecoveryWaitBodyState extends ConsumerState<_RecoveryWaitBody> {
  bool _qr = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final name = orchardDisplayName(widget.orchard.name, l10n);
    final rule = ref.watch(teamRecoveryRuleProvider(widget.orchard.id)).valueOrNull;
    final status = ref.watch(teamRecoveryStatusProvider(widget.orchard.id));
    // The server lists a member who is no owner only their own wait.
    final approvals = status.valueOrNull?.waiting.firstOrNull;
    final String line;
    if (rule != null && !rule.on) {
      line = l10n.recoveryWaitOff(name);
    } else if (status.hasError) {
      line = l10n.recoveryWaitUnknown;
    } else {
      line = l10n.recoveryWaitApprovals(approvals?.approvals.length ?? 0);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.recoveryWaitBody(name), style: TextStyle(fontSize: 13, height: 1.45, color: AppColors.v3TextPrimary)),
        const SizedBox(height: 12),
        FingerprintBox(key: const ValueKey('recovery-my-words'), fingerprint: widget.fingerprint),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('recovery-show-qr'),
            onPressed: () => setState(() => _qr = !_qr),
            icon: const Icon(LucideIcons.qrCode, size: 15),
            label: Text(_qr ? l10n.fpHideMyCode : l10n.fpShowMyCode),
          ),
        ),
        if (_qr) Center(child: FingerprintQr(fingerprint: widget.fingerprint)),
        const SizedBox(height: 8),
        Text(line,
            key: const ValueKey('recovery-wait-state'),
            style: TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.v3TextSecondary)),
      ],
    );
  }
}
