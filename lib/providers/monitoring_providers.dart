import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/features/monitoring/monitor_capabilities.dart';
import 'package:zestssh/features/monitoring/monitor_columns.dart';
import 'package:zestssh/services/monitor_history_service.dart';
import 'package:zestssh/services/prometheus_secure_settings.dart';
import 'package:zestssh/services/prometheus_service.dart';
import 'package:zestssh/services/server_stats_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/host_address.dart';

/// Auto-refresh interval for server monitoring (in seconds).
final monitorRefreshIntervalProvider = StateProvider<int>((ref) => 30);

// ── Server Monitor history + capability detection (device-local) ────

/// Persisted, per-host capability cache (which metrics a host can report).
/// Device-local; never synced.
final monitorCapabilityStoreProvider =
    Provider<MonitorCapabilityStore>((ref) {
  return MonitorCapabilityStore(ref.watch(sharedPreferencesProvider));
});

/// Records one history sample per completed check, updates capability
/// detection, and runs retention opportunistically. Device-local; never synced.
final monitorHistoryServiceProvider = Provider<MonitorHistoryService>((ref) {
  return MonitorHistoryService(
    ref.watch(monitorSamplesDaoProvider),
    ref.watch(monitorCapabilityStoreProvider),
  );
});

/// Cached capabilities for a host, for later UI (renders N/A for metrics not in
/// the set). Read-through; a later UI phase can layer reactivity on writes.
final monitorCapabilitiesProvider =
    Provider.family<MonitorCapabilities, String>((ref, connectionId) {
  return ref.watch(monitorCapabilityStoreProvider).getFor(connectionId);
});

// ── Host detail pane: history range read + chart-series persistence ──

/// The three history windows the detail-pane chart offers (spec §2.1).
enum MonitorHistoryRange { twoHours, twentyFourHours, sevenDays }

extension MonitorHistoryRangeSpan on MonitorHistoryRange {
  /// The look-back window this range covers.
  Duration get span => switch (this) {
        MonitorHistoryRange.twoHours => const Duration(hours: 2),
        MonitorHistoryRange.twentyFourHours => const Duration(hours: 24),
        MonitorHistoryRange.sevenDays => const Duration(days: 7),
      };
}

/// Persisted [MonitorSamples] for a host over a range window (device-local
/// history; §4). Keyed by `(connectionId, range)`; the DAO returns rows
/// oldest→newest. Re-fetches whenever a fresh sample lands (history is written
/// alongside the stats commit) so the chart stays live without a manual refresh.
final monitorHistorySamplesProvider = FutureProvider.family<List<MonitorSample>,
    (String, MonitorHistoryRange)>((ref, arg) async {
  final (connectionId, range) = arg;
  ref.watch(serverStatsProvider); // rebuild when a new sample is committed
  final dao = ref.watch(monitorSamplesDaoProvider);
  final since = DateTime.now().subtract(range.span);
  return dao.rangeFor(connectionId, since);
});

/// The most recent 24 checks for a host, oldest→newest - the source for the
/// desktop "Last 24 checks" status strip (§1). Re-fetches whenever a fresh
/// sample lands so the strip stays live without a manual refresh.
final monitorRecentSamplesProvider =
    FutureProvider.family<List<MonitorSample>, String>((ref, connectionId) async {
  ref.watch(serverStatsProvider); // rebuild when a new sample is committed
  final dao = ref.watch(monitorSamplesDaoProvider);
  return dao.recentFor(connectionId, limit: 24);
});

/// Persisted desktop-table column layout (order + visibility; §2). Device-local
/// via SharedPreferences - column choices are a per-device view preference, not
/// synced configuration.
/// The widths its person set for the Server monitor table's columns, by
/// column: dragged at a column's edge, or fitted to what it holds, and
/// remembered on this device. A column with none takes its own width.
final monitorColumnWidthsProvider =
    StateNotifierProvider<MonitorColumnWidthsNotifier, Map<String, double>>((ref) {
  return MonitorColumnWidthsNotifier(ref.watch(sharedPreferencesProvider));
});

class MonitorColumnWidthsNotifier extends StateNotifier<Map<String, double>> {
  MonitorColumnWidthsNotifier(this._prefs) : super(_load(_prefs));

  final SharedPreferences _prefs;
  static const _widthsKey = 'monitor_column_widths_v1';

