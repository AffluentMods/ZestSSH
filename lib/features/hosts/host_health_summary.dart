import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/features/hosts/host_attention.dart';
import 'package:zestssh/features/monitoring/monitor_evaluation.dart';
import 'package:zestssh/features/monitoring/monitor_thresholds.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/changed_host_keys_provider.dart';
import 'package:zestssh/providers/connection_providers.dart';

/// What the Hosts list's Health column says of a host, from worst to best:
/// a warning or a critical (the chip its card shows), a metric over its
/// line that the person muted or snoozed, a plain reading, or nothing (a
/// host Server Monitor does not watch, or has no reading of yet).
enum HostHealthKind { none, muted, plain, warning, critical }

/// A host's health in one cell (the list view):
/// its worst metric, and how far it is towards its warning line, so the list
/// can be ordered by it.
class HostHealthSummary {
  const HostHealthSummary({
    required this.kind,
    this.metric,
    this.value,
    this.load = 0,
    this.chip,
  });

  static const none = HostHealthSummary(kind: HostHealthKind.none);

  final HostHealthKind kind;

  /// The metric the cell names (null for an unreachable host, a changed host
  /// key, or nothing to say).
  final MonitorMetric? metric;

  /// Its reading, in the metric's own unit.
  final double? value;

  /// The reading over its warning line (1 is at the line): what orders hosts
  /// of one kind.
  final double load;

  /// A warning or a critical: the chip, as the host's card draws it.
  final HostHealthChip? chip;

  /// Worse first: a critical, a warning, a plain reading, a muted one, none.
  /// A muted metric comes after the plain ones: the person asked not to be
  /// told of it.
  int get tier => switch (kind) {
        HostHealthKind.critical => 4,
        HostHealthKind.warning => 3,
        HostHealthKind.plain => 2,
        HostHealthKind.muted => 1,
        HostHealthKind.none => 0,
      };

  /// Negative where this host's health is worse than [other]'s (it is listed
  /// first in the Health order).
  int compareWorseFirst(HostHealthSummary other) {
    final byTier = other.tier.compareTo(tier);
    if (byTier != 0) return byTier;
    return other.load.compareTo(load);
  }
}

/// How far [m]'s reading is towards its warning line.
double _loadOf(MetricEval m) => m.warn > 0 ? m.value! / m.warn : m.value!;

/// The Health cell of a host whose Server Monitor view is [view] (null where
/// the monitor does not watch it). The same verdict as its card's chips and
/// the page's "need attention" count: the person's thresholds for the host,
/// and the metrics they muted or snoozed (lib/features/monitoring/
/// monitor_host_alerts.dart), which raise nothing and are said as muted. A
/// changed host key, which makes a host need attention too, is a critical.
/// Without [l10n] (where only the order is wanted) there is no [chip].
HostHealthSummary hostHealthSummary(
  MonitorHostView? view,
  AppLocalizations? l10n, {
  bool changedHostKey = false,
}) {
  if (changedHostKey) {
    return HostHealthSummary(
      kind: HostHealthKind.critical,
      load: double.maxFinite,
      chip: l10n == null
          ? null
          : HostHealthChip(label: l10n.hostKeyChangedTitle, critical: true, tooltip: l10n.hostKeyChangedTitle),
    );
  }
  if (view == null) return HostHealthSummary.none;
  HostHealthChip? chipOf() => l10n == null ? null : healthChipsFor(view, l10n).firstOrNull;

  // As [healthChipsFor] decides: a watched host that cannot be reached, then
  // a status of warning or critical with a metric that raises it.
  if (view.bucket == MonitorBucket.cantCheck && view.cantCheckReason == CantCheckReason.unreachable) {
    return HostHealthSummary(kind: HostHealthKind.critical, load: double.maxFinite, chip: chipOf());
  }
  final over = view.overLimit;
  if ((view.bucket == MonitorBucket.critical || view.bucket == MonitorBucket.warning) && over.isNotEmpty) {
    final worst = over.first;
    return HostHealthSummary(
      kind: worst.severity == MetricSeverity.critical ? HostHealthKind.critical : HostHealthKind.warning,
      metric: worst.metric,
      value: worst.value,
      load: _loadOf(worst),
      chip: chipOf(),
    );
  }
  final readings = [for (final m in view.metrics) if (m.available) m];
  if (readings.isEmpty) return HostHealthSummary.none;
  // A metric over its line that the person keeps quiet: said, muted.
  final quiet = [for (final m in readings) if (m.silenced && m.severity != MetricSeverity.healthy) m]
    ..sort((a, b) {
      final bySeverity = b.severity.rank.compareTo(a.severity.rank);
      return bySeverity != 0 ? bySeverity : _loadOf(b).compareTo(_loadOf(a));
    });
  if (quiet.isNotEmpty) {
    final m = quiet.first;
    return HostHealthSummary(kind: HostHealthKind.muted, metric: m.metric, value: m.value, load: _loadOf(m));
  }
  // Otherwise the reading nearest its warning line.
  final plain = readings.reduce((a, b) => _loadOf(b) > _loadOf(a) ? b : a);
  return HostHealthSummary(kind: HostHealthKind.plain, metric: plain.metric, value: plain.value, load: _loadOf(plain));
}

/// Every host's health, for ordering by it where no cell is drawn (the host
/// drawer, the SFTP picker): keyed by connection id, hosts with nothing to
/// say absent.
final hostHealthSummariesProvider = Provider<Map<String, HostHealthSummary>>((ref) {
  final views = ref.watch(monitoredHostViewsProvider);
  final changed = ref.watch(changedHostKeysProvider);
  final hosts = ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
  final out = <String, HostHealthSummary>{};
  for (final c in hosts) {
    final s = hostHealthSummary(
      views[c.connection.id],
      null,
      changedHostKey: changed.contains('${normalizeKnownHost(c.connection.host)}:${c.connection.port}'),
    );
    if (s.kind != HostHealthKind.none) out[c.connection.id] = s;
  }
  return out;
});
