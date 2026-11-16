import 'dart:math' as math;

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/server_stats_service.dart';
import 'package:zestssh/theme/app_colors.dart';

// ══════════════════════════════════════════════════════════════════════
// Host severity + freshness (Doc-3 B1 / B2)
//
// Shared severity / staleness / threshold model. Both the mobile
// `ServerMonitorScreen` and the desktop `MonitorTableView` classify hosts
// through [evaluateHost] so the two surfaces never disagree about what is
// critical, warning, stale, offline or healthy.
// ══════════════════════════════════════════════════════════════════════

/// Coarse per-host state. Ordered worst-first so `.index` doubles as the
/// severity sort rank (offline is the most urgent, unknown the least).
enum HostSeverity { offline, critical, warning, stale, healthy, unknown }

extension HostSeverityUi on HostSeverity {
  String label(AppLocalizations l10n) {
    switch (this) {
      case HostSeverity.offline:
        return l10n.monitorBucketOffline;
      case HostSeverity.critical:
        return l10n.monitorBucketCritical;
      case HostSeverity.warning:
        return l10n.monitorBucketWarning;
      case HostSeverity.stale:
        return l10n.monitorBucketStale;
      case HostSeverity.healthy:
        return l10n.monitorBucketHealthy;
      case HostSeverity.unknown:
        return '';
    }
  }

  Color get color {
    switch (this) {
      case HostSeverity.offline:
      case HostSeverity.critical:
        return AppColors.error;
      case HostSeverity.warning:
      case HostSeverity.stale:
        return AppColors.warning;
      case HostSeverity.healthy:
        return AppColors.success;
      case HostSeverity.unknown:
        return AppColors.onSurfaceDim;
    }
  }

  IconData get icon {
    switch (this) {
      case HostSeverity.offline:
        return LucideIcons.cloudOff;
      case HostSeverity.critical:
        return LucideIcons.alertCircle;
      case HostSeverity.warning:
        return LucideIcons.alertTriangle;
      case HostSeverity.stale:
        return LucideIcons.history;
      case HostSeverity.healthy:
        return LucideIcons.checkCircle2;
      case HostSeverity.unknown:
        return LucideIcons.helpCircle;
    }
  }
}

/// Resolved severity + per-subsystem freshness for a single host.
class HostStatus {
  final HostSeverity severity;

  /// The [ServerStats.collectedAt] sample is older than the stale threshold.
  final bool statsStale;

  /// The [HealthCheckResult.checkedAt] sample is older than the threshold.
  final bool healthStale;

  /// Host-level staleness: every available sample is stale and no live
  /// session is keeping the host current (Doc-3 B2 "stale" bucket).
  final bool isStale;

  const HostStatus({
    required this.severity,
    this.statsStale = false,
    this.healthStale = false,
    this.isStale = false,
  });
}

// Thresholds mirror the gauge/latency colour bands so the summary buckets
// and the per-gauge colours never disagree.
const double kGaugeWarn = 70;
const double kGaugeCritical = 90;
const int kLatencyWarnMs = 100;
const int kLatencyCriticalMs = 250;

/// Sparkline flat-floor (percentage points). When a metric's full spread over
/// the visible history is smaller than this, the sparkline is drawn FLAT and
/// centred instead of normalized to its own min/max - so genuine stability
/// reads as a flat line rather than tiny sensor noise amplified to full height.
const double kSparklineFlatRange = 3;

/// Stale threshold relative to the refresh interval: 3× the interval with a
/// 60-second floor so short intervals (10/15s) don't flag a single missed
/// tick or a little network jitter as stale (Doc-3 B2).
Duration staleThreshold(int intervalSeconds) =>
    Duration(seconds: math.max(intervalSeconds * 3, 60));

