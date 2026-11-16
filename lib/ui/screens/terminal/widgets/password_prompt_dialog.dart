import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInput;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/settings_providers.dart' show recordingModeProvider;
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/recording_masked_controller.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Asks for the password a sign-in needs ([request]), as the app's dialog
/// (a phone's sheet). Escape and a tap outside leave it, as every answer is
/// a button (the close button is Cancel); one taken away unanswered (its page
/// replaced, the lock screen shown) leaves the request to be asked again.
Future<void> showPasswordPrompt(BuildContext context, PasswordPromptRequest request) {
  return showZestModal<void>(
    context: context,
    size: ZestModalSize.compact,
    barrierDismissible: false,
    onDismissAttempt: () async => false,
    useRootNavigator: true,
    child: PasswordPromptDialog(request: request),
  );
}

/// Dialog shown when a connection needs a password that isn't saved.
///
/// Displays the target host and username, a password field with
/// visibility toggle, an optional "Save to identity" checkbox,
/// and Connect / Cancel actions.
class PasswordPromptDialog extends StatefulWidget {
  final PasswordPromptRequest request;

  const PasswordPromptDialog({super.key, required this.request});

  @override
  State<PasswordPromptDialog> createState() => _PasswordPromptDialogState();
}

class _PasswordPromptDialogState extends State<PasswordPromptDialog> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  /// The user name, where it is asked for too (an RDP host with no key).
  /// Drawn as bullets while the screen is recorded: an account's name is
  /// masked wherever the app shows one, and this is where it is typed.
  final _username = RecordingMaskedController();
  bool _saveToIdentity = false;

  /// Answered once: Enter in the field and the button both submit.
  bool _answered = false;

  @override
  void dispose() {
    _controller.dispose();
    _username.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final password = _controller.text;
    if (password.isEmpty || _answered) return;
    final username = widget.request.askUsername ? _username.text.trim() : null;
    if (username != null && username.isEmpty) return;
    _answered = true;
    // A phone's password manager may have filled it; it is
    // not offered to save it from here.
    TextInput.finishAutofillContext(shouldSave: false);
    widget.request.completer.complete(
      PasswordPromptResult(
        password: password,
        saveToIdentity: _saveToIdentity,
        username: username,
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
    // (Cancel, Connect); the close button cancels, as Cancel does.
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.lock,
      title: l10n.passwordPromptTitle,
      onClose: _cancel,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Target info. Recording mode: `user@host` is exactly what a
          // screen share must not show, so it goes through the free-text
          // rule (userNN@<fake host>). With no user (a remote screen's VNC
          // password, 4.0) the host alone, masked as a host is: never
          // "@Demo desktop".
          RedactedText(
            req.username.isEmpty ? Redactable.host(req.host) : Redactable.freeText('${req.username}@${req.host}'),
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 13,
              color: AppColors.v3TextSecondary,
            ),
          ),
          // Attempt indicator
          if (req.attempt > 1) ...[
            const SizedBox(height: 4),
            Text(
              l10n.passwordPromptAttemptOf(req.attempt),
              style: TextStyle(fontSize: 12, color: AppColors.v3TextTertiary),
            ),
          ],
          const SizedBox(height: 14),

          // Why it is asked again (on retry), above the field.
          if (req.errorHint != null) ...[
            PromptError(req.errorHint!),
            const SizedBox(height: 10),
          ],

          // The account's user name, where the host has no key to say who
          // signs in (an RDP host, 4.0): typed as its server knows it.
          if (req.askUsername) ...[
            Consumer(builder: (context, ref, _) {
              ref.maskWhileRecording([_username]);
              return ZestTextField(
                key: const ValueKey('password-prompt-username'),
                controller: _username,
                hintText: l10n.passwordPromptUsernameHint,
                autofocus: true,
                // An account's name is never a word to correct or suggest
                // from (the strip above a phone's keyboard would show it
                // while the field draws bullets), and while recording no
                // autofill bar lists saved names over the dialog.
                literal: true,
                autofillHints: ref.watch(recordingModeProvider) ? null : const [AutofillHints.username],
                onSubmit: _focusNode.requestFocus,
              );
            }),
            const SizedBox(height: 10),
          ],

          // Password field (its eye goes through the recording-mode gate,
          // and it says when Caps Lock is on).
          ZestTextField(
            controller: _controller,
            focusNode: _focusNode,
            hintText: l10n.passwordPromptHint,
            // Where the user name is asked for too, that field comes first.
            autofocus: !req.askUsername,
            obscureText: true,
            // The phone's password manager can fill it.
            autofillHints: const [AutofillHints.password],
            onSubmit: _submit,
          ),

          // Save checkbox: not for a host that is not saved, which has
          // nowhere to keep the password.
          if (widget.request.offerSave) ...[
            const SizedBox(height: 10),
            PromptCheckRow(
              value: _saveToIdentity,
              label: l10n.passwordPromptSaveToIdentity,
              onChanged: (v) => setState(() => _saveToIdentity = v),
            ),
          ],
        ],
      ),
      secondaryAction: (label: l10n.cancel, onPressed: _cancel),
      primaryAction: (label: l10n.commonConnect, icon: null, onPressed: _submit),
    );
  }
}

/// Why a sign-in prompt is asked again ("Wrong password"), above its field.
class PromptError extends StatelessWidget {
  const PromptError(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(LucideIcons.alertCircle, size: 14, color: AppColors.v3Error),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.v3Error),
          ),
        ),
      ],
    );
  }
}

/// A sign-in prompt's choice to keep what was typed (Save this password,
/// Remember passphrase): the box and its words, the whole line a target.
class PromptCheckRow extends StatelessWidget {
  const PromptCheckRow({super.key, required this.value, required this.label, required this.onChanged});

  final bool value;
  final String label;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: Checkbox(
                  value: value,
                  onChanged: (v) => onChanged(v ?? false),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 13, color: AppColors.v3TextSecondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
