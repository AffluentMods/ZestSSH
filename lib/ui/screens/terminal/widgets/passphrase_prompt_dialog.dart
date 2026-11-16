import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/terminal/widgets/password_prompt_dialog.dart' show PromptCheckRow;
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Asks for the passphrase of a key a sign-in uses ([request]), as the app's
/// dialog (a phone's sheet). Escape and a tap outside leave it, as every
/// answer is a button (the close button is Cancel); one taken away unanswered
/// (its page replaced, the lock screen shown) leaves the request to be asked
/// again.
Future<void> showPassphrasePrompt(BuildContext context, PassphrasePromptRequest request) {
  return showZestModal<void>(
    context: context,
    size: ZestModalSize.compact,
    barrierDismissible: false,
    onDismissAttempt: () async => false,
    useRootNavigator: true,
    child: PassphrasePromptDialog(request: request),
  );
}

/// Dialog shown when an SSH key is encrypted and needs a passphrase.
///
/// Displays the target host/user, a passphrase field with visibility toggle,
/// an optional "Remember passphrase" checkbox, and Unlock / Cancel actions.
class PassphrasePromptDialog extends StatefulWidget {
  final PassphrasePromptRequest request;

  const PassphrasePromptDialog({super.key, required this.request});

  @override
  State<PassphrasePromptDialog> createState() => _PassphrasePromptDialogState();
}

class _PassphrasePromptDialogState extends State<PassphrasePromptDialog> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _savePassphrase = false;

  /// Answered once: Enter in the field and the button both submit.
  bool _answered = false;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final passphrase = _controller.text;
    if (passphrase.isEmpty || _answered) return;
    _answered = true;
    widget.request.completer.complete(
      PassphrasePromptResult(
        passphrase: passphrase,
        savePassphrase: _savePassphrase,
      ),
    );
    Navigator.of(context).pop();
  }

  void _cancel() {
    if (_answered) return;
    _answered = true;
    widget.request.completer.complete(null);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final req = widget.request;
    final l10n = AppLocalizations.of(context)!;

    // The app's dialog (the dialog rules, 3.4): neutral, its one footer
    // (Cancel, Unlock); the close button cancels, as Cancel does.
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.keyRound,
      title: l10n.passphrasePromptTitle,
      onClose: _cancel,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Target info. Recording mode: `user@host` goes through the
          // free-text rule (userNN@<fake host>).
          RedactedText(
            Redactable.freeText('${req.username}@${req.host}'),
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 13,
              color: AppColors.v3TextSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.passphrasePromptDescription,
            style: TextStyle(fontSize: 13, height: 1.45, color: AppColors.v3TextSecondary),
          ),
          const SizedBox(height: 14),

          // Passphrase field (its eye goes through the recording-mode gate).
          ZestTextField(
            controller: _controller,
            focusNode: _focusNode,
            hintText: l10n.passphrasePromptHint,
            obscureText: true,
            onSubmit: _submit,
          ),
          const SizedBox(height: 10),

          // Save checkbox
          PromptCheckRow(
            value: _savePassphrase,
            label: l10n.passphrasePromptRemember,
            onChanged: (v) => setState(() => _savePassphrase = v),
          ),
        ],
      ),
      secondaryAction: (label: l10n.cancel, onPressed: _cancel),
      primaryAction: (label: l10n.passphrasePromptUnlock, icon: null, onPressed: _submit),
    );
  }
}