  static Map<String, double> _load(SharedPreferences prefs) {
    final raw = prefs.getString(_widthsKey);
    if (raw == null) return const {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return {for (final e in decoded.entries) e.key: (e.value as num).toDouble()};
    } catch (_) {
      // Corrupt: the columns' own widths, and the next write heals it.
      return const {};
    }
  }

  /// A column's width while its edge is dragged; [persist] once it is let go.
  void set(String column, double width) => state = {...state, column: width};

  void persist() {
    // ignore: discarded_futures
    _prefs.setString(_widthsKey, jsonEncode(state));
  }

  void setAndPersist(String column, double width) {
    set(column, width);
    persist();
  }

  /// Every column back to its own width.
  void reset() {
    state = const {};
    // ignore: discarded_futures
    _prefs.remove(_widthsKey);
  }
}

final monitorColumnsProvider =
    StateNotifierProvider<MonitorColumnsNotifier, MonitorColumnConfig>((ref) {
  return MonitorColumnsNotifier(ref.watch(sharedPreferencesProvider));
});

class MonitorColumnsNotifier extends StateNotifier<MonitorColumnConfig> {
  MonitorColumnsNotifier(this._prefs) : super(MonitorColumnConfig.defaults) {
    state = MonitorColumnConfig.decode(_prefs.getString(_prefsKey));
  }

  final SharedPreferences _prefs;
  static const _prefsKey = 'monitor_columns_v1';

  void _persist() {
    try {
      _prefs.setString(_prefsKey, state.encode());
    } catch (_) {
      // Persistence is a nicety, never a hard dependency.
    }
  }

  void toggle(MonitorColumn column, bool on) {
    state = state.toggle(column, on);
    _persist();
  }

  void reorder(int oldIndex, int newIndex) {
    state = state.reorder(oldIndex, newIndex);
    _persist();
  }
}

/// Persists which chart series are VISIBLE per host in the detail-pane legend
/// (spec §2.1: "which metrics are visible persists per host"). Device-local; the
/// stored value is a list of stable series keys ('cpu'/'ram'/'disk'/'swap'/
/// 'load'/'temp'). A host with no stored entry defaults to CPU/RAM/Disk.
class MonitorChartSeriesStore {
  MonitorChartSeriesStore(this._prefs);

  final SharedPreferences _prefs;

  static const _prefsKey = 'monitor_chart_series_v1';

  /// Default visible set for a host that has never toggled the legend.
  static const List<String> kDefaultSeries = ['cpu', 'ram', 'disk'];

  Map<String, dynamic> _readAll() {
    final raw = _prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // Corrupt cache → treat as empty; the next write heals it.
    }
    return {};
  }

  /// Visible series keys for [connectionId]. A stored EMPTY list is honoured
  /// (the user hid everything); only a host with NO entry falls back to the
  /// default CPU/RAM/Disk set.
  List<String> getFor(String connectionId) {
    final entry = _readAll()[connectionId];
    if (entry is List) return entry.map((e) => e.toString()).toList();
    return kDefaultSeries;
  }

  Future<void> setFor(String connectionId, List<String> series) async {
    final all = _readAll();
    all[connectionId] = series;
    try {
      await _prefs.setString(_prefsKey, jsonEncode(all));
    } catch (_) {
      // Persistence is a nicety, never a hard dependency.
    }
  }
}

/// Device-local store for per-host visible chart series (never synced).
final monitorChartSeriesStoreProvider =
    Provider<MonitorChartSeriesStore>((ref) {
  return MonitorChartSeriesStore(ref.watch(sharedPreferencesProvider));
});

/// The current monitor data source mode: 'ssh' or 'prometheus'.
final monitorDataSourceProvider = Provider<String>((ref) {
  final settings = ref.watch(settingsServiceProvider);
  return settings.monitorDataSource;
});

/// Prometheus secure settings helper (wraps FlutterSecureStorage).
final prometheusSecureSettingsProvider =
    Provider<PrometheusSecureSettings>((ref) {
  // Made again when the database opens or closes: the secrets are sealed
  // with it while the encrypting lock is on, and open only then.
  final tree = ref.watch(databaseSessionProvider);
  return PrometheusSecureSettings(ref.watch(secureStorageProvider), tree: () => tree);
});

