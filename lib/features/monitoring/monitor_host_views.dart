import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/features/monitoring/monitor_evaluation.dart';
import 'package:zestssh/features/monitoring/monitor_host_alerts.dart';
import 'package:zestssh/features/monitoring/monitor_status.dart' show monitorStaleAfter;
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/providers/monitor_thresholds_provider.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/server_stats_service.dart';

/// Every host resolved into exactly one of the monitor's four buckets, by
/// host: what the Server monitor's table shows, and what the pickers that act
/// on it read (the aim: make "Reboot needed" and "Updates
/// pending" actionable). Every host, where [monitoredHostViewsProvider] has only
/// those watched: a host with a session open has readings too. It reads what the
/// monitor already found and makes no check of its own; the background checks
/// are only looked at where they are already running, never started for this.
final monitorHostViewsProvider = Provider<Map<String, MonitorHostView>>((ref) {
  final hosts = (ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[])
      .where((c) => c.connection.protocol != 'localShell');
  final health = ref.watch(connectionHealthProvider);
  final stats = ref.watch(serverStatsProvider);
  final sessions = ref.watch(activeSessionsProvider);
  final config = ref.watch(monitorThresholdsProvider);
  final alertPrefs = ref.watch(hostAlertPrefsProvider);
  final statuses = ref.exists(agentlessMonitorPollerProvider)
      ? ref.watch(agentlessMonitorPollerProvider)
      : const <String, MonitorHostStatus>{};
  final staleAfter = monitorStaleAfter(
    checkIntervalMinutes: config.global.checkIntervalMinutes,
    refreshIntervalSeconds: ref.read(serverStatsProvider.notifier).refreshIntervalSeconds,
  );
  final now = DateTime.now();
  return {
    for (final c in hosts)
      c.connection.id: resolveMonitorHost(
        history: ref.read(serverStatsHistoryProvider(c.connection.id)),
        stats: stats[c.connection.id],
        health: health[c.connection.id],
        monitor: statuses[c.connection.id],
        hasActiveSession:
            sessions.values.any((s) => s.connectionId == c.connection.id && s.status == SessionStatus.connected),
        thresholds: config.resolveFor(c.connection.id),
        // The host's own alert choices (its panel's Alert menu).
        silenced: alertPrefs[c.connection.id]?.silencedAt(now) ?? const {},
        countArcAsFree: alertPrefs[c.connection.id]?.countArcAsFree ?? false,
        debounceReadings: config.global.debounceReadings,
        staleAfter: staleAfter,
        now: now,
      ),
  };
});

/// Whether the host's latest reading says it asks for a restart (Debian and
/// Ubuntu write /var/run/reboot-required after updates that need one).
bool monitorNeedsReboot(ServerStats? stats, MonitorHostView view) =>
    stats?.restartRequired == true && view.bucket != MonitorBucket.cantCheck;

/// Whether the host's latest reading, one that can still be trusted, counts
/// updates waiting to be installed.
bool monitorHasUpdates(ServerStats? stats, MonitorHostView view) =>
    (stats?.updatesTotal ?? 0) > 0 && !view.statsStale && view.bucket != MonitorBucket.cantCheck;

/// The hosts the monitor's latest readings single out, for what can be done
/// about them at once: Broadcast's and Run on's quick choices, and the Server
/// monitor's filters.
class MonitorHostFacts {
  const MonitorHostFacts({
    this.rebootNeeded = const {},
    this.updatesPending = const {},
    this.warnings = const {},
  });

  final Set<String> rebootNeeded;
  final Set<String> updatesPending;

  /// Over a limit: at the warning level or worse (a host at the critical one
  /// is not left out of what has a host's warnings looked at).
  final Set<String> warnings;
}

final monitorHostFactsProvider = Provider<MonitorHostFacts>((ref) {
  final views = ref.watch(monitorHostViewsProvider);
  final stats = ref.watch(serverStatsProvider);
  final reboot = <String>{};
  final updates = <String>{};
  final warnings = <String>{};
  views.forEach((id, view) {
    final s = stats[id];
    if (monitorNeedsReboot(s, view)) reboot.add(id);
    if (monitorHasUpdates(s, view)) updates.add(id);
    if (view.bucket == MonitorBucket.warning || view.bucket == MonitorBucket.critical) warnings.add(id);
  });
  return MonitorHostFacts(rebootNeeded: reboot, updatesPending: updates, warnings: warnings);
});
