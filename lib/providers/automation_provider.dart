import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/models/automation_api_key.dart';
import 'package:zestssh/models/enums.dart' show ConnectionProtocol;
import 'package:drift/drift.dart' show Value;
import 'package:zestssh/database/database.dart' show AutomationHistoryCompanion, AutomationHistoryData;
import 'package:zestssh/database/daos/scheduled_tasks_dao.dart';
import 'package:zestssh/features/orchards/spaces.dart' show TreeSpace;
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/automation_service.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/workflow_provider.dart';
import 'package:zestssh/services/deep_link_service.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';

// ── Automation state ────────────────────────────────────────────

enum AutomationStatus { idle, running, completed, error }

/// Why automation did not run what a link or another app asked of it.
enum AutomationBlocked {
  /// Automation needs Squeezed.
  needsSqueezed,

  /// Automation is turned off on this device.
  off,

  /// The API key it came with is not one of this device's, or has expired.
  keyNotKnown,

  /// The API key it came with is for another host.
  otherHost,

  /// The host's key is not allowed in runs with nobody there.
  keyNotUnattended,

  /// The host is a Telnet host: every other way of opening one asks first,
  /// and with nobody there nobody can be asked.
  plaintextHost,

  /// The host is a remote screen (VNC or RDP): a picture for someone to look
  /// at, whose questions (a certificate, a password) nobody is there to
  /// answer.
  screenHost,

  /// The scheduled task whose notification was tapped was deleted or turned
  /// off since.
  taskGone,
}

class AutomationState {
  final AutomationStatus status;
  final AutomationResult? lastResult;
  final String? errorMessage;
  final bool enabled;

  /// Set when automation did not run what it was asked, with why. The UI
  /// says so and then clears it.
  final AutomationBlocked? blocked;

  const AutomationState({
    this.status = AutomationStatus.idle,
    this.lastResult,
    this.errorMessage,
    this.enabled = true,
    this.blocked,
  });

  AutomationState copyWith({
    AutomationStatus? status,
    AutomationResult? lastResult,
    String? errorMessage,
    bool? enabled,
    AutomationBlocked? blocked,
  }) {
    return AutomationState(
      status: status ?? this.status,
      lastResult: lastResult ?? this.lastResult,
      errorMessage: errorMessage ?? this.errorMessage,
      enabled: enabled ?? this.enabled,
      blocked: blocked,
    );
  }

  /// Return a copy with [blocked] cleared.
  AutomationState clearBlocked() => AutomationState(
        status: status,
        lastResult: lastResult,
        errorMessage: errorMessage,
        enabled: enabled,
      );
}

// ── Providers ───────────────────────────────────────────────────

/// The reactive automation state (status, last result, enabled).
final automationProvider =
    StateNotifierProvider<AutomationNotifier, AutomationState>((ref) {
  return AutomationNotifier(ref);
});

/// The underlying [AutomationService] for headless SSH execution.
final automationServiceProvider = Provider<AutomationService>((ref) {
  // Automation runs against your Tree's hosts and keys (3.0).
  final db = ref.watch(treeDatabaseProvider);
  final secureStorage = ref.watch(secureStorageProvider);
  final service = AutomationService(
    db,
    secureStorage,
    // A saved host is signed in to as a session to it is, in your Tree
    // whatever space is on screen.
    signIn: (connection, {required unattended, onLog}) async => (await ref
            .read(activeSessionsProvider.notifier)
            .openRunClient(connection, onLog: onLog, unattended: unattended, space: const TreeSpace()))
        .ssh,
  );
  ref.onDispose(() => service.dispose());
  return service;
});

/// Log of automation runs (most recent first), persisted to database.
final automationLogProvider =
    StreamProvider<List<AutomationHistoryData>>((ref) {
  return ref.watch(automationHistoryDaoProvider).watchAll();
});

/// All automation API keys. Persisted in FlutterSecureStorage as JSON.
final automationKeysProvider =
    StateNotifierProvider<AutomationKeysNotifier, List<AutomationApiKey>>(
        (ref) {
  return AutomationKeysNotifier(ref.watch(secureStorageProvider));
});

class AutomationKeysNotifier extends StateNotifier<List<AutomationApiKey>> {
  final FlutterSecureStorage _storage;
  static const _storageKey = 'automation_api_keys';
  static const _rateLimitKey = 'automation_rate_limit';

  // Rate limiting state - persisted to secure storage so a process restart
  // cannot bypass the lockout window.
  int _failedAttempts = 0;
  DateTime? _lockedUntil;

  // Completes once keys + rate-limit state have finished loading from secure
  // storage. Callers await [ready] before validating so a cold-start intent
  // doesn't race an empty key list (which would fail every automation with
  // "invalid key" until _load() completes).
  final Completer<void> _readyCompleter = Completer<void>();
  Future<void> get ready => _readyCompleter.future;

  AutomationKeysNotifier(this._storage) : super([]) {
    _load();
  }

  /// The keys kept could not be read as this started (3.3.2: on a Mac, macOS did not
  /// let ZestSSH read them): the list in memory started empty, and writing it would
  /// put an empty list, or only what was made since, over every key there is. Until
  /// they are read, nothing is written over them ([_save]).
  bool _unread = false;

  Future<void> _load() async {
    String? json;
    try {
      json = await _storage.read(key: _storageKey);
    } catch (e) {
      _unread = true;
      AppLogger.warning('Automation: the API keys could not be read (${errorKind(e)}); nothing is written over them');
    }
    try {
      if (json != null && json.isNotEmpty) {
        state = AutomationApiKey.decodeList(json);
        // A store from before show-once held each key itself: it is written
        // again at once with only each key's hash and hint, so the keys
        // leave secure storage on the first start of this version.
        if (state.any((k) => k.readFromRawKey)) {
          state = [for (final k in state) k.copyWith()];
          await _save();
          AppLogger.info('Automation: API keys now kept as hashes only');
        }
      }
    } catch (e) {
      AppLogger.error('Failed to load automation keys', e);
      state = [];
    }
    await _loadRateLimitState();
    if (!_readyCompleter.isCompleted) _readyCompleter.complete();
  }

  Future<void> _loadRateLimitState() async {
    try {
      final json = await _storage.read(key: _rateLimitKey);
      if (json != null && json.isNotEmpty) {
        final data = jsonDecode(json) as Map<String, dynamic>;
        _failedAttempts = data['failedAttempts'] as int? ?? 0;
        final lockedStr = data['lockedUntil'] as String?;
        if (lockedStr != null) {
          _lockedUntil = DateTime.tryParse(lockedStr);
          // Clear expired lockouts
          if (_lockedUntil != null && _lockedUntil!.isBefore(DateTime.now())) {
            _lockedUntil = null;
            _failedAttempts = 0;
            await _saveRateLimitState();
          }
        }
      }
    } catch (e) {
      AppLogger.error('Failed to load rate limit state', e);
    }
  }

