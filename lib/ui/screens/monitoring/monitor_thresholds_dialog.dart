import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:zestssh/features/monitoring/monitor_host_views.dart';
import 'package:zestssh/features/monitoring/monitor_state_ui.dart';
import 'package:zestssh/features/monitoring/monitor_thresholds.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/monitor_thresholds_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_list_search_field.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart';

/// Open the Server-Monitor Thresholds settings (§2): two panes (where its
/// host picker had been an old dropdown over the whole
/// dialog). On the left "All hosts (defaults)" and the hosts, with a search and
/// their groups, a mark on those with thresholds of their own; on the right,
/// what is chosen there: its limits, each against where the host stands now.
///
/// §22: pass [hostId] to open straight on that host, e.g. from the per-row
/// quick-edit pencil.
Future<void> showMonitorThresholds(BuildContext context, {String? hostId}) async {
  // Capture the provider container so the notifier can be reached once the
  // dialog is gone.
  final container = ProviderScope.containerOf(context);
  final notifier = container.read(monitorThresholdsProvider.notifier);
  // Snapshot the config the moment the dialog opens. Every handle drag / cell
  // change persists immediately, so "Cancel" (and X / barrier dismiss) means
  // "restore this snapshot"; only Done keeps the edits (§27).
  final snapshot = container.read(monitorThresholdsProvider);
  final result = await showZestModal<bool>(
    context: context,
    size: ZestModalSize.large,
    child: _ThresholdsDialog(initialHostId: hostId),
  );
  // Any exit other than an explicit Done (the Cancel button, the X, or a
  // barrier tap - both of which resolve to null) reverts every live edit.
  if (result != true) {
    notifier.restore(snapshot);
  }
}

/// Under this width one pane: the host is chosen with a select above it.
const double _kTwoPanesFrom = 700;

/// Under this width a limit's numbers go above its track, as on a phone.
const double _kBandInOneRowFrom = 480;

/// Whether the dialog [context] stands in is still there. A field that loses
/// the focus because the dialog closed (Esc, a tap outside) has nothing to keep:
/// its value came after the dialog put everything back, and stayed.
bool _dialogStillOpen(BuildContext context) => context.mounted && (ModalRoute.of(context)?.isActive ?? true);

/// What is being typed into a number or the reason counts now: it is kept when
/// its field loses the focus, and on a phone a tap on Done or on another host
/// leaves the focus where it is.
void _keepWhatIsTyped() {
  FocusManager.instance.primaryFocus?.unfocus();
  FocusManager.instance.applyFocusChangesIfNeeded();
}

class _ThresholdsDialog extends ConsumerStatefulWidget {
  final String? initialHostId;

  const _ThresholdsDialog({this.initialHostId});

  @override
  ConsumerState<_ThresholdsDialog> createState() => _ThresholdsDialogState();
}

class _ThresholdsDialogState extends ConsumerState<_ThresholdsDialog> {
  /// The host chosen on the left; null for All hosts (defaults).
  late String? _hostId = widget.initialHostId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final notifier = ref.read(monitorThresholdsProvider.notifier);
    final connections = (ref.watch(connectionsWithDetailsProvider).valueOrNull ??
            const <ConnectionWithDetails>[])
        .where((c) => c.connection.protocol != 'localShell')
        .toList();
    // A host gone since it was chosen: the defaults.
    final host = connections.where((c) => c.connection.id == _hostId).firstOrNull;
    void choose(String? id) {
      _keepWhatIsTyped();
      setState(() => _hostId = id);
    }

    final right = _ThresholdsPane(key: ValueKey('thresholds-pane-${host?.connection.id ?? 'all'}'), host: host);
    final select = _HostSelect(connections: connections, selectedId: host?.connection.id, onChanged: choose);
    // A phone's sheet scrolls as one, however wide (on its side) or short (the
    // keyboard up): two panes in a fixed height overflowed it, and a list of
    // its own was a slit between the head and the buttons.
    final sheet = ZestSheetScope.of(context);

