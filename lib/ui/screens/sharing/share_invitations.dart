import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/features/sharing/share_providers.dart';
import 'package:zestssh/features/sharing/share_viewer.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/sharing/share_widgets.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// Opens "Shared with you" (3.0): the sessions this account is invited to,
/// and the ones it is watching now.
Future<void> showShareInvitations(BuildContext context) => showZestModal<void>(
      context: context,
      size: ZestModalSize.standard,
      child: const ShareInvitationsDialog(),
    );

/// Joins [share]: a live view opens its own screen; a shared tmux session
/// connects to the host with this person's own access and attaches.
/// Everything it needs of [context] is taken before the first wait: the
/// pop-up it is called from closes on the way.
Future<void> joinIncomingShare(BuildContext context, IncomingShare share) async {
  final l10n = AppLocalizations.of(context)!;
  final navigator = Navigator.of(context);
  final router = GoRouter.of(context);
  final providers = ProviderScope.containerOf(context, listen: false);
  if (share.mode == ShareMode.live) {
    final view = await providers.read(shareJoiningProvider).watch(share);
    if (!context.mounted) return;
    if (view == null) {
      showTopSnackBar(context, l10n.shareFailedNotReady, isError: true);
      return;
    }
    await navigator.maybePop();
    unawaited(router.push(Routes.shareView, extra: share.shareId));
    return;
  }
  final (sessionId, problem) = await providers.read(shareTmuxJoinsProvider).join(share);
  if (!context.mounted) return;
  if (sessionId == null) {
    showTopSnackBar(
      context,
      switch (problem) {
        ShareTmuxJoinProblem.hostMissing => l10n.shareTmuxHostMissing,
        ShareTmuxJoinProblem.noSession => l10n.shareTmuxNoSession,
        ShareTmuxJoinProblem.orchardClosed || null => l10n.shareFailedNotReady,
      },
      isError: true,
    );
    return;
  }
  await navigator.maybePop();
  if (desktopShellInUse) {
    providers.read(workTabsProvider.notifier).onSessionCreated(sessionId);
  } else {
    unawaited(router.push('/terminal/$sessionId'));
  }
}

class ShareInvitationsDialog extends ConsumerStatefulWidget {
  const ShareInvitationsDialog({super.key});

  @override
  ConsumerState<ShareInvitationsDialog> createState() => _ShareInvitationsDialogState();
}

class _ShareInvitationsDialogState extends ConsumerState<ShareInvitationsDialog> {
  String? _joining;

