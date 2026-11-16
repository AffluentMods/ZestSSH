import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/sync_health.dart';
import 'package:zestssh/utils/foreground_ticker.dart';

/// The background sync's live state ([AutoSyncService.activity]).
final syncActivityProvider = StreamProvider<SyncActivity>((ref) {
  final activity = ref.watch(autoSyncServiceProvider).activity;
  final controller = StreamController<SyncActivity>();
  void push() => controller.add(activity.value);
  activity.addListener(push);
  push();
  ref.onDispose(() {
    activity.removeListener(push);
    unawaited(controller.close());
  });
  return controller.stream;
});

/// Ticks every 30 seconds, so a change that has waited too long, or a day
/// without a check, shows without waiting for another sync event. Only while
/// the app is in front ([ForegroundTicker]): it ticked in a minimised window
/// and behind other apps too, where nothing it updates is seen (found in a code
/// audit); back in front it ticks at once.
final syncHealthClockProvider = StreamProvider<DateTime>((ref) {
  final controller = StreamController<DateTime>();
  final ticker = ForegroundTicker(const Duration(seconds: 30), () {
    if (!controller.isClosed) controller.add(DateTime.now());
  });
  ref.onDispose(() {
    ticker.dispose();
    unawaited(controller.close());
  });
  return controller.stream;
});

/// How this device's sync stands, for the status bar and the Account
/// screen. Manual flows (Sync now, setup) count as running while they run.
final syncHealthProvider = Provider<SyncHealthState>((ref) {
  final activity = ref.watch(syncActivityProvider).valueOrNull ?? const SyncActivity();
  final manual = ref.watch(syncStatusProvider);
  ref.watch(syncHealthClockProvider);
  final settings = ref.watch(settingsServiceProvider);
  return syncHealthOf(
    configured: activity.configured,
    mode: settings.syncMode,
    running: activity.running || manual.isSyncing,
    problem: activity.failure,
    paused: activity.paused,
    retrying: activity.retrying,
    pause: settings.syncPause,
    confirmedAt: settings.lastSyncTime,
    dirty: settings.syncDirty,
    dirtySince: settings.syncDirtySince,
    now: DateTime.now(),
  );
});
