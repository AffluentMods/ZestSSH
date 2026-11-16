import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:zestssh/ui/screens/sync/cloud_device_room.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/logger.dart';

bool _running = false;

/// "Sync now" from Settings and the Tree page: the same pull, merge and push
/// as the background sync, with the keys this device keeps (3.0: before,
/// both only said "Syncing..." or where else to look, and synced nothing).
/// Profile's own Sync now also proves the master password again first.
///
/// Says what happened: the version this device is at, or why it did not sync
/// (not set up here, or what stopped it) with what stands behind it to copy.
/// A tap while one runs starts no second one.
Future<void> runSyncNow(BuildContext context, WidgetRef ref) async {
  if (_running) return;
  _running = true;
  final l10n = AppLocalizations.of(context)!;
  final status = ref.read(syncStatusProvider.notifier);
  try {
    showTopSnackBar(context, l10n.settingsSyncing, duration: const Duration(seconds: 2));
    status.setSyncing(true);
    final int version;
    try {
      version = await ref.read(autoSyncServiceProvider).syncNowManual();
    } catch (e) {
      // In the words a sync that stopped is said in everywhere, with what
      // stands behind it.
      status.setErrorFrom(e);
      final said = ref.read(syncStatusProvider);
      if (context.mounted) {
        // Keys that are no longer the account's: the way out is the account
        // page's own Sync now, which asks for the sync password. One press
        // from here. (The request is the app's to answer: this screen may be
        // gone by the time the button is pressed.)
        final request = e is SyncKeysMismatchException
            ? ProviderScope.containerOf(context, listen: false).read(accountSyncNowRequestProvider.notifier)
            : null;
        // Past the devices ZestSSH Cloud syncs for one person: sign one out
        // right here.
        final room = e is SyncCloudDeviceLimitException;
        // The message outlives this screen: the list opens from the app's
        // own navigator, which is there when the action is pressed.
        final nav = Navigator.of(context, rootNavigator: true);
        showTopSnackBar(
          context,
          said.error ?? l10n.syncNowNotSetUp,
          isError: true,
          details: said.errorDetail ?? '$e',
          actionLabel: room ? l10n.syncDeviceRoomAction : (request == null ? null : l10n.accountSyncNow),
          onAction: room
              ? () {
                  if (nav.mounted) unawaited(showCloudDeviceRoom(nav.context));
                }
              : (request == null ? null : () => requestAccountSyncNow(request)),
        );
      }
      return;
    }
    // The size on the store is shown beside the last sync; a status that
    // cannot be read now does not undo the sync that was made.
    var size = ref.read(syncStatusProvider).blobSize ?? 0;
    try {
      size = (await ref.read(syncBackendProvider).getStatus()).blobSize;
    } catch (e) {
      AppLogger.warning('Sync now: the store status could not be read after syncing: $e');
    }
    status.setSynced(DateTime.now(), size);
    if (context.mounted) {
      showTopSnackBar(context, l10n.profileSyncedVersion(version), isSuccess: true);
    }
  } finally {
    _running = false;
  }
}

/// Asks for the account page's own "Sync now" ([accountSyncNowRequestProvider]):
/// the app opens the account page, and the page starts it. Asked again
/// while an earlier request was never answered, it is a new request.
void requestAccountSyncNow(StateController<bool> request) {
  request.state = false;
  request.state = true;
}

/// Opens the account page for a request no account page on screen has taken
/// (one that is on screen takes it the moment it is made, and nothing is
/// opened over it).
void openAccountForSyncNow(BuildContext context, WidgetRef ref) {
  if (!ref.read(accountSyncNowRequestProvider)) return;
  unawaited(ProfileScreen.openAccount(context, ref));
}

/// Opens the account page for a request to bring this device into the account's
/// sync that no account page on screen has taken ([accountTurnSyncOnRequestProvider]).
void openAccountForTurnSyncOn(BuildContext context, WidgetRef ref) {
  if (!ref.read(accountTurnSyncOnRequestProvider)) return;
  unawaited(ProfileScreen.openAccount(context, ref));
}

/// Says that the background sync has paused and why ([AutoSyncService.syncError],
/// with what stands behind it to copy). Where the way out is the sync
/// password proved on this device again, the notice stays until it is closed
/// and offers "Sync now" ([onSyncNow]: the account page's own, which asks for
/// the password). Where the way out is to set sync up again (the store holds
/// no vault: cloud sync was reset from another device, or the store was
/// emptied), it stays as well and offers "Set up sync again", which is the
/// same press: the account page's "Sync now" finds the store empty and asks
/// before it sets sync up anew. Returns false, saying nothing, when there is
/// nothing to say or when the pause comes from a run somebody asked for: the
/// screen it was asked on says what stopped it, and both saying it made two
/// notices for one press.
bool showSyncPausedNotice(
  AutoSyncService sync,
  NotificationCenter center, {
  required VoidCallback onSyncNow,
  VoidCallback? onMakeRoom,
}) {
  final message = sync.syncError.value;
  if (message == null || sync.syncErrorFromManualRun) return false;
  final needsPassword = sync.syncErrorNeedsPassword;
  final needsSetup = sync.syncErrorNeedsSetup;
  // Past the devices ZestSSH Cloud syncs for one person: "Sign out a
  // device" ([onMakeRoom]), which lists them.
  final needsRoom = sync.syncErrorNeedsDeviceRoom && onMakeRoom != null;
  final waits = needsPassword || needsSetup || needsRoom;
  center.show(AppNotification(
    id: const Uuid().v4(),
    title: gl10n.syncPausedTitle,
    body: message,
    severity: NotificationSeverity.error,
    // (A short stay keeps it from holding a place on screen for good; one
    // that waits for the person to act stays until it is closed.)
    dismissAfter: waits ? Duration.zero : const Duration(seconds: 10),
    details: ErrorReport.build(what: message, where: 'Syncing', details: sync.syncErrorDetail),
    actionLabel: needsRoom
        ? gl10n.syncDeviceRoomAction
        : needsPassword
            ? gl10n.accountSyncNow
            : needsSetup
                ? gl10n.syncSetUpAgain
                : null,
    onAction: needsRoom ? onMakeRoom : (waits ? onSyncNow : null),
  ));
  return true;
}
