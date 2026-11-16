import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/utils/logger.dart';

/// When this device last reached ZestSSH Cloud (3.0, the offline
/// limit), kept in the Tree's encrypted database (device-local, never
/// synced, never in a backup) rather than in preferences, where anyone at
/// the keyboard could move it forward. Measured with this device's clock,
/// whose furthest reading is kept too, so turning it back shows.
class OrchardContactNotifier extends StateNotifier<OrchardContact> {
  OrchardContactNotifier(this._store, {int Function()? now})
      : _now = now ?? _epochSeconds,
        super(const OrchardContact()) {
    loaded = _load();
  }

  static const lastKey = 'orchards.last_contact';
  static const latestKey = 'orchards.clock_latest';
  static const excusedKey = 'orchards.outage_excused';
  static const excusedThroughKey = 'orchards.outage_excused_through';
  static const provenUntilKey = 'orchards.outage_proven_until';

  /// How often the clock's furthest reading is written, at most.
  static const _writeEvery = 60;

  /// Null while the app is locked: kept in memory only.
  final LocalStateStore? _store;
  final int Function() _now;

  /// Done once what was kept has been read.
  late final Future<void> loaded;

  var _reached = false;
  var _written = 0;

  static int _epochSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// The clock now, in seconds since the epoch.
  int now() => _now();

  Future<void> _load() async {
    final store = _store;
    if (store == null) return;
    try {
      final last = await store.readInt(lastKey);
      final latest = await store.readInt(latestKey) ?? 0;
      final excused = await store.readInt(excusedKey) ?? 0;
      final excusedThrough = await store.readInt(excusedThroughKey) ?? 0;
      final provenUntil = await store.readInt(provenUntilKey) ?? 0;
      _written = latest;
      // Reaching ZestSSH Cloud meanwhile says more than what was kept.
      if (!mounted || _reached) return;
      state = OrchardContact(
        lastContact: last,
        latest: max(latest, state.latest),
        excused: excused,
        excusedThrough: excusedThrough,
        provenUntil: provenUntil,
      );
    } catch (e) {
      // The database closed under us (the app locked): the next notifier,
      // made when it unlocks, reads it again.
      AppLogger.warning('Orchards: when this device last reached ZestSSH Cloud could not be read ($e)');
    }
  }

  /// This device reached ZestSSH Cloud just now: the limit is measured
  /// afresh from here, and so is the clock.
  Future<void> reached() async {
    final t = _now();
    _reached = true;
    state = OrchardContact(lastContact: t, latest: t);
    try {
      await _store?.writeInt(lastKey, t);
      await _store?.writeInt(latestKey, t);
      // What was excused belonged to the stretch that just ended.
      await _store?.writeInt(excusedKey, 0);
      await _store?.writeInt(excusedThroughKey, 0);
      await _store?.writeInt(provenUntilKey, 0);
      _written = t;
    } catch (e) {
      AppLogger.warning('Orchards: when this device reached ZestSSH Cloud could not be kept ($e)');
    }
  }

  /// ZestSSH Cloud itself was down from [since] to [at] (seconds since the
  /// epoch), as its status service proved with a signed statement that may
  /// be believed until [until]: that time does not count towards the
  /// offline limits, nor does the time that passes while the statement is
  /// believed ([OrchardContact.excusing]). Returns whether that changed
  /// anything.
  Future<bool> excuse({required int since, required int at, int? until}) async {
    await loaded;
    if (!mounted) return false;
    return _take(state.excusing(since: since, at: at, until: until));
  }

  /// The outage that was proven is over (ZestSSH Cloud answers again, or
  /// its status service says that it is up): its last proof is believed no
  /// further ([OrchardContact.ending]). Returns whether that changed
  /// anything.
  Future<bool> outageOver() async {
    await loaded;
    if (!mounted) return false;
    return _take(state.ending(_now()));
  }

  /// [next] is how the contact stands now, where it is not what stood: it
  /// is kept. Returns whether it was something new.
  Future<bool> _take(OrchardContact next) async {
    if (identical(next, state)) return false;
    state = next;
    try {
      await _store?.writeInt(excusedKey, next.excused);
      await _store?.writeInt(excusedThroughKey, next.excusedThrough);
      await _store?.writeInt(provenUntilKey, next.provenUntil);
    } catch (e) {
      // Held in memory for this run; the next proof is written again.
      AppLogger.warning('Orchards: a proven outage could not be kept ($e)');
    }
    return true;
  }

  /// Notes the clock's reading now when it is the furthest yet.
  Future<void> sawTime() async {
    final t = _now();
    if (t <= state.latest) return;
    state = state.seeing(t);
    if (t - _written < _writeEvery) return;
    _written = t;
    try {
      await _store?.writeInt(latestKey, t);
    } catch (_) {/* kept in memory; written with the next reading */}
  }
}

/// When this device last reached ZestSSH Cloud, for the Orchards' offline
/// limits. Read afresh at each unlock.
final orchardContactProvider = StateNotifierProvider<OrchardContactNotifier, OrchardContact>((ref) {
  final unlocked = ref.watch(databaseSessionProvider) != null;
  return OrchardContactNotifier(unlocked ? ref.watch(localStateStoreProvider) : null);
});
