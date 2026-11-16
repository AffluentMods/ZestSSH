import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';

/// The right-docked detail pane chrome: a 48px header with the title, an
/// optional back chevron for a pushed level, the X at the far right, the
/// content, and an optional sticky footer. The same shape the docked Theme
/// Designer and sync-storage editors use inside Settings, lifted out so the
/// Help panel (help/feedback/support spec, section 2) can be the same
/// component at shell level.
class DockPanel extends StatelessWidget {
  const DockPanel({
    super.key,
    required this.title,
    required this.onClose,
    required this.child,
    this.onBack,
    this.headerAction,
    this.footer,
    this.width = 400,
  });

  final String title;
  final VoidCallback onClose;
  final Widget child;

  /// Set on a pushed level: shows the back chevron before the title.
  final VoidCallback? onBack;

  /// An optional control shown in the header between the title and the X
  /// (the Help panel puts its "What's new" link here).
  final Widget? headerAction;

  /// Sticky footer (a form's actions), separated by a hairline.
  final Widget? footer;
  final double width;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The panel is its own focus scope: Tab and Shift+Tab walk the panel's
    // header buttons, fields and footer in order and wrap around inside it,
    // the way a dialog behaves. Without it, reading-order traversal runs
    // over the whole window and a Tab from a field lands on whatever the
    // shell shows beside the panel (sidebar rows, host cards, a terminal).
    return FocusScope(
      debugLabel: 'DockPanel',
      child: SizedBox(
        width: width,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.v3Surface,
            border: Border(left: BorderSide(color: AppColors.v3BorderSubtle)),
          ),
          child: Column(
            children: [
              Container(
                height: 48,
                padding: EdgeInsets.fromLTRB(onBack == null ? 16 : 6, 0, 8, 0),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: AppColors.v3BorderSubtle),
                  ),
                ),
                child: Row(
                  children: [
                    // No tooltip on the chevron: a tooltip anchored under a
                    // header button lands on the first field label, and a
                    // back chevron beside a title needs no explanation.
                    if (onBack != null)
                      Semantics(
                        label: l10n.back,
                        button: true,
                        child: IconButton(
                          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                          icon: Icon(LucideIcons.chevronLeft,
                              size: 20, color: AppColors.v3TextSecondary),
                          onPressed: onBack,
                        ),
                      ),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.v3TextPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    ?headerAction,
                    IconButton(
                      icon: Icon(LucideIcons.x,
                          size: 20, color: AppColors.v3TextSecondary),
                      tooltip: l10n.close,
                      onPressed: onClose,
                    ),
                  ],
                ),
              ),
              Expanded(child: child),
              if (footer != null)
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(color: AppColors.v3BorderSubtle),
                    ),
                  ),
                  child: footer,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
