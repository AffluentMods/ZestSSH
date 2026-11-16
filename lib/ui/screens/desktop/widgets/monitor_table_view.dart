import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart' show NumberFormat;
import 'package:lucide_icons/lucide_icons.dart';

import 'package:zestssh/features/broadcast/broadcast_to_hosts.dart';
import 'package:zestssh/features/hosts/open_selected_hosts.dart';
import 'package:zestssh/features/monitoring/monitor_host_views.dart';
import 'package:zestssh/features/run/run_on_hosts_view.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/ui/screens/monitoring/prometheus_config_sheet.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart' show Connection, MonitorSample;
import 'package:zestssh/features/monitoring/monitor_columns.dart';
import 'package:zestssh/features/monitoring/monitor_evaluation.dart';
import 'package:zestssh/features/monitoring/monitor_state_ui.dart';
import 'package:zestssh/features/monitoring/monitor_thresholds.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/providers/monitor_thresholds_provider.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/server_stats_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/utils/command_text.dart';
import 'package:zestssh/ui/screens/desktop/widgets/monitor_detail_pane.dart';
import 'package:zestssh/ui/screens/help/setup_guide_screen.dart';
import 'package:zestssh/ui/screens/monitoring/monitor_manage_dialog.dart';
import 'package:zestssh/ui/screens/monitoring/monitor_thresholds_dialog.dart';
import 'package:zestssh/ui/screens/purchase/pricing_modal.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/ui/widgets/menu_dots_button.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_empty_state.dart';
import 'package:zestssh/ui/widgets/button_box.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/ui/widgets/load_error_state.dart';
import 'package:zestssh/utils/host_address.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/ui/widgets/guide_help_button.dart';
import 'package:zestssh/ui/screens/desktop/widgets/shell_questions.dart' show confirmUnencryptedConnection;
import 'package:zestssh/utils/number_text.dart';

/// Fixed columns that always frame the table: Host + Status lead; the "Last
/// 24 checks" bars, Seen and the row's buttons trail. The metric columns
/// between them are chooser-managed ([MonitorColumn], §2).
enum _FixedCol { host, status, last24, seen, actions }

/// A column's width until its person sets one: Host is sized to its content
/// ([_hostContentWidth]), and this is what it falls back on.
double _fixedColWidth(_FixedCol c) => switch (c) {
      _FixedCol.host => 180,
      // Fits the widest status chip ("Swap high" beside "Reboot") and the
      // two-line reasons with their fix ("Not watched yet" / "Watch this host").
      _FixedCol.status => 216,
      // 24 bars of 3 with gaps of 1.5, and room around them.
      _FixedCol.last24 => 132,
      _FixedCol.seen => 64,
      _FixedCol.actions => 72,
    };

/// One resolved table column: either a [_FixedCol] or a chooser-managed metric
/// [MonitorColumn]. Exactly one of the two is non-null.
class _Column {
  final _FixedCol? fixed;
  final MonitorColumn? metric;
  const _Column.fixed(this.fixed) : metric = null;
  const _Column.metric(this.metric) : fixed = null;

  double get width => fixed != null ? _fixedColWidth(fixed!) : metric!.width;

  /// Clickable to re-sort. The bars, Seen and the buttons are not sortable,
  /// nor are the composite Network / Disk I/O columns. (Updates is, to find
  /// the hosts with the most waiting.)
  bool get sortable {
    final f = fixed;
    if (f != null) return f == _FixedCol.host || f == _FixedCol.status;
    final m = metric!;
    return m != MonitorColumn.network && m != MonitorColumn.diskIo;
  }

  /// Stable identity for sort-state comparison ([_FixedCol] or [MonitorColumn]).
  Object get identity => fixed ?? metric!;

  /// What its width is kept under, on this device.
  String get key => fixed?.name ?? metric!.key;

  /// Whether its person can set its width: all but the row's buttons.
  bool get resizable => fixed != _FixedCol.actions;

  /// The narrowest it can be dragged, its cells still readable.
  double get minWidth => switch (fixed) {
        _FixedCol.host => 120,
        _FixedCol.status => 120,
        // 24 bars of 3 with gaps of 1.5, and room around them.
        _FixedCol.last24 => 126,
        _FixedCol.seen => 48,
        _FixedCol.actions => _fixedColWidth(_FixedCol.actions),
        null => metric!.isPercentGauge ? 56 : 44,
      };

  String label(AppLocalizations l10n) {
    final f = fixed;
    if (f != null) {
      return switch (f) {
        _FixedCol.host => l10n.monitorColHost,
        _FixedCol.status => l10n.monitorColStatus,
        _FixedCol.last24 => l10n.monitorColLast24Checks,
        _FixedCol.seen => l10n.monitorTableColSeen,
        _FixedCol.actions => '',
      };
    }
    // The table's head is short ("Up"); the chooser names it in full.
    if (metric == MonitorColumn.uptime) return l10n.monitorTableColUp;
    return _metricColLabel(metric!, l10n);
  }
}

String _metricColLabel(MonitorColumn c, AppLocalizations l10n) => switch (c) {
      MonitorColumn.cpu => l10n.monitorCpu,
      MonitorColumn.ram => l10n.monitorRam,
      MonitorColumn.swap => l10n.zestMonMetricSwap,
      MonitorColumn.disk => l10n.monitorDisk,
      MonitorColumn.load => l10n.zestMonSeriesLoad,
      MonitorColumn.temp => l10n.zestMonMetricTemp,
      MonitorColumn.ping => l10n.zestMonMetricPing,
      MonitorColumn.uptime => l10n.monitorColUptime,
      MonitorColumn.network => l10n.zestMonMetricNetwork,
      MonitorColumn.diskIo => l10n.zestMonMetricDiskIo,
      MonitorColumn.updates => l10n.monitorColUpdates,
    };

/// The visible table columns, in order: Host, Status, the visible metric
/// columns, then Last 24 checks, Seen and the row's buttons (§1 / §2).
List<_Column> _resolveColumns(MonitorColumnConfig cfg) => [
      const _Column.fixed(_FixedCol.host),
      const _Column.fixed(_FixedCol.status),
      for (final m in cfg.visibleInOrder) _Column.metric(m),
      const _Column.fixed(_FixedCol.last24),
      const _Column.fixed(_FixedCol.seen),
      const _Column.fixed(_FixedCol.actions),
    ];

/// The scalar used to sort a metric column, or -1 when the host can't report it
/// (so N/A hosts sort to the bottom ascending).
double _metricSortValue(MonitorColumn c, ServerStats? s) {
  double? v;
  switch (c) {
    case MonitorColumn.cpu:
      v = s?.cpuPercent;
    case MonitorColumn.ram:
      v = s?.ramPercent;
    case MonitorColumn.swap:
      v = s?.swapPercent;
    case MonitorColumn.disk:
      v = s?.diskPercent;
    case MonitorColumn.load:
      v = s?.load1;
    case MonitorColumn.temp:
      v = s?.tempC;
    case MonitorColumn.ping:
      v = s?.pingMs?.toDouble();
    case MonitorColumn.uptime:
      v = s?.uptimeSeconds?.toDouble();
    case MonitorColumn.network:
      v = (s?.netRxBytesPerSec ?? 0) + (s?.netTxBytesPerSec ?? 0);
    case MonitorColumn.diskIo:
      v = (s?.diskReadBytesPerSec ?? 0) + (s?.diskWriteBytesPerSec ?? 0);
    case MonitorColumn.updates:
      v = s?.updatesTotal?.toDouble();
  }
  return v ?? -1;
}

/// Where a host stands in the Status sort, problems first: critical, then
/// warning, then the hosts that cannot be checked (each says why and how to
/// fix it), then healthy hosts that ask for a restart, then the rest.
@visibleForTesting
int monitorProblemRank(MonitorBucket bucket, {bool needsReboot = false}) => switch (bucket) {
      MonitorBucket.critical => 0,
      MonitorBucket.warning => 1,
      MonitorBucket.cantCheck => 2,
      MonitorBucket.healthy => needsReboot ? 3 : 4,
    };

/// Fixed leading gutter that holds the 3px row identity rule (§2), kept in
/// both the header and the rows so the columns line up.
const double _kLeadGutter = 14;
const double _kRowHPad = 16;
const double _kRowHeight = 54;

/// How wide each column of the table is, by its [_Column.key], in a table
/// [available] wide: the width its person set, else Host as wide as its
/// content, else the column's own. What is left over goes to the metric columns
/// no width was set for (Host took far too much of
/// it), so the table reaches the toolbar's right edge; with none of those,
/// to Host unless its width was set, and otherwise it stays empty on the right.
@visibleForTesting
Map<String, double> monitorColumnWidths({
  required List<({String key, double width, bool isMetric, bool isHost})> columns,
  required Map<String, double> set,
  required double hostContent,
  required double available,
}) {
  final widths = <String, double>{
    for (final c in columns) c.key: set[c.key] ?? (c.isHost ? hostContent : c.width),
  };
  final extra = available - widths.values.fold(0.0, (sum, w) => sum + w);
  if (extra <= 0) return widths;
  final growing = [
    for (final c in columns)
      if (c.isMetric && !set.containsKey(c.key)) c.key,
  ];
  if (growing.isNotEmpty) {
    for (final k in growing) {
      widths[k] = widths[k]! + extra / growing.length;
    }
  } else {
    for (final c in columns) {
      if (c.isHost && !set.containsKey(c.key)) widths[c.key] = widths[c.key]! + extra;
    }
  }
  return widths;
}

/// The columns of [monitorColumnWidths], from the table's.
List<({String key, double width, bool isMetric, bool isHost})> _widthInputs(List<_Column> cols) => [
      for (final c in cols) (key: c.key, width: c.width, isMetric: c.metric != null, isHost: c.fixed == _FixedCol.host),
    ];

/// How wide [text] draws in [style], as it is drawn in [context].
double _textWidth(BuildContext context, String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.merge(style)),
    maxLines: 1,
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// Where a column's words start inside its cell.
EdgeInsetsGeometry _cellPadding(_Column c) => switch (c.fixed) {
      _FixedCol.last24 => const EdgeInsetsDirectional.only(start: 12, end: 6),
      _FixedCol.actions => EdgeInsets.zero,
      _ => const EdgeInsetsDirectional.only(start: 6, end: 12),
    };

/// How long ago stats were collected, for the Seen column, in a few letters
/// of the page's language ([timeSinceShort]), or never.
String _checkedShort(DateTime? collectedAt, AppLocalizations l10n) {
  if (collectedAt == null) return l10n.zestMonitorCheckedNever;
  return timeSinceShort(l10n, collectedAt);
}

/// How long ago stats were collected, as words inside the tooltip's sentence
/// ("Checked {checked}."), or null when never.
String? _agoPhrase(DateTime? t, AppLocalizations l10n) => t == null ? null : monitorCheckedPhrase(l10n, t);

/// The line under the table: the warning limits every host is held to unless
/// it has its own, the numbers in the
/// person's language. (The status bar said it as well, and no
/// longer does.)
String monitorWarnAtLine(AppLocalizations l10n, MonitorThresholds global) {
  final number = NumberFormat.decimalPattern(l10n.localeName);
  String warn(MonitorMetric m) => number.format(global.forMetric(m).warn);
  return l10n.monitorTableWarnAt(warn(MonitorMetric.cpu), warn(MonitorMetric.ram), warn(MonitorMetric.disk));
}

/// The name of a host's system as a short word for the partial-read note:
/// the words of its os-release name before the version ("FreeBSD" of
/// "FreeBSD 14.1-RELEASE"), or null where none was read.
String? _osWord(String? osName) {
  if (osName == null) return null;
  final words = <String>[];
  for (final w in osName.trim().split(RegExp(r'\s+'))) {
    if (w.isEmpty || RegExp(r'^[0-9(]').hasMatch(w)) break;
    words.add(w);
  }
  return words.isEmpty ? null : words.join(' ');
}

/// Where the collector could read only part of a host's system (it reads
/// Linux and macOS; on FreeBSD and the like the processor and memory
/// commands find nothing, while the disk and the round trip still come
/// back): what it can read, said as "FreeBSD: disk and ping only". Null
/// where processor or memory were read, or nothing was.
@visibleForTesting
String? monitorPartialReadNote(ServerStats s, AppLocalizations l10n, {double? pingMs}) {
  if (s.cpuPercent != null || s.ramPercent != null) return null;
  final read = [
    if (s.diskPercent != null) l10n.monitorTableWordDisk,
    if (s.load1 != null) l10n.monitorTableWordLoad,
    if ((pingMs ?? s.pingMs) != null) l10n.monitorTableWordPing,
  ];
  if (read.isEmpty) return null;
  final list = read.length == 1
      ? read.single
      : l10n.monitorTableListAnd(read.sublist(0, read.length - 1).join(l10n.monitorTableListSep), read.last);
  final os = _osWord(s.osName);
  if (os != null) return l10n.monitorTablePartial(os, list);
  // Said on its own, it starts with a capital where the language has them.
  final note = l10n.monitorTablePartialNoOs(list);
  return note.isEmpty ? note : note[0].toUpperCase() + note.substring(1);
}

