import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:intl/intl.dart' show DateFormat;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/monitoring/monitor_evaluation.dart';
import 'package:zestssh/features/monitoring/monitor_host_alerts.dart';
import 'package:zestssh/features/monitoring/monitor_state_ui.dart';
import 'package:zestssh/features/monitoring/monitor_thresholds.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/command_history_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/providers/monitor_thresholds_provider.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/server_stats_service.dart';
import 'package:zestssh/ui/screens/port_forward/network_bind_confirm.dart';
import 'package:zestssh/ui/screens/port_forward/port_forward_screen.dart' show showPortForwardEditor;
import 'package:zestssh/ui/screens/purchase/pricing_modal.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/l10n/time_text.dart';
import 'package:zestssh/utils/number_text.dart';

// The host panel's sections that say what the app keeps of the host:
// its health with an alert choice per
// metric, its recent sessions, its port forwards. Each is shown only where it
// has something to say; the panel puts them under its own heads.

/// The status of [metric]'s alert choice on host [id], as its button says it.
enum _AlertState { normal, muted, snoozed }

// ── Health ─────────────────────────────────────────────────────────────

/// A watched host's health: when it was read, its load and how long it has
/// been up, then a row per metric (its bar, its value, where it alerts, and
/// its Alert menu). A metric over its limit is drawn in the warning colour,
/// its Alert button outlined in it.
class HostPanelHealth extends ConsumerWidget {
  const HostPanelHealth({super.key, required this.connectionId, required this.hostName, required this.view});

  final String connectionId;
  final String hostName;
  final MonitorHostView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final stats = ref.watch(serverStatsProvider)[connectionId];
    final prefs = ref.watch(hostAlertPrefsProvider)[connectionId] ?? const HostAlertPrefs();
    final info = <String>[
      if (stats != null) l10n.hpanelUpdated(timeSinceShort(l10n, stats.collectedAt)),
      if (stats?.load1 != null) l10n.hpanelLoad(formatDecimal(stats!.load1!, digits: 2, l10n: l10n)),
      if (stats?.uptimeSeconds != null && stats!.uptimeSeconds! > 0)
        l10n.hpanelUp(timeSinceShort(l10n, DateTime.now().subtract(Duration(seconds: stats.uptimeSeconds!)))),
    ];
    final rows = <Widget>[];
    for (final m in const [MonitorMetric.cpu, MonitorMetric.ram, MonitorMetric.swap]) {
      final e = view.metricEval(m);
      if (e == null || !e.available) continue;
      rows.add(_MetricRow(
        key: ValueKey('host-panel-metric-${m.name}'),
        label: monitorMetricLabel(m, l10n),
        eval: e,
        alert: _AlertButton(connectionId: connectionId, hostName: hostName, metric: m, eval: e, prefs: prefs, stats: stats),
      ));
    }
    // Disks: each mount the host reported, each with the disk metric's Alert
    // (one limit holds for every disk, so each opens the same menu; a mount
    // over the limit had none to its name).
    final disk = view.metricEval(MonitorMetric.disk);
    if (disk != null) {
      final mounts = stats?.filesystems ?? const <FilesystemUsage>[];
      if (mounts.isEmpty && disk.available) {
        rows.add(_MetricRow(
          key: const ValueKey('host-panel-metric-disk'),
          label: '${monitorMetricLabel(MonitorMetric.disk, l10n)} /',
          eval: disk,
          alert: _AlertButton(connectionId: connectionId, hostName: hostName, metric: MonitorMetric.disk, eval: disk, prefs: prefs, stats: stats),
        ));
      }
      for (var i = 0; i < mounts.length; i++) {
        final f = mounts[i];
        final e = MetricEval(
          metric: MonitorMetric.disk,
          value: f.usedPercent,
          warn: disk.warn,
          crit: disk.crit,
          severity: f.usedPercent >= disk.crit
              ? MetricSeverity.critical
              : f.usedPercent >= disk.warn
                  ? MetricSeverity.warning
                  : MetricSeverity.healthy,
          silenced: disk.silenced,
        );
        rows.add(_MetricRow(
          key: ValueKey('host-panel-metric-disk-${f.mount}'),
          label: '${monitorMetricLabel(MonitorMetric.disk, l10n)} ${f.mount}',
          eval: e,
          alert: _AlertButton(
            key: ValueKey('host-panel-alert-disk-${f.mount}'),
            connectionId: connectionId,
            hostName: hostName,
            metric: MonitorMetric.disk,
            eval: e,
            prefs: prefs,
            stats: stats,
            first: i == 0,
          ),
        ));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (info.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              info.join(' · '),
              key: const ValueKey('host-panel-health-info'),
              style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11, color: ZestColors.textTertiary),
            ),
          ),
        if (rows.isEmpty)
          Text(monitorPillTooltip(view, l10n), style: TextStyle(fontSize: 12, color: ZestColors.textTertiary))
        else
          ...rows,
      ],
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({super.key, required this.label, required this.eval, this.alert});

  final String label;
  final MetricEval eval;
  final Widget? alert;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final over = eval.severity != MetricSeverity.healthy;
    final tone = switch (eval.severity) {
      MetricSeverity.critical => ZestColors.statusError,
      MetricSeverity.warning => ZestColors.statusWarning,
      MetricSeverity.healthy => ZestColors.textSecondary,
    };
    if (touchSizedAt(context)) return _touch(over, tone);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: ZestColors.textSecondary)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  monitorMetricValue(eval.metric, eval.value!),
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: over ? tone : ZestColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: (eval.value! / eval.metric.bandMax).clamp(0.0, 1.0),
                    minHeight: 4,
                    backgroundColor: ZestColors.surfaceChip,
                    color: over ? tone : ZestColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // Where it alerts, at its own width up to a cap: a longer language
          // is cut with an ellipsis there rather than pushing the row out.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 110),
            child: Text(
              l10n.hpanelAlertsAt(monitorMetricValue(eval.metric, eval.warn)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: over ? tone : ZestColors.textTertiary),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(width: 84, child: Align(alignment: Alignment.centerRight, child: alert ?? const SizedBox.shrink())),
        ],
      ),
    );
  }
}

