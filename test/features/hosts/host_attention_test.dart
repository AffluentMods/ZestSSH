import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/host_attention.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/features/monitoring/monitor_evaluation.dart';
import 'package:zestssh/features/monitoring/monitor_thresholds.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/generated/app_localizations_en.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';

/// The Hosts page's health chips and "need attention" count come from Server
/// Monitor's own verdict, and the count is a toggle that filters the grid.
void main() {
  final l10n = AppLocalizationsEn();

  MetricEval eval(MonitorMetric m, double v, MetricSeverity s) =>
      MetricEval(metric: m, value: v, warn: 80, crit: 90, severity: s);

  MonitorHostView view(MonitorBucket b,
          {List<MetricEval> metrics = const [], CantCheckReason? reason}) =>
      MonitorHostView(bucket: b, metrics: metrics, cantCheckReason: reason);

  group('chips', () {
    test('a host Server Monitor does not watch shows none', () {
      expect(healthChipsFor(null, l10n), isEmpty);
    });

    test('a healthy host shows none', () {
      expect(
          healthChipsFor(
              view(MonitorBucket.healthy, metrics: [
                eval(MonitorMetric.cpu, 20, MetricSeverity.healthy),
              ]),
              l10n),
          isEmpty);
    });

    test('warnings and criticals only, worst first, at most two', () {
      final chips = healthChipsFor(
          view(MonitorBucket.critical, metrics: [
            eval(MonitorMetric.disk, 82, MetricSeverity.warning),
            eval(MonitorMetric.cpu, 100, MetricSeverity.critical),
            eval(MonitorMetric.ram, 85, MetricSeverity.warning),
            eval(MonitorMetric.swap, 10, MetricSeverity.healthy),
          ]),
          l10n);
      expect(chips.length, 2);
      expect(chips.first.label, 'CPU 100%');
      expect(chips.first.critical, isTrue);
      expect(chips[1].critical, isFalse);
      expect(chips.map((c) => c.label), isNot(contains('Swap 10%')));
    });

    test('a watched host that cannot be reached says so', () {
      final chips = healthChipsFor(
          view(MonitorBucket.cantCheck, reason: CantCheckReason.unreachable),
          l10n);
      expect(chips.single.label, 'Unreachable');
      expect(chips.single.critical, isTrue);
      expect(chips.single.tooltip, 'No response to ping or SSH.');
    });

    test('and where a check of it failed on the way to it, what the check failed with', () {
      L10nGlobal.update(l10n);
      final chips = healthChipsFor(
        MonitorHostView(
          bucket: MonitorBucket.cantCheck,
          metrics: const [],
          cantCheckReason: CantCheckReason.unreachable,
          failedWith: TimeoutException('Connection timed out', const Duration(seconds: 10)),
        ),
        l10n,
      );
      expect(chips.single.label, 'Unreachable');
      expect(chips.single.tooltip,
          'The host could not be reached.\nCould not reach the server within the timeout period.');
    });

    test('other reasons it cannot check are not problems with the host', () {
      for (final r in [
        CantCheckReason.connecting,
        CantCheckReason.noCredentials,
        CantCheckReason.neverChecked,
        CantCheckReason.stale,
      ]) {
        final v = view(MonitorBucket.cantCheck, reason: r);
        expect(healthChipsFor(v, l10n), isEmpty, reason: r.name);
        expect(hostNeedsAttention(v, changedHostKey: false), isFalse,
            reason: r.name);
      }
    });
  });

  group('needs attention', () {
    test('a changed host key always does', () {
      expect(hostNeedsAttention(null, changedHostKey: true), isTrue);
    });
    test('critical, warning and unreachable do; healthy does not', () {
      expect(
          hostNeedsAttention(view(MonitorBucket.critical),
              changedHostKey: false),
          isTrue);
      expect(
          hostNeedsAttention(view(MonitorBucket.warning), changedHostKey: false),
          isTrue);
      expect(
          hostNeedsAttention(
              view(MonitorBucket.cantCheck,
                  reason: CantCheckReason.unreachable),
              changedHostKey: false),
          isTrue);
      expect(
          hostNeedsAttention(view(MonitorBucket.healthy), changedHostKey: false),
          isFalse);
      expect(hostNeedsAttention(null, changedHostKey: false), isFalse);
    });
  });

  testWidgets('the header counts them and its toggle shows only them',
      (tester) async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'),
        (call) async => ['wifi']);
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final at = DateTime.now().millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues({
      'cached_server_stats': jsonEncode({
        'c0': {
          'cpuPercent': 100.0,
          'ramUsedMB': 1000,
          'ramTotalMB': 8192,
          'diskPercent': 40.0,
          'collectedAt': at,
          'source': 'ssh',
        },
        'c1': {
          'cpuPercent': 10.0,
          'ramUsedMB': 1000,
          'ramTotalMB': 8192,
          'diskPercent': 40.0,
          'collectedAt': at,
          'source': 'ssh',
        },
      }),
    });
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime(2026, 9, 24);
    const hosts = ['Busy', 'Calm', 'Unwatched'];
    for (var i = 0; i < hosts.length; i++) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'c$i',
            label: hosts[i],
            host: '10.0.0.$i',
            port: const Value(22),
            monitored: Value(i < 2),
            createdAt: now,
            updatedAt: now,
          ));
    }
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      healthChecksEnabledProvider.overrideWith((ref) => false),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: HostsHomePage(onConnectTo: (_) {}, onOpenTmux: (_) {}),
        ),
      ),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }

    // On the host itself; no count in the header or on its group's tile.
    // Filter shows only those.
    expect(find.byKey(const ValueKey('hosts-attention-toggle')), findsNothing);
    expect(find.text('1 needs attention'), findsNothing);
    expect(find.text('CPU 100%'), findsOneWidget);
    for (final h in hosts) {
      expect(find.text(h), findsWidgets, reason: h);
    }
    Future<void> toggleInFilter() async {
      await tester.tap(find.byKey(const ValueKey('hosts-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('filter-attention')));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    }

    await toggleInFilter();
    expect(find.text('Busy'), findsWidgets);
    expect(find.text('Calm'), findsNothing);
    expect(find.text('Unwatched'), findsNothing);
    await toggleInFilter();
    expect(find.text('Calm'), findsWidgets);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  });

  // One rule of when a reading is too old, as Server monitor's pages have it
  // (monitorStaleAfter: the background check's interval, 5 minutes, or a
  // session's refresh, whichever is longer): a reading of 4 minutes ago is
  // current on the Hosts page too. Its chips counted from the refresh alone
  // (90 seconds), and called a host fine that the Monitor page said was not.
  testWidgets('a reading the Monitor page calls current is current on the Hosts page', (tester) async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final at = DateTime.now().subtract(const Duration(minutes: 4)).millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues({
      'cached_server_stats': jsonEncode({
        'c0': {
          'cpuPercent': 100.0,
          'ramUsedMB': 1000,
          'ramTotalMB': 8192,
          'diskPercent': 40.0,
          'collectedAt': at,
          'source': 'ssh',
        },
      }),
    });
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime(2026, 9, 24);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'c0',
          label: 'Busy',
          host: '10.0.0.1',
          monitored: const Value(true),
          createdAt: now,
          updatedAt: now,
        ));
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      healthChecksEnabledProvider.overrideWith((ref) => false),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: HostsHomePage(onConnectTo: (_) {})),
      ),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(c.read(monitoredHostViewsProvider)['c0']!.statsStale, isFalse);
    expect(find.text('CPU 100%'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  });
}
