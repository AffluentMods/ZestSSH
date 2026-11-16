import 'dart:async';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/server_stats_service.dart';
import 'package:zestssh/services/ssh_connection_factory.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/logger.dart';

/// Per-host state the UI reads from [agentlessMonitorPollerProvider]. The
/// engine deliberately exposes a STRUCTURED state (not a user-facing string):
/// the UI maps each value to a localized label. [MonitorHostStatus.detail]
/// carries only raw, dynamic diagnostic text (e.g. a brief error), never a
/// static UI sentence.
enum MonitorHostState {
  /// Exec client is live; a poll is pending (just connected, or between polls,
  /// or the host is covered by an open terminal session).
  monitoring,

  /// Opening the headless exec client right now.
  connecting,

  /// The last poll succeeded - fresh stats are in [serverStatsProvider].
  ok,

  /// Saved credentials can't authenticate without a prompt (no identity, no
  /// saved password, encrypted key with no saved passphrase, hardware token).
  needsCredentials,

  /// A new or changed host key was presented - open a terminal to review it
  /// ([MonitorHostStatus.hostKeyChanged] says which).
  needsHostKeyReview,

  /// The connect or poll failed (network, auth rejected, 2FA, timeout). A
  /// reconnect is scheduled with backoff, but not where the host refused the
  /// sign-in, or the connection ended over something else that no timer
  /// changes ([MonitorHostStatus.notTriedAgain]): that host is tried again
  /// when its credentials change or its person asks.
  error,

  /// Not monitorable: not an SSH host, beyond the free-tier monitor cap, or
  /// skipped on the current network.
  notEligible,
}

/// A monitored host's current [state], with what a check failed with where
/// it did, and an optional raw [detail] string.
class MonitorHostStatus {
  final MonitorHostState state;

  /// Short, NON-localized marker (`monitor-limit`, `live-session`). Null for
  /// the plain states.
  final String? detail;

  /// What the last check failed with ([MonitorHostState.error]): the error
  /// itself, a jump host's failure as that. Whoever shows the host puts it
  /// into words and files it by what it is ([failedCheckReason],
  /// [failedCheckSaid]); it was a line of text that nothing showed, searched
  /// for words that look like a sign-in. On [MonitorHostState.connecting],
  /// what the try before this one failed with, where this one tries again
  /// after it: what is shown of the host says why, and that it is tried.
  final Object? failedWith;

  /// Whether [failedWith] is a sign-in that was refused: the host is not
  /// tried again by a timer then.
  final bool signInRefused;

  /// Whether the host is not dialled again by a timer after [failedWith]: a
  /// sign-in it refused, or a connection that ended over something else no
  /// timer changes. Whoever shows the host says so: nothing more comes of
  /// it until its person asks, or what stood in the way has changed.
  final bool notTriedAgain;

  /// Whether the key that is to be looked at
  /// ([MonitorHostState.needsHostKeyReview]) is another than the one this
  /// device trusts for the host: false where it has seen none before.
  final bool hostKeyChanged;

  final DateTime updatedAt;

  const MonitorHostStatus(
    this.state, {
    this.detail,
    this.failedWith,
    this.signInRefused = false,
    this.notTriedAgain = false,
    this.hostKeyChanged = false,
    required this.updatedAt,
  });
}

// ── Master enable (persisted, default OFF) ──────────────────────────

/// Whether the agentless Server Monitor poller is enabled at all. Persisted in
/// SharedPreferences; OFF by default so no background SSH ever happens until
/// the user opts in.
final agentlessMonitorEnabledProvider =
    StateNotifierProvider<AgentlessMonitorEnabledNotifier, bool>((ref) {
  return AgentlessMonitorEnabledNotifier(ref);
});

class AgentlessMonitorEnabledNotifier extends StateNotifier<bool> {
  AgentlessMonitorEnabledNotifier(this._ref) : super(false) {
    state = _ref.read(sharedPreferencesProvider).getBool(_prefsKey) ?? false;
  }

  final Ref _ref;
  static const _prefsKey = 'agentless_monitor_enabled';

