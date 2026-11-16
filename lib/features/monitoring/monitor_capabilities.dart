import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/services/server_stats_service.dart';
import 'package:zestssh/utils/logger.dart';

/// Which optional metrics a host is known to be able to report (Server Monitor
/// §3.4). Detected automatically on the first successful check and cached per
/// host; there is deliberately NO manual per-host visibility toggle. Metrics a
/// host can't report render `N/A`.
///
/// This is a device-local observation cache, so it is persisted in
/// SharedPreferences (via [MonitorCapabilityStore]), not the synced database.
class MonitorCapabilities {
  /// Stable metric keys.
  static const String kSwap = 'swap';
  static const String kLoad = 'load';
  static const String kTemp = 'temp';
  static const String kPing = 'ping';
  static const String kUptime = 'uptime';
  static const String kFilesystems = 'filesystems';
  static const String kInodes = 'inodes';
  static const String kUpdates = 'updates';
  static const String kFailedUnits = 'failedUnits';
  static const String kProcesses = 'processes';
  static const String kNetIo = 'netIo';
  static const String kDiskIo = 'diskIo';

  /// The set of metric keys this host has reported at least once.
  final Set<String> metrics;

  /// When detection last (re)ran, or null if never detected.
  final DateTime? detectedAt;

  /// Whether the most recent recorded check succeeded. Used to decide when to
  /// re-run detection (a success after a failure re-derives capabilities so a
  /// host that gains a capability picks it up).
  final bool lastCheckOk;

  const MonitorCapabilities({
    this.metrics = const {},
    this.detectedAt,
    this.lastCheckOk = false,
  });

  /// Whether detection has ever produced a result for this host.
  bool get isDetected => detectedAt != null;

  bool can(String metric) => metrics.contains(metric);

  /// Derive the reportable-metric set from a freshly collected sample: a metric
  /// is "capable" when the host returned a non-null value for it.
  static Set<String> deriveFrom(ServerStats s) {
    final caps = <String>{};
    if (s.swapPercent != null) caps.add(kSwap);
    if (s.load1 != null) caps.add(kLoad);
    if (s.tempC != null) caps.add(kTemp);
    if (s.pingMs != null) caps.add(kPing);
    if (s.uptimeSeconds != null) caps.add(kUptime);
    if (s.filesystems.isNotEmpty) caps.add(kFilesystems);
    if (s.inodesRootPercent != null) caps.add(kInodes);
    if (s.updatesTotal != null) caps.add(kUpdates);
    if (s.failedUnits != null) caps.add(kFailedUnits);
    if (s.processesTotal != null) caps.add(kProcesses);
    if (s.netRxBytesPerSec != null || s.netTxBytesPerSec != null) {
      caps.add(kNetIo);
    }
    if (s.diskReadBytesPerSec != null || s.diskWriteBytesPerSec != null) {
      caps.add(kDiskIo);
    }
    return caps;
  }
}

/// Persists [MonitorCapabilities] per connection in SharedPreferences, keyed by
/// connectionId. Device-local by design - never synced.
class MonitorCapabilityStore {
  MonitorCapabilityStore(this._prefs);

  final SharedPreferences _prefs;

  static const _prefsKey = 'monitor_capabilities_v1';

  Map<String, dynamic> _readAll() {
    final raw = _prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (e) {
      AppLogger.debug('MonitorCapabilities: failed to decode cache: $e');
    }
    return {};
  }

  Future<void> _writeAll(Map<String, dynamic> all) async {
    try {
      await _prefs.setString(_prefsKey, jsonEncode(all));
    } catch (e) {
      AppLogger.debug('MonitorCapabilities: failed to persist cache: $e');
    }
  }

  /// Cached capabilities for [connectionId] (empty/undetected if none yet).
  MonitorCapabilities getFor(String connectionId) {
    final entry = _readAll()[connectionId];
    if (entry is! Map) return const MonitorCapabilities();
    final metrics = (entry['metrics'] as List?)
            ?.map((e) => e.toString())
            .toSet() ??
        <String>{};
    final detectedMs = entry['detectedAt'];
    return MonitorCapabilities(
      metrics: metrics,
      detectedAt: detectedMs is int
          ? DateTime.fromMillisecondsSinceEpoch(detectedMs)
          : null,
      lastCheckOk: entry['lastCheckOk'] == true,
    );
  }

  /// Fold a completed check into the cache.
  ///
  /// Detection (re)runs on the FIRST successful check and again on any success
  /// that follows a failure; otherwise the cached metric set is preserved. A
  /// failure only flips [MonitorCapabilities.lastCheckOk] so the next success
  /// re-detects.
  Future<void> recordCheck(
    String connectionId,
    ServerStats? stats, {
    required bool ok,
  }) async {
    final all = _readAll();
    final existing = all[connectionId] is Map
        ? Map<String, dynamic>.from(all[connectionId] as Map)
        : null;
    final hasCaps = existing != null && existing['metrics'] is List;
    final prevOk = existing?['lastCheckOk'] == true;

    Map<String, dynamic> updated;
    if (ok && stats != null && (!hasCaps || !prevOk)) {
      // First success, or success after a failure → (re)derive.
      updated = {
        'metrics': MonitorCapabilities.deriveFrom(stats).toList(),
        'detectedAt': DateTime.now().millisecondsSinceEpoch,
        'lastCheckOk': true,
      };
    } else if (ok) {
      updated = {
        'metrics': (existing?['metrics'] as List?) ?? const <String>[],
        'detectedAt': existing?['detectedAt'],
        'lastCheckOk': true,
      };
    } else {
      updated = {
        'metrics': (existing?['metrics'] as List?) ?? const <String>[],
        'detectedAt': existing?['detectedAt'],
        'lastCheckOk': false,
      };
    }

    all[connectionId] = updated;
    await _writeAll(all);
  }

  /// Drop cached capabilities for a host (e.g. connection deleted).
  Future<void> clearFor(String connectionId) async {
    final all = _readAll();
    if (all.remove(connectionId) != null) {
      await _writeAll(all);
    }
  }
}