/// The one rule for when a watched host's last reading is too old, on every
/// page that says so (the Monitor page and its table, a host's detail, the
/// hosts' chips, the alerts): [staleThreshold] of the longer of the two ways
/// readings come, the background check ([checkIntervalMinutes]) and an open
/// session's refresh ([refreshIntervalSeconds]). (Before, the
/// Monitor page counted from the check and the chips and alerts from the
/// refresh, so a host could be up to date on one and out of date on the
/// other at once.)
Duration monitorStaleAfter({required int checkIntervalMinutes, required int refreshIntervalSeconds}) =>
    staleThreshold(math.max(checkIntervalMinutes * 60, refreshIntervalSeconds));

bool _gaugeAtLeast(ServerStats s, double threshold) {
  final cpu = s.cpuPercent;
  final ram = s.ramPercent;
  final disk = s.diskPercent;
  return (cpu != null && cpu >= threshold) ||
      (ram != null && ram >= threshold) ||
      (disk != null && disk >= threshold);
}

/// Classify a host from BOTH subsystems (health + stats), reconciling their
/// independent freshness. Gauge/latency severity only counts when its own
/// source is fresh, so a stale cached reading never masquerades as a live
/// critical value.
HostStatus evaluateHost({
  required HealthCheckResult? health,
  required ServerStats? stats,
  required bool hasActiveSession,
  required Duration threshold,
  required DateTime now,
}) {
  final statsAge = stats != null ? now.difference(stats.collectedAt) : null;
  final statsStale = statsAge != null && statsAge > threshold;
  // A check's result by its own measure too: the checks run at an interval
  // their person chose, which may be longer than a reading is allowed.
  final healthStale = health != null && health.staleAt(now, threshold);

  final hasKnownStatus =
      health != null && health.status != ConnectionHealth.unknown;

  // No usable data from either subsystem → unmonitored.
  if (!hasActiveSession && !hasKnownStatus && stats == null) {
    return const HostStatus(severity: HostSeverity.unknown);
  }

  // A live session always means reachable; a *fresh* down-probe is the most
  // urgent state.
  final isOffline = !hasActiveSession &&
      health?.status == ConnectionHealth.offline &&
      !healthStale;
  if (isOffline) {
    return HostStatus(
      severity: HostSeverity.offline,
      statsStale: statsStale,
      healthStale: healthStale,
    );
  }

  // Everything we have is stale and nothing is keeping it current → we can't
  // trust any of the numbers, so this is its own bucket.
  final hostStale = !hasActiveSession &&
      (stats == null || statsStale) &&
      (health == null || healthStale);
  if (hostStale) {
    return const HostStatus(
      severity: HostSeverity.stale,
      statsStale: true,
      healthStale: true,
      isStale: true,
    );
  }

  // Latency: the round trip of the reading itself where it has one, else
  // that of a check of whether the host can be reached. Neither once stale.
  final latencyMs = (statsStale ? null : stats?.pingMs) ?? (healthStale ? null : health?.latencyMs);
  final gaugeCritical =
      !statsStale && stats != null && _gaugeAtLeast(stats, kGaugeCritical);
  final latCritical = latencyMs != null && latencyMs > kLatencyCriticalMs;
  if (gaugeCritical || latCritical) {
    return HostStatus(
      severity: HostSeverity.critical,
      statsStale: statsStale,
      healthStale: healthStale,
    );
  }

  final gaugeWarn =
      !statsStale && stats != null && _gaugeAtLeast(stats, kGaugeWarn);
  final latWarn = latencyMs != null && latencyMs > kLatencyWarnMs;
  if (gaugeWarn || latWarn) {
    return HostStatus(
      severity: HostSeverity.warning,
      statsStale: statsStale,
      healthStale: healthStale,
    );
  }

  final online = hasActiveSession || health?.status == ConnectionHealth.online;
  if (online || (stats != null && !statsStale)) {
    return HostStatus(
      severity: HostSeverity.healthy,
      statsStale: statsStale,
      healthStale: healthStale,
    );
  }

  return const HostStatus(severity: HostSeverity.unknown);
}
