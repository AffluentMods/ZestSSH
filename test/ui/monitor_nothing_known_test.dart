import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/monitoring/monitor_state_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/ui/screens/monitoring/server_monitor_screen.dart';

/// The phone's Server Monitor, and a host of which nothing is known (hosts
/// left out of monitoring showed "Checking..." though only one
/// host was picked for it).
///
/// The card of such a host said "Checking" beside a turning wheel, whatever
/// was or was not being done about the host. Since 2.3.0 the checks of
/// whether hosts can be reached are off unless their person turns them on,
/// so the wheel turned for good on every host that was not monitored: to
/// somebody who had taken hosts out of monitoring, it looked as if those
/// were being checked all the same. Nothing was sent to them.
///
/// Now "Checking" is said while a check is under way, and otherwise what is
/// so: the host is not monitored, or it is and nothing has run for it yet.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  setUp(() => L10nGlobal.update(en));

  test('what is so of a host of which nothing is known: checking only while something checks', () {
    for (final monitored in [true, false]) {
      // A reading under way, or the checks of whether hosts can be reached are on: checking, monitored or not.
      for (final (reading, checks) in [(true, false), (false, true), (true, true)]) {
        expect(
          nothingKnownOfHost(monitored: monitored, readingUnderWay: reading, reachabilityChecksOn: checks),
          NothingKnownOfHost.checking,
          reason: 'monitored: $monitored, a reading: $reading, the checks: $checks',
        );
      }
    }
    // Neither: nothing is being done about the host, and it says which it is.
    expect(
      nothingKnownOfHost(monitored: false, readingUnderWay: false, reachabilityChecksOn: false),
      NothingKnownOfHost.notMonitored,
    );
    expect(
      nothingKnownOfHost(monitored: true, readingUnderWay: false, reachabilityChecksOn: false),
      NothingKnownOfHost.neverChecked,
    );
  });

  /// Two hosts, web-01 monitored and db-primary not, with no reading of
  /// either.
  Future<AppDatabase> seeded() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final now = DateTime(2026, 1, 1);
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: 'key-deploy', label: 'deploy key', username: 'deploy', authMethod: 'password', createdAt: now));
    for (final (id, label, host, monitored) in [
      ('web', 'web-01', '192.168.10.11', true),
      ('db', 'db-primary', '192.168.10.31', false),
    ]) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: label,
            host: host,
            identityId: const Value('key-deploy'),
            monitored: Value(monitored),
            createdAt: now,
            updatedAt: now,
          ));
    }
    return db;
  }

  // Where a check of whether a host can be reached would go, in these tests: nowhere. What asked is kept.
  final probed = <String>[];

  /// The phone's screen over [db], with Server Monitor on, what its poller
  /// says of each host ([polled]), and the checks of whether hosts can be
  /// reached off, as they are unless their person turns them on, or on
  /// ([checksOn]).
  Future<void> show(
    WidgetTester tester,
    AppDatabase db,
    Map<String, MonitorHostStatus> polled, {
    bool checksOn = false,
  }) async {
    probed.clear();
    SharedPreferences.setMockInitialValues({
      'agentless_monitor_enabled': true,
      if (checksOn) 'reachability_checks_enabled': true,
    });
    final prefs = await SharedPreferences.getInstance();
    const size = Size(420, 1200);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        serverStatsProvider.overrideWith((ref) => _NoStats(ref)),
        agentlessMonitorPollerProvider.overrideWith((ref) => _Poller(polled)),
        connectionHealthProvider.overrideWith((ref) => ConnectionHealthNotifier(probe: (host, port) async {
              probed.add('$host:$port');
              return null;
            })),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: SizedBox(width: size.width, height: size.height, child: const ServerMonitorScreen())),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> finish(WidgetTester tester, AppDatabase db) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    await db.close();
  }

  Finder cardOf(String label) => find.ancestor(of: find.text(label), matching: find.byType(Card));
  Finder inCard(String label, Finder what) => find.descendant(of: cardOf(label), matching: what);

  testWidgets('a host that is not monitored says so, with no turning wheel; the one being read says Checking',
      (tester) async {
    final db = await seeded();
    await show(tester, db, {
      'web': MonitorHostStatus(MonitorHostState.connecting, updatedAt: DateTime.now()),
    });
    expect(cardOf('web-01'), findsOneWidget);
    expect(cardOf('db-primary'), findsOneWidget);

    // The monitored host, which Server Monitor is connecting to: Checking, and a wheel.
    expect(inCard('web-01', find.text(en.monitorChecking)), findsOneWidget);
    expect(inCard('web-01', find.byType(CircularProgressIndicator)), findsOneWidget);

    // The host that was taken out of monitoring: nothing checks it, and its card says that.
    expect(inCard('db-primary', find.text(en.monitorChecking)), findsNothing);
    expect(inCard('db-primary', find.byType(CircularProgressIndicator)), findsNothing);
    expect(inCard('db-primary', find.byKey(const ValueKey('monitor-card-not-monitored'))), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('monitor-card-not-monitored'))).data,
      en.monitorStatusNotEligible,
    );
    expect(en.monitorStatusNotEligible, 'Not monitored');
    await finish(tester, db);
  });

  testWidgets('a monitored host that nothing has run for yet says that, with no turning wheel', (tester) async {
    final db = await seeded();
    await show(tester, db, const {});
    expect(inCard('web-01', find.text(en.monitorChecking)), findsNothing);
    expect(inCard('web-01', find.byType(CircularProgressIndicator)), findsNothing);
    expect(inCard('web-01', find.byKey(const ValueKey('monitor-card-never-checked'))), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('monitor-card-never-checked'))).data,
      en.zestMonitorTipNeverChecked,
    );
    // And the other is not monitored, as before.
    expect(inCard('db-primary', find.byKey(const ValueKey('monitor-card-not-monitored'))), findsOneWidget);
    expect(find.text(en.monitorChecking), findsNothing);
    expect(probed, isEmpty, reason: 'with the checks off nothing is sent to a host for this screen');
    await finish(tester, db);
  });

  testWidgets('with the checks of whether hosts can be reached turned on, a host whose answer has not come says '
      'Checking, monitored or not', (tester) async {
    final db = await seeded();
    await show(tester, db, const {}, checksOn: true);
    for (final host in ['web-01', 'db-primary']) {
      expect(inCard(host, find.text(en.monitorChecking)), findsOneWidget, reason: host);
      expect(inCard(host, find.byType(CircularProgressIndicator)), findsOneWidget, reason: host);
    }
    expect(find.byKey(const ValueKey('monitor-card-not-monitored')), findsNothing);
    expect(find.byKey(const ValueKey('monitor-card-never-checked')), findsNothing);
    await finish(tester, db);
  });
}

/// Stats that are never fetched.
class _NoStats extends ServerStatsNotifier {
  _NoStats(super.ref);

  @override
  Future<void> refreshAll() async {}

  @override
  Future<void> refreshOne(String connectionId) async {}

  @override
  void startAutoRefresh(int intervalSeconds) {}
}

/// The poller's word of each host, with nothing behind it.
class _Poller extends StateNotifier<Map<String, MonitorHostStatus>> implements AgentlessMonitorPoller {
  _Poller(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
