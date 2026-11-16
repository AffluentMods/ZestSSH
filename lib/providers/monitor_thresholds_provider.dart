import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zestssh/features/monitoring/monitor_thresholds.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/utils/logger.dart';

/// Persisted Server-Monitor threshold configuration (§2). Backed by
/// SharedPreferences (no Drift migration - spec §2.6). Every edit re-emits the
/// whole [MonitorThresholdConfig] so any widget watching it re-evaluates its
/// hosts immediately with no manual refresh.
final monitorThresholdsProvider =
    StateNotifierProvider<MonitorThresholdsNotifier, MonitorThresholdConfig>(
        (ref) => MonitorThresholdsNotifier(ref));

class MonitorThresholdsNotifier extends StateNotifier<MonitorThresholdConfig> {
  MonitorThresholdsNotifier(this._ref)
      : super(MonitorThresholdConfig.defaults) {
    _load();
  }

  final Ref _ref;
  static const _prefsKey = 'monitor_threshold_config_v1';

  void _load() {
    try {
      final raw = _ref.read(sharedPreferencesProvider).getString(_prefsKey);
      if (raw != null) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        final loaded = MonitorThresholdConfig.fromJson(decoded);
        final migrated = _migrateLegacyLatency(loaded);
        state = migrated;
        // Persist once if the migration actually rewrote the stale pair.
        if (!identical(migrated, loaded)) _persist();
      }
    } catch (e) {
      AppLogger.debug('MonitorThresholds: failed to load config: $e');
    }
    // Keep the background poll interval in step with the persisted check
    // interval once the app is up (deferred so we never write another provider
    // mid-build).
    unawaited(Future.microtask(_syncPollInterval));
  }

  /// One-time migration: an early build defaulted latency to 15ms warn / 40ms
  /// crit, which flags anything not on the LAN. Users who never customised
  /// latency still carry that stale pair in their persisted config, where a
  /// code default change can't reach it. Bump exactly (15, 40) to the current
  /// (150, 400) default; leave any other (customised) latency untouched.
  MonitorThresholdConfig _migrateLegacyLatency(MonitorThresholdConfig c) {
    final lat = c.global.forMetric(MonitorMetric.latency);
    if (lat.warn == 15 && lat.crit == 40) {
      return c.copyWith(
        global: c.global.withMetric(
          MonitorMetric.latency,
          const MetricThreshold(150, 400),
        ),
      );
    }
    return c;
  }

  void _persist() {
    try {
      _ref
          .read(sharedPreferencesProvider)
          .setString(_prefsKey, jsonEncode(state.toJson()));
    } catch (e) {
      AppLogger.debug('MonitorThresholds: failed to persist config: $e');
    }
  }

  /// Push the check interval (minutes) into the poller's seconds-based
  /// interval provider so background polling honours it.
  void _syncPollInterval() {
    if (!mounted) return;
    final secs = (state.global.checkIntervalMinutes * 60).clamp(5, 3600);
    final notifier = _ref.read(monitorRefreshIntervalProvider.notifier);
    if (notifier.state != secs) notifier.state = secs;
  }

  // ── Global metric bands ────────────────────────────────────────────

  /// Replace a global metric's warn/crit, keeping `warn < crit`.
  void setGlobalMetric(MonitorMetric metric, MetricThreshold t) {
    state = state.copyWith(global: state.global.withMetric(metric, _sane(metric, t)));
    _persist();
  }

  // ── Checking controls ──────────────────────────────────────────────

  /// Set the debounce "change after N readings" (spec §2.3), N ≥ 1.
  void setDebounceReadings(int n) {
    final clamped = n.clamp(1, 10);
    state = state.copyWith(
        global: state.global.copyWith(debounceReadings: clamped));
    _persist();
  }

  /// Set the background check interval in minutes (spec §2.4), and mirror it to
  /// the live poll timer.
  void setCheckIntervalMinutes(int minutes) {
    final clamped = minutes.clamp(1, 60);
    state = state.copyWith(
        global: state.global.copyWith(checkIntervalMinutes: clamped));
    _persist();
    _syncPollInterval();
  }

  // ── Per-host overrides ─────────────────────────────────────────────

  /// Create or replace the override for [connectionId]. Overrides are stored
  /// SPARSELY: only the metrics actually passed (or previously edited) are
  /// kept, so `resolveFor` falls back to the LIVE global for every untouched
  /// metric and later fleet-wide global edits keep reaching this host. A new
  /// override with no metrics starts empty (all metrics inherit the global).
  void upsertOverride(
    String connectionId, {
    Map<MonitorMetric, MetricThreshold>? metrics,
    String? reason,
  }) {
    final existing = state.overrideFor(connectionId);
    final next = HostThresholdOverride(
      connectionId: connectionId,
      metrics: metrics ??
          existing?.metrics ??
          const <MonitorMetric, MetricThreshold>{},
      reason: reason ?? existing?.reason ?? '',
    );
    final list = [
      for (final o in state.overrides)
        if (o.connectionId != connectionId) o,
      next,
    ];
    state = state.copyWith(overrides: list);
    _persist();
  }

  /// Update a single metric on an existing (or freshly-seeded) override.
  void setOverrideMetric(
      String connectionId, MonitorMetric metric, MetricThreshold t) {
    final existing = state.overrideFor(connectionId);
    // Build from the existing SPARSE map (not seeded from global), so only the
    // metrics the user actually edits are stored; untouched metrics keep
    // inheriting the live global via resolveFor.
    final base =
        existing?.metrics ?? const <MonitorMetric, MetricThreshold>{};
    upsertOverride(
      connectionId,
      metrics: {...base, metric: _sane(metric, t)},
      reason: existing?.reason,
    );
  }

  void setOverrideReason(String connectionId, String reason) {
    upsertOverride(connectionId, reason: reason);
  }

  void removeOverride(String connectionId) {
    if (state.overrideFor(connectionId) == null) return;
    state = state.copyWith(overrides: [
      for (final o in state.overrides)
        if (o.connectionId != connectionId) o,
    ]);
    _persist();
  }

  /// Puts the defaults as they came back: their limits, and how often hosts are
  /// checked. The limits hosts have of their own stay, those of a host deleted
  /// or of another space too, none of which the dialog can show to set again.
  void resetDefaults() {
    state = state.copyWith(global: MonitorThresholdConfig.defaults.global);
    _persist();
    _syncPollInterval();
  }

  /// Replace the whole configuration in one shot. Used to revert to a snapshot
  /// captured when the thresholds dialog opened, so Cancel / dismiss (anything
  /// but an explicit Done) undoes the live edits made while it was open.
  void restore(MonitorThresholdConfig config) {
    state = config;
    _persist();
    _syncPollInterval();
  }

  /// Keep warn strictly below crit within the metric's band (the Warn handle
  /// can never cross the Crit handle - spec §2.1).
  MetricThreshold _sane(MonitorMetric metric, MetricThreshold t) {
    final maxV = metric.bandMax;
    final crit = t.crit.clamp(metric.step, maxV).toDouble();
    var warn = t.warn.clamp(0.0, maxV).toDouble();
    if (warn >= crit) warn = (crit - metric.step).clamp(0.0, maxV).toDouble();
    return MetricThreshold(warn, crit);
  }
}
