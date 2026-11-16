// The notices Server Monitor raises when a host it watches gets into
// trouble (3.0). Held here: what raises one, how often, and what it says.
//
// (testWidgets for its clock, which the test moves: no widget is drawn.)

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/monitor_alert_providers.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/jump_host_failure.dart';
import 'package:zestssh/services/server_stats_service.dart';
import 'package:zestssh/utils/redactor.dart';

Connection host(String id, {String? label, int port = 22}) {
  final at = DateTime.utc(2026);
  return Connection(
    id: id,
    label: label ?? id,
    host: '$id.example.com',
    port: port,
    identityId: 'key-deploy',
    colorIndex: 0,
    protocol: 'ssh',
    zlibCompression: false,
    keepAliveSeconds: 0,
    envVars: '',
    forwardAgent: false,
    compatibilityMode: false,
    sortOrder: 0,
    sizeTier: 1,
    pinned: false,
    monitored: true,
    createdAt: at,
    updatedAt: at,
  );
}

/// Server Monitor's notices, with everything they are raised from played by
/// the test: the hosts that are watched, how each one's own connection
/// stands, its figures, and the clock.
class Alerts {
  Alerts(this.tester, SharedPreferences prefs) {
    MonitorAlertEngine.clock = () => now;
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      monitoredConnectionsProvider.overrideWith((ref) => _monitored.stream),
      agentlessMonitorPollerProvider.overrideWith((ref) => poller),
      serverStatsProvider.overrideWith(PlayedStats.new),
      connectionHealthProvider.overrideWith((ref) => health),
      activeSessionsProvider.overrideWith((ref) => _Sessions()),
      identitiesProvider.overrideWith((ref) => Stream.value([_backup, _deploy])),
    ]);
    container.listen(identitiesProvider, (_, _) {});
    stats = container.read(serverStatsProvider.notifier) as PlayedStats;
    container.read(monitorAlertEngineProvider.notifier);
  }

  final WidgetTester tester;
  late final ProviderContainer container;
  final poller = PlayedPoller();
  final health = PlayedHealth();
  late final PlayedStats stats;
  final _monitored = StreamController<List<Connection>>.broadcast();

  /// What time it is: moved with the test's clock.
  var now = DateTime(2026, 10, 10, 12);

  /// The hosts that are watched.
  Future<void> watching(List<Connection> hosts) async {
    _monitored.add(hosts);
    await settle();
  }

  /// Lets what was set in motion be looked at (the notices wait a moment, so that a burst of changes is one look).
  Future<void> settle() => tester.pump(const Duration(milliseconds: 400));

  Future<void> pass(Duration time) async {
    now = now.add(time);
    await tester.pump(time);
  }

  /// The host's own connection of Server Monitor is being made.
  Future<void> connecting(String id) => _stands(id, MonitorHostStatus(MonitorHostState.connecting, updatedAt: now));

  /// A check of the host failed with [failedWith].
  Future<void> failed(String id, Object failedWith, {bool signInRefused = false, bool notTriedAgain = false}) =>
      _stands(
        id,
        MonitorHostStatus(MonitorHostState.error,
            failedWith: failedWith, signInRefused: signInRefused, notTriedAgain: notTriedAgain, updatedAt: now),
      );

  /// A check of the host found these figures.
  Future<void> found(String id, {double cpu = 5, double disk = 40}) async {
    stats.commitSshStats(
        id, ServerStats(cpuPercent: cpu, diskPercent: disk, collectedAt: now, source: MetricSource.ssh));
    await _stands(id, MonitorHostStatus(MonitorHostState.ok, updatedAt: now));
  }

  Future<void> _stands(String id, MonitorHostStatus status) async {
    poller.state = {...poller.state, id: status};
    await settle();
  }

  /// A check of whether the host can be reached, where those are on, got no answer.
  Future<void> noAnswer(String id) async {
    health.state = {...health.state, id: HealthCheckResult(status: ConnectionHealth.offline, checkedAt: now)};
    await settle();
  }

  /// Whether Server Monitor tells of trouble at all (its setting).
  Future<void> telling(bool on) =>
      container.read(settingsServiceProvider).setMonitorAlertsEnabled(on);

  /// The notices so far, oldest first: how grave, the title, and what is under it. One that was raised again
  /// while it stood, and was counted on it, is there as often as it was raised.
  List<(NotificationSeverity, String, String?)> get notices => [
        for (final n in _history)
          for (var i = 0; i < n.repeats; i++) (n.severity, n.title, n.body),
      ];

  /// How many times a notice with [title] was raised.
  int told(String title) => notices.where((n) => n.$2 == title).length;

  /// What can be copied from each notice, oldest first.
  List<String?> get details => [for (final n in _history) n.details];

  Iterable<AppNotification> get _history => container.read(notificationCenterProvider).history.reversed;
}