// ---------------------------------------------------------------------------
// Prometheus config cache - loads async credentials into memory so the
// PrometheusService provider can remain synchronous.
// ---------------------------------------------------------------------------

/// In-memory snapshot of all Prometheus credentials from secure storage.
class PrometheusConfigCache {
  final String? caPem;
  final Uint8List? clientCertP12Bytes;
  final String? clientCertPassword;
  final String? bearerToken;
  final String? basicAuthUser;
  final String? basicAuthPassword;
  final String? customHeaderValue;

  const PrometheusConfigCache({
    this.caPem,
    this.clientCertP12Bytes,
    this.clientCertPassword,
    this.bearerToken,
    this.basicAuthUser,
    this.basicAuthPassword,
    this.customHeaderValue,
  });
}

/// Async provider that loads all Prometheus credentials into memory.
/// Invalidate this after saving new Prometheus settings.
final prometheusConfigCacheProvider =
    FutureProvider<PrometheusConfigCache>((ref) async {
  final secure = ref.watch(prometheusSecureSettingsProvider);
  return PrometheusConfigCache(
    caPem: await secure.getCaPem(),
    clientCertP12Bytes: await secure.getClientCertP12Bytes(),
    clientCertPassword: await secure.getClientCertPassword(),
    bearerToken: await secure.getBearerToken(),
    basicAuthUser: await secure.getBasicAuthUser(),
    basicAuthPassword: await secure.getBasicAuthPassword(),
    customHeaderValue: await secure.getCustomHeaderValue(),
  );
});

/// Prometheus service instance (null if not configured or cache not loaded).
final prometheusServiceProvider = Provider<PrometheusService?>((ref) {
  final settings = ref.read(settingsServiceProvider);
  final url = settings.prometheusUrl;
  if (url == null || url.isEmpty) return null;

  final cacheAsync = ref.watch(prometheusConfigCacheProvider);
  final cache = cacheAsync.valueOrNull;
  if (cache == null) return null; // Still loading

  return PrometheusService(
    baseUrl: url,
    authType: PrometheusAuthType.fromKey(settings.prometheusAuthType),
    bearerToken: cache.bearerToken,
    basicAuthUser: cache.basicAuthUser,
    basicAuthPassword: cache.basicAuthPassword,
    customHeaderKey: settings.prometheusCustomHeaderKey,
    customHeaderValue: cache.customHeaderValue,
    caPem: cache.caPem,
    clientCertP12Bytes: cache.clientCertP12Bytes,
    clientCertPassword: cache.clientCertPassword,
    verifySsl: settings.prometheusVerifySsl,
  );
});

/// Cached Prometheus target-to-connection mapping.
/// Key: connection ID, Value: Prometheus instance label (e.g. "192.0.2.21:9100").
final prometheusTargetMapProvider =
    StateProvider<Map<String, String>>((ref) => {});

/// Per-connection server stats, keyed by connection ID.
final serverStatsProvider = StateNotifierProvider<ServerStatsNotifier,
    Map<String, ServerStats>>((ref) {
  return ServerStatsNotifier(ref);
});

/// Bounded per-host metric sample history (oldest → newest) for sparklines
/// (Doc-3 B6). Rebuilds whenever a fresh sample lands, since the newest
/// sample is committed to [serverStatsProvider] at the same time.
final serverStatsHistoryProvider =
    Provider.family<List<ServerStats>, String>((ref, connectionId) {
  ref.watch(serverStatsProvider);
  return ref.read(serverStatsProvider.notifier).historyFor(connectionId);
});

/// A recorded collection failure (Doc-3 B5): which mechanism failed and a
/// short, single-line reason suitable for showing on a card.
class CollectionError {
  final MetricSource source;
  final String reason;
  const CollectionError(this.source, this.reason);
}

/// Condense an exception into a short, single-line reason for display.
String _briefReason(Object error) {
  var s = error.toString().trim();
  final newline = s.indexOf('\n');
  if (newline >= 0) s = s.substring(0, newline).trim();
  const maxLen = 120;
  if (s.length > maxLen) s = '${s.substring(0, maxLen - 1).trimRight()}…';
  return s;
}

