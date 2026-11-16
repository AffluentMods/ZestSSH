import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';

/// Legacy SharedPreferences key that used to hold pinned connection ids
/// per-device. As of Part B (schema v18) pin state lives on the synced
/// `Connections.pinned` column instead; this key is only read once during
/// migration and then removed.
const String _legacyPinnedKey = 'pinned_connection_ids';
const String _migratedFlag = 'pins_migrated_to_db';

/// Set of connection ids the user has pinned. Now DERIVED from the synced
/// `Connections.pinned` column (Part B / B4) so a pin propagates across
/// devices, instead of the old per-device prefs set. Pinned hosts get a
/// dedicated "PINNED" shelf and sort to the front of their group; a pin
/// doesn't remove a host from anywhere.
final pinnedHostsProvider =
    NotifierProvider<PinnedHostsNotifier, Set<String>>(
  PinnedHostsNotifier.new,
);

class PinnedHostsNotifier extends Notifier<Set<String>> {
  bool _migrationKicked = false;

  @override
  Set<String> build() {
    // One-shot: fold any legacy per-device prefs pins into the column so
    // existing users don't lose their pins on upgrade.
    _migrateLegacyPinsOnce();
    final conns =
        ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const [];
    return {
      for (final c in conns)
        if (c.connection.pinned) c.connection.id,
    };
  }

  void _migrateLegacyPinsOnce() {
    if (_migrationKicked) return;
    _migrationKicked = true;
    // Defer off the build; setPinned mutates the DB and would re-enter build.
    Future.microtask(() async {
      final prefs = ref.read(sharedPreferencesProvider);
      if (prefs.getBool(_migratedFlag) == true) return;
      final raw = prefs.getString(_legacyPinnedKey);
      if (raw != null && raw.isNotEmpty) {
        try {
          final ids = (jsonDecode(raw) as List).map((e) => e.toString());
          final dao = ref.read(connectionsDaoProvider);
          for (final id in ids) {
            await dao.setPinned(id, true);
          }
        } catch (_) {
          // Corrupt legacy entry - nothing to migrate.
        }
      }
      await prefs.setBool(_migratedFlag, true);
      await prefs.remove(_legacyPinnedKey);
    });
  }

  /// Pin [id] (writes the synced column; the derived state updates via the
  /// connections stream). Idempotent.
  Future<void> pin(String id) async {
    if (state.contains(id)) return;
    await ref.read(connectionsDaoProvider).setPinned(id, true);
  }

  /// Unpin [id]. Idempotent.
  Future<void> unpin(String id) async {
    if (!state.contains(id)) return;
    await ref.read(connectionsDaoProvider).setPinned(id, false);
  }

  /// Pin if not pinned, unpin otherwise.
  Future<void> toggle(String id) async {
    if (state.contains(id)) {
      await unpin(id);
    } else {
      await pin(id);
    }
  }

  /// No-op now that pin state is a Drift column - deleting a connection
  /// drops its pin automatically (no orphan set to prune). Kept so the
  /// connection-delete path's call site doesn't need to change.
  Future<void> pruneMissing(Set<String> validIds) async {}

  bool isPinned(String id) => state.contains(id);
}