    return ZestDialogShell(
      size: ZestModalSize.large,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.slidersHorizontal,
      title: l10n.zestThresholdTitle,
      subtitle: l10n.zestThresholdSubtitle,
      bodyScrolls: sheet,
      body: sheet
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [select, const SizedBox(height: 12), right],
            )
          : LayoutBuilder(
              builder: (context, box) {
                if (box.maxWidth < _kTwoPanesFrom) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      select,
                      const SizedBox(height: 12),
                      Flexible(child: SingleChildScrollView(child: right)),
                    ],
                  );
                }
                return SizedBox(
                  height: 540,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 272,
                        child: _HostsPane(
                          connections: connections,
                          selectedId: host?.connection.id,
                          onChanged: choose,
                        ),
                      ),
                      const SizedBox(width: 12),
                      VerticalDivider(width: 1, thickness: 1, color: ZestTokens.borderSubtle),
                      const SizedBox(width: 16),
                      Expanded(child: SingleChildScrollView(child: right)),
                    ],
                  ),
                );
              },
            ),
      // The defaults as they came, which every host without its own follows:
      // what hosts have of their own is theirs to reset (their panes).
      tertiaryAction: host != null
          ? null
          : (
              label: l10n.zestThresholdReset,
              onPressed: () {
                _keepWhatIsTyped();
                notifier.resetDefaults();
              },
            ),
      secondaryAction: (
        label: l10n.cancel,
        onPressed: () => Navigator.of(context).pop(false),
      ),
      primaryAction: (
        label: l10n.done,
        icon: LucideIcons.check,
        onPressed: () {
          _keepWhatIsTyped();
          Navigator.of(context).pop(true);
        },
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// Left pane: All hosts (defaults), and the hosts by group
// ══════════════════════════════════════════════════════════════════════

class _HostsPane extends ConsumerStatefulWidget {
  final List<ConnectionWithDetails> connections;
  final String? selectedId;
  final ValueChanged<String?> onChanged;

  const _HostsPane({required this.connections, required this.selectedId, required this.onChanged});

  @override
  ConsumerState<_HostsPane> createState() => _HostsPaneState();
}

class _HostsPaneState extends ConsumerState<_HostsPane> {
  final _search = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final config = ref.watch(monitorThresholdsProvider);
    final open = ref.watch(openHostIdsProvider);
    final query = _search.text.trim().toLowerCase();
    final shown = [
      for (final c in widget.connections)
        if (query.isEmpty ||
            c.connection.label.toLowerCase().contains(query) ||
            c.connection.host.toLowerCase().contains(query) ||
            (c.group?.name.toLowerCase().contains(query) ?? false))
          c,
    ];
    final layout = layOutHosts(
      shown,
      groups: ref.watch(connectionGroupsProvider).valueOrNull ?? const [],
      activeFirst: ref.watch(activeFirstProvider(HostListPlace.thresholds)),
      open: open,
      lastUsed: ref.watch(hostUseProvider),
    );

    Widget rowFor(ConnectionWithDetails c) {
      final own = config.overrideFor(c.connection.id)?.metrics.isNotEmpty ?? false;
      return HostRow(
        key: ValueKey('thresholds-host-${c.connection.id}'),
        host: c.connection,
        user: c.identity?.username,
        group: c.group,
        under: true,
        iconSize: 20,
        open: open.contains(c.connection.id),
        openLabel: l10n.broadcastToHostsIsOpen,
        selected: widget.selectedId == c.connection.id,
        onTap: () => widget.onChanged(c.connection.id),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        margin: const EdgeInsets.only(bottom: 1),
        trailing: own
            ? Tooltip(
                message: l10n.zestThresholdHasOwn,
                child: Container(
                  key: ValueKey('thresholds-own-${c.connection.id}'),
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: ZestTokens.brand, shape: BoxShape.circle),
                ),
              )
            : null,
      );
    }

    int countIn(List<HostBlock> blocks) => blocks.fold(0, (n, b) => n + b.hosts.length);
    Iterable<Widget> blockOf(HostBlock b) sync* {
      yield HostGroupHeading(group: b.group, count: '${b.hosts.length}');
      yield* b.hosts.map(rowFor);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZestListSearchField(
          key: const ValueKey('thresholds-hosts-search'),
          controller: _search,
          hintText: l10n.broadcastToHostsSearch,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        const Align(
          alignment: AlignmentDirectional.centerEnd,
          child: ActiveFirstToggle(place: HostListPlace.thresholds),
        ),
        const SizedBox(height: 6),
        _AllHostsRow(selected: widget.selectedId == null, onTap: () => widget.onChanged(null)),
        Expanded(
          child: Scrollbar(
            controller: _scroll,
            child: SingleChildScrollView(
              controller: _scroll,
              child: Padding(
                padding: const EdgeInsetsDirectional.only(end: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (layout.split) ...[
                      HostSectionHeading(active: true, count: countIn(layout.active)),
                      for (final b in layout.active) ...blockOf(b),
                      if (layout.rest.isNotEmpty) HostSectionHeading(active: false, count: countIn(layout.rest)),
                    ],
                    for (final b in layout.rest) ...blockOf(b),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// "All hosts (defaults)": the row on top of the hosts.
class _AllHostsRow extends StatefulWidget {
  final bool selected;
  final VoidCallback onTap;

  const _AllHostsRow({required this.selected, required this.onTap});

  @override
  State<_AllHostsRow> createState() => _AllHostsRowState();
}

class _AllHostsRowState extends State<_AllHostsRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        key: const ValueKey('thresholds-all-hosts'),
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
          decoration: BoxDecoration(
            color: widget.selected
                ? ZestTokens.brandSubtle
                : (_hover ? ZestTokens.surfaceHover : Colors.transparent),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: Icon(LucideIcons.layers, size: 15, color: widget.selected ? ZestTokens.brandInk : ZestTokens.textSecondary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.zestThresholdAllHostsDefaults,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The host chosen with a select, where there is no room for two panes.
class _HostSelect extends ConsumerWidget {
  final List<ConnectionWithDetails> connections;
  final String? selectedId;
  final ValueChanged<String?> onChanged;

  const _HostSelect({required this.connections, required this.selectedId, required this.onChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return ZestSelect<String>(
      key: const ValueKey('thresholds-host-select'),
      value: selectedId ?? '',
      items: [
        ZestSelectItem('', l10n.zestThresholdAllHostsDefaults),
        for (final c in connections)
          ZestSelectItem(
            c.connection.id,
            (c.connection.label.isNotEmpty
                    ? Redactable.host(c.connection.label)
                    : Redactable.address(c.connection.host))
                .displayIn(ref),
          ),
      ],
      onChanged: (id) => onChanged(id.isEmpty ? null : id),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// Right pane: the limits of what is chosen
// ══════════════════════════════════════════════════════════════════════

class _ThresholdsPane extends ConsumerWidget {
  /// The host; null for All hosts (defaults).
  final ConnectionWithDetails? host;

  const _ThresholdsPane({super.key, required this.host});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final config = ref.watch(monitorThresholdsProvider);
    final notifier = ref.read(monitorThresholdsProvider.notifier);
    final h = host;
    if (h == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.zestThresholdAllHostsDefaults,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
          ),
          const SizedBox(height: 12),
          for (final metric in kMonitorMetricDisplayOrder) ...[
            _MetricBand(
              key: ValueKey('thresholds-band-${metric.name}'),
              metric: metric,
              value: config.global.forMetric(metric),
              onChanged: (t) => notifier.setGlobalMetric(metric, t),
            ),
            const SizedBox(height: 6),
          ],
          const SizedBox(height: 12),
          _SectionHeaderLine(l10n.zestThresholdCheckingTitle),
          const SizedBox(height: 12),
          // Labeled field cells: "Every [5 minutes]" · "Change after [2 readings]".
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 10,
                child: _LabeledCell(
                  label: l10n.zestThresholdEveryLabel,
                  values: const [1, 2, 3, 5, 10, 15, 30, 60],
                  current: config.global.checkIntervalMinutes,
                  format: (v) => l10n.zestThresholdMinutesValue(v),
                  onChanged: notifier.setCheckIntervalMinutes,
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                flex: 13,
                child: _LabeledCell(
                  label: l10n.zestThresholdChangeAfterLabel,
                  values: const [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
                  current: config.global.debounceReadings,
                  format: (v) => l10n.zestThresholdReadingsValue(v),
                  onChanged: notifier.setDebounceReadings,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l10n.zestThresholdDebounceHelp,
            style: TextStyle(fontSize: 11, height: 1.4, color: AppColors.v3TextTertiary),
          ),
        ],
      );
    }

    final hostId = h.connection.id;
    final resolved = config.resolveFor(hostId);
    final override = config.overrideFor(hostId);
    final own = override?.metrics.isNotEmpty ?? false;
    final view = ref.watch(monitorHostViewsProvider)[hostId];
    final others = [
      for (final o in config.overrides)
        if (o.connectionId != hostId && o.metrics.isNotEmpty) o,
    ];

    final name = HostRow(
      host: h.connection,
      user: h.identity?.username,
      group: h.group,
      under: true,
      padding: EdgeInsets.zero,
      margin: EdgeInsets.zero,
      hovers: false,
      nameStyle: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
    );
    final copyFrom = _CopyFromButton(hostId: hostId, others: others);
    final reset = ZestButton(
      key: const ValueKey('thresholds-reset-host'),
      label: l10n.zestThresholdReset,
      variant: ZestButtonVariant.ghost,
      onPressed: () {
        _keepWhatIsTyped();
        notifier.removeOverride(hostId);
      },
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // On a phone the buttons go under the name, which has no room beside them.
        LayoutBuilder(
          builder: (context, box) => box.maxWidth < _kBandInOneRowFrom
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    name,
                    const SizedBox(height: 8),
                    Wrap(spacing: 6, runSpacing: 6, children: [copyFrom, if (own) reset]),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: name),
                    const SizedBox(width: 10),
                    copyFrom,
                    if (own) ...[const SizedBox(width: 6), reset],
                  ],
                ),
        ),
        const SizedBox(height: 4),
        Text(
          own ? l10n.zestThresholdHasOwn : l10n.zestThresholdFollowsDefaults,
          key: const ValueKey('thresholds-own-said'),
          style: TextStyle(fontSize: 11.5, color: AppColors.v3TextTertiary),
        ),
        const SizedBox(height: 12),
        for (final metric in kMonitorMetricDisplayOrder) ...[
          _MetricBand(
            key: ValueKey('thresholds-band-${metric.name}'),
            metric: metric,
            value: resolved[metric]!,
            current: view?.metricEval(metric)?.value,
            onChanged: (t) => notifier.setOverrideMetric(hostId, metric, t),
          ),
          const SizedBox(height: 6),
        ],
        const SizedBox(height: 8),
        _ReasonField(
          key: ValueKey('reason-$hostId'),
          initial: override?.reason ?? '',
          onChanged: (r) => notifier.setOverrideReason(hostId, r),
        ),
      ],
    );
  }
}

/// "Copy from…": takes the limits another host has of its own. Offered while
/// another host has any; a list of hosts that follow the defaults would only
/// reset this one, which Reset to defaults says plainly.
class _CopyFromButton extends ConsumerWidget {
  final String hostId;
  final List<HostThresholdOverride> others;

  const _CopyFromButton({required this.hostId, required this.others});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final hosts = ref.watch(hostsByIdProvider);
    final from = [for (final o in others) if (hosts.containsKey(o.connectionId)) o];
    final button = Builder(
      builder: (buttonContext) => ZestButton(
        key: const ValueKey('thresholds-copy-from'),
        label: l10n.zestThresholdCopyFrom,
        icon: LucideIcons.copy,
        variant: ZestButtonVariant.secondary,
        onPressed: from.isEmpty
            ? null
            : () async {
                final box = buttonContext.findRenderObject()! as RenderBox;
                final at = box.localToGlobal(Offset(0, box.size.height + 4));
                final picked = await showMenu<HostThresholdOverride>(
                  context: context,
                  position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + 1, at.dy + 1),
                  color: ZestTokens.surfaceRaised,
                  items: [
                    for (final o in from)
                      PopupMenuItem(
                        key: ValueKey('thresholds-copy-${o.connectionId}'),
                        value: o,
                        height: 38,
                        child: HostRow(host: hosts[o.connectionId]!.connection, showAddress: false, hovers: false),
                      ),
                  ],
                );
                if (picked == null) return;
                ref
                    .read(monitorThresholdsProvider.notifier)
                    .upsertOverride(hostId, metrics: picked.metrics, reason: picked.reason);
              },
      ),
    );
    return from.isEmpty ? Tooltip(message: l10n.zestThresholdCopyNone, child: button) : button;
  }
}

// ══════════════════════════════════════════════════════════════════════
// One metric: its name, a continuous gradient track with 2 on-track handles
// and a mark where the host stands now, and the numbers inline (§21)
// ══════════════════════════════════════════════════════════════════════

class _MetricBand extends StatefulWidget {
  final MonitorMetric metric;
  final MetricThreshold value;

  /// Where the host stands now, so that a limit is set against what it does
  /// ("RAM 93% on web-01"). Null where it is not
  /// known, and for the defaults.
  final double? current;
  final ValueChanged<MetricThreshold> onChanged;

  const _MetricBand({
    super.key,
    required this.metric,
    required this.value,
    this.current,
    required this.onChanged,
  });

  @override
  State<_MetricBand> createState() => _MetricBandState();
}

class _MetricBandState extends State<_MetricBand> {
  late double _warn;
  late double _crit;
  late final TextEditingController _warnCtrl;
  late final TextEditingController _critCtrl;

  double get _max => widget.metric.bandMax;
  double get _step => widget.metric.step;

  @override
  void initState() {
    super.initState();
    _warn = widget.value.warn;
    _crit = widget.value.crit;
    _warnCtrl = TextEditingController(text: _fmt(_warn));
    _critCtrl = TextEditingController(text: _fmt(_crit));
  }

  @override
  void didUpdateWidget(_MetricBand old) {
    super.didUpdateWidget(old);
    // Sync from the provider (e.g. after Reset, or a host's limits copied).
    if (widget.value.warn != _warn && widget.value.warn != old.value.warn) {
      _warn = widget.value.warn;
      _warnCtrl.text = _fmt(_warn);
    }
    if (widget.value.crit != _crit && widget.value.crit != old.value.crit) {
      _crit = widget.value.crit;
      _critCtrl.text = _fmt(_crit);
    }
  }

  @override
  void dispose() {
    _warnCtrl.dispose();
    _critCtrl.dispose();
    super.dispose();
  }

  String _fmt(double v) => v.toStringAsFixed(0);

  void _commit() => widget.onChanged(MetricThreshold(_warn, _crit));

  void _setWarn(double v) {
    // The Warn handle can never cross the Crit handle (§2.1).
    final clamped = v.clamp(0, _crit - _step).toDouble();
    setState(() {
      _warn = clamped;
      _warnCtrl.text = _fmt(clamped);
    });
    _commit();
  }

  void _setCrit(double v) {
    final clamped = v.clamp(_warn + _step, _max).toDouble();
    setState(() {
      _crit = clamped;
      _critCtrl.text = _fmt(clamped);
    });
    _commit();
  }

  void _commitWarnText() {
    // Nothing typed: a click in and out is no limit of the host's own.
    if (_warnCtrl.text.trim() == _fmt(_warn)) return;
    final parsed = double.tryParse(_warnCtrl.text.trim());
    if (parsed == null) {
      _warnCtrl.text = _fmt(_warn);
      return;
    }
    _setWarn(parsed);
  }

  void _commitCritText() {
    if (_critCtrl.text.trim() == _fmt(_crit)) return;
    final parsed = double.tryParse(_critCtrl.text.trim());
    if (parsed == null) {
      _critCtrl.text = _fmt(_crit);
      return;
    }
    _setCrit(parsed);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Muted band tones over the dark panel - one continuous track, hard stops
    // at warn / crit, so the two handles sit ON the gradient they control.
    final green = AppColors.success.withValues(alpha: 0.30);
    final amber = AppColors.warning.withValues(alpha: 0.32);
    final red = AppColors.error.withValues(alpha: 0.32);
    final warnT = (_warn / _max).clamp(0.0, 1.0);
    final critT = (_crit / _max).clamp(0.0, 1.0);
    final now = widget.current;
    final nowColor = now == null
        ? null
        : now >= _crit
            ? AppColors.error
            : now >= _warn
                ? AppColors.warning
                : AppColors.v3TextPrimary;

    final label = Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Text(
        monitorMetricLabel(widget.metric, l10n),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary),
      ),
    );
    final track = LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final nowT = now == null ? null : (now / _max).clamp(0.0, 1.0);
        return SizedBox(
          height: 36,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                right: 0,
                bottom: 3,
                height: 12,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    gradient: LinearGradient(
                      colors: [green, green, amber, amber, red, red],
                      stops: [0, warnT, warnT, critT, critT, 1],
                    ),
                  ),
                ),
              ),
              // Where the host stands now: a line over the track and its
              // figure above it, never in the way of the handles.
              if (nowT != null) ...[
                Positioned(
                  left: nowT * w - 0.75,
                  bottom: 1,
                  height: 18,
                  width: 1.5,
                  child: IgnorePointer(child: ColoredBox(color: nowColor!)),
                ),
                Positioned(
                  // Kept over the track at either end.
                  left: (nowT * w - 22).clamp(0.0, w < 44 ? 0.0 : w - 44),
                  width: 44,
                  top: 0,
                  child: IgnorePointer(
                    child: Tooltip(
                      message: l10n.zestThresholdNow,
                      child: Text(
                        '${now!.round()}${widget.metric.unit}',
                        key: ValueKey('thresholds-now-${widget.metric.name}'),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontFamily: 'JetBrainsMono',
                          fontWeight: FontWeight.w600,
                          color: nowColor,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              Positioned(
                left: warnT * w - 9,
                bottom: 0,
                child: _HandleBar(
                  color: AppColors.warning,
                  onDrag: (dx) => _setWarn(_warn + dx / w * _max),
                ),
              ),
              Positioned(
                left: critT * w - 9,
                bottom: 0,
                child: _HandleBar(
                  color: AppColors.error,
                  onDrag: (dx) => _setCrit(_crit + dx / w * _max),
                ),
              ),
            ],
          ),
        );
      },
    );
    final warn = _NumInput(
      label: l10n.zestThresholdWarn,
      controller: _warnCtrl,
      unit: widget.metric.unit,
      accent: AppColors.warning,
      onCommit: _commitWarnText,
    );
    final crit = _NumInput(
      label: l10n.zestThresholdCrit,
      controller: _critCtrl,
      unit: widget.metric.unit,
      accent: AppColors.error,
      onCommit: _commitCritText,
    );

    return LayoutBuilder(
      builder: (context, box) {
        // On a phone the numbers go above the track, which has no room beside them.
        if (box.maxWidth < _kBandInOneRowFrom) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: label),
                  const SizedBox(width: 6),
                  warn,
                  const SizedBox(width: 6),
                  crit,
                ],
              ),
              track,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // As wide as the longest of them: German's Datenträger.
            SizedBox(width: 84, child: label),
            const SizedBox(width: 6),
            Expanded(child: track),
            const SizedBox(width: 14),
            warn,
            const SizedBox(width: 6),
            crit,
          ],
        );
      },
    );
  }
}