  Future<void> _saveRateLimitState() async {
    try {
      await _storage.write(
        key: _rateLimitKey,
        value: jsonEncode({
          'failedAttempts': _failedAttempts,
          if (_lockedUntil != null)
            'lockedUntil': _lockedUntil!.toIso8601String(),
        }),
      );
    } catch (e) {
      AppLogger.error('Failed to save rate limit state', e);
    }
  }

  Future<void> _save() async {
    if (_unread) {
      // What is kept was never read: read now, and what this run made goes beside
      // it. Still not read: nothing is written, and what is kept stays as it is.
      final String? json;
      try {
        json = await _storage.read(key: _storageKey);
      } catch (e) {
        AppLogger.warning('Automation: the API keys kept could not be read (${errorKind(e)}), and are not written over');
        return;
      }
      _unread = false;
      List<AutomationApiKey> kept;
      try {
        kept = json == null || json.isEmpty ? [] : AutomationApiKey.decodeList(json);
      } catch (_) {
        kept = [];
      }
      final made = {for (final k in state) k.id};
      state = [
        for (final k in kept)
          if (!made.contains(k.id)) k.readFromRawKey ? k.copyWith() : k,
        ...state,
      ];
    }
    await _storage.write(
      key: _storageKey,
      value: AutomationApiKey.encodeList(state),
    );
  }

  /// Create a new key with the given label and optional expiration.
  ///
  /// [scopeConnectionId] restricts the key to a single connection; `null`
  /// (the default) leaves it unrestricted - the pre-scoping behaviour.
  ///
  /// Returns the key's record and the key itself ([secret]). Only the record
  /// is kept (its hash and hint): [secret] is for the one dialog that shows
  /// it, once, and is never stored.
  ({AutomationApiKey key, String secret}) createKey(
    String label, {
    DateTime? expiresAt,
    String? scopeConnectionId,
  }) {
    final secret = AutomationApiKey.generateKey();
    final key = AutomationApiKey.fromSecret(
      id: const Uuid().v4(),
      label: label,
      secret: secret,
      createdAt: DateTime.now(),
      expiresAt: expiresAt,
      scopeConnectionId: scopeConnectionId,
    );
    state = [...state, key];
    _save();
    AppLogger.info('Automation: created API key "${key.label}"'
        '${expiresAt != null ? " (expires ${expiresAt.toIso8601String()})" : ""}'
        '${scopeConnectionId != null ? " (scoped to $scopeConnectionId)" : ""}');
    return (key: key, secret: secret);
  }

  /// Delete a key by ID.
  void deleteKey(String id) {
    state = state.where((k) => k.id != id).toList();
    _save();
    AppLogger.info('Automation: revoked API key $id');
  }

  /// Update the lastUsedAt timestamp for a key.
  void markUsed(String keyValue) {
    final inputHash = _hashBytes(keyValue);
    state = state.map((k) {
      if (_constantTimeEquals(inputHash, _storedHashBytes(k))) {
        return k.copyWith(lastUsedAt: DateTime.now());
      }
      return k;
    }).toList();
    _save();
  }

  /// Compute escalating lockout duration based on the current failure count.
  ///
  /// - 5 failures  -> 1 minute lockout
  /// - 10 failures -> 5 minute lockout
  /// - 15 failures -> 30 minute lockout
  ///
  /// Returns `null` if the threshold has not been reached.
  Duration? _escalatingLockout() {
    if (_failedAttempts >= 15) return const Duration(minutes: 30);
    if (_failedAttempts >= 10) return const Duration(minutes: 5);
    if (_failedAttempts >= 5) return const Duration(minutes: 1);
    return null;
  }

  /// Record a failed authentication attempt and apply lockout if warranted.
  void _recordFailure() {
    _failedAttempts++;
    final lockout = _escalatingLockout();
    if (lockout != null) {
      _lockedUntil = DateTime.now().add(lockout);
      AppLogger.warning(
        'Automation: rate limit lockout for ${lockout.inMinutes} min '
        '(after $_failedAttempts failures)',
      );
    }
    _saveRateLimitState();
  }

  /// Record a successful authentication. Resets the failure counter and any
  /// active lockout to zero - a genuine valid key proves this is not a
  /// brute-force burst.
  void _recordSuccess() {
    if (_failedAttempts != 0 || _lockedUntil != null) {
      _failedAttempts = 0;
      _lockedUntil = null;
      _saveRateLimitState();
    }
  }

  /// Clear any active brute-force lockout. Exposed so the user can recover if
  /// a co-installed app tripped the throttle by spamming bad keys.
  void resetLockout() {
    if (_failedAttempts != 0 || _lockedUntil != null) {
      _failedAttempts = 0;
      _lockedUntil = null;
      _saveRateLimitState();
      AppLogger.info('Automation: rate-limit lockout manually reset');
    }
  }

  /// Check if a key value is valid using constant-time comparison.
  bool isValidKey(String keyValue) {
    // SECURITY: compare the key FIRST. The lockout only throttles guessing of
    // UNKNOWN keys - a valid key must always succeed, otherwise a co-installed
    // app that spams bad keys could permanently deny the owner's automations.
    final inputHash = _hashBytes(keyValue);
    for (final k in state) {
      if (_constantTimeEquals(inputHash, _storedHashBytes(k))) {
        _recordSuccess();
        return true;
      }
    }

    // No key matched. Consult the lockout only on this failure path.
    if (_lockedUntil != null && _lockedUntil!.isAfter(DateTime.now())) {
      return false;
    }
    _recordFailure();
    return false;
  }

  /// Validate a key and mark it as used in one atomic operation.
  /// Eliminates the race condition between separate isValidKey + markUsed calls.
  bool validateAndMarkUsed(String keyValue) {
    // SECURITY: compare the key BEFORE consulting the lockout (see [isValidKey]).
    // A valid, unexpired key always succeeds even while a lockout from earlier
    // bad attempts is active, so a self-DoS via bad-key spam is impossible.
    final inputHash = _hashBytes(keyValue);
    for (int i = 0; i < state.length; i++) {
      if (_constantTimeEquals(inputHash, _storedHashBytes(state[i]))) {
        return _acceptAt(i);
      }
    }

    // No key matched. Consult the lockout only on this failure path.
    if (_lockedUntil != null && _lockedUntil!.isAfter(DateTime.now())) {
      return false;
    }
    _recordFailure();
    return false;
  }