extension on _MetricRow {
  /// Touch sized (4.0, a tablet in landscape): the name, the
  /// value (with a mark as well as the colour while over its limit) and its
  /// one alert control ("Alerts at 70%", 48 high) on a line, and under them
  /// the bar the panel's width with a tick at the alert's limit.
  Widget _touch(bool over, Color tone) {
    final value = eval.value!;
    final max = eval.metric.bandMax;
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 64,
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: ZestColors.textSecondary)),
              ),
              if (over) ...[
                Icon(LucideIcons.alertCircle, size: 14, color: tone, key: ValueKey('host-panel-over-${eval.metric.name}')),
                const SizedBox(width: 4),
              ],
              Text(
                monitorMetricValue(eval.metric, value),
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: over ? tone : ZestColors.textPrimary,
                ),
              ),
              const Spacer(),
              ?alert,
            ],
          ),
          const SizedBox(height: 2),
          SizedBox(
            height: 12,
            child: LayoutBuilder(
              builder: (context, box) {
                final at = (eval.warn / max).clamp(0.0, 1.0) * box.maxWidth;
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 4,
                      height: 4,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: (value / max).clamp(0.0, 1.0),
                          minHeight: 4,
                          backgroundColor: ZestColors.surfaceChip,
                          color: over ? tone : ZestColors.textTertiary,
                        ),
                      ),
                    ),
                    // The alert's limit: a tick across the bar.
                    Positioned(
                      key: ValueKey('host-panel-limit-${eval.metric.name}'),
                      left: at - 1,
                      top: 0,
                      width: 2,
                      height: 12,
                      child: ColoredBox(color: ZestColors.textPrimary),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// A metric's Alert button: what its alert choice is (Alert, Muted,
/// Snoozed), outlined in the warning colour while the metric is over its
/// limit; a click opens its menu.
class _AlertButton extends ConsumerStatefulWidget {
  const _AlertButton({
    super.key,
    required this.connectionId,
    required this.hostName,
    required this.metric,
    required this.eval,
    required this.prefs,
    required this.stats,
    this.first = true,
  });

  final String connectionId;
  final String hostName;
  final MonitorMetric metric;
  final MetricEval eval;
  final HostAlertPrefs prefs;
  final ServerStats? stats;

  /// The first of its metric's buttons (every disk has one, all the same
  /// alert): the one named by the metric's key.
  final bool first;

  @override
  ConsumerState<_AlertButton> createState() => _AlertButtonState();
}

class _AlertButtonState extends ConsumerState<_AlertButton> {
  bool _hover = false;

  _AlertState get _state {
    final s = widget.prefs.silences[widget.metric];
    if (s == null || !s.activeAt(DateTime.now())) return _AlertState.normal;
    return s.kind == MetricSilenceKind.mute ? _AlertState.muted : _AlertState.snoozed;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final over = widget.eval.severity != MetricSeverity.healthy && _state == _AlertState.normal;
    final fg = over ? ZestColors.statusWarning : ZestColors.textSecondary;
    // Touch sized (4.0): the one control says where it alerts ("Alerts at
    // 70%"), with a bell, 48 high; muted or snoozed it says so.
    final touch = touchSizedAt(context);
    final words = switch (_state) {
      _AlertState.normal when touch => l10n.hpanelAlertsAtButton(monitorMetricValue(widget.metric, widget.eval.warn)),
      _AlertState.normal => l10n.hpanelAlert,
      _AlertState.muted => l10n.hpanelAlertMuted,
      _AlertState.snoozed => l10n.hpanelAlertSnoozed,
    };
    // Reached with Tab; said with its metric ("Memory: Alert"), its words
    // alone said nothing of which; a mouse's 32 high around its 26.
    return ZestPressable(
        key: widget.first ? ValueKey('host-panel-alert-${widget.metric.name}') : null,
        onTap: () => showHostAlertMenu(
          context,
          connectionId: widget.connectionId,
          hostName: widget.hostName,
          metric: widget.metric,
          hasArc: widget.stats?.zfsArcFreeableMB != null,
        ),
        onHover: (h) => setState(() => _hover = h),
        semanticLabel: '${monitorMetricLabel(widget.metric, l10n)}: $words',
        excludeChildSemantics: true,
        borderRadius: 6,
        child: Container(
          height: touch ? 48 : 26,
          padding: EdgeInsets.symmetric(horizontal: touch ? 4 : 8),
          decoration: touch
              ? null
              : BoxDecoration(
                  color: _hover ? ZestColors.surfaceRaisedAlt : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: over ? ZestColors.statusWarning : ZestColors.borderDefault),
                ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_state != _AlertState.normal || touch) ...[
                Icon(
                    switch (_state) {
                      _AlertState.muted => LucideIcons.bellOff,
                      _AlertState.snoozed => LucideIcons.alarmClock,
                      _AlertState.normal => LucideIcons.bell,
                    },
                    size: touch ? 14 : 12,
                    color: fg),
                SizedBox(width: touch ? 6 : 4),
              ],
              Flexible(
                child: Text(
                  words,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: touch ? 13 : 11.5, fontWeight: FontWeight.w500, color: fg),
                ),
              ),
              const SizedBox(width: 3),
              Icon(LucideIcons.chevronDown, size: 12, color: fg),
            ],
          ),
        ),
    );
  }
}

