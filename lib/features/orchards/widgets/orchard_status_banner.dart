import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/local_record.dart'
    show kServerBehindStatus, kUnlistedStatus, recordProblemIsNewer;
import 'package:zestssh/features/orchards/record/orchard_record.dart' show FixedRoles;
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart' show OrchardServerException, TeamDeletion;
import 'package:zestssh/features/orchards/team/team_seats.dart';
import 'package:zestssh/features/orchards/team/team_seats_sheet.dart' show openSeatsSheet;
import 'package:zestssh/features/orchards/widgets/orchard_device_dialogs.dart';
import 'package:zestssh/features/orchards/widgets/orchard_rules_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/orchards/widgets/team_delete_dialog.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/features/orchards/widgets/team_recovery_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_jump_provider.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/update_providers.dart' show availableUpdateProvider, inAppUpdateSupportedProvider;
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';
import 'package:zestssh/ui/screens/profile/sso_sign_in.dart';
import 'package:zestssh/ui/screens/security/security_settings_screen.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/sign_in_again.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/update_dialog.dart' show showUpdateDialog;
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/logger.dart';

/// The space around an Orchard banner above the host list.
const kOrchardBannerPadding = EdgeInsets.only(bottom: 8, right: 12);

/// Where the Orchard on screen stands, above its host list (3.0):
/// being deleted (who asked and the day, Undo for owners, Leave
/// for everyone else), said by ZestSSH Cloud to be deleted (Remove it from
/// this device), waiting for team recovery (with this account's words to
/// read out), suspended, access ended, rules not met (with what to do
/// about each),
/// a record this device stopped following, keys waiting to be replaced
/// that this account may replace, new items waiting for seats, or a
/// vault it writes in whose key waits for someone else to replace it.
/// Nothing while all is well.
class OrchardStatusBanner extends ConsumerStatefulWidget {
  const OrchardStatusBanner({super.key, this.padding = kOrchardBannerPadding});

  /// Around the banner (the host list's gutter by default).
  final EdgeInsets padding;

  @override
  ConsumerState<OrchardStatusBanner> createState() => _OrchardStatusBannerState();
}

class _OrchardStatusBannerState extends ConsumerState<OrchardStatusBanner> {
  bool _rotating = false;