  /// A run of one of the app's own scheduled tasks, which names its key by id
  /// and carries no key: the key exists, has not expired, and is marked used,
  /// as [validateAndMarkUsed] does for a key presented.
  ///
  /// SECURITY: the id is not a secret and does not authenticate anything by
  /// itself. What authenticates such a run is the single-use launch token
  /// Android's scheduler hands over with it (ScheduledLaunchTokens,
  /// MainActivity.kt passes api_key_id on only after consuming a valid
  /// token). This only says the task's key is still there, unexpired, so a
  /// revoked or expired key stops its tasks.
  bool validateIdAndMarkUsed(String keyId) {
    for (int i = 0; i < state.length; i++) {
      if (state[i].id == keyId) return _acceptAt(i);
    }
    AppLogger.warning('Automation: a scheduled task names a key that is not there');
    return false;
  }

  /// The key at [i] was matched: refused when expired, else marked used.
  bool _acceptAt(int i) {
    if (state[i].isExpired) {
      AppLogger.warning('Automation: key "${state[i].label}" has expired');
      _recordFailure();
      return false;
    }
    _recordSuccess();
    // Mark used atomically
    state = [
      for (int j = 0; j < state.length; j++)
        if (j == i) state[j].copyWith(lastUsedAt: DateTime.now()) else state[j],
    ];
    _save();
    return true;
  }

  /// SHA-256 of a presented key's UTF-8 bytes.
  static List<int> _hashBytes(String keyValue) =>
      sha256.convert(utf8.encode(keyValue)).bytes;

  /// A stored key's hash as bytes (it is kept as lowercase hex). A hash that
  /// is not 64 hex digits matches nothing.
  static List<int> _storedHashBytes(AutomationApiKey k) {
    final h = k.hash;
    if (h.length != 64) return const [];
    final out = List<int>.filled(32, 0);
    for (int i = 0; i < 32; i++) {
      final b = int.tryParse(h.substring(i * 2, i * 2 + 2), radix: 16);
      if (b == null) return const [];
      out[i] = b;
    }
    return out;
  }

  /// Constant-time comparison to prevent timing attacks.
  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    int result = 0;
    for (int i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }

  /// Rename a key.
  void renameKey(String id, String newLabel) {
    state = state.map((k) {
      if (k.id == id) {
        // Preserve expiry AND scope - dropping either on rename would silently
        // un-expire or (worse) broaden a connection-scoped key to all hosts.
        return k.copyWith(label: newLabel);
      }
      return k;
    }).toList();
    _save();
  }

  /// Return the key whose secret matches [keyValue], or null. Used by the
  /// dispatcher AFTER [validateAndMarkUsed] has already authenticated the
  /// request, to read the matched key's connection scope for enforcement.
  AutomationApiKey? keyForValue(String keyValue) {
    final inputHash = _hashBytes(keyValue);
    for (final k in state) {
      if (_constantTimeEquals(inputHash, _storedHashBytes(k))) return k;
    }
    return null;
  }

  /// The key with this id, or null.
  AutomationApiKey? keyForId(String id) {
    for (final k in state) {
      if (k.id == id) return k;
    }
    return null;
  }
}

// ── Notifier ────────────────────────────────────────────────────

/// The workflow a link or an intent names, among [workflows]: by its [id] first,
/// by its [name] (in any case) where the id finds none. What runs is found by
/// this, and what the question before it names too ([askAutomationLink]).
Workflow? workflowOfLink(Iterable<Workflow> workflows, {String? id, String? name}) {
  if (id != null && id.isNotEmpty) {
    for (final w in workflows) {
      if (w.id == id) return w;
    }
  }
  if (name != null && name.isNotEmpty) {
    final lower = name.toLowerCase();
    for (final w in workflows) {
      if (w.name.toLowerCase() == lower) return w;
    }
  }
  return null;
}

class AutomationNotifier extends StateNotifier<AutomationState> {
  final Ref _ref;
  StreamSubscription<Map<String, dynamic>>? _automationSub;

  AutomationNotifier(this._ref) : super(const AutomationState()) {
    _init();
  }

  void _init() {
    // Sync enabled state from persisted settings, and keep it so: wherever
    // it is switched (it was read once, as this started, and a switch that
    // set the setting alone changed nothing here until the app started
    // again).
    final enabled = _ref.read(automationEnabledProvider);
    state = state.copyWith(enabled: enabled);
    _ref.listen<bool>(automationEnabledProvider, (_, on) => state = state.copyWith(enabled: on));

    // Listen for automation intents while the app is running
    _automationSub = DeepLinkService.automationStream.listen(handleAutomation);

    // Handle cold-start automation intent
    final initial = DeepLinkService.initialAutomation;
    if (initial != null) {
      AppLogger.info('Automation: processing cold-start intent');
      Future.microtask(() => handleAutomation(initial));
    }
  }

  @override
  void dispose() {
    _unlockWatch?.close();
    _automationSub?.cancel();
    super.dispose();
  }

  /// What the run in hand last told whoever asked for it ([_report]).
  ({String stdout, int exitCode})? _lastReported;

  /// [stdout] and [exitCode] to whoever asked for the run (Tasker reads
  /// them), and kept as what the run came to, for a scheduled task's Last.
  Future<void> _report({required String stdout, required int exitCode}) {
    _lastReported = (stdout: stdout, exitCode: exitCode);
    return DeepLinkService.setAutomationResult(stdout: stdout, exitCode: exitCode);
  }

  /// Refuses whatever is asked of automation while nothing could run it:
  /// without Squeezed, or with automation turned off on this device. Says
  /// why ([AutomationState.blocked], which the app shows), tells whoever
  /// asked, and answers true; false when automation could run something.
  /// Asked before anything else, the API key and the hosts too, and by an
  /// automation link before it asks its question (askAutomationLink): a
  /// question answered Run, for something that is then refused, asked for
  /// nothing (found 23 October 2026 in the whitepaper check).
  bool refuseIfNothingRuns() {
    // ── Pro gate ──────────────────────────────────────────────
    final isPro = _ref.read(isProProvider);
    if (!isPro) {
      AppLogger.info('Automation: blocked - Squeezed required for automation');
      _report(
        stdout: 'ERROR: ZestSSH Squeezed required for automation.',
        exitCode: 1,
      );
      state = state.copyWith(
        status: AutomationStatus.error,
        errorMessage: 'Squeezed required for automation',
        blocked: AutomationBlocked.needsSqueezed,
      );
      return true;
    }

    // ── Enabled check ────────────────────────────────────────
    if (!state.enabled) {
      AppLogger.info('Automation: blocked - disabled in settings');
      _report(
        stdout: 'ERROR: Automation is disabled in ZestSSH settings.',
        exitCode: 1,
      );
      state = state.copyWith(
        status: AutomationStatus.error,
        blocked: AutomationBlocked.off,
      );
      return true;
    }
    return false;
  }