/// Desktop Server Monitor surface (§1): a header
/// with the problem filters and the background switch, a dense table (host,
/// status with its reason and fix, the gauges with their warning tick, load,
/// ping, uptime, updates, the last 24 checks, when it was seen, and a
/// terminal and a menu per row), and the warning limits in use underneath.
/// Shares the four-bucket resolver ([resolveMonitorHost]) with the phone's
/// card screen so the two surfaces never disagree.
class MonitorTableView extends ConsumerStatefulWidget {
  const MonitorTableView({super.key});

  @override
  ConsumerState<MonitorTableView> createState() => _MonitorTableViewState();
}

class _MonitorTableViewState extends ConsumerState<MonitorTableView> {
  late final ServerStatsNotifier _statsNotifier;
  final ScrollController _hController = ScrollController();

  bool _isRefreshing = false;
  bool _didInitialRefresh = false;

  /// The active sort column's identity - a [_FixedCol] (host / status) or a
  /// metric [MonitorColumn]. Defaults to Status (problems first).
  Object _sortKey = _FixedCol.status;
  bool _ascending = true;

  /// Active filter segment, or null when showing everything.
  MonitorBucket? _bucketFilter;

  /// The other filters: the hosts that ask for a restart, or have updates
  /// waiting. One filter at a time.
  _FactFilter? _factFilter;

  /// [_hostContentWidth] as last measured, and of what.
  (String, double)? _hostMeasured;

