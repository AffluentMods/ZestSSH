import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/utils/logger.dart';

/// How many tmux sessions each saved connection had the last time we looked
/// (listed on open, refreshed while attached). Kept device-local in the
/// encrypted `local_state` store so a host that has a detached session shows
/// it in the Hosts panel and on its tab even before reconnecting.
class TmuxSessionCounts extends StateNotifier<Map<String, int>> {
  TmuxSessionCounts(this._store) : super(const {}) {
    _load();
  }

  /// Null while the app is locked: counts are then kept in memory only and
  /// nothing is written.
  final LocalStateStore? _store;
  static const _prefix = 'tmux_sessions:';

  Future<void> _load() async {
    final store = _store;
    if (store == null) return;
    final loaded = <String, int>{};
    try {
      for (final k in await store.keysWithPrefix(_prefix)) {
        final n = await store.readInt(k);
        if (n != null && n > 0) loaded[k.substring(_prefix.length)] = n;
      }
    } catch (e) {
      // The database closed under us (the app locked): the next notifier,
      // made when it unlocks, loads the counts again.
      AppLogger.warning('tmux session counts: could not load ($e)');
      return;
    }
    if (mounted && loaded.isNotEmpty) state = {...loaded, ...state};
  }

  /// Record [count] sessions for [connectionId]; zero forgets the host.
  Future<void> set(String connectionId, int count) async {
    if (connectionId.isEmpty) return;
    if ((state[connectionId] ?? 0) == count) return;
    final store = _store;
    try {
      if (count <= 0) {
        state = {...state}..remove(connectionId);
        await store?.remove('$_prefix$connectionId');
      } else {
        state = {...state, connectionId: count};
        await store?.writeInt('$_prefix$connectionId', count);
      }
    } catch (e) {
      // A count is a hint for the Hosts panel; losing one to a lock that
      // closed the database mid-write is harmless.
      AppLogger.warning('tmux session counts: could not save ($e)');
    }
  }
}

/// Follows the Tree's database: made again, and loaded again from the
/// store, when the app unlocks (the database the old one used was closed
/// by the lock). While locked there is no database, so counts stay in
/// memory and nothing is written.
final tmuxSessionCountsProvider =
    StateNotifierProvider<TmuxSessionCounts, Map<String, int>>((ref) {
  if (ref.watch(databaseSessionProvider) == null) return TmuxSessionCounts(null);
  return TmuxSessionCounts(ref.watch(localStateStoreProvider));
});

/// A connection that should open tmux as soon as its session connects (the
/// Hosts-panel badge on a host that is not connected yet).
final tmuxPendingConnectionProvider = StateProvider<String?>((ref) => null);