  /// Handle an incoming automation intent payload from Android intents
  /// or `zestssh://execute` / `zestssh://snippet` / `zestssh://batch`
  /// deep links.
  ///
  /// A run of one of the app's own scheduled tasks (Android's scheduler
  /// hands its id over with the launch token that proves it,
  /// MainActivity.kt) is written to the task as its last run, with what it
  /// came to: the task's card said "Last:" for no task, as nothing wrote it
  /// (found 22 October 2026 in the 3.0 docs check).
  ///
  /// With the encrypting app lock on, nothing can run while the app is
  /// locked: the hosts, keys and tasks are in the closed database (reading it
  /// threw out of here, and whoever asked was told nothing). The tap on a
  /// scheduled task's notification (the person is there, and unlocks) runs
  /// once the app is unlocked; anything else is told that the app is locked.
  /// A scheduled task's run is refused when the task was deleted or turned
  /// off after its notification was posted.
  Future<void> handleAutomation(Map<String, dynamic> data) async {
    final scheduledTaskId = data['api_key_id'] == null ? null : data['scheduled_task_id'] as String?;
    final scheduled = scheduledTaskId != null && scheduledTaskId.isNotEmpty;
    if (!_ref.read(dbReadyProvider)) {
      if (scheduled) {
        _runOnceUnlocked(data);
      } else {
        _refuseWhileLocked();
      }
      return;
    }
    if (!scheduled) return _handleAutomation(data);
    final dao = await _scheduledTaskStillOn(scheduledTaskId);
    if (dao == null) return;
    _lastReported = null;
    await _handleAutomation(data);
    await recordScheduledRun(dao, scheduledTaskId, _lastReported, DateTime.now());
  }

  /// A scheduled task's run waiting for the app to be unlocked (the latest).
  Map<String, dynamic>? _waitingForUnlock;
  ProviderSubscription<bool>? _unlockWatch;

  void _runOnceUnlocked(Map<String, dynamic> data) {
    AppLogger.info('Automation: a scheduled task waits until the app is unlocked');
    _waitingForUnlock = data;
    _unlockWatch ??= _ref.listen<bool>(dbReadyProvider, (_, ready) {
      if (!ready) return;
      final waiting = _waitingForUnlock;
      _waitingForUnlock = null;
      _unlockWatch?.close();
      _unlockWatch = null;
      if (waiting != null) unawaited(handleAutomation(waiting));
    });
  }

  void _refuseWhileLocked() {
    AppLogger.info('Automation: refused, the app is locked');
    _report(stdout: 'ERROR: ZestSSH is locked. Unlock it, then run this again.', exitCode: 1);
    state = state.copyWith(status: AutomationStatus.error, errorMessage: 'ZestSSH is locked');
  }

  /// The dao holding scheduled task [id] while the task is there and on (in
  /// the Tree, or in the space open), or null, the run refused and said so.
  Future<ScheduledTasksDao?> _scheduledTaskStillOn(String id) async {
    final daos = {_ref.read(treeDatabaseProvider).scheduledTasksDao, _ref.read(scheduledTasksDaoProvider)};
    for (final dao in daos) {
      final task = await dao.getById(id);
      if (task == null) continue;
      if (task.enabled) return dao;
      break;
    }
    AppLogger.info('Automation: a scheduled task was deleted or turned off; its notification ran nothing');
    _report(stdout: 'ERROR: This scheduled task was deleted or turned off, so it was not run.', exitCode: 1);
    state = state.copyWith(status: AutomationStatus.error, blocked: AutomationBlocked.taskGone);
    return null;
  }

  Future<void> _handleAutomation(Map<String, dynamic> data) async {
    final action = data['action'] as String?;
    if (action == null) {
      AppLogger.warning('Automation: intent missing action');
      return;
    }
    if (refuseIfNothingRuns()) return;

    // ── API key validation + usage tracking (atomic) ──────
    //
    // Two modes: direct key (from deep links / external intents) or
    // key-by-ID (from scheduled WorkManager tasks, which only store the
    // ID to avoid persisting the raw secret to disk).
    final keysNotifier = _ref.read(automationKeysProvider.notifier);
    // Ensure the key store has finished loading from secure storage before we
    // validate. On a cold-start intent this can otherwise race an empty state,
    // failing the very first automation with "invalid key".
    await keysNotifier.ready;
    final requestKey = data['key'] as String? ?? '';
    final hasKey = requestKey.isNotEmpty;

    // An api_key_id with no key is a run of the app's own scheduler
    // (WorkManager). The app keeps only each key's hash, so the id is checked
    // by itself (there, not expired, marked used). The id is NOT what
    // authenticates it: MainActivity.kt passes api_key_id on only after the
    // run's single-use launch token (ScheduledLaunchTokens) was consumed, and
    // that token is the proof. A link or another app presents the key itself.
    final apiKeyId = data['api_key_id'] as String? ?? '';
    final byId = !hasKey && apiKeyId.isNotEmpty;

    final AutomationApiKey? matchedKey;
    if (byId && keysNotifier.validateIdAndMarkUsed(apiKeyId)) {
      matchedKey = keysNotifier.keyForId(apiKeyId);
    } else if (hasKey && keysNotifier.validateAndMarkUsed(requestKey)) {
      matchedKey = keysNotifier.keyForValue(requestKey);
    } else {
      matchedKey = null;
    }

    if (matchedKey == null) {
      AppLogger.warning('Automation: blocked - invalid or missing API key');
      _report(
        stdout: 'ERROR: Invalid or missing automation API key.',
        exitCode: 1,
      );
      state = state.copyWith(
        status: AutomationStatus.error,
        errorMessage: 'Invalid or missing automation API key',
        blocked: AutomationBlocked.keyNotKnown,
      );
      return;
    }

    // ── Connection-scope enforcement (SECURITY) ───────────────────────
    //
    // A key created with a non-null scopeConnectionId is single-connection: it
    // may only ever act on THAT connection. This is a hard authorization gate,
    // not a UI hint - a scoped key handed to Tasker/Shortcuts must not be able
    // to pivot to another host. Keys created before scoping existed decode with
    // scopeConnectionId == null and skip this block entirely, so their
    // behaviour is UNCHANGED.
    final scope = matchedKey.scopeConnectionId;
    if (scope != null) {
      // A single-connection key can never fan out: a workflow (multi-step,
      // potentially multi-host) is refused outright.
      if (action == 'workflow') {
        _denyScope('This API key is restricted to a single connection and '
            'cannot run workflows.');
        return;
      }

      // Every connection this request targets must resolve to the scoped id.
      final List<String> targets;
      if (action == 'batch') {
        targets = _hostsOf(data);
      } else {
        final single = data['connection_id'] as String? ??
            data['connection_label'] as String? ??
            '';
        targets = single.isEmpty ? const [] : [single];
      }
      if (targets.isEmpty) {
        _denyScope('This API key is restricted to a single connection but the '
            'request targeted none.');
        return;
      }
      final service = _ref.read(automationServiceProvider);
      for (final t in targets) {
        // resolveConnectionId returns null for an unknown identifier, which
        // correctly fails the `!= scope` test (fail-closed).
        final resolved = await service.resolveConnectionId(t);
        if (resolved != scope) {
          _denyScope('This API key is restricted to a single connection and '
              'cannot act on a different host.');
          return;
        }
      }
    }

    // ── Batch action (multiple connections, no single connection_id) ──
    if (action == 'batch') {
      final connectionIds = _hostsOf(data);
      final command = data['command'] as String?;
      // Clamp the caller-supplied timeout into a sane range so a hostile
      // (or buggy) Tasker action can't pin us into an indefinite poll.
      final timeoutSec = (data['timeout'] as int? ?? 30).clamp(1, 300);
      final parallel = data['parallel'] as bool? ?? true;
      await _handleBatch(connectionIds, command, timeoutSec, parallel, data);
      return;
    }

    // ── Workflow action (no connection needed) ───────────────
    if (action == 'workflow') {
      await _handleWorkflow(data);
      return;
    }

    // ── Resolve connection ───────────────────────────────────
    final connectionId = data['connection_id'] as String? ??
        data['connection_label'] as String? ??
        '';

    if (connectionId.isEmpty) {
      AppLogger.warning('Automation: no connection specified');
      _report(
        stdout: 'ERROR: No connection ID or label specified.',
        exitCode: 1,
      );
      return;
    }

    final service = _ref.read(automationServiceProvider);

    switch (action) {
      case 'connect':
        await _handleConnect(service, connectionId);

      case 'open':
        // Persistent open - opens a real session that survives the
        // automation call so port-forward rules marked auto-start
        // come up alongside it. Honours the optional `timeout` extra
        // (in seconds) used as the wait budget for "connected".
        // Clamp into [1, 300] so a hostile/buggy caller can't pin us
        // into an indefinite poll.
        final timeoutSec = (data['timeout'] as int? ?? 30).clamp(1, 300);
        await _handleOpen(service, connectionId, timeoutSec);

      case 'execute':
        final command = data['command'] as String?;
        final timeoutSec = (data['timeout'] as int? ?? 30).clamp(1, 300);
        await _handleExecute(
            service, connectionId, command, timeoutSec, data);

      case 'snippet':
        final snippetName = data['snippet_name'] as String?;
        // Extract var_ prefixed extras as snippet variables.
        // e.g. intent extra "var_branch" → variable "branch".
        final variables = <String, String>{};
        for (final entry in data.entries) {
          final key = entry.key;
          if (key.startsWith('var_') &&
              key.length > 4 &&
              entry.value is String) {
            variables[key.substring(4)] = entry.value as String;
          }
        }
        await _handleSnippet(
          service,
          connectionId,
          snippetName,
          variables.isNotEmpty ? variables : null,
        );

      default:
        AppLogger.warning('Automation: unknown action "$action"');
        _report(
          stdout: 'ERROR: Unknown automation action "$action".',
          exitCode: 1,
        );
    }
  }

