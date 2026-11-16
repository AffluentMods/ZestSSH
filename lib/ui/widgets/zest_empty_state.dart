import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../theme/app_colors.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:zestssh/theme/zest_surfaces.dart' show readableShade;
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/button_box.dart';

/// The height of an empty page's buttons: 36 with a mouse, a finger's 48
/// where the app is touch sized (4.0 accessibility pass: 36 on a phone).
double zestEmptyStateButtonHeight(BuildContext context) => touchSizedAt(context) ? 48 : 36;

/// The ONE empty-state pattern for ZestSSH.
///
/// Every screen that can render with no content routes through this widget so
/// empty states look and behave identically everywhere. The pattern is:
///
///   * an [icon] - a glyph for the kind of thing that would appear here,
///   * a [title] - a one-line statement of WHAT would appear here,
///   * a [message] - a one-line statement of WHY it's empty, only where that
///     differs from the obvious (optional),
///   * a primary action that FILLS it - either the built-in button
///     ([actionLabel] + [onAction]) or a richer [action] slot (e.g. the
///     get-connected options on the hosts screen).
///
/// Feature-UNAVAILABLE emptiness (a Pro-gated feature not unlocked, ssh-agent
/// with no agent running, certificates on a platform that lacks them, …) is
/// expressed by setting [unavailable] and supplying a [message] that says what
/// is needed - and by offering NO action that cannot succeed. Do not pass an
/// [actionLabel]/[action] that would dead-end in that case.
///
/// Colors come only from theme-aware [AppColors] `v3*` tokens, so the same
/// widget reads correctly on desktop chrome and mobile alike.
class ZestEmptyState extends StatelessWidget {
  const ZestEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.actionIcon = LucideIcons.plus,
    this.action,
    this.primaryAction,
    this.secondaryAction,
    this.unavailable = false,
    this.iconSize = 48,
    this.maxWidth = 360,
    this.padding = const EdgeInsets.all(32),
  });

  /// Glyph for the kind of thing that belongs here.
  final IconData icon;

  /// One-line statement of WHAT would appear here.
  final String title;

  /// One-line statement of WHY it's empty (optional - only where it differs
  /// from the obvious, or to say what a feature needs first).
  final String? message;

  /// Label for the built-in primary action. Ignored when [action] is given, or
  /// when [unavailable] is true (an unavailable feature gets no dead CTA).
  final String? actionLabel;

  /// Callback for the built-in primary action.
  final VoidCallback? onAction;

  /// Leading icon for the built-in primary action button.
  final IconData actionIcon;

  /// A richer action slot that replaces the built-in button entirely - used
  /// where the fill path is more than one button (e.g. import / scan / restore
  /// / add). Ignored when [unavailable] is true.
  final Widget? action;

  /// Optional primary action rendered below the message - intended for a
  /// [ZestButton] of size large. Coexists with (and renders after) any legacy
  /// [action]/[actionLabel]. Ignored when [unavailable] is true.
  final Widget? primaryAction;

  /// Optional secondary action, rendered below [primaryAction]. Intended for a
  /// [ZestButton] of size large. Ignored when [unavailable] is true.
  final Widget? secondaryAction;

  /// Marks this as a feature that is unavailable rather than merely unused.
  /// Mutes the icon and suppresses any primary action so nothing dead-ends.
  final bool unavailable;

  /// Icon diameter. The standard is 48; full-bleed welcome states can go
  /// larger, tight sidebars smaller.
  final double iconSize;

  /// Caps the message width for comfortable line lengths.
  final double maxWidth;

  /// Outer padding around the centered column.
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    // Soft, as drawn since 3.0, but at 3:1 on the grounds an empty page
    // stands on (4.0 accessibility pass: it was 1.9 to 2.4:1).
    final grounds = [ZestTokens.surfaceBase, AppColors.v3Background, AppColors.v3Surface, AppColors.v3Elevated];
    final faded = unavailable
        ? AppColors.v3TextDisabled
        : AppColors.v3TextSecondary.withValues(alpha: 0.35);
    final iconColor = readableShade(Color.alphaBlend(faded, AppColors.v3Background), grounds, min: 3);

    Widget? actionWidget;
    if (!unavailable) {
      if (action != null) {
        actionWidget = action;
      } else if (actionLabel != null && onAction != null) {
        // The one button of an empty page: every page passes its "New ..."
        // here rather than a button of its own.
        actionWidget = ButtonBox(
          height: zestEmptyStateButtonHeight(context),
          child: FilledButton.icon(
            onPressed: onAction,
            icon: Icon(actionIcon, size: 16),
            label: Text(actionLabel!),
            style: FilledButton.styleFrom(
              minimumSize: Size(64, zestEmptyStateButtonHeight(context)),
              backgroundColor: AppColors.v3AccentPrimary,
              foregroundColor: AppColors.onBrand(AppColors.v3AccentPrimary),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              textStyle: const TextStyle(
                fontFamily: 'GeistSans',
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ),
        );
      }
    }

    // Actions rendered below the message. The legacy [action]/[actionLabel]
    // button (if any) comes first, then the new large-button slots. All are
    // suppressed when [unavailable] so nothing dead-ends. Each is as wide as
    // its words: a button that fills what it is given stretched across the
    // pane (one empty state had a 407px orange bar).
    final belowMessage = <Widget>[
      for (final w in <Widget?>[
        actionWidget,
        if (!unavailable) primaryAction,
        if (!unavailable) secondaryAction,
      ])
        if (w != null) IntrinsicWidth(child: w),
    ];

    final content = Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: iconSize, color: iconColor),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.v3TextPrimary,
            ),
          ),
          if (message != null) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Text(
                message!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.v3TextTertiary,
                  height: 1.5,
                ),
              ),
            ),
          ],
          for (var i = 0; i < belowMessage.length; i++) ...[
            SizedBox(height: i == 0 ? 20 : 12),
            belowMessage[i],
          ],
        ],
      ),
    );

    // Fill the FULL height of the parent pane and centre the content within it,
    // so a tall pane centres the message rather than parking it at an awkward
    // mid-height. The ConstrainedBox(minHeight) lets the content still scroll
    // when it would otherwise overflow a short pane.
    return LayoutBuilder(
      builder: (context, constraints) {
        final minHeight =
            constraints.maxHeight.isFinite ? constraints.maxHeight : 0.0;
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            child: Center(child: content),
          ),
        );
      },
    );
  }
}

