import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' show activeSessionsProvider, openSessionCount;
import 'package:zestssh/services/app_updater.dart';
import 'package:zestssh/services/update_check_service.dart';

/// SharedPreferences keys owned by the update-check feature.
const _kEnabledKey = 'update_check_enabled';
const _kDismissedVersionKey = 'update_dismissed_version';
const _kLastCheckMsKey = 'update_last_check_ms';

/// Don't hit the network more than once every few hours, even across several
/// launches - the manifest changes at most a few times a month. An app left
/// open checks again as often (3.3.1), so a release out after the one it
/// found is heard of.
const _kMinCheckInterval = Duration(hours: 6);

/// The least time before a check that is due, or overdue, while the app runs:
/// a clock set back, or a check's time that could not be kept, never makes
/// the checks a loop.
const _kLeastWait = Duration(minutes: 1);

/// The time the automatic check goes by (a test's own clock in a test).
final updateClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

final updateCheckServiceProvider = Provider<UpdateCheckService>((ref) {
  final service = UpdateCheckService();
  ref.onDispose(service.dispose);
  return service;
});

/// Whether the automatic update check is enabled (default true). Exposed so
/// a settings toggle can flip it; when off, [updateBannerProvider] never
/// touches the network.
final updateCheckEnabledProvider =
    NotifierProvider<UpdateCheckEnabledNotifier, bool>(
  UpdateCheckEnabledNotifier.new,
);

class UpdateCheckEnabledNotifier extends Notifier<bool> {
  @override
  bool build() =>
      ref.read(sharedPreferencesProvider).getBool(_kEnabledKey) ?? true;

  Future<void> set(bool value) async {
    await ref.read(sharedPreferencesProvider).setBool(_kEnabledKey, value);
    state = value;
    // Turning it off should also clear any banner already on screen AND the
    // persistent status-bar indicator.
    if (!value) {
      ref.read(updateBannerProvider.notifier).clear();
      ref.read(availableUpdateProvider.notifier).set(null);
    }
  }
}

/// The latest known available update, INDEPENDENT of the banner's dismissal.
///
/// The banner ([updateBannerProvider]) hides once the user waves it off, but
/// the status-bar version chip keeps a subtle "update available" indicator
/// from this provider, so the update stays one click away until the user
/// actually upgrades (or turns the check off). Null when up to date or the
/// feature is disabled.
final availableUpdateProvider =
    NotifierProvider<AvailableUpdateNotifier, UpdateInfo?>(
  AvailableUpdateNotifier.new,
);

class AvailableUpdateNotifier extends Notifier<UpdateInfo?> {
  @override
  UpdateInfo? build() => null;
  void set(UpdateInfo? info) => state = info;
}

/// The update banner's state: an [UpdateInfo] when a newer, non-dismissed
/// version is available, else null (no banner).
final updateBannerProvider =
    NotifierProvider<UpdateBannerNotifier, UpdateInfo?>(
  UpdateBannerNotifier.new,
);

class UpdateBannerNotifier extends Notifier<UpdateInfo?> {
  bool _kicked = false;

  /// The next automatic check while the app runs ([_scheduleNext]).
  Timer? _next;

  /// Nothing shows what a check finds any more (the shell has gone: the app
  /// locked, a test's screen taken down): no check is waited for until
  /// something does again.
  bool _paused = false;

  /// This provider was disposed: a check that ends after it changes nothing.
  bool _gone = false;

  @override
  UpdateInfo? build() {
    _gone = false;
    ref.onDispose(() {
      _gone = true;
      _next?.cancel();
    });
    ref.onCancel(() {
      _paused = true;
      _next?.cancel();
    });
    ref.onResume(() {
      _paused = false;
      _scheduleNext();
    });
    // Fire the check once, off the build, the first time anything watches
    // this provider (typically the shell mounting). Deferred so it never
    // blocks first paint. The next ones follow while the app runs.
    if (_kicked) {
      _scheduleNext();
    } else {
      _maybeCheck();
    }
    return null;
  }

  Future<void> _maybeCheck() async {
    if (_kicked) return;
    _kicked = true;
    await _check();
  }

