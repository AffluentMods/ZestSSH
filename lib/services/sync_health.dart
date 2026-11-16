/// How this device's sync stands, in the few states a person needs to see.
/// The status bar and the Account screen both read [syncHealthOf], so they
/// never disagree about whether this device is syncing.
library;

import 'package:zestssh/services/settings_service.dart' show SyncPause;

enum SyncHealth {
  /// Sync is not set up on this device.
  off,

  /// A sync is running now.
  syncing,

  /// The last check found this device matching the account's data.
  upToDate,

  /// Sync is on, but this device is behind: changes made here have waited
  /// too long to go, or it has not confirmed it is current for a day.
  behind,

  /// The last sync failed: the app is trying again by itself, or it stopped
  /// until somebody acts.
  failing,

  /// Its person paused sync on this device: nothing syncs by itself until
  /// the pause ends, and changes made here wait to go.
  paused,
}

class SyncHealthState {
  const SyncHealthState(
    this.health, {
    this.confirmedAt,
    this.problem,
    this.waiting = false,
    this.retrying = false,
    this.pause,
  });

  final SyncHealth health;

  /// When this device last confirmed it matched the account's data.
  final DateTime? confirmedAt;

  /// For [SyncHealth.failing]: what went wrong, when known.
  final String? problem;

  /// For [SyncHealth.behind]: changes made here are waiting to go (rather
  /// than the last check being old).
  final bool waiting;

  /// For [SyncHealth.failing]: the app tries again by itself (the store
  /// could not be reached, most often), so nobody has to do anything.
  final bool retrying;

  /// For [SyncHealth.paused]: until when ([SyncPause.until] null: until its
  /// person resumes it).
  final SyncPause? pause;
}

/// Changes normally leave within seconds; still waiting after this long
/// means something (the network, the store) is in the way.
const Duration kSyncWaitingGrace = Duration(minutes: 5);

/// A device that syncs on its own but has not confirmed it is current for
/// this long is behind: the other devices may have moved on.
const Duration kSyncStaleAfter = Duration(hours: 24);

/// [mode] is the sync mode setting: 'auto', 'instant' or 'manual'. In
/// Manual mode changes wait for the person on purpose, so any waiting change
/// counts as behind, and an old check does not.
SyncHealthState syncHealthOf({
  required bool configured,
  required String mode,
  required bool running,
  required String? problem,
  required bool paused,
  bool retrying = false,
  SyncPause? pause,
  required DateTime? confirmedAt,
  required bool dirty,
  required DateTime? dirtySince,
  required DateTime now,
}) {
  if (!configured) return const SyncHealthState(SyncHealth.off);
  if (running) return SyncHealthState(SyncHealth.syncing, confirmedAt: confirmedAt);
  // Paused by its person: said as that, and not as a failure from before
  // the pause, nor as a change that waits too long (it waits on purpose).
  if (pause != null && pause.at(now)) {
    return SyncHealthState(SyncHealth.paused, confirmedAt: confirmedAt, waiting: dirty, pause: pause);
  }
  if (problem != null || paused) {
    return SyncHealthState(
      SyncHealth.failing,
      confirmedAt: confirmedAt,
      problem: problem,
      // A pause is until somebody acts, whatever else is said.
      retrying: retrying && !paused,
    );
  }
  final automatic = mode == 'auto' || mode == 'instant';
  if (dirty) {
    final waitedLong = dirtySince == null || now.difference(dirtySince) >= kSyncWaitingGrace;
    if (!automatic || waitedLong) {
      return SyncHealthState(SyncHealth.behind, confirmedAt: confirmedAt, waiting: true);
    }
  }
  if (confirmedAt == null) return const SyncHealthState(SyncHealth.behind);
  if (automatic && now.difference(confirmedAt) >= kSyncStaleAfter) {
    return SyncHealthState(SyncHealth.behind, confirmedAt: confirmedAt);
  }
  return SyncHealthState(SyncHealth.upToDate, confirmedAt: confirmedAt);
}
