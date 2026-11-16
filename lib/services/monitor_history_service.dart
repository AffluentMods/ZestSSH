import 'dart:async';

import 'package:drift/drift.dart';
import 'package:zestssh/database/daos/monitor_samples_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/monitoring/monitor_capabilities.dart';
import 'package:zestssh/services/server_stats_service.dart';
import 'package:zestssh/utils/logger.dart';

/// Writes one [MonitorSamples] row per completed Server Monitor check, keeps
/// capability detection current, and runs retention (downsample + discard +
/// backstop cap) opportunistically.
///
/// History is device-local and MUST NOT be synced. Retention (§4):
/// - Full-resolution rows kept for [fullResolutionWindow] (48h).
/// - Then collapsed to [downsampleBucket] (15-minute) averages out to
///   [retentionWindow] (30 days).
/// - Then discarded.
/// - A per-host [perHostRowCap] backstop prunes oldest first.
class MonitorHistoryService {
  MonitorHistoryService(this._dao, this._capabilities);

  final MonitorSamplesDao _dao;
  final MonitorCapabilityStore _capabilities;

  static const Duration fullResolutionWindow = Duration(hours: 48);
  static const Duration downsampleBucket = Duration(minutes: 15);
  static const Duration retentionWindow = Duration(days: 30);

  /// Backstop per-host row cap. 48h at a 60s cadence is ~2880 rows; the cap
  /// sits comfortably above that so it only triggers under abnormal churn.
  static const int perHostRowCap = 6000;

  /// Minimum spacing between opportunistic maintenance passes.
  static const Duration _maintenanceInterval = Duration(minutes: 15);

  DateTime? _lastMaintenance;
  bool _maintenanceRunning = false;

  /// Record one completed check for [connectionId].
  ///
  /// On success pass [ok] = true with the collected [stats]; on failure pass
  /// [ok] = false (stats may be null) - a failure row is written with a null
  /// metric set so the chart can draw a truthful gap. Set [updateCapabilities]
  /// to false for non-SSH sources (e.g. Prometheus) so capability detection
  /// stays SSH-authoritative.
  Future<void> record(
    String connectionId,
    ServerStats? stats, {
    required bool ok,
    bool updateCapabilities = true,
  }) async {
    final metrics = ok ? stats : null;
    try {
      await _dao.insertSample(MonitorSamplesCompanion.insert(
        connectionId: connectionId,
        capturedAt: DateTime.now(),
        ok: Value(ok),
        cpuPercent: Value(metrics?.cpuPercent),
        ramPercent: Value(metrics?.ramPercent),
        swapPercent: Value(metrics?.swapPercent),
        diskPercent: Value(metrics?.diskPercent),
        load1: Value(metrics?.load1),
        load5: Value(metrics?.load5),
        load15: Value(metrics?.load15),
        tempC: Value(metrics?.tempC),
        pingMs: Value(metrics?.pingMs),
      ));
    } catch (e) {
      AppLogger.debug('MonitorHistory: insert failed for $connectionId: $e');
    }

    if (updateCapabilities) {
      try {
        await _capabilities.recordCheck(connectionId, stats, ok: ok);
      } catch (e) {
        AppLogger.debug('MonitorHistory: capability update failed: $e');
      }
    }

    unawaited(_maybeRunMaintenance());
  }

  /// Run retention if enough time has elapsed since the last pass. Cheap on the
  /// common path (a couple of timestamp comparisons).
  Future<void> _maybeRunMaintenance() async {
    if (_maintenanceRunning) return;
    final now = DateTime.now();
    if (_lastMaintenance != null &&
        now.difference(_lastMaintenance!) < _maintenanceInterval) {
      return;
    }
    _lastMaintenance = now;
    _maintenanceRunning = true;
    try {
      await runMaintenance();
    } catch (e) {
      AppLogger.debug('MonitorHistory: maintenance failed: $e');
    } finally {
      _maintenanceRunning = false;
    }
  }

  /// Run all retention steps once (also callable directly, e.g. on app start).
  Future<void> runMaintenance() async {
    final now = DateTime.now();
    // 1. Discard everything past the retention window.
    await _dao.deleteOlderThan(now.subtract(retentionWindow));
    // 2. Collapse raw rows older than the full-resolution window into buckets.
    await _downsample(now.subtract(fullResolutionWindow));
    // 3. Per-host backstop cap.
    for (final id in await _dao.distinctConnectionIds()) {
      await _dao.enforceHostCap(id, perHostRowCap);
    }
  }

  /// Aggregate raw rows older than [rawCutoff] into 15-minute buckets per host.
  /// A bucket with any successful sample averages those; a bucket of only
  /// failures becomes a single failure row so gaps survive downsampling.
  Future<void> _downsample(DateTime rawCutoff) async {
    final raw = await _dao.rawSamplesOlderThan(rawCutoff);
    if (raw.isEmpty) return;

    final bucketMs = downsampleBucket.inMilliseconds;
    final groups = <String, List<MonitorSample>>{};
    for (final s in raw) {
      final bucketStartMs =
          (s.capturedAt.millisecondsSinceEpoch ~/ bucketMs) * bucketMs;
      groups
          .putIfAbsent('${s.connectionId}@$bucketStartMs', () => [])
          .add(s);
    }

    final companions = <MonitorSamplesCompanion>[];
    for (final rows in groups.values) {
      final connId = rows.first.connectionId;
      final bucketStart = DateTime.fromMillisecondsSinceEpoch(
          (rows.first.capturedAt.millisecondsSinceEpoch ~/ bucketMs) *
              bucketMs);
      final okRows = rows.where((r) => r.ok).toList();
      if (okRows.isEmpty) {
        companions.add(MonitorSamplesCompanion.insert(
          connectionId: connId,
          capturedAt: bucketStart,
          ok: const Value(false),
          resolutionSeconds: Value(downsampleBucket.inSeconds),
        ));
      } else {
        companions.add(MonitorSamplesCompanion.insert(
          connectionId: connId,
          capturedAt: bucketStart,
          ok: const Value(true),
          resolutionSeconds: Value(downsampleBucket.inSeconds),
          cpuPercent: Value(_avg(okRows.map((r) => r.cpuPercent))),
          ramPercent: Value(_avg(okRows.map((r) => r.ramPercent))),
          swapPercent: Value(_avg(okRows.map((r) => r.swapPercent))),
          diskPercent: Value(_avg(okRows.map((r) => r.diskPercent))),
          load1: Value(_avg(okRows.map((r) => r.load1))),
          load5: Value(_avg(okRows.map((r) => r.load5))),
          load15: Value(_avg(okRows.map((r) => r.load15))),
          tempC: Value(_avg(okRows.map((r) => r.tempC))),
          pingMs: Value(_avgInt(okRows.map((r) => r.pingMs))),
        ));
      }
    }

    await _dao.insertSamples(companions);
    await _dao.deleteRawOlderThan(rawCutoff);
  }

  static double? _avg(Iterable<double?> xs) {
    final vals = xs.whereType<double>().toList();
    if (vals.isEmpty) return null;
    return vals.reduce((a, b) => a + b) / vals.length;
  }

  static int? _avgInt(Iterable<int?> xs) {
    final vals = xs.whereType<int>().toList();
    if (vals.isEmpty) return null;
    return (vals.reduce((a, b) => a + b) / vals.length).round();
  }
}