  /// The automatic check, then the next one set for when it is due: an app
  /// left open hears of a release out after the one it found (3.3.1; it
  /// checked once per start before).
  Future<void> _check() async {
    try {
      await _checkOnce();
    } finally {
      _scheduleNext();
    }
  }

  Future<void> _checkOnce() async {
    final prefs = ref.read(sharedPreferencesProvider);
    if (!(prefs.getBool(_kEnabledKey) ?? true)) return;

    // Throttle across launches.
    final now = ref.read(updateClockProvider);
    final lastMs = prefs.getInt(_kLastCheckMsKey) ?? 0;
    final nowMs = now().millisecondsSinceEpoch;
    if (nowMs - lastMs < _kMinCheckInterval.inMilliseconds) return;

    final info = await ref.read(updateCheckServiceProvider).check();
    if (_gone) return;
    await prefs.setInt(_kLastCheckMsKey, now().millisecondsSinceEpoch);
    if (_gone || info == null) return;

    // The persistent status-bar indicator tracks availability regardless of
    // banner dismissal, so it is set BEFORE the dismissal check below. A
    // newer release takes the place of the one found before.
    ref.read(availableUpdateProvider.notifier).set(info);

    // Respect a per-version dismissal: once the user waves off "1.5.42",
    // don't nag again until an even newer version ships.
    if (prefs.getString(_kDismissedVersionKey) == info.version) return;

    // The banner offers this release already (a later check found it
    // again): it is said once.
    final shown = state;
    if (shown != null && shown.version == info.version && shown.build == info.build) return;

    state = info;

    // Surface it in the notification center too (the banner is easy to miss),
    // gated by the user's "Update available" notification toggle.
    if (ref.read(notifyUpdateAvailableProvider)) {
      ref.read(notificationCenterProvider.notifier).info(
            gl10n.notifPrefsUpdateAvailable,
            body: gl10n.updateAvailableBody(info.version),
          );
    }
  }

  /// When the next automatic check is due: six hours after the last check
  /// (of this start or an earlier one), at least [_kLeastWait] away. None
  /// while nothing shows what it finds, and none where a check asks nothing
  /// (a store's build). Turned off, the wait is the whole interval, and the
  /// check then sees the switch again.
  void _scheduleNext() {
    _next?.cancel();
    _next = null;
    if (_gone || _paused) return;
    if (!ref.read(updateCheckServiceProvider).checksForUpdates) return;
    final prefs = ref.read(sharedPreferencesProvider);
    var wait = _kMinCheckInterval;
    if (prefs.getBool(_kEnabledKey) ?? true) {
      final lastMs = prefs.getInt(_kLastCheckMsKey) ?? 0;
      final dueMs = lastMs + _kMinCheckInterval.inMilliseconds - ref.read(updateClockProvider)().millisecondsSinceEpoch;
      wait = Duration(milliseconds: dueMs.clamp(_kLeastWait.inMilliseconds, _kMinCheckInterval.inMilliseconds));
    }
    _next = Timer(wait, () {
      _next = null;
      _check();
    });
  }

  /// A check the person asked for (clicking the version, or Update and
  /// restart just before it downloads): runs now, whatever the throttle or
  /// the automatic-check setting says, updates the status bar's indicator,
  /// and returns what it found so the UI can say so. The banner, where it
  /// offers a release, offers the one found now, or none where this copy is
  /// the latest; the caller shows the answer.
  Future<UpdateCheckOutcome> checkNow() async {
    final outcome = await ref.read(updateCheckServiceProvider).checkNow();
    if (_gone) return outcome;
    switch (outcome) {
      case UpdateAvailable(:final info):
        ref.read(availableUpdateProvider.notifier).set(info);
        if (state != null) state = info;
      case UpdateCheckUpToDate():
        ref.read(availableUpdateProvider.notifier).set(null);
        state = null;
      case UpdateCheckFailed():
        return outcome;
    }
    await ref
        .read(sharedPreferencesProvider)
        .setInt(_kLastCheckMsKey, ref.read(updateClockProvider)().millisecondsSinceEpoch);
    return outcome;
  }

