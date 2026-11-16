import 'dart:typed_data';

import 'package:zestssh/services/account/account_deletion_api.dart';
import 'package:zestssh/utils/logger.dart';

/// A sign-in made moments ago, for the deletion step that requires one.
class FreshSignIn {
  const FreshSignIn({required this.token, required this.uid, this.email = ''});

  /// The bearer the server accepts: a Firebase ID token on phones, the
  /// session token from the browser sign-in on desktop.
  final String token;

  /// The account the person signed in to.
  final String uid;

  /// Its email, when known, for matching a desktop session saved before
  /// account ids were.
  final String email;
}

/// Where the deletion is, for the progress text.
enum AccountDeletionStage {
  signingIn,
  stoppingSync,
  deletingSyncStore,
  deletingAccount,
  verifying,
}

/// How the server side of a deletion ended.
sealed class AccountDeletionOutcome {
  const AccountDeletionOutcome();
}

/// The person backed out before anything was deleted. Sync runs as before.
class AccountDeletionCancelled extends AccountDeletionOutcome {
  const AccountDeletionCancelled();
}

/// The fresh sign-in was for a different account. Nothing was deleted.
class AccountDeletionWrongAccount extends AccountDeletionOutcome {
  const AccountDeletionWrongAccount();
}

/// The server side stopped part way or failed outright.
class AccountDeletionFailed extends AccountDeletionOutcome {
  const AccountDeletionFailed({
    required this.code,
    required this.somethingDeleted,
    this.orchards = const [],
    this.cause,
    this.keptUntil,
  });

  /// For `sync-reset-kept`: the day from which the account can be deleted,
  /// once the cloud copy Reset cloud sync set aside is no longer kept
  /// ([AccountDeletionException.keptUntil]).
  final DateTime? keptUntil;

  /// What stopped a request to the server, where one was stopped
  /// ([AccountDeletionException.stopped]): for saying how ZestSSH Cloud
  /// stands, where that was the reason.
  final Object? cause;

  /// `sign-in-failed`, `sync-store-failed`, `not-verified`, `sole-owner`,
  /// `sync-reset-kept`, or a server code from [AccountDeletionException].
  final String code;

  /// For `sole-owner`: the Orchards to hand over first, as the check that
  /// found them names them (names on this device, ids from the server).
  final List<String> orchards;

  /// True when some data was already deleted. Sync then stays off and this
  /// device's sync keys are forgotten, so nothing is uploaded again; running
  /// Delete account once more finishes the job.
  final bool somethingDeleted;
}

/// The server deleted the account, its synced data and the sign-in, and a
/// check from this device confirmed nothing is left. Sync is off and this
/// device no longer holds the account. Only local data remains.
class AccountDeletionServerDone extends AccountDeletionOutcome {
  const AccountDeletionServerDone();
}

/// Deleting an account, server side first.
///
/// Order: first, the Orchards this account is the only owner of while
/// others are in them, which it must hand over (nothing is signed in or
/// deleted while there are any); sign in again and, when ZestSSH Cloud holds
/// synced data, enter
/// the sync password (nothing has changed yet, so backing out is free), turn
/// sync off and wait for a running cycle, delete the self-hosted sync store
/// when one is in use, delete the ZestSSH account on the server, then check
/// from this device that the server no longer knows it. Local data is left
/// for the caller's last-chance step.
///
/// Every step is injected, so the order is testable without a network.
class AccountDeletionFlow {
  AccountDeletionFlow({
    required this.isSameAccount,
    required this.signInAgain,
    required this.suspendSync,
    required this.resumeSync,
    required this.api,
    required this.askSyncPassword,
    this.deleteSyncStore,
    required this.forgetSyncKeys,
    required this.forgetAccount,
    this.soleOwnerOrchards,
  });

  /// The Orchards this account is the only owner of while others are in
  /// them (3.0), as this device knows them: deleting the account
  /// would leave them with no one who can do what only owners do. Checked
  /// before anything is deleted; the server checks the same.
  final Future<List<String>> Function()? soleOwnerOrchards;

  /// Whether a fresh sign-in is for the account being deleted.
  final bool Function(FreshSignIn fresh) isSameAccount;

  /// Asks the person to sign in again. Null when they back out.
  final Future<FreshSignIn?> Function() signInAgain;

  /// Turns sync off and waits for a cycle already running.
  final Future<void> Function() suspendSync;

