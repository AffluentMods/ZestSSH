import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/screens/model/screen_options.dart' show ScreenOptions;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/orchards/rules/crate_offline.dart' show CrateClosedOffline, requireCratesOpenIn;
import 'package:zestssh/features/orchards/watch/watched_crates.dart' show hostIsWatchedIn;
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/server_stats_service.dart';
import 'package:zestssh/services/ssh_service.dart';

/// Health status for a connection.
enum ConnectionHealth {
  unknown, // Never checked
  online, // Responds to TCP connect, or a session is connected to it
  offline, // No response within timeout
  checking, // Currently pinging (kept for API compat, not shown in UI)
}

/// Result of a single health check.
class HealthCheckResult {
  final ConnectionHealth status;
  final int? latencyMs;
  final DateTime checkedAt;

  /// How long this result stands by its own measure: the checks run at an
  /// interval their person chose, and a result is not old before the next
  /// two were due. Zero where nothing is said ([staleAt] then goes by what
  /// its reader allows).
  final Duration goodFor;

  const HealthCheckResult({
    required this.status,
    this.latencyMs,
    required this.checkedAt,
    this.goodFor = Duration.zero,
  });

  /// Whether this result is too old to go by at [now], for a reader that
  /// takes anything older than [staleAfter] as stale: the longer of that
  /// and what the result itself stands for.
  bool staleAt(DateTime now, Duration staleAfter) =>
      now.difference(checkedAt) > (goodFor > staleAfter ? goodFor : staleAfter);
}

/// For the status bar's count of hosts that can be reached: how many of the
/// hosts that are checked are [online], of how many ([tracked]). Nothing
/// where hosts are not checked ([checksOn], Settings): all that is known
/// then is which hosts a session is connected to, and the count of sessions
/// beside it says that already.
({int online, int tracked}) reachableHostsCount(Map<String, HealthCheckResult> health, {required bool checksOn}) {
  if (!checksOn) return (online: 0, tracked: 0);
  final online = health.values.where((h) => h.status == ConnectionHealth.online).length;
  final offline = health.values.where((h) => h.status == ConnectionHealth.offline).length;
  return (online: online, tracked: online + offline);
}

/// Where a check of a host connects: what a connect to it would dial.
typedef ProbeTarget = ({String host, int port});

/// Says where a check of [connection] connects, or null where the host is
/// not to be checked: it is reached through another host, it is skipped on
/// the network this device is on, or the app connects to it only when
/// someone asks.
typedef ProbeTargetResolver = Future<ProbeTarget?> Function(Connection connection);

/// One check: connects to [host]:[port] and gives the time that took in
/// milliseconds, or null where no connection was made.
typedef ReachabilityProbe = Future<int?> Function(String host, int port);

/// A connection to [host]:[port], closed the moment it stands.
///
/// The host sees it. An SSH server logs it as a connection that ended
/// before anyone signed in (OpenSSH: "kex_exchange_identification:
/// Connection closed by remote host"), and a server that bans addresses for
/// those bans this one. That is why nothing is checked this way until its
/// person turns the checks on, and why a host is checked no more often than
/// the interval they chose.
Future<int?> tcpReachabilityProbe(String host, int port) async {
  try {
    final stopwatch = Stopwatch()..start();
    final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 3));
    stopwatch.stop();
    // destroy(), not close(): this is a reachability probe whose stream is
    // never listened to, so close() only half-closes the write side and the
    // socket lingers (holding its OS handle) until the peer's banner drains
    // or it times out. Ticking per checked host, that leaks a handle every
    // probe and accumulates into thousands over a long session. destroy()
    // releases both directions and the handle immediately (as the LAN scan
    // probe already does).
    socket.destroy();
    return stopwatch.elapsedMilliseconds;
  } catch (_) {
    return null;
  }
}

/// The host as it is saved, where no network settings are at hand: checked
/// at its own address unless it is reached through another host.
Future<ProbeTarget?> savedProbeTarget(Connection connection) async =>
    connection.connectViaId != null || throughRdpGateway(connection) ? null : (host: connection.host, port: connection.port);

/// An RDP host reached through an RD Gateway (one this version reads or not): its address is the
/// PC's as the gateway knows it, often a name inside the gateway's network, never dialled from
/// here. Not checked.
bool throughRdpGateway(Connection connection) =>
    connection.protocol == 'rdp' && ScreenOptions.decode(connection.screenOptions).gateway != null;

