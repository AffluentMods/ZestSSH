import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:zestssh/features/monitoring/monitor_host_alerts.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/features/monitoring/monitor_evaluation.dart';
import 'package:zestssh/features/monitoring/monitor_status.dart'
    show monitorStaleAfter;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/providers/monitor_thresholds_provider.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/desktop/widgets/monitor_detail_pane.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/load_error_state.dart';
import 'package:zestssh/ui/screens/desktop/widgets/shell_questions.dart' show confirmUnencryptedConnection;

/// Mobile Server Monitor detail screen for a single host.
///
/// Opened by tapping a host card on the mobile Server Monitor. It resolves the
/// host through the SAME monitoring providers + resolver the desktop table and
/// the mobile card list use, then hands them to [MonitorDetailPane] - the very
/// widget the desktop master/detail view renders. The pane is a pure consumer
/// of the data layer (history chart, "Now" metric cards, filesystems, system),
/// already laid out top-to-bottom and internally scrollable, so it drops
/// straight onto a phone with no new data path and no duplicated chart code.
class ServerDetailScreen extends ConsumerStatefulWidget {
  final String connectionId;
  final String serverName;
  final String host;
  final int port;

  const ServerDetailScreen({
    required this.connectionId,
    required this.serverName,
    required this.host,
    required this.port,
    super.key,
  });

  @override
  ConsumerState<ServerDetailScreen> createState() => _ServerDetailScreenState();
}

class _ServerDetailScreenState extends ConsumerState<ServerDetailScreen> {
  String get _id => widget.connectionId;

  @override
  void initState() {
    super.initState();
    // Pull one fresh health probe + stats sample for THIS host on open, so the
    // graphs populate immediately instead of waiting for the next poll cycle.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshHost();
    });
  }

  ConnectionWithDetails? _match() {
    final conns =
        ref.read(connectionsWithDetailsProvider).valueOrNull ?? const [];
    for (final c in conns) {
      if (c.connection.id == _id) return c;
    }
    return null;
  }

  /// Refresh a single host: one stats collect, and a check of whether it
  /// can be reached where those checks are on (Settings), now when its person
  /// [asked] and only if it is due when the screen merely opens.
  /// Mirrors the desktop detail pane's refresh so both surfaces behave alike.
  Future<void> _refreshHost({bool asked = false}) async {
    final match = _match();
    if (match != null) {
      await ref
          .read(connectionHealthProvider.notifier)
          .checkAll([match.connection], asked: asked);
    }
    // Asked for: Server Monitor tries it again now, where it had stopped.
    if (asked) ref.read(agentlessMonitorPollerProvider.notifier).retry(_id);
    await ref.read(serverStatsProvider.notifier).refreshOne(_id);
  }

  /// Open (or reuse) a terminal on this host running `systemctl --failed` - the
  /// detail view's "View" action for a failed-units row.
  ///
  /// A Telnet host is asked about first, as every way of opening one asks
  /// (it opened with no question).
  Future<void> _viewFailedUnits() async {
    final match = _match();
    if (match == null) return;
    if (match.connection.protocol == 'telnet' && (!await confirmUnencryptedConnection(context) || !mounted)) {
      return;
    }
    final sessionId = ref.read(activeSessionsProvider.notifier).startSession(
          match.connection,
          initialCommand: 'systemctl --failed',
        );
    if (sessionId == null) return;
    context.push('/terminal/$sessionId');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final connectionsAsync = ref.watch(connectionsWithDetailsProvider);
    // The router hands over the label-or-host the card showed; the transient
    // shells paint its display form (recording mode).
    final title = widget.serverName.isNotEmpty &&
            widget.serverName != widget.host
        ? Redactable.host(widget.serverName)
        : Redactable.address(widget.host);

    return connectionsAsync.when(
      loading: () => _shell(
        title,
        Center(child: CircularProgressIndicator(color: AppColors.brandOrange)),
      ),
      error: (e, stack) => _shell(
        title,
        LoadErrorState(
          message: l10n.homeUnableToLoadConnections,
          where: 'Loading the host of a server monitor',
          error: e,
          stack: stack,
          onRetry: () => ref.invalidate(connectionsWithDetailsProvider),
        ),
      ),
      data: (connections) {
        ConnectionWithDetails? details;
        for (final c in connections) {
          if (c.connection.id == _id) {
            details = c;
            break;
          }
        }
        // Host was deleted while this screen was open (or a bad deep link).
        if (details == null) {
          return _shell(title, _message(l10n.monitorNoConnections));
        }

        // Resolve THIS host into the shared four-bucket view + live stats from
        // the exact inputs the desktop table and mobile card list feed the
        // resolver, so all three surfaces can never disagree.
        final statsMap = ref.watch(serverStatsProvider);
        final healthMap = ref.watch(connectionHealthProvider);
        final monitorStatuses = ref.watch(agentlessMonitorPollerProvider);
        final sessions = ref.watch(activeSessionsProvider);
        final config = ref.watch(monitorThresholdsProvider);
        final staleAfter = monitorStaleAfter(
            checkIntervalMinutes: config.global.checkIntervalMinutes,
            refreshIntervalSeconds: ref.read(serverStatsProvider.notifier).refreshIntervalSeconds);

        final hasActiveSession = sessions.values.any(
          (s) => s.connectionId == _id && s.status == SessionStatus.connected,
        );

        final view = resolveMonitorHost(
          history: ref.read(serverStatsHistoryProvider(_id)),
          stats: statsMap[_id],
          health: healthMap[_id],
          monitor: monitorStatuses[_id],
          hasActiveSession: hasActiveSession,
          thresholds: config.resolveFor(_id),
          // The host's own alert choices (its panel's Alert menu).
          silenced: ref.read(hostAlertPrefsProvider)[_id]?.silencedAt(DateTime.now()) ?? const {},
          countArcAsFree: ref.read(hostAlertPrefsProvider)[_id]?.countArcAsFree ?? false,
          debounceReadings: config.global.debounceReadings,
          staleAfter: staleAfter,
          now: DateTime.now(),
        );

        // The pane carries its own header (host name, status pill, host:port,
        // refresh + close), so it is the screen chrome here - no redundant
        // AppBar. Its close acts as "back"; the system back gesture also works.
        // When the host has no data yet, the pane naturally shows an empty
        // "No history yet" chart plus N/A metric cards - the same sensible
        // empty state the desktop shows, never the old "coming soon" text.
        return Scaffold(
          backgroundColor: AppColors.background,
          body: SafeArea(
            child: MonitorDetailPane(
              details: details,
              view: view,
              stats: statsMap[_id],
              onClose: () {
                if (context.canPop()) context.pop();
              },
              onRefresh: () => _refreshHost(asked: true),
              onViewFailedUnits: _viewFailedUnits,
            ),
          ),
        );
      },
    );
  }

  /// A minimal back-enabled Scaffold for the transient loading / error /
  /// not-found states (the data state uses the detail pane's own header).
  Widget _shell(Redactable title, Widget body) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: RedactedText(title),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: body,
    );
  }

  Widget _message(String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style:
                TextStyle(color: AppColors.textSecondary, fontSize: 14),
          ),
        ),
      );
}