/// The Alert menu of [metric] on host [connectionId], opened at the button
/// that was clicked ([context]) and always inside the window: the limit it
/// alerts at (the default, or one of its own), muted, or snoozed; and for
/// memory on a ZFS host, whether its ARC counts as free.
Future<void> showHostAlertMenu(
  BuildContext context, {
  required String connectionId,
  required String hostName,
  required MonitorMetric metric,
  bool hasArc = false,
}) async {
  final box = context.findRenderObject();
  final overlay = Overlay.of(context).context.findRenderObject();
  if (box is! RenderBox || overlay is! RenderBox) return;
  final anchor = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  await showDialog<void>(
    context: context,
    barrierColor: Colors.transparent,
    builder: (dialogContext) => CustomSingleChildLayout(
      delegate: _InsideWindow(anchor),
      child: _AlertMenu(connectionId: connectionId, hostName: hostName, metric: metric, hasArc: hasArc),
    ),
  );
}

/// Places a pop-up under [anchor], right edges together, and keeps it inside
/// the window: above the anchor where there is no room below, moved left
/// where there is none to the right.
class _InsideWindow extends SingleChildLayoutDelegate {
  _InsideWindow(this.anchor);

  final Rect anchor;
  static const _margin = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(Size(constraints.maxWidth - 2 * _margin, constraints.maxHeight - 2 * _margin));

