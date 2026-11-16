import 'package:flutter/widgets.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/services/sync_setup_state_service.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/error_translator.dart';

/// Setup stepping aside for a vault that another of the account's devices
/// created while this one was being set up (3.0).
///
/// Setup looks at the store, finds no vault, and has the person choose a
/// password and write a recovery key down, which takes minutes. Its first
/// write then asks to be made only where nothing is ([SyncBackend.push] with
/// createOnly), and a store that holds a vault by then refuses it. Nothing
/// was created, so the password and the recovery key of this run open
/// nothing: the person is told so, and joins the vault that is there.

/// The vault that was created meanwhile, or null when [refusal] says nothing
/// of the kind: it was no refusal of that sort, the store holds no vault, or
/// the store cannot be asked (what the write failed with then stands).
///
/// A store that honours "only where nothing is" refuses with a
/// [SyncConflictException]. A hosted server from before it did refuses a
/// second setup because the keys it is sent are not the account's
/// ([SyncKeysMismatchException]).
Future<SyncStatus?> vaultSetUpMeanwhile(SyncBackend backend, Object refusal) async {
  if (refusal is! SyncConflictException && refusal is! SyncKeysMismatchException) return null;
  try {
    final status = await backend.getStatus();
    return status.hasData ? status : null;
  } catch (_) {
    return null;
  }
}

/// Tells the person that sync was set up from another device while this one
/// was at it, that nothing was created here, and that the recovery key they
/// were just shown opens nothing. Returns when they have read it.
Future<void> showSyncSetUpElsewhere(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.warning,
    title: l10n.syncSetupElsewhereTitle,
    body: l10n.syncSetupElsewhereBody,
    bullets: [l10n.syncSetupElsewhereNext],
    // The one sentence that warns, in amber (3.4): it was a bullet.
    warning: l10n.syncSetupElsewhereKey,
    confirmLabel: l10n.profileContinue,
    showCancel: false,
  );
}

/// Steps setup aside when [refusal] of its first write means a vault was
/// created meanwhile, and returns that vault for the caller to join: sync is
/// no longer shown as running, what this run of setup had kept is forgotten
/// (the salts of a password and a recovery key that open nothing, and how far
/// it had come), and the person is told. Null when [refusal] means something
/// else: nothing is forgotten and nothing is said.
Future<SyncStatus?> stepAsideIfSetUpElsewhere(
  BuildContext context, {
  required SyncBackend backend,
  required SyncSetupStateService setup,
  required SyncStatusNotifier syncing,
  required Object refusal,
}) async {
  final theirs = await vaultSetUpMeanwhile(backend, refusal);
  if (theirs == null) return null;
  syncing.setSyncing(false);
  await setup.reset();
  if (context.mounted) await showSyncSetUpElsewhere(context);
  return theirs;
}

/// What setup is said to have failed with: the store's own words or the
/// network's, never the exception as it was thrown, and without the full stop
/// of its last sentence, since the sentence it is put into ends with one.
String setupFailureSaid(Object failure) {
  final said = failure is SyncException
      ? failure.message
      : describeNetworkError(failure, subject: gl10n.errSubjectSyncServer).message;
  return said.trimRight().replaceFirst(RegExp(r'[.。]$'), '');
}

/// What stands behind [setupFailureSaid], for the notice's "Copy details".
String setupFailureDetails(Object failure) {
  if (failure is SyncException) return failure.detail ?? failure.toString();
  return describeNetworkError(failure, subject: gl10n.errSubjectSyncServer).detail ?? failure.toString();
}
