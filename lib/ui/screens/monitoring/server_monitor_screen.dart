import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart' show NumberFormat;
import 'package:zestssh/features/monitoring/monitor_host_alerts.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/ui/screens/help/setup_guide_screen.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/core/latency_format.dart';
import 'package:zestssh/utils/error_translator.dart';
import 'package:zestssh/features/monitoring/monitor_evaluation.dart';
import 'package:zestssh/features/monitoring/monitor_state_ui.dart';
import 'package:zestssh/features/monitoring/monitor_status.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/monitor_thresholds_provider.dart';
import 'package:zestssh/ui/screens/monitoring/monitor_thresholds_dialog.dart';
import 'package:zestssh/ui/screens/monitoring/prometheus_config_sheet.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/server_stats_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/monitoring/monitor_manage_dialog.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/ui/widgets/load_error_state.dart';
import 'package:zestssh/utils/host_address.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_scroll_fade.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/utils/number_text.dart';

/// Whether a host needs its person (a phone's and a tablet's Monitor leads
/// with these, since 3.0): over a limit, or a check that cannot be made
/// for a reason someone can act on (its sign-in refused or missing, the host
/// not reached, a check that failed, a host key to review). One merely being
/// read, not read yet or not watched needs nobody.
bool monitorNeedsAttention(MonitorHostView view) => switch (view.bucket) {
      MonitorBucket.critical || MonitorBucket.warning => true,
      MonitorBucket.healthy => false,
      MonitorBucket.cantCheck => switch (view.cantCheckReason) {
          CantCheckReason.authFailed ||
          CantCheckReason.noCredentials ||
          CantCheckReason.unreachable ||
          CantCheckReason.checkFailed ||
          CantCheckReason.hostKeyReview =>
            true,
          _ => false,
        },
    };

/// How many of the hosts that need nothing a phone's and a tablet's Monitor
/// shows under those that need attention before "Show N more".
const kMonitorOthersShown = 3;

/// A number that is not a value to copy (a percentage, a load, an uptime, a
/// count): monospace on a computer, as it was; on a phone and a tablet the
/// app's own type with figures of one width (3.0: monospace is
/// for values to copy).
String? get _numberFont => isTouchLayout ? null : 'JetBrainsMono';

List<FontFeature>? get _numberFigures => isTouchLayout ? const [FontFeature.tabularFigures()] : null;

/// A server card's type size: on a phone and a tablet no smaller than 13 (before
/// 4.0, CPU, RAM and Disk read at 11, RAM's
/// megabytes at 9); a computer's as it was.
double _cardSize(double computer) => isTouchLayout && computer < 13 ? 13 : computer;

/// RAM in use and in all, under its gauge: "13.9 / 15.6 GB" on a phone and a
/// tablet, where "14240 / 16000 MB" no longer fits a third of a card at 13;
/// a computer's "14240 / 16000 MB" as it was.
String _ramSubtitle(AppLocalizations l10n, int usedMb, int totalMb) {
  if (!isTouchLayout || totalMb < 1024) return l10n.sizeMegabytes('$usedMb / $totalMb');
  final number = NumberFormat.decimalPatternDigits(locale: l10n.localeName, decimalDigits: 1);
  return l10n.sizeGigabytes('${number.format(usedMb / 1024)} / ${number.format(totalMb / 1024)}');
}

/// Server monitoring dashboard.
///
/// Displays health, latency, CPU, RAM, and disk usage for all saved
/// connections. Stats are collected over active SSH sessions using
/// lightweight shell commands. Cached stats survive app restarts.
class ServerMonitorScreen extends ConsumerStatefulWidget {
  const ServerMonitorScreen({super.key, this.underBar});

  /// What goes under the screen's bar, over everything else: Home's banners
  /// on a phone's and a tablet's Monitor tab, as every tab has them under
  /// its title.
  final Widget? underBar;

  @override
  ConsumerState<ServerMonitorScreen> createState() =>
      _ServerMonitorScreenState();
}

enum _SortMode {
  /// Worst-first - the Doc-3 B1 default. Ranks by [HostSeverity].
  severity,
  nameAsc,
  nameDesc,
  cpuDesc,
  ramDesc,
  diskDesc,
}

extension _SortModeLabel on _SortMode {
  String label(AppLocalizations l10n) {
    switch (this) {
      case _SortMode.severity:
        return l10n.monitorSortSeverity;
      case _SortMode.nameAsc:
        return l10n.monitorSortNameAsc;
      case _SortMode.nameDesc:
        return l10n.monitorSortNameDesc;
      case _SortMode.cpuDesc:
        return l10n.monitorSortCpu;
      case _SortMode.ramDesc:
        return l10n.monitorSortRam;
      case _SortMode.diskDesc:
        return l10n.monitorSortDisk;
    }
  }

  IconData get icon {
    switch (this) {
      case _SortMode.severity:
        return LucideIcons.alertCircle;
      case _SortMode.nameAsc:
      case _SortMode.nameDesc:
        return LucideIcons.arrowDownAZ;
      case _SortMode.cpuDesc:
        return LucideIcons.cpu;
      case _SortMode.ramDesc:
        return LucideIcons.circuitBoard;
      case _SortMode.diskDesc:
        return LucideIcons.hardDrive;
    }
  }
}

class _ServerMonitorScreenState extends ConsumerState<ServerMonitorScreen> {
  late final ServerStatsNotifier _statsNotifier;
  bool _isRefreshing = false;
  _SortMode _sortMode = _SortMode.severity;
  bool _hideUnmonitored = false;

  /// Active summary-strip bucket filter, or null when showing everything.
  MonitorBucket? _bucketFilter;

  /// A phone's and a tablet's Monitor: every host that needs nothing shown,
  /// not only the first few ([kMonitorOthersShown]).
  bool _showAllOthers = false;

