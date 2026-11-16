// ══════════════════════════════════════════════════════════════════════
// Server-Monitor four-bucket evaluation (§1)
//
// One pure resolver, [resolveMonitorHost], turns a host's raw signals (fresh
// stats, TCP health, the agentless poller state, live-session flag) plus the
// configured thresholds into exactly ONE of four buckets:
//
//   Critical · Warning · Healthy · Can't check
//
// Every non-collectable case (unreachable, no credentials, auth failed,
// connecting, stale, never-checked, host-key review, a check that failed for
// another reason) collapses into **Can't check** with a [CantCheckReason]
// that names the cause for the pill tooltip. A check that failed is filed by
// what it failed with ([failedCheckReason]), which the view hands on for
// whoever shows it to put into words.
//
// Debounce (spec §2.3) is computed HERE, deterministically, from the metric
// history: a gauge breach must persist for N consecutive readings before it
// changes the host's status, so a single spike can never raise it. It only
// holds a status back from getting worse: the status is never worse than what
// the latest check found, so a host that is back within its limits reads
// healthy at that check. Because it is pure and derived from history + the
// current thresholds, changing a threshold re-evaluates every host immediately
// with no stale debounce state to clear.
// ══════════════════════════════════════════════════════════════════════

import 'package:zest_ssh_core/dartssh2.dart' show SSHChannelOpenError;
import 'package:zestssh/database/database.dart' show MonitorSample;
import 'package:zestssh/features/monitoring/monitor_thresholds.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' show connectionFailureText, reconnectCannotHelp;
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/jump_host_failure.dart';
import 'package:zestssh/services/server_stats_service.dart';
import 'package:zestssh/utils/error_translator.dart';

/// The four (and only four) buckets a monitored host can fall into. Ordered
/// worst-first so `.index` doubles as the chip / sort rank.
enum MonitorBucket { critical, warning, healthy, cantCheck }

/// Why a host lands in [MonitorBucket.cantCheck] - drives the neutral pill's
/// tooltip and any inline action link.
enum CantCheckReason {
  /// The host refused the sign-in: it took none of the keys or the password
  /// it was offered, or ended the connection saying that it does.
  authFailed,

  /// No usable saved credentials to authenticate without a prompt.
  noCredentials,

  /// The host could not be reached: a check of it failed on the way to it
  /// (a time-out, a refused connection, a name that is not found, a jump
  /// host that could not be reached or could not reach it), or it does not
  /// answer the checks of whether it can be reached.
  unreachable,

  /// A check of the host failed for another reason than those two: a jump
  /// host that passes nothing on or refused its own sign-in, jump hosts that
  /// cannot be followed, a host that ended the connection, no algorithm in
  /// common. What it failed with says which ([MonitorHostView.failedWith]).
  checkFailed,

  /// A new / changed host key needs review before monitoring can resume
  /// ([MonitorHostView.hostKeyChanged] says which).
  hostKeyReview,

  /// A poll is in flight (just connected / between polls / collecting).
  connecting,

  /// The last reading is older than the stale window - no longer trustworthy.
  stale,

  /// Reachable, but nothing (no session, no Prometheus target, or the free
  /// tier cap) is collecting stats for it.
  noCollector,

  /// Background monitoring has never run for this host.
  neverChecked,
}

/// Per-metric severity - the single-reading classification against a metric's
/// warn/crit thresholds.
enum MetricSeverity { healthy, warning, critical }

extension MetricSeverityRank on MetricSeverity {
  int get rank => index; // healthy 0 < warning 1 < critical 2
}

/// One metric's current value, its resolved thresholds and its severity - the
/// data the gauge tick markers and the breach tooltip read.
class MetricEval {
  final MonitorMetric metric;

  /// Current value (percent for gauges, ms for latency); null when unavailable
  /// or its source sample is stale.
  final double? value;

  final double warn;
  final double crit;

  /// Where the value stands against [warn] and [crit], whether or not the
  /// person keeps the metric quiet ([silenced]): what its bar is drawn by.
  final MetricSeverity severity;

  /// The person muted or snoozed this metric of the host (its panel's Alert
  /// menu): it raises nothing (no status, no chip, no notice), whatever its
  /// [severity].
  final bool silenced;

