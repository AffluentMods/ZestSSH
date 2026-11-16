import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInput;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/keyboard_lock_warning.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// A new master password for the sync vault, typed twice: the password and
/// its confirmation must match, and it must be 12 characters at least, of
/// strength 3 or more ([masterPasswordStrength]); each is said in the dialog.
/// Returns it, or null where the dialog is cancelled. Setting up sync, a
/// restore with the recovery key and a change of the password use it
/// ([title] says which: a change was asked once, with neither rule, and a slip
/// in it made a vault that only the recovery key could open). A password manager
/// is offered it when the dialog goes ahead, under the address of [account] where
/// the store is the account's.
Future<String?> showNewMasterPasswordDialog(BuildContext context, {String? title, String? account}) async {
  final l10n = AppLocalizations.of(context)!;
  final pwCtrl = TextEditingController();
  final confirmCtrl = TextEditingController();
  final pwFocus = FocusNode();
  final confirmFocus = FocusNode();
  String? error;
  int strengthScore = 0;

  var pwVisible = false;
  var confirmVisible = false;

  // In the app's dialog (the dialog rules, 3.4): it was a Material one, its
  // main button orange and its explainer in a colour of its own.
  final result = await showZestModal<String>(
    context: context,
    size: ZestModalSize.compact,
    barrierDismissible: false,
    child: StatefulBuilder(
      builder: (context, setLocal) {
        void submit() {
          if (pwCtrl.text.length < 12) {
            setLocal(() => error = l10n.profilePasswordTooShort);
            return;
          }
          if (masterPasswordStrength(pwCtrl.text) < 3) {
            setLocal(() => error = l10n.profilePasswordTooWeak);
            return;
          }
          if (pwCtrl.text != confirmCtrl.text) {
            setLocal(() => error = l10n.profilePasswordsDoNotMatch);
            return;
          }
          TextInput.finishAutofillContext();
          Navigator.pop(context, pwCtrl.text);
        }

        return ZestDialogShell(
        size: ZestModalSize.compact,
        tone: ZestDialogTone.neutral,
        icon: LucideIcons.lock,
        title: title ?? l10n.profileChooseMasterPassword,
        body: AutofillGroup(
          onDisposeAction: AutofillContextAction.cancel,
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.profileMasterPasswordExplainer,
              style: TextStyle(fontSize: 13, height: 1.45, color: AppColors.v3TextSecondary),
            ),
            const SizedBox(height: 16),
            if (account != null && account.isNotEmpty) ...[
              // What a password manager saves it under; nothing to type.
              TextField(
                key: const ValueKey('sync-password-account'),
                controller: TextEditingController(text: account),
                readOnly: true,
                autofillHints: const [AutofillHints.username],
                decoration: InputDecoration(labelText: l10n.twoStepEmailLabel),
              ),
              const SizedBox(height: 8),
            ],
            TextField(
              controller: pwCtrl,
              focusNode: pwFocus,
              obscureText: !pwVisible,
              autofocus: true,
              autofillHints: const [AutofillHints.newPassword],
              // Enter/Tab move to the confirm field (the eye toggle below is
              // excluded from traversal so Tab flows field → field).
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => confirmFocus.requestFocus(),
              onChanged: (v) =>
                  setLocal(() => strengthScore = masterPasswordStrength(v)),
              decoration: InputDecoration(
                labelText: l10n.profileMasterPasswordLabel,
                prefixIcon: const Icon(LucideIcons.lock),
                suffixIcon: ExcludeFocus(
                  child: IconButton(
                    tooltip: pwVisible ? AppLocalizations.of(context)!.zestDialogHide : AppLocalizations.of(context)!.zestDialogShow,
                    icon: Icon(pwVisible
                        ? LucideIcons.eyeOff
                        : LucideIcons.eye),
                    onPressed: () =>
                        setLocal(() => pwVisible = !pwVisible),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            // Password strength bar
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: strengthScore / 4,
                minHeight: 4,
                backgroundColor: AppColors.surface,
                valueColor: AlwaysStoppedAnimation(
                  strengthScore <= 1
                      ? AppColors.error
                      : strengthScore == 2
                          ? Colors.orange
                          : strengthScore == 3
                              ? Colors.amber
                              : AppColors.success,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                strengthScore <= 1
                    ? l10n.profileStrengthWeak
                    : strengthScore == 2
                        ? l10n.profileStrengthFair
                        : strengthScore == 3
                            ? l10n.profileStrengthGood
                            : l10n.profileStrengthStrong,
                style: TextStyle(
                  fontSize: 11,
                  color: strengthScore <= 1
                      ? AppColors.error
                      : strengthScore == 2
                          ? Colors.orange
                          : strengthScore == 3
                              ? Colors.amber
                              : AppColors.success,
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: confirmCtrl,
              focusNode: confirmFocus,
              obscureText: !confirmVisible,
              autofillHints: const [AutofillHints.newPassword],
              onSubmitted: (_) => submit(),
              decoration: InputDecoration(
                labelText: l10n.profileConfirmPasswordLabel,
                prefixIcon: const Icon(LucideIcons.lock),
                suffixIcon: ExcludeFocus(
                  child: IconButton(
                    tooltip: confirmVisible ? AppLocalizations.of(context)!.zestDialogHide : AppLocalizations.of(context)!.zestDialogShow,
                    icon: Icon(confirmVisible
                        ? LucideIcons.eyeOff
                        : LucideIcons.eye),
                    onPressed: () =>
                        setLocal(() => confirmVisible = !confirmVisible),
                  ),
                ),
              ),
            ),
            // Caps Lock on while CREATING the vault password is the worst
            // case - you'd set a password you can't reproduce. Warn (desktop).
            const KeyboardLockWarning(),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                l10n.syncPasswordManagerHint,
                style: TextStyle(fontSize: 12, color: AppColors.v3TextSecondary),
              ),
            ),
            if (error != null) ...[
              const SizedBox(height: 10),
              Text(
                error!,
                style: TextStyle(color: AppColors.v3Error, fontSize: 12),
              ),
            ],
          ],
        ),
        ),
        secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.pop(context)),
        primaryAction: (label: l10n.profileContinue, icon: null, onPressed: submit),
      );
      },
    ),
  );

  pwFocus.dispose();
  confirmFocus.dispose();
  // The typed password leaves the fields as the dialog closes (the result
  // holds it for the caller): it stayed in two controllers nobody disposed
  // until they were collected (found in a code audit).
  pwCtrl.clear();
  confirmCtrl.clear();
  return result;
}

/// Simple password strength scorer (0-4).
///
/// Checks length, character diversity, and basic patterns.
/// Not a replacement for zxcvbn, but catches "aaaaaaaaaaaa"
/// and similar low-entropy inputs that pass the length check.
int masterPasswordStrength(String pw) {
  if (pw.isEmpty) return 0;
  var score = 0;
  if (pw.length >= 12) score++;
  if (pw.length >= 16) score++;
  if (RegExp(r'[a-z]').hasMatch(pw) &&
      RegExp(r'[A-Z]').hasMatch(pw)) {
    score++;
  }
  if (RegExp(r'\d').hasMatch(pw)) score++;
  if (RegExp(r'[^a-zA-Z0-9]').hasMatch(pw)) score++;
  // Penalize obvious patterns.
  if (RegExp(r'^(.)\1+$').hasMatch(pw)) score = 0; // all same char
  if (RegExp(r'^(012|123|234|345|456|567|678|789|abc|bcd)', caseSensitive: false)
      .hasMatch(pw)) {
    score = score > 0 ? score - 1 : 0;
  }
  return score.clamp(0, 4);
}