  @override
  void initState() {
    super.initState();
    _statsNotifier = ref.read(serverStatsProvider.notifier);
    // Restore the persisted sort preference (Doc-3 B1). Defaults to severity.
    final saved = ref.read(settingsServiceProvider).monitorSortMode;
    _sortMode = _SortMode.values.firstWhere(
      (m) => m.name == saved,
      orElse: () => _SortMode.severity,
    );
    // Trigger initial health checks + stats collection.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshEverything();
    });
  }

  @override
  void dispose() {
    // Don't stop auto-refresh on dispose - let it keep running in background.
    // It will be stopped when the user explicitly turns it off.
    super.dispose();
  }

  void _setSortMode(_SortMode mode) {
    setState(() => _sortMode = mode);
    // Persist through the settings service (fire-and-forget).
    ref.read(settingsServiceProvider).setMonitorSortMode(mode.name);
  }

  /// Refresh the stats (SSH/Prometheus) and, where the checks of whether
  /// hosts can be reached are on (Settings), those: every host now when its
  /// person [asked] (the button, a pull), and only the hosts that are due
  /// when the screen merely opens.
  Future<void> _refreshEverything({bool showSnackbar = false, bool asked = false}) async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    final l10n = AppLocalizations.of(context)!;

    try {
      // 1. Trigger health checks for all connections.
      final connections =
          ref.read(connectionsWithDetailsProvider).valueOrNull ?? [];
      final conns = connections.map((c) => c.connection).toList();
      if (conns.isNotEmpty) {
        final healthNotifier = ref.read(connectionHealthProvider.notifier);
        await healthNotifier.checkAll(conns, asked: asked);
      }
      // Asked for: Server Monitor tries again now the hosts it had stopped
      // trying, or that wait for their next try.
      if (asked) ref.read(agentlessMonitorPollerProvider.notifier).retry();

      // 2. Collect stats from active sessions / Prometheus.
      await _statsNotifier.refreshAll();

      if (mounted && showSnackbar) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
            content: Text(l10n.monitorStatsRefreshed),
            backgroundColor: AppColors.success,
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ));
      }
    } catch (e) {
      if (mounted && showSnackbar) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
            content:
                Text(l10n.monitorRefreshFailed(describeNetworkError(e).message)),
            backgroundColor: AppColors.error,
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ));
      }
    } finally {
      if (mounted) {
        setState(() => _isRefreshing = false);
      }
    }
  }

  /// Sort and filter the connections list.
  List<ConnectionWithDetails> _sortAndFilter(
    List<ConnectionWithDetails> connections,
    Map<String, HostStatus> statusMap,
    Map<String, ServerStats> statsMap,
    Map<String, MonitorBucket?> bucketMap,
  ) {
    var list = connections.toList();

    // Filter: hide unmonitored (no data from either subsystem).
    if (_hideUnmonitored) {
      list = list.where((c) {
        final s = statusMap[c.connection.id];
        return s != null && s.severity != HostSeverity.unknown;
      }).toList();
    }

    // Filter: summary-strip bucket (the unified issue-#1 taxonomy).
    final bucket = _bucketFilter;
    if (bucket != null) {
      list = list.where((c) => bucketMap[c.connection.id] == bucket).toList();
    }

    String nameOf(ConnectionWithDetails c) => (c.connection.label.isNotEmpty
            ? c.connection.label
            : c.connection.host)
        .toLowerCase();

    list.sort((a, b) {
      final aId = a.connection.id;
      final bId = b.connection.id;

      switch (_sortMode) {
        case _SortMode.severity:
          final sa = statusMap[aId]?.severity ?? HostSeverity.unknown;
          final sb = statusMap[bId]?.severity ?? HostSeverity.unknown;
          final cmp = sa.index.compareTo(sb.index);
          return cmp != 0 ? cmp : nameOf(a).compareTo(nameOf(b));
        case _SortMode.nameAsc:
          return nameOf(a).compareTo(nameOf(b));
        case _SortMode.nameDesc:
          return nameOf(b).compareTo(nameOf(a));
        case _SortMode.cpuDesc:
          return (statsMap[bId]?.cpuPercent ?? -1)
              .compareTo(statsMap[aId]?.cpuPercent ?? -1);
        case _SortMode.ramDesc:
          return (statsMap[bId]?.ramPercent ?? -1)
              .compareTo(statsMap[aId]?.ramPercent ?? -1);
        case _SortMode.diskDesc:
          return (statsMap[bId]?.diskPercent ?? -1)
              .compareTo(statsMap[aId]?.diskPercent ?? -1);
      }
    });

    return list;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final connectionsAsync = ref.watch(connectionsWithDetailsProvider);
    final agentlessEnabled = ref.watch(agentlessMonitorEnabledProvider);
    final healthMap = ref.watch(connectionHealthProvider);
    final statsMap = ref.watch(serverStatsProvider);
    final sessions = ref.watch(activeSessionsProvider);

    // Staleness must be measured against the BACKGROUND poll cadence (minutes),
    // not the live-session auto-refresh interval (30s default). Using the live
    // interval marked every background sample stale, which greyed the gauges and
    // showed "Can't check" for hosts that were actually reporting. Mirrors the
    // desktop MonitorTableView, which sources the window the same way.
    final threshold = monitorStaleAfter(
      checkIntervalMinutes: ref.watch(monitorThresholdsProvider).global.checkIntervalMinutes,
      refreshIntervalSeconds: ref.read(serverStatsProvider.notifier).refreshIntervalSeconds,
    );

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        // On a phone, the name of its tab ("Monitor"): beside its four
        // buttons, "Server Monitor" ran out of a phone's bar 360 wide.
        title: Text(MediaQuery.sizeOf(context).width < 600 ? l10n.phoneTabMonitor : l10n.monitorTitle),
        actions: [
          const SetupGuideButton(SetupTopic.serverMonitor),
          // Slimmed to the two per-visit actions (refresh + sort/filter);
          // configuration (manage hosts, thresholds, auto-refresh) collapses
          // into the trailing overflow menu - five 48dp targets were crowding
          // the title on phones, and Manage already has entry points in the
          // monitor bar below.

          // Manual refresh, and sort and filter: only while monitoring is on.
          if (agentlessEnabled)
          IconButton(
            icon: _isRefreshing
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.brandOrange,
                    ),
                  )
                : const Icon(LucideIcons.refreshCw),
            tooltip: l10n.monitorRefreshAll,
            onPressed: _isRefreshing
                ? null
                : () => _refreshEverything(showSnackbar: true, asked: true),
          ),

          // Sort & Filter (merged)
          if (agentlessEnabled)
          PopupMenuButton<String>(
            icon: Icon(
              LucideIcons.arrowDownWideNarrow,
              size: 20,
              color: _hideUnmonitored ? AppColors.accentInk : null,
            ),
            tooltip: l10n.monitorSortAndFilter,
            onSelected: (value) {
              if (value == 'filter_toggle') {
                setState(() => _hideUnmonitored = !_hideUnmonitored);
              } else {
                // Sort mode
                final mode =
                    _SortMode.values.firstWhere((m) => m.name == value);
                _setSortMode(mode);
              }
            },
            itemBuilder: (context) => [
              // Sort options
              PopupMenuItem(
                enabled: false,
                height: 28,
                child: Text(l10n.monitorSortHeader,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary)),
              ),
              for (final mode in _SortMode.values)
                PopupMenuItem(
                  value: mode.name,
                  child: Row(
                    children: [
                      Icon(mode.icon,
                          size: 16,
                          color: _sortMode == mode
                              ? AppColors.accentInk
                              : AppColors.textSecondary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(mode.label(l10n),
                            style: TextStyle(
                              color: _sortMode == mode
                                  ? AppColors.accentInk
                                  : null,
                              fontWeight:
                                  _sortMode == mode ? FontWeight.w600 : null,
                            )),
                      ),
                      if (_sortMode == mode)
                        Icon(LucideIcons.check,
                            size: 16, color: AppColors.accentInk),
                    ],
                  ),
                ),
              const PopupMenuDivider(),
              // Filter option
              PopupMenuItem(
                value: 'filter_toggle',
                child: Row(
                  children: [
                    Icon(
                      _hideUnmonitored
                          ? LucideIcons.checkSquare
                          : LucideIcons.square,
                      size: 16,
                      color: _hideUnmonitored
                          ? AppColors.accentInk
                          : AppColors.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Text(l10n.monitorHideUnmonitored),
                  ],
                ),
              ),
            ],
          ),

          // Overflow: configuration actions (manage / thresholds / auto-
          // refresh). The icon tints green while auto-refresh runs so its
          // state stays visible without a dedicated AppBar slot.
          PopupMenuButton<String>(
            icon: Icon(
              LucideIcons.moreHorizontal,
              color:
                  _statsNotifier.isAutoRefreshing ? AppColors.success : null,
            ),
            tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
            onSelected: (value) {
              if (value == 'manage') {
                showMonitorManageServers(context);
              } else if (value == 'thresholds') {
                showMonitorThresholds(context);
              } else if (value == 'datasource') {
                showMonitorDataSourceSheet(context);
              } else if (value == 'auto_off') {
                _statsNotifier.stopAutoRefresh();
                setState(() {});
              } else if (value.startsWith('auto_')) {
                _statsNotifier.startAutoRefresh(int.parse(value.substring(5)));
                setState(() {});
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'manage',
                child: Row(children: [
                  Icon(LucideIcons.listChecks,
                      size: 18, color: AppColors.textSecondary),
                  const SizedBox(width: 12),
                  Text(l10n.monitorManageAction),
                ]),
              ),
              PopupMenuItem(
                value: 'thresholds',
                child: Row(children: [
                  Icon(LucideIcons.slidersHorizontal,
                      size: 18, color: AppColors.textSecondary),
                  const SizedBox(width: 12),
                  Text(l10n.zestMonitorThresholdsButton),
                ]),
              ),
              PopupMenuItem(
                value: 'datasource',
                child: Row(children: [
                  Icon(LucideIcons.server,
                      size: 18, color: AppColors.textSecondary),
                  const SizedBox(width: 12),
                  Text(l10n.monitorDataSource),
                ]),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                enabled: false,
                height: 28,
                child: Text(
                  _statsNotifier.isAutoRefreshing
                      ? l10n.monitorAutoRefreshOnTooltip(
                          _statsNotifier.refreshIntervalSeconds)
                      : l10n.monitorAutoRefreshOffTooltip,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary),
                ),
              ),
              PopupMenuItem(
                value: 'auto_off',
                child: Row(children: [
                  Icon(
                    !_statsNotifier.isAutoRefreshing
                        ? LucideIcons.circleDot
                        : LucideIcons.circle,
                    size: 16,
                    color: !_statsNotifier.isAutoRefreshing
                        ? AppColors.accentInk
                        : AppColors.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Text(l10n.monitorAutoRefreshOff),
                ]),
              ),
              for (final secs in [10, 15, 30, 60, 120])
                PopupMenuItem(
                  value: 'auto_$secs',
                  child: Row(children: [
                    Icon(
                      _statsNotifier.isAutoRefreshing &&
                              _statsNotifier.refreshIntervalSeconds == secs
                          ? LucideIcons.circleDot
                          : LucideIcons.circle,
                      size: 16,
                      color: _statsNotifier.isAutoRefreshing &&
                              _statsNotifier.refreshIntervalSeconds == secs
                          ? AppColors.accentInk
                          : AppColors.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Text(l10n.monitorAutoRefreshEvery(secs)),
                  ]),
                ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (widget.underBar != null) SizedBox(width: double.infinity, child: widget.underBar),
          if (agentlessEnabled)
          _AgentlessMonitorBar(
            enabled: agentlessEnabled,
            onToggle: (v) => ref
                .read(agentlessMonitorEnabledProvider.notifier)
                .setEnabled(v),
            onManage: () => showMonitorManageServers(context),
          ),
          Expanded(
            child: !agentlessEnabled
                ? _AgentlessOffState(
                    onEnable: () => ref
                        .read(agentlessMonitorEnabledProvider.notifier)
                        .setEnabled(true),
                    onManage: () => showMonitorManageServers(context),
                  )
                : connectionsAsync.when(
        data: (connections) {
          // Filter out local shells.
          final sshOnly = connections
              .where((c) => c.connection.protocol != 'localShell')
              .toList();

          if (sshOnly.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.activity,
                      size: 64, color: AppColors.onSurfaceDim),
                  const SizedBox(height: 16),
                  Text(
                    l10n.monitorNoConnections,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.monitorAddConnection,
                    style: TextStyle(
                      color: AppColors.onSurfaceDim,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            );
          }

          // Evaluate freshness (for the stale banners) AND the four-bucket
          // status (for the chips + card pills) once for the whole fleet, so
          // every host lands in exactly one bucket and the chips sum to the
          // host count.
          final monitorStatuses = ref.watch(agentlessMonitorPollerProvider);
          final config = ref.watch(monitorThresholdsProvider);
          final now = DateTime.now();
          final statusMap = <String, HostStatus>{};
          final viewMap = <String, MonitorHostView>{};
          final bucketMap = <String, MonitorBucket?>{};
          final counts = <MonitorBucket, int>{};
          for (final c in sshOnly) {
            final id = c.connection.id;
            final hasActiveSession = sessions.values.any(
              (s) =>
                  s.connectionId == id &&
                  s.status == SessionStatus.connected,
            );
            final status = evaluateHost(
              health: healthMap[id],
              stats: statsMap[id],
              hasActiveSession: hasActiveSession,
              threshold: threshold,
              now: now,
            );
            statusMap[id] = status;
            final view = resolveMonitorHost(
              history: ref.read(serverStatsHistoryProvider(id)),
              stats: statsMap[id],
              health: healthMap[id],
              monitor: monitorStatuses[id],
              hasActiveSession: hasActiveSession,
              thresholds: config.resolveFor(id),
              // The host's own alert choices (its panel's Alert menu).
              silenced: ref.read(hostAlertPrefsProvider)[id]?.silencedAt(now) ?? const {},
              countArcAsFree: ref.read(hostAlertPrefsProvider)[id]?.countArcAsFree ?? false,
              debounceReadings: config.global.debounceReadings,
              staleAfter: threshold,
              now: now,
            );
            viewMap[id] = view;
            bucketMap[id] = view.bucket;
            counts[view.bucket] = (counts[view.bucket] ?? 0) + 1;
          }

          final sshConnections =
              _sortAndFilter(sshOnly, statusMap, statsMap, bucketMap);

          final showSortChip = _sortMode != _SortMode.severity ||
              _hideUnmonitored ||
              _bucketFilter != null;

          // Headers rendered above the card list (scroll with content).
          final headers = <Widget>[
            _SeveritySummaryStrip(
              counts: counts,
              active: _bucketFilter,
              onTap: (sev) => setState(() {
                _bucketFilter = _bucketFilter == sev ? null : sev;
              }),
            ),
            if (showSortChip)
              _buildFilterChipRow(l10n, sshConnections.length, sshOnly.length),
          ];

          Widget listBody;
          if (sshConnections.isEmpty) {
            // Everything filtered out.
            listBody = ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ...headers,
                const SizedBox(height: 48),
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(LucideIcons.filterX,
                          size: 48, color: AppColors.onSurfaceDim),
                      const SizedBox(height: 12),
                      Text(
                        l10n.monitorNoMatch,
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 15,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => setState(() {
                          _hideUnmonitored = false;
                          _bucketFilter = null;
                        }),
                        child: Text(l10n.monitorShowAll),
                      ),
                    ],
                  ),
                ),
              ],
            );
          } else {
            // A phone's and a tablet's Monitor leads with the hosts that need
            // attention, then the others, folded to a few (3.0). Only in its own
            // order
            // (most alarming first) with nothing picked: a sort or a filter
            // someone chose shows the list as chosen. A computer keeps its list.
            final rows = <Object>[...headers];
            final problemsFirst = isTouchLayout &&
                _sortMode == _SortMode.severity &&
                _bucketFilter == null &&
                !_hideUnmonitored;
            // Over a critical limit first, then a warning, then a check that
            // cannot be made; each in the list's own order.
            final attention = problemsFirst
                ? [
                    for (final bucket in const [MonitorBucket.critical, MonitorBucket.warning, MonitorBucket.cantCheck])
                      for (final c in sshConnections)
                        if (viewMap[c.connection.id]!.bucket == bucket && monitorNeedsAttention(viewMap[c.connection.id]!))
                          c,
                  ]
                : const <ConnectionWithDetails>[];
            if (attention.isEmpty) {
              rows.addAll(sshConnections);
            } else {
              final others = [for (final c in sshConnections) if (!attention.contains(c)) c];
              final shownOthers = _showAllOthers ? others : others.take(kMonitorOthersShown).toList();
              rows
                ..add(ZestSectionHeader(
                    key: const ValueKey('monitor-attention-header'),
                    label: l10n.hostsFilterAttention,
                    count: attention.length))
                ..addAll(attention);
              if (others.isNotEmpty) {
                rows
                  ..add(Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: ZestSectionHeader(
                        key: const ValueKey('monitor-others-header'),
                        label: l10n.monitorOtherHosts,
                        count: others.length),
                  ))
                  ..addAll(shownOthers);
                if (others.length > kMonitorOthersShown) {
                  rows.add(Center(
                    child: TextButton(
                      key: ValueKey(_showAllOthers ? 'monitor-show-fewer' : 'monitor-show-more'),
                      onPressed: () => setState(() => _showAllOthers = !_showAllOthers),
                      child: Text(_showAllOthers
                          ? l10n.hostsGroupsShowFewer
                          : l10n.monitorShowMoreHosts(others.length - kMonitorOthersShown)),
                    ),
                  ));
                }
              }
            }
            // Where the readings came from, on a phone and a tablet, only
            // where the hosts' sources differ (some through Prometheus, some
            // over SSH): one that every card says is said by none.
            final showSources = !isTouchLayout ||
                {
                  for (final c in sshConnections)
                    if (statsMap[c.connection.id]?.source case final source?)
                      if (source != MetricSource.none) source,
                }.length > 1;
            listBody = ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final row = rows[index];
                if (row is Widget) return row;
                final connDetails = row as ConnectionWithDetails;
                final conn = connDetails.connection;
                final status = statusMap[conn.id] ??
                    const HostStatus(severity: HostSeverity.unknown);
                final hasActiveSession = sessions.values.any(
                  (s) =>
                      s.connectionId == conn.id &&
                      s.status == SessionStatus.connected,
                );

                return _ServerCard(
                  connection: connDetails,
                  health: healthMap[conn.id],
                  stats: statsMap[conn.id],
                  status: status,
                  view: viewMap[conn.id]!,
                  hasActiveSession: hasActiveSession,
                  showSource: showSources,
                  onTap: () {
                    context.push(
                      '/monitor/server/${conn.id}',
                      extra: {
                        'serverName': conn.label.isNotEmpty
                            ? conn.label
                            : conn.host,
                        'host': conn.host,
                        'port': conn.port,
                      },
                    );
                  },
                  onRefresh: hasActiveSession
                      ? () {
                          ref
                              .read(serverStatsProvider.notifier)
                              .refreshOne(conn.id);
                        }
                      : () async {
                          // No active session - at least re-check health
                          // (where those checks are on: Settings).
                          await ref
                              .read(connectionHealthProvider.notifier)
                              .checkHealth(conn);
                        },
                );
              },
            );
          }

          return RefreshIndicator(
            onRefresh: () => _refreshEverything(asked: true),
            color: AppColors.brandOrange,
            // Cards scrolled under the background monitoring bar fade out
            // there: cut hard, a card's last pixels under the bar read as an
            // empty sliver of a card (the folded list, a design
            // audit).
            child: ZestScrollFade(key: const ValueKey('monitor-list-fade'), child: listBody),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, stack) => LoadErrorState(
          message: l10n.homeUnableToLoadConnections,
          where: 'Loading the hosts of the server monitor',
          error: e,
          stack: stack,
          onRetry: () => ref.invalidate(connectionsWithDetailsProvider),
        ),
                  ),
          ),
        ],
      ),
    );
  }

  /// Chip row summarising the active sort/filter with a Clear affordance.
  Widget _buildFilterChipRow(
      AppLocalizations l10n, int shown, int total) {
    Widget chip(IconData icon, String label, Color color) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (_sortMode != _SortMode.severity)
                  chip(_sortMode.icon, _sortMode.label(l10n),
                      AppColors.brandOrange),
                if (_bucketFilter != null)
                  chip(_bucketFilter!.icon, _bucketFilter!.label(l10n),
                      _bucketFilter!.color),
                if (_hideUnmonitored)
                  chip(LucideIcons.listFilter, '$shown/$total', AppColors.warning),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () {
              setState(() {
                _hideUnmonitored = false;
                _bucketFilter = null;
                _sortMode = _SortMode.severity;
              });
              ref
                  .read(settingsServiceProvider)
                  .setMonitorSortMode(_SortMode.severity.name);
            },
            child: Text(
              l10n.monitorClear,
              style: TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// Severity summary strip (Doc-3 B1)
// ══════════════════════════════════════════════════════════════════════

class _SeveritySummaryStrip extends StatelessWidget {
  final Map<MonitorBucket, int> counts;
  final MonitorBucket? active;
  final ValueChanged<MonitorBucket> onTap;

  const _SeveritySummaryStrip({
    required this.counts,
    required this.active,
    required this.onTap,
  });

  // Display order - most alarming first. The unified [MonitorBucket] taxonomy
  // (issue #1) promotes the actionable agentless states (Unreachable / No
  // credentials) to first-class chips; unmonitored hosts have no bucket and so
  // no tally.
  static const _order = [
    MonitorBucket.critical,
    MonitorBucket.warning,
    MonitorBucket.healthy,
    MonitorBucket.cantCheck,
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final pills = <Widget>[];
    for (final bucket in _order) {
      final count = counts[bucket] ?? 0;
      // Hide empty buckets to stay clean, but always keep the active one so
      // the selection stays clearable.
      if (count == 0 && active != bucket) continue;
      pills.add(_SummaryPill(
        // Same unified 1.7 vocabulary the per-card status pills use, so the
        // chip taxonomy and the row pills never drift (Doc-2 §6 / Foundations).
        color: bucket.color,
        icon: bucket.icon,
        count: count,
        label: bucket.label(l10n),
        selected: active == bucket,
        onTap: () => onTap(bucket),
      ));
    }

    if (pills.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      // A chip that does not fit fades out at the edge, so the row reads as
      // one to scroll (it was cut hard at a phone's edge, a design
      // audit).
      child: ZestScrollFade(
        key: const ValueKey('monitor-summary-fade'),
        axis: Axis.horizontal,
        extent: 28,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (var i = 0; i < pills.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                pills[i],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SummaryPill extends StatelessWidget {
  final Color color;
  final IconData icon;
  final int count;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SummaryPill({
    required this.color,
    required this.icon,
    required this.count,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: selected ? 0.22 : 0.10),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? color.withValues(alpha: 0.7)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 6),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  fontFamily: _numberFont,
                  fontFeatures: _numberFigures,
                  color: color,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: color.withValues(alpha: 0.9),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// Server Card
// ══════════════════════════════════════════════════════════════════════

class _ServerCard extends ConsumerWidget {
  final ConnectionWithDetails connection;
  final HealthCheckResult? health;
  final ServerStats? stats;
  final HostStatus status;
  final MonitorHostView view;
  final bool hasActiveSession;
  final VoidCallback onTap;
  final VoidCallback onRefresh;

  /// Whether the card says where its readings came from ("via SSH"). On a
  /// phone and a tablet only where the cards' sources differ: every card
  /// saying "via SSH" said nothing. A
  /// computer's card keeps its chip.
  final bool showSource;

  const _ServerCard({
    required this.connection,
    this.health,
    this.stats,
    required this.status,
    required this.view,
    required this.hasActiveSession,
    required this.onTap,
    required this.onRefresh,
    this.showSource = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final conn = connection.connection;
    final identity = connection.identity;
    // Recording mode: the rejected user named in the status tooltip and the
    // Can't-check line is the display form.
    final rejectedUserRaw = identity?.username;
    final rejectedUser = rejectedUserRaw == null
        ? null
        : Redactable.username(rejectedUserRaw).displayIn(ref);
    // The host as this card names it, for what a check that failed is said of.
    final hostName = (conn.label.isNotEmpty ? Redactable.host(conn.label) : Redactable.address(conn.host)).displayIn(ref);
    // Four-bucket status (§1) - the header pill shares its chip's label so a
    // card filtered under "Can't check" reads "Can't check" in its pill too.
    final bucket = view.bucket;
    final pillTooltip = monitorPillTooltip(
      view,
      l10n,
      checkedPhrase: view.statsCollectedAt != null
          ? monitorCheckedPhrase(l10n, view.statsCollectedAt!)
          : null,
      rejectedUser: rejectedUser,
      host: hostName,
      port: conn.port,
    );
    final isOnline = health?.status == ConnectionHealth.online;
    final isOffline = health?.status == ConnectionHealth.offline;

    final statsStale = status.statsStale;
    final healthStale = status.healthStale;
    final isStale = status.isStale;

    // Which mechanism produced the current data + any recent collection
    // failure (Doc-3 B5).
    final collectError = ref.watch(serverStatsErrorProvider(conn.id));
    final sourceLabel =
        stats != null && showSource ? _sourceLabel(l10n, stats!.source) : null;

    // Per-host metric history for the sparklines (Doc-3 B6).
    final history = ref.watch(serverStatsHistoryProvider(conn.id));
    final cpuHistory = history.map((s) => s.cpuPercent).toList();
    final ramHistory = history.map((s) => s.ramPercent).toList();
    final diskHistory = history.map((s) => s.diskPercent).toList();

    // Custom colour (colorValue) wins; otherwise the connection's palette
    // colour, inheriting the identity's when the connection is still default.
    final color = AppColors.effectiveConnectionColor(
      connColorValue: conn.colorValue,
      connColorIndex: conn.colorIndex,
      identityColorValue: identity?.colorValue,
      identityColorIndex: identity?.colorIndex ?? 0,
    );

    // Cached (stats from a previous session) but not yet fully stale.
    final isCachedStats = stats != null && !hasActiveSession && !isStale;

    // Timestamp of the freshest sample from either subsystem, for the "ago".
    DateTime? lastUpdated;
    if (stats != null) lastUpdated = stats!.collectedAt;
    if (health != null &&
        (lastUpdated == null || health!.checkedAt.isAfter(lastUpdated))) {
      lastUpdated = health!.checkedAt;
    }

    return Card(
      color: AppColors.surface,
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: hasActiveSession
              ? AppColors.success.withValues(alpha: 0.4)
              : isOnline
                  ? AppColors.success.withValues(alpha: 0.2)
                  : AppColors.divider,
          width: hasActiveSession ? 1.5 : 0.5,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──────────────────────────────────────────
            Row(
              children: [
                // Color bar
                Container(
                  width: 4,
                  height: 36,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 12),

                // Status pill (four-bucket) with a keyboard-reachable,
                // cause-naming tooltip (§1.2). Every host is bucketed, so the
                // pill is always shown; the fuller Can't-check reason + action
                // link render in the banner below.
                Semantics(
                  label: pillTooltip,
                  container: true,
                  child: Tooltip(
                    message: pillTooltip,
                    waitDuration: const Duration(milliseconds: 300),
                    // A phone and a tablet: a chip only where the host needs
                    // someone; Healthy, or a reading under way, is plain text
                    // (3.0).
                    child: isTouchLayout && !monitorNeedsAttention(view)
                        ? Text(
                            bucket.label(l10n),
                            key: ValueKey('monitor-status-text-${conn.id}'),
                            style: TextStyle(fontSize: _cardSize(12), color: AppColors.textSecondary),
                          )
                        : ZestStatusPill(
                            kind: bucket.kind,
                            label: bucket.label(l10n),
                            icon: bucket.icon,
                          ),
                  ),
                ),
                const SizedBox(width: 10),

                // The host's own icon.
                HostGlyph(host: conn, size: 26),
                const SizedBox(width: 10),

                // Name & host
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RedactedText(
                        conn.label.isNotEmpty
                            ? Redactable.host(conn.label)
                            : Redactable.address(conn.host),
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.onSurface,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                      RedactedText(
                        Redactable.address(hostWithPort(conn.host, conn.port)),
                        // 12 still: monospace at 13 cut a status pill's
                        // host's port off on a phone.
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: 'JetBrainsMono',
                          color: AppColors.textSecondary,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ],
                  ),
                ),

                // Latency - muted when the health sample is stale. Plain text
                // on a phone and a tablet (coloured only past its limit).
                if (health?.latencyMs != null && isTouchLayout)
                  Text(
                    '${latencyText(health!.latencyMs)} ms',
                    key: ValueKey('monitor-latency-text-${conn.id}'),
                    style: TextStyle(
                      fontSize: _cardSize(12),
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: healthStale || health!.latencyMs! <= kLatencyWarnMs
                          ? AppColors.textSecondary
                          : _latencyColor(health!.latencyMs!),
                    ),
                  )
                else if (health?.latencyMs != null)
                  _InfoChip(
                    label: '${latencyText(health!.latencyMs)}ms',
                    icon: LucideIcons.activity,
                    color: healthStale
                        ? AppColors.onSurfaceDim
                        : _latencyColor(health!.latencyMs!),
                  ),

                const SizedBox(width: 8),

                // A session open to it: plain text on a phone and a tablet.
                if (hasActiveSession && isTouchLayout)
                  Text(
                    l10n.monitorActive,
                    style: TextStyle(fontSize: _cardSize(12), fontWeight: FontWeight.w500, color: AppColors.success),
                  )
                // Session badge
                else if (hasActiveSession)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.success.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(LucideIcons.terminal,
                            size: 10, color: AppColors.success),
                        const SizedBox(width: 4),
                        Text(
                          l10n.monitorActive,
                          style: TextStyle(
                            fontSize: _cardSize(10),
                            color: AppColors.success,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),

                // Refresh button - always enabled (pings health if no session)
                IconButton(
                  icon: const Icon(LucideIcons.refreshCw, size: 18),
                  onPressed: onRefresh,
                  tooltip: hasActiveSession
                      ? l10n.monitorRefreshStats
                      : l10n.monitorConnectForStats,
                  color: AppColors.textSecondary,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                ),
              ],
            ),

            // ── A host that is SFTP only runs no command to read figures
            //    with: said, in place of what checking it would need.
            if (noTerminalReason(conn, l10n) case final noTerminal?)
              Padding(
                key: ValueKey('monitor-sftp-only-${conn.id}'),
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  children: [
                    Icon(LucideIcons.folderOpen, size: 14, color: AppColors.textSecondary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        noTerminal,
                        style: TextStyle(fontSize: _cardSize(12), height: 1.3, color: AppColors.textSecondary),
                      ),
                    ),
                  ],
                ),
              )
            // ── Can't-check detail line: the reason + an action link to the
            //    credential where the user can act (§1.2).
            else if (bucket == MonitorBucket.cantCheck)
              _CantCheckLine(
                view: view,
                connectionId: conn.id,
                rejectedUser: rejectedUser,
                hostName: hostName,
                port: conn.port,
              ),

            // ── Stats gauges ────────────────────────────────────
            if (stats != null) ...[
              const SizedBox(height: 16),
              // Collection source (Doc-3 B5) - which mechanism produced these
              // numbers. Muted / informational; only when the source is known.
              if (sourceLabel != null) ...[
                Row(
                  children: [
                    // Plain text on a phone and a tablet ("via SSH" was a
                    // chip; chips are for filters and what needs someone).
                    if (isTouchLayout)
                      Text(
                        sourceLabel,
                        key: ValueKey('monitor-source-text-${conn.id}'),
                        style: TextStyle(fontSize: _cardSize(11.5), color: AppColors.textSecondary),
                      )
                    else
                      _SourceChip(
                        icon: _sourceIcon(stats!.source),
                        label: sourceLabel,
                      ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              // Stale / cached banner - unmistakable when data is old.
              if (isStale) ...[
                _StaleBanner(
                  color: AppColors.warning,
                  bold: true,
                  text: l10n.monitorStaleUpdated(
                    lastUpdated != null
                        ? monitorCheckedPhrase(l10n, lastUpdated)
                        : monitorCheckedPhrase(l10n, stats!.collectedAt),
                  ),
                ),
              ] else if (isCachedStats) ...[
                // The last reading, not stale: a quiet line, not a warning
                // (a design audit).
                _StaleBanner(
                  color: AppColors.onSurfaceDim,
                  bold: false,
                  text: l10n.monitorLastCollected(
                      monitorCheckedPhrase(l10n, stats!.collectedAt)),
                ),
              ],
              Row(
                children: [
                  Expanded(
                    child: _GaugeBar(
                      label: l10n.monitorCpu,
                      value: stats!.cpuPercent,
                      icon: LucideIcons.cpu,
                      stale: statsStale,
                      history: cpuHistory,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _GaugeBar(
                      label: l10n.monitorRam,
                      value: stats!.ramPercent,
                      subtitle: stats!.ramUsedMB != null &&
                              stats!.ramTotalMB != null
                          ? _ramSubtitle(l10n, stats!.ramUsedMB!, stats!.ramTotalMB!)
                          : null,
                      icon: LucideIcons.circuitBoard,
                      stale: statsStale,
                      history: ramHistory,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _GaugeBar(
                      label: l10n.monitorDisk,
                      value: stats!.diskPercent,
                      icon: LucideIcons.hardDrive,
                      stale: statsStale,
                      history: diskHistory,
                    ),
                  ),
                ],
              ),
            ] else if (collectError != null) ...[
              // Name the mechanism that failed + a brief reason (Doc-3 B5),
              // shown only when there's no fresh data to display.
              const SizedBox(height: 12),
              _CollectErrorLine(error: collectError),
            ] else if (hasActiveSession) ...[
              const SizedBox(height: 12),
              Center(
                child: Text(
                  l10n.monitorCollectingStats,
                  style: TextStyle(
                    fontSize: _cardSize(12),
                    color: AppColors.onSurfaceDim,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ] else if (isOffline) ...[
              const SizedBox(height: 12),
              Center(
                child: Text(
                  l10n.monitorServerOffline,
                  style: TextStyle(
                    fontSize: _cardSize(12),
                    color: AppColors.error,
                  ),
                ),
              ),
            ] else if (health == null && !monitorNeedsAttention(view)) ...[
              // (A host whose check failed or needs someone has its reason
              // above: not "never checked" under it, the design audit.)
              // Nothing is known of the host: "Checking" only while a check
              // of it is under way, and otherwise what is so of it
              // ([nothingKnownOfHost]).
              const SizedBox(height: 12),
              Center(
                child: switch (nothingKnownOfHost(
                  monitored: conn.monitored,
                  readingUnderWay: view.cantCheckReason == CantCheckReason.connecting,
                  reachabilityChecksOn: ref.watch(healthChecksEnabledProvider),
                )) {
                  NothingKnownOfHost.checking => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: AppColors.textSecondary.withValues(alpha: 0.5),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          l10n.monitorChecking,
                          style: TextStyle(
                            fontSize: _cardSize(12),
                            color: AppColors.onSurfaceDim,
                          ),
                        ),
                      ],
                    ),
                  NothingKnownOfHost.notMonitored => Text(
                      l10n.monitorStatusNotEligible,
                      key: const ValueKey('monitor-card-not-monitored'),
                      style: TextStyle(fontSize: _cardSize(12), color: AppColors.onSurfaceDim),
                      textAlign: TextAlign.center,
                    ),
                  NothingKnownOfHost.neverChecked => Text(
                      l10n.zestMonitorTipNeverChecked,
                      key: const ValueKey('monitor-card-never-checked'),
                      style: TextStyle(fontSize: _cardSize(12), color: AppColors.onSurfaceDim),
                      textAlign: TextAlign.center,
                    ),
                },
              ),
            ] else ...[
              // Empty-state requirement (Doc-3 B5): no data, no live session,
              // no Prometheus match - spell out what collection needs.
              const SizedBox(height: 12),
              Center(
                child: Text(
                  l10n.monitorNeedsSshOrPrometheus,
                  style: TextStyle(
                    fontSize: _cardSize(12),
                    color: AppColors.onSurfaceDim,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],

            // ── Load Average ───────────────────────────────────
            if (stats?.loadAverage != null &&
                stats!.loadAverage!.length >= 3) ...[
              const SizedBox(height: 8),
              Opacity(
                opacity: statsStale ? 0.5 : 1.0,
                child: Row(
                  children: [
                    Icon(LucideIcons.trendingUp,
                        size: 12, color: AppColors.textSecondary),
                    const SizedBox(width: 6),
                    Text(
                      '${l10n.monitorLoadAvg}: ',
                      style: TextStyle(
                        fontSize: _cardSize(11),
                        color: AppColors.textSecondary,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        stats!.loadAverage!
                            .take(3)
                            .map((v) => formatDecimal(v, digits: 2, l10n: l10n))
                            .join('  '),
                        style: TextStyle(
                          fontSize: _cardSize(11),
                          fontFamily: _numberFont,
                          fontFeatures: _numberFigures,
                          color: AppColors.onSurface,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // ── Uptime ──────────────────────────────────────────
            if (stats?.uptime != null) ...[
              const SizedBox(height: 4),
              Opacity(
                opacity: statsStale ? 0.5 : 1.0,
                child: Row(
                  children: [
                    Icon(LucideIcons.clock,
                        size: 12, color: AppColors.textSecondary),
                    const SizedBox(width: 6),
                    Expanded(
                      // Abbreviated to 2 units (B4); full precision on hover.
                      child: Tooltip(
                        message: l10n.monitorUptime(stats!.uptime!),
                        waitDuration: const Duration(milliseconds: 300),
                        child: Text(
                          l10n.monitorUptime(abbreviateUptime(stats!.uptime!)),
                          style: TextStyle(
                            fontSize: _cardSize(11),
                            color: AppColors.textSecondary,
                            fontFamily: _numberFont,
                            fontFeatures: _numberFigures,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                    ),
                    if (!isCachedStats && !isStale) ...[
                      const SizedBox(width: 8),
                      Text(
                        timeAgoWords(l10n, stats!.collectedAt, seconds: true),
                        style: TextStyle(
                          fontSize: _cardSize(10),
                          color: AppColors.onSurfaceDim,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],

          ],
        ),
      ),
      ),
    );
  }

  Color _latencyColor(int ms) {
    // Calibrated for real SSH (Doc-3 B3): LAN + regional round-trips
    // (~60-100ms) are perfectly normal and must NOT read as caution - the
    // old <50/<150 bands flagged a healthy 61-70ms link amber. Interactive
    // SSH stays comfortable to ~100ms; 100-250ms is noticeable but usable;
    // above that it genuinely drags.
    if (ms <= kLatencyWarnMs) return AppColors.success;
    if (ms <= kLatencyCriticalMs) return AppColors.warning;
    return AppColors.error;
  }

  /// Muted "via {mechanism}" label for the source chip (Doc-3 B5), or null
  /// when the source is unknown (legacy cache) - nothing is rendered then.
  String? _sourceLabel(AppLocalizations l10n, MetricSource source) {
    switch (source) {
      case MetricSource.prometheus:
        return l10n.monitorSourceVia(l10n.monitorMechanismPrometheus);
      case MetricSource.ssh:
        return l10n.monitorSourceVia(l10n.monitorMechanismSsh);
      case MetricSource.none:
        return null;
    }
  }

  IconData _sourceIcon(MetricSource source) {
    switch (source) {
      case MetricSource.prometheus:
        return LucideIcons.lineChart;
      case MetricSource.ssh:
        return LucideIcons.terminal;
      case MetricSource.none:
        return LucideIcons.helpCircle;
    }
  }
}

/// Compact banner that makes cached / stale data unmistakable (Doc-3 B2).
class _StaleBanner extends StatelessWidget {
  final Color color;
  final bool bold;
  final String text;

  const _StaleBanner({
    required this.color,
    required this.bold,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: bold ? 0.16 : 0.1),
        borderRadius: BorderRadius.circular(6),
        border: bold
            ? Border.all(color: color.withValues(alpha: 0.4), width: 0.5)
            : null,
      ),
      child: Row(
        children: [
          Icon(bold ? LucideIcons.alertTriangle : LucideIcons.history,
              size: 11, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: _cardSize(10),
                color: color,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Abbreviate a raw uptime string to its 2 most-significant non-zero units on
/// ONE consistent day/hour/minute ladder (Doc-3 B4), e.g.
/// "up 5 days, 3 hours, 42 minutes" → "5d 3h". Weeks are always folded into
/// days (1w = 7d) so the column never mixes a weeks-based value ("6w 6d") next
/// to a days-based one ("173d 10h") - every host renders on the same scale.
/// The full string is shown on hover at the call site. Handles the word form
/// and the Prometheus "H:M" form; falls back to the cleaned raw string if
/// unparseable.
String abbreviateUptime(String raw) {
  final units = <String, int>{};
  final wordRe = RegExp(
    r'(\d+)\s*(weeks?|days?|hours?|hrs?|mins?|minutes?)',
    caseSensitive: false,
  );
  for (final m in wordRe.allMatches(raw)) {
    final v = int.tryParse(m.group(1)!) ?? 0;
    final u = m.group(2)!.toLowerCase();
    if (u.startsWith('w')) {
      // Fold weeks into days for a single, consistent d/h/m ladder.
      units['d'] = (units['d'] ?? 0) + v * 7;
    } else if (u.startsWith('d')) {
      units['d'] = (units['d'] ?? 0) + v;
    } else if (u.startsWith('h')) {
      units['h'] = (units['h'] ?? 0) + v;
    } else {
      units['m'] = (units['m'] ?? 0) + v;
    }
  }
  // "H:M" form (e.g. Prometheus "3:42") when no hour/minute words appeared.
  if (!units.containsKey('h') && !units.containsKey('m')) {
    final colon = RegExp(r'(\d+):(\d{2})').firstMatch(raw);
    if (colon != null) {
      units['h'] = int.tryParse(colon.group(1)!) ?? 0;
      units['m'] = int.tryParse(colon.group(2)!) ?? 0;
    }
  }
  const seq = ['d', 'h', 'm'];
  final parts = <String>[];
  for (final u in seq) {
    final v = units[u] ?? 0;
    if (v > 0) {
      parts.add('$v$u');
      if (parts.length == 2) break;
    }
  }
  if (parts.isEmpty) {
    return raw
        .replaceFirst(RegExp(r'^\s*up\s+', caseSensitive: false), '')
        .trim();
  }
  return parts.join(' ');
}

// ══════════════════════════════════════════════════════════════════════
// Gauge Bar
// ══════════════════════════════════════════════════════════════════════

class _GaugeBar extends StatelessWidget {
  final String label;
  final double? value;
  final String? subtitle;
  final IconData icon;
  final String? notAvailableLabel;

  /// De-emphasise the reading (muted colour) when the underlying sample is
  /// stale so it never reads as live (Doc-3 B2).
  final bool stale;

  /// Bounded metric history (oldest → newest, 0-100, nulls = gaps) for the
  /// sparkline (Doc-3 B6). Null / <2 samples renders no sparkline.
  final List<double?>? history;

  const _GaugeBar({
    required this.label,
    required this.value,
    this.subtitle,
    required this.icon,
    // ignore: unused_element_parameter
    this.notAvailableLabel,
    this.stale = false,
    this.history,
  });

  @override
  Widget build(BuildContext context) {
    final displayValue = value?.clamp(0.0, 100.0);
    final liveColor = _gaugeColor(displayValue);
    final color = stale ? AppColors.onSurfaceDim : liveColor;

    final hist = history;
    final hasSparkline =
        hist != null && hist.where((v) => v != null).length >= 2;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Label row
        Row(
          children: [
            Icon(icon, size: 12, color: AppColors.textSecondary),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: _cardSize(11),
                fontWeight: FontWeight.w500,
                color: AppColors.textSecondary,
              ),
            ),
            // The value takes all the room after the label, at the end (a
            // Spacer beside it took half, and cut "89%" short on a phone).
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                key: ValueKey('monitor-gauge-value-$label'),
                textAlign: TextAlign.end,
                displayValue != null
                    ? formatPercentNumber(displayValue)
                    : (notAvailableLabel ??
                        AppLocalizations.of(context)!.monitorNotAvailable),
                style: TextStyle(
                  fontSize: _cardSize(11),
                  fontWeight: FontWeight.w600,
                  fontFamily: _numberFont,
                  fontFeatures: _numberFigures,
                  color:
                      displayValue != null ? color : AppColors.onSurfaceDim,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),

        // Progress bar
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: displayValue != null ? displayValue / 100 : 0,
            minHeight: 6,
            backgroundColor: AppColors.surfaceContainerHigh,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),

        // History bars (Doc-3 B6 / §10) - calm bars on an absolute 0-100 scale,
        // consistent with the desktop table's History column. Only shown when
        // we have enough history.
        if (hasSparkline) ...[
          const SizedBox(height: 3),
          MonitorHistoryBars(
            values: hist,
            color: color.withValues(alpha: 0.7),
            height: 14,
          ),
        ],

        // Subtitle (e.g. "4096 / 8192 MB")
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            style: TextStyle(
              fontSize: _cardSize(9),
              color: AppColors.onSurfaceDim,
              fontFamily: _numberFont,
              fontFeatures: _numberFigures,
            ),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ],
      ],
    );
  }

  Color _gaugeColor(double? value) {
    if (value == null) return AppColors.onSurfaceDim;
    if (value < kGaugeWarn) return AppColors.success;
    if (value < kGaugeCritical) return AppColors.warning;
    return AppColors.error;
  }
}

// ══════════════════════════════════════════════════════════════════════
// Info Chip
// ══════════════════════════════════════════════════════════════════════

class _InfoChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;

  const _InfoChip({
    required this.label,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
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
// Collection-source visibility (Doc-3 B5)
// ══════════════════════════════════════════════════════════════════════

/// Small muted chip naming which mechanism produced a card's data - e.g.
/// "via Prometheus" / "via SSH". Informational, not loud.
class _SourceChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _SourceChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.onSurfaceDim.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: AppColors.onSurfaceDim),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: AppColors.onSurfaceDim,
            ),
          ),
        ],
      ),
    );
  }
}

/// Names the collection mechanism that failed plus a brief reason - shown on a
/// card only when there's no fresh data to display instead.
class _CollectErrorLine extends StatelessWidget {
  final CollectionError error;

  const _CollectErrorLine({required this.error});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final mechanism = switch (error.source) {
      MetricSource.prometheus => l10n.monitorMechanismPrometheus,
      MetricSource.ssh => l10n.monitorMechanismSsh,
      MetricSource.none => '',
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(LucideIcons.alertCircle, size: 12, color: AppColors.error),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            l10n.monitorCollectFailed(mechanism, error.reason),
            style: TextStyle(fontSize: _cardSize(12), color: AppColors.error),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// The Can't-check detail banner: a neutral line naming the cause (§1.2) plus,
/// for the actionable reasons, a link to add / fix the host's credential, and,
/// where a check that failed is the cause, what it failed with and a way to
/// copy that.
class _CantCheckLine extends StatelessWidget {
  final MonitorHostView view;
  final String connectionId;
  final String? rejectedUser;

  /// The host as its card names it, and its port: what a check that failed
  /// is said of.
  final String hostName;
  final int port;

  const _CantCheckLine({
    required this.view,
    required this.connectionId,
    required this.rejectedUser,
    required this.hostName,
    required this.port,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final message = monitorPillTooltip(view, l10n, rejectedUser: rejectedUser, host: hostName, port: port);
    final report = failedCheckReport(view, message);
    final action = view.cantCheckReason != null
        ? monitorCantCheckAction(view.cantCheckReason!)
        : null;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.onSurfaceDim.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: AppColors.onSurfaceDim.withValues(alpha: 0.25), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(LucideIcons.helpCircle,
                  size: 14, color: AppColors.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    fontSize: _cardSize(12),
                    height: 1.3,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          // What can be done about it, under sentences that take the width:
          // the link to the host's sign-in details, and what a check failed
          // with, to copy.
          if (action != null || report != null)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Wrap(
                spacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (action != null)
                    TextButton(
                      onPressed: () => context.push('/connection/edit/$connectionId'),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.accentInk,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        action == MonitorCantCheckAction.addCredential
                            ? l10n.zestMonitorActionAddCredential
                            : l10n.monitorTableFixLogin,
                      ),
                    ),
                  if (report != null) CopyDetailsButton(detail: report, color: AppColors.textSecondary),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// Agentless background-monitoring: master toggle strip + off-state
// ══════════════════════════════════════════════════════════════════════

/// Header strip with the master on/off switch for agentless background
/// monitoring, a short explainer, and a shortcut to choose which hosts to
/// monitor. Always visible so the user can flip it from either state.
class _AgentlessMonitorBar extends StatelessWidget {
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final VoidCallback onManage;

  const _AgentlessMonitorBar({
    required this.enabled,
    required this.onToggle,
    required this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      child: Row(
        children: [
          Icon(
            LucideIcons.radar,
            size: 20,
            color: enabled ? AppColors.accentInk : AppColors.textSecondary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.monitorAgentlessEnable,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.monitorAgentlessEnableDesc,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.3,
                    color: AppColors.textSecondary,
                  ),
                ),
                if (enabled)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: TextButton.icon(
                      onPressed: onManage,
                      icon: const Icon(LucideIcons.listChecks, size: 16),
                      label: Text(l10n.monitorManageAction),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.accentInk,
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        minimumSize: const Size(0, 28),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ZestSwitch(value: enabled, onChanged: onToggle),
        ],
      ),
    );
  }
}

/// Full-body explainer shown when agentless monitoring is off: what it does
/// plus a primary CTA to enable it and a shortcut to choose hosts.
class _AgentlessOffState extends StatelessWidget {
  final VoidCallback onEnable;
  final VoidCallback onManage;

  const _AgentlessOffState({required this.onEnable, required this.onManage});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Scrolls where it does not fit (the large text a phone can be set
    // to): the button that turns the monitor on was cut off.
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.radar,
                size: 56, color: AppColors.onSurfaceDim),
            const SizedBox(height: 16),
            Text(
              l10n.monitorAgentlessOffTitle,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: AppColors.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.monitorAgentlessOffBody,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: AppColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onEnable,
              icon: const Icon(LucideIcons.play, size: 18),
              label: Text(l10n.monitorAgentlessEnableAction),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onManage,
              icon: const Icon(LucideIcons.listChecks, size: 18),
              label: Text(l10n.monitorManageAction),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
