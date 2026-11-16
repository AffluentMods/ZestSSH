import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/monitoring/monitor_evaluation.dart';
import 'package:zestssh/features/monitoring/monitor_host_alerts.dart';
import 'package:zestssh/features/monitoring/monitor_thresholds.dart';
import 'package:zestssh/services/server_stats_service.dart';

/// A host's own alert choices in the evaluation every screen shares:
/// a metric muted or snoozed raises nothing, though it is still
/// read as over; ZFS's ARC counted as free memory where the host says so.
void main() {
  final now = DateTime(2026, 10, 22, 12);
  final stats = ServerStats(
    cpuPercent: 14,
    ramUsedMB: 890,
    ramTotalMB: 1000,
    diskPercent: 40,
    collectedAt: now,
    source: MetricSource.ssh,
    zfsArcFreeableMB: 500,
  );

  MonitorHostView view({Set<MonitorMetric> silenced = const {}, bool arc = false}) => resolveMonitorHost(
        history: [stats],
        stats: stats,
        health: null,
        monitor: null,
        hasActiveSession: false,
        thresholds: {for (final m in MonitorMetric.values) m: kDefaultThresholds[m]!},
        debounceReadings: 1,
        staleAfter: const Duration(hours: 1),
        now: now,
        silenced: silenced,
        countArcAsFree: arc,
      );

  test('a metric over its limit raises the host', () {
    final v = view();
    expect(v.bucket, MonitorBucket.critical);
    expect(v.breachedMetric, MonitorMetric.ram);
  });

  test('kept quiet, it raises nothing, but is still read as over', () {
    final v = view(silenced: {MonitorMetric.ram});
    expect(v.bucket, MonitorBucket.healthy);
    expect(v.overLimit, isEmpty);
    final ram = v.metricEval(MonitorMetric.ram)!;
    expect(ram.severity, MetricSeverity.critical, reason: 'the panel still draws it over');
    expect(ram.silenced, isTrue);
    expect(ram.raised, MetricSeverity.healthy);
  });

  test('ZFS ARC counted as free: memory without what can be given back', () {
    final v = view(arc: true);
    expect(v.metricEval(MonitorMetric.ram)!.value, closeTo(39, 0.01));
    expect(v.bucket, MonitorBucket.healthy);
  });

  group('the choices themselves', () {
    test('a timed snooze ends at its time; a mute and "until it recovers" do not end by themselves', () {
      final until = MetricSilence(MetricSilenceKind.until, until: now.add(const Duration(hours: 1)));
      expect(until.activeAt(now), isTrue);
      expect(until.activeAt(now.add(const Duration(hours: 1, seconds: 1))), isFalse);
      expect(const MetricSilence(MetricSilenceKind.mute).activeAt(now.add(const Duration(days: 999))), isTrue);
      expect(const MetricSilence(MetricSilenceKind.untilRecovers).activeAt(now.add(const Duration(days: 9))), isTrue);
    });

    test('kept as they were set', () {
      final p = HostAlertPrefs(
        silences: {
          MonitorMetric.ram: const MetricSilence(MetricSilenceKind.mute),
          MonitorMetric.disk: MetricSilence(MetricSilenceKind.until, until: now),
          MonitorMetric.cpu: const MetricSilence(MetricSilenceKind.untilRecovers),
        },
        countArcAsFree: true,
      );
      final back = HostAlertPrefs.fromJson(p.toJson());
      expect(back.silences, p.silences);
      expect(back.countArcAsFree, isTrue);
      expect(HostAlertPrefs.fromJson(null).isEmpty, isTrue);
      expect(HostAlertPrefs.fromJson({'silences': {'ram': {'kind': 'nonsense'}}}).isEmpty, isTrue);
    });

    test('the value a silence that waits for recovery reads', () {
      expect(metricValueIn(stats, MonitorMetric.ram), closeTo(89, 0.01));
      expect(metricValueIn(stats, MonitorMetric.ram, countArcAsFree: true), closeTo(39, 0.01));
      expect(metricValueIn(stats, MonitorMetric.cpu), 14);
    });
  });
}
