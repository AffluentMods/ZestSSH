import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';

/// The single stepped-pane shell the whole Cloud Sync flow lives in
/// (one shell for the whole flow: setup modal,
/// recovery-key page, storage modal and the mobile dialog all collapse into
/// this).
///
/// A header carrying EITHER a brand icon [tileIcon] (the account pane) OR a
/// back arrow [onBack] (a setup step), a [title], and a mono [subtitle] (the
/// "Step n of 3" slot); a scrolling [body]; and a sticky footer holding a
/// neutral secondary and the pane's single brand primary. The §1b accent layer
/// shows as a 2px brand rind along the top edge and a warm wash behind the
/// header.
///
/// Designed to FILL its parent (a fixed-size desktop dialog or a full mobile
/// screen), so give it a bounded height - host it under a `SizedBox`,
/// `Expanded`, or a `Dialog` with a fixed size, never an unbounded column.
/// [body] should scroll and carry its own padding (`.pane-body` is 14px).
class ZestStepScaffold extends StatelessWidget {
  const ZestStepScaffold({
    super.key,
    this.tileIcon,
    this.onBack,
    required this.title,
    this.subtitle,
    this.onClose,
    required this.body,
    this.footerLeading,
    this.primaryLabel,
    this.onPrimary,
    this.primaryEnabled = true,
    this.primaryBusy = false,
    this.secondaryLabel,
    this.onSecondary,
    this.showFooter = true,
  }) : assert(tileIcon == null || onBack == null,
            'The header shows either a brand tile OR a back arrow, not both.');

  /// Brand icon tile on the left (mutually exclusive with [onBack]).
  final IconData? tileIcon;

  /// Back arrow on the left (mutually exclusive with [tileIcon]).
  final VoidCallback? onBack;

  /// Already-localized pane title.
  final String title;

  /// Mono subtitle - e.g. "Step 1 of 3" or an account email. Null hides it.
  final String? subtitle;

  /// Close (×) affordance at the far right. Null hides it.
  final VoidCallback? onClose;

  /// The scrolling pane content (provide its own scroll view + 14px padding).
  final Widget body;

  /// Optional left-aligned footer content, opposite the buttons (e.g. a
  /// "Restore from cloud" button, or a Test-connection control).
  final Widget? footerLeading;

  /// Primary (brand) button label. Null hides the primary.
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final bool primaryEnabled;
  final bool primaryBusy;

  /// Secondary (neutral) button label - usually Cancel. Null hides it.
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  /// Hide the whole footer (a pane with no actions).
  final bool showFooter;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: ZestTokens.surfaceBase),
      child: Column(
        children: [
          // 2px brand rind along the very top edge of the pane.
          Container(height: 2, color: ZestTokens.brand),
          _StepHeader(
            tileIcon: tileIcon,
            onBack: onBack,
            title: title,
            subtitle: subtitle,
            onClose: onClose,
          ),
          Expanded(child: body),
          if (showFooter &&
              (primaryLabel != null ||
                  secondaryLabel != null ||
                  footerLeading != null))
            _StepFooter(
              leading: footerLeading,
              primaryLabel: primaryLabel,
              onPrimary: onPrimary,
              primaryEnabled: primaryEnabled,
              primaryBusy: primaryBusy,
              secondaryLabel: secondaryLabel,
              onSecondary: onSecondary,
            ),
        ],
      ),
    );
  }
}

class _StepHeader extends StatelessWidget {
  const _StepHeader({
    this.tileIcon,
    this.onBack,
    required this.title,
    this.subtitle,
    this.onClose,
  });

  final IconData? tileIcon;
  final VoidCallback? onBack;
  final String title;
  final String? subtitle;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        // Warm wash behind the header (an accent layer).
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [ZestTokens.brandSubtle, Colors.transparent],
        ),
        border: Border(
          bottom: BorderSide(color: ZestTokens.borderSubtle),
        ),
      ),
      child: Row(
        children: [
          if (tileIcon != null) ...[
            _BrandTile(icon: tileIcon!),
            const SizedBox(width: 10),
          ] else if (onBack != null) ...[
            _HeaderIconButton(
              icon: LucideIcons.arrowLeft,
              onTap: onBack!,
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: ZestTokens.textPrimary,
                    height: 1.25,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 1),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 11,
                      color: ZestTokens.textMuted,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (onClose != null) ...[
            const SizedBox(width: 8),
            _HeaderIconButton(
              icon: LucideIcons.x,
              onTap: onClose!,
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            ),
          ],
        ],
      ),
    );
  }
}

/// 34×34 brand-tinted icon tile - the account pane's identity glyph.
class _BrandTile extends StatelessWidget {
  const _BrandTile({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: ZestTokens.brandIconBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, size: 17, color: ZestTokens.brandInk),
    );
  }
}

/// A 30×30 ghost icon button for the header back / close affordances.
class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 16),
      onPressed: onTap,
      tooltip: tooltip,
      color: ZestTokens.textMuted,
      hoverColor: ZestTokens.surfaceRaisedAlt,
      constraints: const BoxConstraints.tightFor(width: 30, height: 30),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      splashRadius: 18,
    );
  }
}

/// The sticky pane footer (`.pane-ft`): a hairline top rule over a
/// [ZestTokens.surfacePanel] bar, an optional [leading] slot on the left, and
/// the neutral secondary + brand primary pinned right.
class _StepFooter extends StatelessWidget {
  const _StepFooter({
    this.leading,
    this.primaryLabel,
    this.onPrimary,
    this.primaryEnabled = true,
    this.primaryBusy = false,
    this.secondaryLabel,
    this.onSecondary,
  });

  final Widget? leading;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final bool primaryEnabled;
  final bool primaryBusy;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ZestTokens.surfacePanel,
        border: Border(top: BorderSide(color: ZestTokens.borderSubtle)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            ?leading,
            const Spacer(),
            if (secondaryLabel != null) ...[
              ZestButton(
                label: secondaryLabel!,
                variant: ZestButtonVariant.secondary,
                size: ZestButtonSize.large,
                onPressed: onSecondary,
              ),
              const SizedBox(width: ZestSizing.buttonGap),
            ],
            if (primaryLabel != null)
              ZestButton(
                label: primaryLabel!,
                variant: ZestButtonVariant.primary,
                size: ZestButtonSize.large,
                isLoading: primaryBusy,
                onPressed:
                    (primaryEnabled && !primaryBusy) ? onPrimary : null,
              ),
          ],
        ),
      ),
    );
  }
}