  @override
  Offset getPositionForChild(Size size, Size child) {
    var x = anchor.right - child.width;
    var y = anchor.bottom + 4;
    if (y + child.height > size.height - _margin) y = anchor.top - 4 - child.height;
    x = x.clamp(_margin, (size.width - child.width - _margin).clamp(_margin, double.infinity));
    y = y.clamp(_margin, (size.height - child.height - _margin).clamp(_margin, double.infinity));
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_InsideWindow old) => old.anchor != anchor;
}

class _AlertMenu extends ConsumerStatefulWidget {
  const _AlertMenu({required this.connectionId, required this.hostName, required this.metric, required this.hasArc});

  final String connectionId;
  final String hostName;
  final MonitorMetric metric;
  final bool hasArc;

  @override
  ConsumerState<_AlertMenu> createState() => _AlertMenuState();
}

class _AlertMenuState extends ConsumerState<_AlertMenu> {
  late final TextEditingController _custom;

  @override
  void initState() {
    super.initState();
    final config = ref.read(monitorThresholdsProvider);
    final own = config.overrideFor(widget.connectionId)?.metrics[widget.metric];
    _custom = TextEditingController(text: _fmt((own ?? config.global.forMetric(widget.metric)).warn));
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  static String _fmt(double v) => formatDecimalUpTo(v);

  /// A typed limit, with a decimal point or the decimal comma [_fmt] writes
  /// in German or French.
  static double? _typed(String v) => double.tryParse(v.trim().replaceAll(',', '.'));

  /// Its own limit for the host: the warning limit is [warn], the critical
  /// one kept above it.
  void _setCustom(double warn) {
    final notifier = ref.read(monitorThresholdsProvider.notifier);
    final current = ref.read(monitorThresholdsProvider).resolveFor(widget.connectionId)[widget.metric]!;
    final step = widget.metric.step;
    final maxV = widget.metric.bandMax;
    final w = warn.clamp(0.0, maxV - step).toDouble();
    final crit = current.crit > w ? current.crit : (w + step * 5).clamp(w + step, maxV).toDouble();
    notifier.setOverrideMetric(widget.connectionId, widget.metric, MetricThreshold(w, crit));
    ref.read(hostAlertPrefsProvider.notifier).unsilence(widget.connectionId, widget.metric);
  }

  /// Back to the default limit: this host's own for the metric goes.
  void _useDefault() {
    final config = ref.read(monitorThresholdsProvider);
    final notifier = ref.read(monitorThresholdsProvider.notifier);
    final own = config.overrideFor(widget.connectionId);
    if (own != null && own.metrics.containsKey(widget.metric)) {
      final rest = {...own.metrics}..remove(widget.metric);
      if (rest.isEmpty && own.reason.isEmpty) {
        notifier.removeOverride(widget.connectionId);
      } else {
        notifier.upsertOverride(widget.connectionId, metrics: rest);
      }
    }
    ref.read(hostAlertPrefsProvider.notifier).unsilence(widget.connectionId, widget.metric);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final config = ref.watch(monitorThresholdsProvider);
    final prefs = ref.watch(hostAlertPrefsProvider)[widget.connectionId] ?? const HostAlertPrefs();
    final silence = prefs.silences[widget.metric];
    final own = config.overrideFor(widget.connectionId)?.metrics[widget.metric];
    final alerts = ref.read(hostAlertPrefsProvider.notifier);
    final muted = silence?.kind == MetricSilenceKind.mute;
    final snoozed = silence != null && !muted && silence.activeAt(DateTime.now());
    void close() => Navigator.of(context).pop();
    final unit = widget.metric.unit;

    Widget head(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: Text(
            text.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 10,
              letterSpacing: 1,
              fontWeight: FontWeight.w600,
              color: ZestColors.textTertiary,
            ),
          ),
        );
    Widget divider() => Divider(height: 9, thickness: 1, color: ZestColors.borderSubtle, indent: 10, endIndent: 10);

    return Material(
      color: Colors.transparent,
      child: Container(
        key: const ValueKey('host-alert-menu'),
        width: 272,
        padding: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: ZestColors.surfaceRaisedAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: ZestColors.borderStrong),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 18, offset: const Offset(0, 6))],
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              head(l10n.hpanelAlertTitle(monitorMetricLabel(widget.metric, l10n), Redactable.host(widget.hostName).displayIn(ref))),
              _MenuRow(
                key: const ValueKey('alert-default'),
                leading: _Radio(on: !muted && own == null),
                label: l10n.hpanelUseDefault,
                trailing: Text('${_fmt(config.global.forMetric(widget.metric).warn)}$unit',
                    style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, color: ZestColors.textTertiary)),
                onTap: () {
                  _useDefault();
                  close();
                },
              ),
              _MenuRow(
                key: const ValueKey('alert-custom'),
                leading: _Radio(on: !muted && own != null),
                label: l10n.hpanelCustomThreshold,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 50,
                      height: 26,
                      child: TextField(
                        key: const ValueKey('alert-custom-field'),
                        controller: _custom,
                        textAlign: TextAlign.right,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                        style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, color: ZestColors.textPrimary),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                        ),
                        onSubmitted: (v) {
                          final n = _typed(v);
                          if (n == null) return;
                          _setCustom(n);
                          close();
                        },
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(unit, style: TextStyle(fontSize: 11.5, color: ZestColors.textTertiary)),
                  ],
                ),
                onTap: () {
                  final n = _typed(_custom.text);
                  if (n == null) return;
                  _setCustom(n);
                  close();
                },
              ),
              _MenuRow(
                key: const ValueKey('alert-mute'),
                leading: _Radio(on: muted),
                label: l10n.hpanelMute,
                trailing: Text(l10n.hpanelMuteSub, style: TextStyle(fontSize: 11, color: ZestColors.textTertiary)),
                onTap: () {
                  alerts.mute(widget.connectionId, widget.metric);
                  close();
                },
              ),
              divider(),
              head(l10n.hpanelSnooze),
              _MenuRow(
                key: const ValueKey('alert-snooze-hour'),
                leading: Icon(LucideIcons.clock, size: 14, color: ZestColors.textSecondary),
                label: l10n.hpanelSnoozeHour,
                onTap: () {
                  alerts.snoozeFor(widget.connectionId, widget.metric, const Duration(hours: 1));
                  close();
                },
              ),
              _MenuRow(
                key: const ValueKey('alert-snooze-day'),
                leading: Icon(LucideIcons.clock, size: 14, color: ZestColors.textSecondary),
                label: l10n.hpanelSnoozeDay,
                onTap: () {
                  alerts.snoozeFor(widget.connectionId, widget.metric, const Duration(hours: 24));
                  close();
                },
              ),
              _MenuRow(
                key: const ValueKey('alert-snooze-recovers'),
                leading: Icon(LucideIcons.rotateCcw, size: 14, color: ZestColors.textSecondary),
                label: l10n.hpanelSnoozeRecovers,
                onTap: () {
                  alerts.snoozeUntilRecovers(widget.connectionId, widget.metric);
                  close();
                },
              ),
              if (muted || snoozed)
                _MenuRow(
                  key: const ValueKey('alert-end-snooze'),
                  leading: Icon(LucideIcons.bell, size: 14, color: ZestColors.textSecondary),
                  label: l10n.hpanelSnoozeEnd,
                  onTap: () {
                    alerts.unsilence(widget.connectionId, widget.metric);
                    close();
                  },
                ),
              if (widget.metric == MonitorMetric.ram && (widget.hasArc || prefs.countArcAsFree)) ...[
                divider(),
                _MenuRow(
                  key: const ValueKey('alert-zfs-arc'),
                  leading: _Check(on: prefs.countArcAsFree),
                  label: l10n.hpanelZfsArc,
                  onTap: () => alerts.setCountArcAsFree(widget.connectionId, !prefs.countArcAsFree),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuRow extends StatefulWidget {
  const _MenuRow({super.key, required this.leading, required this.label, required this.onTap, this.trailing});

  final Widget leading;
  final String label;
  final Widget? trailing;
  final VoidCallback onTap;

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    // Reached with Tab and the arrows, its tick or dot said as checked or not
    // (4.0, the accessibility pass).
    final checked = switch (widget.leading) {
      _Radio(:final on) => on,
      _Check(:final on) => on,
      _ => null,
    };
    return ZestPressable(
        onTap: widget.onTap,
        onHover: (h) => setState(() => _hover = h),
        checked: checked,
        minSize: 0,
        borderRadius: 6,
        child: Container(
          // A finger's 48 where the controls are touch sized.
          constraints: BoxConstraints(minHeight: touchSizedAt(context) ? 48 : 34),
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: _hover ? ZestColors.textPrimary.withValues(alpha: 0.05) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              SizedBox(width: 18, child: Center(child: widget.leading)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(widget.label, style: TextStyle(fontSize: 12.5, color: ZestColors.textPrimary)),
              ),
              if (widget.trailing != null) ...[const SizedBox(width: 8), widget.trailing!],
            ],
          ),
        ),
    );
  }
}