  const MetricEval({
    required this.metric,
    required this.value,
    required this.warn,
    required this.crit,
    required this.severity,
    this.silenced = false,
  });

  /// The severity it raises the host by: none where it is kept quiet.
  MetricSeverity get raised => silenced ? MetricSeverity.healthy : severity;

  bool get available => value != null;
}

/// A fully-resolved monitor status for one host: the bucket, the reason (when
/// Can't check), which metric drove a Critical/Warning, per-metric evals for the
/// bar tick markers, and the freshest stats timestamp for the Checked column.
class MonitorHostView {
  final MonitorBucket bucket;

  /// Non-null iff [bucket] == [MonitorBucket.cantCheck].
  final CantCheckReason? cantCheckReason;

  /// The metric furthest over its limit at the latest check, when [bucket] is
  /// Critical / Warning (null otherwise). There always is one then: the status
  /// is never worse than what the latest check found.
  final MonitorMetric? breachedMetric;

  /// Non-null when the latest check found a gauge worse than [bucket] shows:
  /// how many checks in a row have to find it before the status changes (the
  /// person's "change after N readings"). The pill's tooltip says so, rather
  /// than calling metrics that are over a limit fine.
  final int? pendingReadings;

  /// CPU / RAM / Swap / Disk / Temp / Latency evals, each carrying its value +
  /// resolved thresholds for the bar markers and the tooltip. Read by metric via
  /// [metricEval], so the list order is not load-bearing.
  final List<MetricEval> metrics;

  /// When the current stats sample was collected - drives the Checked column
  /// ("1m", "18m", "never") and the tooltip's "checked …" line. Null = never.
  final DateTime? statsCollectedAt;

  /// The current stats sample is older than the stale window.
  final bool statsStale;

  /// What the check failed with, where a failed check is why the host cannot
  /// be checked: the error itself, for whoever shows the host to put into
  /// words and into a report that can be copied.
  final Object? failedWith;

  /// Whether no timer tries the host again after [failedWith]
  /// ([MonitorHostStatus.notTriedAgain]): what is shown of it says so, and
  /// how it is tried again.
  final bool notTriedAgain;

  /// Where a key of the host's is to be looked at
  /// ([CantCheckReason.hostKeyReview]): whether it is another than the one
  /// this device trusts, and not the first it sees of the host.
  final bool hostKeyChanged;

  /// Whether the host is being tried again, now, after the try that failed
  /// with [failedWith]: what is shown of it says why that one failed, and
  /// that it is tried.
  final bool tryingAgain;

  const MonitorHostView({
    required this.bucket,
    required this.metrics,
    this.cantCheckReason,
    this.breachedMetric,
    this.pendingReadings,
    this.statsCollectedAt,
    this.statsStale = false,
    this.failedWith,
    this.notTriedAgain = false,
    this.hostKeyChanged = false,
    this.tryingAgain = false,
  });

  MetricEval? metricEval(MonitorMetric m) {
    for (final e in metrics) {
      if (e.metric == m) return e;
    }
    return null;
  }

  /// The metrics over a limit at the latest check, worst first: critical
  /// before warning, and among equals the one furthest over its warning limit.
  /// A metric the person keeps quiet is not among them.
  List<MetricEval> get overLimit {
    final over = [
      for (final e in metrics)
        if (e.available && e.raised != MetricSeverity.healthy) e,
    ];
    over.sort((a, b) {
      final bySeverity = b.severity.rank.compareTo(a.severity.rank);
      if (bySeverity != 0) return bySeverity;
      return (b.value! - b.warn).compareTo(a.value! - a.warn);
    });
    return over;
  }
}

/// Classify a single gauge value against its warn/crit.
MetricSeverity _severityOf(double value, MetricThreshold t) {
  if (value >= t.crit) return MetricSeverity.critical;
  if (value >= t.warn) return MetricSeverity.warning;
  return MetricSeverity.healthy;
}

