import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/backup/backup_destination.dart';
import 'package:zestssh/services/backup/backup_destination_manager.dart';

// ── Manager ────────────────────────────────────────────────────────

/// Singleton [BackupDestinationManager] - loaded from SharedPreferences
/// on first access.
final backupDestinationManagerProvider =
    FutureProvider<BackupDestinationManager>((ref) async {
  final prefs = ref.watch(sharedPreferencesProvider);
  // Loaded again when the database opens or closes: the WebDAV passwords
  // are sealed with it while the encrypting lock is on, and open only then.
  final tree = ref.watch(databaseSessionProvider);
  final manager = BackupDestinationManager(
    tree: () => tree,
    prefs: prefs,
    // WebDAV passwords go to Keychain / EncryptedSharedPreferences, not the
    // plaintext prefs JSON.
    secureStorage: ref.watch(secureStorageProvider),
  );
  await manager.loadFromPrefs();
  return manager;
});

// ── Destination list ───────────────────────────────────────────────

/// Reactive list of configured [BackupDestination]s.
///
/// Invalidate this provider after adding/removing a destination so
/// downstream widgets rebuild.
final backupDestinationsProvider =
    FutureProvider<List<BackupDestination>>((ref) async {
  final manager = await ref.watch(backupDestinationManagerProvider.future);
  return manager.destinations;
});

/// Count of configured destinations (for the settings tile subtitle).
final backupDestinationCountProvider = FutureProvider<int>((ref) async {
  final destinations = await ref.watch(backupDestinationsProvider.future);
  return destinations.length;
});

// ── Health ─────────────────────────────────────────────────────────

/// Health status across all configured destinations.
///
/// This is intentionally a [FutureProvider] (not a stream) because
/// health checks hit the network and should only run when the user
/// navigates to the backup settings screen.
final backupHealthStatusProvider =
    FutureProvider<BackupHealthStatus>((ref) async {
  final manager = await ref.watch(backupDestinationManagerProvider.future);
  return manager.checkHealth();
});

// ── CRUD helpers ──────────────────────────────────────────────────

/// Notifier that wraps CRUD operations and invalidates downstream
/// providers automatically.
class BackupDestinationNotifier {
  final Ref _ref;

  BackupDestinationNotifier(this._ref);

  Future<void> add(BackupDestination destination) async {
    final manager =
        await _ref.read(backupDestinationManagerProvider.future);
    await manager.addDestination(destination);
    _invalidate();
  }

  Future<void> remove(String id) async {
    final manager =
        await _ref.read(backupDestinationManagerProvider.future);
    await manager.removeDestination(id);
    _invalidate();
  }

  Future<void> update(BackupDestination destination) async {
    final manager =
        await _ref.read(backupDestinationManagerProvider.future);
    await manager.updateDestination(destination);
    _invalidate();
  }

  void _invalidate() {
    _ref.invalidate(backupDestinationManagerProvider);
    _ref.invalidate(backupDestinationsProvider);
    _ref.invalidate(backupDestinationCountProvider);
    _ref.invalidate(backupHealthStatusProvider);
  }
}

final backupDestinationNotifierProvider =
    Provider<BackupDestinationNotifier>((ref) {
  return BackupDestinationNotifier(ref);
});