  /// The host whose detail pane is open on the right, or null when closed.
  /// Selecting a table row opens the pane; the pane's X (or the host vanishing)
  /// clears it. Persistent, no slide animation - master/detail like every other
  /// screen (host detail pane spec §1).
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _statsNotifier = ref.read(serverStatsProvider.notifier);
  }

  /// Refresh a single host, as its person asked: one stats collect, and a
  /// check of whether it can be reached where those checks are on (Settings;
  /// off, nothing connects to it for this).
  Future<void> _refreshHost(String connectionId) async {
    final conns =
        ref.read(connectionsWithDetailsProvider).valueOrNull ?? const [];
    final match =
        conns.where((c) => c.connection.id == connectionId).toList();
    if (match.isNotEmpty) {
      await ref
          .read(connectionHealthProvider.notifier)
          .checkAll([match.first.connection], asked: true);
    }
    // Asked for: Server Monitor tries it again now, where it had stopped.
    ref.read(agentlessMonitorPollerProvider.notifier).retry(connectionId);
    await _statsNotifier.refreshOne(connectionId);
  }

  /// Open (or reuse) a terminal on the host and run `systemctl --failed` - the
  /// detail pane's "View" action for a failed-units row (spec §2.4).
  ///
  /// A Telnet host is asked about first, as every way of opening one asks
  /// (it opened with no question).
  Future<void> _viewFailedUnits(String connectionId) async {
    final conns =
        ref.read(connectionsWithDetailsProvider).valueOrNull ?? const [];
    final match =
        conns.where((c) => c.connection.id == connectionId).toList();
    if (match.isEmpty) return;
    if (match.first.connection.protocol == 'telnet' && (!await confirmUnencryptedConnection(context) || !mounted)) {
      return;
    }
    final sessionId =
        ref.read(activeSessionsProvider.notifier).startSession(match.first.connection);
    if (sessionId == null) return;
    unawaited(_sendCommandWhenReady(
        sessionId, CommandText.entered('systemctl --failed')));
  }

  /// Write [command] to a session once it is connected (bounded ~10s poll), so
  /// the command runs as soon as the freshly-opened terminal is ready.
  Future<void> _sendCommandWhenReady(String sessionId, String command) async {
    final bytes = Uint8List.fromList(utf8.encode(command));
    for (var i = 0; i < 40; i++) {
      if (!mounted) return;
      final s = ref.read(activeSessionsProvider)[sessionId];
      if (s == null) return;
      if (s.status == SessionStatus.connected && s.session?.shell != null) {
        // Typed by the app as the session starts: not something its person
        // sent into a session that was running.
        ref.read(activeSessionsProvider.notifier).sendInput(sessionId, bytes, atStart: true);
        return;
      }
      if (s.status == SessionStatus.error) return;
      await Future.delayed(const Duration(milliseconds: 250));
    }
  }

  /// A session to [conn], in a tab of its own (or the one it has), with the
  /// sessions in front: the row's terminal button. The free plan's session
  /// limit is said where it keeps it from opening.
  void _openSession(Connection conn) {
    unawaited(openSelectedHostsFlow(context, ref, [conn], OpenSelectedAs.tabs));
  }

  /// Adds [conn] to the hosts checked in the background, the way the list of
  /// hosts to watch does ([ConnectionsDao.setMonitored]); where the free plan
  /// watches as many as it can, the plans open instead.
  void _watch(Connection conn) {
    if (!ref.read(canAddMonitoredHostProvider)) {
      PricingModal.show(context);
      return;
    }
    unawaited(ref.read(connectionsDaoProvider).setMonitored(conn.id, true));
  }

  void _editHost(String connectionId) => context.push('${Routes.connectionEdit}/$connectionId');

  @override
  void dispose() {
    _hController.dispose();
    super.dispose();
  }

  /// Stats from every host there is a way to read them from, and, where the
  /// checks of whether hosts can be reached are on (Settings), those: every
  /// host now when its person [asked] (the refresh button), and only the
  /// hosts that are due when the page merely opens.
  Future<void> _refreshEverything({bool asked = false}) async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    try {
      final connections =
          ref.read(connectionsWithDetailsProvider).valueOrNull ?? const [];
      final conns = connections
          .map((c) => c.connection)
          .where((c) => c.protocol != 'localShell')
          .toList();
      if (conns.isNotEmpty) {
        await ref.read(connectionHealthProvider.notifier).checkAll(conns, asked: asked);
      }
      // Asked for: Server Monitor tries again now the hosts it had stopped
      // trying, or that wait for their next try.
      if (asked) ref.read(agentlessMonitorPollerProvider.notifier).retry();
      await _statsNotifier.refreshAll();
    } catch (_) {
      // Best-effort - per-host collection failures surface in the row.
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  void _onSort(_Column col) {
    if (!col.sortable) return;
    setState(() {
      if (_sortKey == col.identity) {
        _ascending = !_ascending;
      } else {
        _sortKey = col.identity;
        // Host / Status ascend by default (A-Z, problems first); metric
        // columns show the highest / most-interesting value first.
        _ascending =
            col.fixed == _FixedCol.host || col.fixed == _FixedCol.status;
      }
    });
  }

  List<ConnectionWithDetails> _sortAndFilter(
    List<ConnectionWithDetails> connections,
    Map<String, MonitorHostView> viewMap,
    Map<String, ServerStats> statsMap,
  ) {
    var list = connections.toList();

    final bucket = _bucketFilter;
    if (bucket != null) {
      list = list
          .where((c) => viewMap[c.connection.id]?.bucket == bucket)
          .toList();
    }
    final fact = _factFilter;
    if (fact != null) {
      list = [
        for (final c in list)
          if (_factOf(fact, statsMap[c.connection.id], viewMap[c.connection.id])) c,
      ];
    }

    String nameOf(ConnectionWithDetails c) => (c.connection.label.isNotEmpty
            ? c.connection.label
            : c.connection.host)
        .toLowerCase();

    int rankOf(String id) {
      final v = viewMap[id];
      if (v == null) return monitorProblemRank(MonitorBucket.cantCheck);
      return monitorProblemRank(v.bucket, needsReboot: monitorNeedsReboot(statsMap[id], v));
    }

    int cmp(ConnectionWithDetails a, ConnectionWithDetails b) {
      final aId = a.connection.id;
      final bId = b.connection.id;
      final key = _sortKey;
      if (key == _FixedCol.host) {
        return nameOf(a).compareTo(nameOf(b));
      }
      if (key == _FixedCol.status) {
        final c = rankOf(aId).compareTo(rankOf(bId));
        return c != 0 ? c : nameOf(a).compareTo(nameOf(b));
      }
      if (key is MonitorColumn) {
        return _metricSortValue(key, statsMap[aId])
            .compareTo(_metricSortValue(key, statsMap[bId]));
      }
      return 0;
    }

    list.sort((a, b) {
      final r = cmp(a, b);
      return _ascending ? r : -r;
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    final activeNav = ref.watch(activeSidebarNavProvider);
    if (activeNav == NavSection.monitor && !_didInitialRefresh) {
      _didInitialRefresh = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refreshEverything();
      });
    }

    final connectionsAsync = ref.watch(connectionsWithDetailsProvider);
    final agentlessEnabled = ref.watch(agentlessMonitorEnabledProvider);
    final statsMap = ref.watch(serverStatsProvider);
    final sessions = ref.watch(activeSessionsProvider);
    final config = ref.watch(monitorThresholdsProvider);
    final columns = _resolveColumns(ref.watch(monitorColumnsProvider));
    final monitorStatuses = ref.watch(agentlessMonitorPollerProvider);
    final canWatchMore = ref.watch(canAddMonitoredHostProvider);

    // How many hosts the background checks look at: the watched SSH hosts,
    // as many as the plan checks.
    final watchedSsh = (ref.watch(monitoredConnectionsProvider).valueOrNull ?? const <Connection>[])
        .where((c) => c.protocol == 'ssh')
        .length;
    final checking = ref.watch(isProProvider) ? watchedSsh : math.min(watchedSsh, freeMonitorLimit);

    // Resolve every host into exactly ONE of the four buckets, so the
    // filter totals sum to the host count (§1.5).
    final sshOnly = (connectionsAsync.valueOrNull ?? const <ConnectionWithDetails>[])
        .where((c) => c.connection.protocol != 'localShell')
        .toList();
    final viewMap = ref.watch(monitorHostViewsProvider);
    final counts = <MonitorBucket, int>{};
    for (final view in viewMap.values) {
      counts[view.bucket] = (counts[view.bucket] ?? 0) + 1;
    }
    final facts = ref.watch(monitorHostFactsProvider);

    final showTable = agentlessEnabled && sshOnly.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _MonitorHeader(
          filters: showTable
              ? _FilterSegments(
                  total: sshOnly.length,
                  counts: counts,
                  active: _bucketFilter,
                  onSelect: (b) => setState(() {
                    _bucketFilter = b;
                    _factFilter = null;
                  }),
                  rebootCount: facts.rebootNeeded.length,
                  updatesCount: facts.updatesPending.length,
                  activeFact: _factFilter,
                  onSelectFact: (f) => setState(() {
                    _factFilter = f;
                    _bucketFilter = null;
                  }),
                )
              : null,
          backgroundOn: agentlessEnabled,
          checking: checking,
          onToggle: (v) => ref.read(agentlessMonitorEnabledProvider.notifier).setEnabled(v),
          onThresholds: () => showMonitorThresholds(context),
          refreshing: _isRefreshing,
          onRefresh: () => _refreshEverything(asked: true),
          onPageMenu: _openPageMenu,
        ),
        Divider(height: 1, color: ZestTokens.borderSubtle),
        Expanded(
          child: !agentlessEnabled
              ? _AgentlessOffState(
                  onEnable: () => ref
                      .read(agentlessMonitorEnabledProvider.notifier)
                      .setEnabled(true),
                  onManage: () => showMonitorManageServers(context),
                )
              : connectionsAsync.when(
                  // A reload (another space) keeps what is shown until its rows come: a spinner here was a flash.
                  skipLoadingOnReload: true,
                  loading: () => Center(
                    child: CircularProgressIndicator(
                      color: AppColors.v3AccentPrimary,
                    ),
                  ),
                  error: (e, stack) => LoadErrorState(
                    message: l10n.homeUnableToLoadConnections,
                    where: 'Loading the hosts of the server monitor',
                    error: e,
                    stack: stack,
                    onRetry: () => ref.invalidate(connectionsWithDetailsProvider),
                  ),
                  data: (_) {
                    if (sshOnly.isEmpty) {
                      return ZestEmptyState(
                        icon: LucideIcons.activity,
                        title: l10n.monitorNoConnections,
                        message: l10n.monitorAddConnection,
                      );
                    }

                    final rows = _sortAndFilter(sshOnly, viewMap, statsMap);
                    // What Broadcast to these hands on: not a host that is SFTP
                    // only, which it cannot tick. Run snippet on these, what Run
                    // on hosts can run on, and each counts its own: the others
                    // were counted, and failed with SSH only.
                    final canBroadcastTo = {
                      for (final c in rows)
                        if (noTerminalReason(c.connection, l10n) == null) c.connection.id,
                    };
                    final canRunOn = {
                      for (final c in rows)
                        if (noRunOnHostsReason(c.connection, l10n) == null) c.connection.id,
                    };

                    // Resolve the selected host (if any). Selection persists
                    // even when a filter hides its row; it only clears when
                    // the host is deleted (falls out of sshOnly/viewMap).
                    final selId = _selectedId;
                    ConnectionWithDetails? selDetails;
                    if (selId != null) {
                      for (final c in sshOnly) {
                        if (c.connection.id == selId) {
                          selDetails = c;
                          break;
                        }
                      }
                      if (selDetails == null) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted && _selectedId == selId) {
                            setState(() => _selectedId = null);
                          }
                        });
                      }
                    }

                    final content = Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: rows.isEmpty
                              ? ZestEmptyState(
                                  icon: LucideIcons.filterX,
                                  title: l10n.monitorNoMatch,
                                  actionLabel: l10n.monitorShowAll,
                                  actionIcon: LucideIcons.filterX,
                                  onAction: () => setState(() {
                                    _bucketFilter = null;
                                    _factFilter = null;
                                  }),
                                )
                              : _buildTable(l10n, columns, rows, sshOnly, viewMap,
                                  statsMap, sessions, selId, canWatchMore, monitorStatuses),
                        ),
                        // The rows a filter leaves, to act
                        // on at once.
                        if (canBroadcastTo.isNotEmpty && (_bucketFilter != null || _factFilter != null))
                          _FilteredActions(
                            runOn: canRunOn.length,
                            broadcastTo: canBroadcastTo.length,
                            onBroadcast: () => unawaited(broadcastToHostsFlow(context, ref, preselected: canBroadcastTo)),
                            onRun: () => unawaited(showRunOnHosts(context, preselected: canRunOn)),
                          ),
                        // The warning limits in use, under the table.
                        _WarnAtFooter(text: monitorWarnAtLine(l10n, config.global)),
                      ],
                    );

                    final sel = selDetails;
                    if (sel == null) return content;
                    // Table and detail pane are separate traversal units so
                    // Tab inside the pane never lands on a table row that
                    // shares its horizontal band.
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: FocusTraversalGroup(child: content)),
                        SizedBox(
                          width: kMonitorDetailPaneWidth,
                          child: FocusScope(
                            debugLabel: 'MonitorDetailPane',
                            child: MonitorDetailPane(
                              key: ValueKey(sel.connection.id),
                              details: sel,
                              view: viewMap[sel.connection.id]!,
                              stats: statsMap[sel.connection.id],
                              onClose: () =>
                                  setState(() => _selectedId = null),
                              onRefresh: () => _refreshHost(sel.connection.id),
                              onViewFailedUnits: () =>
                                  _viewFailedUnits(sel.connection.id),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// The page's own menu (the header's three dots): the hosts to watch, the
  /// data source, the setup guide, and how often the open sessions' stats
  /// refresh by themselves.
  Future<void> _openPageMenu(RelativeRect position) async {
    final l10n = AppLocalizations.of(context)!;
    final auto = _statsNotifier.isAutoRefreshing;
    final picked = await showMenu<String>(
      context: context,
      position: position,
      color: ZestTokens.surfaceRaised,
      items: [
        PopupMenuItem(value: 'choose', child: _MenuRow(icon: LucideIcons.listChecks, label: l10n.monitorTableChooseHosts)),
        PopupMenuItem(value: 'source', child: _MenuRow(icon: LucideIcons.server, label: l10n.monitorDataSource)),
        PopupMenuItem(value: 'guide', child: _MenuRow(icon: LucideIcons.bookOpen, label: l10n.setupGuideTitle)),
        const PopupMenuDivider(),
        PopupMenuItem(
          enabled: false,
          height: 28,
          child: Text(l10n.monitorTableAutoRefresh,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ZestTokens.textTertiary)),
        ),
        PopupMenuItem(value: 'auto:0', child: _IntervalRow(label: l10n.monitorAutoRefreshOff, selected: !auto)),
        for (final secs in [10, 15, 30, 60, 120])
          PopupMenuItem(
            value: 'auto:$secs',
            child: _IntervalRow(
              label: l10n.monitorAutoRefreshEvery(secs),
              selected: auto && _statsNotifier.refreshIntervalSeconds == secs,
            ),
          ),
      ],
    );
    if (!mounted || picked == null) return;
    switch (picked) {
      case 'choose':
        unawaited(showMonitorManageServers(context));
      case 'source':
        showMonitorDataSourceSheet(context);
      case 'guide':
        showSetupGuide(context, SetupTopic.serverMonitor);
      default:
        final secs = int.tryParse(picked.substring('auto:'.length)) ?? 0;
        if (secs == 0) {
          _statsNotifier.stopAutoRefresh();
        } else {
          _statsNotifier.startAutoRefresh(secs);
        }
        setState(() {});
    }
  }

  /// A row's own menu (its three dots).
  Future<void> _openRowMenu(RelativeRect position, ConnectionWithDetails details) async {
    final l10n = AppLocalizations.of(context)!;
    final conn = details.connection;
    final picked = await showMenu<String>(
      context: context,
      position: position,
      color: ZestTokens.surfaceRaised,
      items: [
        PopupMenuItem(value: 'open', child: _MenuRow(icon: LucideIcons.terminal, label: l10n.monitorTableOpenSession)),
        PopupMenuItem(value: 'check', child: _MenuRow(icon: LucideIcons.refreshCw, label: l10n.monitorTableCheckNow)),
        PopupMenuItem(value: 'details', child: _MenuRow(icon: LucideIcons.panelRight, label: l10n.monitorTableDetails)),
        PopupMenuItem(
            value: 'thresholds',
            child: _MenuRow(icon: LucideIcons.slidersHorizontal, label: l10n.monitorTableHostThresholds)),
        PopupMenuItem(value: 'edit', child: _MenuRow(icon: LucideIcons.pencil, label: l10n.monitorTableEditHost)),
        if (conn.protocol == 'ssh') ...[
          const PopupMenuDivider(),
          conn.monitored
              ? PopupMenuItem(value: 'unwatch', child: _MenuRow(icon: LucideIcons.eyeOff, label: l10n.monitorTableStopWatching))
              : PopupMenuItem(value: 'watch', child: _MenuRow(icon: LucideIcons.eye, label: l10n.monitorTableWatch)),
        ],
      ],
    );
    if (!mounted || picked == null) return;
    switch (picked) {
      case 'open':
        _openSession(conn);
      case 'check':
        unawaited(_refreshHost(conn.id));
      case 'details':
        setState(() => _selectedId = conn.id);
      case 'thresholds':
        unawaited(showMonitorThresholds(context, hostId: conn.id));
      case 'edit':
        _editHost(conn.id);
      case 'watch':
        _watch(conn);
      case 'unwatch':
        unawaited(ref.read(connectionsDaoProvider).setMonitored(conn.id, false));
    }
  }

  Widget _buildTable(
    AppLocalizations l10n,
    List<_Column> columns,
    List<ConnectionWithDetails> rows,
    List<ConnectionWithDetails> allRows,
    Map<String, MonitorHostView> viewMap,
    Map<String, ServerStats> statsMap,
    Map<String, SessionState> sessions,
    String? selectedId,
    bool canWatchMore,
    Map<String, MonitorHostStatus> monitorStatuses,
  ) {
    final set = ref.watch(monitorColumnWidthsProvider);
    return LayoutBuilder(builder: (context, box) {
    final widths = monitorColumnWidths(
      columns: _widthInputs(columns),
      set: set,
      hostContent: _hostContentWidth(context, allRows),
      available: box.maxWidth.isFinite ? box.maxWidth - _kLeadGutter - _kRowHPad * 2 : 0,
    );
    final width = widths.values.fold(0.0, (sum, w) => sum + w) + _kLeadGutter + _kRowHPad * 2;
    return Scrollbar(
      controller: _hController,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _hController,
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _HeaderRow(
                widths: widths,
                columns: columns,
                sortKey: _sortKey,
                ascending: _ascending,
                onSort: _onSort,
                onResize: (c, width) => ref.read(monitorColumnWidthsProvider.notifier).set(c.key, width),
                onResizeEnd: () => ref.read(monitorColumnWidthsProvider.notifier).persist(),
                onFit: (c) => ref
                    .read(monitorColumnWidthsProvider.notifier)
                    .setAndPersist(c.key, _fitWidth(context, l10n, c, allRows, viewMap, statsMap)),
              ),
              Divider(height: 1, color: ZestTokens.borderSubtle),
              Expanded(
                child: ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, color: ZestTokens.borderSubtle),
                  itemBuilder: (context, index) {
                    final c = rows[index];
                    final conn = c.connection;
                    final hasActiveSession = sessions.values.any(
                      (s) =>
                          s.connectionId == conn.id &&
                          s.status == SessionStatus.connected,
                    );
                    return _MonitorRow(
                      key: ValueKey(conn.id),
                      widths: widths,
                      columns: columns,
                      details: c,
                      view: viewMap[conn.id]!,
                      stats: statsMap[conn.id],
                      monitorStatus: monitorStatuses[conn.id],
                      hasActiveSession: hasActiveSession,
                      canWatchMore: canWatchMore,
                      selected: selectedId == conn.id,
                      onTap: () => setState(() => _selectedId = conn.id),
                      onWatch: () => _watch(conn),
                      onEditHost: () => _editHost(conn.id),
                      onCheckNow: () => _refreshHost(conn.id),
                      onOpenSession: () => _openSession(conn),
                      onMenu: (position) => _openRowMenu(position, c),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    });
  }

  /// How wide the Host column's content is: the widest of the hosts' names and
  /// addresses, beside the icon and the dot of an open session, whichever
  /// rows a filter shows (a column that changed with the filter would jump).
  double _hostContentWidth(BuildContext context, List<ConnectionWithDetails> hosts) {
    // Measured again only where the words change: this table rebuilds with
    // every reading.
    final words = [
      for (final c in hosts) ...[
        (c.connection.label.isNotEmpty ? Redactable.host(c.connection.label) : Redactable.address(c.connection.host)).displayIn(ref),
        _hostEndpointShown(c),
      ],
    ];
    final said = words.join('\n');
    final known = _hostMeasured;
    if (known != null && known.$1 == said) return known.$2;
    var widest = 0.0;
    for (var i = 0; i < words.length; i++) {
      widest = math.max(widest, _textWidth(context, words[i], i.isEven ? _kHostNameStyle : _kHostAddressStyle));
    }
    final padding = _cellPadding(const _Column.fixed(_FixedCol.host)).horizontal;
    // The icon and its gap, the dot and its gap, the mark of a failed read.
    final width = (widest + _kHostIconSize + 10 + 14 + 20 + padding).ceilToDouble();
    final clamped = width.clamp(const _Column.fixed(_FixedCol.host).minWidth, 340.0);
    _hostMeasured = (said, clamped);
    return clamped;
  }

  /// user@address as a host's row shows it (masked while recording).
  String _hostEndpointShown(ConnectionWithDetails c) {
    final conn = c.connection;
    final address = Redactable.address(conn.host).displayIn(ref);
    final at = conn.port == 22 ? address : hostWithPort(address, conn.port);
    final user = c.identity?.username;
    return user == null || user.isEmpty ? at : '${Redactable.username(user).displayIn(ref)}@$at';
  }

  /// A double-click on a column's edge: as wide as what it holds now.
  double _fitWidth(
    BuildContext context,
    AppLocalizations l10n,
    _Column c,
    List<ConnectionWithDetails> hosts,
    Map<String, MonitorHostView> viewMap,
    Map<String, ServerStats> statsMap,
  ) {
    final padding = _cellPadding(c).horizontal;
    // The head's words, and its sort arrow.
    var fit = _textWidth(context, c.label(l10n).toUpperCase(), _kHeaderStyle) + 12 + 15;
    switch (c.fixed) {
      case _FixedCol.host:
        return _hostContentWidth(context, hosts);
      case _FixedCol.status:
        // The widest a status comes to here: its reasons and chips are drawn
        // by the cell, and these are their sizes (see [_fixedColWidth]).
        final anyReboot = hosts.any((h) {
          final v = viewMap[h.connection.id];
          return v != null && monitorNeedsReboot(statsMap[h.connection.id], v);
        });
        final anyNoCheck = hosts.any((h) => viewMap[h.connection.id]?.bucket == MonitorBucket.cantCheck);
        final anyOver = hosts.any((h) {
          final b = viewMap[h.connection.id]?.bucket;
          return b == MonitorBucket.warning || b == MonitorBucket.critical;
        });
        final content = anyReboot ? _fixedColWidth(_FixedCol.status) : (anyNoCheck ? 176.0 : (anyOver ? 136.0 : 100.0));
        return math.max(fit, content);
      case _FixedCol.last24:
        return _fixedColWidth(_FixedCol.last24);
      case _FixedCol.seen:
        for (final h in hosts) {
          final seen = _checkedShort(viewMap[h.connection.id]?.statsCollectedAt, l10n);
          fit = math.max(fit, _textWidth(context, seen, _kMetricStyle) + padding);
        }
        return fit;
      case _FixedCol.actions:
        return _fixedColWidth(_FixedCol.actions);
      case null:
        break;
    }
    final column = c.metric!;
    if (column.isPercentGauge) {
      // Its figure over its bar: wide enough for 100% and a bar to read.
      return math.max(fit, 64);
    }
    for (final h in hosts) {
      final view = viewMap[h.connection.id];
      if (view == null) continue;
      final (text, _) = _metricCellContent(column, statsMap[h.connection.id], view);
      if (text != null) fit = math.max(fit, _textWidth(context, text, _kMetricStyle) + padding);
    }
    return fit;
  }
}

/// What the Host column's words are drawn in, to size it to them.
const _kHostNameStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w600);
const _kHostAddressStyle = TextStyle(fontSize: 11.5, fontFamily: 'JetBrainsMono');
const double _kHostIconSize = 22;
const _kMetricStyle = TextStyle(fontSize: 12, fontFamily: 'JetBrainsMono');
const _kHeaderStyle = TextStyle(fontSize: 10.5, fontFamily: 'JetBrainsMono', fontWeight: FontWeight.w700, letterSpacing: 0.8);

/// The filters beside the problem segments, of what a host's latest reading
/// says.
enum _FactFilter { reboot, updates }

bool _factOf(_FactFilter fact, ServerStats? stats, MonitorHostView? view) {
  if (view == null) return false;
  return switch (fact) {
    _FactFilter.reboot => monitorNeedsReboot(stats, view),
    _FactFilter.updates => monitorHasUpdates(stats, view),
  };
}

/// Under the table while a filter is on: what can be done to the rows it left
/// at once. It opens Broadcast to hosts or Run on hosts with them ticked, to
/// look at before anything happens (nothing here restarts or updates a host).
class _FilteredActions extends StatelessWidget {
  /// How many of them Run on hosts can run on: SSH hosts alone.
  final int runOn;

  /// How many of them a broadcast can reach, the most there are of either.
  final int broadcastTo;
  final VoidCallback onBroadcast;
  final VoidCallback onRun;

  const _FilteredActions({required this.runOn, required this.broadcastTo, required this.onBroadcast, required this.onRun});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      key: const ValueKey('monitor-filtered-actions'),
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaised,
        border: Border(top: BorderSide(color: ZestTokens.borderSubtle)),
      ),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 6,
        children: [
          if (runOn > 0)
            ZestButton(
              key: const ValueKey('monitor-run-these'),
              label: l10n.monitorRunOnThese(runOn),
              icon: LucideIcons.listChecks,
              variant: ZestButtonVariant.secondary,
              onPressed: onRun,
            ),
          ZestButton(
            key: const ValueKey('monitor-broadcast-these'),
            label: l10n.monitorBroadcastToThese(broadcastTo),
            icon: LucideIcons.radio,
            variant: ZestButtonVariant.secondary,
            onPressed: onBroadcast,
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// Page header: title, filters, background switch, tools
// ══════════════════════════════════════════════════════════════════════

class _MonitorHeader extends StatelessWidget {
  /// The filter segments, where there is a table to filter.
  final Widget? filters;
  final bool backgroundOn;

  /// How many hosts the background checks look at.
  final int checking;
  final ValueChanged<bool> onToggle;
  final VoidCallback onThresholds;
  final bool refreshing;
  final VoidCallback onRefresh;
  final void Function(RelativeRect position) onPageMenu;

  const _MonitorHeader({
    required this.filters,
    required this.backgroundOn,
    required this.checking,
    required this.onToggle,
    required this.onThresholds,
    required this.refreshing,
    required this.onRefresh,
    required this.onPageMenu,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final background = backgroundOn ? l10n.monitorTableBackgroundOn(checking) : l10n.monitorTableBackgroundOff;
    // Where the page is narrow (the window's least width, 800, leaves it
    // 600), Thresholds is a tool button of its icon alone, its name in its
    // tooltip, as Columns is: with the title's guide button its name ran
    // the row over by a few pixels in Spanish and Russian.
    return LayoutBuilder(builder: (context, box) {
    final compact = box.maxWidth < _kMonitorHeaderCompactBelow;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 16, 12),
      child: Row(
        children: [
          GuideTitle(
            feature: 'monitor',
            title: Text(
              l10n.monitorTitle,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
                color: ZestTokens.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 16),
          // The segments take what they need, up to two thirds of the room
          // between the title and the tools (they scroll past that); the
          // background line takes the rest.
          Flexible(
            flex: 2,
            child: filters == null
                ? const SizedBox.shrink()
                : Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: filters),
                  ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              background,
              key: const ValueKey('monitor-background-line'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: TextStyle(fontSize: 13, color: ZestTokens.textSecondary),
            ),
          ),
          const SizedBox(width: 10),
          Semantics(
            label: l10n.monitorTableBackgroundSwitch,
            child: ZestSwitch(
              key: const ValueKey('monitor-background-switch'),
              value: backgroundOn,
              onChanged: onToggle,
            ),
          ),
          const SizedBox(width: 12),
          if (compact)
            _ToolIconButton(
              key: const ValueKey('monitor-thresholds'),
              tooltip: l10n.zestMonitorThresholdsButton,
              onPressed: onThresholds,
              child: const Icon(LucideIcons.slidersHorizontal, size: 16),
            )
          else
            OutlinedButton.icon(
              key: const ValueKey('monitor-thresholds'),
              onPressed: onThresholds,
              icon: const Icon(LucideIcons.slidersHorizontal, size: 16),
              label: Text(l10n.zestMonitorThresholdsButton),
            ),
          const SizedBox(width: 8),
          // Columns chooser (§2): reorder + toggle the metric columns, persisted.
          const _ColumnsButton(),
          const SizedBox(width: 8),
          _ToolIconButton(
            key: const ValueKey('monitor-refresh'),
            tooltip: l10n.monitorRefreshAll,
            onPressed: refreshing ? null : onRefresh,
            child: refreshing
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: ZestTokens.textSecondary),
                  )
                : const Icon(LucideIcons.refreshCw, size: 16),
          ),
          const SizedBox(width: 8),
          Builder(
            builder: (buttonContext) => _ToolIconButton(
              key: const ValueKey('monitor-page-menu'),
              tooltip: l10n.monitorTablePageMenu,
              onPressed: () => onPageMenu(menuPositionAt(buttonContext, offset: const Offset(0, 38))),
              child: const Icon(LucideIcons.moreHorizontal, size: 16),
            ),
          ),
        ],
      ),
    );
    });
  }
}

/// The Server monitor header's width under which Thresholds shows its icon
/// alone.
const double _kMonitorHeaderCompactBelow = 720;

/// A square, outlined tool button with only an icon: the header's columns,
/// refresh and menu buttons (the theme's outlined look, 34 high as its
/// labelled neighbour); Thresholds too where the page is narrow.
class _ToolIconButton extends StatelessWidget {
  final String tooltip;
  final VoidCallback? onPressed;
  final Widget child;

  const _ToolIconButton({super.key, required this.tooltip, required this.onPressed, required this.child});

  @override
  Widget build(BuildContext context) {
    // Named by its tooltip inside the button: a tooltip around a button
    // names no node of it, and a screen reader found three unnamed buttons
    // (4.0 accessibility pass).
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      waitDuration: const Duration(milliseconds: 400),
      child: ButtonBox(
        width: 34,
        height: 34,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: const Size(34, 34),
            foregroundColor: ZestTokens.textSecondary,
          ),
          child: Semantics(label: tooltip, child: child),
        ),
      ),
    );
  }
}