  Future<void> _rotate(OrchardSummary orchard) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _rotating = true);
    try {
      final left = await ref.read(orchardServiceProvider).rotateDue(orchard.id);
      if (!mounted) return;
      if (left.isEmpty) {
        showTopSnackBar(context, l10n.orchardBannerRotated, isSuccess: true);
      } else {
        showTopSnackBar(context, l10n.orchardKeysReplaceLater, isWarning: true);
      }
    } catch (e) {
      AppLogger.warning('Orchards: replacing waiting keys failed ($e)');
      if (mounted) showTopSnackBar(context, orchardChangeErrorMessage(e, l10n), isError: true, details: '$e');
    } finally {
      if (mounted) setState(() => _rotating = false);
      ref.read(orchardListVersionProvider.notifier).state++;
    }
  }

  /// The update that reads what the team now uses: the app's own where it
  /// has one ready, else the download page.
  Future<void> _update() async {
    final update = ref.read(availableUpdateProvider);
    if (update != null && ref.read(inAppUpdateSupportedProvider)) {
      await showUpdateDialog(context, update);
      return;
    }
    final page = kZestDownloadPage;
    Object? failure;
    try {
      if (await launchUrl(Uri.parse(page), mode: LaunchMode.externalApplication)) return;
    } catch (e) {
      failure = e;
    }
    // Said, with the address to copy: it was only logged, and Update did
    // nothing anyone could see.
    AppLogger.warning('Opening the download page failed: ${failure ?? 'no app opened it'}');
    if (!mounted) return;
    showTopSnackBar(context, AppLocalizations.of(context)!.terminalOpenUrlFailed,
        isError: true, details: [page, if (failure != null) '$failure'].join('\n'));
  }

  Future<void> _details(String reason) {
    final l10n = AppLocalizations.of(context)!;
    return ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.neutral,
      title: l10n.orchardBannerRecordDetails,
      body: reason,
      showCancel: false,
      confirmLabel: l10n.close,
    );
  }

  @override
  Widget build(BuildContext context) {
    final orchard = ref.watch(activeOrchardProvider).valueOrNull;
    if (orchard == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final name = orchardDisplayName(orchard.name, l10n);
    final problem = orchard.recordProblem;
    if (orchard.status == kRecoveryWaitStatus) {
      return _Banner(
        key: const ValueKey('orchard-banner-recovery'),
        padding: widget.padding,
        tone: TeamTone.warning,
        icon: LucideIcons.lifeBuoy,
        text: l10n.orchardBannerRecoveryWait(name),
        action: (label: l10n.orchardBannerRecoveryShowWords, onPressed: () => showRecoveryWait(context, ref, orchard)),
      );
    }
    if (orchard.status == kServerBehindStatus) {
      // ZestSSH Cloud was restored from a backup that lost the change that
      // put this account in (the restore work): nothing to do here, and
      // nothing is lost; it syncs again once a member's device sends the
      // changes back.
      return _Banner(
        key: const ValueKey('orchard-banner-server-behind'),
        padding: widget.padding,
        tone: TeamTone.warning,
        icon: LucideIcons.cloudOff,
        text: ErrorCodes.withCode(l10n.orchardBannerServerBehind(name), ErrorCodes.teamServerBehind),
      );
    }
    if (orchard.status == kUnlistedStatus) {
      // ZestSSH Cloud no longer lists the team for this account, and the
      // team's signed record here still has it in: nothing goes on
      // the server's word alone; its person says.
      return _Banner(
        key: const ValueKey('orchard-banner-unlisted'),
        padding: widget.padding,
        tone: TeamTone.warning,
        icon: LucideIcons.cloudOff,
        text: ErrorCodes.withCode(l10n.orchardBannerUnlisted(name), ErrorCodes.teamUnlisted),
        action: (label: l10n.orchardBannerRemove, onPressed: () => removeUnlistedTeamFlow(context, ref, orchard)),
      );
    }
    if (orchard.status == kDeletingStatus) {
      // Being deleted: everyone is held back until an owner
      // undoes it or the day comes; anyone may leave meanwhile.
      final d = orchard.deleting;
      final people = ref.watch(teamPeopleProvider(orchard.id)).valueOrNull;
      final asker = people?.members.where((m) => m.uid == d?.by).firstOrNull;
      final askerName = asker == null ? null : Redactable.account(asker.name ?? asker.email ?? '').displayIn(ref);
      final day = d == null ? null : teamDeletionDay(d.purgeAt, l10n);
      final text = switch (d) {
        null => l10n.orchardBannerDeletingNoDay(name),
        TeamDeletion(purging: true) => l10n.orchardBannerDeletingNow(name),
        _ when asker?.isMe == true => l10n.orchardBannerDeletingYou(name, day!),
        _ when askerName != null && askerName.isNotEmpty => l10n.orchardBannerDeleting(name, askerName, day!),
        _ => l10n.orchardBannerDeletingNoName(name, day!),
      };
      return _Banner(
        key: const ValueKey('orchard-banner-deleting'),
        padding: widget.padding,
        tone: TeamTone.critical,
        icon: LucideIcons.trash2,
        text: text,
        // Owners and admins undo it; the rest leave.
        action: (orchard.isOwner || orchard.role == FixedRoles.admin) && d?.purging != true
            ? (label: l10n.orchardBannerUndo, onPressed: () => undoTeamDeletion(context, ref, orchard))
            : (label: l10n.orchardLeave, onPressed: () => leaveTeamBeingDeleted(context, ref, orchard)),
      );
    }
    if (orchard.status == kDeletedStatus) {
      // ZestSSH Cloud says it was deleted, and this device did not see it
      // being deleted long enough ago to remove it unasked: its person says.
      final at = orchard.deletedAt;
      return _Banner(
        key: const ValueKey('orchard-banner-deleted'),
        padding: widget.padding,
        tone: TeamTone.critical,
        icon: LucideIcons.trash2,
        text: at == null ? l10n.orchardBannerDeletedNoDay(name) : l10n.orchardBannerDeleted(name, teamDeletionDay(at, l10n)),
        action: (label: l10n.orchardBannerRemove, onPressed: () => removeDeletedTeamFlow(context, ref, orchard)),
      );
    }
    if (orchard.status == 'suspended') {
      return _Banner(
        key: const ValueKey('orchard-banner-suspended'),
        padding: widget.padding,
        tone: TeamTone.warning,
        icon: LucideIcons.pauseCircle,
        text: l10n.orchardBannerSuspended(name),
      );
    }
    if (orchard.status == 'ended') {
      return _Banner(
        key: const ValueKey('orchard-banner-ended'),
        padding: widget.padding,
        tone: TeamTone.critical,
        icon: LucideIcons.calendarX,
        text: l10n.orchardBannerEnded(name),
      );
    }
    if (orchard.status == kDirectoryHeldStatus) {
      return _Banner(
        key: const ValueKey('orchard-banner-directory'),
        padding: widget.padding,
        tone: TeamTone.warning,
        icon: LucideIcons.users,
        text: l10n.orchardBannerDirectoryHeld(name),
      );
    }
    if (!kKnownOrchardStatuses.contains(orchard.status)) {
      return _Banner(
        key: const ValueKey('orchard-banner-unavailable'),
        padding: widget.padding,
        tone: TeamTone.warning,
        icon: LucideIcons.cloudOff,
        text: l10n.orchardBannerUnavailable(name),
      );
    }
    final unmet = unmetRulesOf(ref, orchard);
    if (unmet.isNotEmpty) {
      return OrchardRulesBanner(
        key: const ValueKey('orchard-banner-rules'),
        orchard: orchard,
        unmet: unmet,
        padding: widget.padding,
      );
    }
    if (problem != null && recordProblemIsNewer(problem)) {
      return _Banner(
        key: const ValueKey('orchard-banner-newer'),
        padding: widget.padding,
        tone: TeamTone.warning,
        icon: LucideIcons.download,
        text: l10n.orchardBannerNewer(name),
        action: (label: l10n.orchardBannerUpdate, onPressed: _update),
      );
    }
    if (problem != null) {
      return _Banner(
        key: const ValueKey('orchard-banner-record'),
        padding: widget.padding,
        tone: TeamTone.critical,
        icon: LucideIcons.shieldAlert,
        text: l10n.orchardBannerRecordProblem(name),
        action: (label: l10n.orchardBannerRecordDetails, onPressed: () => _details(problem)),
      );
    }
    if (orchard.keysWaiting) {
      return _Banner(
        key: const ValueKey('orchard-banner-rotate'),
        padding: widget.padding,
        tone: TeamTone.info,
        icon: LucideIcons.keyRound,
        text: l10n.orchardBannerRotationDue(name),
        busy: _rotating,
        action: (label: l10n.orchardBannerRotate, onPressed: _rotating ? null : () => _rotate(orchard)),
      );
    }
    if (orchard.active && ref.watch(orchardSeatsShortProvider).contains(orchard.id)) {
      // Owners on a computer buy seats from the seats sheet; nothing is
      // bought, or pointed to, on a phone.
      final buys = orchard.isOwner && ref.watch(billingOnThisDeviceProvider);
      // What its vaults hold, with seats free perhaps: said as that, and with
      // what support asks for.
      final full = ref.watch(orchardVaultsFullProvider).contains(orchard.id);
      final text = full
          ? ErrorCodes.withCode(l10n.orchardVaultsFullBanner(name), ErrorCodes.teamVaultsFull)
          : l10n.orchardSeatsBanner(name);
      return _Banner(
        key: const ValueKey('orchard-banner-seats'),
        padding: widget.padding,
        tone: TeamTone.warning,
        icon: LucideIcons.armchair,
        text: text,
        action: buys ? (label: l10n.teamSeatsBuy, onPressed: () => openSeatsSheet(context, ref, orchard.id)) : null,
        below: full
            ? CopyDetailsButton(
                key: const ValueKey('orchard-banner-seats-details'),
                detail: ErrorReport.build(
                    what: text, where: 'Team vaults', error: const OrchardServerException(409, 'seats-needed', reason: 'storage')),
              )
            : null,
      );
    }
    final waiting = orchard.writesUnderWaitingKey;
    if (waiting != null) {
      // Someone who may not replace the key still writes under it: whoever
      // lost access holds that generation, and only those who manage the vault
      // were told. Nothing to do here but to know it.
      return _Banner(
        key: const ValueKey('orchard-banner-rotate-waits'),
        padding: widget.padding,
        tone: TeamTone.info,
        icon: LucideIcons.keyRound,
        text: l10n.orchardBannerRotationWaits(crateDisplayName(waiting, l10n)),
      );
    }
    return const SizedBox.shrink();
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    super.key,
    required this.tone,
    required this.icon,
    required this.text,
    this.action,
    this.below,
    this.busy = false,
    this.padding = kOrchardBannerPadding,
  });

  final EdgeInsets padding;

  final TeamTone tone;
  final IconData icon;
  final String text;
  final ({String label, VoidCallback? onPressed})? action;

  /// Under the words: Copy details, where it is a fault.
  final Widget? below;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final action = this.action;
    // The team pages' callout: amber for what waits on someone, red for
    // what ended or broke; its one action a button (it was bare words).
    return Padding(
      padding: padding,
      child: TeamCallout(
        tone: tone,
        icon: icon,
        title: text,
        action: action == null && !busy
            ? null
            : teamButton(label: action?.label ?? '', busy: busy, onPressed: action?.onPressed),
        below: below,
      ),
    );
  }
}