/// Where a check of [connection] connects, given how it resolves on the
/// network this device is on ([resolved]; null where the network settings
/// could not be read, and the host is taken as it is saved, as a connect
/// does then): the address a connect would dial, and nowhere for a host
/// that is reached through another host. That one is checked as itself, and
/// the address behind it may be another machine's on the network this
/// device is on.
///
/// Without Squeezed ([isPro]) a chain is not dialed and the host is
/// connected to directly (ConnectionResolver.jumpGateSkip): then so is its
/// check.
ProbeTarget? probeTargetFor(Connection connection, {required ResolvedConnection? resolved, required bool isPro}) {
  if (throughRdpGateway(connection)) return null;
  final baseChain = [if (connection.connectViaId != null) connection.connectViaId!];
  final chain = resolved?.jumpChain ?? baseChain;
  final dialed = chain.isNotEmpty &&
      ConnectionResolver.jumpGateSkip(
            isPro: isPro,
            baseHasConnectVia: baseChain.isNotEmpty,
            overrideChangedJump: resolved != null && !listEquals(chain, baseChain),
            overrideChain: chain,
            networkName: resolved?.network.name,
          ) ==
          null;
  if (dialed) return null;
  return (host: resolved?.address ?? connection.host, port: resolved?.port ?? connection.port);
}

