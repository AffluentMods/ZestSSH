import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/sharing/session_shares.dart';
import 'package:zestssh/features/sharing/share_host.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/sharing/share_session_dialog.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';

// What the sharing screens share (3.0, session sharing): small pieces of the
// dialogs, the buttons they all use, and what a shared session shows about
// itself: a chip in its header on a computer, and a strip under the toolbar
// (on a phone the whole time, on a computer while someone else has the
// keyboard or asks for it).

/// A section of a sharing dialog: the app's one section header.
class ShareGroupLabel extends StatelessWidget {
  const ShareGroupLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => ZestSectionHeader(label: text);
}

class ShareSwitchRow extends StatelessWidget {
  const ShareSwitchRow({super.key, required this.title, required this.subtitle, required this.value, required this.onChanged});

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textTertiary)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ZestSwitch(value: value, onChanged: onChanged),
        ],
      );
}

/// A note inside a dialog or a card: one step up from what it sits on (never
/// a dark hole in it), or amber where it warns. [footer] goes under the
/// words (a code and Copy details, a button).
class ShareNoteBox extends StatelessWidget {
  const ShareNoteBox({super.key, required this.icon, required this.text, this.warn = false, this.footer});
  final IconData icon;
  final String text;
  final bool warn;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final tint = warn ? ZestTokens.statusWarning : ZestTokens.textTertiary;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: warn ? ZestTokens.statusWarning.withValues(alpha: 0.08) : ZestTokens.surfaceRaisedAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: warn ? ZestTokens.statusWarning.withValues(alpha: 0.35) : ZestTokens.borderSubtle),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 16, color: tint)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary)),
                if (footer != null) ...[const SizedBox(height: 8), footer!],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A person, as a circle with the first letter of their name.
class ShareAvatar extends StatelessWidget {
  const ShareAvatar({super.key, required this.name, this.size = 28});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final letter = name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: ZestTokens.surfaceChip,
        shape: BoxShape.circle,
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Text(letter,
          style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary, height: 1)),
    );
  }
}

/// A small badge beside a title ("Recommended").
class ShareBadge extends StatelessWidget {
  const ShareBadge(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: ZestTokens.brandSubtle, borderRadius: BorderRadius.circular(4)),
        child: Text(text,
            style: TextStyle(fontSize: 10.5, height: 1.3, fontWeight: FontWeight.w600, color: ZestTokens.brandInk)),
      );
}

/// What a button of the sharing screens is: the one main thing (filled), a
/// neutral outlined one, a quiet one, or one that ends something (red).
enum ShareButtonKind { primary, secondary, ghost, danger }

/// Whether the app runs as on a computer (its buttons 34 high, a phone's 44).
bool get _onComputer => switch (defaultTargetPlatform) {
      TargetPlatform.windows || TargetPlatform.macOS || TargetPlatform.linux => true,
      _ => false,
    };

