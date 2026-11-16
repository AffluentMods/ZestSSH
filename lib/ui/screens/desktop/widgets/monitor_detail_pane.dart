import 'dart:math' as math;

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zestssh/core/widgets/os_icon.dart';
import 'package:zestssh/database/database.dart' show MonitorSample;
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/features/monitoring/monitor_capabilities.dart';
import 'package:zestssh/features/monitoring/monitor_evaluation.dart';
import 'package:zestssh/features/monitoring/monitor_state_ui.dart';
import 'package:zestssh/features/monitoring/monitor_thresholds.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/os_kind.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/providers/os_detection_providers.dart';
import 'package:zestssh/services/server_stats_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/monitoring/monitor_thresholds_dialog.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/utils/byte_size.dart';
import 'package:zestssh/utils/host_address.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/l10n/time_text.dart';
import 'package:zestssh/utils/number_text.dart';

// ══════════════════════════════════════════════════════════════════════
// Server Monitor host detail pane (desktop) - spec §2
//
// The right-hand master/detail pane that opens when a monitor table row is
// selected. Top-to-bottom: header, History (multi-series chart + toggleable
// legend), Now (metric cards), Filesystems, System. It is a pure CONSUMER of
// the backend data layer - it never collects.
// ══════════════════════════════════════════════════════════════════════

/// Reference width of the pane.
const double kMonitorDetailPaneWidth = 452;

// The six history series, fixed colour per metric (spec §2.1 - the only
// mockup-specific colour literals allowed here).
const Color _cCpu = Color(0xFFF0736B);
const Color _cRam = Color(0xFFE8C14E);
const Color _cDisk = Color(0xFF5EB3E4);
const Color _cSwap = Color(0xFFB07FE0);
const Color _cLoad = Color(0xFF3FB98A);
const Color _cTemp = Color(0xFFE8823D);

// The dashed critical-threshold line colour + the amber "restart required"
// alert-row tints (whitelisted literals).
const Color _cThresholdDash = Color(0xFF6B322C);
const Color _cWarnPanel = Color(0xFF1A1712);
const Color _cWarnTrack = Color(0xFFC88A2E);

/// The six series the history chart can plot. `cpu`/`ram`/`disk`/`swap` are
/// percentages (0-100); `load`/`temp` are not.
enum _Series { cpu, ram, disk, swap, load, temp }

extension _SeriesInfo on _Series {
  String get key => switch (this) {
        _Series.cpu => 'cpu',
        _Series.ram => 'ram',
        _Series.disk => 'disk',
        _Series.swap => 'swap',
        _Series.load => 'load',
        _Series.temp => 'temp',
      };

  Color get color => switch (this) {
        _Series.cpu => _cCpu,
        _Series.ram => _cRam,
        _Series.disk => _cDisk,
        _Series.swap => _cSwap,
        _Series.load => _cLoad,
        _Series.temp => _cTemp,
      };

  bool get isPercent =>
      this == _Series.cpu ||
      this == _Series.ram ||
      this == _Series.disk ||
      this == _Series.swap;

  /// Short legend label (CPU / RAM / Disk / Swap / Load / Temp).
  String label(AppLocalizations l10n) => switch (this) {
        _Series.cpu => l10n.zestMonMetricCpu,
        _Series.ram => l10n.zestMonMetricRam,
        _Series.disk => l10n.zestMonMetricDisk,
        _Series.swap => l10n.zestMonMetricSwap,
        _Series.load => l10n.zestMonSeriesLoad,
        _Series.temp => l10n.zestMonMetricTemp,
      };

  /// The plotted value from one history sample, or null (a gap).
  double? sampleValue(MonitorSample s) => switch (this) {
        _Series.cpu => s.cpuPercent,
        _Series.ram => s.ramPercent,
        _Series.disk => s.diskPercent,
        _Series.swap => s.swapPercent,
        _Series.load => s.load1,
        _Series.temp => s.tempC,
      };

  /// The current value from the live sample, for the legend read-out.
  double? liveValue(ServerStats? s) {
    if (s == null) return null;
    return switch (this) {
      _Series.cpu => s.cpuPercent,
      _Series.ram => s.ramPercent,
      _Series.disk => s.diskPercent,
      _Series.swap => s.swapPercent,
      _Series.load => s.load1,
      _Series.temp => s.tempC,
    };
  }
}

const List<_Series> _kSeriesOrder = [
  _Series.cpu,
  _Series.ram,
  _Series.disk,
  _Series.swap,
  _Series.load,
  _Series.temp,
];

/// The host detail pane. Fed the freshly-resolved [view] + [stats] each time the
/// table rebuilds, so its numbers track the live collection.
class MonitorDetailPane extends ConsumerStatefulWidget {
  const MonitorDetailPane({
    super.key,
    required this.details,
    required this.view,
    required this.stats,
    required this.onClose,
    required this.onRefresh,
    required this.onViewFailedUnits,
  });

  final ConnectionWithDetails details;
  final MonitorHostView view;
  final ServerStats? stats;
  final VoidCallback onClose;

  /// Refresh just this host (health + a single stats collect).
  final Future<void> Function() onRefresh;

  /// Open a terminal on this host running `systemctl --failed`.
  final VoidCallback onViewFailedUnits;

  @override
  ConsumerState<MonitorDetailPane> createState() => _MonitorDetailPaneState();
}

class _MonitorDetailPaneState extends ConsumerState<MonitorDetailPane> {
  MonitorHistoryRange _range = MonitorHistoryRange.twentyFourHours;
  late Set<_Series> _visible;
  bool _refreshing = false;

