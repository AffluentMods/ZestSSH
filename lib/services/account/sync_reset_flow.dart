import 'package:zestssh/services/account/account_deletion_flow.dart' show FreshSignIn;
import 'package:zestssh/services/account/sync_reset_api.dart';
import 'package:zestssh/utils/logger.dart';

/// Where a reset is, for the progress text.
enum SyncResetStage { signingIn, stoppingSync, resetting, turningOffHere }

/// How a reset ended.
sealed class SyncResetOutcome {
  const SyncResetOutcome();
}

/// The person backed out before anything was changed. Sync runs as before.
class SyncResetCancelled extends SyncResetOutcome {
  const SyncResetCancelled();
}

/// The fresh sign-in was for a different account. Nothing was changed.
class SyncResetWrongAccount extends SyncResetOutcome {
  const SyncResetWrongAccount();
}

/// Nothing was reset. Sync runs as before.
class SyncResetFailed extends SyncResetOutcome {
  const SyncResetFailed({required this.code, required this.detail, this.cause});

  /// What stopped the request to the server, where one was stopped
  /// ([SyncResetException.stopped]): for saying how ZestSSH Cloud stands,
  /// where that was the reason.
  final Object? cause;

  /// `sign-in-failed`, or a code from [SyncResetException].
  final String code;

  /// What was thrown or answered, for "Copy details".
  final String detail;
}

/// The cloud copy is out of use and sync is off on this device, ready to be
/// set up again.
class SyncResetDone extends SyncResetOutcome {
  const SyncResetDone({required this.hadData, required this.keptDays});

  /// False when the account held no cloud copy to begin with.
  final bool hadData;

  /// For how many days the copy that was set aside is kept; 0 when the
  /// server does not say.
  final int keptDays;
}

/// Resetting cloud sync on ZestSSH Cloud (3.0), for the person who can no
/// longer prove the master password and has no recovery key: the cloud copy
/// is taken out of use so that sync can be set up again.
///
/// Order: sign in again (nothing has changed yet, so backing out is free);
/// turn sync off and wait for a cycle already running, so that nothing is
/// written while the copy goes; ask the server; then turn sync off on this
/// device, forgetting the keys of the copy that is gone, and lift the hold
/// on sync so that it runs again once it is set up anew. When the server
/// refuses, sync is turned back on and nothing has changed.
///
/// Every step is injected, so the order is testable without a network.
class SyncResetFlow {
  SyncResetFlow({
    required this.isSameAccount,
    required this.signInAgain,
    required this.suspendSync,
    required this.resumeSync,
    required this.api,
    required this.disconnectHere,
  });

  /// Whether a fresh sign-in is for the account whose sync is reset.
  final bool Function(FreshSignIn fresh) isSameAccount;

  /// Asks the person to sign in again. Null when they back out.
  final Future<FreshSignIn?> Function() signInAgain;

  /// Turns sync off and waits for a cycle already running.
  final Future<void> Function() suspendSync;

  /// Turns sync back on, when nothing was reset.
  final void Function() resumeSync;

  final SyncResetApi api;

  /// Turns sync off on this device and forgets its sync keys.
  final Future<void> Function() disconnectHere;

  Future<SyncResetOutcome> run({void Function(SyncResetStage stage)? onStage}) async {
    onStage?.call(SyncResetStage.signingIn);
    final FreshSignIn? fresh;
    try {
      fresh = await signInAgain();
    } catch (e) {
      AppLogger.warning('Sync reset: signing in again failed: $e');
      return SyncResetFailed(code: 'sign-in-failed', detail: '$e');
    }
    if (fresh == null) return const SyncResetCancelled();
    if (!isSameAccount(fresh)) return const SyncResetWrongAccount();

    onStage?.call(SyncResetStage.stoppingSync);
    await suspendSync();

    onStage?.call(SyncResetStage.resetting);
    final SyncResetResult result;
    try {
      result = await api.reset(token: fresh.token, confirmUid: fresh.uid);
    } on SyncResetException catch (e) {
      AppLogger.warning('Sync reset: the server refused: $e');
      resumeSync();
      return SyncResetFailed(code: e.code, detail: e.detail, cause: e.stopped);
    }

    // The copy is out of use: this device's keys open nothing now. They are
    // forgotten first; only then is the hold on sync lifted, so that no
    // cycle runs with them, and sync can run again once it is set up anew.
    onStage?.call(SyncResetStage.turningOffHere);
    await disconnectHere();
    resumeSync();
    return SyncResetDone(hadData: result.hadData, keptDays: result.keptDays);
  }
}