/// A button of the sharing screens: the theme's own, one height whatever its
/// kind (34 on a computer, [dense] 30 inside a strip or a row; always 44 on
/// a phone, where a finger presses it), radius 8.
///
/// [iconOnly]: its [icon] alone in a square, [label] its tooltip, where the
/// words have no room beside what it sits by ([shareButtonWidth] measures
/// them).
Widget shareButton({
  Key? key,
  required String label,
  required VoidCallback? onPressed,
  ShareButtonKind kind = ShareButtonKind.secondary,
  IconData? icon,
  bool dense = false,
  bool iconOnly = false,
}) {
  final height = _onComputer ? (dense ? 30.0 : 34.0) : 44.0;
  final square = iconOnly && icon != null;
  final base = ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(square ? height : 0, height)),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    padding: WidgetStatePropertyAll(square ? EdgeInsets.zero : EdgeInsets.symmetric(horizontal: dense ? 12 : 14)),
    textStyle: const WidgetStatePropertyAll(_shareButtonText),
  );
  final text = Text(label);
  final glyph = icon == null ? null : Icon(icon, size: 16);
  final style = switch (kind) {
    ShareButtonKind.primary || ShareButtonKind.secondary => base,
    ShareButtonKind.ghost => base.copyWith(
        foregroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.disabled) ? ZestTokens.textPlaceholder : ZestTokens.textSecondary),
      ),
    ShareButtonKind.danger => base.copyWith(
        foregroundColor: WidgetStatePropertyAll(ZestTokens.statusCritical),
        side: WidgetStatePropertyAll(BorderSide(color: ZestTokens.statusCritical.withValues(alpha: 0.55))),
        overlayColor: WidgetStatePropertyAll(ZestTokens.statusCritical.withValues(alpha: 0.08)),
      ),
  };
  Widget plain(Widget child) => switch (kind) {
        ShareButtonKind.primary => FilledButton(key: key, style: style, onPressed: onPressed, child: child),
        ShareButtonKind.ghost => TextButton(key: key, style: style, onPressed: onPressed, child: child),
        ShareButtonKind.secondary || ShareButtonKind.danger =>
          OutlinedButton(key: key, style: style, onPressed: onPressed, child: child),
      };
  if (glyph == null) return plain(text);
  if (square) return Tooltip(message: label, child: plain(glyph));
  return switch (kind) {
    ShareButtonKind.primary => FilledButton.icon(key: key, style: style, onPressed: onPressed, icon: glyph, label: text),
    ShareButtonKind.ghost => TextButton.icon(key: key, style: style, onPressed: onPressed, icon: glyph, label: text),
    ShareButtonKind.secondary || ShareButtonKind.danger =>
      OutlinedButton.icon(key: key, style: style, onPressed: onPressed, icon: glyph, label: text),
  };
}

/// The words of a [shareButton].
const _shareButtonText = TextStyle(fontFamily: 'GeistSans', fontSize: 13, fontWeight: FontWeight.w600);