class _Radio extends StatelessWidget {
  const _Radio({required this.on});
  final bool on;

  @override
  Widget build(BuildContext context) => Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: on ? ZestColors.accentPrimary : ZestColors.borderStrong, width: on ? 4 : 1.2),
        ),
      );
}

class _Check extends StatelessWidget {
  const _Check({required this.on});
  final bool on;

  @override
  Widget build(BuildContext context) => Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: on ? ZestColors.accentPrimary : Colors.transparent,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: on ? ZestColors.accentPrimary : ZestColors.borderStrong, width: 1.2),
        ),
        child: on ? Icon(LucideIcons.check, size: 10, color: ZestColors.onBrand) : null,
      );
}

/// A host Server monitor does not watch: a button that adds it, as the
/// monitor's own list does, or, where the free plan watches as many as it
/// can, the limit said and the way past it.
class HostPanelWatch extends ConsumerWidget {
  const HostPanelWatch({super.key, required this.connectionId});

  final String connectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final canAdd = ref.watch(canAddMonitoredHostProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          canAdd ? l10n.hpanelWatchHint : l10n.monitorAgentlessLimitReached(freeMonitorLimit),
          key: const ValueKey('host-panel-watch-hint'),
          style: TextStyle(fontSize: 12, height: 1.4, color: canAdd ? ZestColors.textTertiary : ZestColors.statusWarning),
        ),
        const SizedBox(height: 8),
        if (canAdd)
          ZestButton(
            key: const ValueKey('host-panel-watch'),
            label: l10n.hpanelWatch,
            icon: LucideIcons.activity,
            onPressed: () => ref.read(connectionsDaoProvider).setMonitored(connectionId, true),
          )
        else
          ZestButton(
            key: const ValueKey('host-panel-upgrade'),
            label: l10n.upgrade,
            icon: LucideIcons.sparkles,
            onPressed: () => PricingModal.show(context),
          ),
      ],
    );
  }
}

