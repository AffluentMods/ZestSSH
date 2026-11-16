import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import 'package:zestssh/features/monitoring/monitor_evaluation.dart';
import 'package:zestssh/features/monitoring/monitor_status.dart'
    show kSparklineFlatRange;
import 'package:zestssh/features/monitoring/monitor_thresholds.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/terminal_providers.dart' show connectionFailureText, hostEndedText;
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/error_translator.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/utils/number_text.dart';

// ══════════════════════════════════════════════════════════════════════
// Server-Monitor bucket presentation (§1)
//
// The FOUR-bucket taxonomy (Critical · Warning · Healthy · Can't check) is
// defined in `monitor_evaluation.dart`. This file is its PRESENTATION layer:
// the single source both the summary/filter chips AND the per-row status pills
// draw their label / glyph / colour from, so a host under the "Can't check"
// chip reads "Can't check" in its own pill too - and the pill's tooltip names
// the cause.
// ══════════════════════════════════════════════════════════════════════

extension MonitorBucketUi on MonitorBucket {
  /// Already-localized label - the SINGLE source both the chip and the row pill
  /// draw from, so they can never drift.
  String label(AppLocalizations l10n) => switch (this) {
        MonitorBucket.critical => l10n.monitorBucketCritical,
        MonitorBucket.warning => l10n.monitorBucketWarning,
        MonitorBucket.healthy => l10n.monitorBucketHealthy,
        MonitorBucket.cantCheck => l10n.zestMonitorBucketCantCheck,
      };

  /// Leading glyph, kept distinct so the state never relies on hue alone. The
  /// Can't-check bucket uses a question mark (the neutral "?" pill).
  IconData get icon => switch (this) {
        MonitorBucket.critical => LucideIcons.alertCircle,
        MonitorBucket.warning => LucideIcons.alertTriangle,
        MonitorBucket.healthy => LucideIcons.checkCircle2,
        MonitorBucket.cantCheck => LucideIcons.helpCircle,
      };

  /// Unified status role - drives the chip + pill + row-bar colour. Can't-check
  /// is deliberately the neutral grey, never red/amber.
  ZestStatusKind get kind => switch (this) {
        MonitorBucket.critical => ZestStatusKind.critical,
        MonitorBucket.warning => ZestStatusKind.warning,
        MonitorBucket.healthy => ZestStatusKind.healthy,
        MonitorBucket.cantCheck => ZestStatusKind.neutral,
      };

  Color get color => zestStatusColor(kind);
}

/// Calm history sparkline for the monitor History column (#10 / §2.1).
///
/// Draws a thin line normalized to the series' OWN min/max with ~10% padding,
/// so the SHAPE of recent history stays legible even when the metric sits high
/// (the absolute level already lives in the gauge column, not here). When the
/// whole visible spread is under [kSparklineFlatRange] percentage points the
/// line is drawn FLAT and centred, so genuine stability reads as a level line
/// instead of sensor noise amplified to full height - and a host pinned at 100%
/// renders a line, never a solid block. Null samples break the line into
/// segments. Colour is the caller's status tone; a Can't-check row shows a dash
/// (decided by the cell), never an empty chart.
class MonitorHistoryBars extends StatelessWidget {
  final List<double?> values;
  final Color color;
  final double height;

  const MonitorHistoryBars({
    super.key,
    required this.values,
    required this.color,
    this.height = 20,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _MonitorHistoryBarsPainter(values: values, color: color),
      ),
    );
  }
}

class _MonitorHistoryBarsPainter extends CustomPainter {
  final List<double?> values;
  final Color color;