/// Manages server stats collection across active SSH sessions and/or Prometheus.
///
/// Stats are persisted to SharedPreferences so they survive app restarts.
/// Cached stats show the last-known state with a "collected at" timestamp.
class ServerStatsNotifier extends StateNotifier<Map<String, ServerStats>> {
  final Ref _ref;
  Timer? _refreshTimer;

  static const _cacheKey = 'cached_server_stats';

  /// Bounded per-host sample history for sparklines (Doc-3 B6). In-memory
  /// only - it accrues while the app runs (the newest sample is also the
  /// value in [state]); capped so memory stays flat over long sessions.
  static const int _maxHistorySamples = 60;
  final Map<String, List<ServerStats>> _statsHistory = {};

  /// Read-only sample history (oldest → newest) for a connection. Empty when
  /// nothing has been collected yet.
  List<ServerStats> historyFor(String connectionId) =>
      List.unmodifiable(_statsHistory[connectionId] ?? const <ServerStats>[]);

  /// Append a freshly-collected sample to the ring buffer, dropping the
  /// oldest when full. Called alongside every [state] commit.
  void _recordHistory(String connectionId, ServerStats stats) {
    final list =
        _statsHistory.putIfAbsent(connectionId, () => <ServerStats>[]);
    list.add(stats);
    if (list.length > _maxHistorySamples) {
      list.removeRange(0, list.length - _maxHistorySamples);
    }
  }

  /// Last collection failure per connection (Doc-3 B5). Set in the collect
  /// catch blocks, cleared on the next successful collect. Surfaced read-only
  /// via [serverStatsErrorProvider] so a card can name the failed mechanism
  /// and a brief reason.
  final Map<String, CollectionError> _lastError = {};

  /// The most recent collection failure for a connection, or null when the
  /// last collect succeeded.
  CollectionError? lastErrorFor(String connectionId) =>
      _lastError[connectionId];

  /// Record a collection failure and re-emit [state] so watchers rebuild - a
  /// failed collect commits no new stats on its own.
  void _recordError(String connectionId, MetricSource source, Object error) {
    _lastError[connectionId] = CollectionError(source, _briefReason(error));
    if (mounted) state = {...state};
  }

  /// Clear a stored failure after a successful collect. The success path
  /// already re-emits [state], so no extra notify is needed here.
  void _clearError(String connectionId) {
    _lastError.remove(connectionId);
  }

  ServerStatsNotifier(this._ref) : super({}) {
    // Load cached stats on creation.
    _loadCachedStats();
  }

  /// Load previously cached stats from SharedPreferences.
  void _loadCachedStats() {
    try {
      final prefs = _ref.read(sharedPreferencesProvider);
      final json = prefs.getString(_cacheKey);
      if (json == null) return;

      final decoded = jsonDecode(json) as Map<String, dynamic>;
      final loaded = <String, ServerStats>{};

      for (final entry in decoded.entries) {
        final data = entry.value as Map<String, dynamic>;
        final loadAvgRaw = data['loadAverage'];
        List<double>? loadAvg;
        if (loadAvgRaw is List) {
          loadAvg = loadAvgRaw.map((e) => (e as num).toDouble()).toList();
        }
        // Collection source (Doc-3 B5). Absent in caches written before this
        // field existed → default to none so old data never crashes the load.
        final sourceRaw = data['source'];
        final source = sourceRaw is String
            ? MetricSource.values.firstWhere(
                (s) => s.name == sourceRaw,
                orElse: () => MetricSource.none,
              )
            : MetricSource.none;
        loaded[entry.key] = ServerStats(
          cpuPercent: (data['cpuPercent'] as num?)?.toDouble(),
          ramUsedMB: data['ramUsedMB'] as int?,
          ramTotalMB: data['ramTotalMB'] as int?,
          diskPercent: (data['diskPercent'] as num?)?.toDouble(),
          uptime: data['uptime'] as String?,
          loadAverage: loadAvg,
          collectedAt: DateTime.fromMillisecondsSinceEpoch(
              data['collectedAt'] as int),
          source: source,
          zfsArcFreeableMB: data['zfsArcFreeableMB'] as int?,
        );
      }

      if (mounted && loaded.isNotEmpty) {
        state = loaded;
        AppLogger.debug(
            'ServerStats: loaded ${loaded.length} cached stats from disk');
      }
    } catch (e) {
      AppLogger.debug('ServerStats: failed to load cached stats: $e');
    }
  }