/// The TIER-2 empty state: a single section on a screen that has OTHER
/// sections is empty.
///
/// Where [ZestEmptyState] (tier 1) owns a whole pane with an icon, heading and
/// a centred CTA, [ZestEmptyRow] is deliberately tiny - one italic line at
/// normal text size, optionally with an inline [action] on the trailing edge.
/// No icon, no heading, no centring, no vertical padding beyond normal row
/// spacing. Stacking three tier-1 states down one screen (as the Automation
/// Triggers tab used to) is ~900px of nothing; this is the fix.
///
/// Use tier 1 ONLY when the ENTIRE screen/pane is empty, and never more than
/// once per screen. Every other empty section is a [ZestEmptyRow].
class ZestEmptyRow extends StatelessWidget {
  const ZestEmptyRow({
    super.key,
    required this.message,
    this.action,
    this.padding = const EdgeInsets.symmetric(vertical: 10),
  });

  /// The one italic line, e.g. "No API keys yet".
  final String message;

  /// Optional inline action on the trailing edge (a small text button / link
  /// or a compact secondary [ZestButton]). Omitted when there's nothing to do.
  final Widget? action;

  /// Row padding. Defaults to normal row spacing - no extra vertical padding.
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 13,
                fontStyle: FontStyle.italic,
                color: AppColors.v3TextSecondary,
              ),
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: 12),
            action!,
          ],
        ],
      ),
    );
  }
}