  /// Horizontal position (0..1 across the chart) the pointer is hovering /
  /// scrubbing, or null when not interacting. Drives the crosshair + time
  /// tooltip on the history chart.
  double? _chartHoverFrac;

  String get _connectionId => widget.details.connection.id;

  @override
  void initState() {
    super.initState();
    _visible = _loadVisible();
  }

  @override
  void didUpdateWidget(MonitorDetailPane old) {
    super.didUpdateWidget(old);
    // Selecting a different host re-seeds the persisted legend for that host.
    if (old.details.connection.id != _connectionId) {
      _visible = _loadVisible();
      _range = MonitorHistoryRange.twentyFourHours;
    }
  }

  Set<_Series> _loadVisible() {
    final keys =
        ref.read(monitorChartSeriesStoreProvider).getFor(_connectionId).toSet();
    return _kSeriesOrder.where((s) => keys.contains(s.key)).toSet();
  }

  void _toggleSeries(_Series s) {
    setState(() {
      if (_visible.contains(s)) {
        _visible.remove(s);
      } else {
        _visible.add(s);
      }
    });
    // Persist in fixed order so the stored list is stable.
    final ordered =
        _kSeriesOrder.where(_visible.contains).map((e) => e.key).toList();
    ref.read(monitorChartSeriesStoreProvider).setFor(_connectionId, ordered);
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.v3Background,
        border: Border(
          left: BorderSide(color: AppColors.v3BorderSubtle, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context, l10n),
          Divider(height: 1, color: AppColors.v3BorderSubtle),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(14, 13, 14, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _historySection(context, l10n),
                  const SizedBox(height: 18),
                  _nowSection(context, l10n),
                  const SizedBox(height: 18),
                  _filesystemsSection(context, l10n),
                  _systemSection(context, l10n),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Header ───────────────────────────────────────────────────────────

  Widget _header(BuildContext context, AppLocalizations l10n) {
    final conn = widget.details.connection;
    // Recording mode: the header paints the display forms (this pane is also
    // the mobile detail screen's chrome, so both surfaces mask alike).
    final name = conn.label.isNotEmpty
        ? Redactable.host(conn.label).displayIn(ref)
        : Redactable.address(conn.host).displayIn(ref);
    final osKind = ref.watch(detectedOsProvider(_connectionId));
    final osId = osKind != null ? _osKindToCatalogId(osKind) : null;

    final checked = _checkedAgo(widget.view.statsCollectedAt, l10n);
    final hostPort =
        Redactable.address(hostWithPort(conn.host, conn.port)).displayIn(ref);
    final sub = checked == null ? hostPort : '$hostPort · $checked';

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      child: Row(
        children: [
          OsIcon(osId: osId, size: 30, cornerRadius: 8),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.v3TextPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 7),
                    ZestStatusPill(
                      kind: widget.view.bucket.kind,
                      label: widget.view.bucket.label(l10n),
                      icon: widget.view.bucket.icon,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'JetBrainsMono',
                    color: AppColors.v3TextTertiary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: l10n.zestMonRefresh,
            onPressed: _refreshing ? null : _refresh,
            visualDensity: VisualDensity.compact,
            icon: _refreshing
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.v3AccentPrimary,
                    ),
                  )
                : Icon(LucideIcons.refreshCw,
                    size: 18, color: AppColors.v3TextSecondary),
          ),
          IconButton(
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: widget.onClose,
            visualDensity: VisualDensity.compact,
            icon:
                Icon(LucideIcons.x, size: 18, color: AppColors.v3TextSecondary),
          ),
        ],
      ),
    );
  }

  // ── History ──────────────────────────────────────────────────────────

  Widget _historySection(BuildContext context, AppLocalizations l10n) {
    final samplesAsync =
        ref.watch(monitorHistorySamplesProvider((_connectionId, _range)));
    final samples = samplesAsync.valueOrNull ?? const <MonitorSample>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZestSectionHeader(
          label: l10n.zestMonHistory,
          trailing: _RangeTabs(
            range: _range,
            onChanged: (r) => setState(() => _range = r),
          ),
        ),
        const SizedBox(height: 10),
        _chart(context, l10n, samples),
        const SizedBox(height: 9),
        _legend(context, l10n),
        const SizedBox(height: 8),
        Text(
          // A touch screen's word for it on a phone or a tablet.
          _touch(Theme.of(context).platform) ? l10n.zestMonLegendHintTap : l10n.zestMonLegendHint,
          key: const ValueKey('monitor-legend-hint'),
          style: TextStyle(
            fontSize: 11,
            height: 1.5,
            color: AppColors.v3TextTertiary,
          ),
        ),
      ],
    );
  }

  Widget _chart(
    BuildContext context,
    AppLocalizations l10n,
    List<MonitorSample> samples,
  ) {
    // Axis mode: percentage 0-100 by default; Load or Temp ALONE rescales to
    // its own range (spec §2.1).
    final visiblePercent = _visible.where((s) => s.isPercent).toList();
    final visibleNonPercent = _visible.where((s) => !s.isPercent).toList();
    final singleNonPercent =
        visiblePercent.isEmpty && visibleNonPercent.length == 1;

    // Topmost visible metric drives the dashed critical line.
    _Series? top;
    for (final s in _kSeriesOrder) {
      if (_visible.contains(s)) {
        top = s;
        break;
      }
    }

    // Time window for the x axis. When there is LESS history than the selected
    // range, fit the axis to the data that actually exists (earliest sample ..
    // now) instead of stretching a few recent points across the full range -
    // that drew a near-empty plot with a diagonal artifact jammed against the
    // right edge (spec §2.1: "plot only the span that has data").
    final now = DateTime.now();
    final rangeSince = now.subtract(_range.span);
    DateTime since = rangeSince;
    if (samples.isNotEmpty) {
      final earliest = samples
          .map((s) => s.capturedAt)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      if (earliest.isAfter(rangeSince)) since = earliest;
    }
    final totalMs = now.difference(since).inMilliseconds;

    // Build one line per visible series (in fixed order).
    final lines = <_ChartLine>[];
    double dataMax = 0;
    for (final s in _kSeriesOrder) {
      if (!_visible.contains(s)) continue;
      final pts = <_ChartPoint?>[];
      var hasAny = false;
      for (final sample in samples) {
        final v = s.sampleValue(sample);
        if (v == null) {
          pts.add(null);
          continue;
        }
        hasAny = true;
        if (v > dataMax) dataMax = v;
        final xFrac = totalMs <= 0
            ? 0.0
            : (sample.capturedAt.difference(since).inMilliseconds / totalMs)
                .clamp(0.0, 1.0);
        pts.add(_ChartPoint(xFrac.toDouble(), v));
      }
      if (hasAny) lines.add(_ChartLine(s.color, pts));
    }

    double axisMin = 0;
    double axisMax = 100;
    if (singleNonPercent) {
      final s = visibleNonPercent.first;
      final floor = s == _Series.temp ? 40.0 : 1.0;
      axisMax = math.max(dataMax * 1.1, floor);
    }

    // Dashed critical line value, in axis units, for the top visible metric.
    double? threshold;
    if (top != null) {
      if (singleNonPercent) {
        // Only Temp has a critical in its own units; Load has none.
        if (top == _Series.temp) {
          threshold = widget.view.metricEval(MonitorMetric.temp)?.crit;
        }
      } else {
        // Percent axis: only percentage metrics contribute a line at their
        // critical. Load/Temp thresholds are meaningless on a 0-100 axis.
        threshold = switch (top) {
          _Series.cpu => widget.view.metricEval(MonitorMetric.cpu)?.crit,
          _Series.ram => widget.view.metricEval(MonitorMetric.ram)?.crit,
          _Series.disk => widget.view.metricEval(MonitorMetric.disk)?.crit,
          _Series.swap => widget.view.metricEval(MonitorMetric.swap)?.crit,
          _ => null,
        };
      }
    }

    final empty = samples.isEmpty;

    // Snap the pointer position to the nearest real sample and gather its time
    // + per-series values for the hover tooltip.
    _ChartHover? hover;
    if (_chartHoverFrac != null && !empty && totalMs > 0) {
      final hf = _chartHoverFrac!;
      MonitorSample? best;
      var bestDx = double.infinity;
      for (final sm in samples) {
        final xf = (sm.capturedAt.difference(since).inMilliseconds / totalMs)
            .clamp(0.0, 1.0);
        final dx = (xf - hf).abs();
        if (dx < bestDx) {
          bestDx = dx;
          best = sm;
        }
      }
      if (best != null) {
        final snapXFrac =
            (best.capturedAt.difference(since).inMilliseconds / totalMs)
                .clamp(0.0, 1.0);
        final entries = <_HoverEntry>[];
        for (final s in _kSeriesOrder) {
          if (!_visible.contains(s)) continue;
          final v = s.sampleValue(best);
          if (v == null) continue;
          entries.add(_HoverEntry(s.color, _fmtSeriesValue(s, v), v));
        }
        hover = _ChartHover(
          snapXFrac.toDouble(),
          _fmtHoverTime(l10n, best.capturedAt, _range),
          entries,
        );
      }
    }

    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: AppColors.v3ChromeBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.v3BorderSubtle, width: 1),
      ),
      child: SizedBox(
        height: 110,
        child: empty
            ? Center(
                child: Text(
                  l10n.zestMonNoHistory,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: AppColors.v3TextTertiary,
                  ),
                ),
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.maxWidth;
                  void setFrac(double dx) {
                    if (w <= 0) return;
                    final f = (dx / w).clamp(0.0, 1.0);
                    if (f != _chartHoverFrac) {
                      setState(() => _chartHoverFrac = f);
                    }
                  }

                  void clear() {
                    if (_chartHoverFrac != null) {
                      setState(() => _chartHoverFrac = null);
                    }
                  }

                  return MouseRegion(
                    // Desktop: track the mouse; hide when it leaves.
                    onHover: (e) => setFrac(e.localPosition.dx),
                    onExit: (_) => clear(),
                    child: Listener(
                      // Touch: scrub while a finger is down, hide on release.
                      onPointerDown: (e) => setFrac(e.localPosition.dx),
                      onPointerMove: (e) => setFrac(e.localPosition.dx),
                      onPointerUp: (_) => clear(),
                      onPointerCancel: (_) => clear(),
                      child: CustomPaint(
                        size: Size.infinite,
                        painter: _HistoryChartPainter(
                          lines: lines,
                          axisMin: axisMin,
                          axisMax: axisMax,
                          threshold: threshold,
                          gridColor: AppColors.v3BorderSubtle,
                          dashColor: _cThresholdDash,
                          labelColor: AppColors.v3TextTertiary,
                          showAxisLabels: singleNonPercent,
                          hover: hover,
                          tooltipBg: AppColors.v3ChromeBg,
                          tooltipText: AppColors.v3TextPrimary,
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }

  /// Format a hovered sample's time: HH:mm for the 2h/24h ranges, and the
  /// day and month before it for the 7d range where a bare time would be
  /// ambiguous, as [l10n]'s language writes them.
  String _fmtHoverTime(AppLocalizations l10n, DateTime t, MonitorHistoryRange range) {
    if (range == MonitorHistoryRange.sevenDays) return DateFormat.MMMd(l10n.localeName).add_Hm().formatPlain(t);
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  String _fmtSeriesValue(_Series s, double v) => switch (s) {
        _Series.load => formatDecimal(v, digits: 2),
        _Series.temp => '${formatDecimal(v, digits: 0)}°C',
        _ => formatPercentNumber(v),
      };

  Widget _legend(BuildContext context, AppLocalizations l10n) {
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        for (final s in _kSeriesOrder)
          _LegendItem(
            label: s.label(l10n),
            valueText: _visible.contains(s)
                ? _seriesValueText(s, l10n)
                : null,
            color: s.color,
            visible: _visible.contains(s),
            onTap: () => _toggleSeries(s),
          ),
      ],
    );
  }

  String? _seriesValueText(_Series s, AppLocalizations l10n) {
    final v = s.liveValue(widget.stats);
    if (v == null) return l10n.zestMonNotAvailable;
    return switch (s) {
      _Series.load => formatDecimal(v, digits: 2, l10n: l10n),
      _Series.temp => '${formatDecimal(v, digits: 0, l10n: l10n)}°C',
      _ => formatPercentNumber(v, l10n: l10n),
    };
  }

  // ── Now ──────────────────────────────────────────────────────────────

  Widget _nowSection(BuildContext context, AppLocalizations l10n) {
    final stats = widget.stats;
    final caps = ref.watch(monitorCapabilitiesProvider(_connectionId));

    final cpuEval = widget.view.metricEval(MonitorMetric.cpu);
    final ramEval = widget.view.metricEval(MonitorMetric.ram);
    final swapEval = widget.view.metricEval(MonitorMetric.swap);
    final tempEval = widget.view.metricEval(MonitorMetric.temp);
    final latEval = widget.view.metricEval(MonitorMetric.latency);

    // Swap / Temp are now real scored metrics - read their value + resolved
    // severity + thresholds straight off the host view (per-host overrides
    // included), matching how CPU/RAM read theirs (null when stale → N/A).
    final swapV = swapEval?.value;
    final swapSev = swapV == null ? null : swapEval?.severity;
    final tempV = tempEval?.value;
    final tempSev = tempV == null ? null : tempEval?.severity;
    final pingV = stats?.pingMs?.toDouble();
    final pingSev = (pingV == null || latEval == null)
        ? null
        : _sev(pingV, latEval.warn, latEval.crit);

    final netReportable = caps.can(MonitorCapabilities.kNetIo) ||
        stats?.netRxBytesPerSec != null ||
        stats?.netTxBytesPerSec != null;
    final diskIoReportable = caps.can(MonitorCapabilities.kDiskIo) ||
        stats?.diskReadBytesPerSec != null ||
        stats?.diskWriteBytesPerSec != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZestSectionHeader(
          label: l10n.zestMonNow,
          trailing: _SectionAction(
            label: l10n.zestMonEditThresholds,
            onTap: () =>
                showMonitorThresholds(context, hostId: _connectionId),
          ),
        ),
        const SizedBox(height: 10),
        // Row 1 - percentage cards with a track + threshold tick.
        Row(
          children: [
            Expanded(
              child: _TrackCard(
                label: l10n.zestMonMetricCpu,
                value: cpuEval?.value,
                severity: cpuEval?.severity,
                crit: cpuEval?.crit ?? 85,
                l10n: l10n,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _TrackCard(
                label: l10n.zestMonMetricRam,
                value: ramEval?.value,
                severity: ramEval?.severity,
                crit: ramEval?.crit ?? 85,
                l10n: l10n,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _TrackCard(
                label: l10n.zestMonMetricSwap,
                value: swapV,
                severity: swapSev,
                crit: swapEval?.crit ?? 85,
                l10n: l10n,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // Row 2 - non-percentage values, no track.
        Row(
          children: [
            Expanded(
              child: _ValueCard(
                label: l10n.zestMonMetricLoad,
                valueText: _loadText(stats),
                small: true,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _ValueCard(
                label: l10n.zestMonMetricTemp,
                valueText: tempV == null
                    ? l10n.zestMonNotAvailable
                    : '${formatDecimal(tempV, digits: 0, l10n: l10n)}°C',
                severity: tempSev,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _ValueCard(
                label: l10n.zestMonMetricPing,
                valueText: pingV == null
                    ? l10n.zestMonNotAvailable
                    : pingV < 1
                        ? '<1ms'
                        : '${formatDecimal(pingV, digits: 0, l10n: l10n)}ms',
                severity: pingSev,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // Wide row - Network + Disk I/O.
        Row(
          children: [
            Expanded(
              child: _ValueCard(
                label: l10n.zestMonMetricNetwork,
                valueText: netReportable
                    ? l10n.zestMonNetworkValue(
                        _rate(stats?.netRxBytesPerSec, l10n),
                        _rate(stats?.netTxBytesPerSec, l10n),
                      )
                    : l10n.zestMonNotAvailable,
                extraSmall: true,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _ValueCard(
                label: l10n.zestMonMetricDiskIo,
                valueText: diskIoReportable
                    ? l10n.zestMonDiskIoValue(
                        _rate(stats?.diskReadBytesPerSec, l10n),
                        _rate(stats?.diskWriteBytesPerSec, l10n),
                      )
                    : l10n.zestMonNotAvailable,
                extraSmall: true,
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _loadText(ServerStats? s) {
    final l1 = s?.load1, l5 = s?.load5, l15 = s?.load15;
    if (l1 == null && l5 == null && l15 == null) {
      return AppLocalizations.of(context)!.zestMonNotAvailable;
    }
    String f(double? v) => v == null ? '-' : formatDecimal(v);
    return '${f(l1)} ${f(l5)} ${f(l15)}';
  }

  String _rate(double? bytesPerSec, AppLocalizations l10n) {
    if (bytesPerSec == null) return l10n.zestMonNotAvailable;
    return _fmtRate(bytesPerSec);
  }

  // ── Filesystems ──────────────────────────────────────────────────────

  Widget _filesystemsSection(BuildContext context, AppLocalizations l10n) {
    final stats = widget.stats;
    final filesystems = stats?.filesystems ?? const <FilesystemUsage>[];
    final inodes = stats?.inodesRootPercent;
    if (filesystems.isEmpty && inodes == null) return const SizedBox.shrink();

    final diskCrit = widget.view.metricEval(MonitorMetric.disk)?.crit ?? 90;

    // Merge the mounts + the inodes pseudo-row, then sort by usage descending
    // (spec §2.3 - the inodes row participates in the sort).
    final rows = <_FsRow>[
      for (final fs in filesystems)
        _FsRow(
          mount: fs.mount,
          percent: fs.usedPercent,
          sizeText: l10n.zestMonFsSize(_fmtSize(fs.usedBytes),
              _fmtSize(fs.totalBytes)),
        ),
      if (inodes != null)
        _FsRow(
          mount: l10n.zestMonInodes('/'),
          percent: inodes,
          sizeText: formatPercentNumber(inodes, l10n: l10n),
        ),
    ]..sort((a, b) => b.percent.compareTo(a.percent));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZestSectionHeader(label: l10n.zestMonFilesystems, count: rows.length),
        const SizedBox(height: 10),
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: 4),
          _FilesystemRow(row: rows[i], crit: diskCrit),
        ],
        const SizedBox(height: 18),
      ],
    );
  }

  // ── System ───────────────────────────────────────────────────────────

  Widget _systemSection(BuildContext context, AppLocalizations l10n) {
    final stats = widget.stats;
    if (stats == null) return const SizedBox.shrink();

    final rows = <Widget>[];

    if (stats.restartRequired == true) {
      rows.add(_SystemRow.alert(
        icon: LucideIcons.rotateCcw,
        text: l10n.zestMonRestartRequired,
      ));
    }
    if (stats.updatesTotal != null) {
      rows.add(_SystemRow(
        icon: LucideIcons.archive,
        text: l10n.zestMonUpdates(
            stats.updatesTotal!, stats.updatesSecurity ?? 0),
      ));
    }
    // Always show the failed-units line on a systemd host (failedUnits
    // non-null): the healthy "no failed units" state is a positive
    // confirmation, and only a real failure carries the View action.
    if (stats.failedUnits != null) {
      final failed = stats.failedUnits!;
      rows.add(_SystemRow(
        icon: failed > 0
            ? LucideIcons.octagon
            : LucideIcons.checkCircle2,
        text: failed > 0
            ? l10n.zestMonFailedUnits(failed)
            : l10n.zestMonNoFailedUnits,
        actionLabel: failed > 0 ? l10n.zestMonFailedUnitsView : null,
        onAction: failed > 0 ? widget.onViewFailedUnits : null,
      ));
    }
    if (stats.processesTotal != null) {
      rows.add(_SystemRow(
        icon: LucideIcons.alertTriangle,
        text: l10n.zestMonProcesses(
            stats.zombieProcesses ?? 0, stats.processesTotal!),
      ));
    }
    // OS line - always last.
    rows.add(_SystemRow(
      icon: LucideIcons.info,
      text: l10n.zestMonOsLine(
        stats.osName ?? l10n.zestMonNotAvailable,
        stats.kernel ?? l10n.zestMonNotAvailable,
        _uptimeText(stats, l10n),
      ),
      mono: true,
    ));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZestSectionHeader(label: l10n.zestMonSystem),
        const SizedBox(height: 10),
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: 4),
          rows[i],
        ],
      ],
    );
  }

  String _uptimeText(ServerStats s, AppLocalizations l10n) {
    final secs = s.uptimeSeconds;
    if (secs != null) return _fmtUptime(secs);
    return s.uptime ?? l10n.zestMonNotAvailable;
  }

  // ── Small formatting helpers ─────────────────────────────────────────

  String? _checkedAgo(DateTime? t, AppLocalizations l10n) {
    if (t == null) return null;
    return l10n.zestMonCheckedAgo(timeSinceShort(l10n, t));
  }
}

MetricSeverity _sev(double v, double warn, double crit) => v >= crit
    ? MetricSeverity.critical
    : v >= warn
        ? MetricSeverity.warning
        : MetricSeverity.healthy;

Color _severityColor(MetricSeverity? s) => switch (s) {
      MetricSeverity.critical => AppColors.error,
      MetricSeverity.warning => AppColors.warning,
      MetricSeverity.healthy => AppColors.success,
      null => AppColors.v3TextTertiary,
    };

String _fmtRate(double bytesPerSec) => formatByteRate(bytesPerSec, digits: SizeDigits.belowTen);

String _fmtSize(int bytes) => formatByteSize(bytes, digits: SizeDigits.belowTen);

String _fmtUptime(int secs) {
  final d = secs ~/ 86400;
  final h = (secs % 86400) ~/ 3600;
  final m = (secs % 3600) ~/ 60;
  if (d > 0) return '${d}d ${h}h';
  if (h > 0) return '${h}h ${m}m';
  return '${m}m';
}

/// OsKind → OS-catalog id (a self-contained copy of the hosts-page mapping so
/// the pane can render the branded OS tile without importing that page).
String? _osKindToCatalogId(OsKind kind) => switch (kind) {
      OsKind.ubuntu => 'ubuntu',
      OsKind.debian => 'debian',
      OsKind.fedora => 'fedora',
      OsKind.centos => 'centos',
      OsKind.rhel => 'rhel',
      OsKind.arch => 'arch',
      OsKind.alpine => 'alpine',
      OsKind.nixos => 'nixos',
      OsKind.opensuse => 'opensuse',
      OsKind.gentoo => 'gentoo',
      OsKind.mint => 'mint',
      OsKind.pop => 'pop',
      OsKind.manjaro => 'manjaro',
      OsKind.kali => 'kali',
      OsKind.raspbian => 'raspberry_pi',
      OsKind.rocky => 'rocky',
      OsKind.alma => 'alma',
      OsKind.void_ => 'void',
      OsKind.slackware => null,
      OsKind.freebsd => 'freebsd',
      OsKind.openbsd => 'openbsd',
      OsKind.netbsd => 'netbsd',
      OsKind.macos => 'macos',
      OsKind.windows => 'windows',
      OsKind.synology => null,
      OsKind.unraid => 'unraid',
      OsKind.truenas => 'truenas',
      OsKind.openwrt => null,
      OsKind.ddwrt => null,
      OsKind.linux => 'unknown',
      OsKind.unknown => null,
    };

// ══════════════════════════════════════════════════════════════════════
// Range tabs (History section header trailing)
// ══════════════════════════════════════════════════════════════════════

class _RangeTabs extends StatelessWidget {
  const _RangeTabs({required this.range, required this.onChanged});

  final MonitorHistoryRange range;
  final ValueChanged<MonitorHistoryRange> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Widget tab(MonitorHistoryRange r, String label) {
      final on = r == range;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(r),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: on ? FontWeight.w600 : FontWeight.w400,
              color: on ? AppColors.v3AccentInk : AppColors.v3TextTertiary,
            ),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        tab(MonitorHistoryRange.twoHours, l10n.zestMonRange2h),
        tab(MonitorHistoryRange.twentyFourHours, l10n.zestMonRange24h),
        tab(MonitorHistoryRange.sevenDays, l10n.zestMonRange7d),
      ],
    );
  }
}

/// A right-aligned brand text action for a section header (e.g. "Edit
/// thresholds").
class _SectionAction extends StatelessWidget {
  const _SectionAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AppColors.v3AccentInk,
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// Legend item (toggle)
// ══════════════════════════════════════════════════════════════════════

class _LegendItem extends StatelessWidget {
  const _LegendItem({
    required this.label,
    required this.valueText,
    required this.color,
    required this.visible,
    required this.onTap,
  });

  final String label;
  final String? valueText;
  final Color color;
  final bool visible;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 9,
              height: 2,
              decoration: BoxDecoration(
                color: visible ? color : AppColors.v3TextTertiary,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              valueText == null ? label : '$label $valueText',
              style: TextStyle(
                fontSize: 11,
                color: visible
                    ? AppColors.v3TextSecondary
                    : AppColors.v3TextTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// Now cards
// ══════════════════════════════════════════════════════════════════════

/// A percentage card: label, mono value coloured by status, then a track with
/// fill + threshold tick (spec §2.2 row 1).
class _TrackCard extends StatelessWidget {
  const _TrackCard({
    required this.label,
    required this.value,
    required this.severity,
    required this.crit,
    required this.l10n,
  });

  final String label;
  final double? value;
  final MetricSeverity? severity;
  final double crit;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final v = value;
    final color = _severityColor(severity);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
      decoration: BoxDecoration(
        color: AppColors.v3Surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 10, color: AppColors.v3TextTertiary),
          ),
          const SizedBox(height: 2),
          Text(
            v == null ? l10n.zestMonNotAvailable : formatPercentNumber(v, l10n: l10n),
            style: TextStyle(
              fontSize: 15,
              fontFamily: 'JetBrainsMono',
              color: v == null ? AppColors.v3TextTertiary : color,
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 3,
            width: double.infinity,
            child: v == null
                ? null
                : CustomPaint(
                    size: Size.infinite,
                    painter: _TrackPainter(
                      value: v,
                      color: color,
                      crit: crit,
                      trackColor: AppColors.v3BorderSubtle,
                      tickColor: AppColors.v3TextTertiary,
                      tickHitColor: AppColors.v3TextPrimary,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// A value-only card (spec §2.2 row 2 + wide row): label + mono value, no track.
class _ValueCard extends StatelessWidget {
  const _ValueCard({
    required this.label,
    required this.valueText,
    this.severity,
    this.small = false,
    this.extraSmall = false,
  });

  final String label;
  final String valueText;
  final MetricSeverity? severity;
  final bool small;
  final bool extraSmall;

  @override
  Widget build(BuildContext context) {
    final na = valueText == AppLocalizations.of(context)!.zestMonNotAvailable;
    final color = na
        ? AppColors.v3TextTertiary
        : (severity != null
            ? _severityColor(severity)
            : AppColors.v3TextSecondary);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
      decoration: BoxDecoration(
        color: AppColors.v3Surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 10, color: AppColors.v3TextTertiary),
          ),
          SizedBox(height: extraSmall ? 3 : (small ? 4 : 2)),
          Text(
            valueText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: extraSmall ? 12 : (small ? 13 : 15),
              fontFamily: 'JetBrainsMono',
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// Filesystem row
// ══════════════════════════════════════════════════════════════════════

class _FsRow {
  const _FsRow({
    required this.mount,
    required this.percent,
    required this.sizeText,
  });
  final String mount;
  final double percent;
  final String sizeText;
}

class _FilesystemRow extends StatelessWidget {
  const _FilesystemRow({required this.row, required this.crit});

  final _FsRow row;
  final double crit;

  @override
  Widget build(BuildContext context) {
    // Colour the fill by usage vs the disk thresholds so a full mount reads red.
    final sev = _sev(row.percent, crit - 10, crit);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.v3Surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 82,
            child: Text(
              row.mount,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'JetBrainsMono',
                color: AppColors.v3TextSecondary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SizedBox(
              height: 3,
              child: CustomPaint(
                size: Size.infinite,
                painter: _TrackPainter(
                  value: row.percent,
                  color: _severityColor(sev),
                  crit: crit,
                  trackColor: AppColors.v3BorderSubtle,
                  tickColor: AppColors.v3TextTertiary,
                  tickHitColor: AppColors.v3TextPrimary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 92,
            child: Text(
              row.sizeText,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'JetBrainsMono',
                color: AppColors.v3TextSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// System row
// ══════════════════════════════════════════════════════════════════════

class _SystemRow extends StatelessWidget {
  const _SystemRow({
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
    this.mono = false,
  }) : alert = false;

  const _SystemRow.alert({required this.icon, required this.text})
      : actionLabel = null,
        onAction = null,
        mono = false,
        alert = true;

  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool mono;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    final iconColor =
        alert ? AppColors.warning : AppColors.v3TextSecondary;
    final textColor =
        alert ? AppColors.warning : AppColors.v3TextSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: alert ? _cWarnPanel : AppColors.v3Surface,
        borderRadius: alert ? BorderRadius.zero : BorderRadius.circular(8),
        border: alert
            ? const Border(left: BorderSide(color: _cWarnTrack, width: 3))
            : null,
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: iconColor),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: mono ? 11 : 12,
                fontFamily: mono ? 'JetBrainsMono' : null,
                color: textColor,
              ),
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(width: 9),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onAction,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Text(
                  actionLabel!,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.v3AccentInk,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// Painters
// ══════════════════════════════════════════════════════════════════════

class _ChartPoint {
  const _ChartPoint(this.xFrac, this.value);
  final double xFrac;
  final double value;
}

class _ChartLine {
  const _ChartLine(this.color, this.points);
  final Color color;
  final List<_ChartPoint?> points;
}

/// One series' value at the hovered sample, for the crosshair tooltip.
class _HoverEntry {
  const _HoverEntry(this.color, this.text, this.value);
  final Color color;
  final String text;
  final double value;
}

/// The hovered/scrubbed point on the history chart: where the crosshair sits
/// (0..1 across the width, snapped to a real sample), its formatted time, and
/// each visible series' value there.
class _ChartHover {
  const _ChartHover(this.xFrac, this.timeLabel, this.entries);
  final double xFrac;
  final String timeLabel;
  final List<_HoverEntry> entries;
}

/// Paints the multi-series history chart: three gridlines at 25/50/75%, a dashed
/// critical line for the top visible metric, and one rounded polyline per series
/// (spec §2.1).
class _HistoryChartPainter extends CustomPainter {
  _HistoryChartPainter({
    required this.lines,
    required this.axisMin,
    required this.axisMax,
    required this.threshold,
    required this.gridColor,
    required this.dashColor,
    required this.labelColor,
    required this.showAxisLabels,
    this.hover,
    required this.tooltipBg,
    required this.tooltipText,
  });

  final List<_ChartLine> lines;
  final double axisMin;
  final double axisMax;
  final double? threshold;
  final Color gridColor;
  final Color dashColor;
  final Color labelColor;
  final bool showAxisLabels;
  final _ChartHover? hover;
  final Color tooltipBg;
  final Color tooltipText;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (final frac in const [0.25, 0.5, 0.75]) {
      final y = h * frac;
      canvas.drawLine(Offset(0, y), Offset(w, y), grid);
    }

    if (showAxisLabels) {
      for (final frac in const [0.25, 0.5, 0.75]) {
        final value = axisMax - (axisMax - axisMin) * frac;
        _drawLabel(canvas, formatDecimal(value, digits: 0), Offset(2, h * frac - 6));
      }
    }

    final span = (axisMax - axisMin).abs() < 1e-9 ? 1.0 : axisMax - axisMin;
    // Plot inside the middle ~84% so a line at 0/100 doesn't sit on the edge.
    const padTop = 0.08;
    const padBottom = 0.08;
    double yFor(double v) {
      final norm = ((v - axisMin) / span).clamp(0.0, 1.0);
      return h * padTop + (1 - norm) * h * (1 - padTop - padBottom);
    }

    if (threshold != null) {
      final y = yFor(threshold!);
      final dash = Paint()
        ..color = dashColor
        ..strokeWidth = 1;
      const dashW = 3.0, gapW = 4.0;
      var x = 0.0;
      while (x < w) {
        canvas.drawLine(Offset(x, y), Offset(math.min(x + dashW, w), y), dash);
        x += dashW + gapW;
      }
    }

    for (final line in lines) {
      final paint = Paint()
        ..color = line.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;

      Path? path;
      var seg = 0;
      Offset? last;
      void flush() {
        if (path != null && seg >= 2) {
          canvas.drawPath(path!, paint);
        } else if (path != null && seg == 1 && last != null) {
          canvas.drawCircle(last, 1.2, Paint()..color = line.color);
        }
        path = null;
        seg = 0;
      }

      for (final p in line.points) {
        if (p == null) {
          flush();
          continue;
        }
        final o = Offset(p.xFrac * w, yFor(p.value));
        if (path == null) {
          path = Path()..moveTo(o.dx, o.dy);
        } else {
          path!.lineTo(o.dx, o.dy);
        }
        last = o;
        seg++;
      }
      flush();
    }

    // ── Hover crosshair + time tooltip ──────────────────────────────────
    final hv = hover;
    if (hv != null) {
      final hx = hv.xFrac.clamp(0.0, 1.0) * w;
      canvas.drawLine(
        Offset(hx, 0),
        Offset(hx, h),
        Paint()
          ..color = labelColor.withValues(alpha: 0.55)
          ..strokeWidth = 1,
      );
      for (final e in hv.entries) {
        final dy = yFor(e.value);
        canvas.drawCircle(Offset(hx, dy), 3, Paint()..color = tooltipBg);
        canvas.drawCircle(Offset(hx, dy), 2.4, Paint()..color = e.color);
      }
      _drawTooltip(canvas, size, hx, hv);
    }
  }

  /// The time (bold) plus one colored value line per series, in a small pinned
  /// box that flips to the left of the crosshair near the right edge.
  void _drawTooltip(Canvas canvas, Size size, double hx, _ChartHover hv) {
    final timeTp = TextPainter(
      text: TextSpan(
        text: hv.timeLabel,
        style: TextStyle(
          color: tooltipText,
          fontSize: 9.5,
          fontFamily: 'JetBrainsMono',
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final valueTps = [
      for (final e in hv.entries)
        TextPainter(
          text: TextSpan(
            text: e.text,
            style: TextStyle(
              color: e.color,
              fontSize: 9,
              fontFamily: 'JetBrainsMono',
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout()
    ];

    const padX = 5.0, padY = 4.0, lineGap = 2.0, dotW = 9.0;
    var contentW = timeTp.width;
    for (final tp in valueTps) {
      contentW = math.max(contentW, dotW + tp.width);
    }
    var contentH = timeTp.height;
    for (final tp in valueTps) {
      contentH += lineGap + tp.height;
    }
    final boxW = contentW + padX * 2;
    final boxH = contentH + padY * 2;

    var left = hx + 8;
    if (left + boxW > size.width) left = hx - 8 - boxW;
    left = left.clamp(0.0, math.max(0.0, size.width - boxW));
    const top = 2.0;

    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, boxW, boxH),
      const Radius.circular(4),
    );
    canvas.drawRRect(
        rect, Paint()..color = tooltipBg.withValues(alpha: 0.94));
    canvas.drawRRect(
      rect,
      Paint()
        ..color = gridColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    var y = top + padY;
    timeTp.paint(canvas, Offset(left + padX, y));
    y += timeTp.height + lineGap;
    for (var i = 0; i < valueTps.length; i++) {
      final tp = valueTps[i];
      canvas.drawCircle(
          Offset(left + padX + 2.5, y + tp.height / 2), 2.5,
          Paint()..color = hv.entries[i].color);
      tp.paint(canvas, Offset(left + padX + dotW, y));
      y += tp.height + lineGap;
    }
  }

  void _drawLabel(Canvas canvas, String text, Offset at) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: labelColor,
          fontSize: 8,
          fontFamily: 'JetBrainsMono',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_HistoryChartPainter old) =>
      old.lines != lines ||
      old.axisMin != axisMin ||
      old.axisMax != axisMax ||
      old.threshold != threshold ||
      old.showAxisLabels != showAxisLabels ||
      old.hover != hover;
}

/// Paints a 3px metric track: background, value fill, and one tick at the
/// critical threshold that brightens once crossed (spec §2.2).
class _TrackPainter extends CustomPainter {
  const _TrackPainter({
    required this.value,
    required this.color,
    required this.crit,
    required this.trackColor,
    required this.tickColor,
    required this.tickHitColor,
  });

  final double value; // 0..100
  final Color color;
  final double crit;
  final Color trackColor;
  final Color tickColor;
  final Color tickHitColor;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 2);
    final track = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width, size.height), r);
    canvas.drawRRect(track, Paint()..color = trackColor);

    final fillW = (value / 100).clamp(0.0, 1.0) * size.width;
    if (fillW > 0) {
      final fill = RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, fillW, size.height), r);
      canvas.drawRRect(fill, Paint()..color = color);
    }

    final x = (crit / 100).clamp(0.0, 1.0) * size.width;
    final crossed = value >= crit;
    final tick = Paint()
      ..color = crossed ? tickHitColor : tickColor.withValues(alpha: 0.7)
      ..strokeWidth = 1;
    final dx = x.clamp(0.5, size.width - 0.5);
    canvas.drawLine(Offset(dx, -1), Offset(dx, size.height + 1), tick);
  }

  @override
  bool shouldRepaint(_TrackPainter old) =>
      old.value != value || old.color != color || old.crit != crit;
}

/// Whether [platform] is a touch screen's (a phone or a tablet), where a
/// hint says tap, not click.
bool _touch(TargetPlatform platform) =>
    platform == TargetPlatform.iOS || platform == TargetPlatform.android || platform == TargetPlatform.fuchsia;