/// How wide a [shareButton] with an icon and [label] is drawn in [context]:
/// its padding, the icon, the room after it and the words.
double shareButtonWidth(BuildContext context, String label, {bool dense = false}) {
  final words = TextPainter(
    text: TextSpan(text: label, style: _shareButtonText),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = words.width;
  words.dispose();
  return 2 * (dense ? 12 : 14) + 16 + 8 + width;
}

/// Opens where keys are compared (the Team page's members), closing the
/// pop-up [context] is in first: on a computer the Team destination, on a
/// phone its page.
void openKeyComparison(BuildContext context, WidgetRef ref) {
  final router = GoRouter.maybeOf(context);
  Navigator.of(context).pop();
  if (!openTeamPage(ref, TeamPage.members)) unawaited(router?.push('${Routes.team}/${TeamPage.members.name}'));
}

/// Rebuilds with the share of [sessionId] and everything that changes in
/// it; [builder] gets null when the session is not shared.
class SessionShareBuilder extends StatelessWidget {
  const SessionShareBuilder({super.key, required this.sessionId, required this.builder});

  final String sessionId;
  final Widget Function(BuildContext context, ShareHostController? share) builder;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Map<String, ShareHostController>>(
        valueListenable: SessionShares.active,
        builder: (context, shares, _) {
          final share = shares[sessionId];
          if (share == null) return builder(context, null);
          return ListenableBuilder(listenable: share, builder: (context, _) => builder(context, share));
        },
      );
}

/// How many people are in the share now: watching a live view (one whose
/// device is still connecting is not there yet), or attached to the shared
/// tmux session.
int _present(ShareHostController share) => share.guests
    .where((g) =>
        g.state == ShareGuestState.watching ||
        g.state == ShareGuestState.typing ||
        (share.mode == ShareMode.tmux && g.state == ShareGuestState.connected))
    .length;

String _shareLabel(AppLocalizations l10n, ShareHostController share) {
  final what = share.mode == ShareMode.live ? l10n.shareChipLive : l10n.shareChipTmux;
  return l10n.shareChipCount(what, _present(share));
}

/// The session header's chip on a computer: shared, how, and with how many
/// people there now. One look whatever happens in the share: what needs a
/// look (the keyboard) is the strip's to say. A click opens who they are and
/// what each may do.
class SessionShareChip extends ConsumerWidget {
  const SessionShareChip({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return SessionShareBuilder(
      sessionId: sessionId,
      builder: (context, share) {
        if (share == null) return const SizedBox.shrink();
        final ink = ZestTokens.brandInk;
        return Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Tooltip(
            message: l10n.shareChipTooltip,
            child: Builder(
              builder: (chipContext) => Material(
                color: ZestTokens.brandSubtle,
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  key: ValueKey('share-chip-$sessionId'),
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => showShareParticipants(chipContext, sessionId),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(LucideIcons.users, size: 13, color: ink),
                        const SizedBox(width: 5),
                        Text(_shareLabel(l10n, share),
                            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: ink)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// What a strip says with its colour: nothing to act on, the keyboard
/// changing hands, or something held or counting down.
enum ShareStripTone { neutral, brand, warning }

/// One strip under a session's header, for every state of a shared or
/// watched session: a neutral band with a short bar of the tone's colour at
/// its start, the icon in that colour, the words in the text's own, and the
/// actions at the end. On a computer one line of at least 40; narrower (a
/// phone) the words on a line or two and the actions on a row of their own.
class ShareStateStrip extends StatelessWidget {
  const ShareStateStrip({
    super.key,
    required this.icon,
    required this.text,
    this.tone = ShareStripTone.neutral,
    this.actions = const [],
    this.onTap,
    this.tapKey,
  });

  final IconData icon;
  final String text;
  final ShareStripTone tone;

  /// Buttons ([shareButton], dense).
  final List<Widget> actions;

  /// What a press on the strip itself opens; a chevron says so where there
  /// is no action on it.
  final VoidCallback? onTap;
  final Key? tapKey;

  /// From this width the actions are beside the words.
  static const double besideFrom = 720;

  @override
  Widget build(BuildContext context) {
    final (bar, ink) = switch (tone) {
      ShareStripTone.neutral => (ZestTokens.borderStrong, ZestTokens.textTertiary),
      ShareStripTone.brand => (ZestTokens.brand, ZestTokens.brandInk),
      ShareStripTone.warning => (ZestTokens.statusWarning, ZestTokens.statusWarning),
    };
    final words = Row(
      children: [
        Icon(icon, size: 16, color: ink),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 13, height: 1.35, color: ZestTokens.textPrimary)),
        ),
        if (onTap != null && actions.isEmpty) ...[
          const SizedBox(width: 8),
          Icon(LucideIcons.chevronRight, size: 16, color: ZestTokens.textTertiary),
        ],
      ],
    );
    final body = LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth >= besideFrom) {
        return ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Expanded(child: words),
                for (final a in actions) ...[const SizedBox(width: 8), a],
              ],
            ),
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            words,
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: actions),
            ],
          ],
        ),
      );
    });
    return Material(
      color: ZestTokens.surfaceRaised,
      child: InkWell(
        key: tapKey,
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: bar, width: 3),
              bottom: BorderSide(color: ZestTokens.borderSubtle),
            ),
          ),
          child: body,
        ),
      ),
    );
  }
}

/// The line under a shared session's header, on a computer and on a phone:
/// on a phone it is always there while the session is shared; on a computer
/// it shows while someone else has the keyboard or asks for it, which nobody
/// should miss.
class SessionShareStrip extends ConsumerWidget {
  const SessionShareStrip({super.key, required this.sessionId, this.always = false});

  final String sessionId;