  /// Persist current stats to SharedPreferences.
  void _saveStatsToCache() {
    try {
      final prefs = _ref.read(sharedPreferencesProvider);
      final encoded = <String, dynamic>{};

      for (final entry in state.entries) {
        final stats = entry.value;
        encoded[entry.key] = {
          'cpuPercent': stats.cpuPercent,
          'ramUsedMB': stats.ramUsedMB,
          'ramTotalMB': stats.ramTotalMB,
          'diskPercent': stats.diskPercent,
          'uptime': stats.uptime,
          'loadAverage': stats.loadAverage,
          'collectedAt': stats.collectedAt.millisecondsSinceEpoch,
          'source': stats.source.name,
          if (stats.zfsArcFreeableMB != null) 'zfsArcFreeableMB': stats.zfsArcFreeableMB,
        };
      }

      prefs.setString(_cacheKey, jsonEncode(encoded));
    } catch (e) {
      AppLogger.debug('ServerStats: failed to save cached stats: $e');
    }
  }

  /// Refresh stats for all connections using the active data source.
  ///
  /// If the data source is explicitly 'prometheus', use Prometheus.
  /// If it's 'ssh' but a Prometheus service is configured, also try
  /// Prometheus (auto-detect). This way users don't have to manually
  /// switch the data source after configuring a Prometheus URL.
  Future<void> refreshAll() async {
    final dataSource = _ref.read(monitorDataSourceProvider);
    final prometheus = _ref.read(prometheusServiceProvider);

    if (dataSource == 'prometheus' || prometheus != null) {
      await _refreshAllPrometheus();
    }

    // Always also try SSH for active sessions (covers connections
    // without a Prometheus match).
    await _refreshAllSsh();
  }

  /// Refresh via Prometheus for all mapped connections.
  Future<void> _refreshAllPrometheus() async {
    final prometheus = _ref.read(prometheusServiceProvider);
    if (prometheus == null) return;

    final targetMap = _ref.read(prometheusTargetMapProvider);
    if (targetMap.isEmpty) {
      // Try auto-discovery
      await discoverPrometheusTargets();
    }

    final targets = _ref.read(prometheusTargetMapProvider);
    final futures = <Future<void>>[];

    for (final entry in targets.entries) {
      futures
          .add(_collectPrometheusStats(entry.key, entry.value, prometheus));
    }

    if (futures.isNotEmpty) {
      await Future.wait(futures);
    }
  }

  /// Collect stats from Prometheus for a single connection.
  Future<void> _collectPrometheusStats(
      String connectionId,
      String instance,
      PrometheusService prometheus) async {
    try {
      final promStats = await prometheus.getBasicStats(instance);
      final stats = ServerStats(
        cpuPercent: promStats.cpuPercent,
        ramUsedMB: promStats.ramUsedMB,
        ramTotalMB: promStats.ramTotalMB,
        diskPercent: promStats.diskPercent,
        uptime: promStats.uptime,
        loadAverage: promStats.loadAverage,
        collectedAt: promStats.collectedAt,
        source: MetricSource.prometheus,
      );

      if (mounted) {
        _clearError(connectionId);
        state = {...state, connectionId: stats};
        _recordHistory(connectionId, stats);
        _saveStatsToCache();
        // History only - capability detection stays SSH-authoritative, since a
        // Prometheus target reports a different metric set than the SSH probe.
        unawaited(_ref.read(monitorHistoryServiceProvider).record(
            connectionId, stats,
            ok: true, updateCapabilities: false));
      }
    } catch (e) {
      _recordError(connectionId, MetricSource.prometheus, e);
      unawaited(_ref.read(monitorHistoryServiceProvider).record(
          connectionId, null,
          ok: false, updateCapabilities: false));
      AppLogger.debug(
          'Prometheus stats collection failed for $connectionId: $e');
    }
  }

