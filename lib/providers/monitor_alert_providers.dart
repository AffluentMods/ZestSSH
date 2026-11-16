import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/monitoring/monitor_evaluation.dart';
import 'package:zestssh/features/monitoring/monitor_host_alerts.dart';
import 'package:zestssh/features/monitoring/monitor_state_ui.dart';
import 'package:zestssh/features/monitoring/monitor_status.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/providers/monitor_thresholds_provider.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';

/// A trouble a watched host can be in that its person is told of.
enum HostTrouble {
  /// A metric is over its warning limit.
  warning,

  /// A metric is over its critical limit.
  critical,

  /// It cannot be reached.
  notReached,

  /// It refused the sign-in.
  signInRefused,

  /// A check of it fails for another reason.
  checkFailed,
}

/// The trouble [view] shows a host to be in, or null where it shows none.
HostTrouble? troubleOf(MonitorHostView view) => switch ((view.bucket, view.cantCheckReason)) {
      (MonitorBucket.critical, _) => HostTrouble.critical,
      (MonitorBucket.warning, _) => HostTrouble.warning,
      (MonitorBucket.cantCheck, CantCheckReason.unreachable) => HostTrouble.notReached,
      (MonitorBucket.cantCheck, CantCheckReason.authFailed) => HostTrouble.signInRefused,
      (MonitorBucket.cantCheck, CantCheckReason.checkFailed) => HostTrouble.checkFailed,
      _ => null,
    };

/// Whether [view] is what a check found of the host: its figures, what the
/// check failed with, or that it answers where nothing reads its figures.
/// Anything else says nothing of how the host is (figures that are too old,
/// a host that was never checked, or has nothing to sign in with, or whose
/// key is to be looked at), and leaves what was found before standing.
bool isFinding(MonitorHostView view) =>
    view.bucket != MonitorBucket.cantCheck ||
    troubleOf(view) != null ||
    view.cantCheckReason == CantCheckReason.noCollector;

/// Raises a notice when what a check finds of a watched host becomes a
/// trouble it was not in before, or a worse one, so that Server Monitor
/// tells its person and is not only there to be looked at.
///
/// It only OBSERVES: it reads the exact same signals the monitor UI feeds
/// [resolveMonitorHost] (stats, TCP health, poller state, live-session flag,
/// thresholds), so it can never disagree with what the screens show, and it
/// never mutates monitor state. It looks once for a burst of changes.
///
/// What a host is found in first, after the app starts, is where it stands,
/// and is not told: a host that was in trouble before is not news. From
/// there a notice is raised when a check finds a trouble the host was not
/// in at the check before: critical after a warning as well, since that it
/// got worse is news, and a warning after critical not, since that is
/// better. A host that stays in a trouble is told of once, however often it
/// is checked again: a check that is under way is no finding, and leaves
/// what was found standing. (It was one: a host that could not be reached
/// raised its notice again every fifteen minutes for as long as it was
/// tried.) A host that swings in and out of the same trouble is told of
/// once in fifteen minutes.
///
/// The notice says which host, what the trouble is, and under it what the
/// check found: the metrics over their limits, or what the check failed
/// with, as the host's status says it, with the report to copy.
///
/// The poller is foreground-only, so alerts are in-app (the notification
/// centre). Off-hours alerting is a separate feature (background monitoring).
class MonitorAlertEngine extends StateNotifier<void> {
  MonitorAlertEngine(this._ref) : super(null) {
    // Any change to the metrics, the poller state, or TCP health re-evaluates.
    _ref.listen(serverStatsProvider, (_, __) => _schedule());
    _ref.listen(agentlessMonitorPollerProvider, (_, __) => _schedule());
    _ref.listen(connectionHealthProvider, (_, __) => _schedule());
    _ref.listen(monitoredConnectionsProvider, (_, __) => _schedule());
    _ref.listen(hostAlertPrefsProvider, (_, _) => _schedule());
  }

  final Ref _ref;

  /// The clock the alerts go by. (The tests set it.)
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  /// What the last check found each host in: a trouble, or none. A host
  /// that is not in it has had no finding yet.
  final Map<String, HostTrouble?> _found = {};

  /// When each trouble of each host was last told, so that a host that
  /// swings in and out of it is not told of at every swing.
  final Map<(String, HostTrouble), DateTime> _told = {};
  static const _alertCooldown = Duration(minutes: 15);
  Timer? _debounce;

  void _schedule() {
    _debounce?.cancel();
    // Mirror the poller's ~300ms reconcile debounce so a burst of updates
    // produces one evaluation, not one per signal.
    _debounce = Timer(const Duration(milliseconds: 300), _evaluate);
  }