  /// Shown the whole time the session is shared (a phone has no chip).
  final bool always;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return SessionShareBuilder(
      sessionId: sessionId,
      builder: (context, share) {
        if (share == null) return const SizedBox.shrink();
        final holder = share.keyboardHolder;
        final asking = [
          for (final g in share.guests)
            if (g.asksKeyboard) g.uid,
        ];
        if (holder == null && asking.isEmpty && !always) return const SizedBox.shrink();
        String name(String uid) => Redactable.account(SessionShares.nameOf(sessionId, uid)).displayIn(ref);
        final String text;
        final List<Widget> actions;
        if (holder != null) {
          text = l10n.shareTypingBanner(name(holder));
          actions = [
            shareButton(
              key: ValueKey('share-strip-take-back-$sessionId'),
              label: l10n.shareTakeBack,
              onPressed: share.takeBack,
              dense: true,
            ),
          ];
        } else if (asking.isNotEmpty) {
          text = l10n.shareAskingBanner(name(asking.first));
          actions = [
            shareButton(
              label: l10n.shareNotNow,
              kind: ShareButtonKind.ghost,
              onPressed: () => share.denyKeyboard(asking.first),
              dense: true,
            ),
            shareButton(
              key: ValueKey('share-strip-give-$sessionId'),
              label: l10n.shareGiveKeyboard,
              kind: ShareButtonKind.primary,
              onPressed: () => share.giveKeyboard(asking.first),
              dense: true,
            ),
          ];
        } else {
          text = _shareLabel(l10n, share);
          actions = const [];
        }
        return ShareStateStrip(
          tapKey: ValueKey('share-strip-$sessionId'),
          icon: holder != null || asking.isNotEmpty ? LucideIcons.keyboard : LucideIcons.users,
          text: text,
          tone: holder != null || asking.isNotEmpty ? ShareStripTone.brand : ShareStripTone.neutral,
          actions: actions,
          onTap: () => showShareParticipants(context, sessionId),
        );
      },
    );
  }
}

/// Opens who is in the share of [sessionId]: a dialog on a computer, a sheet
/// on a phone.
Future<void> showShareParticipants(BuildContext context, String sessionId) {
  return showZestModal<void>(
    context: context,
    size: ZestModalSize.standard,
    child: ShareParticipantsDialog(sessionId: sessionId),
  );
}

/// One thing that can be done about a person in a share.
typedef _PersonAction = ({Key? key, String label, VoidCallback onPressed, ShareButtonKind kind});

/// Who is in a share, where each stands, the keyboard, and stopping.
class ShareParticipantsDialog extends ConsumerWidget {
  const ShareParticipantsDialog({super.key, required this.sessionId});

  final String sessionId;