  @override
  void initState() {
    super.initState();
    // What is listed may be a moment old: ask again as it opens.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(shareInvitationsProvider.notifier).refresh());
    });
  }

  Future<void> _join(IncomingShare share) async {
    if (_joining != null) return;
    setState(() => _joining = share.shareId);
    try {
      await joinIncomingShare(context, share);
    } finally {
      if (mounted) setState(() => _joining = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final invitations = ref.watch(shareInvitationsProvider);
    return ValueListenableBuilder<Map<String, ShareViewerController>>(
      valueListenable: ShareViews.active,
      builder: (context, views, _) {
        final watching = [
          for (final e in views.entries)
            if (e.value.phase != ShareViewPhase.ended) e.key,
        ];
        final waiting = [
          for (final s in invitations)
            if (!watching.contains(s.shareId)) s,
        ];
        // How many of each, under the title; nothing where the body says
        // there is nothing.
        final counts = [
          if (watching.isNotEmpty) l10n.shareUiInvitesWatchingCount(watching.length),
          if (waiting.isNotEmpty) l10n.shareUiInvitesWaitingCount(waiting.length),
        ];
        // No footer: the header's close closes it, and each card has its own
        // buttons.
        return ZestDialogShell(
          size: ZestModalSize.standard,
          tone: ZestDialogTone.info,
          icon: LucideIcons.users,
          title: l10n.shareInvitesTitle,
          subtitle: counts.isEmpty ? null : counts.join(' · '),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (watching.isEmpty && waiting.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(l10n.shareInvitesEmpty,
                      style: TextStyle(fontSize: 13, height: 1.5, color: ZestTokens.textSecondary)),
                ),
              if (watching.isNotEmpty) ...[
                ShareGroupLabel(l10n.shareWatchingNow),
                for (final id in watching) _watchingCard(l10n, id),
                const SizedBox(height: 8),
              ],
              if (waiting.isNotEmpty) ...[
                if (watching.isNotEmpty) ShareGroupLabel(l10n.shareInvitesWaiting),
                for (final s in waiting) _inviteCard(l10n, s),
              ],
            ],
          ),
        );
      },
    );
  }

  String _who(AppLocalizations l10n, IncomingShare s) =>
      Redactable.account(s.fromEmail ?? l10n.shareSomeone).displayIn(ref);

  String _where(AppLocalizations l10n, IncomingShare s) => s.hostLabel == null
      ? l10n.shareInviteInCrate(s.crateName)
      : l10n.shareInviteOn(Redactable.host(s.hostLabel!).displayIn(ref), s.crateName);

  Widget _watchingCard(AppLocalizations l10n, String shareId) {
    final share = ShareViews.shareOf(shareId);
    if (share == null) return const SizedBox.shrink();
    return _Card(
      key: ValueKey('share-watching-$shareId'),
      icon: LucideIcons.eye,
      title: l10n.shareViewTitle(_who(l10n, share)),
      lines: [_where(l10n, share)],
      actions: [
        shareButton(
          label: l10n.shareViewLeave,
          onPressed: () => unawaited(ShareViews.close(shareId)),
        ),
        shareButton(
          key: ValueKey('share-open-$shareId'),
          label: l10n.shareOpen,
          kind: ShareButtonKind.primary,
          onPressed: () {
            final router = GoRouter.of(context);
            Navigator.of(context).pop();
            unawaited(router.push(Routes.shareView, extra: shareId));
          },
        ),
      ],
    );
  }

  Widget _inviteCard(AppLocalizations l10n, IncomingShare s) {
    final who = _who(l10n, s);
    final live = s.mode == ShareMode.live;
    final invitation = s.invitation.invitation;
    final busy = _joining == s.shareId;
    return _Card(
      key: ValueKey('share-invite-${s.shareId}'),
      icon: live ? LucideIcons.eye : LucideIcons.terminalSquare,
      title: s.asksToWatch
          ? l10n.shareInviteWatch(who)
          : live
              ? l10n.shareInviteLive(who)
              : l10n.shareInviteTmux(who),
      lines: [
        _where(l10n, s),
        // What joining means: watching a session that waits for them (a
        // watched Crate), watching with the right to end it, or
        // watching until handed the keyboard.
        if (s.asksToWatch)
          l10n.shareInviteWatchHow(s.crateName)
        else if (live && invitation.mayEnd)
          l10n.shareInviteLiveHowCanEnd
        else if (live)
          l10n.shareInviteLiveHow
        else
          l10n.shareInviteTmuxHow(
              invitation.tmuxSession, Redactable.username(invitation.remoteUser).displayIn(ref)),
      ],
      // Their keys changed: said as a warning, with the way to where keys
      // are compared.
      warning: s.keysChanged
          ? ShareNoteBox(
              key: ValueKey('share-keys-changed-${s.shareId}'),
              icon: LucideIcons.alertTriangle,
              warn: true,
              text: l10n.shareInviteKeysChanged(who),
              footer: shareButton(
                label: l10n.orchardMemberCheck,
                icon: LucideIcons.fingerprint,
                onPressed: () => openKeyComparison(context, ref),
                dense: true,
              ),
            )
          : null,
      actions: [
        shareButton(
          key: ValueKey('share-decline-${s.shareId}'),
          label: l10n.shareDecline,
          onPressed: busy ? null : () => unawaited(ref.read(shareInvitationsProvider.notifier).decline(s)),
        ),
        shareButton(
          key: ValueKey('share-join-${s.shareId}'),
          label: live ? l10n.shareWatch : l10n.shareJoin,
          kind: ShareButtonKind.primary,
          onPressed: s.keysChanged || _joining != null ? null : () => unawaited(_join(s)),
        ),
      ],
    );
  }
}

/// One share on "Shared with you": what it is, where, what joining means, a
/// warning where there is one, and its buttons at the end.
class _Card extends StatelessWidget {
  const _Card({
    super.key,
    required this.icon,
    required this.title,
    required this.lines,
    required this.actions,
    this.warning,
  });

  final IconData icon;
  final String title;
  final List<String> lines;
  final List<Widget> actions;
  final Widget? warning;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: ZestTokens.surfaceRaised,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: ZestTokens.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(icon, size: 16, color: ZestTokens.textSecondary),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: TextStyle(
                                fontSize: 13.5, height: 1.35, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                        for (final line in lines) ...[
                          const SizedBox(height: 4),
                          Text(line, style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textTertiary)),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (warning != null) ...[const SizedBox(height: 12), warning!],
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: actions,
              ),
            ],
          ),
        ),
      );
}
