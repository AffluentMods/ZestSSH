import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/recovery_key_service.dart';
import 'package:zestssh/services/sync/recovery_key_replacement.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync/sync_failure.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/logger.dart';

/// Checks a recovery key the person types back from their kit (3.0),
/// so a lost or mistyped kit is found out now and not on the
/// day it is needed. Nothing changes anywhere: the store is only read. A key
/// that does not open the vault can be typed again; one that opens another
/// vault, or none stored at all, offers [onMakeNew] (making a new key needs
/// the master password, which the person still knows).
Future<void> runRecoveryKeyCheck(
  BuildContext context,
  WidgetRef ref, {
  required SyncBackend backend,
  required List<int> deviceDek,
  required Future<void> Function() onMakeNew,
}) async {
  final l10n = AppLocalizations.of(context)!;
  // Typing the key paints it on screen: the recording mode gate first.
  if (!await confirmRevealWhileRecording(context, ref)) return;
  if (!context.mounted) return;
  RecoveryKeyCheck? outcome;
  final typed = await showZestInputDialog(
    context: context,
    title: l10n.recoveryCheckTitle,
    subtitle: l10n.recoveryCheckBody,
    icon: LucideIcons.shieldCheck,
    fieldLabel: l10n.recoveryCheckField,
    hintText: 'ZEST-XXXX-XXXX-XXXX-XXXX-XXXX',
    confirmLabel: l10n.recoveryCheckAction,
    cancelLabel: l10n.cancel,
    busyLabel: l10n.recoveryCheckChecking,
    onConfirm: (value) async {
      if (RecoveryKeyService.tidy(value) == null) return l10n.recoveryCheckFormat;
      try {
        outcome = await checkRecoveryKey(backend, value, deviceDek: deviceDek);
      } on SyncException catch (e) {
        return e.message;
      } catch (e) {
        AppLogger.warning('Recovery key check: the store could not be read: $e');
        return SyncFailure.ofStore(e, hosted: backend.kind.isHosted).message;
      }
      // Not the key: typed again, with the dialog still open.
      return outcome == RecoveryKeyCheck.wrongKey ? l10n.recoveryCheckWrong : null;
    },
  );
  final result = outcome;
  if (typed == null || result == null || result == RecoveryKeyCheck.wrongKey || !context.mounted) return;
  if (result == RecoveryKeyCheck.works) {
    await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.success,
      icon: LucideIcons.checkCircle2,
      title: l10n.recoveryCheckWorksTitle,
      body: l10n.recoveryCheckWorksBody,
      showCancel: false,
      confirmLabel: l10n.close,
    );
    return;
  }
  // A recovery that would not work: said in its amber sentence (the whole
  // dialog was yellow).
  final makeNew = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.warning,
    title: result == RecoveryKeyCheck.otherVault ? l10n.recoveryCheckOtherTitle : l10n.recoveryCheckNoneTitle,
    body: '',
    warning: result == RecoveryKeyCheck.otherVault ? l10n.recoveryCheckOtherBody : l10n.recoveryCheckNoneBody,
    confirmLabel: l10n.recoveryCheckMakeNew,
    cancelLabel: l10n.close,
  );
  if (makeNew == true && context.mounted) await onMakeNew();
}