  Future<void> _stop(BuildContext context, WidgetRef ref, ShareHostController share) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.shareStopConfirmTitle,
      body: share.mode == ShareMode.live ? l10n.shareStopConfirmLive : l10n.shareStopConfirmTmux,
      confirmLabel: l10n.shareStop,
    );
    if (ok != true) return;
    // A shared tmux session: the others are detached from it. They can
    // still connect to the host themselves, as they always could.
    if (share.mode == ShareMode.tmux) {
      unawaited(ref.read(tmuxHostProvider(sessionId)).controller?.detachOtherClients());
    }
    await SessionShares.stop(sessionId);
    if (context.mounted) Navigator.of(context).maybePop();
  }

  /// Where [g] stands, as one pill: neutral invited, pending connecting,
  /// green watching or attached, amber where the keyboard is theirs or asked
  /// for, dimmed where they said no.
  Widget _pill(AppLocalizations l10n, ShareGuest g, bool live) {
    if (g.asksKeyboard) return ZestStatusPill(kind: ZestStatusKind.warning, label: l10n.shareAsksKeyboard, icon: LucideIcons.keyboard);
    return switch (g.state) {
      ShareGuestState.invited => ZestStatusPill(kind: ZestStatusKind.neutral, label: l10n.shareStateInvited, icon: LucideIcons.mail),
      ShareGuestState.declined => ZestStatusPill(kind: ZestStatusKind.stale, label: l10n.shareStateDeclined, icon: LucideIcons.xCircle),
      ShareGuestState.connected => live
          ? ZestStatusPill(kind: ZestStatusKind.pending, label: l10n.shareStateConnecting)
          : ZestStatusPill(kind: ZestStatusKind.healthy, label: l10n.shareStateAttached),
      ShareGuestState.watching => ZestStatusPill(
          kind: ZestStatusKind.healthy,
          icon: LucideIcons.eye,
          label: g.canEnd
              ? l10n.shareStateWatchingCanEnd
              : g.canType
                  ? l10n.shareStateWatching
                  : l10n.shareStateWatchingOnly,
        ),
      ShareGuestState.typing => ZestStatusPill(kind: ZestStatusKind.warning, label: l10n.shareStateTyping, icon: LucideIcons.keyboard),
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return SessionShareBuilder(
      sessionId: sessionId,
      builder: (context, share) {
        if (share == null) {
          // It ended while this was open.
          return ZestDialogShell(
            size: ZestModalSize.standard,
            tone: ZestDialogTone.info,
            icon: LucideIcons.users,
            title: l10n.shareEndedTitle,
            body: Text(l10n.shareEndedBody,
                style: TextStyle(fontSize: 13, height: 1.5, color: ZestTokens.textSecondary)),
            secondaryAction: (label: l10n.close, onPressed: () => Navigator.of(context).pop()),
          );
        }
        final live = share.mode == ShareMode.live;
        final holder = share.keyboardHolder;
        return ZestDialogShell(
          size: ZestModalSize.standard,
          tone: ZestDialogTone.info,
          icon: LucideIcons.users,
          title: live ? l10n.shareChipLive : l10n.sharePopTmuxTitle(share.tmuxSession),
          subtitle: share.isLineOpen ? (live ? l10n.shareLiveEncrypted : l10n.shareTmuxOwnAccess) : l10n.shareReconnecting,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PersonRow(
                name: l10n.shareYou,
                status: live
                    ? (holder == null
                        ? ZestStatusPill(kind: ZestStatusKind.healthy, label: l10n.shareYouHaveKeyboard, icon: LucideIcons.keyboard)
                        : ZestStatusPill(kind: ZestStatusKind.neutral, label: l10n.shareYouCanStillType, icon: LucideIcons.keyboard))
                    : ZestStatusPill(kind: ZestStatusKind.healthy, label: l10n.shareStateAttached),
              ),
              for (final g in share.guests)
                _PersonRow(
                  key: ValueKey('share-guest-${g.uid}'),
                  name: Redactable.account(SessionShares.nameOf(sessionId, g.uid)).displayIn(ref),
                  status: _pill(l10n, g, live),
                  actions: [
                    if (g.state == ShareGuestState.typing)
                      (
                        key: ValueKey('share-take-back-${g.uid}'),
                        label: l10n.shareTakeBack,
                        onPressed: share.takeBack,
                        kind: ShareButtonKind.secondary,
                      )
                    else if (g.state == ShareGuestState.watching && g.canType) ...[
                      if (g.asksKeyboard)
                        (
                          key: null,
                          label: l10n.shareNotNow,
                          onPressed: () => share.denyKeyboard(g.uid),
                          kind: ShareButtonKind.ghost,
                        ),
                      (
                        key: ValueKey('share-give-${g.uid}'),
                        label: l10n.shareGiveKeyboard,
                        onPressed: () => share.giveKeyboard(g.uid),
                        kind: ShareButtonKind.secondary,
                      ),
                    ],
                  ],
                  removeKey: ValueKey('share-remove-${g.uid}'),
                  removeLabel: l10n.shareRemovePerson,
                  onRemove: () => unawaited(share.remove(g.uid)),
                ),
            ],
          ),
          primaryAction: (
            label: l10n.shareStop,
            icon: LucideIcons.x,
            onPressed: () => unawaited(_stop(context, ref, share)),
          ),
          primaryDanger: true,
          secondaryAction: (
            label: l10n.shareInviteMore,
            onPressed: () {
              // The next pop-up opens from what stays, not from this one,
              // which is on its way out.
              final navigator = Navigator.of(context);
              final stays = navigator.context;
              navigator.pop();
              unawaited(showShareSession(stays, sessionId));
            },
          ),
        );
      },
    );
  }
}

