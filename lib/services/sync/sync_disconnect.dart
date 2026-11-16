import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_setup_state_service.dart';

/// Turns sync off on THIS device and touches nothing a store holds: the
/// timers stop, the device's sync keys and the salt of its password are
/// forgotten, a key kept unlocked in memory is dropped ([lockVault]), setup
/// is back at its start, and what the device remembered of the store (its
/// version, what was last agreed, changes waiting to go up) is cleared. The
/// data on the device stays. Sync starts again only through "Set up sync".
///
/// Used when the store is changed for another one, and when the cloud copy
/// is reset or found gone and sync is set up again.
Future<void> disconnectSyncOnThisDevice({
  required AutoSyncService autoSync,
  required SyncSetupStateService setup,
  required SettingsService settings,
  required FlutterSecureStorage secureStorage,
  required void Function() lockVault,
}) async {
  autoSync.stopAutoSync();
  await autoSync.clearSyncCredentials();
  lockVault();
  await setup.reset();
  await settings.setSyncServerVersion(0);
  await settings.setSyncContentHash('');
  await settings.setSyncDirty(false);
  await secureStorage.delete(key: 'sync_salt');
  autoSync.resetFailures();
}
