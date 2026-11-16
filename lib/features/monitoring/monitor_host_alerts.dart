import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/monitoring/monitor_thresholds.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitor_thresholds_provider.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/services/server_stats_service.dart';
import 'package:zestssh/utils/logger.dart';

// ══════════════════════════════════════════════════════════════════════
// A host's own alert choices, per metric (the host panel's Alert
// menu): a metric muted (never raises the host, never shown on its
// card), or snoozed (for a time, or until it is back under its limit), and
// whether a ZFS host's ARC counts as free memory. Kept on this device, as the
// thresholds are; the evaluation reads them ([resolveMonitorHost]'s
// `silenced` and `countArcAsFree`), so the cards, the "need attention" count
// and the notices all go by them.
// ══════════════════════════════════════════════════════════════════════

/// How a metric of a host is kept quiet.
enum MetricSilenceKind {
  /// Until the person turns it back on.
  mute,

  /// Until [MetricSilence.until].
  until,

  /// Until a reading finds it back under its warning limit.
  untilRecovers,
}

/// A metric of a host kept quiet: it still shows in the host's panel, in the
/// warning colour where it is over, but raises nothing.
@immutable
class MetricSilence {
  const MetricSilence(this.kind, {this.until});

  final MetricSilenceKind kind;

  /// When a [MetricSilenceKind.until] snooze ends.
  final DateTime? until;

  /// Whether it keeps the metric quiet at [now].
  bool activeAt(DateTime now) => kind != MetricSilenceKind.until || (until != null && now.isBefore(until!));

  Map<String, dynamic> toJson() => {'kind': kind.name, if (until != null) 'until': until!.millisecondsSinceEpoch};

  static MetricSilence? fromJson(Object? j) {
    if (j is! Map) return null;
    final kind = MetricSilenceKind.values.where((k) => k.name == j['kind']).firstOrNull;
    if (kind == null) return null;
    final until = j['until'];
    return MetricSilence(kind, until: until is int ? DateTime.fromMillisecondsSinceEpoch(until) : null);
  }

  @override
  bool operator ==(Object other) => other is MetricSilence && other.kind == kind && other.until == until;

  @override
  int get hashCode => Object.hash(kind, until);
}

/// One host's alert choices.
@immutable
class HostAlertPrefs {
  const HostAlertPrefs({this.silences = const {}, this.countArcAsFree = false});

  final Map<MonitorMetric, MetricSilence> silences;

  /// ZFS's ARC that can be given back counts as free memory (RAM).
  final bool countArcAsFree;

  bool get isEmpty => silences.isEmpty && !countArcAsFree;

  /// The metrics kept quiet at [now].
  Set<MonitorMetric> silencedAt(DateTime now) => {
        for (final e in silences.entries)
          if (e.value.activeAt(now)) e.key,
      };

  HostAlertPrefs copyWith({Map<MonitorMetric, MetricSilence>? silences, bool? countArcAsFree}) =>
      HostAlertPrefs(silences: silences ?? this.silences, countArcAsFree: countArcAsFree ?? this.countArcAsFree);

  Map<String, dynamic> toJson() => {
        'silences': {for (final e in silences.entries) e.key.name: e.value.toJson()},
        if (countArcAsFree) 'arcFree': true,
      };

  static HostAlertPrefs fromJson(Object? j) {
    if (j is! Map) return const HostAlertPrefs();
    final out = <MonitorMetric, MetricSilence>{};
    final raw = j['silences'];
    if (raw is Map) {
      for (final m in MonitorMetric.values) {
        final s = MetricSilence.fromJson(raw[m.name]);
        if (s != null) out[m] = s;
      }
    }
    return HostAlertPrefs(silences: out, countArcAsFree: j['arcFree'] == true);
  }
}

/// The value of [metric] in [stats] as the evaluation reads it, or null.
double? metricValueIn(ServerStats stats, MonitorMetric metric, {bool countArcAsFree = false}) => switch (metric) {
      MonitorMetric.cpu => stats.cpuPercent,
      MonitorMetric.ram => stats.ramPercentWith(arcAsFree: countArcAsFree),
      MonitorMetric.disk => stats.diskPercent,
      MonitorMetric.swap => stats.swapPercent,
      MonitorMetric.temp => stats.tempC,
      MonitorMetric.latency => stats.pingMs?.toDouble(),
    };

/// Every host's alert choices, by connection id; a host with none is absent.
final hostAlertPrefsProvider = StateNotifierProvider<HostAlertPrefsNotifier, Map<String, HostAlertPrefs>>(
  (ref) => HostAlertPrefsNotifier(ref),
);