  /// Refuse a request that a connection-scoped API key is not allowed to make,
  /// reporting [message] back to the caller (deep-link result) and the UI.
  /// A batch's hosts, as a link gives them (a list of text) or as Android
  /// hands them over from an intent: a list of objects, which a cast to a
  /// list of text threw on, so that a batch from Tasker never ran (found 16
  /// October 2026 in the client's security review).
  static List<String> _hostsOf(Map<String, dynamic> data) => [
        for (final host in data['connection_ids'] as List? ?? const [])
          if (host != null) '$host',
      ];

  void _denyScope(String message) {
    AppLogger.warning('Automation: BLOCKED by key scope - $message');
    _report(
      stdout: 'ERROR: $message',
      exitCode: 1,
    );
    state = state.copyWith(
      status: AutomationStatus.error,
      errorMessage: 'API key is restricted to a single connection',
      blocked: AutomationBlocked.otherHost,
    );
  }

  Future<void> _handleConnect(
      AutomationService service, String connectionId) async {
    AppLogger.info('Automation: CONNECT for $connectionId');
    state = state.copyWith(status: AutomationStatus.running);

    final result = await service.executeCommand(
      connectionId: connectionId,
      command: 'echo "ZestSSH: connected successfully"',
      timeout: const Duration(seconds: 15),
      unattended: true,
    );

    state = state.copyWith(
      status: result.success
          ? AutomationStatus.completed
          : AutomationStatus.error,
      lastResult: result,
      errorMessage: result.success ? null : result.error,
    );

    _logResult(
      action: 'connect',
      connectionId: connectionId,
      command: 'echo "ZestSSH: connected successfully"',
      result: result,
    );

    _report(
      stdout: result.success
          ? 'Connected to $connectionId successfully'
          : 'Connection failed: ${result.error}',
      exitCode: result.success ? 0 : 1,
    );
  }