  List<Connection> _monitored() =>
      _ref.read(monitoredConnectionsProvider).valueOrNull ?? const [];

  MonitorHostView _resolve(String id) {
    final statsNotifier = _ref.read(serverStatsProvider.notifier);
    final config = _ref.read(monitorThresholdsProvider);
    final sessions = _ref.read(activeSessionsProvider);
    final hasActiveSession = sessions.values.any(
      (s) => s.connectionId == id && s.status == SessionStatus.connected,
    );
    // The host's own alert choices: a muted or snoozed metric tells nothing.
    final prefs = _ref.read(hostAlertPrefsProvider)[id];
    final at = clock();
    return resolveMonitorHost(
      silenced: prefs?.silencedAt(at) ?? const {},
      countArcAsFree: prefs?.countArcAsFree ?? false,
      history: statsNotifier.historyFor(id),
      stats: _ref.read(serverStatsProvider)[id],
      health: _ref.read(connectionHealthProvider)[id],
      monitor: _ref.read(agentlessMonitorPollerProvider)[id],
      hasActiveSession: hasActiveSession,
      thresholds: config.resolveFor(id),
      debounceReadings: config.global.debounceReadings,
      staleAfter: monitorStaleAfter(
          checkIntervalMinutes: config.global.checkIntervalMinutes,
          refreshIntervalSeconds: statsNotifier.refreshIntervalSeconds),
      now: at,
    );
  }

  bool _alertsEnabled() =>
      _ref.read(settingsServiceProvider).monitorAlertsEnabled;

  void _evaluate() {
    final enabled = _alertsEnabled();
    final checks = _ref.read(agentlessMonitorPollerProvider);
    for (final c in _monitored()) {
      // A check that is under way is no finding, whatever figures of the
      // check before are still at hand.
      if (checks[c.id]?.state == MonitorHostState.connecting) continue;
      final view = _resolve(c.id);
      if (!isFinding(view)) continue;
      final known = _found.containsKey(c.id);
      final was = _found[c.id];
      final now = troubleOf(view);
      _found[c.id] = now;
      // The first finding is where the host stands; no trouble, the same
      // trouble, and a warning after critical are nothing to tell.
      if (!known || now == null || now == was) continue;
      if (was == HostTrouble.critical && now == HostTrouble.warning) continue;
      final at = clock();
      final told = _told[(c.id, now)];
      if (!enabled || (told != null && at.difference(told) < _alertCooldown)) continue;
      _told[(c.id, now)] = at;
      _tell(c, view, now);
    }
  }

  void _tell(Connection c, MonitorHostView view, HostTrouble trouble) {
    final l10n = gl10n;
    final name = (c.label.isNotEmpty ? Redactable.host(c.label) : Redactable.address(c.host)).display;
    final notices = _ref.read(notificationCenterProvider.notifier);
    switch (trouble) {
      case HostTrouble.critical:
        notices.error(l10n.monitorNoticeCritical(name), body: monitorOverLimitLines(view, l10n).join(' '));
      case HostTrouble.warning:
        notices.warning(l10n.monitorNoticeWarning(name), body: monitorOverLimitLines(view, l10n).join(' '));
      case HostTrouble.notReached || HostTrouble.signInRefused || HostTrouble.checkFailed:
        // What the host's status says: its first line is what the title
        // says of the host by name, and the rest is why, where there is more.
        final said = monitorPillTooltip(view, l10n, rejectedUser: _signsInAs(c), host: name, port: c.port);
        final lines = said.split('\n');
        notices.error(
          switch (trouble) {
            HostTrouble.notReached => l10n.monitorNoticeNotReached(name),
            HostTrouble.signInRefused => l10n.monitorNoticeSignInRefused(name),
            _ => l10n.monitorNoticeCheckFailed(name),
          },
          body: lines.length > 1 ? lines.skip(1).join(' ') : said,
          details: failedCheckReport(view, said),
        );
    }
  }

  /// Who [c] is signed in to as, as it is shown; null where that is not
  /// known.
  String? _signsInAs(Connection c) {
    for (final identity in _ref.read(identitiesProvider).valueOrNull ?? const <Identity>[]) {
      if (identity.id == c.identityId) return Redactable.username(identity.username).display;
    }
    return null;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

/// Instantiated once at app start (see app.dart) so alerts fire without any
/// monitor screen open, for as long as the app runs.
final monitorAlertEngineProvider =
    StateNotifierProvider<MonitorAlertEngine, void>(
  (ref) => MonitorAlertEngine(ref),
);
