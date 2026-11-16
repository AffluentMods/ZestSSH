import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/zest_scroll_fade.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_pane_footer.dart';

/// ZestSSH 1.7 detail-pane scaffold: the standard chrome for the right-hand
/// side of a [ZestMasterDetail] (or any full-pane editor).
///
/// Top → bottom it is:
///  1. a HEADER - [title] (with an optional [subtitle]); a brand DIRTY DOT
///     right of the title whenever [isDirty]; then, on the right, an optional
///     [modeToggle], an optional `+ {newLabel}` action, and a close "X" at the
///     far right. There is deliberately NO back arrow - closing is the X, and
///     navigation is the list on the left.
///  2. a scrollable BODY.
///  3. a STICKY FOOTER pinned to the pane bottom (never floating in flow):
///     [footerLeading] on the left, then Cancel + Save on the right.
///
/// The commit signal is baked in: **Save is disabled until [isDirty]**, so an
/// enabled Save is the single, always-visible indicator of uncommitted edits
/// (reinforced by the dirty dot beside the title).
class ZestDetailScaffold extends StatelessWidget {
  const ZestDetailScaffold({
    super.key,
    required this.title,
    this.subtitle,
    this.subtitleMono = false,
    this.icon,
    this.iconColor,
    this.iconBackground,
    this.badge,
    this.modeToggle,
    this.onNew,
    this.newLabel,
    required this.body,
    this.isDirty = false,
    this.onSave,
    this.onCancel,
    this.saveLabel,
    this.cancelLabel,
    this.onClose,
    this.footerLeading,
    this.headerAction,
    this.footer,
    this.notice,
  });

  /// Already-localized pane title.
  final String title;

  /// Already-localized secondary line under the title (optional).
  final String? subtitle;

  /// Render [subtitle] in the mono family (JetBrainsMono) instead of the sans
  /// body face. Use for identity-like subtitles: a fingerprint, a command, a
  /// `user@host:port`, a `source → dest` tunnel. Matches the Hosts/Monitor
  /// header anatomy.
  final bool subtitleMono;

  /// Optional leading glyph for the tinted icon tile at the far left of the
  /// header. When null there is no tile (older callers look unchanged).
  final IconData? icon;

  /// Icon glyph colour. Defaults to the brand accent. Pass the object's own
  /// colour where it has one (a network's colour, a snippet category).
  final Color? iconColor;

  /// Icon tile fill. Defaults to [ZestTokens.brandIconBg].
  final Color? iconBackground;

  /// Optional type/state badge shown immediately right of the title (e.g. a key
  /// algorithm, a snippet category, a forward type, a schedule). Build it with
  /// [ZestDetailBadge] for the shared pill styling.
  final Widget? badge;

  /// An optional segmented control (e.g. Simple / Advanced) shown left of the
  /// New action in the header.
  final Widget? modeToggle;

  /// Header "new" action callback. The `+ {newLabel}` button shows only when
  /// this is non-null.
  final VoidCallback? onNew;

  /// Already-localized label for the header New action.
  final String? newLabel;

  /// The pane body. Wrapped so it scrolls when taller than the pane.
  final Widget body;

  /// Whether the body has uncommitted edits. Enables Save and shows the dirty
  /// dot beside the title.
  final bool isDirty;

  /// Footer Save callback. Fired only while [isDirty] (Save is disabled
  /// otherwise).
  final VoidCallback? onSave;

  /// Footer Cancel callback (dismisses / discards). A form-reset ("Clear")
  /// belongs next to the New control, never in the footer.
  final VoidCallback? onCancel;

  /// Override for the primary footer label (default "Save").
  final String? saveLabel;

  /// Override for the secondary footer label (default "Cancel").
  final String? cancelLabel;

  /// Header close ("X") callback.
  final VoidCallback? onClose;

  /// A leading footer slot (e.g. a Run or Delete button) shown at the far left
  /// of the footer, opposite Cancel/Save.
  final Widget? footerLeading;

  /// An optional header action shown in the header just LEFT of the close "X"
  /// (and right of any [modeToggle]) - e.g. a Run button. Purely additive: when
  /// null the header looks exactly as before.
  final Widget? headerAction;

  /// Replaces the standard Cancel + Save footer for a pane whose actions are
  /// not a save (a read-only reader with Copy / Save as snippet). Build it
  /// with [ZestPaneFooter] so it keeps the same sticky chrome. Null keeps the
  /// standard footer.
  final Widget? footer;