/// An icon and its words, for a menu item.
class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MenuRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: ZestTokens.textSecondary),
        const SizedBox(width: 10),
        Flexible(child: Text(label, style: TextStyle(fontSize: 13, color: ZestTokens.textPrimary))),
      ],
    );
  }
}

class _IntervalRow extends StatelessWidget {
  final String label;
  final bool selected;

  const _IntervalRow({required this.label, required this.selected});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          selected ? LucideIcons.circleDot : LucideIcons.circle,
          size: 16,
          color: selected ? ZestTokens.brandInk : ZestTokens.textSecondary,
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: selected ? ZestTokens.brandInk : ZestTokens.textPrimary,
          ),
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// Filter segments: All / Critical / Warning / Can't check
// ══════════════════════════════════════════════════════════════════════

class _FilterSegments extends StatelessWidget {
  final int total;
  final Map<MonitorBucket, int> counts;
  final MonitorBucket? active;
  final ValueChanged<MonitorBucket?> onSelect;
  final int rebootCount;
  final int updatesCount;
  final _FactFilter? activeFact;
  final ValueChanged<_FactFilter?> onSelectFact;

  const _FilterSegments({
    required this.total,
    required this.counts,
    required this.active,
    required this.onSelect,
    required this.rebootCount,
    required this.updatesCount,
    required this.activeFact,
    required this.onSelectFact,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Problems only: a segment shows while it has hosts (or is the one
    // chosen), so a calm fleet reads "All 21" and nothing else.
    bool shows(MonitorBucket b) => (counts[b] ?? 0) > 0 || active == b;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceChip,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Segment(
            key: const ValueKey('monitor-filter-all'),
            label: l10n.monitorTableFilterAll,
            count: total,
            selected: active == null && activeFact == null,
            onTap: () => onSelect(null),
          ),
          if (shows(MonitorBucket.critical))
            _Segment(
              key: const ValueKey('monitor-filter-critical'),
              label: MonitorBucket.critical.label(l10n),
              count: counts[MonitorBucket.critical] ?? 0,
              icon: LucideIcons.alertCircle,
              tone: ZestTokens.statusCritical,
              selected: active == MonitorBucket.critical,
              onTap: () => onSelect(MonitorBucket.critical),
            ),
          if (shows(MonitorBucket.warning))
            _Segment(
              key: const ValueKey('monitor-filter-warning'),
              label: MonitorBucket.warning.label(l10n),
              count: counts[MonitorBucket.warning] ?? 0,
              icon: LucideIcons.alertTriangle,
              tone: ZestTokens.statusWarning,
              selected: active == MonitorBucket.warning,
              onTap: () => onSelect(MonitorBucket.warning),
            ),
          if (shows(MonitorBucket.cantCheck))
            _Segment(
              key: const ValueKey('monitor-filter-cantCheck'),
              label: MonitorBucket.cantCheck.label(l10n),
              count: counts[MonitorBucket.cantCheck] ?? 0,
              selected: active == MonitorBucket.cantCheck,
              onTap: () => onSelect(MonitorBucket.cantCheck),
            ),
          // What can be done something about at once,
          // shown as the problems are: while there are any.
          if (rebootCount > 0 || activeFact == _FactFilter.reboot)
            _Segment(
              key: const ValueKey('monitor-filter-reboot'),
              label: l10n.hostRebootNeeded,
              count: rebootCount,
              icon: LucideIcons.rotateCcw,
              selected: activeFact == _FactFilter.reboot,
              onTap: () => onSelectFact(_FactFilter.reboot),
            ),
          if (updatesCount > 0 || activeFact == _FactFilter.updates)
            _Segment(
              key: const ValueKey('monitor-filter-updates'),
              label: l10n.monitorColUpdates,
              count: updatesCount,
              icon: LucideIcons.packageCheck,
              selected: activeFact == _FactFilter.updates,
              onTap: () => onSelectFact(_FactFilter.updates),
            ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  final String label;
  final int count;
  final IconData? icon;

  /// The status colour of a problem segment's words; null for neutral ones.
  final Color? tone;
  final bool selected;
  final VoidCallback onTap;

  const _Segment({
    super.key,
    required this.label,
    required this.count,
    this.icon,
    this.tone,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = tone ?? (selected ? ZestTokens.textPrimary : ZestTokens.textSecondary);
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? ZestTokens.surfaceRaised : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 13, color: color),
                  const SizedBox(width: 5),
                ],
                Text(
                  label,
                  style: TextStyle(fontSize: 12.5, fontWeight: selected ? FontWeight.w600 : FontWeight.w500, color: color),
                ),
                const SizedBox(width: 5),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The warning limits in use, right under the table: "Warn at CPU 90% · RAM
/// 85% · Disk 85%".
class _WarnAtFooter extends StatelessWidget {
  final String text;

  const _WarnAtFooter({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: AlignmentDirectional.centerEnd,
      decoration: BoxDecoration(border: Border(top: BorderSide(color: ZestTokens.borderSubtle))),
      child: Text(
        text,
        key: const ValueKey('monitor-warn-at'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, fontFamily: 'JetBrainsMono', color: ZestTokens.textTertiary),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// Table header row
// ══════════════════════════════════════════════════════════════════════

class _HeaderRow extends StatelessWidget {
  final List<_Column> columns;
  final Object sortKey;
  final bool ascending;
  final ValueChanged<_Column> onSort;

  /// How wide each column is, by its key ([monitorColumnWidths]).
  final Map<String, double> widths;

  /// A column's edge dragged: its new width. The drag's end, to remember it.
  final void Function(_Column column, double width) onResize;
  final VoidCallback onResizeEnd;

  /// A column's edge double-clicked: as wide as what it holds.
  final ValueChanged<_Column> onFit;

  const _HeaderRow({
    required this.widths,
    required this.columns,
    required this.sortKey,
    required this.ascending,
    required this.onSort,
    required this.onResize,
    required this.onResizeEnd,
    required this.onFit,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _kRowHPad),
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            const SizedBox(width: _kLeadGutter),
            for (final c in columns)
              SizedBox(
                width: widths[c.key] ?? c.width,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: _HeaderCell(
                        leading: c.fixed == _FixedCol.last24 ? 6 : 0,
                        label: c.label(l10n),
                        sortable: c.sortable,
                        active: sortKey == c.identity,
                        ascending: ascending,
                        onTap: () => onSort(c),
                      ),
                    ),
                    if (c.resizable)
                      PositionedDirectional(
                        end: 0,
                        top: 0,
                        bottom: 0,
                        child: _ColumnEdge(
                          key: ValueKey('monitor-col-edge-${c.key}'),
                          width: widths[c.key] ?? c.width,
                          minWidth: c.minWidth,
                          onResize: (w) => onResize(c, w),
                          onResizeEnd: onResizeEnd,
                          onFit: () => onFit(c),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The edge of a column's head: dragged it
/// sets the column's width, double-clicked it fits the column to what it
/// holds. Both are remembered on this device.
class _ColumnEdge extends StatefulWidget {
  final double width;
  final double minWidth;
  final ValueChanged<double> onResize;
  final VoidCallback onResizeEnd;
  final VoidCallback onFit;

  const _ColumnEdge({
    super.key,
    required this.width,
    required this.minWidth,
    required this.onResize,
    required this.onResizeEnd,
    required this.onFit,
  });

  @override
  State<_ColumnEdge> createState() => _ColumnEdgeState();
}

class _ColumnEdgeState extends State<_ColumnEdge> {
  bool _hover = false;
  bool _dragging = false;
  late double _width;

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final lit = _hover || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: widget.onFit,
        onHorizontalDragStart: (_) => setState(() {
          _dragging = true;
          _width = widget.width;
        }),
        onHorizontalDragUpdate: (d) {
          // Kept here, not read back: past the least width, the edge waits
          // for the mouse to come back to it.
          _width += rtl ? -d.delta.dx : d.delta.dx;
          widget.onResize(math.max(_width, widget.minWidth));
        },
        onHorizontalDragEnd: (_) {
          setState(() => _dragging = false);
          widget.onResizeEnd();
        },
        child: SizedBox(
          width: 9,
          child: Center(
            child: Container(
              width: lit ? 2 : 1,
              height: lit ? 22 : 14,
              decoration: BoxDecoration(
                color: lit ? ZestTokens.brand : ZestTokens.borderSubtle,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  /// More room before its words (the column after the numbers).
  final double leading;
  final String label;
  final bool sortable;
  final bool active;
  final bool ascending;
  final VoidCallback onTap;

  const _HeaderCell({
    this.leading = 0,
    required this.label,
    required this.sortable,
    required this.active,
    required this.ascending,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // The buttons' column has no head.
    if (label.isEmpty) return const SizedBox.shrink();
    final color = active ? ZestTokens.textPrimary : ZestTokens.textTertiary;
    final content = Row(
      children: [
        Flexible(
          child: Text(
            label.toUpperCase(),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: TextStyle(
              fontSize: 10.5,
              fontFamily: 'JetBrainsMono',
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              letterSpacing: 0.8,
              color: color,
            ),
          ),
        ),
        if (active) ...[
          const SizedBox(width: 4),
          Icon(
            ascending ? LucideIcons.arrowDown : LucideIcons.arrowUp,
            size: 11,
            color: color,
          ),
        ],
      ],
    );

    // A head cut short in a longer language says itself in full on hover.
    final padded = Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 600),
      excludeFromSemantics: true,
      child: Padding(
        padding: EdgeInsetsDirectional.only(start: 6 + leading, end: 6),
        child: content,
      ),
    );
    if (!sortable) return Align(alignment: AlignmentDirectional.centerStart, child: padded);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Align(alignment: AlignmentDirectional.centerStart, child: padded),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// One host row
// ══════════════════════════════════════════════════════════════════════

class _MonitorRow extends ConsumerStatefulWidget {
  final List<_Column> columns;

  /// How wide each column is, by its key ([monitorColumnWidths]).
  final Map<String, double> widths;
  final ConnectionWithDetails details;
  final MonitorHostView view;
  final ServerStats? stats;

  /// What the background checks say of the host, where they look at it.
  final MonitorHostStatus? monitorStatus;
  final bool hasActiveSession;

  /// The plan watches another host: "Watch this host" adds it, where it
  /// would otherwise open the plans.
  final bool canWatchMore;

  /// This row's host is the one open in the detail pane.
  final bool selected;

  /// Selecting the row opens the detail pane for this host.
  final VoidCallback onTap;
  final VoidCallback onWatch;
  final VoidCallback onEditHost;
  final VoidCallback onCheckNow;
  final VoidCallback onOpenSession;
  final void Function(RelativeRect position) onMenu;

  const _MonitorRow({
    super.key,
    required this.widths,
    required this.columns,
    required this.details,
    required this.view,
    required this.stats,
    required this.monitorStatus,
    required this.hasActiveSession,
    required this.canWatchMore,
    required this.selected,
    required this.onTap,
    required this.onWatch,
    required this.onEditHost,
    required this.onCheckNow,
    required this.onOpenSession,
    required this.onMenu,
  });

  @override
  ConsumerState<_MonitorRow> createState() => _MonitorRowState();
}

class _MonitorRowState extends ConsumerState<_MonitorRow> {
  // Row hover thickens the gauge tracks so their threshold ticks become
  // draggable handles (§3). Handles appear only while hovered.
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final details = widget.details;
    final view = widget.view;
    final conn = details.connection;
    final stats = widget.stats;
    // Recording mode: everything this row paints (the name, host:port, the
    // rejected user in the status tooltip, the host the override toast names)
    // is the display form. The sort upstream still keys on the real name.
    final hostName = conn.label.isNotEmpty
        ? Redactable.host(conn.label).displayIn(ref)
        : Redactable.address(conn.host).displayIn(ref);
    final rejectedUser = details.identity?.username;
    final rejectedUserShown = rejectedUser == null
        ? null
        : Redactable.username(rejectedUser).displayIn(ref);
    final collectError = ref.watch(serverStatsErrorProvider(conn.id));

    // The figures of a reading that can be trusted: a host that cannot be
    // checked, or whose last reading is past its time, shows none of them.
    final live = stats != null && !view.statsStale && view.bucket != MonitorBucket.cantCheck;
    final ping = view.metricEval(MonitorMetric.latency)?.value;
    final partial = live ? monitorPartialReadNote(stats, l10n, pingMs: ping) : null;

    Widget cellFor(_Column c) {
      final fixed = c.fixed;
      if (fixed != null) {
        switch (fixed) {
          case _FixedCol.host:
            return _HostCell(
              details: details,
              hasActiveSession: widget.hasActiveSession,
              collectError: collectError,
            );
          case _FixedCol.status:
            return _StatusCell(
              view: view,
              connection: conn,
              monitorStatus: widget.monitorStatus,
              needsReboot: monitorNeedsReboot(stats, view),
              partialNote: partial,
              canWatchMore: widget.canWatchMore,
              rejectedUser: rejectedUserShown,
              hostName: hostName,
              onWatch: widget.onWatch,
              onEditHost: widget.onEditHost,
              onCheckNow: widget.onCheckNow,
              onOpenSession: widget.onOpenSession,
            );
          case _FixedCol.last24:
            return MonitorChecksBars(connectionId: conn.id);
          case _FixedCol.seen:
            return _SeenCell(collectedAt: view.statsCollectedAt);
          case _FixedCol.actions:
            return _RowActions(
              connectionId: conn.id,
              onOpenSession: widget.onOpenSession,
              onMenu: widget.onMenu,
            );
        }
      }
      if (!live) return const SizedBox.shrink();
      final column = c.metric!;
      if (column.isPercentGauge) {
        final eval = view.metricEval(column.metric!);
        // A host with no swap at all says so (it said SwapTotal 0), where a
        // host whose swap could not be read says nothing.
        if (column == MonitorColumn.swap && eval?.value == null && stats.noSwap) {
          return _QuietValue(l10n.monitorTableSwapNone, key: const ValueKey('monitor-swap-none'));
        }
        return _MetricGaugeCell(
          connectionId: conn.id,
          hostName: hostName,
          metric: column.metric!,
          eval: eval,
          rowHovered: _hovered,
        );
      }
      return _MetricValueCell(column: column, stats: stats, view: view);
    }

    // §2 identity invariant: the 3px left rule encodes IDENTITY (the host's
    // own colour label → its group's colour → nothing), NEVER health. Health
    // stays in the status chip, the gauge colours and the row background.
    final group = details.group;
    final identityColor = AppColors.resolveConnectionLabelColorOrNull(
      connColorValue: conn.colorValue,
      connColorIndex: conn.colorIndex,
      inheritedGroupColor: group != null
          ? resolveGroupColor(
              colorValue: group.colorValue,
              colorIndex: group.colorIndex,
              name: group.name,
            )
          : null,
    );

    // A selected row (its detail pane open) gets a subtle brand tint; a row
    // over a limit a faint wash of its status colour.
    final Color rowBg = widget.selected
        ? ZestTokens.brandSubtle
        : switch (view.bucket) {
            MonitorBucket.critical => ZestTokens.statusCritical.withValues(alpha: 0.06),
            MonitorBucket.warning => ZestTokens.statusWarning.withValues(alpha: 0.05),
            // The theme's own hover, as every other row: a half of it turned
            // Daylight's row grey and its text unreadable (the design audit).
            _ => _hovered ? ZestTokens.surfaceHover : Colors.transparent,
          };

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          color: rowBg,
          padding: const EdgeInsets.symmetric(horizontal: _kRowHPad),
          height: _kRowHeight,
          child: Row(
            children: [
              // §2: the 3px left rule is the host's IDENTITY colour, never its
              // health. With no colour on the host or its group the rule is
              // omitted entirely, leaving a neutral row.
              SizedBox(
                width: _kLeadGutter,
                child: identityColor == null
                    ? null
                    : Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Container(
                          width: 3,
                          height: 32,
                          decoration: BoxDecoration(
                            color: identityColor,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
              ),
              for (final c in widget.columns)
                SizedBox(
                  width: widget.widths[c.key] ?? c.width,
                  child: Padding(padding: _cellPadding(c), child: cellFor(c)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Row cells ────────────────────────────────────────────────────────

class _HostCell extends StatelessWidget {
  final ConnectionWithDetails details;
  final bool hasActiveSession;
  final CollectionError? collectError;

  const _HostCell({
    required this.details,
    required this.hasActiveSession,
    required this.collectError,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final err = collectError;
    // The one row of a host, its own icon beside its name.
    // The row around it lights up and takes the tap.
    return HostRow(
      host: details.connection,
      user: details.identity?.username,
      group: details.group,
      under: true,
      iconSize: _kHostIconSize,
      open: hasActiveSession,
      openLabel: l10n.broadcastToHostsIsOpen,
      nameStyle: _kHostNameStyle.copyWith(color: ZestTokens.textPrimary),
      padding: EdgeInsets.zero,
      margin: EdgeInsets.zero,
      hovers: false,
      // Reading the stats of an open session failed: what with, on hover.
      trailing: err == null
          ? null
          : Tooltip(
              message: l10n.monitorCollectFailed(
                switch (err.source) {
                  MetricSource.prometheus => l10n.monitorMechanismPrometheus,
                  MetricSource.ssh => l10n.monitorMechanismSsh,
                  MetricSource.none => '',
                },
                err.reason,
              ),
              waitDuration: const Duration(milliseconds: 300),
              child: Icon(LucideIcons.alertCircle, size: 14, color: ZestTokens.statusCritical),
            ),
    );
  }
}

/// What the Status cell says of a host that cannot be checked: a short reason
/// and, where there is one, the fix.
class _CantCheckLine {
  final String title;
  final String? action;
  final VoidCallback? onAction;
  final String? actionTooltip;

  const _CantCheckLine(this.title, {this.action, this.onAction, this.actionTooltip});
}

/// The status of a host, in the table's Status column: a chip naming the
/// metric over its limit ("RAM high"); a quiet check mark where all is well;
/// for a host that cannot be checked, why in a few words and a button that
/// fixes it ("Not watched yet" / "Watch this host"). A Reboot chip follows
/// where the host asks for a restart, and a note under it where the
/// collector can read only part of the host. Under the mouse, a card says
/// the full cause, with its details to copy where a check failed (§19).
class _StatusCell extends StatefulWidget {
  final MonitorHostView view;
  final Connection connection;
  final MonitorHostStatus? monitorStatus;
  final bool needsReboot;
  final String? partialNote;
  final bool canWatchMore;
  final String? rejectedUser;

  /// The host as its row shows it: what a check that failed is said of.
  final String hostName;
  final VoidCallback onWatch;
  final VoidCallback onEditHost;
  final VoidCallback onCheckNow;
  final VoidCallback onOpenSession;

  const _StatusCell({
    required this.view,
    required this.connection,
    required this.monitorStatus,
    required this.needsReboot,
    required this.partialNote,
    required this.canWatchMore,
    required this.rejectedUser,
    required this.hostName,
    required this.onWatch,
    required this.onEditHost,
    required this.onCheckNow,
    required this.onOpenSession,
  });

  @override
  State<_StatusCell> createState() => _StatusCellState();
}

class _StatusCellState extends State<_StatusCell> {
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();
  Timer? _hideTimer;

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _show() {
    _hideTimer?.cancel();
    if (!_portal.isShowing) _portal.show();
  }

  // A short close delay bridges the gap between the status and the detached
  // card so the pointer can travel into the card (e.g. to click the action
  // link) without dismissing it.
  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 90), () {
      if (mounted && _portal.isShowing) _portal.hide();
    });
  }

  /// Why the host cannot be checked, and its fix.
  _CantCheckLine _cantCheck(AppLocalizations l10n) {
    final conn = widget.connection;
    final view = widget.view;
    // A host that is SFTP only runs no command to read figures with.
    final noTerminal = noTerminalReason(conn, l10n);
    if (noTerminal != null) return _CantCheckLine(noTerminal);
    if (conn.protocol != 'ssh') return _CantCheckLine(l10n.monitorTableSshOnly);
    if (!conn.monitored) {
      return widget.canWatchMore
          ? _CantCheckLine(l10n.monitorTableNotWatched, action: l10n.monitorTableWatch, onAction: widget.onWatch)
          : _CantCheckLine(
              l10n.monitorTableNotWatched,
              action: l10n.monitorTableUpgradeToWatch,
              onAction: widget.onWatch,
              actionTooltip: l10n.monitorAgentlessLimitReached(freeMonitorLimit),
            );
    }
    switch (view.cantCheckReason!) {
      case CantCheckReason.noCredentials:
        return _CantCheckLine(l10n.monitorTableNoLogin, action: l10n.monitorTableAddKey, onAction: widget.onEditHost);
      case CantCheckReason.authFailed:
        return _CantCheckLine(l10n.monitorTableSignInRefused,
            action: l10n.monitorTableFixLogin, onAction: widget.onEditHost);
      case CantCheckReason.unreachable:
        return _CantCheckLine(l10n.monitorTableUnreachable,
            action: l10n.monitorTableTryAgain, onAction: widget.onCheckNow);
      case CantCheckReason.checkFailed:
        return _CantCheckLine(l10n.monitorTableCheckFailed,
            action: l10n.monitorTableTryAgain, onAction: widget.onCheckNow);
      case CantCheckReason.hostKeyReview:
        // A session to the host shows its key, to accept or refuse.
        return _CantCheckLine(view.hostKeyChanged ? l10n.monitorTableKeyChanged : l10n.monitorTableKeyNew,
            action: l10n.monitorTableReviewKey, onAction: widget.onOpenSession);
      case CantCheckReason.connecting:
        return _CantCheckLine(l10n.monitorTableChecking);
      case CantCheckReason.stale:
        return _CantCheckLine(l10n.monitorTableStale, action: l10n.monitorTableCheckNow, onAction: widget.onCheckNow);
      case CantCheckReason.noCollector:
        if (widget.monitorStatus?.detail == 'monitor-limit') {
          return _CantCheckLine(l10n.monitorTableOverLimit,
              action: l10n.upgrade, onAction: () => PricingModal.show(context));
        }
        return _CantCheckLine(l10n.monitorTableNotCheckedYet,
            action: l10n.monitorTableCheckNow, onAction: widget.onCheckNow);
      case CantCheckReason.neverChecked:
        return _CantCheckLine(l10n.monitorTableNotCheckedYet,
            action: l10n.monitorTableCheckNow, onAction: widget.onCheckNow);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final view = widget.view;
    final id = widget.connection.id;
    final tooltip = monitorPillTooltip(
      view,
      l10n,
      checkedPhrase: _agoPhrase(view.statsCollectedAt, l10n),
      rejectedUser: widget.rejectedUser,
      host: widget.hostName,
      port: widget.connection.port,
    );
    // The tooltip text is a bold primary cause line plus an optional muted
    // second line; the card presents them as two tiers (§19).
    final lines = tooltip.split('\n');
    final primary = lines.first;
    final secondary = lines.length > 1 ? lines.sublist(1).join('\n') : null;
    // A check that failed: what was said of it and what it failed with, to
    // copy from the card.
    final report = failedCheckReport(view, tooltip);

    final cardAction = view.bucket == MonitorBucket.cantCheck && widget.connection.monitored
        ? monitorCantCheckAction(view.cantCheckReason!)
        : null;

    // The first line: what the mouse shows the card for.
    final Widget head;
    Widget? second;
    switch (view.bucket) {
      case MonitorBucket.critical:
      case MonitorBucket.warning:
        final metric = view.breachedMetric ?? (view.overLimit.isEmpty ? null : view.overLimit.first.metric);
        head = ZestStatusPill(
          kind: view.bucket.kind,
          label: metric == null ? view.bucket.label(l10n) : l10n.monitorTableMetricHigh(monitorMetricLabel(metric, l10n)),
          icon: view.bucket.icon,
        );
        second = widget.partialNote == null ? null : _PartialNote(widget.partialNote!);
      case MonitorBucket.healthy:
        head = _QuietOk(label: l10n.monitorTableOk);
        second = widget.partialNote == null ? null : _PartialNote(widget.partialNote!);
      case MonitorBucket.cantCheck:
        final line = _cantCheck(l10n);
        head = Text(
          line.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary),
        );
        if (line.action != null) {
          second = _LinkButton(
            key: ValueKey('monitor-action-$id'),
            label: line.action!,
            tooltip: line.actionTooltip,
            onPressed: line.onAction,
          );
        }
    }

    final hoverTarget = OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (context) {
        return CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topLeft,
          offset: const Offset(0, 6),
          // Align breaks the Overlay's tight full-screen constraints so the
          // card takes its natural size, anchored at the follower origin.
          child: Align(
            alignment: Alignment.topLeft,
            child: MouseRegion(
              onEnter: (_) => _show(),
              onExit: (_) => _scheduleHide(),
              child: _StatusHoverCard(
                primary: primary,
                secondary: secondary,
                action: cardAction,
                connectionId: id,
                report: report,
              ),
            ),
          ),
        );
      },
      child: CompositedTransformTarget(
        link: _link,
        child: MouseRegion(
          key: ValueKey('monitor-status-$id'),
          onEnter: (_) => _show(),
          onExit: (_) => _scheduleHide(),
          // Keep the cause reachable by assistive tech / keyboard focus, not
          // hover-only.
          child: Semantics(label: tooltip, container: true, child: head),
        ),
      ),
    );

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // "Reboot needed" beside the status where the column holds both, else
        // under it. It only says so: nothing here restarts a host.
        Wrap(
          spacing: 6,
          runSpacing: 3,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            hoverTarget,
            if (widget.needsReboot)
              Tooltip(
                message: l10n.monitorTableRebootTip,
                child: ZestStatusPill(
                  key: ValueKey('monitor-reboot-$id'),
                  kind: ZestStatusKind.warning,
                  label: l10n.hostRebootNeeded,
                  icon: LucideIcons.rotateCcw,
                ),
              ),
          ],
        ),
        if (second != null) ...[
          const SizedBox(height: 3),
          second,
        ],
      ],
    );
  }
}

/// A healthy host's status: a quiet check mark and "OK", no chip.
class _QuietOk extends StatelessWidget {
  final String label;

  const _QuietOk({required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(LucideIcons.check, size: 14, color: ZestTokens.statusHealthy.withValues(alpha: 0.85)),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 12.5, color: ZestTokens.textSecondary)),
      ],
    );
  }
}

/// What the collector can read of a host it reads only partly.
class _PartialNote extends StatelessWidget {
  final String text;

  const _PartialNote(this.text);

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: text,
      waitDuration: const Duration(milliseconds: 400),
      child: Text(
        text,
        key: const ValueKey('monitor-partial'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 10.5, fontFamily: 'JetBrainsMono', color: ZestTokens.textTertiary),
      ),
    );
  }
}

/// A small text button in the accent ink: the fix under a status ("Watch this
/// host", "Add a key"), and the card's credentials link. A real button
/// (hover, focus, a click cursor), sized to its words.
class _LinkButton extends StatelessWidget {
  final String label;
  final String? tooltip;
  final VoidCallback? onPressed;

  const _LinkButton({super.key, required this.label, this.tooltip, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final button = TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: ZestTokens.brandInk,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        minimumSize: const Size(0, 20),
        maximumSize: const Size(double.infinity, 22),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        // The theme's face, at the size of the words around it.
        textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 12, fontWeight: FontWeight.w600),
      ),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    // Left edge in line with the words above it.
    final shifted = Transform.translate(offset: const Offset(-2, 0), child: button);
    final t = tooltip;
    return t == null ? shifted : Tooltip(message: t, child: shifted);
  }
}

/// The custom hover popover for a status (§19): a rounded card with a subtle
/// border, a bold primary cause line, a muted secondary line, and - for the
/// actionable Can't-check reasons - the credentials link.
class _StatusHoverCard extends StatelessWidget {
  final String primary;
  final String? secondary;
  final MonitorCantCheckAction? action;
  final String connectionId;

  /// What a check that failed is copied as, where one is why the host
  /// cannot be checked.
  final String? report;

  const _StatusHoverCard({
    required this.primary,
    required this.secondary,
    required this.action,
    required this.connectionId,
    required this.report,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      width: 280,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.borderStrong, width: 0.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            primary,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.35,
              fontWeight: FontWeight.w600,
              color: ZestTokens.textPrimary,
            ),
          ),
          if (secondary != null && secondary!.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              secondary!,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: ZestTokens.textSecondary,
              ),
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: 6),
            _LinkButton(
              label: action == MonitorCantCheckAction.addCredential
                  ? l10n.zestMonitorActionAddCredential
                  : l10n.monitorTableFixLogin,
              onPressed: () => context.push('${Routes.connectionEdit}/$connectionId'),
            ),
          ],
          if (report != null) ...[
            const SizedBox(height: 4),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: CopyDetailsButton(detail: report!),
            ),
          ],
        ],
      ),
    );
  }
}

MetricSeverity _sevOf(double v, double warn, double crit) => v >= crit
    ? MetricSeverity.critical
    : v >= warn
        ? MetricSeverity.warning
        : MetricSeverity.healthy;

/// The colour of a figure by where it stands: the page's text within its
/// limits, amber over the warning one, red over the critical one.
Color _figureColor(MetricSeverity? s) => switch (s) {
      MetricSeverity.critical => ZestTokens.statusCritical,
      MetricSeverity.warning => ZestTokens.statusWarning,
      _ => ZestTokens.textPrimary,
    };

/// Which handle of a gauge track is being manipulated (§3).
enum _Handle { warn, crit }

/// A percentage-gauge cell (CPU / RAM / Swap / Disk): the value over a thin bar
/// with a tick at the warning threshold; the value and the bar turn amber
/// over it (red over the critical one). On row hover the track thickens and
/// its warn + crit ticks become draggable handles that write a per-host
/// override immediately (§3). Arrow keys nudge a focused handle by 1 (shift
/// = 10); a live readout follows the handle; a host that already overrides
/// this metric renders brighter handles.
class _MetricGaugeCell extends ConsumerStatefulWidget {
  final String connectionId;
  final String hostName;
  final MonitorMetric metric; // cpu / ram / swap / disk
  final MetricEval? eval;
  final bool rowHovered;

  const _MetricGaugeCell({
    required this.connectionId,
    required this.hostName,
    required this.metric,
    required this.eval,
    required this.rowHovered,
  });

  @override
  ConsumerState<_MetricGaugeCell> createState() => _MetricGaugeCellState();
}

class _MetricGaugeCellState extends ConsumerState<_MetricGaugeCell> {
  static const double _bandMax = 100; // percentage gauges

  final FocusNode _warnFocus = FocusNode(debugLabel: 'gaugeWarn');
  final FocusNode _critFocus = FocusNode(debugLabel: 'gaugeCrit');

  _Handle? _dragging;
  double? _dragValue; // live value of the handle being dragged
  double? _dragOther; // the fixed companion threshold during a drag
  HostThresholdOverride? _prevOverride; // snapshot for the toast's Undo

  @override
  void dispose() {
    _warnFocus.dispose();
    _critFocus.dispose();
    super.dispose();
  }

  void _write(double warn, double crit) {
    ref.read(monitorThresholdsProvider.notifier).setOverrideMetric(
        widget.connectionId, widget.metric, MetricThreshold(warn, crit));
  }

  void _onDragStart(_Handle h, MetricEval e) {
    _prevOverride =
        ref.read(monitorThresholdsProvider).overrideFor(widget.connectionId);
    setState(() {
      _dragging = h;
      _dragValue = h == _Handle.warn ? e.warn : e.crit;
      _dragOther = h == _Handle.warn ? e.crit : e.warn;
    });
    (h == _Handle.warn ? _warnFocus : _critFocus).requestFocus();
  }

  void _onDragUpdate(double dx, double width) {
    final h = _dragging;
    final other = _dragOther;
    if (h == null || _dragValue == null || other == null || width <= 0) return;
    var v = _dragValue! + dx / width * _bandMax;
    if (h == _Handle.warn) {
      v = v.clamp(0.0, other - 1);
      _write(v, other); // warn handle can never cross crit
    } else {
      v = v.clamp(other + 1, _bandMax);
      _write(other, v);
    }
    setState(() => _dragValue = v);
  }

  void _onDragEnd() {
    final h = _dragging;
    final v = _dragValue;
    if (h != null && v != null) _showToast(h, v.round());
    setState(() {
      _dragging = null;
      _dragValue = null;
      _dragOther = null;
    });
  }

  KeyEventResult _onKey(_Handle h, MetricEval e, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final isLeft = event.logicalKey == LogicalKeyboardKey.arrowLeft;
    final isRight = event.logicalKey == LogicalKeyboardKey.arrowRight;
    if (!isLeft && !isRight) return KeyEventResult.ignored;
    final step = HardwareKeyboard.instance.isShiftPressed ? 10.0 : 1.0;
    final delta = isRight ? step : -step;
    _prevOverride =
        ref.read(monitorThresholdsProvider).overrideFor(widget.connectionId);
    var warn = e.warn;
    var crit = e.crit;
    double committed;
    if (h == _Handle.warn) {
      warn = (warn + delta).clamp(0.0, crit - 1);
      committed = warn;
    } else {
      crit = (crit + delta).clamp(warn + 1, _bandMax);
      committed = crit;
    }
    _write(warn, crit);
    _showToast(h, committed.round());
    return KeyEventResult.handled;
  }

  void _showToast(_Handle h, int value) {
    _showOverrideToast(
      context,
      ref,
      connectionId: widget.connectionId,
      host: widget.hostName,
      metric: widget.metric,
      handle: h,
      value: value,
      previous: _prevOverride,
    );
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.eval;
    final v = e?.value?.clamp(0.0, 100.0);
    // Nothing read of it: the cell stays empty, as the mockup has it.
    if (e == null || v == null) return const SizedBox.shrink();

    final valueColor = _figureColor(e.severity);
    final fillColor = e.severity == MetricSeverity.healthy
        ? ZestTokens.textTertiary.withValues(alpha: 0.7)
        : valueColor;
    final hovered = widget.rowHovered;
    final overridden = ref
            .watch(monitorThresholdsProvider)
            .overrideFor(widget.connectionId)
            ?.metrics
            .containsKey(widget.metric) ??
        false;

    // While dragging, the active handle follows the drag; the companion + the
    // idle state read from the freshly-resolved eval.
    final warn = _dragging == _Handle.warn
        ? (_dragValue ?? e.warn)
        : (_dragging == _Handle.crit ? (_dragOther ?? e.warn) : e.warn);
    final crit = _dragging == _Handle.crit
        ? (_dragValue ?? e.crit)
        : (_dragging == _Handle.warn ? (_dragOther ?? e.crit) : e.crit);
    final trackHeight = hovered ? 8.0 : 3.0;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          formatPercentNumber(v),
          key: ValueKey('monitor-value-${widget.metric.name}'),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            fontFamily: 'JetBrainsMono',
            color: valueColor,
          ),
        ),
        const SizedBox(height: 4),
        LayoutBuilder(
          builder: (context, cns) {
            final w = cns.maxWidth;
            return SizedBox(
              // Reserve a stable height so the row doesn't jump on hover.
              height: 12,
              width: w,
              child: Stack(
                key: ValueKey('monitor-bar-${widget.metric.name}'),
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: (12 - trackHeight) / 2,
                    height: trackHeight,
                    child: CustomPaint(
                      painter: _GaugeTrackPainter(
                        value: v,
                        color: fillColor,
                        warn: warn,
                        crit: crit,
                        hovered: hovered,
                        overridden: overridden,
                        trackColor: ZestTokens.borderSubtle,
                      ),
                    ),
                  ),
                  // At rest: one tick where the warning starts.
                  if (!hovered)
                    Positioned(
                      key: ValueKey('monitor-tick-${widget.metric.name}'),
                      left: (warn / _bandMax).clamp(0.0, 1.0) * (w - 1),
                      top: 2,
                      width: 1,
                      height: 8,
                      child: ColoredBox(
                        color: v >= warn ? ZestTokens.textPrimary : ZestTokens.textTertiary,
                      ),
                    ),
                  if (hovered) ...[
                    _handle(_Handle.warn, warn, w, e),
                    _handle(_Handle.crit, crit, w, e),
                    if (_dragging != null && _dragValue != null)
                      _readout(_dragValue!, w),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _handle(_Handle h, double value, double width, MetricEval e) {
    const hitW = 18.0;
    final x = (value / _bandMax).clamp(0.0, 1.0) * width;
    final maxLeft = (width - hitW).clamp(0.0, width);
    final focus = h == _Handle.warn ? _warnFocus : _critFocus;
    return Positioned(
      left: (x - hitW / 2).clamp(0.0, maxLeft),
      top: 0,
      bottom: 0,
      width: hitW,
      child: Focus(
        focusNode: focus,
        onKeyEvent: (_, ev) => _onKey(h, e, ev),
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeLeftRight,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: focus.requestFocus,
            onHorizontalDragStart: (_) => _onDragStart(h, e),
            onHorizontalDragUpdate: (d) => _onDragUpdate(d.delta.dx, width),
            onHorizontalDragEnd: (_) => _onDragEnd(),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }

  Widget _readout(double value, double width) {
    const boxW = 32.0;
    final x = (value / _bandMax).clamp(0.0, 1.0) * width;
    final maxLeft = (width - boxW).clamp(0.0, width);
    return Positioned(
      left: (x - boxW / 2).clamp(0.0, maxLeft),
      top: -14,
      width: boxW,
      child: IgnorePointer(
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 1),
          decoration: BoxDecoration(
            color: ZestTokens.surfaceRaised,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: ZestTokens.borderStrong, width: 0.5),
          ),
          child: Text(
            '${value.round()}',
            style: TextStyle(
              fontSize: 9,
              fontFamily: 'JetBrainsMono',
              color: ZestTokens.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints a gauge track: background and value fill; on hover a thicker track
/// with warn + crit handle ticks (brighter when the host overrides the
/// metric). The resting warning tick is a widget beside it, so it can be
/// found and measured.
class _GaugeTrackPainter extends CustomPainter {
  final double value; // 0..100
  final Color color;
  final double warn;
  final double crit;
  final bool hovered;
  final bool overridden;
  final Color trackColor;

  const _GaugeTrackPainter({
    required this.value,
    required this.color,
    required this.warn,
    required this.crit,
    required this.hovered,
    required this.overridden,
    required this.trackColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width, size.height), r),
      Paint()..color = trackColor,
    );

    final fillW = (value / 100).clamp(0.0, 1.0) * size.width;
    if (fillW > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, fillW, size.height), r),
        Paint()..color = color,
      );
    }

    if (!hovered) return;

    double xOf(double t) => (t / 100).clamp(0.0, 1.0) * size.width;

    void handle(double t, Color c) {
      final dx = xOf(t).clamp(2.0, size.width - 2.0);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(dx, size.height / 2),
            width: 4,
            height: size.height + 6,
          ),
          const Radius.circular(2),
        ),
        Paint()..color = c.withValues(alpha: overridden ? 1.0 : 0.85),
      );
    }

    handle(warn, ZestTokens.statusWarning);
    handle(crit, ZestTokens.statusCritical);
  }

  @override
  bool shouldRepaint(_GaugeTrackPainter old) =>
      old.value != value ||
      old.color != color ||
      old.warn != warn ||
      old.crit != crit ||
      old.hovered != hovered ||
      old.overridden != overridden;
}

/// A figure in quiet mono: "none" for a host without swap.
class _QuietValue extends StatelessWidget {
  final String text;

  const _QuietValue(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Text(text, style: TextStyle(fontSize: 12, fontFamily: 'JetBrainsMono', color: ZestTokens.textTertiary)),
    );
  }
}

/// A value-only metric cell (Load / Temp / Ping / Up / Network / Disk I/O /
/// Updates): mono, empty where the host does not report it (never 0). Temp
/// and Ping tint by their scored severity; the rest stay neutral.
class _MetricValueCell extends StatelessWidget {
  final MonitorColumn column;
  final ServerStats? stats;
  final MonitorHostView view;

  const _MetricValueCell({
    required this.column,
    required this.stats,
    required this.view,
  });

  @override
  Widget build(BuildContext context) {
    final (text, sev) = _metricCellContent(column, stats, view);
    if (text == null) return const SizedBox.shrink();
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          fontFamily: 'JetBrainsMono',
          color: sev == null || sev == MetricSeverity.healthy ? ZestTokens.textSecondary : _figureColor(sev),
        ),
      ),
    );
  }

}

/// What a value-only metric column says of a host: its words, and how they
/// are tinted. Null words where the host does not report it.
(String?, MetricSeverity?) _metricCellContent(MonitorColumn column, ServerStats? s, MonitorHostView view) {
  switch (column) {
    case MonitorColumn.load:
      final v = s?.load1;
      return (v == null ? null : formatDecimal(v, digits: 2), null);
    case MonitorColumn.temp:
      final e = view.metricEval(MonitorMetric.temp);
      final v = e?.value;
      return v == null ? (null, null) : ('${formatDecimal(v, digits: 0)}°C', e?.severity);
    case MonitorColumn.ping:
      // The round trip of the reading where it has one, else that of a
      // check of whether the host can be reached ([resolveMonitorHost]).
      final e = view.metricEval(MonitorMetric.latency);
      final v = e?.value;
      if (e == null || v == null) return (null, null);
      final sev = _sevOf(v, e.warn, e.crit);
      // A measured RTT under a millisecond truncates to 0; show <1ms, not 0ms.
      return (v < 1 ? '<1ms' : '${v.round()}ms', sev);
    case MonitorColumn.uptime:
      final secs = s?.uptimeSeconds;
      return (secs == null ? null : _uptimeShort(secs), null);
    case MonitorColumn.network:
      final rx = s?.netRxBytesPerSec;
      final tx = s?.netTxBytesPerSec;
      if (rx == null && tx == null) return (null, null);
      return ('↓${_rateShort(rx)} ↑${_rateShort(tx)}', null);
    case MonitorColumn.diskIo:
      final rd = s?.diskReadBytesPerSec;
      final wr = s?.diskWriteBytesPerSec;
      if (rd == null && wr == null) return (null, null);
      return ('r ${_rateShort(rd)} w ${_rateShort(wr)}', null);
    case MonitorColumn.updates:
      // Pending updates, where the host keeps a count of them (Ubuntu's
      // update-notifier); empty elsewhere.
      final t = s?.updatesTotal;
      return (t == null ? null : '$t', null);
    case MonitorColumn.cpu:
    case MonitorColumn.ram:
    case MonitorColumn.swap:
    case MonitorColumn.disk:
      return (null, null); // percentage gauges never render here
  }
}

/// What one of the last 24 checks found, for its bar.
@visibleForTesting
enum MonitorCheckMark { empty, noData, ok, warning, critical }

/// The 24 slots of the "Last 24 checks" bars from the stored checks (oldest
/// first, as [monitorRecentSamplesProvider] gives them): the most recent 24,
/// right-aligned, with the slots no check has filled yet empty on the left.
/// A check that failed, or that read nothing to score, has no data.
@visibleForTesting
List<MonitorCheckMark> monitorCheckMarks(
  List<MonitorSample> samples,
  Map<MonitorMetric, MetricThreshold> thresholds, {
  int slots = 24,
}) {
  final recent = samples.length > slots ? samples.sublist(samples.length - slots) : samples;
  return [
    for (var i = recent.length; i < slots; i++) MonitorCheckMark.empty,
    for (final s in recent)
      switch (monitorSampleSeverity(s, thresholds)) {
        MetricSeverity.critical => MonitorCheckMark.critical,
        MetricSeverity.warning => MonitorCheckMark.warning,
        MetricSeverity.healthy => MonitorCheckMark.ok,
        null => MonitorCheckMark.noData,
      },
  ];
}

/// The "Last 24 checks" bars (§1): one small bar per stored check, green
/// where it was within the limits, amber (and taller) where it found a
/// warning, red where it found a critical level, grey where it read nothing;
/// a dot where no check has been made yet.
class MonitorChecksBars extends ConsumerWidget {
  final String connectionId;

  const MonitorChecksBars({super.key, required this.connectionId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final samples =
        ref.watch(monitorRecentSamplesProvider(connectionId)).valueOrNull ??
            const <MonitorSample>[];
    final thresholds =
        ref.watch(monitorThresholdsProvider).resolveFor(connectionId);
    final marks = monitorCheckMarks(samples, thresholds);

    // Each bar is keyed by its slot and what it shows ("monitor-check-23-warning").
    Widget bar(int i, MonitorCheckMark m) {
      final (height, color) = switch (m) {
        MonitorCheckMark.empty => (2.0, ZestTokens.textTertiary.withValues(alpha: 0.45)),
        MonitorCheckMark.noData => (10.0, ZestTokens.textTertiary.withValues(alpha: 0.5)),
        MonitorCheckMark.ok => (10.0, ZestTokens.statusHealthy.withValues(alpha: 0.75)),
        MonitorCheckMark.warning => (16.0, ZestTokens.statusWarning),
        MonitorCheckMark.critical => (16.0, ZestTokens.statusCritical),
      };
      return Container(
        key: ValueKey('monitor-check-$i-${m.name}'),
        width: 3,
        height: height,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(1)),
      );
    }

    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: SizedBox(
        height: 16,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < marks.length; i++) ...[
              if (i > 0) const SizedBox(width: 1.5),
              bar(i, marks[i]),
            ],
          ],
        ),
      ),
    );
  }
}