// ── Recent sessions ────────────────────────────────────────────────────

/// One stretch of work on a host, as command history has it: from its first
/// command to its last, with no pause of half an hour or more between.
typedef HostSessionSpan = ({DateTime start, DateTime end});

/// The host's recent stretches of work, newest first, from its commands in
/// the history (oldest or newest first, in any order): commands half an hour
/// or more apart are two sessions. The app keeps no record of sessions of
/// its own; command history is what it has, where the person keeps it.
List<HostSessionSpan> hostSessionSpans(Iterable<CommandHistoryEntry> entries, String connectionId, {int max = 3}) {
  final times = [
    for (final e in entries)
      if (e.connectionId == connectionId) e.createdAt,
  ]..sort();
  final spans = <HostSessionSpan>[];
  for (final t in times) {
    if (spans.isNotEmpty && t.difference(spans.last.end) < const Duration(minutes: 30)) {
      spans[spans.length - 1] = (start: spans.last.start, end: t);
    } else {
      spans.add((start: t, end: t));
    }
  }
  return spans.reversed.take(max).toList();
}

/// The host's recent sessions, when and how long; nothing where command
/// history has none of its commands.
class HostPanelRecentSessions extends ConsumerWidget {
  const HostPanelRecentSessions({super.key, required this.connectionId});

  final String connectionId;

  static bool hasAny(WidgetRef ref, String connectionId) => hostSessionSpans(
        ref.watch(recentCommandHistoryProvider).valueOrNull ?? const [],
        connectionId,
        max: 1,
      ).isNotEmpty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final spans = hostSessionSpans(ref.watch(recentCommandHistoryProvider).valueOrNull ?? const [], connectionId);
    final now = DateTime.now();
    String when(DateTime t) {
      final local = t.toLocal();
      final today = DateTime(now.year, now.month, now.day);
      final day = DateTime(local.year, local.month, local.day);
      final time = DateFormat.Hm(locale).formatPlain(local);
      if (day == today) return '${l10n.historyGroupToday}, $time';
      if (today.difference(day).inDays == 1) return '${l10n.historyGroupYesterday}, $time';
      return '${DateFormat.MMMd(locale).format(local)}, $time';
    }