  const _MonitorHistoryBarsPainter({required this.values, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final n = values.length;
    if (n == 0 || size.width <= 0 || size.height <= 0) return;

    // Series-local min/max over the non-null samples.
    double? lo, hi;
    for (final v in values) {
      if (v == null) continue;
      lo = (lo == null || v < lo) ? v : lo;
      hi = (hi == null || v > hi) ? v : hi;
    }
    if (lo == null || hi == null) return;
    final double minV = lo;
    final double range = hi - minV;
    // Under the flat floor, the whole series is genuinely stable → draw level.
    final bool flat = range < kSparklineFlatRange;

    double yFor(double v) {
      if (flat) return size.height / 2;
      final t = ((v - minV) / range).clamp(0.0, 1.0);
      // Middle 80% of the height (10% padding top and bottom); a higher value
      // sits higher on screen (smaller y).
      return size.height * (0.9 - t * 0.8);
    }

    double xFor(int i) =>
        n == 1 ? size.width / 2 : (i / (n - 1)) * size.width;

    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    Path? path;
    Offset? last;
    var segLen = 0;
    void flush() {
      if (path != null && segLen >= 2) {
        canvas.drawPath(path!, line);
      } else if (path != null && segLen == 1 && last != null) {
        // Isolated point between gaps - a dot so it isn't invisible.
        canvas.drawCircle(last, 1.0, Paint()..color = color);
      }
      path = null;
      segLen = 0;
    }

    for (var i = 0; i < n; i++) {
      final v = values[i];
      if (v == null) {
        flush();
        continue;
      }
      final p = Offset(xFor(i), yFor(v));
      if (path == null) {
        path = Path()..moveTo(p.dx, p.dy);
      } else {
        path!.lineTo(p.dx, p.dy);
      }
      last = p;
      segLen++;
    }
    flush();
  }

  @override
  bool shouldRepaint(_MonitorHistoryBarsPainter old) =>
      old.color != color || !listEquals(old.values, values);
}

/// The localized name for a metric (reuses the existing gauge headers so the
/// tooltip and the columns speak the same words).
String monitorMetricLabel(MonitorMetric metric, AppLocalizations l10n) =>
    switch (metric) {
      MonitorMetric.cpu => l10n.monitorCpu,
      MonitorMetric.ram => l10n.monitorRam,
      MonitorMetric.disk => l10n.monitorDisk,
      MonitorMetric.latency => l10n.monitorColLatency,
      MonitorMetric.swap => l10n.zestMonMetricSwap,
      MonitorMetric.temp => l10n.zestMonMetricTemp,
    };

/// Format a metric value with its unit ("92%", "420ms", "61°C").
String monitorMetricValue(MonitorMetric metric, double value) {
  final n = formatDecimal(value, digits: 0);
  return switch (metric) {
    MonitorMetric.temp => '$n°C',
    MonitorMetric.latency => '${n}ms',
    _ => '$n%',
  };
}

/// One line for every metric that is over a limit at the latest check, worst
/// first, each with the limit it is over (the critical one when it is over
/// that, else the warning one): what the status of a host says of them, and
/// what a notice of them says.
List<String> monitorOverLimitLines(MonitorHostView view, AppLocalizations l10n) => [
      for (final e in view.overLimit)
        e.severity == MetricSeverity.critical
            ? l10n.zestMonitorTipCritical(
                monitorMetricLabel(e.metric, l10n),
                monitorMetricValue(e.metric, e.value!),
                monitorMetricValue(e.metric, e.crit),
              )
            : l10n.zestMonitorTipWarning(
                monitorMetricLabel(e.metric, l10n),
                monitorMetricValue(e.metric, e.value!),
                monitorMetricValue(e.metric, e.warn),
              ),
    ];

/// What a check of a host failed with, in the words a session that failed
/// the same way is given, of the host as [host] (its name as it is shown) at
/// [port]: that it timed out, which jump host did not open the way and why,
/// what the host said when it ended the connection. The names in it (a jump
/// host's, another host's) are masked while recording, as they are where a
/// session shows the same sentence.
String failedCheckSaid(Object failedWith, {String? host, int? port}) => Redactable.freeText(
        ConnectionError.translate(connectionFailureText(failedWith), host: host, port: port).description)
    .display;

/// The report of a host that cannot be checked because a check of it
/// failed, to copy: what was [said] of it, and what the check failed with.
/// Null where no failed check is why.
///
/// A sign-in that was cut off does not print what cut it off: the report
/// has that behind it, for the host and for a jump host on the way, as
/// every report has ([ErrorReport.build]; this one put it there by hand
/// before the others had it).
String? failedCheckReport(MonitorHostView view, String said) {
  final failedWith = view.failedWith;
  if (failedWith == null) return null;
  return ErrorReport.build(what: said, where: 'Server Monitor: a check of a host', error: failedWith);
}

/// An inline action a Can't-check pill can offer (spec §1.2). Null for causes
/// the user can't act on directly (unreachable / never-checked / connecting).
enum MonitorCantCheckAction { addCredential, fixCredential }

MonitorCantCheckAction? monitorCantCheckAction(CantCheckReason reason) =>
    switch (reason) {
      CantCheckReason.noCredentials => MonitorCantCheckAction.addCredential,
      CantCheckReason.authFailed => MonitorCantCheckAction.fixCredential,
      _ => null,
    };

/// Build the keyboard-reachable pill tooltip that names the cause (spec §1.2).
///
/// * Critical / Warning / Healthy → one line for every metric that is over a
///   limit at the latest check, worst first, each with the limit it is over
///   (the critical one when it is over that, else the warning one); then, when
///   the status has not caught up with what that check found (see
///   [MonitorHostView.pendingReadings]), a line saying when it will; then a
///   line noting that the other metrics are fine and when it was checked.
///   Nothing over a limit → "all metrics within limits" and when it was
///   checked. The lines say only what the latest check found: a metric that
///   is within its limits is never named as being over one.
/// * Can't check → the reason sentence. Where a check that failed is the
///   reason, the lines behind it say what it failed with, in the words a
///   session that failed the same way is given ([failedCheckSaid]); for a
///   sign-in the host refused, the rejected user, and what the host said
///   where it ended the connection saying why. Where no timer tries the
///   host again ([MonitorHostView.notTriedAgain]), a last line says that,
///   and how it is tried again. A key of the host's that is to be looked at
///   is said as the first this device sees of it, or as one that changed.
///
/// [checkedPhrase] is an already-localized "…ago" phrase (or null when never).
/// [rejectedUser] is the SSH username for the refused sign-in's line. [host]
/// is the host as it is shown, and [port] its port, for what a check failed
/// with.
String monitorPillTooltip(
  MonitorHostView view,
  AppLocalizations l10n, {
  String? checkedPhrase,
  String? rejectedUser,
  String? host,
  int? port,
}) {
  switch (view.bucket) {
    case MonitorBucket.critical:
    case MonitorBucket.warning:
    case MonitorBucket.healthy:
      final over = monitorOverLimitLines(view, l10n);
      if (over.isEmpty) return l10n.zestMonitorTipHealthy(checkedPhrase ?? '');
      final pending = view.pendingReadings;
      final others = view.metrics.where((e) => e.available).length > over.length;
      return [
        ...over,
        if (pending != null) l10n.zestMonitorTipPending(pending),
        others
            ? l10n.zestMonitorTipOthersFine(checkedPhrase ?? '')
            : l10n.zestMonitorTipChecked(checkedPhrase ?? ''),
      ].join('\n');
    case MonitorBucket.cantCheck:
      final failedWith = view.failedWith;
      final why = failedWith == null ? null : failedCheckSaid(failedWith, host: host, port: port);
      // Nothing more comes of it by itself: said last, with what does. (A
      // host that could not be reached is always tried again.)
      final held = view.notTriedAgain ? l10n.zestMonitorTipNotTriedAgain : null;
      // Tried again now, after the try that failed: said last, after why
      // that one failed.
      final trying = view.tryingAgain ? l10n.zestMonitorTipTryingAgain : null;
      switch (view.cantCheckReason!) {
        case CantCheckReason.authFailed:
          // That it refused says all there is, unless the host said more
          // when it ended the connection (too many failed sign-ins).
          final hostSaid = failedWith == null ? null : hostEndedText(l10n, failedWith);
          return [
            l10n.zestMonitorTipSignInRefused,
            if (rejectedUser != null && rejectedUser.trim().isNotEmpty) l10n.zestMonitorTipAuthUser(rejectedUser),
            if (hostSaid != null) Redactable.freeText(hostSaid).display,
            ?held,
            ?trying,
          ].join('\n');
        case CantCheckReason.noCredentials:
          return l10n.zestMonitorTipNoCredentials;
        case CantCheckReason.unreachable:
          // A check that failed on the way to it; or, with no check of it at
          // all, no answer to the checks of whether it can be reached.
          return why == null
              ? l10n.zestMonitorTipUnreachable
              : [l10n.zestMonitorTipNotReached, why, ?trying].join('\n');
        case CantCheckReason.checkFailed:
          return [l10n.zestMonitorTipCheckFailed, ?why, ?held, ?trying].join('\n');
        case CantCheckReason.hostKeyReview:
          return view.hostKeyChanged ? l10n.zestMonitorTipHostKeyReview : l10n.zestMonitorTipHostKeyNew;
        case CantCheckReason.connecting:
          return l10n.zestMonitorTipConnecting;
        case CantCheckReason.stale:
          return l10n.zestMonitorTipStale;
        case CantCheckReason.noCollector:
          return l10n.zestMonitorTipNoCollector;
        case CantCheckReason.neverChecked:
          return l10n.zestMonitorTipNeverChecked;
      }
  }
}

/// What a host's card says where nothing is known of the host: no reading,
/// no session, no answer to a check of whether it can be reached.
enum NothingKnownOfHost {
  /// A check of it is under way: a turning wheel, and "Checking".
  checking,