class HostAlertPrefsNotifier extends StateNotifier<Map<String, HostAlertPrefs>> {
  HostAlertPrefsNotifier(this._ref) : super(const {}) {
    _load();
    // A snooze "until it recovers" ends at the first reading that finds the
    // metric back under its warning limit; a timed one that is over goes.
    _ref.listen<Map<String, ServerStats>>(serverStatsProvider, (_, next) => _sweep(next), fireImmediately: true);
  }

  final Ref _ref;
  static const _prefsKey = 'monitor_host_alert_prefs_v1';

  /// The clock the snoozes go by. (The tests set it.)
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  void _load() {
    try {
      final raw = _ref.read(sharedPreferencesProvider).getString(_prefsKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      state = {
        for (final e in decoded.entries)
          if (e.key is String) e.key as String: HostAlertPrefs.fromJson(e.value),
      }..removeWhere((_, p) => p.isEmpty);
    } catch (e) {
      AppLogger.debug('HostAlertPrefs: could not read them: $e');
    }
  }

  void _persist() {
    try {
      _ref.read(sharedPreferencesProvider).setString(
            _prefsKey,
            jsonEncode({for (final e in state.entries) e.key: e.value.toJson()}),
          );
    } catch (e) {
      AppLogger.debug('HostAlertPrefs: could not keep them: $e');
    }
  }

  HostAlertPrefs of(String id) => state[id] ?? const HostAlertPrefs();

  void _set(String id, HostAlertPrefs prefs) {
    final next = {...state};
    if (prefs.isEmpty) {
      next.remove(id);
    } else {
      next[id] = prefs;
    }
    state = next;
    _persist();
  }

  void _silence(String id, MonitorMetric metric, MetricSilence? silence) {
    final p = of(id);
    final silences = {...p.silences};
    if (silence == null) {
      silences.remove(metric);
    } else {
      silences[metric] = silence;
    }
    _set(id, p.copyWith(silences: silences));
  }

  /// Mute [metric] of host [id]: it raises nothing and shows on no card.
  void mute(String id, MonitorMetric metric) => _silence(id, metric, const MetricSilence(MetricSilenceKind.mute));

  /// Snooze [metric] of host [id] for [length] from now.
  void snoozeFor(String id, MonitorMetric metric, Duration length) =>
      _silence(id, metric, MetricSilence(MetricSilenceKind.until, until: clock().add(length)));

  /// Snooze [metric] of host [id] until a reading finds it under its warning
  /// limit again.
  void snoozeUntilRecovers(String id, MonitorMetric metric) =>
      _silence(id, metric, const MetricSilence(MetricSilenceKind.untilRecovers));

  /// [metric] of host [id] raises the host again as it always did.
  void unsilence(String id, MonitorMetric metric) => _silence(id, metric, null);

  /// Every metric of host [id] kept quiet the same way (its right-click
  /// menu's Health: mute all, snooze all).
  void _silenceAll(String id, MetricSilence silence) =>
      _set(id, of(id).copyWith(silences: {for (final m in MonitorMetric.values) m: silence}));

  void muteAll(String id) => _silenceAll(id, const MetricSilence(MetricSilenceKind.mute));

  void snoozeAllFor(String id, Duration length) =>
      _silenceAll(id, MetricSilence(MetricSilenceKind.until, until: clock().add(length)));

  void snoozeAllUntilRecovers(String id) => _silenceAll(id, const MetricSilence(MetricSilenceKind.untilRecovers));

  /// Whether ZFS's ARC counts as free memory on host [id].
  void setCountArcAsFree(String id, bool on) => _set(id, of(id).copyWith(countArcAsFree: on));

  void _sweep(Map<String, ServerStats> stats) {
    if (state.isEmpty) return;
    final now = clock();
    final config = _ref.read(monitorThresholdsProvider);
    final ended = <(String, MonitorMetric, MetricSilence)>[];
    for (final e in state.entries) {
      for (final s in e.value.silences.entries) {
        if (s.value.kind == MetricSilenceKind.until && !s.value.activeAt(now)) {
          ended.add((e.key, s.key, s.value));
        } else if (s.value.kind == MetricSilenceKind.untilRecovers) {
          final reading = stats[e.key];
          final v = reading == null ? null : metricValueIn(reading, s.key, countArcAsFree: e.value.countArcAsFree);
          if (v != null && v < config.resolveFor(e.key)[s.key]!.warn) ended.add((e.key, s.key, s.value));
        }
      }
    }
    if (ended.isEmpty) return;
    // Out of the listener's own change, as a provider is never changed while
    // another is being worked out; a silence changed since is left as it is.
    Future.microtask(() {
      if (!mounted) return;
      for (final (id, metric, silence) in ended) {
        if (of(id).silences[metric] == silence) _silence(id, metric, null);
      }
    });
  }
}