  /// Open a persistent SSH session for the given connection (typically
  /// invoked from a Tasker action so port-forward rules marked auto-start
  /// come up automatically and stay up while the app is running).
  ///
  /// Differs from [_handleConnect] in that the session is not torn down
  /// when this method returns: it lives on as a regular tab, the
  /// foreground service notification holds the OS at bay, and the
  /// existing `_autoStartPortForwards` path takes care of the tunnels.
  ///
  /// We wait up to [timeoutSec] seconds for the session to reach the
  /// `connected` state before reporting back to Tasker, so the user's
  /// downstream Tasker actions can rely on the tunnels being up.
  Future<void> _handleOpen(
    AutomationService service,
    String connectionId,
    int timeoutSec,
  ) async {
    AppLogger.info('Automation: OPEN for $connectionId');
    state = state.copyWith(status: AutomationStatus.running);

    // Resolve the label/id to a real connection row.
    final resolvedId = await service.resolveConnectionId(connectionId);
    if (resolvedId == null) {
      const msg = 'Connection not found';
      state = state.copyWith(
        status: AutomationStatus.error,
        errorMessage: '$msg: $connectionId',
      );
      _report(
        stdout: 'ERROR: $msg "$connectionId".',
        exitCode: 1,
      );
      return;
    }

    // Your Tree's, as the service found it, whatever space is on screen.
    final tree = _ref.read(treeDatabaseProvider);
    final connection = await tree.connectionsDao.getById(resolvedId);
    if (connection == null) {
      const msg = 'Connection record disappeared after resolve';
      state = state.copyWith(
        status: AutomationStatus.error,
        errorMessage: '$msg: $resolvedId',
      );
      _report(
        stdout: 'ERROR: $msg.',
        exitCode: 1,
      );
      return;
    }

    // A Telnet host: what is typed there, a password among it, crosses the
    // network as it is, and every other way of opening one asks first
    // (confirmUnencryptedConnection). Here nobody is there to be asked, so it
    // is not opened. (It opened with no question: found in a
    // security audit.) A Telnet host has no port forwards,
    // which are what an unattended open is for.
    if (connection.protocol == 'telnet') {
      AppLogger.warning('Automation: BLOCKED unattended OPEN of "$connectionId" - a Telnet host');
      state = state.copyWith(
        status: AutomationStatus.error,
        errorMessage: 'A Telnet host is not opened with nobody there',
        blocked: AutomationBlocked.plaintextHost,
      );
      _report(
        stdout: 'ERROR: "${connection.label}" is a Telnet host. Nothing encrypts a Telnet session and '
            'nobody was there to be asked first, so it was not opened. Open it yourself in ZestSSH.',
        exitCode: 1,
      );
      return;
    }

    // A remote screen (VNC, RDP; 4.0): a picture for someone to look at. With
    // nobody there it has no use, and its questions (whether to trust a
    // certificate, a password to type) have nobody to answer them. It has no
    // port forwards either, which are what an unattended open is for. (It
    // opened and waited: found while planning 4.0.)
    if (ConnectionProtocol.storedIsScreen(connection.protocol)) {
      AppLogger.warning('Automation: BLOCKED unattended OPEN of "$connectionId" - a remote screen');
      state = state.copyWith(
        status: AutomationStatus.error,
        errorMessage: 'A remote screen is not opened with nobody there',
        blocked: AutomationBlocked.screenHost,
      );
      _report(
        stdout: 'ERROR: "${connection.label}" is a remote screen. A screen is for someone to look at and '
            'nobody was there, so it was not opened. Open it yourself in ZestSSH.',
        exitCode: 1,
      );
      return;
    }

    // ── Unattended gate ────────────────────────────────────────────
    // `open` is a HEADLESS entry point (deep link / external intent / API key)
    // that uses the interactive session machinery. Its host's own key is
    // checked here first, for a clear refusal; the session is then opened
    // unattended (3.0), so that what it signs in with besides (the key this
    // host takes on this network, every jump host's) is checked too, and
    // nothing is asked of a person who is not there. Otherwise a credential
    // the user walled off could still bring up a full persistent session AND
    // its auto-start port forwards with no one present. Mirrors the refusal
    // executeCommand returns for the other headless actions.
    if (connection.identityId != null) {
      final identity = await tree.identitiesDao.getById(connection.identityId!);
      if (identity != null &&
          AutomationService.unattendedBlocked(
              unattended: true, allowUnattended: identity.allowUnattended)) {
        AppLogger.warning(
            'Automation: BLOCKED unattended OPEN of "$connectionId" - identity '
            '${identity.id} is not opted in to unattended runs');
        state = state.copyWith(
          status: AutomationStatus.error,
          errorMessage: 'Unattended runs are not enabled for this credential',
          blocked: AutomationBlocked.keyNotUnattended,
        );
        _report(
          stdout: 'ERROR: Unattended runs are not enabled for the credential '
              '"${identity.label}". Enable it in Keys → the credential → '
              'Allow unattended runs.',
          exitCode: 1,
        );
        return;
      }
    }

    // Hand the connection off to the persistent session machinery. This
    // call returns immediately (the connect happens in the background)
    // and gives us back a sessionId we can poll, or null if the call
    // was rejected by the free-tier session-limit gate.
    final sessions = _ref.read(activeSessionsProvider.notifier);
    final sessionId = sessions.startSession(connection, unattended: true, space: const TreeSpace());
    if (sessionId == null) {
      const msg = 'Session limit reached';
      state = state.copyWith(
        status: AutomationStatus.error,
        errorMessage: msg,
      );
      _report(
        stdout: 'ERROR: $msg. Close an existing session or upgrade.',
        exitCode: 1,
      );
      return;
    }

    // Poll until the session reaches `connected`, errors out, or we hit
    // the timeout budget. Tunnels start as part of the connect flow, so
    // by the time we report success the auto-start forwards have been
    // queued up by `_autoStartPortForwards`.
    final deadline = DateTime.now().add(Duration(seconds: timeoutSec));
    SessionState? finalState;
    while (DateTime.now().isBefore(deadline)) {
      final cur = _ref.read(activeSessionsProvider)[sessionId];
      if (cur == null) break;
      if (cur.status == SessionStatus.connected ||
          cur.status == SessionStatus.error ||
          cur.status == SessionStatus.disconnected) {
        finalState = cur;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    finalState ??= _ref.read(activeSessionsProvider)[sessionId];

    final connected = finalState?.status == SessionStatus.connected;
    state = state.copyWith(
      status:
          connected ? AutomationStatus.completed : AutomationStatus.error,
      errorMessage: connected
          ? null
          : (finalState?.errorMessage ??
              'Session did not become ready within ${timeoutSec}s'),
    );

    _logResult(
      action: 'open',
      connectionId: resolvedId,
      command: '(open persistent session)',
      result: AutomationResult(
        success: connected,
        output: connected
            ? 'session=$sessionId'
            : (finalState?.errorMessage ?? ''),
        error: connected ? '' : (finalState?.errorMessage ?? ''),
        elapsed: Duration.zero,
      ),
    );

    _report(
      stdout: connected
          ? 'Opened session $sessionId for $connectionId - '
              'auto-start tunnels are coming up'
          : 'Open failed: '
              '${finalState?.errorMessage ?? "timed out after ${timeoutSec}s"}',
      exitCode: connected ? 0 : 1,
    );
  }

  Future<void> _handleExecute(AutomationService service,
      String connectionId, String? command, int timeoutSec,
      [Map<String, dynamic> data = const {}]) async {
    if (command == null || command.isEmpty) {
      _report(
        stdout: 'ERROR: No command specified.',
        exitCode: 1,
      );
      return;
    }

    // Not the command: it can hold a password, and what is logged goes into
    // Copy details (the scrub cannot know every way of writing one).
    AppLogger.info('Automation: EXECUTE (${command.length} chars) on $connectionId (${timeoutSec}s)');
    state = state.copyWith(status: AutomationStatus.running);

    final result = await service.executeCommand(
      connectionId: connectionId,
      command: command,
      timeout: Duration(seconds: timeoutSec),
      unattended: true,
    );

    // Apply output filters if specified
    final grepPattern = data['grep'] as String?;
    final headCount = data['head'] as int?;
    final tailCount = data['tail'] as int?;
    final filteredOutput = AutomationService.applyOutputFilters(
      result.output,
      grepPattern: grepPattern,
      head: headCount,
      tail: tailCount,
    );

    state = state.copyWith(
      status: result.success
          ? AutomationStatus.completed
          : AutomationStatus.error,
      lastResult: result,
      errorMessage: result.success ? null : result.error,
    );

    _report(
      stdout: filteredOutput.isNotEmpty ? filteredOutput : result.error,
      exitCode: result.exitCode ?? (result.success ? 0 : 1),
    );

    _logResult(
      action: 'execute',
      connectionId: connectionId,
      command: command,
      result: result,
    );

    // Send webhook callback if specified
    final callbackUrl = data['callback'] as String?;
    if (callbackUrl != null && callbackUrl.isNotEmpty) {
      AutomationService.sendWebhook(
        webhookUrl: callbackUrl,
        connection: connectionId,
        command: command,
        result: result,
      );
    }
  }

  Future<void> _handleSnippet(
    AutomationService service,
    String connectionId,
    String? snippetName, [
    Map<String, String>? variables,
  ]) async {
    if (snippetName == null || snippetName.isEmpty) {
      _report(
        stdout: 'ERROR: No snippet name specified.',
        exitCode: 1,
      );
      return;
    }

    AppLogger.info('Automation: SNIPPET "$snippetName" on $connectionId'
        '${variables != null ? " with ${variables.length} var(s)" : ""}');
    state = state.copyWith(status: AutomationStatus.running);

    final result = await service.runSnippet(
      connectionId: connectionId,
      snippetName: snippetName,
      variables: variables,
      unattended: true,
    );

    state = state.copyWith(
      status: result.success
          ? AutomationStatus.completed
          : AutomationStatus.error,
      lastResult: result,
      errorMessage: result.success ? null : result.error,
    );

    _logResult(
      action: 'snippet',
      connectionId: connectionId,
      command: snippetName,
      snippetName: snippetName,
      result: result,
    );

    _report(
      stdout: result.output.isNotEmpty ? result.output : result.error,
      exitCode: result.exitCode ?? (result.success ? 0 : 1),
    );
  }

  Future<void> _handleBatch(List<String> connectionIds, String? command,
      int timeoutSec, bool parallel,
      [Map<String, dynamic> data = const {}]) async {
    if (connectionIds.isEmpty) {
      _report(
        stdout: 'ERROR: No connections specified for batch execution.',
        exitCode: 1,
      );
      return;
    }

    if (command == null || command.isEmpty) {
      _report(
        stdout: 'ERROR: No command specified.',
        exitCode: 1,
      );
      return;
    }

    AppLogger.info('Automation: BATCH (${command.length} chars) on '
        '${connectionIds.length} connections (parallel=$parallel, '
        '${timeoutSec}s)');
    state = state.copyWith(status: AutomationStatus.running);

    final service = _ref.read(automationServiceProvider);
    final results = await service.executeBatch(
      connectionIds: connectionIds,
      command: command,
      timeout: Duration(seconds: timeoutSec),
      parallel: parallel,
      unattended: true,
    );

    // Extract output filter params
    final grepPattern = data['grep'] as String?;
    final headCount = data['head'] as int?;
    final tailCount = data['tail'] as int?;

    // Build a combined stdout summary
    final buffer = StringBuffer();
    var allSucceeded = true;
    for (final entry in results.entries) {
      final r = entry.value;
      buffer.writeln('=== ${entry.key} (exit=${r.exitCode ?? "?"}) ===');
      final filteredOutput = AutomationService.applyOutputFilters(
        r.output,
        grepPattern: grepPattern,
        head: headCount,
        tail: tailCount,
      );
      if (filteredOutput.isNotEmpty) buffer.writeln(filteredOutput.trimRight());
      if (r.error.isNotEmpty) buffer.writeln('STDERR: ${r.error.trimRight()}');
      if (!r.success) allSucceeded = false;
    }

    state = state.copyWith(
      status: allSucceeded
          ? AutomationStatus.completed
          : AutomationStatus.error,
      errorMessage: allSucceeded ? null : 'One or more batch commands failed',
    );

    // Log each connection result individually
    for (final entry in results.entries) {
      _logResult(
        action: 'batch',
        connectionId: entry.key,
        command: command,
        result: entry.value,
      );
    }

    _report(
      stdout: buffer.toString(),
      exitCode: allSucceeded ? 0 : 1,
    );

    // Send webhook callback if specified
    final callbackUrl = data['callback'] as String?;
    if (callbackUrl != null && callbackUrl.isNotEmpty) {
      // For batch, send a single webhook with the combined output
      AutomationService.sendWebhook(
        webhookUrl: callbackUrl,
        connection: connectionIds.join(','),
        command: command,
        result: AutomationResult(
          success: allSucceeded,
          output: buffer.toString(),
          error: allSucceeded ? '' : 'One or more batch commands failed',
          exitCode: allSucceeded ? 0 : 1,
          elapsed: results.values.fold(
            Duration.zero,
            (sum, r) => sum + r.elapsed,
          ),
        ),
      );
    }
  }

  Future<void> _handleWorkflow(Map<String, dynamic> data) async {
    final workflowName = data['workflow_name'] as String?;
    final workflowId = data['workflow_id'] as String?;

    if ((workflowName == null || workflowName.isEmpty) &&
        (workflowId == null || workflowId.isEmpty)) {
      _report(
        stdout: 'ERROR: No workflow name or ID specified.',
        exitCode: 1,
      );
      return;
    }

    AppLogger.info('Automation: WORKFLOW '
        '${workflowName != null ? '"$workflowName"' : 'id=$workflowId'}');
    state = state.copyWith(status: AutomationStatus.running);

    // Look up workflow by name (case-insensitive) or ID, among your Tree's,
    // whichever space is on screen: this runs on the Tree's hosts.
    final List<Workflow> workflows;
    try {
      workflows = await _ref.read(workflowsProvider.notifier).ofTheTree();
    } catch (e) {
      AppLogger.error('Automation: could not read the workflows', e);
      _report(stdout: 'ERROR: ${e.toString()}', exitCode: 1);
      state = state.copyWith(status: AutomationStatus.error, errorMessage: e.toString());
      return;
    }
    final workflow = workflowOfLink(workflows, id: workflowId, name: workflowName);

    if (workflow == null) {
      final identifier = workflowName ?? workflowId ?? '';
      AppLogger.warning('Automation: workflow not found: $identifier');
      _report(
        stdout: 'ERROR: Workflow not found: $identifier',
        exitCode: 1,
      );
      state = state.copyWith(
        status: AutomationStatus.error,
        errorMessage: 'Workflow not found: $identifier',
      );
      return;
    }

    // Turned off (its switch in the workflow list): it still runs when it is
    // run in the app, and nothing else starts it, not a link, another app or
    // a schedule. Said in Automation history, where such a run is looked for
    // (the switch was saved and never read: found 22 October 2026 in the 3.0
    // docs check).
    if (!workflow.enabled) {
      AppLogger.info('Automation: workflow "${workflow.name}" is turned off, not run');
      _logResult(
        action: 'workflow',
        connectionId: workflow.name,
        command: '${workflow.steps.length} steps',
        result: AutomationResult(
          success: false,
          output: '',
          error: gl10n.automationWorkflowOffNotRun,
          exitCode: 1,
          elapsed: Duration.zero,
        ),
      );
      _report(
        stdout: 'ERROR: Workflow "${workflow.name}" is turned off in ZestSSH.',
        exitCode: 1,
      );
      state = state.copyWith(
        status: AutomationStatus.error,
        errorMessage: 'Workflow is turned off',
      );
      return;
    }

    try {
      final result = await _ref
          .read(workflowsProvider.notifier)
          .runWorkflow(workflow.id, unattended: true);

      state = state.copyWith(
        status: result.success
            ? AutomationStatus.completed
            : AutomationStatus.error,
        errorMessage: result.success ? null : result.errorMessage,
      );

      // A run blocked purely by the unattended gate must read as exactly that,
      // not an opaque "unknown error" - the workflow path only logs the
      // aggregate, so surface needsCredentials in both the history row and the
      // deep-link summary.
      final failReason = result.needsCredentials
          ? 'Blocked: a step targets a credential not enabled for unattended '
              'runs (enable it in Keys → Allow unattended runs)'
          : (result.errorMessage ?? 'unknown error');

      // Log to automation history
      _logResult(
        action: 'workflow',
        connectionId: workflow.name,
        command: '${workflow.steps.length} steps',
        result: AutomationResult(
          success: result.success,
          output: result.toString(),
          error: result.success ? '' : failReason,
          exitCode: result.success ? 0 : 1,
          elapsed: result.totalElapsed,
          needsCredentials: result.needsCredentials,
        ),
      );

      final summary = result.success
          ? 'Workflow "${workflow.name}" completed: '
              '${result.stepsOkLine} '
              '(${result.totalElapsed.inMilliseconds}ms)'
          : 'Workflow "${workflow.name}" failed: $failReason '
              '(${result.stepsOkLine})';

      _report(
        stdout: summary,
        exitCode: result.success ? 0 : 1,
      );
    } catch (e) {
      AppLogger.error('Automation: workflow execution error', e);
      _report(
        stdout: 'ERROR: ${e.toString()}',
        exitCode: 1,
      );
      state = state.copyWith(
        status: AutomationStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  // ── Public API for programmatic use ───────────────────────

  /// Execute a command programmatically (from deep links or UI).
  Future<AutomationResult> executeCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final isPro = _ref.read(isProProvider);
    if (!isPro) {
      return const AutomationResult(
        success: false,
        output: '',
        error: 'Squeezed required for automation',
        elapsed: Duration.zero,
      );
    }

    state = state.copyWith(status: AutomationStatus.running);
    final service = _ref.read(automationServiceProvider);
    final result = await service.executeCommand(
      connectionId: connectionId,
      command: command,
      timeout: timeout,
    );

    state = state.copyWith(
      status: result.success
          ? AutomationStatus.completed
          : AutomationStatus.error,
      lastResult: result,
      errorMessage: result.success ? null : result.error,
    );

    return result;
  }

  /// Execute a snippet programmatically.
  Future<AutomationResult> runSnippet({
    required String connectionId,
    required String snippetName,
    Map<String, String>? variables,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final isPro = _ref.read(isProProvider);
    if (!isPro) {
      return const AutomationResult(
        success: false,
        output: '',
        error: 'Squeezed required for automation',
        elapsed: Duration.zero,
      );
    }

    state = state.copyWith(status: AutomationStatus.running);
    final service = _ref.read(automationServiceProvider);
    final result = await service.runSnippet(
      connectionId: connectionId,
      snippetName: snippetName,
      variables: variables,
      timeout: timeout,
    );

    state = state.copyWith(
      status: result.success
          ? AutomationStatus.completed
          : AutomationStatus.error,
      lastResult: result,
      errorMessage: result.success ? null : result.error,
    );

    return result;
  }

  /// Execute the same command across multiple connections programmatically.
  Future<Map<String, AutomationResult>> handleBatchExecution({
    required List<String> connectionIds,
    required String command,
    Duration timeout = const Duration(seconds: 30),
    bool parallel = true,
  }) async {
    final isPro = _ref.read(isProProvider);
    if (!isPro) {
      return {
        for (final id in connectionIds)
          id: const AutomationResult(
            success: false,
            output: '',
            error: 'Squeezed required for automation',
            elapsed: Duration.zero,
          ),
      };
    }

    state = state.copyWith(status: AutomationStatus.running);
    final service = _ref.read(automationServiceProvider);
    final results = await service.executeBatch(
      connectionIds: connectionIds,
      command: command,
      timeout: timeout,
      parallel: parallel,
    );

    final allSucceeded = results.values.every((r) => r.success);
    state = state.copyWith(
      status: allSucceeded
          ? AutomationStatus.completed
          : AutomationStatus.error,
      errorMessage: allSucceeded ? null : 'One or more batch commands failed',
    );

    return results;
  }

  /// Toggle automation on/off.
  void setEnabled(bool enabled) {
    state = state.copyWith(enabled: enabled);
  }

  /// Clear the blocked message after the UI has shown it.
  void clearBlocked() {
    state = state.clearBlocked();
  }

  /// Record an automation result in the log.
  void _logResult({
    required String action,
    required String connectionId,
    required String command,
    String? snippetName,
    required AutomationResult result,
  }) {
    final dao = _ref.read(automationHistoryDaoProvider);
    dao.insert(AutomationHistoryCompanion(
      id: Value(const Uuid().v4()),
      timestamp: Value(DateTime.now()),
      action: Value(action),
      connectionId: Value(connectionId),
      command: Value(command),
      snippetName: Value(snippetName),
      stdout: Value(result.output),
      stderr: Value(result.error),
      exitCode: Value(result.exitCode),
      success: Value(result.success),
      elapsedMs: Value(result.elapsed.inMilliseconds),
    ));

    // Keep max 500 entries
    dao.trim(500);
  }

  /// Clear the automation log.
  void clearLog() {
    _ref.read(automationHistoryDaoProvider).deleteAll();
  }
}

/// Writes the last run of the scheduled task [taskId]: when ([at]), and
/// whether it ran ('success') or not ('failed'), by the exit code of what the
/// run [reported] to whoever asked for it (none: it ended before saying
/// anything, which is a failure). What it printed is not kept here: it is in
/// Automation history.
Future<void> recordScheduledRun(
  ScheduledTasksDao dao,
  String taskId,
  ({String stdout, int exitCode})? reported,
  DateTime at,
) async {
  try {
    await dao.updateLastRun(taskId, at, reported?.exitCode == 0 ? 'success' : 'failed');
  } catch (e) {
    AppLogger.warning('Automation: could not write the last run of a scheduled task: $e');
  }
}
