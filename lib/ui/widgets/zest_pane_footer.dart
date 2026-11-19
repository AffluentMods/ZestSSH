import 'package:flutter/material.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';

/// The shared sticky pane footer (`.footer`), promoted from the Hosts editor.
///
/// A hairline top rule over a [ZestTokens.surfacePanel] bar, with an optional
/// [leading] slot on the left (e.g. the Test group, a Delete button) and,
/// pinned to the right, the pane's single orange **Save**. There is no Cancel:
/// the pane's header close button leaves it (with the same question about
/// unsaved changes), and a form-reset ("Clear") belongs next to the pane's
/// New/primary control, never here.
///
/// Save is the only primary/orange button on the pane; it is disabled whenever
/// [saveEnabled] is false (typically "not dirty") so an enabled Save is the
/// single always-visible signal of uncommitted edits.
class ZestPaneFooter extends StatelessWidget {
  const ZestPaneFooter({
    super.key,
    this.leading,
    this.onSave,
    this.saveLabel,
    this.saveEnabled = true,
    this.saveBusy = false,
  });

  /// Optional left-aligned content, opposite Save.
  final Widget? leading;

  /// Save callback. Fired only while [saveEnabled] and not [saveBusy].
  final VoidCallback? onSave;

  /// Override for the primary label (default localized "Save").
  final String? saveLabel;

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
        // Save takes what its words need, up to half the pane (a longer label
        // goes to a second line inside it, French "Enregistrer le workflow" in
        // a narrow pane), and what stands at the left has the rest.
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              if (leading != null)
                Expanded(
                  child: Align(alignment: AlignmentDirectional.centerStart, child: leading!),
                )
              else
                const Spacer(),
              const SizedBox(width: ZestSizing.buttonGap),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: constraints.maxWidth / 2),
                child: ZestButton(
                  label: saveLabel ?? l10n?.zestCommonSave ?? 'Save',
                  variant: ZestButtonVariant.primary,
                  size: ZestButtonSize.large,
                  isLoading: saveBusy,
                  onPressed: (saveEnabled && !saveBusy) ? onSave : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