  /// Refresh via SSH for all active sessions.
  Future<void> _refreshAllSsh() async {
    final sessions = _ref.read(activeSessionsProvider);
    AppLogger.debug(
        'ServerStats: refreshAllSsh - ${sessions.length} sessions total');

    final futures = <Future<void>>[];
    for (final entry in sessions.entries) {
      final sessionState = entry.value;
      if (sessionState.status != SessionStatus.connected) continue;
      if (sessionState.session == null) continue;

      final shell = sessionState.session!.shell;
      if (shell is! SshService) continue;

      final connectionId = sessionState.connectionId;
      if (connectionId == null) continue;

      // Skip if we already got Prometheus data for this connection recently
      final existing = state[connectionId];
      if (existing != null &&
          DateTime.now().difference(existing.collectedAt).inSeconds < 10) {
        continue;
      }

      futures.add(_collectSshStats(connectionId, shell));
    }

    if (futures.isEmpty) {
      AppLogger.debug('ServerStats: no eligible SSH sessions for stats');
    }
    await Future.wait(futures);
  }

  /// Refresh stats for a single connection.
  Future<void> refreshOne(String connectionId) async {
    // Try Prometheus first
    final dataSource = _ref.read(monitorDataSourceProvider);
    if (dataSource == 'prometheus') {
      final prometheus = _ref.read(prometheusServiceProvider);
      final targets = _ref.read(prometheusTargetMapProvider);
      final instance = targets[connectionId];
      if (prometheus != null && instance != null) {
        await _collectPrometheusStats(connectionId, instance, prometheus);
        return;
      }
    }

    // Fall back to SSH
    final sessions = _ref.read(activeSessionsProvider);
    for (final entry in sessions.entries) {
      final sessionState = entry.value;
      if (sessionState.connectionId != connectionId) continue;
      if (sessionState.status != SessionStatus.connected) continue;
      if (sessionState.session == null) continue;

      final shell = sessionState.session!.shell;
      if (shell is! SshService) continue;

      await _collectSshStats(connectionId, shell);
      return;
    }
  }

  /// Commit a pre-collected [stats] sample for [connectionId] through the SAME
  /// success path (state + history + cache + clear-error) the live-session SSH
  /// collector uses. Written for the agentless Server Monitor poller, which
  /// collects once and decides host health BEFORE committing - so a dead
  /// connection's all-null sample is never written over good data. Writes
  /// `source: MetricSource.ssh`. The poller only calls this for hosts WITHOUT
  /// a live terminal session, so it never double-collects one [_refreshAllSsh]
  /// already covers.
  void commitSshStats(String connectionId, ServerStats stats) {
    if (!mounted) return;
    _clearError(connectionId);
    state = {...state, connectionId: stats};
    _recordHistory(connectionId, stats);
    _saveStatsToCache();
  }

  /// Record an agentless-poller collection failure for [connectionId],
  /// mirroring the live-session error path so the host card can surface a
  /// reason (Doc-3 B5).
  void recordSshError(String connectionId, Object error) =>
      _recordError(connectionId, MetricSource.ssh, error);

  Future<void> _collectSshStats(String connectionId, SshService ssh) async {
    try {
      final stats = await ServerStatsService.getStats(ssh.client);
      AppLogger.debug(
          'ServerStats: collected for $connectionId - '
          'cpu=${stats.cpuPercent?.toStringAsFixed(1)}%, '
          'ram=${stats.ramUsedMB}/${stats.ramTotalMB}MB, '
          'disk=${stats.diskPercent?.toStringAsFixed(1)}%');
      if (mounted) {
        _clearError(connectionId);
        state = {...state, connectionId: stats};
        _recordHistory(connectionId, stats);
        _saveStatsToCache();
        // Persist a device-local history sample + refresh capability detection.
        unawaited(_ref
            .read(monitorHistoryServiceProvider)
            .record(connectionId, stats, ok: true));
      }
    } catch (e) {
      _recordError(connectionId, MetricSource.ssh, e);
      unawaited(_ref
          .read(monitorHistoryServiceProvider)
          .record(connectionId, null, ok: false));
      AppLogger.debug('SSH stats collection failed for $connectionId: $e');
    }
  }

  /// Auto-discover Prometheus targets and match them to saved connections.
  Future<int> discoverPrometheusTargets() async {
    final prometheus = _ref.read(prometheusServiceProvider);
    if (prometheus == null) return 0;

    try {
      final targets = await prometheus.discoverTargets();
      if (targets.isEmpty) return 0;

      AppLogger.debug(
          'Prometheus: discovered ${targets.length} targets: '
          '${targets.map((t) => t.instance).join(", ")}');

      // Auto-match targets to saved connections by hostname/IP/label
      final connectionsAsync = _ref.read(connectionsWithDetailsProvider);
      final connections = connectionsAsync.valueOrNull ?? [];
      if (connections.isNotEmpty) {
        final sshConnections = connections
            .where((c) => c.connection.protocol != 'localShell')
            .toList();
        _smartMatchTargets(targets, sshConnections);
      }

      return targets.length;
    } catch (e) {
      AppLogger.debug('Prometheus discovery failed: $e');
      return 0;
    }
  }

