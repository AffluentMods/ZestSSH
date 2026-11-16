import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/mac_keychain.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync/sync_failure.dart';
import 'package:zestssh/services/sync/unread_sync_store.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/database/database.dart';

/// What the background sync is doing and how its last run ended, for the
/// status bar and the Account screen ([AutoSyncService.activity]).
@immutable
class SyncActivity {
  const SyncActivity({
    this.configured = false,
    this.running = false,
    this.paused = false,
    this.retrying = false,
    this.failure,
  });

  /// Sync credentials exist on this device.
  final bool configured;

  /// A sync cycle is running now.
  final bool running;

  /// Background sync stopped, until the person syncs by hand or sets sync up
  /// again: what stopped it does not pass by itself.
  final bool paused;

  /// The last try failed because of the store (it could not be reached, most
  /// often), and the app tries again by itself: nobody has to do anything.
  final bool retrying;

  /// What stopped the last cycle, in plain words; null when it finished.
  final String? failure;

  SyncActivity copyWith({
    bool? configured,
    bool? running,
    bool? paused,
    bool? retrying,
    String? failure,
    bool clearFailure = false,
  }) =>
      SyncActivity(
        configured: configured ?? this.configured,
        running: running ?? this.running,
        paused: paused ?? this.paused,
        retrying: retrying ?? this.retrying,
        failure: clearFailure ? null : (failure ?? this.failure),
      );
}

/// The user's answer to a stale-device reconcile prompt.
enum StaleReconcileChoice {
  /// Keep the local-only rows and push them (today's union behavior). The user
  /// accepts that some may reappear on other devices.
  mergeAnyway,

  /// Defer to the cloud: drop the ambiguous local-only rows so this device
  /// matches the cloud, then continue.
  adoptCloud,

  /// Do nothing this cycle (do not merge, do not push). The prompt returns
  /// on a later cycle. Used for a dismissed dialog.
  cancel,
}

/// UI hook the sync cycle calls when a device that has been offline longer than
/// [kTombstoneRetention] is about to merge a cloud that may have forgotten some
/// of this device's rows. Returns the user's decision. When no handler is
/// registered (headless / no UI attached) the cycle takes the safe path and
/// skips the merge+push entirely, so nothing is resurrected unattended.
typedef StaleReconcileHandler = Future<StaleReconcileChoice> Function(
    StaleReconcileReport report);

/// Timer-based auto sync when sync mode is 'auto'.
///
/// Stores the DEK (not the MEK or the password) for unattended syncs,
/// along with the pre-computed verification hash for push auth.
class AutoSyncService {
  static const _syncDekKey = 'sync_dek';
  static const _syncArgon2ParamsKey = 'sync_argon2_params';
  static const _maxConsecutiveFailures = 3;
  // Legacy keys - migrated on first use.
  static const _legacySyncPasswordKey = 'sync_password';
  static const _legacySyncMekKey = 'sync_mek';
  static const _debounceDelay = Duration(seconds: 5);