/// Compact uptime for the table column ("62d", "5h", "12m").
String _uptimeShort(int secs) {
  final d = secs ~/ 86400;
  if (d >= 1) return '${d}d';
  final h = secs ~/ 3600;
  if (h >= 1) return '${h}h';
  return '${secs ~/ 60}m';
}

/// Compact byte-rate for the Network / Disk I/O columns ("1.2M", "84K").
String _rateShort(double? bytesPerSec) {
  final b = bytesPerSec ?? 0;
  if (b < 1024) return '${formatDecimal(b, digits: 0)}B';
  const units = ['K', 'M', 'G', 'T'];
  var v = b / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${formatDecimal(v, digits: v >= 10 ? 0 : 1)}${units[i]}';
}

/// How long ago the host was last read (§1.4): "2m", or "never".
class _SeenCell extends StatelessWidget {
  final DateTime? collectedAt;

  const _SeenCell({required this.collectedAt});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final never = collectedAt == null;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Text(
        _checkedShort(collectedAt, l10n),
        style: TextStyle(
          fontSize: 12,
          fontFamily: 'JetBrainsMono',
          color: never ? ZestTokens.textTertiary : ZestTokens.textSecondary,
        ),
      ),
    );
  }
}

/// A row's own buttons: a session to the host, and its menu.
class _RowActions extends StatelessWidget {
  final String connectionId;
  final VoidCallback onOpenSession;
  final void Function(RelativeRect position) onMenu;

