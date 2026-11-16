import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';

/// Floating toolbar that appears when text is selected in the terminal.
///
/// Shows Copy, Share, and Save as Snippet actions in a compact
/// pill-shaped overlay above the terminal.
class TerminalSelectionToolbar extends StatelessWidget {
  final String selectedText;
  final VoidCallback onCopy;
  final VoidCallback? onSaveAsSnippet;
  final VoidCallback onDismiss;

  const TerminalSelectionToolbar({
    super.key,
    required this.selectedText,
    required this.onCopy,
    this.onSaveAsSnippet,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.1),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Copy button
          _ToolbarButton(
            icon: LucideIcons.copy,
            label: AppLocalizations.of(context)!.copy,
            onTap: () {
              Clipboard.setData(ClipboardData(text: selectedText));
              onCopy();
            },
          ),

          _divider(),

          // Share button
          _ToolbarButton(
            icon: LucideIcons.share2,
            label: AppLocalizations.of(context)!.homeShare,
            onTap: () {
              Share.share(selectedText);
              onDismiss();
            },
          ),

          // Save as snippet (optional - only when handler provided)
          if (onSaveAsSnippet != null) ...[
            _divider(),
            _ToolbarButton(
              icon: LucideIcons.code,
              label: AppLocalizations.of(context)!.autoWizSnippet,
              onTap: () {
                onSaveAsSnippet!();
                onDismiss();
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _divider() {
    return Container(
      width: 1,
      height: 20,
      color: Colors.white.withValues(alpha: 0.1),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ToolbarButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // A button, named by its text alone (it was named "Copy button" on top of
    // its text, so a screen reader said both).
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: AppColors.onSurface),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.onSurface,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