  /// It is not among the hosts that are monitored, and nothing checks it.
  notMonitored,

  /// It is monitored, and nothing has run for it yet.
  neverChecked,
}

/// What is so of a host of which nothing is known.
///
/// "Checking" is true only while something checks: a reading is being taken
/// of the host ([readingUnderWay]: Server Monitor has connected to it, or is
/// about to), or the checks of whether hosts can be reached are on
/// ([reachabilityChecksOn]) and this host's answer has not come. Without
/// either, nothing is being done about the host, and its card says which
/// it is: a host that is not monitored ([monitored] is its switch), or one
/// that is and has not been looked at yet.
///
/// (Every such card said "Checking" beside a turning wheel. The checks of
/// whether hosts can be reached are off unless their person turns them on,
/// since 2.3.0, so the wheel turned for good on every host that was not
/// monitored: it looked as if they were being checked, to somebody who had
/// taken them out of monitoring for a reason.)
NothingKnownOfHost nothingKnownOfHost({
  required bool monitored,
  required bool readingUnderWay,
  required bool reachabilityChecksOn,
}) {
  if (readingUnderWay || reachabilityChecksOn) return NothingKnownOfHost.checking;
  return monitored ? NothingKnownOfHost.neverChecked : NothingKnownOfHost.notMonitored;
}

/// How long ago a host was checked, as words inside a sentence ("Checked
/// {checked}.", "updated {ago}"), to the second from 10 seconds to a minute,
/// as the monitor refreshes every few seconds. [now] is for tests.
String monitorCheckedPhrase(AppLocalizations l10n, DateTime at, {DateTime? now}) =>
    timeAgoInSentence(l10n, at, now: now, seconds: true);
