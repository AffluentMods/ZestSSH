// ══════════════════════════════════════════════════════════════════════
// Server-Monitor threshold configuration model (§2)
//
// A pure, serializable model for the per-metric warn/crit bands, the debounce
// "change after N readings" control, the check interval, and the per-host
// overrides. Persistence lives in `monitor_thresholds_provider.dart`; the
// status computation reads the resolved thresholds through [resolveFor].
// ══════════════════════════════════════════════════════════════════════

/// The metrics the Server-Monitor thresholds cover. CPU / RAM / Swap / Disk are
/// 0-100 percentage gauges; latency is a raw round-trip in milliseconds; temp is
/// a °C reading (band runs to ~120°C).
enum MonitorMetric { cpu, ram, disk, latency, swap, temp }

extension MonitorMetricInfo on MonitorMetric {
  /// A percentage gauge (0-100). Latency (ms) and temp (°C) are NOT percentages.
  bool get isPercent =>
      this != MonitorMetric.latency && this != MonitorMetric.temp;

  /// Upper bound of the metric's threshold band. Percentage gauges top out at
  /// 100%; latency's band runs to 1000ms so the default 400ms crit sits
  /// sensibly; temp's band runs to 120°C so 70/85 sit in the lower-middle.
  double get bandMax => switch (this) {
        MonitorMetric.latency => 1000,
        MonitorMetric.temp => 120,
        _ => 100,
      };

  /// Smallest step used by the numeric inputs / drag snapping.
  double get step => this == MonitorMetric.latency ? 10 : 1;

  /// Unit suffix for display ("%", "ms", or "°C").
  String get unit => switch (this) {
        MonitorMetric.latency => 'ms',
        MonitorMetric.temp => '°C',
        _ => '%',
      };
}

/// UI display order for the metric bands / gauge columns: the two
/// new metrics interleave with the originals (CPU, RAM, Swap, Disk, Temp,
/// Latency) rather than trailing the enum's declaration order.
const List<MonitorMetric> kMonitorMetricDisplayOrder = [
  MonitorMetric.cpu,
  MonitorMetric.ram,
  MonitorMetric.swap,
  MonitorMetric.disk,
  MonitorMetric.temp,
  MonitorMetric.latency,
];

/// A single metric's warn + crit thresholds. Gauges are percentages (0-100);
/// latency is milliseconds. Invariant enforced by callers: `warn < crit`.
class MetricThreshold {
  final double warn;
  final double crit;

  const MetricThreshold(this.warn, this.crit);

  MetricThreshold copyWith({double? warn, double? crit}) =>
      MetricThreshold(warn ?? this.warn, crit ?? this.crit);

  Map<String, dynamic> toJson() => {'warn': warn, 'crit': crit};

  factory MetricThreshold.fromJson(Map<String, dynamic> j) => MetricThreshold(
        (j['warn'] as num).toDouble(),
        (j['crit'] as num).toDouble(),
      );

  @override
  bool operator ==(Object other) =>
      other is MetricThreshold && other.warn == warn && other.crit == crit;

  @override
  int get hashCode => Object.hash(warn, crit);
}

/// Default global thresholds (spec §2.1 / §4): CPU 70/85, RAM 70/85, Disk 80/90,
/// Latency 150/400ms, Swap 60/85, Temp 70/85°C.
const Map<MonitorMetric, MetricThreshold> kDefaultThresholds = {
  MonitorMetric.cpu: MetricThreshold(70, 85),
  MonitorMetric.ram: MetricThreshold(70, 85),
  MonitorMetric.disk: MetricThreshold(80, 90),
  MonitorMetric.latency: MetricThreshold(150, 400),
  MonitorMetric.swap: MetricThreshold(60, 85),
  MonitorMetric.temp: MetricThreshold(70, 85),
};

/// Default debounce: a host must breach on this many consecutive checks before
/// its status flips (spec §2.3).
const int kDefaultDebounceReadings = 2;

/// Default background check interval in minutes (spec §2.4).
const int kDefaultCheckIntervalMinutes = 5;

/// The global threshold set + the two "Checking" controls (debounce + check
/// interval). Immutable; edits go through [copyWith].
class MonitorThresholds {
  final Map<MonitorMetric, MetricThreshold> metrics;
  final int debounceReadings;
  final int checkIntervalMinutes;

  const MonitorThresholds({
    required this.metrics,
    this.debounceReadings = kDefaultDebounceReadings,
    this.checkIntervalMinutes = kDefaultCheckIntervalMinutes,
  });

  static const MonitorThresholds defaults = MonitorThresholds(
    metrics: kDefaultThresholds,
  );

  /// The warn/crit for [m], falling back to the built-in default so a missing
  /// key never crashes the status calc.
  MetricThreshold forMetric(MonitorMetric m) =>
      metrics[m] ?? kDefaultThresholds[m]!;

  MonitorThresholds copyWith({
    Map<MonitorMetric, MetricThreshold>? metrics,
    int? debounceReadings,
    int? checkIntervalMinutes,
  }) =>
      MonitorThresholds(
        metrics: metrics ?? this.metrics,
        debounceReadings: debounceReadings ?? this.debounceReadings,
        checkIntervalMinutes: checkIntervalMinutes ?? this.checkIntervalMinutes,
      );