final _backup = Identity(
  id: 'key-backup',
  label: 'backup key',
  username: 'backup',
  authMethod: 'password',
  colorIndex: 0,
  isDefault: false,
  usesAgent: false,
  allowUnattended: false,
  passwordAfterKey: false,
  createdAt: DateTime.utc(2025),
  updatedAt: DateTime.utc(2026),
);

final _deploy = Identity(
  id: 'key-deploy',
  label: 'deploy key',
  username: 'deploy',
  authMethod: 'password',
  colorIndex: 0,
  isDefault: false,
  usesAgent: false,
  allowUnattended: false,
  passwordAfterKey: false,
  createdAt: DateTime.utc(2025),
  updatedAt: DateTime.utc(2026),
);

Future<void> withAlerts(WidgetTester tester, Future<void> Function(Alerts a) body) async {
  SharedPreferences.setMockInitialValues({});
  final a = Alerts(tester, await SharedPreferences.getInstance());
  try {
    await body(a);
  } finally {
    await tester.pump(const Duration(seconds: 30));
    a.container.dispose();
    await a._monitored.close();
    MonitorAlertEngine.clock = DateTime.now;
  }
}

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));

  final web = host('web', label: 'web-01');
  final db = host('db', label: 'db-primary');
  final timedOut = TimeoutException('Connection timed out', const Duration(seconds: 10));

  testWidgets('a host that was fine and can no longer be reached raises one notice, and no more for as long as it '
      'stays that way, however often it is tried again', (tester) => withAlerts(tester, (a) async {
    await a.watching([web]);
    await a.found('web');
    expect(a.notices, isEmpty);

    await a.connecting('web');
    await a.failed('web', timedOut);
    expect(a.notices, hasLength(1));

    // It is tried again, at longer and longer waits, for an hour: each try is a connection that is being made,
    // and then the same failure.
    for (var i = 0; i < 12; i++) {
      await a.pass(const Duration(minutes: 5));
      await a.connecting('web');
      await a.failed('web', timedOut);
    }
    expect(a.notices, hasLength(1), reason: 'it was one more notice every fifteen minutes');
  }));

  testWidgets('a host that goes from a warning to critical raises a notice for that too; one that gets better, '
      'from critical to a warning, raises none', (tester) => withAlerts(tester, (a) async {
    await a.watching([web]);
    await a.found('web');
    await a.found('web', disk: 85);
    await a.found('web', disk: 85);
    expect(a.notices, [
      (NotificationSeverity.warning, 'web-01 needs attention', 'Disk is at 85%, over the 80% warning limit.'),
    ]);
    await a.found('web', disk: 95);
    await a.found('web', disk: 95);
    expect(a.notices, hasLength(2), reason: 'that it got worse was said by nothing');
    expect(a.notices.last,
        (NotificationSeverity.error, 'web-01 is critical', 'Disk is at 95%, over the 90% critical limit.'));
    expect(a.details, [null, null], reason: 'figures over a limit are no error to copy');

    // (Long after the first warning, so that it is not the fifteen minutes that keep this one back.)
    await a.pass(const Duration(minutes: 20));
    await a.found('web', disk: 85);
    await a.found('web', disk: 85);
    expect(a.notices, hasLength(2));
  }));

  testWidgets('what a host is found in first is where it stands, and is not told: a host that was in trouble '
      'before the app started is not news', (tester) => withAlerts(tester, (a) async {
    await a.watching([web, db]);
    // Being connected to, with figures of the last time that are too old to count, and then: critical, and
    // one that cannot be reached.
    await a.connecting('web');
    await a.connecting('db');
    await a.found('web', disk: 95);
    await a.failed('db', timedOut);
    expect(a.notices, isEmpty);
    // What changes from there is told.
    await a.found('db');
    await a.failed('db', timedOut);
    expect(a.notices.map((n) => n.$2), ['db-primary cannot be reached']);
  }));

  testWidgets('a host that cannot be reached: what the check failed with is under its name, with the report to '
      'copy; and where only the checks of whether it can be reached say so, that', (tester) => withAlerts(tester, (a) async {
    await a.watching([web, db]);
    await a.found('web');
    await a.failed('web', timedOut);
    expect(a.notices, [
      (NotificationSeverity.error, 'web-01 cannot be reached', 'Could not reach web-01 within the timeout period.'),
    ]);
    expect(a.details.single, allOf(contains('Where: Server Monitor: a check of a host'), contains('TimeoutException')));

    // A host that Server Monitor has no connection of its own to, which stops answering.
    a.health.state = {'db': HealthCheckResult(status: ConnectionHealth.online, checkedAt: a.now)};
    await a.settle();
    await a.noAnswer('db');
    expect(a.notices.last, (NotificationSeverity.error, 'db-primary cannot be reached', 'No response to ping or SSH.'));
    expect(a.details.last, isNull);

    // A host with no name of its own is told of by its address, and what the check failed with by its port.
    final cache = host('cache', label: '', port: 2222);
    await a.watching([web, db, cache]);
    await a.found('cache');
    await a.failed('cache', const SocketException('Connection refused'));
    expect(a.notices.last, (
      NotificationSeverity.error,
      'cache.example.com cannot be reached',
      'cache.example.com is not accepting connections on port 2222.',
    ));
  }));

  testWidgets('a host that refuses the sign-in, and one whose check fails for another reason, are told of as '
      'that', (tester) => withAlerts(tester, (a) async {
    await a.watching([web, db]);
    await a.found('web');
    await a.found('db');

    final tooMany = SSHAuthAbortError('Connection closed before authentication',
        SSHDisconnectError(2, 'Too many authentication failures', authentic: true));
    await a.failed('web', tooMany, signInRefused: true);
    expect(a.notices.single, (
      NotificationSeverity.error,
      'web-01 refused the sign-in',
      'Rejected user deploy. The host ended the connection. Its reason: Too many authentication failures',
    ));

    await a.failed(
        'db',
        JumpHostFailure(
            label: 'vpn-gateway',
            host: '192.168.10.23',
            port: 22,
            stage: JumpStage.onward,
            cause: SSHChannelOpenError(1, 'open failed'),
            onward: 'db-primary'));
    expect(a.notices.last, (
      NotificationSeverity.error,
      'db-primary can no longer be checked',
      'The jump host vpn-gateway does not pass connections on to db-primary: forwarding is turned off there, or not '
          'allowed for this account or key.',
    ));
    expect(a.details.last, contains('SSHChannelOpenError'));
  }));

  testWidgets('a host that no timer tries again: its notice says so, after why, with how it is tried again',
      (tester) => withAlerts(tester, (a) async {
    await a.watching([web, db]);
    await a.found('web');
    await a.found('db');

    await a.failed('web', SSHAuthFailError('All authentication methods failed'),
        signInRefused: true, notTriedAgain: true);
    expect(a.notices.single, (
      NotificationSeverity.error,
      'web-01 refused the sign-in',
      'Rejected user deploy. It is not tried again by itself: every try would end the same way. Refresh to try '
          'again.',
    ));

    await a.failed(
        'db',
        SSHAuthAbortError('Connection closed before authentication',
            SSHKexGroupError('of 1024 bits', bits: 1024, shortestTaken: 2048)),
        notTriedAgain: true);
    final (severity, title, body) = a.notices.last;
    expect((severity, title), (NotificationSeverity.error, 'db-primary can no longer be checked'));
    expect(body,
        startsWith('This host offers only an outdated key exchange (a group of 1024 bits; none under 2048 bits is taken)'));
    expect(body, endsWith(' It is not tried again by itself: every try would end the same way. Refresh to try again.'));
    expect(a.details.last, contains('SSHKexGroupError'));
  }));

  testWidgets('a host that swings in and out of a trouble is told of once in fifteen minutes; a trouble that is '
      'another one is told at once', (tester) => withAlerts(tester, (a) async {
    await a.watching([web]);
    await a.found('web');
    await a.failed('web', timedOut);
    await a.found('web');
    await a.pass(const Duration(minutes: 5));
    await a.failed('web', timedOut);
    expect(a.notices, hasLength(1));
    // Another trouble, within the fifteen minutes.
    await a.failed('web', SSHAuthFailError('All authentication methods failed'), signInRefused: true);
    expect((a.told('web-01 cannot be reached'), a.told('web-01 refused the sign-in')), (1, 1));
    // The first one again, once the fifteen minutes are over.
    await a.found('web');
    await a.pass(const Duration(minutes: 11));
    await a.failed('web', timedOut);
    expect((a.told('web-01 cannot be reached'), a.told('web-01 refused the sign-in')), (2, 1));
  }));

  testWidgets('figures that have grown too old, and a check that is under way, are no recovery: a host that was '
      'critical and is found critical again is not told of twice', (tester) => withAlerts(tester, (a) async {
    await a.watching([web]);
    await a.found('web');
    await a.found('web', disk: 95);
    await a.found('web', disk: 95);
    expect(a.notices, hasLength(1));
    // Nothing is checked for an hour (the app was away): its figures are too old to say anything.
    await a.pass(const Duration(hours: 1));
    await a.connecting('web');
    await a.found('web', disk: 95);
    await a.found('web', disk: 95);
    expect(a.notices, hasLength(1));
  }));

  testWidgets('with the notices turned off nothing is told, and what happened meanwhile is not told when they are '
      'turned on again', (tester) => withAlerts(tester, (a) async {
    await a.telling(false);
    await a.watching([web, db]);
    await a.found('web');
    await a.found('db');
    await a.failed('web', timedOut);
    expect(a.notices, isEmpty);
    await a.telling(true);
    // What was found while they were off is where each host stands. One that was fine then and fails now is
    // news, also where that is the first thing to happen once they are on.
    await a.failed('db', timedOut);
    expect(a.notices.map((n) => n.$2), ['db-primary cannot be reached']);
    await a.connecting('web');
    await a.failed('web', timedOut);
    expect(a.notices.map((n) => n.$2), ['db-primary cannot be reached'], reason: 'web-01 could not be reached before');
    await a.found('web');
    await a.pass(const Duration(minutes: 1));
    await a.failed('web', timedOut);
    expect(a.notices.map((n) => n.$2), ['db-primary cannot be reached', 'web-01 cannot be reached'],
        reason: 'and what happens from here is told');
  }));

  testWidgets('while recording, the names in a notice are masked', (tester) => withAlerts(tester, (a) async {
    Redactor.instance
      ..clearNames()
      ..enabled = true
      ..level = RedactLevel.layout
      ..registerNames(['web-01', 'db-primary', 'vpn-gateway']);
    addTearDown(() => Redactor.instance
      ..clearNames()
      ..enabled = false);
    final cache = host('cache', label: 'cache-01');
    await a.watching([web, db, cache]);
    await a.found('web');
    await a.found('db');
    await a.found('cache');
    await a.failed('web', timedOut);
    await a.failed(
        'db',
        JumpHostFailure(
            label: 'vpn-gateway',
            host: '192.168.10.23',
            port: 22,
            stage: JumpStage.onward,
            cause: SSHChannelOpenError(1, 'open failed'),
            onward: 'db-primary'));
    await a.failed('cache', SSHAuthFailError('All authentication methods failed'), signInRefused: true);
    expect(a.notices, hasLength(3));
    expect(a.notices.last.$3, startsWith('Rejected user '), reason: 'who was refused is said, and masked');
    for (final (_, title, body) in a.notices) {
      for (final name in ['web-01', 'db-primary', 'vpn-gateway', 'deploy']) {
        expect('$title $body', isNot(contains(name)));
      }
    }
  }));

  test('the setting for the notices says what they are raised for, in every language and in the search of the '
      'settings', () {
    expect(en.notifPrefsMonitorAlertsDesc,
        'When a monitored host goes critical or over a warning limit, or can no longer be checked');
    expect(en.notificationsResourceAlertsDesc, 'Notify ${en.notifPrefsMonitorAlertsDesc.replaceFirst('When', 'when')}');
    // (The search of the settings on a computer finds a setting by the setting's own words.)
    final search = File('lib/ui/screens/desktop/widgets/settings_inline_view.dart').readAsStringSync();
    expect(search, contains('(l) => l.notifPrefsMonitorAlerts, (l) => l.notifPrefsMonitorAlertsDesc'));
    for (final locale in AppLocalizations.supportedLocales) {
      if (locale.languageCode == 'en') continue;
      final l = lookupAppLocalizations(locale);
      expect(l.notifPrefsMonitorAlertsDesc, isNot(en.notifPrefsMonitorAlertsDesc), reason: '$locale');
      expect(l.notificationsResourceAlertsDesc, isNot(en.notificationsResourceAlertsDesc), reason: '$locale');
      // Three things, as before, of which the last is no longer only a host that is offline.
      expect(l.notifPrefsMonitorAlertsDesc.length, greaterThan(20), reason: '$locale');
    }
  });

  test('each notice names its host in every language', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      final titles = [
        l.monitorNoticeCritical('web-01'),
        l.monitorNoticeWarning('web-01'),
        l.monitorNoticeNotReached('web-01'),
        l.monitorNoticeSignInRefused('web-01'),
        l.monitorNoticeCheckFailed('web-01'),
      ];
      expect(titles.toSet(), hasLength(5), reason: '$locale: each its own');
      for (final title in titles) {
        expect(title, contains('web-01'), reason: '$locale');
      }
      if (locale.languageCode == 'en') continue;
      final english = [
        en.monitorNoticeCritical('web-01'),
        en.monitorNoticeWarning('web-01'),
        en.monitorNoticeNotReached('web-01'),
        en.monitorNoticeSignInRefused('web-01'),
        en.monitorNoticeCheckFailed('web-01'),
      ];
      for (var i = 0; i < titles.length; i++) {
        expect(titles[i], isNot(english[i]), reason: '$locale');
      }
    }
  });
}

/// Server Monitor's own connections, as the test says they stand.
class PlayedPoller extends StateNotifier<Map<String, MonitorHostStatus>> implements AgentlessMonitorPoller {
  PlayedPoller() : super(const {});

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// The figures of hosts, as the test gives them: nothing is asked of any host.
class PlayedStats extends ServerStatsNotifier {
  PlayedStats(super.ref);

  @override
  Future<void> refreshAll() async {}

  @override
  Future<void> refreshOne(String connectionId) async {}

  @override
  void startAutoRefresh(int intervalSeconds) {}
}

/// No checks of whether hosts can be reached.
class PlayedHealth extends StateNotifier<Map<String, HealthCheckResult>> implements ConnectionHealthNotifier {
  PlayedHealth() : super(const {});

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// No sessions are open.
class _Sessions extends StateNotifier<Map<String, SessionState>> implements ActiveSessionsNotifier {
  _Sessions() : super(const {});

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