/// A slim rounded handle that sits ON the gradient track. The 18px hit box
/// keeps the 5px visual bar comfortably draggable.
class _HandleBar extends StatelessWidget {
  final Color color;
  final ValueChanged<double> onDrag;

  const _HandleBar({required this.color, required this.onDrag});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: SizedBox(
          width: 18,
          height: 18,
          child: Center(
            child: Container(
              width: 5,
              height: 18,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(3),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 3,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact "Warn 70 %" / "Crit 85 %" cell: a bordered box with a small
/// coloured label, a mono editable number and a muted unit (§21).
class _NumInput extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String unit;
  final Color accent;
  final VoidCallback onCommit;

  const _NumInput({
    required this.label,
    required this.controller,
    required this.unit,
    required this.accent,
    required this.onCommit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.v3Background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: accent,
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 34,
            child: Focus(
              onFocusChange: (has) {
                if (!has && _dialogStillOpen(context)) onCommit();
              },
              child: TextField(
                controller: controller,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onSubmitted: (_) => onCommit(),
                style: TextStyle(
                  fontSize: 13,
                  fontFamily: 'JetBrainsMono',
                  color: AppColors.v3TextPrimary,
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  isCollapsed: true,
                  filled: false,
                  contentPadding: EdgeInsets.symmetric(vertical: 4),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                  focusedErrorBorder: InputBorder.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 3),
          // As wide for every unit, so the columns of numbers line up.
          SizedBox(
            width: 18,
            child: Text(
              unit,
              maxLines: 1,
              style: TextStyle(fontSize: 11, color: AppColors.v3TextTertiary),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// Checking: labeled field cells (interval + debounce)
// ══════════════════════════════════════════════════════════════════════

/// A "[label] [value ▾]" cell - a fixed label chip and a value area that opens
/// a menu of the allowed values. Replaces the old +/- steppers (§21).
class _LabeledCell extends StatelessWidget {
  final String label;
  final List<int> values;
  final int current;
  final String Function(int) format;
  final ValueChanged<int> onChanged;

  const _LabeledCell({
    required this.label,
    required this.values,
    required this.current,
    required this.format,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: AppColors.v3Surface,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              child: Text(
                label,
                style: TextStyle(fontSize: 12, color: AppColors.v3TextSecondary),
              ),
            ),
            Expanded(
              child: PopupMenuButton<int>(
                tooltip: '',
                color: AppColors.v3Surface,
                position: PopupMenuPosition.under,
                onSelected: onChanged,
                itemBuilder: (context) => [
                  for (final v in values)
                    PopupMenuItem<int>(
                      value: v,
                      height: 38,
                      child: Text(
                        format(v),
                        style: TextStyle(
                          fontSize: 13,
                          color: v == current
                              ? AppColors.v3AccentInk
                              : AppColors.v3TextPrimary,
                        ),
                      ),
                    ),
                ],
                child: Container(
                  color: AppColors.v3Background,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          format(current),
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.v3TextPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Icon(
                        LucideIcons.chevronDown,
                        size: 18,
                        color: AppColors.v3TextSecondary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// Why a host has its own limits
// ══════════════════════════════════════════════════════════════════════

class _ReasonField extends StatefulWidget {
  final String initial;
  final ValueChanged<String> onChanged;

  const _ReasonField({super.key, required this.initial, required this.onChanged});

  @override
  State<_ReasonField> createState() => _ReasonFieldState();
}

class _ReasonFieldState extends State<_ReasonField> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);

  @override
  void didUpdateWidget(_ReasonField old) {
    super.didUpdateWidget(old);
    // Its limits copied from another host, with the why they were kept for.
    if (widget.initial != old.initial && widget.initial != _ctrl.text) _ctrl.text = widget.initial;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.zestThresholdWhyLabel,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AppColors.v3TextTertiary,
          ),
        ),
        const SizedBox(height: 5),
        Focus(
          onFocusChange: (has) {
            if (has || !_dialogStillOpen(context)) return;
            // Nothing typed: a click in and out is no override of the host's.
            final text = _ctrl.text.trim();
            if (text != widget.initial) widget.onChanged(text);
          },
          child: TextField(
            key: const ValueKey('thresholds-why'),
            controller: _ctrl,
            onSubmitted: (v) => widget.onChanged(v.trim()),
            maxLength: 120,
            style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary),
            decoration: InputDecoration(
              isDense: true,
              counterText: '',
              hintText: l10n.zestThresholdOverrideReasonHint,
              hintStyle: TextStyle(
                fontSize: 13,
                color: AppColors.v3TextTertiary,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              filled: true,
              fillColor: AppColors.v3Background,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: AppColors.v3BorderSubtle),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: AppColors.v3BorderSubtle),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(
                    color: AppColors.v3AccentPrimary.withValues(alpha: 0.6)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// Section headers
// ══════════════════════════════════════════════════════════════════════

/// An uppercase section label with a trailing hairline rule (§21).
class _SectionHeaderLine extends StatelessWidget {
  final String text;
  const _SectionHeaderLine(this.text);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
            color: AppColors.v3TextTertiary,
          ),
        ),
        const SizedBox(width: 9),
        Expanded(child: Container(height: 1, color: AppColors.v3BorderSubtle)),
      ],
    );
  }
}