  /// Smart-match Prometheus targets to saved connections.
  ///
  /// Matching strategies (in priority order):
  /// 1. Exact IP match (connection host == target instance host)
  /// 2. Connection label matches target instance (e.g. label "db-primary" == instance "db-primary")
  /// 3. Connection label matches target job name
  /// 4. Connection host/label contained in target instance or vice versa
  /// 5. Target "nodename" label from node_uname_info matches connection
  ///
  /// Only matches targets that have node_exporter-style metrics (job containing
  /// "node" or ports 9100, 9090 are preferred over random exporters).
  void _smartMatchTargets(
      List<PrometheusTarget> targets,
      List<ConnectionWithDetails> connections) {
    final mapping = <String, String>{};

    // Pre-process targets: extract clean hostname, categorize by likely type
    final nodeTargets = <PrometheusTarget>[];
    final otherTargets = <PrometheusTarget>[];
    for (final t in targets) {
      final job = t.job.toLowerCase();
      final inst = t.instance.toLowerCase();
      // Prefer node_exporter targets (typically job=node or port 9100)
      if (job.contains('node') || inst.endsWith(':9100') ||
          !inst.contains(':') || inst.contains('https://')) {
        nodeTargets.add(t);
      } else {
        otherTargets.add(t);
      }
    }

    // Try matching each connection against node targets first, then others
    for (final c in connections) {
      final connHost = c.connection.host.toLowerCase();
      final connLabel = c.connection.label.toLowerCase().trim();
      String? matchedInstance;

      // Strategy 1: exact IP/host match against node targets
      for (final t in nodeTargets) {
        final instHost = _cleanInstanceHost(t.instance);
        if (instHost == connHost) {
          matchedInstance = t.instance;
          break;
        }
      }

      // Strategy 2: connection label matches target instance name
      if (matchedInstance == null && connLabel.isNotEmpty) {
        for (final t in nodeTargets) {
          final instHost = _cleanInstanceHost(t.instance);
          if (instHost == connLabel || t.instance.toLowerCase() == connLabel) {
            matchedInstance = t.instance;
            break;
          }
        }
      }

      // Strategy 3: connection label matches target job
      if (matchedInstance == null && connLabel.isNotEmpty) {
        for (final t in nodeTargets) {
          if (t.job.toLowerCase() == connLabel) {
            matchedInstance = t.instance;
            break;
          }
        }
      }

      // Strategy 4: partial / contains matching (label ↔ instance)
      if (matchedInstance == null && connLabel.isNotEmpty) {
        for (final t in nodeTargets) {
          final instHost = _cleanInstanceHost(t.instance);
          // e.g. label="DB Primary" matches instance="db-primary"
          final normalizedLabel = connLabel.replaceAll(RegExp(r'[\s_-]+'), '');
          final normalizedInst = instHost.replaceAll(RegExp(r'[\s_-]+'), '');
          if (normalizedLabel == normalizedInst ||
              normalizedInst.contains(normalizedLabel) ||
              normalizedLabel.contains(normalizedInst)) {
            matchedInstance = t.instance;
            break;
          }
        }
      }

      // Strategy 5: same as above but against all targets (not just node)
      if (matchedInstance == null) {
        for (final t in otherTargets) {
          final instHost = _cleanInstanceHost(t.instance);
          if (instHost == connHost) {
            matchedInstance = t.instance;
            break;
          }
          if (connLabel.isNotEmpty) {
            final normalizedLabel = connLabel.replaceAll(RegExp(r'[\s_-]+'), '');
            final normalizedInst = instHost.replaceAll(RegExp(r'[\s_-]+'), '');
            if (normalizedLabel == normalizedInst ||
                normalizedInst.contains(normalizedLabel) ||
                normalizedLabel.contains(normalizedInst)) {
              matchedInstance = t.instance;
              break;
            }
          }
        }
      }

      if (matchedInstance != null) {
        mapping[c.connection.id] = matchedInstance;
        AppLogger.debug(
            'Prometheus: matched "${c.connection.label.isEmpty ? c.connection.host : c.connection.label}" '
            '→ $matchedInstance');
      }
    }

    _ref.read(prometheusTargetMapProvider.notifier).state = mapping;
    AppLogger.debug(
        'Prometheus: matched ${mapping.length}/${connections.length} '
        'connections to targets');
  }