/// The worst gauge severity in a single [ServerStats] sample, across every
/// metric the sample actually reported: cpu / ram / disk / swap (percent) and
/// temp (°C). A metric the host cannot report comes back null and is SKIPPED -
/// it can never push the host to warning/critical, and its absence is not read
/// as healthy (an all-null sample simply contributes nothing; only reported
/// metrics count). Latency is folded in separately by the caller.
MetricSeverity _gaugeSeverity(
  ServerStats s,
  Map<MonitorMetric, MetricThreshold> thresholds, {
  Set<MonitorMetric> silenced = const {},
  bool countArcAsFree = false,
}) {
  var worst = MetricSeverity.healthy;
  final pairs = <MonitorMetric, double?>{
    MonitorMetric.cpu: s.cpuPercent,
    MonitorMetric.ram: s.ramPercentWith(arcAsFree: countArcAsFree),
    MonitorMetric.disk: s.diskPercent,
    MonitorMetric.swap: s.swapPercent,
    MonitorMetric.temp: s.tempC,
  };
  for (final e in pairs.entries) {
    final v = e.value;
    if (v == null) continue; // N/A → excluded from scoring
    if (silenced.contains(e.key)) continue; // kept quiet by the person
    final sev = _severityOf(v, thresholds[e.key]!);
    if (sev.rank > worst.rank) worst = sev;
  }
  return worst;
}

/// The per-check status for the desktop status strip (§1): the worst severity
/// across the metrics THIS sample actually recorded, or null when the check
/// produced no scorable metric (a failed check, or an ok check that recorded no
/// reportable metric). A null metric is excluded, never counted as healthy - so
/// a "can't check" block stays neutral rather than reading green.
MetricSeverity? monitorSampleSeverity(
  MonitorSample s,
  Map<MonitorMetric, MetricThreshold> thresholds,
) {
  if (!s.ok) return null;
  MetricSeverity? worst;
  void fold(double? v, MonitorMetric m) {
    if (v == null) return; // N/A → excluded
    final sev = _severityOf(v, thresholds[m]!);
    if (worst == null || sev.rank > worst!.rank) worst = sev;
  }

  fold(s.cpuPercent, MonitorMetric.cpu);
  fold(s.ramPercent, MonitorMetric.ram);
  fold(s.swapPercent, MonitorMetric.swap);
  fold(s.diskPercent, MonitorMetric.disk);
  fold(s.tempC, MonitorMetric.temp);
  fold(s.pingMs?.toDouble(), MonitorMetric.latency);
  return worst; // null when an ok sample scored no reportable metric
}

/// The gauge severity a host's status shows, from its [readings] (oldest →
/// newest, never empty): the worst level that EVERY one of the last [n]
/// readings reaches (spec §2.3).
///
/// A level therefore shows only once it has held for [n] readings in a row, so
/// a lone spike never raises the status; and the status is never worse than
/// what the latest reading found, so a host that is back within its limits
/// reads healthy at that check, with no wait. With fewer than [n] readings so
/// far, the ones there are decide (the first reading counts at once). An [n]
/// below two leaves the latest reading alone to decide.
MetricSeverity _settledGaugeSeverity(List<MetricSeverity> readings, int n) {
  var settled = readings.last;
  final from = readings.length > n ? readings.length - n : 0;
  for (var i = from; i < readings.length - 1; i++) {
    if (readings[i].rank < settled.rank) settled = readings[i];
  }
  return settled;
}

/// Why a check that failed could not be made, from what it failed with.
///
/// A refused sign-in is one that the host itself refused ([MonitorHostStatus
/// .signInRefused]); a host that could not be reached is one whose check
/// failed on the way to it, as a session to it would be told (a time-out, a
/// refused connection, a name that is not found, the network), or behind a
/// jump host that could not be reached or said that it could not reach the
/// next one. Anything else is a check that failed, and what it failed with
/// says why: a jump host's own refused sign-in among them, which is not the
/// host's, and not mended in the host's sign-in details.
///
/// (It was read from the words of the error: any that held "auth",
/// "password" or "rejected" was a failed sign-in, and so was every failure
/// of a host that answers a check of whether it can be reached. A host
/// whose check timed out, or whose jump hosts cannot be followed, was said
/// to have failed the sign-in, with a link to its sign-in details.)
CantCheckReason failedCheckReason(MonitorHostStatus status) {
  final failedWith = status.failedWith;
  if (failedWith is JumpHostFailure) {
    final cause = failedWith.cause;
    final notReached = switch (failedWith.stage) {
      JumpStage.reach => _failedOnTheWay(cause),
      JumpStage.onward => cause is SSHChannelOpenError && cause.code == 2,
      JumpStage.details || JumpStage.signIn => false,
    };
    return notReached ? CantCheckReason.unreachable : CantCheckReason.checkFailed;
  }
  // The connection to a jump host ended while the host behind it was
  // being connected to: the host was not reached. But for what no later
  // try mends by itself (the jump host's key failed when new keys were
  // taken), which is a check that failed, with why.
  if (failedWith is JumpHostEndedOnTheWay) {
    return reconnectCannotHelp(failedWith) ? CantCheckReason.checkFailed : CantCheckReason.unreachable;
  }
  if (status.signInRefused) return CantCheckReason.authFailed;
  if (failedWith != null && _failedOnTheWay(failedWith)) return CantCheckReason.unreachable;
  return CantCheckReason.checkFailed;
}