  /// Turn the whole background poller on/off. Persisted immediately.
  Future<void> setEnabled(bool value) async {
    if (state == value) return;
    state = value;
    await _ref.read(sharedPreferencesProvider).setBool(_prefsKey, value);
  }

  Future<void> toggle() => setEnabled(!state);
}

// ── Monitored connection set + free-tier gate ───────────────────────

/// The hosts the user opted in to agentless monitoring, in the stable order
/// ([watchMonitored]) the free-tier "first N" cap is applied against.
final monitoredConnectionsProvider = StreamProvider<List<Connection>>((ref) {
  return ref.watch(connectionsDaoProvider).watchMonitored();
});

/// The host keys this device trusts, for whoever has to know that they
/// changed (Server Monitor takes up again a host whose key it could not
/// accept).
final trustedHostKeysProvider = StreamProvider<List<KnownHost>>((ref) {
  return ref.watch(knownHostsDaoProvider).watchAll();
});

/// How many hosts are currently opted in to monitoring.
final monitoredCountProvider = Provider<int>((ref) {
  return ref.watch(monitoredConnectionsProvider).valueOrNull?.length ?? 0;
});

/// Whether the user can opt ANOTHER host in to monitoring right now - the gate
/// the UI checks before flipping a host's `monitored` flag. Pro/Squeezed users
/// are unlimited; free users are capped at [freeMonitorLimit].
final canAddMonitoredHostProvider = Provider<bool>((ref) {
  if (ref.watch(isProProvider)) return true;
  return ref.watch(monitoredCountProvider) < freeMonitorLimit;
});

// ── The poller ──────────────────────────────────────────────────────

/// Background poller that periodically SSH-connects (headless, no PTY) to the
/// opt-in monitored hosts using their saved credentials, runs the existing
/// stat commands, and feeds results into the shared [serverStatsProvider] map.
///
/// Its [state] is the per-host [MonitorHostStatus] map the UI reads. Actual
/// metric values are read from [serverStatsProvider] / [connectionStatsProvider]
/// exactly as for live-session monitoring.
final agentlessMonitorPollerProvider = StateNotifierProvider<
    AgentlessMonitorPoller, Map<String, MonitorHostStatus>>((ref) {
  return AgentlessMonitorPoller(ref);
});

/// Per-host status for [connectionId], or null if it isn't a monitored host.
final monitorHostStatusProvider =
    Provider.family<MonitorHostStatus?, String>((ref, connectionId) {
  return ref.watch(agentlessMonitorPollerProvider)[connectionId];
});

/// Why Server Monitor does not dial a host again by itself: a key of the
/// host's that this device does not trust, or a sign-in that the host
/// refused or that could not be gone through with (what else no timer
/// changes: [MonitorExecOutcome.endsTheSame]).
enum _HeldFor { hostKey, signIn }

/// A host Server Monitor got as far as and could not sign in to, for a
/// reason no timer changes, as it stood then.
class _Held {
  _Held(this.why, Connection c, this.identity, this.status)
      : host = c.host,
        port = c.port,
        identityId = c.identityId,
        connectViaId = c.connectViaId,
        compatibilityMode = c.compatibilityMode;

  final _HeldFor why;
  final String host;
  final int port;
  final String? identityId;
  final String? connectViaId;

  /// Whether it was offered what an old server needs as well: a host that
  /// the app had nothing in common with may have something with the other.
  final bool compatibilityMode;

  /// The key or password it signs in with, as it was saved then.
  final Identity? identity;

  /// What is shown of it while it is held.
  final MonitorHostStatus status;

  /// Whether [c] is still saved as it was: reached at the same place, the
  /// same way, with the same key or password, and offered the same.
  bool same(Connection c) =>
      c.host == host &&
      c.port == port &&
      c.identityId == identityId &&
      c.connectViaId == connectViaId &&
      c.compatibilityMode == compatibilityMode;
}

