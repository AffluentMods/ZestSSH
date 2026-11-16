import 'package:flutter/material.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';

/// The shared sticky pane footer (`.footer`), promoted from the Hosts editor.
///
/// A hairline top rule over a [ZestTokens.surfacePanel] bar, with an optional
/// [leading] slot on the left (e.g. Test buttons, a Delete button) and, pinned
/// to the right, exactly two buttons: a neutral **Cancel** and the pane's single
/// orange **Save**. The footer copy is Cancel + Save ONLY - a form-reset
/// ("Clear") belongs next to the pane's New/primary control, never here.
///
/// Save is the only primary/orange button on the pane; it is disabled whenever
/// [saveEnabled] is false (typically "not dirty") so an enabled Save is the
/// single always-visible signal of uncommitted edits.
class ZestPaneFooter extends StatelessWidget {
  const ZestPaneFooter({
    super.key,
    this.leading,
    this.onCancel,
    this.onSave,
    this.saveLabel,
    this.cancelLabel,
    this.saveEnabled = true,
    this.saveBusy = false,
  });

  /// Optional left-aligned content, opposite Cancel/Save.
  final Widget? leading;

  /// Cancel/close callback. Null disables the button.
  final VoidCallback? onCancel;

  /// Save callback. Fired only while [saveEnabled] and not [saveBusy].
  final VoidCallback? onSave;

  /// Override for the primary label (default localized "Save").
  final String? saveLabel;

  /// Override for the secondary label (default localized "Cancel").
  final String? cancelLabel;

  /// Whether Save is enabled (typically mirrors "is dirty").
  final bool saveEnabled;

  /// Show a spinner on Save and block taps while an in-flight save runs.
  final bool saveBusy;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ZestTokens.surfacePanel,
        border: Border(
          top: BorderSide(color: ZestTokens.borderSubtle, width: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        // The two buttons go under one another, right-aligned, where a narrow
        // pane or long words (French "Enregistrer le workflow") leave no room
        // for them side by side; they ran off the pane's edge. What stands at
        // the left takes what it needs, up to half the pane, and they have
        // the rest: as a flexible child it was given half whatever it used,
        // and they went under one another beside a short Delete(found on
        // the Alerts editor).
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              if (leading != null)
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: constraints.maxWidth / 2),
                  child: leading!,
                ),
              const SizedBox(width: ZestSizing.buttonGap),
              Expanded(
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: ZestSizing.buttonGap,
                  runSpacing: 8,
                  children: [
                    ZestButton(
                      label: cancelLabel ?? l10n?.zestCommonCancel ?? 'Cancel',
                      variant: ZestButtonVariant.secondary,
                      size: ZestButtonSize.large,
                      onPressed: onCancel,
                    ),
                    ZestButton(
                      label: saveLabel ?? l10n?.zestCommonSave ?? 'Save',
                      variant: ZestButtonVariant.primary,
                      size: ZestButtonSize.large,
                      isLoading: saveBusy,
                      onPressed: (saveEnabled && !saveBusy) ? onSave : null,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
