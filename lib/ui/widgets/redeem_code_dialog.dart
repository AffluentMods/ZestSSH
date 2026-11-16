import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/redeem_service.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Shows the "Redeem a code" dialog. Returns the [RedeemResult] on success,
/// or for a code that gives a team seats ([RedeemResult.teamCode], which the
/// caller takes to a team); on any other failure the dialog stays open and
/// shows the error under the field; null if the user cancelled. The caller
/// refreshes entitlements and shows a confirmation on a result that is ok.
///
/// The app's own input dialog, in the app's language (it was a plain dialog
/// with its words written in English). [redeem] is what redeems the code:
/// the service, unless a test hands in its own.
Future<RedeemResult?> showRedeemCodeDialog(
  BuildContext context, {
  Future<RedeemResult> Function(String code)? redeem,
}) async {
  final l10n = AppLocalizations.of(context)!;
  RedeemResult? redeemed;
  final entered = await showZestInputDialog(
    context: context,
    title: l10n.settingsMobRedeemCode,
    subtitle: l10n.redeemDialogBody,
    icon: LucideIcons.gift,
    // The shape of a code, the same in every language.
    hintText: 'ZEST-XXXX-XXXX-XXXX',
    confirmLabel: l10n.redeemDialogAction,
    busyLabel: l10n.redeemDialogBusy,
    inputFormatters: [
      LengthLimitingTextInputFormatter(128),
      // Uppercase as they type so it matches the stored form.
      TextInputFormatter.withFunction((oldValue, newValue) => newValue.copyWith(text: newValue.text.toUpperCase())),
    ],
    validator: (value) => value.trim().isEmpty ? l10n.redeemSvcEnterCode : null,
    // A code that was not redeemed is said under the field, and the dialog
    // stays for another try.
    onConfirm: (value) async {
      final result = await (redeem ?? RedeemService.redeem)(value);
      if (!result.ok && !result.teamCode) return result.message;
      redeemed = result;
      return null;
    },
  );
  return entered == null ? null : redeemed;
}