/// The Orchard's rules this account or this device falls short of (3.0),
/// each with what to do about it: everything on this device still
/// works, but the Orchard does not sync until they are met. Owners can also
/// change the rules from here.
class OrchardRulesBanner extends ConsumerStatefulWidget {
  const OrchardRulesBanner({
    super.key,
    required this.orchard,
    required this.unmet,
    this.padding = kOrchardBannerPadding,
  });

  final OrchardSummary orchard;
  final List<UnmetRule> unmet;
  final EdgeInsets padding;

  @override
  ConsumerState<OrchardRulesBanner> createState() => _OrchardRulesBannerState();
}

class _OrchardRulesBannerState extends ConsumerState<OrchardRulesBanner> {
  bool _busy = false;

  Future<void> _signInAgain() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      if (!await refreshSignIn(context, ref, wrongAccount: l10n.orchardSignInWrongAccount)) return;
      await ref.read(orchardSyncSchedulerProvider).syncAll();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A team's Sign-in lasts: a passkey meets it unless the
  /// team requires company sign-in, where only signing in asks the company.
  Future<void> _confirmForReauth() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      final shown = await confirmOrSignIn(
        context,
        ref,
        about: l10n.stepUpReauthBody,
        sayWindow: false,
        askFirst: false,
        signInOnly: widget.orchard.rules.requireSso,
        wrongAccount: l10n.orchardSignInWrongAccount,
      );
      if (shown != ItsYou.confirmed) return;
      await ref.read(orchardSyncSchedulerProvider).syncAll();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openAccount() => ProfileScreen.openAccount(context, ref);