  /// Extract clean hostname from a Prometheus instance label.
  /// "192.168.10.21:9100" → "192.168.10.21"
  /// "https://traefik.example.com" → "traefik.example.com"
  /// "db-primary" → "db-primary"
  String _cleanInstanceHost(String instance) => prometheusInstanceHost(instance);

  /// Match Prometheus targets to saved connection hosts (legacy API).
  void matchTargetsToConnections(
      List<PrometheusTarget> targets,
      Map<String, String> connectionHosts) {
    final mapping = <String, String>{};

    for (final entry in connectionHosts.entries) {
      final connectionId = entry.key;
      final host = entry.value.toLowerCase();

      for (final target in targets) {
        final instanceHost = _cleanInstanceHost(target.instance);
        if (instanceHost == host) {
          mapping[connectionId] = target.instance;
          break;
        }
      }
    }

    _ref.read(prometheusTargetMapProvider.notifier).state = mapping;
    AppLogger.debug(
        'Prometheus: matched ${mapping.length} connections to targets');
  }

  /// Whether auto-refresh is currently running.
  bool get isAutoRefreshing => _refreshTimer != null;

  /// The current auto-refresh interval in seconds.
  int _refreshIntervalSeconds = 30;
  int get refreshIntervalSeconds => _refreshIntervalSeconds;

  /// Start periodic auto-refresh.
  void startAutoRefresh(int intervalSeconds) {
    stopAutoRefresh();
    _refreshIntervalSeconds = intervalSeconds;
    refreshAll();
    _refreshTimer = Timer.periodic(
      Duration(seconds: intervalSeconds),
      (_) => refreshAll(),
    );
  }

  /// Stop periodic auto-refresh.
  void stopAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  /// Clear stats for a connection (e.g. when it disconnects).
  ///
  /// Note: we do NOT clear cached stats - they remain visible with
  /// the "collected at" timestamp so the user can still see last-known values.
  void clearStats(String connectionId) {
    // Don't remove from state - keep the cached data visible.
    // The UI shows the "collected at" timestamp so users know it's stale.
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }
}

/// Convenience provider: stats for a specific connection.
final connectionStatsProvider =
    Provider.family<ServerStats?, String>((ref, connectionId) {
  final allStats = ref.watch(serverStatsProvider);
  return allStats[connectionId];
});

/// The last collection failure for a connection (Doc-3 B5), or null when the
/// most recent collect succeeded. Watches [serverStatsProvider] so it rebuilds
/// every collect cycle (success re-commits state; failure re-emits it).
final serverStatsErrorProvider =
    Provider.family<CollectionError?, String>((ref, connectionId) {
  ref.watch(serverStatsProvider);
  return ref.read(serverStatsProvider.notifier).lastErrorFor(connectionId);
});

/// Whether a connection has a Prometheus target match.
final hasPrometheusMatchProvider =
    Provider.family<bool, String>((ref, connectionId) {
  final targets = ref.watch(prometheusTargetMapProvider);
  return targets.containsKey(connectionId);
});

/// The host a Prometheus target's instance names, as a host of the app is
/// written: "192.168.10.21:9100" is "192.168.10.21", "https://traefik.example.com"
/// is "traefik.example.com", and "[2001:db8::1]:9100" is "2001:db8::1" (it kept
/// its brackets, and a bare IPv6 address lost its last group, so neither was
/// ever matched to its host).
String prometheusInstanceHost(String instance) {
  var s = instance.toLowerCase();
  if (s.startsWith('https://')) s = s.substring(8);
  if (s.startsWith('http://')) s = s.substring(7);
  final slash = s.indexOf('/');
  if (slash >= 0) s = s.substring(0, slash);
  final split = splitHostPort(s);
  if (split != null) return split.host;
  final colon = s.lastIndexOf(':');
  return colon > 0 ? s.substring(0, colon) : s;
}
