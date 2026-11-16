import 'package:flutter/material.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// The question the account page asks before signing out, before deleting
/// what is on this device, and before deleting the account: the app's own
/// dialog (it was a plain one, built in the page).
///
/// [destructive] is for what cannot be taken back: the dialog has that tone
/// and its button says Delete. Otherwise the button says Continue. True only
/// for that button: Cancel is false, and a question that was left (Escape, a
/// click beside it) is null, which every caller takes for a no.
Future<bool?> askAccountQuestion(
  BuildContext context, {
  required String title,
  required String message,
  bool destructive = false,
}) {
  final l10n = AppLocalizations.of(context)!;
  return ZestConfirmDialog.show(
    context,
    tone: destructive ? ZestDialogTone.destructive : ZestDialogTone.neutral,
    title: title,
    body: message,
    confirmLabel: destructive ? l10n.delete : l10n.profileContinue,
  );
}