  Future<void> _askDevice() => showDeviceAsk(context, ref, widget.orchard);

  Future<void> _signInWithSso() async {
    setState(() => _busy = true);
    try {
      await signInThroughCompany(context, ref);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openLockSettings() async {
    if (jumpToDesktopSettings(ref, SettingsJumpTarget.security)) return;
    await SecuritySettingsScreen.show(context);
    if (!mounted) return;
    // Whatever the screen changed shows here, and syncs.
    ref.read(securityLockEnabledProvider.notifier).state = ref.read(settingsServiceProvider).securityLockEnabled;
    ref.invalidate(autoLockTimeoutProvider);
    ref.invalidate(deviceLockProvider);
  }

  ({String text, List<({String label, Future<void> Function() onPressed})> actions}) _line(
      UnmetRule rule, AppLocalizations l10n) {
    final signIn = (label: l10n.orchardRuleSignInAgain, onPressed: _signInAgain);
    final lock = (label: l10n.orchardRuleOpenLockSettings, onPressed: _openLockSettings);
    final o = widget.orchard;
    return switch (rule) {
      UnmetRule.twoStep => (
          text: l10n.orchardRuleTwoStepFix,
          actions: [(label: l10n.orchardRuleOpenAccount, onPressed: _openAccount), signIn],
        ),
      UnmetRule.emailDomain => (
          text: o.ruleDomains.isEmpty
              ? l10n.orchardRuleEmailDomainFixUnknown
              : l10n.orchardRuleEmailDomainFix(o.ruleDomains.join(', ')),
          actions: const [],
        ),
      UnmetRule.reauth => (
          text: l10n.orchardRuleReauthFix,
          actions: [(label: l10n.orchardRuleSignInAgain, onPressed: _confirmForReauth)],
        ),
      UnmetRule.sso => (
          text: l10n.orchardRuleSsoFix,
          actions: [(label: l10n.orchardRuleSignInWithSso, onPressed: _signInWithSso)],
        ),
      // Not approved yet, or approved once and removed: it asks.
      UnmetRule.trustedDevice => (
          text: o.deviceRemoved ? l10n.orchardRuleTrustedDeviceRemoved : l10n.orchardRuleTrustedDeviceFix,
          actions: [(label: l10n.deviceAskAction, onPressed: _askDevice)],
        ),
      UnmetRule.appLock => (text: l10n.orchardRuleAppLockFix, actions: [lock]),
      UnmetRule.lockTimeout => (text: l10n.orchardRuleLockTimeoutFix(o.rules.maxLockMinutes), actions: [lock]),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final o = widget.orchard;
    return Padding(
      padding: widget.padding,
      child: TeamCallout(
        tone: TeamTone.warning,
        icon: LucideIcons.shieldAlert,
        // Removed from it, this device holds nothing of it.
        title: o.deviceRemoved
            ? l10n.orchardDeviceRemovedBanner(orchardDisplayName(o.name, l10n))
            : l10n.orchardRulesBanner(orchardDisplayName(o.name, l10n)),
        below: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final rule in widget.unmet)
              Builder(builder: (context) {
                final line = _line(rule, l10n);
                // What is short, then what to do about it: buttons, not
                // bare words.
                return Padding(
                  key: ValueKey('orchard-rule-${rule.name}'),
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(line.text, style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary)),
                      if (line.actions.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final (i, a) in line.actions.indexed)
                              teamButton(
                                // The first is what fixes it.
                                kind: i == 0 ? TeamButtonKind.primary : TeamButtonKind.secondary,
                                busy: _busy && i == 0,
                                label: a.label,
                                onPressed: _busy ? null : () => a.onPressed(),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                );
              }),
            // (Not from a device nobody approved: the rules are closed to
            // it, an owner's too.)
            if (o.isOwner && !o.rulesUnmet.contains(kTrustedDeviceRule))
              teamButton(
                key: const ValueKey('orchard-rules-change'),
                icon: LucideIcons.scrollText,
                label: l10n.orchardRulesChange,
                // On desktop the Team page's Rules; elsewhere the dialog.
                onPressed: _busy
                    ? null
                    : () {
                        if (!openTeamPage(ref, TeamPage.rules)) showOrchardRules(context, ref, o.id);
                      },
              ),
          ],
        ),
      ),
    );
  }
}