/// One person of a share: the avatar at the name's line, the name, where
/// they stand as a pill, and what can be done about them. On a computer the
/// actions are buttons at the end of the row with the remove beside them;
/// narrower (a phone's sheet) they are in a menu, so every row is as tall
/// as the next.
class _PersonRow extends StatelessWidget {
  const _PersonRow({
    super.key,
    required this.name,
    required this.status,
    this.actions = const [],
    this.onRemove,
    this.removeKey,
    this.removeLabel = '',
  });

  final String name;
  final Widget status;
  final List<_PersonAction> actions;
  final VoidCallback? onRemove;
  final Key? removeKey;
  final String removeLabel;

  /// From this width the actions are buttons beside the name.
  static const double _besideFrom = 420;

  Future<void> _menu(BuildContext context, RelativeRect at) async {
    final picked = await showMenu<VoidCallback>(
      context: context,
      position: at,
      items: [
        for (final a in actions)
          PopupMenuItem(key: a.key, value: a.onPressed, height: 44, child: Text(a.label)),
        if (onRemove != null)
          PopupMenuItem(
            key: removeKey,
            value: onRemove,
            height: 44,
            child: Text(removeLabel, style: TextStyle(color: ZestTokens.statusCritical)),
          ),
      ],
    );
    picked?.call();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: LayoutBuilder(builder: (context, constraints) {
          final beside = constraints.maxWidth >= _besideFrom;
          final l10n = AppLocalizations.of(context)!;
          final who = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, height: 1.4, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
              const SizedBox(height: 4),
              // A long state in a long language is drawn a little smaller,
              // never cut off and never over the row's edge.
              FittedBox(fit: BoxFit.scaleDown, alignment: AlignmentDirectional.centerStart, child: status),
            ],
          );
          final hasMore = actions.isNotEmpty || onRemove != null;
          return ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ShareAvatar(name: name),
                const SizedBox(width: 12),
                Expanded(child: who),
                if (beside) ...[
                  // Lined up with the middle of the name and its pill.
                  for (final a in actions) ...[
                    const SizedBox(width: 6),
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: shareButton(key: a.key, label: a.label, onPressed: a.onPressed, kind: a.kind, dense: true),
                    ),
                  ],
                  if (onRemove != null) ...[
                    const SizedBox(width: 4),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: IconButton(
                        key: removeKey,
                        tooltip: removeLabel,
                        constraints: const BoxConstraints.tightFor(width: 34, height: 34),
                        padding: EdgeInsets.zero,
                        iconSize: 16,
                        color: ZestTokens.textTertiary,
                        onPressed: onRemove,
                        icon: const Icon(LucideIcons.userMinus),
                      ),
                    ),
                  ],
                ] else if (hasMore)
                  Builder(
                    builder: (buttonContext) => IconButton(
                      tooltip: l10n.zestCommonMoreActions,
                      constraints: const BoxConstraints.tightFor(width: 44, height: 44),
                      padding: EdgeInsets.zero,
                      iconSize: 18,
                      color: ZestTokens.textSecondary,
                      onPressed: () {
                        final box = buttonContext.findRenderObject()! as RenderBox;
                        final overlay = Navigator.of(buttonContext).overlay!.context.findRenderObject()! as RenderBox;
                        unawaited(_menu(
                          buttonContext,
                          RelativeRect.fromRect(
                            box.localToGlobal(Offset.zero, ancestor: overlay) & box.size,
                            Offset.zero & overlay.size,
                          ),
                        ));
                      },
                      icon: const Icon(LucideIcons.moreVertical),
                    ),
                  )
                else
                  const SizedBox(width: 44),
              ],
            ),
          );
        }),
      );
}
