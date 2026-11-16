import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/monitoring/monitor_evaluation.dart';
import 'package:zestssh/features/monitoring/monitor_host_alerts.dart';
import 'package:zestssh/features/monitoring/monitor_state_ui.dart';
import 'package:zestssh/features/monitoring/monitor_status.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/providers/monitor_thresholds_provider.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';

/// Server Monitor's view of every host it watches, keyed by connection id.
///
/// The same evaluation the monitor table, its alerts and the tray use (the
/// person's thresholds, debounce and staleness), so the Hosts page's health
/// chips and its "need attention" count always agree with Server Monitor.
/// Hosts it does not watch are absent: the Hosts page claims nothing about
/// them.
final monitoredHostViewsProvider =
    Provider<Map<String, MonitorHostView>>((ref) {
  final monitored = ref.watch(monitoredConnectionsProvider).valueOrNull;
  if (monitored == null || monitored.isEmpty) return const {};
  final stats = ref.watch(serverStatsProvider);
  final health = ref.watch(connectionHealthProvider);
  final monitor = ref.watch(agentlessMonitorPollerProvider);
  final sessions = ref.watch(activeSessionsProvider);
  final config = ref.watch(monitorThresholdsProvider);
  final statsNotifier = ref.read(serverStatsProvider.notifier);
  // Each host's own alert choices: metrics muted or snoozed, and ZFS's ARC
  // counted as free memory.
  final alertPrefs = ref.watch(hostAlertPrefsProvider);
  final now = DateTime.now();
  return {
    for (final c in monitored)
      c.id: resolveMonitorHost(
        silenced: alertPrefs[c.id]?.silencedAt(now) ?? const {},
        countArcAsFree: alertPrefs[c.id]?.countArcAsFree ?? false,
        history: statsNotifier.historyFor(c.id),
        stats: stats[c.id],
        health: health[c.id],
        monitor: monitor[c.id],
        hasActiveSession: sessions.values.any((s) =>
            s.connectionId == c.id && s.status == SessionStatus.connected),
        thresholds: config.resolveFor(c.id),
        debounceReadings: config.global.debounceReadings,
        // One rule of when a reading is too old, as the monitor's pages
        // have it: the background check's interval or an open page's
        // refresh, whichever is longer.
        staleAfter: monitorStaleAfter(
          checkIntervalMinutes: config.global.checkIntervalMinutes,
          refreshIntervalSeconds: statsNotifier.refreshIntervalSeconds,
        ),
        now: now,
      ),
  };
});

/// One health chip on a host card: a metric over its threshold, or a
/// watched host that cannot be reached.
class HostHealthChip {
  const HostHealthChip({
    required this.label,
    required this.critical,
    required this.tooltip,
  });

  final String label;
  final bool critical;
  final String tooltip;

  @override
  bool operator ==(Object other) =>
      other is HostHealthChip &&
      other.label == label &&
      other.critical == critical &&
      other.tooltip == tooltip;

  @override
  int get hashCode => Object.hash(label, critical, tooltip);
}

/// The chips a card shows for [view]: only warnings and criticals, worst
/// first, at most two (the card is one line). Healthy hosts and hosts Server
/// Monitor does not watch show none.
List<HostHealthChip> healthChipsFor(
  MonitorHostView? view,
  AppLocalizations l10n,
) {
  if (view == null) return const [];
  if (view.bucket == MonitorBucket.cantCheck &&
      view.cantCheckReason == CantCheckReason.unreachable) {
    return [
      HostHealthChip(
        label: l10n.hostsHealthUnreachable,
        critical: true,
        // What Server Monitor's own status says of it: that it does not
        // answer, or what the check of it failed with on the way.
        tooltip: monitorPillTooltip(view, l10n),
      ),
    ];
  }
  if (view.bucket != MonitorBucket.critical &&
      view.bucket != MonitorBucket.warning) {
    return const [];
  }
  // A metric the person muted or snoozed shows no chip.
  final hot = view.metrics
      .where((m) => m.available && m.raised != MetricSeverity.healthy)
      .toList()
    ..sort((a, b) => b.severity.rank.compareTo(a.severity.rank));
  return [
    for (final m in hot.take(2))
      HostHealthChip(
        label:
            '${monitorMetricLabel(m.metric, l10n)} ${monitorMetricValue(m.metric, m.value!)}',
        critical: m.severity == MetricSeverity.critical,
        tooltip: m.severity == MetricSeverity.critical
            ? l10n.zestMonitorTipCritical(
                monitorMetricLabel(m.metric, l10n),
                monitorMetricValue(m.metric, m.value!),
                monitorMetricValue(m.metric, m.crit))
            : l10n.zestMonitorTipWarning(
                monitorMetricLabel(m.metric, l10n),
                monitorMetricValue(m.metric, m.value!),
                monitorMetricValue(m.metric, m.warn)),
      ),
  ];
}

/// Whether a host needs the person: a metric over its threshold, a watched
/// host that cannot be reached, or a changed host key nobody has resolved.
bool hostNeedsAttention(
  MonitorHostView? view, {
  required bool changedHostKey,
}) {
  if (changedHostKey) return true;
  if (view == null) return false;
  if (view.bucket == MonitorBucket.critical ||
      view.bucket == MonitorBucket.warning) {
    return true;
  }
  return view.bucket == MonitorBucket.cantCheck &&
      view.cantCheckReason == CantCheckReason.unreachable;
}