  const _RowActions({required this.connectionId, required this.onOpenSession, required this.onMenu});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        IconButton(
          key: ValueKey('monitor-open-$connectionId'),
          tooltip: l10n.monitorTableOpenSession,
          onPressed: onOpenSession,
          icon: Icon(LucideIcons.terminal, size: 15, color: ZestTokens.textSecondary),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          visualDensity: VisualDensity.compact,
        ),
        MenuDotsButton(
          key: ValueKey('monitor-menu-$connectionId'),
          tooltip: l10n.monitorTableRowMenu,
          icon: LucideIcons.moreHorizontal,
          iconSize: 15,
          color: ZestTokens.textSecondary,
          onOpen: onMenu,
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// Column chooser (§2): toolbar button + anchored reorder/toggle popover
// ══════════════════════════════════════════════════════════════════════

class _ColumnsButton extends StatefulWidget {
  const _ColumnsButton();

  @override
  State<_ColumnsButton> createState() => _ColumnsButtonState();
}

class _ColumnsButtonState extends State<_ColumnsButton> {
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (context) {
          return Stack(
            children: [
              // Outside-tap barrier closes the popover.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _portal.hide,
                ),
              ),
              CompositedTransformFollower(
                link: _link,
                showWhenUnlinked: false,
                targetAnchor: Alignment.bottomRight,
                followerAnchor: Alignment.topRight,
                offset: const Offset(0, 6),
                child: Align(
                  alignment: Alignment.topRight,
                  child: _ColumnChooserPopover(),
                ),
              ),
            ],
          );
        },
        child: _ToolIconButton(
          key: const ValueKey('monitor-columns'),
          tooltip: l10n.monitorColumnsButton,
          onPressed: _portal.toggle,
          child: const Icon(LucideIcons.columns, size: 16),
        ),
      ),
    );
  }
}