  /// How long the app waits before it tries again by itself after tries in a
  /// row that the store failed: it could not be reached, it answered with a
  /// fault of its own, or another device kept writing. The last wait goes for
  /// every try after it, and in automatic mode no wait is longer than the
  /// time between two checks. Nothing is given up: a server that was down
  /// for a day is synced with when it is back. (Until this was held, three
  /// such failures stopped background sync until the app was started again
  /// or somebody pressed "Sync now", and nothing said so.)
  static const retryWaits = <Duration>[
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 15),
  ];

  Timer? _periodicTimer;
  Timer? _debounceTimer;

  /// The try that waits its time after the store failed one ([retryWaits]).
  Timer? _retryTimer;

  /// No try by itself before this: the end of that wait.
  DateTime? _retryAt;

  /// Tries in a row that the store failed.
  int _storeFailures = 0;

  /// Tries in a row that failed for another reason (what the store holds
  /// could not be merged here, something on this device): these do not pass
  /// by themselves, and after [_maxConsecutiveFailures] sync is paused.
  int _consecutiveFailures = 0;
  bool _isSyncing = false;

  /// Whether a cycle was asked for while one ran, and returned without running.
  bool _askedWhileRunning = false;

  /// Completes when the cycle in flight finishes, so a manual "Sync now" can
  /// wait for a background cycle instead of being dropped by the busy guard.
  Completer<void>? _inFlight;

  /// Set while the account is being deleted: no cycle of any kind may run,
  /// or it could upload this device's data again mid-deletion.
  bool _suspended = false;

  /// Surfaced to the UI when a sync cycle hits a state the user must act
  /// on - specifically a split-brain where this device's cached data key
  /// can't decrypt the server blob (another device re-keyed it). null
  /// when healthy. The old code swallowed this and sync just went quiet.
  final ValueNotifier<String?> syncError = ValueNotifier<String?>(null);

  /// What stands behind [syncError] (what was thrown, or what the restore or
  /// the server said), for the report of the notice that says it; set before
  /// [syncError] changes.
  String? syncErrorDetail;

  /// Whether the pause [syncError] names ends when the sync password is
  /// proved on this device again, which the account page's "Sync now" does:
  /// this device's keys are not the account's any more (the server refuses
  /// what it sends, or it cannot read what the store holds). False while
  /// nothing is said.
  bool get syncErrorNeedsPassword => syncError.value != null && _errorNeedsPassword;
  bool _errorNeedsPassword = false;

  /// Whether the pause [syncError] names ends only when sync is set up again:
  /// the store holds no vault this device could write to (cloud sync was
  /// reset from another device, or the store was emptied), which the account
  /// page's "Sync now" finds and offers to do. False while nothing is said.
  bool get syncErrorNeedsSetup => syncError.value != null && _errorNeedsSetup;
  bool _errorNeedsSetup = false;

  /// Whether the pause [syncError] names ends when one of the account's
  /// devices is signed out: ZestSSH Cloud syncs up to seven of a person's
  /// devices, and this one is past them (SyncCloudDeviceLimitException).
  /// Setting sync up again would not help. False while nothing is said.
  bool get syncErrorNeedsDeviceRoom => syncError.value != null && _errorNeedsDeviceRoom;
  bool _errorNeedsDeviceRoom = false;

  /// Whether [syncError] comes from a run somebody asked for ("Sync now"):
  /// the screen it was asked on says what stopped it, so nothing else has to
  /// say it a second time. False while nothing is said.
  bool get syncErrorFromManualRun => syncError.value != null && _errorFromManualRun;
  bool _errorFromManualRun = false;

  /// Says why sync stopped until somebody acts ([syncError]), with what
  /// stands behind it and what kind of pause it is, set before the listeners
  /// of [syncError] hear of it.
  void _sayPaused(
    String message, {
    String? detail,
    bool needsPassword = false,
    bool needsSetup = false,
    bool needsDeviceRoom = false,
    required bool manual,
  }) {
    syncErrorDetail = detail;
    _errorNeedsPassword = needsPassword;
    _errorNeedsSetup = needsSetup;
    _errorNeedsDeviceRoom = needsDeviceRoom;
    _errorFromManualRun = manual;
    syncError.value = message;
  }

  /// Live state for the status bar and the Account screen. A new value is
  /// set whenever it changes, and when local changes start waiting (so a
  /// listener reads the waiting state again).
  final ValueNotifier<SyncActivity> activity = ValueNotifier<SyncActivity>(const SyncActivity());

  int _cyclesRun = 0;
  bool _disposed = false;

  /// Sets [activity], unless the service is gone (a cycle or a storage read
  /// can finish after [dispose]).
  void _setActivity(SyncActivity Function(SyncActivity current) change) {
    if (!_disposed) activity.value = change(activity.value);
  }

  /// How far THIS device's clock is off from the sync server's (positive = we
  /// are ahead). Set on each cycle from the server Date header; null when within
  /// tolerance or the server didn't report a time. A large skew silently
  /// corrupts newest-wins conflict resolution, so the UI surfaces it.
  final ValueNotifier<Duration?> clockSkew = ValueNotifier<Duration?>(null);

  /// Skew beyond this is worth warning about (well above normal NTP drift, low
  /// enough to catch a wrong date/timezone that would break conflict ordering).
  static const Duration _clockSkewThreshold = Duration(minutes: 2);

  /// "host:port, host:port" of any host key where a device's synced fingerprint
  /// disagreed with the one trusted here (never auto-merged). Set on the sync
  /// that saw it; the UI raises a changed-key-weight warning. Null when clean.
  final ValueNotifier<String?> hostKeyConflict = ValueNotifier<String?>(null);

  /// How many times the store gave this device an old copy of the account's
  /// data, as its count inside the encryption shows: restored from a backup,
  /// or someone who can write to it keeping an old copy. What is newer here
  /// was kept and sent back; the UI tells its person.
  final ValueNotifier<int> storeWentBack = ValueNotifier<int>(0);

  /// The count [storeWentBack] was last raised for: a store that keeps
  /// serving the same old copy is told of once in a run.
  int? _storeWentBackSaid;

  /// Registered by the app so a stale-device reconcile can prompt the user
  /// before this device resurrects rows the cloud has GC'd. Null in headless
  /// contexts, in which case the cycle skips the merge+push (the safe default).
  StaleReconcileHandler? staleReconcileHandler;

  /// True once THIS device has been offline longer than the tombstone retention
  /// window - past the point where the cloud may have pruned tombstones for
  /// items deleted elsewhere, so a blind union would silently re-insert them.
  /// A never-synced device (null last-sync) is NOT stale: its first pull is a
  /// join, handled by the join flow, not this reconcile.
  bool _isStale() {
    final last = _settingsService.lastSyncTime;
    if (last == null) return false;
    return DateTime.now().difference(last) > kTombstoneRetention;
  }

  /// True once sync credentials (a stored DEK) are known to exist on this
  /// device. Gates [notifyLocalChange] so users who never set up Cloud Sync
  /// incur zero overhead even though [SettingsService.syncMode] defaults to
  /// 'auto'. Kept in sync by [_refreshSyncConfigured] + store/clear creds.
  bool _syncConfigured = false;

  /// Your Tree's database, whose seal keeps sync's key while the encrypting
  /// lock is on ([SecretSeal]); null while it is closed.
  AppDatabase? get _tree {
    try {
      return _syncDataService.database;
    } catch (_) {
      return null;
    }
  }

  /// Sync's key as kept, opened where it is sealed; null where there is none
  /// or it does not open.
  Future<String?> _readDek() async => openKept(_tree, _syncDekKey, await _secureStorage.read(key: _syncDekKey));

  /// The sync password's verification value as kept, opened where it is
  /// sealed ([AccountSecret]); null where there is none or it does not open.
  Future<String?> _readVerification() => AccountSecret.syncVerification.read(_secureStorage, tree: () => _tree);

  /// Whether sync is set up on this device (its key is kept here), in any
  /// mode, paused or not.
  Future<bool> setUpHere() async {
    await _refreshSyncConfigured();
    return _syncConfigured;
  }

  Future<void> _refreshSyncConfigured() async {
    final dek = await _secureStorage.read(key: _syncDekKey);
    _syncConfigured = dek != null && dek.isNotEmpty;
    _setActivity((a) => a.copyWith(configured: _syncConfigured));
  }

  final SyncDataService _syncDataService;
  final SettingsService _settingsService;
  final FlutterSecureStorage _secureStorage;

  /// Resolves the currently-selected sync backend (hosted, self-hosted,
  /// WebDAV, S3, or Drive). Re-read at the start of each cycle so a mid-run
  /// provider switch takes effect on the next cycle, not this one.
  final SyncBackend Function() _resolveBackend;

  AutoSyncService({
    required SyncDataService syncDataService,
    required SettingsService settingsService,
    required FlutterSecureStorage secureStorage,
    required SyncBackend Function() resolveBackend,
    void Function()? onCycleSucceeded,
    DateTime Function()? clock,
    Timer Function(Duration wait, void Function() then)? timer,
    this.networkUp,
  })  : _syncDataService = syncDataService,
        _settingsService = settingsService,
        _secureStorage = secureStorage,
        _resolveBackend = resolveBackend,
        _onCycleSucceeded = onCycleSucceeded,
        _clock = clock ?? DateTime.now,
        _timer = timer ?? Timer.new;

  /// The time, and a timer: a test's own where it must not wait.
  final DateTime Function() _clock;
  final Timer Function(Duration wait, void Function() then) _timer;

  /// The device's network changing, as whether it has one now; listened to
  /// while sync runs by itself ([startAutoSync] to [stopAutoSync]). The app
  /// gives it as it starts (lib/app.dart), before sync is started; null
  /// where nothing says how the network stands (a wait then runs its time).
  Stream<bool> Function()? networkUp;
  StreamSubscription<bool>? _networkChanges;

  /// Called after a cycle that ended well (pushed, or nothing to push), for
  /// follow-up work that needs sync in place: checking the account's keys.
  final void Function()? _onCycleSucceeded;

  /// Start periodic auto-sync timer and run one cycle now (so a fresh
  /// launch pulls anything the other device pushed).
  void startAutoSync() {
    stopAutoSync();

    // Refresh the "is sync configured" gate (async, cheap) so
    // notifyLocalChange knows whether to do any work, and the status shows
    // sync as set up in Manual mode too.
    unawaited(_refreshSyncConfigured());

    // Paused by its person: nothing runs by itself until the pause ends.
    if (_holdForPause()) return;

    final mode = _settingsService.syncMode;
    if (mode != 'auto' && mode != 'instant') return;

    // A network that came back is the moment to try again, not the end of
    // the wait after a try the store failed.
    _networkChanges = networkUp?.call().listen(
      (up) {
        if (up) networkChanged();
      },
      onError: (Object _) {},
    );

    if (mode == 'instant') {
      AppLogger.info('Starting instant sync (syncs on every change, looks for '
          "other devices' every ${instantPullEvery.inMinutes}m)");
      _armInstantPull();
      unawaited(_runSyncCycle());
      return;
    }

    final intervalMinutes = _settingsService.syncIntervalMinutes;
    AppLogger.info(
      'Starting auto-sync timer (every ${intervalMinutes}m)',
    );

    _periodicTimer = Timer.periodic(
      Duration(minutes: intervalMinutes),
      (_) => _runSyncCycle(),
    );

    unawaited(_runSyncCycle());
  }

  /// How often Instant mode looks for what other devices changed. A change
  /// made here goes within a second; nothing tells this device when another
  /// one changed something (the stores have no way to call it), so without
  /// a timer their changes came only at start, when the app came back to the
  /// front or with a change made here (found while checking the 3.0 docs).
  /// Five minutes is the shortest automatic schedule, so Instant is never
  /// slower than any of them at bringing other devices' changes; a look
  /// that finds nothing new downloads nothing.
  static const instantPullEvery = Duration(minutes: 5);

  /// Looks for other devices' changes after [instantPullEvery], and again
  /// after each look, while the mode is Instant ([stopAutoSync] ends it).
  void _armInstantPull() {
    _periodicTimer = _timer(instantPullEvery, () {
      _periodicTimer = null;
      if (_disposed || _suspended || _settingsService.syncMode != 'instant') return;
      unawaited(_runSyncCycle());
      _armInstantPull();
    });
  }

  /// Run a sync cycle now regardless of the interval - used on app launch,
  /// on resume from background, and by an explicit "Sync now" that should
  /// go through the automatic (credential-cached, no-password) path.
  Future<void> triggerSync() => _runSyncCycle();

  /// Runs a cycle now after what stopped sync was dealt with (a device
  /// signed out to make room on ZestSSH Cloud): the refusals before it no
  /// longer count, so a sync paused after them goes on.
  /// A cycle already running is waited for first, as Sync now does, and the
  /// wait after a try the store failed is over (3.4.2 sweep, L3: a cycle in
  /// flight made this return at once, and nothing ran again after it).
  Future<void> retryAfterFix() async {
    while (_isSyncing) {
      await (_inFlight?.future ?? Future<void>.value());
    }
    _consecutiveFailures = 0;
    _dropRetry();
    syncError.value = null;
    await _runSyncCycle();
  }

  /// The pause of this device's person, where one holds now
  /// ([SettingsService.syncPause]).
  SyncPause? get pausedNow {
    final pause = _settingsService.syncPause;
    return pause != null && pause.at(_clock()) ? pause : null;
  }

  /// Pauses sync on this device (3.0), until [until], or until [endPause]
  /// where that is null: nothing syncs by itself meanwhile, and changes made
  /// here wait to go. Sync now still syncs, and sync stays set up. A cycle
  /// already running finishes.
  Future<void> pause({DateTime? until}) async {
    await _settingsService.setSyncPause(SyncPause(until: until));
    startAutoSync();
    _setActivity((a) => a.copyWith());
    AppLogger.info(until == null ? 'Sync paused until resumed' : 'Sync paused until $until');
  }

  /// Ends the pause ([pause]): sync runs by itself again, as its mode says,
  /// from now (a change that waited goes now).
  Future<void> endPause() async {
    await _settingsService.setSyncPause(null);
    startAutoSync();
    _setActivity((a) => a.copyWith());
    AppLogger.info('Sync pause ended');
  }

  /// Whether a pause of its person's holds now, so that nothing is to run by
  /// itself: one with a time ends by itself then ([endPause]), and one whose
  /// time has passed is forgotten.
  bool _holdForPause() {
    final pause = _settingsService.syncPause;
    if (pause == null) return false;
    if (!pause.at(_clock())) {
      unawaited(_settingsService.setSyncPause(null));
      return false;
    }
    final until = pause.until;
    if (until != null) {
      _pauseEnd = _timer(until.difference(_clock()), () {
        _pauseEnd = null;
        unawaited(endPause());
      });
    }
    return true;
  }

  Timer? _pauseEnd;

  /// The Profile screen's "Sync now": the same pull, merge and push as the
  /// background cycle, so another device's newer changes are merged BEFORE
  /// this device uploads (the old manual push overwrote them). Runs even when
  /// sync is set to manual or auto-sync has paused after failures, because
  /// the caller has just re-verified the account's keys and stored them.
  /// Everything local is offered for upload (unflagged edits such as trigger
  /// changes included); an unchanged fingerprint still skips a no-op push.
  ///
  /// Waits for a cycle already in flight, then runs a fresh one. Returns the
  /// store version this device is at afterwards; throws a [SyncException]
  /// describing what stopped the cycle, so the caller can show it.
  Future<int> syncNowManual() async {
    while (_isSyncing) {
      await (_inFlight?.future ?? Future<void>.value());
    }
    _consecutiveFailures = 0;
    syncError.value = null;
    await _settingsService.setSyncDirty(true);
    final problem = await _runSyncCycle(manual: true);
    if (problem != null) throw problem;
    return _settingsService.syncServerVersion;
  }

  /// Puts a new recovery key on the store (3.0): the same pull,
  /// merge and push as "Sync now", with the data key wrapped under the new
  /// key ([wrappedDek], [salt], [hash]) riding along on a push that always
  /// happens. The stored credentials must be the account's current ones: the
  /// caller has just proved the master password against the store and
  /// stored what it proved. Throws a [SyncException] saying what stopped it;
  /// until this returns, the old recovery key is the one that works.
  Future<void> replaceRecoveryKey({
    required Uint8List wrappedDek,
    required Uint8List salt,
    required Uint8List hash,
  }) async {
    final push = _RecoveryPush(wrappedDek: wrappedDek, salt: salt, hash: hash);
    // A cycle that started first makes this one step aside without running;
    // wait for it and go again, a few times at most.
    for (var tries = 0; tries < 3; tries++) {
      while (_isSyncing) {
        await (_inFlight?.future ?? Future<void>.value());
      }
      if (_suspended) break;
      _consecutiveFailures = 0;
      syncError.value = null;
      final problem = await _runSyncCycle(manual: true, recovery: push);
      if (problem != null) throw problem;
      if (push.pushed) return;
    }
    throw SyncException(gl10n.recoveryReplaceNotSaved);
  }

  /// Whether the account's store holds a recovery key, as this device last
  /// saw it; with [refresh], asks the store first. Null when unknown (sync
  /// is not set up here, the store does not say, or it cannot be reached).
  Future<bool?> recoveryKeyStatus({bool refresh = false}) async {
    if (refresh && _syncConfigured) {
      try {
        await _noteRecovery(await _resolveBackend().getStatus());
      } catch (e) {
        AppLogger.debug('Recovery key status check failed: $e');
      }
    }
    return _settingsService.syncRecoveryKeySet;
  }

  /// Keeps what the store says about its recovery key, when it says.
  Future<void> _noteRecovery(SyncStatus status) async {
    final has = status.hasRecovery;
    if (has != null && has != _settingsService.syncRecoveryKeySet) {
      await _settingsService.setSyncRecoveryKeySet(has);
    }
  }

  /// Turn sync off before the account is deleted: stop the timers, refuse
  /// every later cycle (automatic, triggered or "Sync now"), and wait for a
  /// cycle already running to finish, so nothing is uploaded mid-deletion.
  Future<void> suspend() async {
    _suspended = true;
    stopAutoSync();
    while (_isSyncing) {
      await (_inFlight?.future ?? Future<void>.value());
    }
  }

  /// Undo [suspend] when the deletion stopped before anything was deleted.
  /// Restarts the timers when sync is set to run automatically.
  void resume() {
    if (!_suspended) return;
    _suspended = false;
    startAutoSync();
  }

  /// Whether [suspend] is in effect.
  bool get isSuspended => _suspended;

  /// How many times [stopAutoSync] was called, and how many when the cycle
  /// running now began: a cycle that was under way when sync was stopped arms
  /// no try again by itself ([_failed]); one begun after it does (3.4.2 sweep,
  /// L2: a cycle under way at a lock armed one on the service the lock had
  /// left behind, which then tried against a closed database).
  int _stops = 0;
  int _stopsAtCycleStart = 0;

  /// The provider let this service go (its database closed with a lock, or a
  /// change of profile): it is stopped, and nothing more runs by itself on
  /// it. Its notifiers are left as they are, for whatever still holds them.
  void retire() {
    stopAutoSync();
    _disposed = true;
  }

  /// Stop the periodic auto-sync timer.
  void stopAutoSync() {
    _stops++;
    _pauseEnd?.cancel();
    _pauseEnd = null;
    _periodicTimer?.cancel();
    _periodicTimer = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    unawaited(_networkChanges?.cancel());
    _networkChanges = null;
    _dropRetry();
    _storeFailures = 0;
    _consecutiveFailures = 0;
    AppLogger.info('Auto-sync stopped');
  }

  /// Notify that local data has changed - marks the state dirty and
  /// debounces a push cycle. A pull's own restore writes also land here,
  /// but the cycle skips the resulting push via a content fingerprint
  /// (the gathered data equals what we just restored), so there's no echo.
  void notifyLocalChange() {
    final mode = _settingsService.syncMode;
    // Do nothing for users who never set up sync (mode defaults to 'auto'
    // but there are no credentials). Prevents a prefs write + timer on every
    // connection/identity edit for the majority who don't use Cloud Sync.
    if (!_syncConfigured) return;

    // Persist the dirty flag so a force-quit between edit and push doesn't
    // strand the change - the next cycle (launch/timer) still pushes it.
    // In Manual too (3.4.2 sweep, L4): the change goes with the first cycle
    // once the mode is back to Automatic or Instant, not only with the next
    // edit or a Sync now.
    unawaited(_settingsService
        .setSyncDirty(true)
        .then((_) => _setActivity((a) => a.copyWith())));
    if (mode != 'auto' && mode != 'instant') return;
    // (Paused by its person, the cycle this sets runs nothing: the change
    // waits, kept, until the pause ends.)

    _debounceTimer?.cancel();
    final delay = mode == 'instant'
        ? const Duration(seconds: 1)
        : _debounceDelay;
    _debounceTimer = Timer(delay, () => _runSyncCycle());
  }

  /// The device's network came back or changed: a try that waits its time
  /// after the store failed one goes now. With nothing waiting, nothing is
  /// done (a network change is no reason to sync by itself).
  void networkChanged() {
    if (_retryAt == null) return;
    _dropRetry();
    unawaited(_runSyncCycle());
  }

  /// Forgets the try that waits its time, and the wait.
  void _dropRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryAt = null;
  }

  /// A try failed. When the store was being asked ([store]) the app tries
  /// again by itself after a wait, in the modes that sync by themselves;
  /// any other failure counts towards the pause.
  void _failed({required bool store}) {
    if (!store) {
      _consecutiveFailures++;
      return;
    }
    _storeFailures++;
    final mode = _settingsService.syncMode;
    if (_stops != _stopsAtCycleStart || _suspended || _disposed || (mode != 'auto' && mode != 'instant') ||
        pausedNow != null) {
      return;
    }
    var wait = retryWaits[math.min(_storeFailures, retryWaits.length) - 1];
    if (mode == 'auto') {
      final between = Duration(minutes: _settingsService.syncIntervalMinutes);
      if (between < wait) wait = between;
    }
    _retryAt = _clock().add(wait);
    _retryTimer = _timer(wait, () {
      // The wait is over whatever the clock says by now.
      _retryTimer = null;
      _retryAt = null;
      unawaited(_runSyncCycle());
    });
    AppLogger.info('Auto-sync: the store failed try $_storeFailures, the next is in ${wait.inSeconds}s');
  }

  /// Check if a sync is due based on the configured interval.
  bool checkSyncDue() {
    final mode = _settingsService.syncMode;
    if (mode != 'auto' && mode != 'instant') return false;
    if (pausedNow != null) return false;
    if (mode == 'instant') return true;

    final lastSync = _settingsService.lastSyncTime;
    if (lastSync == null) return true;

    final intervalMinutes = _settingsService.syncIntervalMinutes;
    final elapsed = DateTime.now().difference(lastSync);
    return elapsed.inMinutes >= intervalMinutes;
  }

  /// Whether the service is currently running a sync operation.
  bool get isSyncing => _isSyncing;

  /// Run one full sync cycle: PULL if the server is ahead, then PUSH if we
  /// have local changes (or the server has no blob yet).
  ///
  /// Pull-before-push converges multi-device to the UNION of all devices'
  /// data without loss ([SyncDataService.restoreAll] is upsert/merge - it
  /// never deletes). `expectedVersion` is an optimistic lock; on a 409 the
  /// inner loop re-pulls the other device's change, merges, and pushes the
  /// union. The whole cycle runs under a single [_isSyncing] guard (no
  /// recursion) so a concurrently-scheduled trigger can't interleave.
  /// One pull, merge and push cycle. Background callers ignore the result. A
  /// [manual] run ([syncNowManual]) skips the sync-mode and failure-pause
  /// gates and gets back what stopped the cycle (null when it finished or had
  /// nothing to do), so the UI can say why instead of claiming success.
  Future<SyncException?> _runSyncCycle({bool manual = false, _RecoveryPush? recovery}) async {
    final ran = _cyclesRun;
    final problem = await _runOneCycle(manual: manual, recovery: recovery);
    if (_cyclesRun != ran) {
      _setActivity((a) => a.copyWith(
            running: false,
            paused: _consecutiveFailures >= _maxConsecutiveFailures,
            retrying: _retryTimer != null,
            failure: problem?.message,
            clearFailure: problem == null,
          ));
    }
    return problem;
  }

  Future<SyncException?> _runOneCycle({bool manual = false, _RecoveryPush? recovery}) async {
    if (_suspended) return null;
    if (!manual) {
      final mode = _settingsService.syncMode;
      if (mode != 'auto' && mode != 'instant') return null;
      // Paused by its person (Sync now is manual, and still runs).
      if (pausedNow != null) return null;

      // macOS did not let ZestSSH read a saved key in this run (3.3.2): nothing
      // runs by itself until the person chooses Try again where that is said, as
      // each try could bring macOS's question up again.
      if (keychainWaitsForPerson) return null;

      if (_consecutiveFailures >= _maxConsecutiveFailures) {
        AppLogger.warning(
          'Auto-sync paused after $_consecutiveFailures consecutive failures. '
          'User action required.',
        );
        return null;
      }

      // After a try the store failed, the next one waits its time: the
      // timer set then runs it, or a network change does.
      final retryAt = _retryAt;
      if (retryAt != null && _clock().isBefore(retryAt)) return null;
    }

    if (_isSyncing) {
      // Asked for while one runs (the cycle of a change saved meanwhile): the
      // running one goes again when it ends, if something is still to send.
      _askedWhileRunning = true;
      return null;
    }
    _isSyncing = true;
    _cyclesRun++;
    // This try stands for the one that was waiting.
    _dropRetry();
    _setActivity((a) => a.copyWith(running: true));
    final inFlight = Completer<void>();
    _inFlight = inFlight;
    _stopsAtCycleStart = _stops;

    // The active backend, resolved once for the whole cycle (a provider
    // switch mid-cycle applies on the next run, keeping this cycle
    // self-consistent). Resolved inside the try, whose finally ends the cycle:
    // a resolve that threw left sync "running" for the rest of the run, every
    // later cycle "asked while running" and Sync now waiting for ever (the
    // 3.4.2 sweep, L1).
    SyncBackend? resolved;
    var succeeded = false;
    // True while the store is being asked: a failure then is the store's
    // (or the way to it), and passes by itself.
    var asking = false;

    try {
      final backend = resolved = _resolveBackend();
      // ── Credentials (DEK + verification hash) ─────────────────────
      var dekB64 = await _readDek();
      var verHashB64 =
          await _readVerification();
      if (dekB64 == null) {
        await _migrateLegacyCredentials();
        dekB64 = await _readDek();
        verHashB64 =
            await _readVerification();
      }
      if (dekB64 == null || dekB64.isEmpty ||
          verHashB64 == null || verHashB64.isEmpty) {
        AppLogger.debug(
          'Auto-sync skipped: no sync credentials stored. '
          'User must set up or join sync first.',
        );
        return SyncSetupRequiredException(gl10n.syncNowNotSetUp);
      }

      // Salt was persisted at setup/join. If it's somehow missing we must
      // NOT invent a new one (that would diverge our key from the server's
      // blob) - bail and let the user re-join.
      final saltB64 = await _secureStorage.read(key: 'sync_salt');
      if (saltB64 == null) {
        AppLogger.warning('Auto-sync skipped: no salt stored.');
        return SyncSetupRequiredException(gl10n.syncNowNotSetUp);
      }

      final dek = SecretKey(base64Decode(dekB64));
      final salt = base64Decode(saltB64);
      final verificationHash = Uint8List.fromList(base64Decode(verHashB64));
      final dekBytes = await dek.extractBytes(); // for the keyed fingerprint

      // KDF params the wrapped DEK was derived under. A credentialed account
      // with no persisted params predates the v2 (128 MB) default, so its
      // params are the legacy set - sending those (never the current default)
      // is what stops a data-only push from drifting an old account's stored
      // params away from its wrapped DEK.
      final argon2Params = await _readStoredArgon2Params();

      // Up to two attempts so a push 409 (another device pushed first) can
      // re-pull + re-push against the new version. The guard is held across
      // both attempts - no recursion, no re-entrancy window.
      for (var attempt = 0; attempt < 2; attempt++) {
        asking = true;
        final status = await backend.getStatus();
        asking = false;
        await _noteRecovery(status);
        // A recovery key only goes on a store that holds the vault.
        if (recovery != null && !status.hasData) {
          return SyncSetupRequiredException(gl10n.syncNowNotSetUp);
        }
        // Clock-skew guard: newest-wins arbitration trusts this device's clock,
        // so a wrong local time silently makes it win (or lose) every conflict.
        // Compare against the server's clock and surface a large gap.
        final serverNow = status.serverTime;
        if (serverNow != null) {
          final skew = DateTime.now().toUtc().difference(serverNow);
          clockSkew.value =
              skew.abs() > _clockSkewThreshold ? skew : null;
          // A clock that is wrong prunes no tombstone (SyncDataService).
          _syncDataService.clockInDoubt = clockSkew.value != null;
        }
        var localVersion = _settingsService.syncServerVersion;
        // What this device holds of the store once a pull took it whole
        // (nothing kept as it is here): what it last synced, where no push
        // follows.
        Map<String, String>? pulledBase;

        // Whether the store is where this device left it. It is not when it
        // is BEHIND the device (it was restored from a backup, and lost what
        // was sent to it since), nor when it is at the device's number but
        // was written at another time than the device knows (a restored
        // store that others have written to since: another content under
        // the same count). Such a store is fetched from and merged like any
        // other device's work, and what this device holds that the store
        // does not is sent, changed here or not. (It used to be passed over:
        // never fetched from, what it had lost never sent again, and a
        // change made here refused as "another device wrote first" for ever.)
        final knownWritten = _settingsService.syncStoreUpdatedAt;
        final written = status.updatedAt;
        final behind = status.hasData && status.version < localVersion;
        final replaced = status.hasData &&
            status.version == localVersion &&
            knownWritten != null &&
            written != null &&
            written.millisecondsSinceEpoch != knownWritten.millisecondsSinceEpoch;
        var wentBack = behind || replaced;
        if (wentBack) {
          AppLogger.warning(
            'Auto-sync: the store is not where this device left it '
            '(store v${status.version}, this device v$localVersion): fetching, merging and sending what it lacks',
          );
        }

        // ── PULL if the store is ahead of us, or went back ────────
        if (status.hasData && (status.version > localVersion || wentBack)) {
          // Refuse an implausibly large blob before downloading it - a
          // rogue/compromised server could otherwise OOM the app on the
          // unattended launch/resume pull. Sync data is tiny (KBs).
          if (status.blobSize > SyncService.maxBlobBytes) {
            _consecutiveFailures = _maxConsecutiveFailures;
            // (It was English.)
            _sayPaused(
              gl10n.syncTooLargeRefused,
              detail: 'Blob of ${status.blobSize} bytes refused (limit ${SyncService.maxBlobBytes})',
              manual: manual,
            );
            AppLogger.error(
                'Auto-sync refused oversized blob: ${status.blobSize} bytes');
            return SyncException(syncError.value!);
          }
          asking = true;
          final pullResult = await backend.pull();
          asking = false;
          Map<String, dynamic> data;
          try {
            data = await SyncService.decrypt(pullResult.encryptedData, dek);
          } on SyncDecryptionException catch (e) {
            // Split-brain: our cached DEK can't decrypt the server blob -
            // another device re-keyed it. Surface it and STOP; pushing here
            // would overwrite the other device's data with our incompatible
            // key. Stays paused until resetFailures() (a successful re-join).
            _consecutiveFailures = _maxConsecutiveFailures;
            // (It was English.) The way out is the same as for a push the
            // server refuses: the sync password proved here again.
            _sayPaused(gl10n.syncCannotDecrypt, detail: e.detail ?? '$e', needsPassword: true, manual: manual);
            AppLogger.error(
                'Auto-sync pull decrypt failed (split-brain key mismatch)', e);
            return SyncKeysMismatchException(syncError.value!);
          }
          // ── A blob older than this device has seen ─────────────────
          // Its version and time are the store's word; its count is inside
          // the encryption. Below the highest this device saw, it is an old
          // copy whatever number it came under: merged as a store that went
          // back, and told of where a race between two pushes does not
          // explain it (SyncDataService.compareStoreCount). One with no
          // count at all, on a device that has seen one, is merged the same
          // way and not told of.
          final counted = await _syncDataService.compareStoreCount(data);
          if (counted.older && !wentBack) {
            AppLogger.warning(
              'Auto-sync: the store is not where this device left it '
              '(its data counts ${counted.count ?? 'nothing'}, this device saw ${counted.seen}): '
              'fetching, merging and sending what it lacks',
            );
          }
          wentBack = wentBack || counted.older;
          // ── Stale-device reconcile ─────────────────────────────────
          // A device offline longer than the tombstone-retention window may
          // still hold rows the cloud has deleted AND forgotten (its tombstone
          // GC'd). Merging then pushing would silently resurrect them for every
          // device. Before restoring, stop and let the user decide. This only
          // runs on the rare stale pull; a recently-synced device never enters
          // it, so the common path pays nothing.
          if (_isStale()) {
            final report = await _syncDataService.assessStaleReconcile(data);
            if (report.hasLocalOnly) {
              final handler = staleReconcileHandler;
              if (handler == null) {
                // No UI attached: never resurrect unattended. Skip the whole
                // cycle; a later cycle with a handler registered will prompt.
                AppLogger.warning(
                    'Stale-device reconcile needed (${report.total} local-only '
                    'rows) but no UI handler registered - skipping sync cycle.');
                return SyncException(gl10n.syncNowPausedForDecision);
              }
              final choice = await handler(report);
              switch (choice) {
                case StaleReconcileChoice.cancel:
                  AppLogger.info('Stale-device reconcile deferred by user; '
                      'sync paused this cycle.');
                  return SyncException(gl10n.syncNowPausedForDecision);
                case StaleReconcileChoice.adoptCloud:
                  await _syncDataService.dropLocalOnly(report);
                  AppLogger.info('Stale-device reconcile: adopted cloud, '
                      'dropped ${report.total} local-only rows.');
                case StaleReconcileChoice.mergeAnyway:
                  AppLogger.info('Stale-device reconcile: user kept '
                      '${report.total} local-only rows (they will be pushed).');
              }
            }
          }
          // Merged three ways with what this device last synced (3.0): a
          // change made here and not there is kept, and sent by the push
          // below.
          final result = await _syncDataService.restoreAll(
            data,
            merge: SyncMergeBase(
                key: dekBytes, base: await _syncDataService.loadSyncBase(), storeWentBack: wentBack),
          );
          if (result.knownHostConflicts.isNotEmpty) {
            // A synced host key disagreed with one already trusted here - a
            // possible MITM on one of the devices. Surface it (never merged).
            hostKeyConflict.value = result.knownHostConflicts.join(', ');
          }
          if (result.success) {
            if (counted.wentBack && _storeWentBackSaid != counted.count) {
              _storeWentBackSaid = counted.count;
              storeWentBack.value++;
            }
            if (result.keptHere > 0) {
              // Kept here, so the store lacks them: they are sent now.
              await _settingsService.setSyncDirty(true);
            } else {
              pulledBase = SyncDataService.itemHashes(data, dekBytes);
            }
            localVersion = pullResult.version;
            await _settingsService.setSyncServerVersion(pullResult.version, storeUpdatedAt: pullResult.updatedAt);
            await _settingsService.setSyncContentHash(
                SyncDataService.contentFingerprint(data, dekBytes));
            await _settingsService.setLastSyncTime(DateTime.now());
            AppLogger.info(
              'Auto-sync pulled v${pullResult.version} '
              '(${result.recordsRestored} records merged)',
            );
          } else {
            // The other devices' data could not be merged here. Pushing now
            // would only loop on conflicts and bury the cause, and the device
            // would look healthy while it is not: stop, and say why.
            AppLogger.warning('Auto-sync restore failed: ${result.error}');
            _sayPaused(gl10n.syncMergeFailed, detail: result.error, manual: manual);
            throw SyncException(gl10n.syncMergeFailed, detail: result.error);
          }
        } else if (knownWritten == null && written != null) {
          // Level with the store, and not yet knowing when it was written
          // (this device wrote it itself to a server that does not say, or
          // an older version of the app synced last): noted now.
          await _settingsService.setSyncStoreUpdatedAt(written);
        }

        // ── PUSH if we have local changes, the server has no blob, or the
        //    store went back and may lack what this device holds ───────
        final dirty = _settingsService.syncDirty;
        if (dirty || !status.hasData || recovery != null || wentBack) {
          // Read before gathering: a change saved after this is not in what is
          // sent, and stays marked for the next push.
          final mark = _settingsService.syncDirtyMark;
          final data = await _syncDataService.gatherAll();
          final fingerprint =
              SyncDataService.contentFingerprint(data, dekBytes);

          // Skip a no-op / echo push: if the synced content is exactly what
          // we last reconciled, there's nothing to send. This is what stops
          // a pull's own restore writes from echoing a push (and ping-ponging
          // the version), and stops writes to non-synced tables from
          // inflating the version.
          if (recovery == null &&
              status.hasData &&
              fingerprint == _settingsService.syncContentHash) {
            // What the store holds is what this device holds.
            await _syncDataService.saveSyncBase(SyncDataService.itemHashes(data, dekBytes));
            await _settingsService.clearSyncDirty(since: mark);
            // Checked and current: this is the device's last sync too.
            await _settingsService.setLastSyncTime(DateTime.now());
            _consecutiveFailures = 0;
            _storeFailures = 0;
            syncError.value = null;
            succeeded = true;
            return null;
          }

          try {
            asking = true;
            final (version: newVersion, blobSize: _, updatedAt: pushedAt) = await backend.push(
              data: data,
              dek: dek,
              salt: salt,
              verificationHash: verificationHash,
              deviceId: await _getDeviceId(),
              expectedVersion: status.hasData ? localVersion : null,
              // We saw an empty store and did NOT merge remote data. Declare a
              // create so a store that gained data since (another device's
              // first push) rejects this write → conflict → we loop, pull,
              // merge, and re-push the union instead of clobbering it.
              createOnly: !status.hasData,
              // Match the wrapped DEK's params (never the current default).
              argon2Params: argon2Params,
              // A new recovery key, wrapped under the same params.
              wrappedDekRecovery: recovery?.wrappedDek,
              recoverySalt: recovery?.salt,
              recoveryHash: recovery?.hash,
            );
            asking = false;
            if (recovery != null) {
              recovery.pushed = true;
              await _settingsService.setSyncRecoveryKeySet(true);
            }
            await _settingsService.setSyncServerVersion(newVersion, storeUpdatedAt: pushedAt);
            await _settingsService.setSyncContentHash(fingerprint);
            // Only now: a push another device beat counts for nothing.
            final sent = SyncDataService.storeCountOf(data);
            if (sent != null) await _syncDataService.noteStoreCount(sent);
            // What was sent is what this device last synced.
            await _syncDataService.saveSyncBase(SyncDataService.itemHashes(data, dekBytes));
            await _settingsService.clearSyncDirty(since: mark);
            await _settingsService.setLastSyncTime(DateTime.now());
            _consecutiveFailures = 0;
            _storeFailures = 0;
            syncError.value = null;
            AppLogger.info('Auto-sync pushed v$newVersion');
            succeeded = true;
            return null;
          } on SyncConflictException catch (e) {
            // Another device pushed between our getStatus and our push. Loop
            // once more: re-getStatus sees the newer version, pulls + merges
            // it, then pushes the union with the right expectation.
            AppLogger.warning(
              'Auto-sync push conflict (server v${e.serverVersion}); '
              'attempt ${attempt + 1}/2',
            );
            asking = false;
            if (attempt == 0) continue;
            // Another device wrote first, twice over: it passes by itself.
            _failed(store: true);
            return SyncFailure.writtenFirst(e);
          }
        } else {
          // Nothing to push and we were already current - healthy. Record the
          // check: "last synced" means the last time this device confirmed it
          // matches the account, and it paces the next automatic check.
          // What this device last synced: what it took whole from the store,
          // or, where it keeps none yet and has nothing to send, what it holds.
          if (pulledBase != null) {
            await _syncDataService.saveSyncBase(pulledBase);
          } else if (await _syncDataService.loadSyncBase() == null) {
            await _syncDataService.saveSyncBase(
                SyncDataService.itemHashes(await _syncDataService.gatherAll(), dekBytes));
          }
          await _settingsService.setLastSyncTime(DateTime.now());
          _consecutiveFailures = 0;
          _storeFailures = 0;
          syncError.value = null;
          succeeded = true;
          return null;
        }
      }
    } on SyncStoreUnknownException catch (e) {
      // The store this device syncs with could not be read (3.4.2): nothing
      // was asked of any store. Not counted, and not tried again by itself.
      // A keychain macOS said no to is said by its own notice, whose Try
      // again reads the store again; anything else pauses sync with what it
      // is, until the storage is chosen again.
      if (!e.keychain) _sayPaused(e.message, detail: e.detail, manual: manual);
      AppLogger.warning('Auto-sync waits: the store it syncs with is not known (${e.detail})');
      return e;
    } on SyncSetupRequiredException catch (e) {
      // This device can't write a recoverable blob - the store was emptied out
      // of band, or the server rejected a stale/legacy push (426). Pause
      // instead of retry-looping, and surface the specific reason the exception
      // carries (the server's own message for a 426).
      _consecutiveFailures = _maxConsecutiveFailures;
      // Keys that are no longer the account's are proved again; anything
      // else that asks for setup is set up again.
      final keys = e is SyncKeysMismatchException;
      // Past the devices ZestSSH Cloud syncs for one person: a device is
      // signed out, nothing is set up again.
      final room = e is SyncCloudDeviceLimitException;
      _sayPaused(e.message,
          detail: e.detail, needsPassword: keys, needsSetup: !keys && !room, needsDeviceRoom: room, manual: manual);
      AppLogger.error('Auto-sync paused: setup required', e);
      return e;
    } on KeychainAccessDenied catch (e) {
      // A key sync needs could not be read (3.3.2). Not counted towards the
      // pause, and not tried again by itself: background cycles wait until the
      // person chooses Try again (keychainWaitsForPerson), where it is said.
      AppLogger.warning('Auto-sync waits: macOS did not let ZestSSH read a saved key (${e.status})');
      return SyncFailure.onDevice(e);
    } on SyncException catch (e, stack) {
      _failed(store: asking);
      AppLogger.error(
        asking
            ? 'Auto-sync: the store failed (try $_storeFailures)'
            : 'Auto-sync failed ($_consecutiveFailures/$_maxConsecutiveFailures)',
        e,
        stack,
      );
      // The store's failure is said as what it is, with its code; what the
      // store said in so many words, and what failed here, as it was said.
      return asking ? SyncFailure.ofStore(e, hosted: resolved?.kind == SyncBackendKind.zestServer) : e;
    } catch (e, stack) {
      _failed(store: asking);
      AppLogger.error(
        asking
            ? 'Auto-sync: the store failed (try $_storeFailures)'
            : 'Auto-sync failed ($_consecutiveFailures/$_maxConsecutiveFailures)',
        e,
        stack,
      );
      // A headline a person can act on, the error as it was caught kept for
      // "Copy details". (Whatever failed used to be said as "Couldn't reach
      // the sync server", a failure on this device included.)
      return asking
          ? SyncFailure.ofStore(e, hosted: resolved?.kind == SyncBackendKind.zestServer)
          : SyncFailure.onDevice(e);
    } finally {
      _isSyncing = false;
      inFlight.complete();
      if (identical(_inFlight, inFlight)) _inFlight = null;
      if (succeeded) _afterSuccessfulCycle();
      if (_askedWhileRunning) {
        _askedWhileRunning = false;
        if (succeeded && _settingsService.syncDirty && !_disposed && !_suspended) {
          _debounceTimer?.cancel();
          _debounceTimer = _timer(_debounceDelay, () => _runSyncCycle());
        }
      }
    }
    return null;
  }

  /// Never lets follow-up work break or delay sync.
  void _afterSuccessfulCycle() {
    final hook = _onCycleSucceeded;
    if (hook == null) return;
    try {
      hook();
    } catch (e) {
      AppLogger.warning('After-sync work failed: $e');
    }
  }

  /// Migrate from legacy `sync_mek` or `sync_password` storage.
  ///
  /// Old versions stored the MEK directly. Since the MEK now wraps
  /// the DEK rather than encrypting data, we can't automatically
  /// migrate - the user must do a manual sync to establish the new
  /// DEK. Clear the legacy keys so the migration check doesn't run
  /// again.
  Future<void> _migrateLegacyCredentials() async {
    final legacyMek = await _secureStorage.read(key: _legacySyncMekKey);
    final legacyPassword =
        await _secureStorage.read(key: _legacySyncPasswordKey);

    if (legacyMek != null || legacyPassword != null) {
      AppLogger.info(
        'Legacy sync credentials found - clearing. '
        'User must sync manually to establish new DEK.',
      );
      await _secureStorage.delete(key: _legacySyncMekKey);
      await _secureStorage.delete(key: _legacySyncPasswordKey);
    }
  }

  Future<String> _getDeviceId() async {
    var deviceId = await _secureStorage.read(key: 'device_id');
    if (deviceId == null) {
      deviceId =
          '${Platform.operatingSystem}_${const Uuid().v4().substring(0, 8)}';
      await _secureStorage.write(key: 'device_id', value: deviceId);
    }
    return deviceId;
  }

  /// Reset the failure counter (and clear any surfaced error), allowing
  /// auto-sync to resume. Call after the user re-joins / fixes credentials.
  void resetFailures() {
    _consecutiveFailures = 0;
    syncError.value = null;
    AppLogger.info('Auto-sync failure counter reset');
  }

  /// Store the DEK and verification hash for auto-sync use.
  ///
  /// Call this after a successful manual sync or setup so that
  /// auto-sync can operate without prompting the user.
  Future<void> storeSyncCredentials(
    SecretKey dek,
    Uint8List verificationHash, {
    Map<String, dynamic>? argon2Params,
  }) async {
    final dekBytes = await dek.extractBytes();
    // Persist the KDF params this DEK was wrapped under so data-only pushes
    // send matching params. Callers that adopt an existing account's key
    // (join / restore / sync-now) MUST pass its pulled params; setup / change-
    // password establish fresh material with the current default.
    //
    // Write params BEFORE the DEK: _readStoredArgon2Params only matters once a
    // DEK exists, so params-first guarantees a credentialed account can never
    // be seen as paramless (which would wrongly fall back to legacy 64 MB) if
    // the process is killed mid-write.
    await _secureStorage.write(
      key: _syncArgon2ParamsKey,
      value: jsonEncode(argon2Params ?? SyncService.argon2Params),
    );
    await _secureStorage.write(
      key: _syncDekKey,
      value: await keepSealed(_tree, _syncDekKey, base64Encode(dekBytes)),
    );
    await AccountSecret.syncVerification
        .write(_secureStorage, base64Encode(verificationHash), tree: () => _tree);
    // Clean up any legacy keys.
    await _secureStorage.delete(key: _legacySyncMekKey);
    await _secureStorage.delete(key: _legacySyncPasswordKey);
    _syncConfigured = true;
    _setActivity((a) => a.copyWith(configured: true, clearFailure: true, paused: false));
  }

  /// This device's sync credentials, to hand to a new device the person
  /// approves after both screens showed the same words (3.0);
  /// null while sync is not set up here.
  Future<({Uint8List dek, Uint8List verificationHash, Map<String, dynamic> argon2Params})?>
      readCredentials() async {
    final dek = await _readDek();
    final hash = await _readVerification();
    if (dek == null || hash == null) return null;
    try {
      return (
        dek: base64Decode(dek),
        verificationHash: base64Decode(hash),
        argon2Params: await _readStoredArgon2Params(),
      );
    } on FormatException {
      return null;
    }
  }

  /// Read the KDF params the stored DEK was wrapped under. Falls back to the
  /// legacy (v1, 64 MB) set when none are persisted, because a credentialed
  /// account without stored params necessarily predates the v2 default.
  Future<Map<String, dynamic>> _readStoredArgon2Params() async {
    final raw = await _secureStorage.read(key: _syncArgon2ParamsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {
        // Fall through to the legacy default.
      }
    }
    return SyncService.legacyArgon2Params;
  }

  /// Clear all stored sync credentials.
  Future<void> clearSyncCredentials() async {
    await _secureStorage.delete(key: _syncDekKey);
    await AccountSecret.syncVerification.delete(_secureStorage);
    await _secureStorage.delete(key: _syncArgon2ParamsKey);
    await _secureStorage.delete(key: _legacySyncMekKey);
    await _secureStorage.delete(key: _legacySyncPasswordKey);
    await _settingsService.setSyncRecoveryKeySet(null);
    // What this device last synced belongs to the sync taken apart.
    await _syncDataService.clearSyncBase();
    _syncConfigured = false;
    // Nothing is left to try again.
    _dropRetry();
    _storeFailures = 0;
    _setActivity((_) => const SyncActivity());
  }

  /// Release resources held by this service.
  void dispose() {
    stopAutoSync();
    _disposed = true;
    activity.dispose();
    syncError.dispose();
    clockSkew.dispose();
    hostKeyConflict.dispose();
    storeWentBack.dispose();
  }
}

/// A new recovery key on its way to the store with one sync cycle.
class _RecoveryPush {
  _RecoveryPush({required this.wrappedDek, required this.salt, required this.hash});

  final Uint8List wrappedDek;
  final Uint8List salt;
  final Uint8List hash;

  /// Set once the store accepted the push that carried it.
  bool pushed = false;
}