/// Where the app's checks connect ([of]): where a connect from the network
/// this device is on would ([probeTargetFor]), and nowhere for a host that
/// is skipped on this network, or that is in a Crate whose sessions are
/// watched or one closed on this device: the app makes no connection to
/// those by itself.
class ReachabilityTargets {
  ReachabilityTargets(this._ref, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Ref _ref;
  final DateTime Function() _now;

  /// How long the network this device is on is taken as looked up: the
  /// hosts due at one tick are resolved on one lookup.
  static const networkGoodFor = Duration(seconds: 4);

  Future<Network>? _network;
  DateTime? _networkAt;

  Future<Network> _currentNetwork() {
    final at = _networkAt;
    final known = _network;
    if (known != null && at != null && _now().difference(at) < networkGoodFor) return known;
    _networkAt = _now();
    return _network = _ref.read(connectionResolverProvider).currentNetwork().timeout(const Duration(seconds: 5));
  }

  Future<ProbeTarget?> of(Connection connection) async {
    final db = _ref.read(databaseProvider);
    if (await hostIsWatchedIn(db, connection.id)) return null;
    try {
      await requireCratesOpenIn(db, hostId: connection.id);
    } on CrateClosedOffline {
      return null;
    }

    ResolvedConnection? resolved;
    try {
      resolved = await _ref.read(connectionResolverProvider).resolveOn(await _currentNetwork(), connection.id);
    } on HostUnreachableException {
      return null;
    } catch (_) {
      // The network settings could not be read (and are asked for anew the
      // next time).
      _network = null;
      resolved = null;
    }
    return probeTargetFor(connection, resolved: resolved, isPro: _ref.read(isProProvider));
  }
}

/// Provider for connection health status map.
final connectionHealthProvider = StateNotifierProvider<
    ConnectionHealthNotifier, Map<String, HealthCheckResult>>((ref) {
  final targets = ReachabilityTargets(ref);
  return ConnectionHealthNotifier(targetOf: targets.of);
});

/// The hosts with a session that is connected now, by connection id.
Set<String> connectedHosts(Map<String, SessionState> sessions) => {
      for (final s in sessions.values)
        if (s.status == SessionStatus.connected && s.connectionId != null) s.connectionId!,
    };

/// Keeps the checks to what Settings say and to the sessions there are: on
/// or off, how often, and which hosts a session already answers for, as
/// things stand now and as they change. Called once as the app starts
/// (app.dart); until then nothing is checked. What it returns ends it.
///
/// (From outside any provider, with the app's container: the hosts sessions
/// are connected to are shown at once, and a provider may not change
/// another one while it is being built.)
///
/// It also times how long a round trip takes on each host's session
/// ([roundTrip]), as a session connects and every
/// [ConnectionHealthNotifier.sessionLatencyEvery] after: that is the latency
/// shown for a host a session is connected to, with no check involved.
void Function() wireReachabilityChecks(
  ProviderContainer container, {
  SessionRoundTrip roundTrip = sshSessionRoundTrip,
}) {
  ConnectionHealthNotifier checks() => container.read(connectionHealthProvider.notifier);

  var timing = false;
  Future<void> timeSessions() async {
    // One round at a time, and none while nobody is looking.
    if (timing || checks().away) return;
    timing = true;
    try {
      final byHost = <String, List<SessionState>>{};
      for (final s in container.read(activeSessionsProvider).values) {
        final id = s.connectionId;
        if (s.status == SessionStatus.connected && id != null) byHost.putIfAbsent(id, () => []).add(s);
      }
      await Future.wait([
        for (final host in byHost.entries)
          () async {
            // The first of its sessions that can be timed.
            for (final session in host.value) {
              final ms = await roundTrip(session);
              if (ms == null) continue;
              checks().sessionLatency(host.key, ms);
              return;
            }
          }(),
      ]);
    } finally {
      timing = false;
    }
  }

  final following = [
    container.listen<bool>(healthChecksEnabledProvider, (_, on) => checks().setEnabled(on), fireImmediately: true),
    container.listen<int>(
      healthCheckIntervalProvider,
      (_, seconds) => checks().setInterval(Duration(seconds: seconds)),
      fireImmediately: true,
    ),
    container.listen<Map<String, SessionState>>(
      activeSessionsProvider,
      (before, sessions) {
        final hosts = connectedHosts(sessions);
        checks().setSessionHosts(hosts);
        // A host a session has just connected to is timed now.
        if (hosts.difference(before == null ? const {} : connectedHosts(before)).isNotEmpty) unawaited(timeSessions());
      },
      fireImmediately: true,
    ),
  ];
  final everySoOften = Timer.periodic(ConnectionHealthNotifier.sessionLatencyEvery, (_) => timeSessions());
  return () {
    everySoOften.cancel();
    for (final one in following) {
      one.close();
    }
  };
}

/// How long one round trip takes on [session]'s own connection, in
/// milliseconds, or null where there is none to time.
typedef SessionRoundTrip = Future<int?> Function(SessionState session);

/// [SessionRoundTrip] for the app's sessions: an SSH session's connection
/// is asked one keep-alive question, timed
/// ([ServerStatsService.roundTripMs]). Nothing for a session of another
/// kind, nor for a watched one, of which only the terminal is used (its
/// shell is on purpose not an [SshService]), nor where no answer came, nor
/// for a session that has no connection (not yet, or no longer: asking for
/// it throws).
Future<int?> sshSessionRoundTrip(SessionState session) async {
  final shell = session.session?.shell;
  if (shell is! SshService) return null;
  try {
    return await ServerStatsService.roundTripMs(shell.client);
  } catch (_) {
    return null;
  }
}

/// Whether saved hosts can be reached, by a TCP connection to each at an
/// interval, for the hosts its person asked to have checked (Settings; off
/// until they turn it on, since every check is a connection the host sees
/// and logs: [tcpReachabilityProbe]).
///
/// What it never does:
///  * check anything while it is off ([setEnabled]) or paused ([pause]),
///    whoever asks: every check, a screen's sweep too, goes through
///    [checkHealth], and that is where it is refused;
///  * check a host more often than the interval ([setInterval]) unless its
///    person pressed a refresh, but for one check a tick later when a result
///    differs from what is shown;
///  * check a host a session is connected to ([setSessionHosts]): the
///    session says it is reachable;
///  * check a host its [ProbeTargetResolver] gives no address for.
///
/// Uses 3-ping averaging and debouncing to prevent status flicker:
/// - Stores the last 3 probe results per connection.
/// - Only changes displayed status when 2 out of 3 probes agree.
/// - Minimum 3-second gap between status updates per connection.
/// - No intermediate "checking" state emitted to UI.
class ConnectionHealthNotifier
    extends StateNotifier<Map<String, HealthCheckResult>> {
  ConnectionHealthNotifier({
    ProbeTargetResolver? targetOf,
    ReachabilityProbe? probe,
    DateTime Function()? now,
  })  : _targetOf = targetOf ?? savedProbeTarget,
        _probe = probe ?? tcpReachabilityProbe,
        _now = now ?? DateTime.now,
        super({});

  final ProbeTargetResolver _targetOf;
  final ReachabilityProbe _probe;
  final DateTime Function() _now;

  Timer? _periodicTimer;

  /// Whether a screen asked for the hosts to be checked ([startPeriodicChecks]).
  bool _wanted = false;

  /// Whether the checks are on in Settings. Off, nothing connects anywhere.
  bool _enabled = false;

  /// Whether the app is away (in the background, its window not in front,
  /// or locked): nobody is looking, so nothing is checked.
  bool _paused = false;

  /// How often a host is checked.
  Duration _interval = defaultInterval;

  /// Hosts whose latest result differs from what is shown: checked once more
  /// a tick later, so that a host that went away or came back shows it
  /// without waiting a whole interval.
  final Set<String> _confirm = {};

  /// Hosts a session is connected to. Reachable, as the session says, and
  /// never checked.
  final Set<String> _sessionHosts = {};

  /// Last 3 probe results per connection ID for averaging.
  final Map<String, List<ConnectionHealth>> _history = {};

  /// Timestamps of last status update per connection for debouncing.
  final Map<String, DateTime> _lastUpdate = {};

  /// Timestamps of last health probe per connection for scheduling.
  final Map<String, DateTime> _lastProbeTime = {};

  /// Last 3 successful round-trip latencies (ms) per connection. The REPORTED
  /// latency is the median of this window, so a single anomalous probe can't
  /// spike the value (and can't flip a latency-threshold monitor bucket on its
  /// own - the status consensus already uses [_history], but the raw latency
  /// value did not until now).
  final Map<String, List<int>> _latencyHistory = {};

  /// Median of a short latency window (already smoothing away lone spikes).
  int _smoothedLatency(String id, int sample) {
    final lat = _latencyHistory.putIfAbsent(id, () => []);
    lat.add(sample);
    if (lat.length > 3) lat.removeAt(0);
    final sorted = [...lat]..sort();
    return sorted[sorted.length ~/ 2];
  }

  /// The full connection list for per-connection scheduling.
  List<Connection> _connections = [];

  /// Currently active health check futures, keyed by connection ID.
  final _activeChecks = <String, Future<void>>{};

  /// Maximum number of concurrent health checks to prevent resource exhaustion.
  static const _maxConcurrentChecks = 10;

  /// Minimum time between visible status changes (debounce).
  static const _debounceInterval = Duration(seconds: 3);

  /// How often the checks look for hosts that are due.
  static const tick = Duration(seconds: 5);

  /// How often a host is checked until Settings say otherwise.
  static const defaultInterval = Duration(seconds: 60);

  /// The shortest interval there is: nothing is checked more often.
  static const shortestInterval = Duration(seconds: 30);

  /// How often a session's round trip is timed, for the latency of the host
  /// it is connected to ([sessionLatency]).
  static const sessionLatencyEvery = Duration(seconds: 30);

  /// The kinds of host a TCP connection says something about (a host that
  /// is SFTP only is reached on its SSH port). Not a serial port, a shell
  /// on this device or the demo, whose "address" is none.
  static const _checkedProtocols = {'ssh', 'sftp', 'mosh', 'telnet', 'et'};

  /// Whether the checks are on.
  bool get enabled => _enabled;

  /// Turns the checks on or off (Settings). Off, they stop at once and what
  /// they found is forgotten: a dot that is checked no longer says nothing.
  void setEnabled(bool enabled) {
    if (_enabled == enabled) return;
    _enabled = enabled;
    if (enabled) {
      _arm();
    } else {
      _disarm();
      _forgetChecks();
    }
  }

  /// How often a host is checked.
  Duration get interval => _interval;

  /// How often a host is checked from now on, never more often than
  /// [shortestInterval].
  void setInterval(Duration interval) {
    _interval = interval < shortestInterval ? shortestInterval : interval;
  }

  /// The app is away: nothing is checked until [resume].
  void pause() => _paused = true;

  /// Whether the app is away ([pause]).
  bool get away => _paused;

  /// The app is back: the hosts that fell due meanwhile are checked now.
  void resume() {
    _paused = false;
    _checkDueConnections();
  }

  /// The hosts a session is connected to now. They show as reachable, which
  /// their session says, and are not checked while it is. A host whose last
  /// session ended is unknown again until it is next due: a session brings
  /// no check forward, so a host is still checked no more often than the
  /// interval.
  void setSessionHosts(Set<String> ids) {
    final gone = _sessionHosts.difference(ids);
    final came = ids.difference(_sessionHosts);
    if (gone.isEmpty && came.isEmpty) return;
    _sessionHosts
      ..removeAll(gone)
      ..addAll(came);
    final next = {...state};
    for (final id in gone) {
      // (How long its session's round trips took is not a check's figure.)
      _forgetShown(id);
      next.remove(id);
    }
    final now = _now();
    for (final id in came) {
      _forgetShown(id);
      next[id] = HealthCheckResult(status: ConnectionHealth.online, checkedAt: now);
    }
    if (mounted) state = next;
  }

  /// How long a round trip took on a session connected to the host [id],
  /// timed on that session's own connection: its latency for as long as a
  /// session is connected to it. Nothing for a host no session is
  /// connected to.
  void sessionLatency(String id, int latencyMs) {
    if (!mounted || !_sessionHosts.contains(id)) return;
    state = {
      ...state,
      id: HealthCheckResult(
        status: ConnectionHealth.online,
        latencyMs: _smoothedLatency(id, latencyMs),
        checkedAt: _now(),
        goodFor: sessionLatencyEvery * 2,
      ),
    };
  }

  /// Check health of a single connection by attempting a TCP connect.
  ///
  /// Does NOT emit a `checking` intermediate state to the UI -
  /// keeps the previous status visible until the probe completes.
  Future<void> checkHealth(Connection connection) async {
    if (!_enabled || _paused) return;
    if (!_checkedProtocols.contains(connection.protocol)) return;

    final id = connection.id;
    if (_sessionHosts.contains(id)) return;
    _lastProbeTime[id] = _now();

    ProbeTarget? target;
    try {
      target = await _targetOf(connection);
    } catch (_) {
      target = null;
    }
    // Turned off, or a session connected, while that was looked up.
    if (!mounted || !_enabled || _sessionHosts.contains(id)) return;
    if (target == null) {
      // Not to be checked: nothing is said of it.
      _forgetShown(id);
      if (state.containsKey(id)) state = {...state}..remove(id);
      return;
    }

    final latencyMs = await _probe(target.host, target.port);
    if (!mounted || !_enabled || _sessionHosts.contains(id)) return;
    _recordProbe(
      id,
      latencyMs == null ? ConnectionHealth.offline : ConnectionHealth.online,
      latencyMs: latencyMs,
    );
  }

  /// Record a probe result and update state using 3-ping averaging + debounce.
  void _recordProbe(String id, ConnectionHealth probeResult,
      {int? latencyMs}) {
    // Add to history (keep last 3)
    final history = _history.putIfAbsent(id, () => []);
    history.add(probeResult);
    if (history.length > 3) {
      history.removeAt(0);
    }

    // Determine consensus: use majority of last 3 probes
    final newStatus = _consensusStatus(history);

    // The latest result is not what is shown (two of three decide): look
    // once more at the next tick.
    if (probeResult == newStatus) {
      _confirm.remove(id);
    } else {
      _confirm.add(id);
    }

    // Smooth the reported latency (median of the last 3 successful probes) so a
    // lone anomalous RTT can't spike the value or, via the latency threshold,
    // flip a monitor bucket on its own.
    final int? smoothedLatency =
        latencyMs != null ? _smoothedLatency(id, latencyMs) : null;

    // Debounce: don't update if we changed too recently
    final lastUpdate = _lastUpdate[id];
    final now = _now();
    final current = state[id];

    if (lastUpdate != null &&
        now.difference(lastUpdate) < _debounceInterval &&
        current != null &&
        current.status == newStatus) {
      // Same status within debounce window - update latency only
      if (smoothedLatency != null && newStatus == ConnectionHealth.online) {
        state = {
          ...state,
          id: HealthCheckResult(
            status: newStatus,
            latencyMs: smoothedLatency,
            checkedAt: now,
            goodFor: _interval * 2,
          ),
        };
      }
      return;
    }

    // Update if status changed or enough time has passed
    _lastUpdate[id] = now;
    state = {
      ...state,
      id: HealthCheckResult(
        status: newStatus,
        latencyMs: newStatus == ConnectionHealth.online ? smoothedLatency : null,
        checkedAt: now,
        goodFor: _interval * 2,
      ),
    };
  }

  /// Determine consensus status from history using majority vote.
  ConnectionHealth _consensusStatus(List<ConnectionHealth> history) {
    if (history.isEmpty) return ConnectionHealth.unknown;
    if (history.length == 1) return history.first;

    final onlineCount =
        history.where((h) => h == ConnectionHealth.online).length;
    final offlineCount =
        history.where((h) => h == ConnectionHealth.offline).length;

    // Majority wins (2 out of 3)
    if (onlineCount >= 2) return ConnectionHealth.online;
    if (offlineCount >= 2) return ConnectionHealth.offline;

    // No clear majority yet - keep most recent
    return history.last;
  }

  /// Check connections that are due for a probe.
  void _checkDueConnections() {
    if (!_wanted) return;
    final now = _now();
    for (final conn in _connections) {
      // (Passed over here, and not left to [checkHealth] to refuse: each
      // would hold one of the ten places until the loop is over, and the
      // hosts after ten of them would never be reached.)
      if (!_checkedProtocols.contains(conn.protocol)) continue;
      if (_sessionHosts.contains(conn.id)) continue;

      // Skip if already checking this connection
      if (_activeChecks.containsKey(conn.id)) continue;
      // Limit concurrent checks to prevent resource exhaustion
      if (_activeChecks.length >= _maxConcurrentChecks) break;

      if (_due(conn.id, now)) {
        final future = checkHealth(conn);
        _activeChecks[conn.id] = future;
        future.whenComplete(() => _activeChecks.remove(conn.id));
      }
    }
  }

  /// Whether [id] is to be checked at [now]: it never was, or an interval
  /// ago (a tick ago where its latest result is to be looked at again).
  bool _due(String id, DateTime now) {
    final lastProbe = _lastProbeTime[id];
    final wait = _confirm.contains(id) ? tick : _interval;
    return lastProbe == null || now.difference(lastProbe) >= wait;
  }

  /// Check the health of [connections], respecting the concurrency limit:
  /// those that are due, or every one of them now where its person [asked]
  /// for it (a refresh they pressed). A screen that merely opens asks for
  /// nothing: its sweep does not check a host more often than the interval.
  /// Nothing at all where the checks are off ([checkHealth]).
  Future<void> checkAll(List<Connection> connections, {bool asked = false}) async {
    final now = _now();
    final futures = <Future<void>>[];
    for (final conn in connections) {
      if (_activeChecks.containsKey(conn.id)) continue;
      if (!asked && !_due(conn.id, now)) continue;
      while (_activeChecks.length >= _maxConcurrentChecks) {
        await Future.any(_activeChecks.values);
      }
      final future = checkHealth(conn);
      _activeChecks[conn.id] = future;
      future.whenComplete(() => _activeChecks.remove(conn.id));
      futures.add(future);
    }
    await Future.wait(futures);
  }

  /// Start periodic health checks of [connections], where the checks are on
  /// (and once they are turned on): every host once now, then each at the
  /// interval.
  ///
  /// Guarded against duplicate calls from widget rebuilds.
  void startPeriodicChecks(List<Connection> connections) {
    updateConnections(connections);
    if (_wanted) return; // Prevent duplicate timers from rebuild
    _wanted = true;
    _arm();
  }

  /// Stop periodic health checks.
  void stopPeriodicChecks() {
    _wanted = false;
    _disarm();
  }

  /// Starts the checks once a screen wants them and they are on. (Called
  /// when either becomes so, and they stop when either ends: never twice.)
  void _arm() {
    if (!_wanted || !_enabled) return;
    unawaited(checkAll(_connections));
    _periodicTimer = Timer.periodic(tick, (_) => _checkDueConnections());
  }

  void _disarm() {
    _periodicTimer?.cancel();
    _periodicTimer = null;
  }

  /// Update the connections list used by periodic checks. Nothing is said
  /// any more of a host that is not on it (it was deleted, or the list is
  /// another space's now); should it be back, it is due no sooner for that.
  void updateConnections(List<Connection> connections) {
    _connections = connections;
    final saved = {for (final c in connections) c.id};
    final gone = [
      for (final id in state.keys)
        if (!saved.contains(id) && !_sessionHosts.contains(id)) id,
    ];
    if (gone.isEmpty) return;
    for (final id in gone) {
      _forgetShown(id);
    }
    state = {...state}..removeWhere((id, _) => gone.contains(id));
  }

  /// What the checks of [id] found, so that the next one decides alone.
  /// When it was last checked stays: it is not due any sooner for this.
  void _forgetShown(String id) {
    _history.remove(id);
    _lastUpdate.remove(id);
    _latencyHistory.remove(id);
    _confirm.remove(id);
  }

  /// What the checks found: gone with them. What sessions say stays.
  void _forgetChecks() {
    _history.clear();
    _lastUpdate.clear();
    _lastProbeTime.clear();
    _latencyHistory.clear();
    _confirm.clear();
    if (!mounted) return;
    state = {
      for (final entry in state.entries)
        if (_sessionHosts.contains(entry.key)) entry.key: entry.value,
    };
  }

  /// Get health for a specific connection.
  HealthCheckResult? getHealth(String connectionId) => state[connectionId];

  @override
  void dispose() {
    _periodicTimer?.cancel();
    _activeChecks.clear();
    super.dispose();
  }
}