class _ColumnChooserPopover extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final cfg = ref.watch(monitorColumnsProvider);
    final notifier = ref.read(monitorColumnsProvider.notifier);
    final widthsSet = ref.watch(monitorColumnWidthsProvider).isNotEmpty;

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 240,
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: ZestTokens.surfaceRaised,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: ZestTokens.borderStrong, width: 0.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 8),
              child: Text(
                l10n.monitorColumnsButton,
                style: TextStyle(fontSize: 11, color: ZestTokens.textTertiary),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ReorderableListView(
                shrinkWrap: true,
                buildDefaultDragHandles: false,
                // reorder takes the old onReorder index (one past the slot when moving down).
                onReorderItem: (o, n) => notifier.reorder(o, n > o ? n + 1 : n),
                children: [
                  for (var i = 0; i < cfg.order.length; i++)
                    _ColumnChooserRow(
                      key: ValueKey(cfg.order[i]),
                      index: i,
                      label: _metricColLabel(cfg.order[i], l10n),
                      on: cfg.visible.contains(cfg.order[i]),
                      onToggle: (v) => notifier.toggle(cfg.order[i], v),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 2, right: 2, top: 8),
              child: Text(
                l10n.monitorColumnsFootnote,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: ZestTokens.textTertiary,
                ),
              ),
            ),
            // Widths set by dragging a column's edge are remembered: this
            // puts them back.
            if (widthsSet)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: _LinkButton(
                  key: const ValueKey('monitor-columns-reset-widths'),
                  label: l10n.monitorColumnsResetWidths,
                  onPressed: () => ref.read(monitorColumnWidthsProvider.notifier).reset(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ColumnChooserRow extends StatelessWidget {
  final int index;
  final String label;
  final bool on;
  final ValueChanged<bool> onToggle;

  const _ColumnChooserRow({
    super.key,
    required this.index,
    required this.label,
    required this.on,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Icon(LucideIcons.gripVertical,
                  size: 15, color: ZestTokens.textTertiary),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: on ? ZestTokens.textSecondary : ZestTokens.textTertiary,
              ),
            ),
          ),
          ZestSwitch(value: on, onChanged: onToggle),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// Drag-to-override toast (§6): announced + reversible
// ══════════════════════════════════════════════════════════════════════

/// The single visible override toast, so a fresh drag replaces the last one.
OverlayEntry? _activeOverrideToast;

/// Show the undoable "override created" toast for a drag / arrow-key threshold
/// edit (§6). [previous] is the host's override snapshot BEFORE this edit, used
/// by Undo to restore it exactly (null → the host had no override → remove it).
void _showOverrideToast(
  BuildContext context,
  WidgetRef ref, {
  required String connectionId,
  required String host,
  required MonitorMetric metric,
  required _Handle handle,
  required int value,
  required HostThresholdOverride? previous,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  final l10n = AppLocalizations.of(context)!;
  final notifier = ref.read(monitorThresholdsProvider.notifier);

  void undo() {
    if (previous == null) {
      notifier.removeOverride(connectionId);
    } else {
      notifier.upsertOverride(connectionId,
          metrics: previous.metrics, reason: previous.reason);
    }
  }

  final bound = handle == _Handle.warn
      ? l10n.zestThresholdWarn.toLowerCase()
      : l10n.zestThresholdCrit.toLowerCase();

  _activeOverrideToast?.remove();
  late final OverlayEntry entry;
  void dismiss() {
    if (identical(_activeOverrideToast, entry)) _activeOverrideToast = null;
    entry.remove();
  }

  entry = OverlayEntry(
    builder: (_) => _OverrideToastCard(
      title: l10n.monitorOverrideToastTitle(host),
      detail: l10n.monitorOverrideToastDetail(
          monitorMetricLabel(metric, l10n), bound, value),
      undoLabel: l10n.monitorUndo,
      addReasonLabel: l10n.monitorAddReason,
      onUndo: () {
        undo();
        dismiss();
      },
      onAddReason: (ctx) {
        dismiss();
        showMonitorThresholds(ctx, hostId: connectionId);
      },
      onDismiss: dismiss,
    ),
  );
  _activeOverrideToast = entry;
  overlay.insert(entry);
}

class _OverrideToastCard extends StatefulWidget {
  final String title;
  final String detail;
  final String undoLabel;
  final String addReasonLabel;
  final VoidCallback onUndo;
  final void Function(BuildContext) onAddReason;
  final VoidCallback onDismiss;

  const _OverrideToastCard({
    required this.title,
    required this.detail,
    required this.undoLabel,
    required this.addReasonLabel,
    required this.onUndo,
    required this.onAddReason,
    required this.onDismiss,
  });

  @override
  State<_OverrideToastCard> createState() => _OverrideToastCardState();
}

class _OverrideToastCardState extends State<_OverrideToastCard> {
  Timer? _timer;
  double _opacity = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 6), widget.onDismiss);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _opacity = 1);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 24,
      child: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: AnimatedOpacity(
            opacity: _opacity,
            duration: const Duration(milliseconds: 160),
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: 340,
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: BoxDecoration(
                  color: ZestTokens.surfaceRaised,
                  borderRadius: BorderRadius.circular(9),
                  border:
                      Border.all(color: ZestTokens.borderStrong, width: 0.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(LucideIcons.slidersHorizontal,
                            size: 16, color: ZestTokens.brandInk),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.title,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: ZestTokens.textPrimary),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                widget.detail,
                                style: TextStyle(
                                  fontSize: 11,
                                  height: 1.4,
                                  color: ZestTokens.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.only(left: 24),
                      child: Row(
                        children: [
                          _LinkButton(
                            label: widget.undoLabel,
                            onPressed: () {
                              _timer?.cancel();
                              widget.onUndo();
                            },
                          ),
                          const SizedBox(width: 12),
                          _LinkButton(
                            label: widget.addReasonLabel,
                            onPressed: () {
                              _timer?.cancel();
                              widget.onAddReason(context);
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// Background monitoring off
// ══════════════════════════════════════════════════════════════════════

class _AgentlessOffState extends StatelessWidget {
  final VoidCallback onEnable;
  final VoidCallback onManage;

  const _AgentlessOffState({required this.onEnable, required this.onManage});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Scrolls where the window is too low for it: its two buttons, the way
    // to turn the monitor on among them, were cut off there.
    return Center(
      child: SingleChildScrollView(
        key: const ValueKey('monitor-off'),
        child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.radar,
                  size: 52, color: ZestTokens.textTertiary),
              const SizedBox(height: 16),
              Text(
                l10n.monitorAgentlessOffTitle,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: ZestTokens.textPrimary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                l10n.monitorAgentlessOffBody,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: ZestTokens.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              // A Wrap: in a language whose words are longer the two buttons
              // stand one under the other, where a row ran out of the page.
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: onEnable,
                    icon: const Icon(LucideIcons.play, size: 18),
                    label: Text(l10n.monitorAgentlessEnableAction),
                  ),
                  OutlinedButton.icon(
                    onPressed: onManage,
                    icon: const Icon(LucideIcons.listChecks, size: 18),
                    label: Text(l10n.monitorManageAction),
                  ),
                ],
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}