  /// User dismissed the banner - remember this version so it stays hidden
  /// until something newer is released.
  Future<void> dismiss() async {
    final info = state;
    if (info == null) return;
    await ref
        .read(sharedPreferencesProvider)
        .setString(_kDismissedVersionKey, info.version);
    state = null;
  }

  /// Hide the banner without recording a dismissal (used when the feature
  /// is turned off in settings).
  void clear() => state = null;
}

// ── The in-app updater (lib/services/app_updater.dart) ─────────────────

/// Whether this copy offers "Update and restart" at all: a computer's build
/// from the website (never a store's, never a phone's). A test says its own.
final inAppUpdateSupportedProvider = Provider<bool>((ref) => UpdateCheckService.manualCheckSupported);

/// This copy's build number (279 for 3.0.0+279), or null where it cannot be
/// read: a release of the same version is newer only by a higher build
/// (compareReleases). A test says its own.
final appBuildNumberProvider = FutureProvider<int?>((ref) async {
  try {
    return int.tryParse((await PackageInfo.fromPlatform()).buildNumber.trim());
  } catch (_) {
    return null;
  }
});

/// Downloads, checks and installs an update (a test puts a stand-in).
final appUpdaterProvider = Provider<AppUpdater>((ref) => AppUpdater());

/// How many sessions an update's restart would end, counted as quitting
/// counts them ([openSessionCount]). A test says its own.
final updateOpenSessionCountProvider = Provider<int>((ref) => openSessionCount(ref.watch(activeSessionsProvider)));

/// How the app quits for an update: set by the desktop shell while it is up
/// (null otherwise). It is given the installer's start, which it runs first
/// (nothing is ended where that fails), then quits as Quit does, without
/// asking again (the update asked already). False where it did not quit.
abstract final class UpdateRestart {
  static Future<bool> Function(Future<void> Function() launch)? endApp;
}

/// What the app keeps between the update's start and the next start: the
/// version that was being installed and where its installer logged.
const kUpdatePendingKey = 'update_pending_v1';

/// Notes an update as started, just before the app quits for it.
Future<void> markUpdatePending(SharedPreferences prefs, PreparedUpdate prepared, {required String from}) =>
    prefs.setString(
      kUpdatePendingKey,
      jsonEncode({
        'version': prepared.version,
        if (prepared.build != null) 'build': prepared.build,
        'from': from,
        'log': prepared.logPath,
      }),
    );

/// What became of the update started before this start.
sealed class LastUpdate {
  const LastUpdate();
}

/// It went in: this is the new version.
class LastUpdateInstalled extends LastUpdate {
  const LastUpdateInstalled(this.version);
  final String version;
}

/// The app opened again on the old version; [log] is the end of what the
/// installer or the helper wrote, if it wrote anything.
class LastUpdateNotInstalled extends LastUpdate {
  const LastUpdateNotInstalled(this.version, this.log);
  final String version;
  final String? log;
}

/// Reads, and forgets, the update started before this start; null where
/// there was none. [running] is this start's version and [runningBuild]
/// its build number, where known: an update to another build of the same
/// version went in only where the build that runs is that one or later.
Future<LastUpdate?> takeLastUpdate(SharedPreferences prefs, String running, {int? runningBuild}) async {
  final raw = prefs.getString(kUpdatePendingKey);
  if (raw == null) return null;
  await prefs.remove(kUpdatePendingKey);
  try {
    final m = jsonDecode(raw) as Map<String, Object?>;
    final version = m['version'] as String;
    final build = m['build'] is int ? m['build'] as int : null;
    if (compareReleases(running, runningBuild, version, build) >= 0) return LastUpdateInstalled(version);
    String? log;
    final path = m['log'];
    if (path is String) {
      try {
        final lines = await File(path).readAsLines();
        log = lines.skip(lines.length > 60 ? lines.length - 60 : 0).join('\n');
      } catch (_) {
        // (The installer wrote no log: it may not have started.)
      }
    }
    return LastUpdateNotInstalled(version, log);
  } catch (_) {
    return null;
  }
}