  /// Return a copy with a single metric's threshold replaced.
  MonitorThresholds withMetric(MonitorMetric m, MetricThreshold t) {
    final next = {...metrics, m: t};
    return copyWith(metrics: next);
  }

  Map<String, dynamic> toJson() => {
        'metrics': {
          for (final e in metrics.entries) e.key.name: e.value.toJson(),
        },
        'debounceReadings': debounceReadings,
        'checkIntervalMinutes': checkIntervalMinutes,
      };

  factory MonitorThresholds.fromJson(Map<String, dynamic> j) {
    return MonitorThresholds(
      metrics: _metricsFromJson(j['metrics']),
      debounceReadings:
          (j['debounceReadings'] as num?)?.toInt() ?? kDefaultDebounceReadings,
      checkIntervalMinutes: (j['checkIntervalMinutes'] as num?)?.toInt() ??
          kDefaultCheckIntervalMinutes,
    );
  }
}

/// A per-host override (spec §2.5): a full set of metric thresholds plus a
/// free-text reason. Debounce / check-interval stay global - only the bands
/// can be overridden per host.
class HostThresholdOverride {
  final String connectionId;
  final Map<MonitorMetric, MetricThreshold> metrics;
  final String reason;

  const HostThresholdOverride({
    required this.connectionId,
    required this.metrics,
    this.reason = '',
  });

  HostThresholdOverride copyWith({
    Map<MonitorMetric, MetricThreshold>? metrics,
    String? reason,
  }) =>
      HostThresholdOverride(
        connectionId: connectionId,
        metrics: metrics ?? this.metrics,
        reason: reason ?? this.reason,
      );

  MetricThreshold forMetric(MonitorMetric m) =>
      metrics[m] ?? kDefaultThresholds[m]!;

  Map<String, dynamic> toJson() => {
        'connectionId': connectionId,
        'metrics': {
          for (final e in metrics.entries) e.key.name: e.value.toJson(),
        },
        'reason': reason,
      };

  factory HostThresholdOverride.fromJson(Map<String, dynamic> j) =>
      HostThresholdOverride(
        connectionId: j['connectionId'] as String,
        metrics: _metricsFromJson(j['metrics']),
        reason: (j['reason'] as String?) ?? '',
      );
}

/// The whole persisted threshold configuration: the global set + the list of
/// per-host overrides.
class MonitorThresholdConfig {
  final MonitorThresholds global;
  final List<HostThresholdOverride> overrides;

  const MonitorThresholdConfig({
    required this.global,
    this.overrides = const [],
  });

  static const MonitorThresholdConfig defaults = MonitorThresholdConfig(
    global: MonitorThresholds.defaults,
  );

  HostThresholdOverride? overrideFor(String connectionId) {
    for (final o in overrides) {
      if (o.connectionId == connectionId) return o;
    }
    return null;
  }

  /// The effective warn/crit for every metric on [connectionId] - the host's
  /// override where one exists, otherwise the global set (spec §2.5).
  Map<MonitorMetric, MetricThreshold> resolveFor(String connectionId) {
    final o = overrideFor(connectionId);
    return {
      for (final m in MonitorMetric.values)
        m: o?.metrics[m] ?? global.forMetric(m),
    };
  }

  MonitorThresholdConfig copyWith({
    MonitorThresholds? global,
    List<HostThresholdOverride>? overrides,
  }) =>
      MonitorThresholdConfig(
        global: global ?? this.global,
        overrides: overrides ?? this.overrides,
      );

  Map<String, dynamic> toJson() => {
        'global': global.toJson(),
        'overrides': overrides.map((o) => o.toJson()).toList(),
      };

  factory MonitorThresholdConfig.fromJson(Map<String, dynamic> j) {
    final rawOverrides = j['overrides'];
    return MonitorThresholdConfig(
      global: MonitorThresholds.fromJson(
          (j['global'] as Map).cast<String, dynamic>()),
      overrides: rawOverrides is List
          ? rawOverrides
              .whereType<Map>()
              .map((o) => HostThresholdOverride.fromJson(o.cast<String, dynamic>()))
              .toList()
          : const [],
    );
  }
}

/// Decode a `{metricName: {warn, crit}}` JSON map. Only metrics actually
/// present in the blob are kept - a per-host override is SPARSE, storing just
/// the metrics the user changed, so [MonitorThresholdConfig.resolveFor] falls
/// back to the current global for every untouched metric (and later fleet-wide
/// global edits keep propagating to overridden hosts). Filling absent metrics
/// with defaults here would freeze them at first-touch values.
Map<MonitorMetric, MetricThreshold> _metricsFromJson(Object? raw) {
  final out = <MonitorMetric, MetricThreshold>{};
  if (raw is Map) {
    for (final m in MonitorMetric.values) {
      final entry = raw[m.name];
      if (entry is Map) {
        out[m] = MetricThreshold.fromJson(entry.cast<String, dynamic>());
      }
    }
  }
  return out;
}