    return Column(
      children: [
        for (final s in spans)
          Container(
            key: ValueKey('host-panel-session-${s.start.millisecondsSinceEpoch}'),
            constraints: const BoxConstraints(minHeight: 32),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ZestColors.borderSubtle))),
            child: Row(
              children: [
                Expanded(child: Text(when(s.start), style: TextStyle(fontSize: 12.5, color: ZestColors.textPrimary))),
                Text(
                  durationWords(l10n, s.end.difference(s.start)),
                  style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, color: ZestColors.textTertiary),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ── Port forwards ──────────────────────────────────────────────────────

/// Adds a port forward to host [connectionId]: the app's own editor, saved
/// for the host.
Future<void> addPortForwardFor(BuildContext context, WidgetRef ref, String connectionId) async {
  final result = await showPortForwardEditor(context);
  if (result == null || !context.mounted) return;
  // One that other devices on the network can reach: asked first, as the
  // Port forwarding page asks (this way in did not: found in
  // security reviews).
  if (!await confirmNetworkBind(context,
          listensOn: forwardListensOn(forwardTypeOf(result.type), result.bindAddress), port: result.bindPort) ||
      !context.mounted) {
    return;
  }
  await ref.read(portForwardRulesDaoProvider).insertRule(PortForwardRulesCompanion.insert(
        id: result.id,
        connectionId: connectionId,
        type: result.type,
        bindAddress: Value(result.bindAddress),
        bindPort: result.bindPort,
        remoteHost: result.remoteHost,
        remotePort: result.remotePort,
        autoStart: Value(result.autoStart),
        label: Value(result.label),
        createdAt: DateTime.now(),
      ));
}

/// The host's port forwards: each as it maps, its name under it, and a
/// switch that starts it (connecting first where the host is not open) or
/// stops it, as the Port forwarding page does.
class HostPanelPortForwards extends ConsumerWidget {
  const HostPanelPortForwards({super.key, required this.rules});

  final List<PortForwardRule> rules;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeForwardIdsProvider);
    return Column(
      children: [
        for (final r in rules)
          Padding(
            key: ValueKey('host-panel-forward-${r.id}'),
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Container(
                  width: 20,
                  height: 20,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: ZestColors.surfaceChip,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: ZestColors.borderSubtle),
                  ),
                  child: Text(
                    switch (r.type) { 'remote' => 'R', 'dynamic' => 'D', _ => 'L' },
                    style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 10, color: ZestColors.textSecondary),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _mapping(ref, r),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, color: ZestColors.textPrimary),
                      ),
                      if ((r.label ?? '').trim().isNotEmpty)
                        Text(
                          r.label!.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: ZestColors.textTertiary),
                        ),
                    ],
                  ),
                ),
                ZestSwitch(
                  key: ValueKey('host-panel-forward-switch-${r.id}'),
                  value: active.contains(r.id),
                  onChanged: (on) {
                    final sessions = ref.read(activeSessionsProvider.notifier);
                    if (on) {
                      // ignore: discarded_futures
                      sessions.connectThenStartForward(r);
                    } else {
                      // ignore: discarded_futures
                      sessions.stopSavedForward(r.id);
                    }
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _mapping(WidgetRef ref, PortForwardRule r) {
    final remote = Redactable.address('${r.remoteHost}:${r.remotePort}').displayIn(ref);
    return switch (r.type) {
      'dynamic' => 'localhost:${r.bindPort}',
      'remote' => '$remote → ${r.bindPort}',
      _ => '${r.bindPort} → $remote',
    };
  }
}

/// The command that connects to [c] from a shell: `ssh`, its port where it
/// is not 22, and who signs in where.
String sshCommandFor(ConnectionWithDetails c) {
  final conn = c.connection;
  final user = c.identity?.username;
  final target = (user == null || user.isEmpty) ? conn.host : '$user@${conn.host}';
  return conn.port == 22 ? 'ssh $target' : 'ssh -p ${conn.port} $target';
}