  /// Turns sync back on, only when nothing was deleted.
  final void Function() resumeSync;

  final AccountDeletionApi api;

  /// Asks for the sync password of the synced data on ZestSSH Cloud and
  /// returns its verification value, derived with [HostedSyncData]'s salt and
  /// parameters. Null when the person backs out. The server requires it.
  final Future<Uint8List?> Function(HostedSyncData data) askSyncPassword;

  /// Deletes the synced data in the person's own store (WebDAV, S3, Google
  /// Drive or a self-hosted server). Null when the hosted server holds it,
  /// since deleting the account deletes that. Returns false when the person
  /// backed out (a self-hosted server asks for the sync password).
  final Future<bool> Function()? deleteSyncStore;

  /// Forgets this device's sync keys, so sync cannot start again.
  final Future<void> Function() forgetSyncKeys;

  /// Signs this device out of the deleted account [fresh] names and forgets
  /// its sync keys and account keys.
  final Future<void> Function(FreshSignIn fresh) forgetAccount;

  Future<AccountDeletionOutcome> run({
    void Function(AccountDeletionStage stage)? onStage,
  }) async {
    final blocking = await soleOwnerOrchards?.call() ?? const <String>[];
    if (blocking.isNotEmpty) {
      return AccountDeletionFailed(code: 'sole-owner', somethingDeleted: false, orchards: blocking);
    }
    onStage?.call(AccountDeletionStage.signingIn);
    final FreshSignIn? fresh;
    try {
      fresh = await signInAgain();
    } catch (e) {
      AppLogger.warning('Account deletion: signing in again failed: $e');
      return const AccountDeletionFailed(
          code: 'sign-in-failed', somethingDeleted: false);
    }
    if (fresh == null) return const AccountDeletionCancelled();
    if (!isSameAccount(fresh)) return const AccountDeletionWrongAccount();

    Uint8List? passwordHash;
    try {
      final synced = await api.hostedSyncData(fresh.token);
      if (synced != null) {
        passwordHash = await askSyncPassword(synced);
        if (passwordHash == null) return const AccountDeletionCancelled();
      }
    } on AccountDeletionException catch (e) {
      AppLogger.warning('Account deletion: could not read the account: $e');
      return AccountDeletionFailed(code: e.code, somethingDeleted: false, cause: e.stopped, keptUntil: e.keptUntil);
    }

    onStage?.call(AccountDeletionStage.stoppingSync);
    await suspendSync();

    var somethingDeleted = false;
    Future<AccountDeletionOutcome> stop(String code,
        {List<String> orchards = const [], Object? cause, DateTime? keptUntil}) async {
      if (somethingDeleted) {
        await forgetSyncKeys();
      } else {
        resumeSync();
      }
      return AccountDeletionFailed(
          code: code, somethingDeleted: somethingDeleted, orchards: orchards, cause: cause, keptUntil: keptUntil);
    }

    final deleteStore = deleteSyncStore;
    if (deleteStore != null) {
      onStage?.call(AccountDeletionStage.deletingSyncStore);
      try {
        if (!await deleteStore()) {
          resumeSync();
          return const AccountDeletionCancelled();
        }
      } catch (e) {
        AppLogger.warning('Account deletion: the sync store was not deleted: $e');
        return stop('sync-store-failed');
      }
      somethingDeleted = true;
    }

    onStage?.call(AccountDeletionStage.deletingAccount);
    try {
      await api.deleteNow(
        token: fresh.token,
        confirmUid: fresh.uid,
        passwordHash: passwordHash,
      );
    } on AccountDeletionException catch (e) {
      AppLogger.warning('Account deletion: the server refused: $e');
      somethingDeleted = somethingDeleted || e.dataDeleted;
      return stop(e.code, orchards: e.orchards, cause: e.stopped, keptUntil: e.keptUntil);
    }
    somethingDeleted = true;

    onStage?.call(AccountDeletionStage.verifying);
    try {
      if (!await api.isGone(fresh.token)) {
        AppLogger.warning('Account deletion: the server still knows the account');
        return await stop('not-verified');
      }
    } on AccountDeletionException catch (e) {
      AppLogger.warning('Account deletion: could not check the server: $e');
      return stop('not-verified');
    }

    await forgetAccount(fresh);
    return const AccountDeletionServerDone();
  }
}