class AgentlessMonitorPoller
    extends StateNotifier<Map<String, MonitorHostStatus>> {
  AgentlessMonitorPoller(this._ref) : super(const {}) {
    _wire();
  }

  final Ref _ref;

  /// Max hosts to dial concurrently when (re)building the pool.
  static const _maxConcurrentConnects = 4;

  /// One authenticated exec service per pooled host.
  final _pool = <String, SshService>{};

  /// Per-host backoff reconnect timers + attempt counters.
  final _reconnectTimers = <String, Timer>{};
  final _reconnectAttempts = <String, int>{};

  /// Hosts the monitor does not dial again by itself: the last connection
  /// got as far as the host and could not sign in, for a reason no timer
  /// changes (a key of the host's that this device does not trust, a
  /// sign-in the host refused, or a connection the SSH core ended over the
  /// host's key, its group for the key exchange, nothing in common with
  /// what it was offered, or a key of the app's own that could not sign).
  /// Dialled again it ends the same way, and
  /// each time is one more connection in the host's log that ended before
  /// sign-in, or one more refused sign-in: a host that bans addresses for
  /// those bans this one (such a host
  /// was dialled again at every change of any session and every time the
  /// window came to the front, and a refused sign-in every five minutes
  /// for ever).
  ///
  /// Taken up again when what stood in the way may have changed: the host
  /// as it is saved, the keys this device trusts, the key or password it
  /// signs in with, a session of its person's that connected to it, or its
  /// person asking ([retry]); and when Server Monitor is turned off and on.
  final _held = <String, _Held>{};

  /// Bounded connect queue.
  final _connectQueue = Queue<Connection>();
  final _connectingIds = <String>{};
  int _activeConnects = 0;

  Timer? _pollTimer;
  Timer? _reconcileDebounce;
  Timer? _graceTeardownTimer;

  bool _paused = false;
  bool _reconciling = false;
  bool _reconcilePending = false;

  void _wire() {
    // React to every input that changes the desired pool: the master toggle,
    // the monitored set, the Pro entitlement (free cap), live terminal
    // sessions (avoid double-collect), and the poll interval.
    _ref.listen<bool>(agentlessMonitorEnabledProvider, (_, _) {
      _scheduleReconcile();
    }, fireImmediately: true);
    _ref.listen<AsyncValue<List<Connection>>>(
        monitoredConnectionsProvider, (_, _) => _scheduleReconcile());
    _ref.listen<bool>(isProProvider, (_, _) => _scheduleReconcile());
    _ref.listen<Map<String, SessionState>>(
        activeSessionsProvider, (_, _) => _scheduleReconcile());
    _ref.listen<int>(
        monitorRefreshIntervalProvider, (_, _) => _restartPollTimerIfRunning());
    // What may let a held host sign in after all.
    _ref.listen<AsyncValue<List<KnownHost>>>(trustedHostKeysProvider, (_, _) {
      _release((id, held) => held.why == _HeldFor.hostKey);
    });
    _ref.listen<AsyncValue<List<Identity>>>(identitiesProvider, (_, next) {
      final saved = {for (final i in next.valueOrNull ?? const <Identity>[]) i.id: i};
      _release((id, held) => held.why == _HeldFor.signIn && saved[held.identityId] != held.identity);
    });
  }

  /// Holds [conn] ([_held]), shown as [status].
  void _hold(Connection conn, _HeldFor why, MonitorHostStatus status) {
    final identities = _ref.read(identitiesProvider).valueOrNull ?? const <Identity>[];
    _held[conn.id] = _Held(
      why,
      conn,
      identities.where((i) => i.id == conn.identityId).firstOrNull,
      status,
    );
  }

  /// Takes up again the held hosts that [which] names.
  void _release(bool Function(String id, _Held held) which) {
    final before = _held.length;
    _held.removeWhere(which);
    if (_held.length != before) _scheduleReconcile();
  }

  /// Its person asks for [id], or for every host where none is named, to
  /// be tried again now (a refresh they pressed): a held host is taken up,
  /// and one waiting for its next try does not wait.
  void retry([String? id]) {
    bool asked(String host) => id == null || host == id;
    _held.removeWhere((host, _) => asked(host));
    for (final host in _reconnectTimers.keys.where(asked).toList()) {
      _reconnectTimers.remove(host)?.cancel();
      _reconnectAttempts.remove(host);
    }
    _scheduleReconcile();
  }

  // ── Foreground pause / resume (wired from app.dart + WindowService) ──

  /// Stop polling immediately (app backgrounded / window minimized or blurred).
  /// The pool is kept for a short grace window so quick desktop focus churn
  /// doesn't cause a reconnect storm; sustained background then tears it down.
  void pause() {
    if (_paused) return;
    _paused = true;
    _stopPollTimer();
    _graceTeardownTimer?.cancel();
    _graceTeardownTimer = Timer(const Duration(seconds: 60), () {
      if (!mounted || !_paused) return;
      _teardownAll();
    });
    AppLogger.debug('Monitor: paused (foreground lost)');
  }

  /// Resume polling (app foregrounded / window restored or focused).
  void resume() {
    _graceTeardownTimer?.cancel();
    _graceTeardownTimer = null;
    if (!_paused && _pollTimer != null) return;
    _paused = false;
    AppLogger.debug('Monitor: resumed (foreground gained)');
    _scheduleReconcile();
  }

  // ── Reconcile ───────────────────────────────────────────────────────

  void _scheduleReconcile() {
    _reconcileDebounce?.cancel();
    _reconcileDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      unawaited(_reconcile());
    });
  }

  Future<void> _reconcile() async {
    if (!mounted) return;
    if (_reconciling) {
      _reconcilePending = true;
      return;
    }
    _reconciling = true;
    try {
      await _reconcileBody();
    } catch (e, st) {
      AppLogger.error('Monitor: reconcile failed', e, st);
    } finally {
      _reconciling = false;
      if (_reconcilePending && mounted) {
        _reconcilePending = false;
        unawaited(_reconcile());
      }
    }
  }

  Future<void> _reconcileBody() async {
    final enabled = _ref.read(agentlessMonitorEnabledProvider);
    if (!enabled) {
      await _teardownAll();
      // Turned off: turned on again, every host is tried anew.
      _held.clear();
      if (mounted) state = const {};
      return;
    }
    if (_paused) {
      // Keep the pool (grace window) but stop polling while backgrounded.
      _stopPollTimer();
      return;
    }

    final monitored = _ref.read(monitoredConnectionsProvider).valueOrNull ??
        const <Connection>[];
    final isPro = _ref.read(isProProvider);
    final liveSessionIds = _liveSessionConnectionIds();
    final factory = _ref.read(sshConnectionFactoryProvider);

    final newStatuses = <String, MonitorHostStatus>{};
    final desired = <String>{};
    // A host that is monitored no longer is held no longer.
    _held.removeWhere((id, _) => !monitored.any((c) => c.id == id));

    var sshSlot = 0;
    for (final c in monitored) {
      // Non-SSH monitored hosts can't be polled agentlessly.
      if (c.protocol != 'ssh') {
        newStatuses[c.id] = _status(MonitorHostState.notEligible);
        continue;
      }

      // Free-tier cap: only the first [freeMonitorLimit] SSH hosts are in
      // scope; the rest are "upgrade to monitor".
      if (!isPro && sshSlot >= freeMonitorLimit) {
        newStatuses[c.id] =
            _status(MonitorHostState.notEligible, detail: 'monitor-limit');
        continue;
      }
      sshSlot++;

      // Covered by an open terminal tab → the live-session collector already
      // refreshes it; don't pool it (avoids double-collect).
      if (liveSessionIds.contains(c.id)) {
        // (Its person signed in to it: whatever stood in the monitor's way
        // may be gone.)
        _held.remove(c.id);
        newStatuses[c.id] =
            _status(MonitorHostState.monitoring, detail: 'live-session');
        continue;
      }

      // Held: not dialled until what stood in the way may have changed.
      // (One saved differently since is dialled, and held anew if it ends
      // the same way.)
      final held = _held[c.id];
      if (held != null && held.same(c)) {
        newStatuses[c.id] = held.status;
        continue;
      }

      // Already pooled → known silent-capable; keep its live status.
      if (_pool.containsKey(c.id)) {
        desired.add(c.id);
        newStatuses[c.id] =
            state[c.id] ?? _status(MonitorHostState.monitoring);
        continue;
      }

      // New candidate: don't open a socket for a host that would need an
      // interactive prompt - mark it "needs credentials" instead.
      final silent = await factory.canPollSilently(c);
      if (!mounted) return;
      if (!silent) {
        newStatuses[c.id] = _status(MonitorHostState.needsCredentials);
        continue;
      }
      desired.add(c.id);
      // Preserve a mid-backoff error status, and the status of a try that
      // is under way or waits its turn; otherwise it is tried now, and what
      // the try before failed with stays said ([_tryingAgain]).
      newStatuses[c.id] = _reconnectTimers.containsKey(c.id) || _connectingIds.contains(c.id)
          ? (state[c.id] ?? _status(MonitorHostState.connecting))
          : _tryingAgain(state[c.id]);
    }

    // Drop pooled hosts + reconnect timers no longer desired.
    for (final id in _pool.keys.toList()) {
      if (!desired.contains(id)) await _disconnectHost(id);
    }
    for (final id in _reconnectTimers.keys.toList()) {
      if (!desired.contains(id)) {
        _reconnectTimers.remove(id)?.cancel();
        _reconnectAttempts.remove(id);
      }
    }

    if (mounted) state = newStatuses;

    // Connect desired hosts that aren't pooled or already scheduled.
    for (final c in monitored) {
      if (desired.contains(c.id) &&
          !_pool.containsKey(c.id) &&
          !_reconnectTimers.containsKey(c.id)) {
        _enqueueConnect(c);
      }
    }

    if (desired.isNotEmpty) {
      _startPollTimer();
    } else {
      _stopPollTimer();
    }
  }

  // ── Connect pool (bounded concurrency) ──────────────────────────────

  void _enqueueConnect(Connection conn) {
    if (_pool.containsKey(conn.id) || _connectingIds.contains(conn.id)) return;
    _connectingIds.add(conn.id);
    _connectQueue.add(conn);
    _pumpConnectQueue();
  }

  void _pumpConnectQueue() {
    while (_activeConnects < _maxConcurrentConnects &&
        _connectQueue.isNotEmpty) {
      final conn = _connectQueue.removeFirst();
      _activeConnects++;
      unawaited(_connectHost(conn).whenComplete(() {
        _activeConnects--;
        _connectingIds.remove(conn.id);
        if (mounted) _pumpConnectQueue();
      }));
    }
  }

  Future<void> _connectHost(Connection conn) async {
    if (!mounted || _paused || !_ref.read(agentlessMonitorEnabledProvider)) {
      return;
    }
    final tryingAgain = _tryingAgain(state[conn.id]);
    _setStatus(conn.id, MonitorHostState.connecting,
        failedWith: tryingAgain.failedWith, signInRefused: tryingAgain.signInRefused);

    MonitorExecResult result;
    try {
      result = await _ref
          .read(activeSessionsProvider.notifier)
          .openExecClient(conn);
    } catch (e) {
      result = MonitorExecResult.error(e);
    }

    // If we were torn down / disabled / this host is no longer desired while
    // connecting, drop any client we just opened.
    if (!mounted ||
        _paused ||
        !_ref.read(agentlessMonitorEnabledProvider) ||
        !_isStillDesired(conn.id)) {
      if (result.outcome == MonitorExecOutcome.ok) {
        try {
          await result.service!.disconnect();
        } catch (_) {/* best-effort */}
      }
      return;
    }

    switch (result.outcome) {
      case MonitorExecOutcome.ok:
        _pool[conn.id] = result.service!;
        _reconnectAttempts.remove(conn.id);
        _reconnectTimers.remove(conn.id)?.cancel();
        _setStatus(conn.id, MonitorHostState.monitoring);
        // Immediate first poll so stats appear without waiting a full cycle.
        await _pollHost(conn.id);
        _startPollTimer();
        break;
      case MonitorExecOutcome.needsCredentials:
        _setStatus(conn.id, MonitorHostState.needsCredentials);
        break;
      case MonitorExecOutcome.needsHostKeyReview:
        _setStatus(conn.id, MonitorHostState.needsHostKeyReview, hostKeyChanged: result.hostKeyChanged);
        _hold(conn, _HeldFor.hostKey, state[conn.id]!);
        break;
      case MonitorExecOutcome.signInRefused:
        _setStatus(conn.id, MonitorHostState.error,
            failedWith: result.failedWith, signInRefused: true, notTriedAgain: true);
        _hold(conn, _HeldFor.signIn, state[conn.id]!);
        break;
      case MonitorExecOutcome.endsTheSame:
        _setStatus(conn.id, MonitorHostState.error, failedWith: result.failedWith, notTriedAgain: true);
        _hold(conn, _HeldFor.signIn, state[conn.id]!);
        break;
      case MonitorExecOutcome.notEligible:
        _setStatus(conn.id, MonitorHostState.notEligible,
            detail: result.detail);
        break;
      case MonitorExecOutcome.error:
        _setStatus(conn.id, MonitorHostState.error, failedWith: result.failedWith);
        _scheduleReconnect(conn);
        break;
    }
  }

  void _scheduleReconnect(Connection conn) {
    if (!mounted || _paused) return;
    final attempts = (_reconnectAttempts[conn.id] ?? 0) + 1;
    _reconnectAttempts[conn.id] = attempts;
    // 5s, 10s, 20s, 40s, 80s, 160s, capped at 300s.
    final shift = (attempts - 1).clamp(0, 6);
    final delaySec = (5 * (1 << shift)).clamp(5, 300);
    _reconnectTimers[conn.id]?.cancel();
    _reconnectTimers[conn.id] = Timer(Duration(seconds: delaySec), () {
      _reconnectTimers.remove(conn.id);
      if (!mounted || _paused || !_isStillDesired(conn.id)) return;
      _enqueueConnect(conn);
    });
  }

  // ── Polling ─────────────────────────────────────────────────────────

  void _startPollTimer() {
    if (_pollTimer != null || _paused) return;
    final interval = _ref.read(monitorRefreshIntervalProvider).clamp(5, 3600);
    _pollTimer =
        Timer.periodic(Duration(seconds: interval), (_) => _pollAll());
  }

  void _stopPollTimer() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _restartPollTimerIfRunning() {
    if (_pollTimer != null) {
      _stopPollTimer();
      _startPollTimer();
    }
  }

  void _pollAll() {
    if (!mounted || _paused) return;
    for (final id in _pool.keys.toList()) {
      unawaited(_pollHost(id));
    }
  }

  Future<void> _pollHost(String id) async {
    final service = _pool[id];
    if (service == null) return;

    ServerStats stats;
    try {
      stats = await ServerStatsService.getStats(service.client);
    } catch (e) {
      await _handlePollFailure(id, e);
      return;
    }
    if (!mounted) return;

    // A dead exec connection makes every stat command fail (getStats swallows
    // per-command errors and returns all-null). Treat an all-null sample as a
    // dropped connection: tear down + reconnect rather than overwriting good
    // data with nulls.
    final healthy = stats.cpuPercent != null ||
        stats.ramTotalMB != null ||
        stats.diskPercent != null ||
        stats.uptime != null ||
        stats.loadAverage != null;
    if (!healthy) {
      await _handlePollFailure(id, MonitorNoFigures(gl10n.monitorNoFiguresCame));
      return;
    }

    _ref.read(serverStatsProvider.notifier).commitSshStats(id, stats);
    // Every completed check writes one device-local history sample + refreshes
    // capability detection (success path).
    unawaited(
        _ref.read(monitorHistoryServiceProvider).record(id, stats, ok: true));
    _setStatus(id, MonitorHostState.ok);
  }

  Future<void> _handlePollFailure(String id, Object failedWith) async {
    await _disconnectHost(id);
    if (!mounted) return;
    _ref.read(serverStatsProvider.notifier).recordSshError(id, failedWith);
    // A failed check still writes one sample (null metrics, ok=false) so the
    // history chart can draw a truthful gap.
    unawaited(
        _ref.read(monitorHistoryServiceProvider).record(id, null, ok: false));
    _setStatus(id, MonitorHostState.error, failedWith: failedWith);
    final conn = _connectionForId(id);
    if (conn != null) _scheduleReconnect(conn);
  }

  // ── Teardown helpers ────────────────────────────────────────────────

  Future<void> _disconnectHost(String id) async {
    final service = _pool.remove(id);
    if (service == null) return;
    try {
      ServerStatsService.clearCache(service.client);
    } catch (_) {/* client may already be closed */}
    try {
      await service.disconnect();
    } catch (_) {/* best-effort */}
  }

  Future<void> _teardownAll() async {
    _stopPollTimer();
    for (final id in _pool.keys.toList()) {
      await _disconnectHost(id);
    }
    for (final t in _reconnectTimers.values) {
      t.cancel();
    }
    _reconnectTimers.clear();
    _reconnectAttempts.clear();
    _connectQueue.clear();
    _connectingIds.clear();
  }

  // ── Small helpers ───────────────────────────────────────────────────

  Set<String> _liveSessionConnectionIds() {
    final sessions = _ref.read(activeSessionsProvider);
    final ids = <String>{};
    for (final s in sessions.values) {
      if (s.status != SessionStatus.connected) continue;
      final id = s.connectionId;
      if (id == null) continue;
      if (s.session?.shell.isEncryptedSsh ?? false) ids.add(id);
    }
    return ids;
  }

  Connection? _connectionForId(String id) {
    final monitored = _ref.read(monitoredConnectionsProvider).valueOrNull ??
        const <Connection>[];
    for (final c in monitored) {
      if (c.id == id) return c;
    }
    return null;
  }

  bool _isStillDesired(String id) {
    if (!mounted || _paused) return false;
    if (!_ref.read(agentlessMonitorEnabledProvider)) return false;
    if (_liveSessionConnectionIds().contains(id)) return false;
    final conn = _connectionForId(id);
    return conn != null && conn.protocol == 'ssh';
  }

  MonitorHostStatus _status(MonitorHostState st, {String? detail}) =>
      MonitorHostStatus(st, detail: detail, updatedAt: DateTime.now());

  /// A host that is tried now, after [before]: where the try before failed
  /// (or was itself one that tried again after one that failed), what that
  /// one failed with stays said until this one ends. (A host on a network
  /// that cannot reach it, a phone on cellular to a host at home, said
  /// "Connecting to collect stats." through every try, which takes as long
  /// as the connection's time-out: never why it could not be checked.)
  MonitorHostStatus _tryingAgain(MonitorHostStatus? before) {
    final failed = before != null &&
        before.failedWith != null &&
        (before.state == MonitorHostState.error || before.state == MonitorHostState.connecting);
    return MonitorHostStatus(
      MonitorHostState.connecting,
      failedWith: failed ? before.failedWith : null,
      signInRefused: failed && before.signInRefused,
      updatedAt: DateTime.now(),
    );
  }

  void _setStatus(
    String id,
    MonitorHostState st, {
    String? detail,
    Object? failedWith,
    bool signInRefused = false,
    bool notTriedAgain = false,
    bool hostKeyChanged = false,
  }) {
    if (!mounted) return;
    state = {
      ...state,
      id: MonitorHostStatus(
        st,
        detail: detail,
        failedWith: failedWith,
        signInRefused: signInRefused,
        notTriedAgain: notTriedAgain,
        hostKeyChanged: hostKeyChanged,
        updatedAt: DateTime.now(),
      ),
    };
  }

  @override
  void dispose() {
    _reconcileDebounce?.cancel();
    _graceTeardownTimer?.cancel();
    _pollTimer?.cancel();
    for (final t in _reconnectTimers.values) {
      t.cancel();
    }
    // Fire-and-forget disconnects - the notifier is going away.
    for (final s in _pool.values) {
      try {
        ServerStatsService.clearCache(s.client);
      } catch (_) {}
      try {
        s.disconnect();
      } catch (_) {}
    }
    _pool.clear();
    super.dispose();
  }
}