  /// A notice just above the footer, which does not scroll away with the body:
  /// what stopped a save, beside the button that was pressed.
  final Widget? notice;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: ZestTokens.surfaceBase,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context),
          // The body scrolls with room under its last field, and fades at
          // an edge where more waits (a field was cut in half by the footer).
          Expanded(
            child: ZestScrollFade(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 24),
                child: body,
              ),
            ),
          ),
          ?notice,
          footer ?? _footer(context),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: iconBackground ?? ZestTokens.brandIconBg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 16, color: iconColor ?? ZestTokens.brandInk),
            ),
            const SizedBox(width: 11),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                          color: ZestTokens.textPrimary,
                          height: 1.1,
                        ),
                      ),
                    ),
                    if (badge != null) ...[
                      const SizedBox(width: 8),
                      badge!,
                    ],
                    if (isDirty) ...[
                      const SizedBox(width: ZestSizing.buttonGap),
                      Tooltip(
                        message: l10n?.zestDetailUnsaved ?? 'Unsaved changes',
                        child: const _DirtyDot(),
                      ),
                    ],
                  ],
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: subtitleMono ? 11.5 : 13,
                      fontFamily: subtitleMono ? 'JetBrainsMono' : null,
                      color: subtitleMono
                          ? ZestTokens.textMuted
                          : ZestTokens.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (modeToggle != null) ...[
            modeToggle!,
            const SizedBox(width: ZestSizing.buttonGap),
          ],
          if (headerAction != null) ...[
            headerAction!,
            const SizedBox(width: ZestSizing.buttonGap),
          ],
          IconButton(
            icon: const Icon(LucideIcons.x, size: 18),
            color: ZestTokens.textSecondary,
            splashRadius: 18,
            tooltip: l10n?.zestCommonCancel ?? 'Cancel',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }

  Widget _footer(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Delegates to the shared sticky footer so every detail pane's Cancel + Save
    // row is one implementation. The visible uncommitted-edits signal (Save is
    // DISABLED until [isDirty]) is preserved via [saveEnabled].
    return ZestPaneFooter(
      leading: footerLeading,
      onCancel: onCancel,
      cancelLabel: cancelLabel ?? l10n?.zestCommonCancel,
      onSave: onSave,
      saveEnabled: isDirty,
      saveLabel: saveLabel ?? l10n?.zestCommonSave,
    );
  }
}

/// The shared type/state badge pill for a detail-pane header (the small chip
/// right of the title: a key algorithm, a snippet category, a forward type, a
/// schedule): 10px text, 4px radius, tight pad.
class ZestDetailBadge extends StatelessWidget {
  const ZestDetailBadge({
    super.key,
    required this.label,
    this.color,
    this.background,
  });

  /// Already-localized (or already-formatted) badge text.
  final String label;

  /// Text colour. Defaults to the brand accent.
  final Color? color;

  /// Fill. Defaults to [ZestTokens.brandBadge].
  final Color? background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: background ?? ZestTokens.brandBadge,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: color ?? ZestTokens.brandInk,
        ),
      ),
    );
  }
}

/// The 6px brand dot shown beside a dirty title.
class _DirtyDot extends StatelessWidget {
  const _DirtyDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: ZestTokens.brand,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// The outcome of the shared discard guard.
enum DiscardChoice { save, discard, cancel }

/// Prompt the user about unsaved edits before navigating away from a dirty
/// detail. Returns [DiscardChoice.save] / [DiscardChoice.discard] /
/// [DiscardChoice.cancel]; dismissing the dialog (barrier tap / back) counts as
/// [DiscardChoice.cancel].
///
/// The per-feature `confirmDiscardIfDirty` that decides WHEN to show this lives
/// in each feature controller; this helper is just the dialog.
Future<DiscardChoice> showZestDiscardDialog(BuildContext context) async {
  final l10n = AppLocalizations.of(context);
  // The app's own dialog shell (it was a plain dialog), as the dialog rules of
  // 3.4 have it: Cancel and Save, the main button, at the right; Discard, the
  // side option, a red link at the left. Enter does nothing here: none of the
  // three is the one to take without looking. An ordinary question: nothing
  // amber.
  final choice = await showZestModal<DiscardChoice>(
    context: context,
    size: ZestModalSize.compact,
    child: Builder(
      builder: (dialogContext) => ZestDialogShell(
        size: ZestModalSize.compact,
        tone: ZestDialogTone.neutral,
        title: l10n?.zestDiscardTitle ?? 'Unsaved changes',
        body: Text(
          l10n?.zestDiscardBody ?? 'You have unsaved changes. Save them before switching?',
          style: TextStyle(color: ZestTokens.textSecondary, fontSize: 13, height: 1.45),
        ),
        primaryAction: (
          label: l10n?.zestDiscardSave ?? 'Save',
          icon: null,
          onPressed: () => Navigator.of(dialogContext).pop(DiscardChoice.save),
        ),
        secondaryAction: (
          label: l10n?.zestDiscardCancel ?? 'Cancel',
          onPressed: () => Navigator.of(dialogContext).pop(DiscardChoice.cancel),
        ),
        tertiaryDanger: true,
        tertiaryAction: (
          label: l10n?.zestDiscardDiscard ?? 'Discard',
          onPressed: () => Navigator.of(dialogContext).pop(DiscardChoice.discard),
        ),
      ),
    ),
  );
  return choice ?? DiscardChoice.cancel;
}