/// Whether [error] is a connection that could not be made, as a session
/// that failed with it is told.
bool _failedOnTheWay(Object error) => switch (ConnectionError.translate(connectionFailureText(error)).type) {
      ConnectionErrorType.timeout ||
      ConnectionErrorType.refused ||
      ConnectionErrorType.hostUnreachable ||
      ConnectionErrorType.networkError =>
        true,
      _ => false,
    };

/// Resolve a host's four-bucket status. Pure - all state (including debounce)
/// derives from the arguments, so a threshold change re-evaluates immediately.
MonitorHostView resolveMonitorHost({
  required List<ServerStats> history,
  required ServerStats? stats,
  required HealthCheckResult? health,
  required MonitorHostStatus? monitor,
  required bool hasActiveSession,
  required Map<MonitorMetric, MetricThreshold> thresholds,
  required int debounceReadings,
  required Duration staleAfter,
  required DateTime now,
  Set<MonitorMetric> silenced = const {},
  bool countArcAsFree = false,
}) {
  final statsAge = stats != null ? now.difference(stats.collectedAt) : null;
  final statsStale = statsAge != null && statsAge > staleAfter;
  final healthStale = health != null && health.staleAt(now, staleAfter);
  final freshStats = stats != null && !statsStale;

  // ── Per-metric evals (always built, for the bar markers + tooltip) ──
  // Latency: the round trip of the reading itself where it has one (timed
  // on the connection the stats come over), else that of a check of whether
  // the host can be reached, where those are on. Neither once it is stale.
  final latencyVal =
      ((statsStale ? null : stats?.pingMs) ?? (healthStale ? null : health?.latencyMs))?.toDouble();
  List<MetricEval> buildMetrics() {
    MetricEval evalGauge(MonitorMetric m, double? v) {
      final t = thresholds[m]!;
      final value = statsStale ? null : v; // stale gauge → not a live value
      return MetricEval(
        metric: m,
        value: value,
        warn: t.warn,
        crit: t.crit,
        severity: value == null
            ? MetricSeverity.healthy
            : _severityOf(value, t),
        silenced: silenced.contains(m),
      );
    }

    final lt = thresholds[MonitorMetric.latency]!;
    return [
      evalGauge(MonitorMetric.cpu, stats?.cpuPercent),
      evalGauge(MonitorMetric.ram, stats?.ramPercentWith(arcAsFree: countArcAsFree)),
      evalGauge(MonitorMetric.swap, stats?.swapPercent),
      evalGauge(MonitorMetric.disk, stats?.diskPercent),
      evalGauge(MonitorMetric.temp, stats?.tempC),
      MetricEval(
        metric: MonitorMetric.latency,
        value: latencyVal,
        warn: lt.warn,
        crit: lt.crit,
        severity: latencyVal == null
            ? MetricSeverity.healthy
            : _severityOf(latencyVal, lt),
        silenced: silenced.contains(MonitorMetric.latency),
      ),
    ];
  }

  final metrics = buildMetrics();

  MonitorHostView cantCheck(
    CantCheckReason reason, {
    Object? failedWith,
    bool notTriedAgain = false,
    bool hostKeyChanged = false,
    bool tryingAgain = false,
  }) =>
      MonitorHostView(
        bucket: MonitorBucket.cantCheck,
        cantCheckReason: reason,
        metrics: metrics,
        statsCollectedAt: stats?.collectedAt,
        statsStale: statsStale,
        failedWith: failedWith,
        notTriedAgain: notTriedAgain,
        hostKeyChanged: hostKeyChanged,
        tryingAgain: tryingAgain,
      );

  // ── 1. Agentless-poller states take precedence (they mean "no trust") ──
  final m = monitor;
  if (m != null) {
    switch (m.state) {
      case MonitorHostState.needsCredentials:
        return cantCheck(CantCheckReason.noCredentials);
      case MonitorHostState.needsHostKeyReview:
        return cantCheck(CantCheckReason.hostKeyReview, hostKeyChanged: m.hostKeyChanged);
      case MonitorHostState.error:
        // By what the check failed with, and nothing else: whether the host
        // answers a check of whether it can be reached says nothing of why
        // a check of it failed.
        return cantCheck(failedCheckReason(m), failedWith: m.failedWith, notTriedAgain: m.notTriedAgain);
      case MonitorHostState.notEligible:
        // Free-tier cap / not-monitorable → nothing is collecting.
        if (!freshStats) return cantCheck(CantCheckReason.noCollector);
        break; // has fresh stats somehow → fall through
      case MonitorHostState.connecting:
      case MonitorHostState.monitoring:
      case MonitorHostState.ok:
        if (!freshStats) {
          // Tried again after a try that failed: why that one failed, and
          // that it is tried, until this one ends. "Connecting" is said
          // only where no try before it failed.
          if (m.state == MonitorHostState.connecting && m.failedWith != null) {
            return cantCheck(failedCheckReason(m), failedWith: m.failedWith, tryingAgain: true);
          }
          return cantCheck(CantCheckReason.connecting);
        }
        break; // fall through to compute health from the fresh sample
    }
  }

  // ── 2. Fresh stats → compute a real Critical/Warning/Healthy ──
  if (freshStats) {
    // The readings so far, ending with the current sample. (The history ends
    // with it already once the sample is committed; right after a cold start
    // that loaded cached stats there is no history, and the sample stands
    // alone.) The current sample is always the last reading, which is what
    // keeps the status from ever being worse than the latest check.
    MetricSeverity gauge(ServerStats s) =>
        _gaugeSeverity(s, thresholds, silenced: silenced, countArcAsFree: countArcAsFree);
    final readings = [
      for (final s in history) gauge(s),
      if (history.isEmpty || !identical(history.last, stats)) gauge(stats),
    ];
    final gaugeNow = readings.last;
    final gaugeSev = _settledGaugeSeverity(readings, debounceReadings);

    // Latency applies immediately (its history isn't retained); it can only
    // raise the floor, so it never masks a gauge breach.
    final latencySev = metrics
        .firstWhere((e) => e.metric == MonitorMetric.latency)
        .raised;
    final hostSev =
        latencySev.rank > gaugeSev.rank ? latencySev : gaugeSev;

    final bucket = switch (hostSev) {
      MetricSeverity.critical => MonitorBucket.critical,
      MetricSeverity.warning => MonitorBucket.warning,
      MetricSeverity.healthy => MonitorBucket.healthy,
    };
    final view = MonitorHostView(
      bucket: bucket,
      metrics: metrics,
      // The latest check found a gauge worse than the status shows: it has
      // not held for enough checks in a row yet.
      pendingReadings: gaugeNow.rank > hostSev.rank ? debounceReadings : null,
      statsCollectedAt: stats.collectedAt,
      statsStale: false,
    );
    if (hostSev == MetricSeverity.healthy) return view;
    final over = view.overLimit;
    return MonitorHostView(
      bucket: view.bucket,
      breachedMetric: over.isEmpty ? null : over.first.metric,
      pendingReadings: view.pendingReadings,
      metrics: metrics,
      statsCollectedAt: stats.collectedAt,
      statsStale: false,
    );
  }

  // ── 3. No fresh stats → a Can't-check reason ──
  if (hasActiveSession) {
    // A terminal is open and collecting; stats just haven't landed yet.
    return cantCheck(CantCheckReason.connecting);
  }
  if (stats != null) {
    // We have data, but it's past the stale window.
    return cantCheck(CantCheckReason.stale);
  }
  switch (health?.status) {
    case ConnectionHealth.offline:
      return cantCheck(CantCheckReason.unreachable);
    case ConnectionHealth.online:
      return cantCheck(CantCheckReason.noCollector);
    case ConnectionHealth.checking:
    case ConnectionHealth.unknown:
    case null:
      return cantCheck(CantCheckReason.neverChecked);
  }
}
