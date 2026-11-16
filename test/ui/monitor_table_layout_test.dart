import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/monitoring/monitor_evaluation.dart';
import 'package:zestssh/features/monitoring/monitor_thresholds.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/services/server_stats_service.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/desktop/widgets/monitor_table_view.dart';

import '../helpers/desktop_mouse.dart';
import '../helpers/monitor_table_fixture.dart';

/// The computer's Server monitor table, built as designed:
/// problems first, the filters, "Watch this host", the warning
/// tick on the bars, the last 24 checks from the stored checks, and what a
/// row says of a host without swap, one read only partly, one that asks for
/// a restart and one with no saved login.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));

  late AppDatabase db;

  Future<ProviderContainer> pump(WidgetTester tester, {bool pro = true}) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fleet = MonitorFleet();
    db = await fleet.database();
    final prefs = await fleet.preferences();
    await tester.pumpWidget(fleet.app(fleet.overrides(db, prefs, pro: pro), const MonitorTableView()));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    return ProviderScope.containerOf(tester.element(find.byType(MonitorTableView)));
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    await db.close();
  }

  /// The hosts in the order the table shows them, top to bottom.
  List<String> order(WidgetTester tester) {
    final names = [for (final h in MonitorFleet.hosts.values) h.$1];
    final shown = names.where((n) => find.text(n).evaluate().isNotEmpty).toList()
      ..sort((a, b) => tester.getTopLeft(find.text(a)).dy.compareTo(tester.getTopLeft(find.text(b)).dy));
    return shown;
  }

  Finder inRow(String id, Finder f) => find.descendant(of: find.byKey(ValueKey(id)), matching: f);

  desktopTest('it sorts problems first: over a limit, then cannot be checked, then a restart asked for, then the rest',
      (tester) async {
    await pump(tester);
    expect(tester.takeException(), isNull);
    expect(order(tester), [
      'hypervisor-a', // RAM high
      'build-runner', 'cache-01', 'vpn-gateway', // cannot be checked, by name
      'web-02', // asks for a restart
      'db-primary', 'edge-router', 'hypervisor-b', 'log-store', 'mac-studio', 'monitoring', 'web-01',
    ]);
    expect(inRow('hva', find.text(en.monitorTableMetricHigh(en.monitorRam))), findsOneWidget);
    expect(inRow('mon', find.text(en.monitorTableOk)), findsOneWidget);
    expect(monitorProblemRank(MonitorBucket.cantCheck), lessThan(monitorProblemRank(MonitorBucket.healthy)));
    await finish(tester);
  });

  desktopTest('the filters show their counts and keep only their hosts', (tester) async {
    await pump(tester);
    String segment(String key) => tester
        .widgetList<Text>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)))
        .map((t) => t.data)
        .join(' ');
    expect(segment('monitor-filter-all'), '${en.monitorTableFilterAll} 12');
    expect(segment('monitor-filter-warning'), '${en.monitorBucketWarning} 1');
    expect(segment('monitor-filter-cantCheck'), '${en.zestMonitorBucketCantCheck} 3');
    // Nothing is critical: no Critical segment.
    expect(find.byKey(const ValueKey('monitor-filter-critical')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('monitor-filter-warning')));
    await tester.pump();
    expect(order(tester), ['hypervisor-a']);

    await tester.tap(find.byKey(const ValueKey('monitor-filter-cantCheck')));
    await tester.pump();
    expect(order(tester), ['build-runner', 'cache-01', 'vpn-gateway']);

    await tester.tap(find.byKey(const ValueKey('monitor-filter-all')));
    await tester.pump();
    expect(order(tester), hasLength(12));
    await finish(tester);
  });

  desktopTest('"Watch this host" adds a host that is not watched to the background checks', (tester) async {
    await pump(tester);
    expect(inRow('build', find.text(en.monitorTableNotWatched)), findsOneWidget);
    Future<bool> watched() async => (await (db.select(db.connections)..where((c) => c.id.equals('build'))).getSingle()).monitored;
    expect(await tester.runAsync(watched), isFalse);
    await tester.tap(find.byKey(const ValueKey('monitor-action-build')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(await tester.runAsync(watched), isTrue);
    await finish(tester);
  });

  desktopTest('on the free plan, with as many hosts watched as it checks, the button says so', (tester) async {
    final container = await pump(tester, pro: false);
    expect(container.read(isProProvider), isFalse);
    final action = find.byKey(const ValueKey('monitor-action-build'));
    expect(find.descendant(of: action, matching: find.text(en.monitorTableUpgradeToWatch)), findsOneWidget);
    final tips = tester.widgetList<Tooltip>(find.ancestor(of: find.text(en.monitorTableUpgradeToWatch).first, matching: find.byType(Tooltip)));
    expect(tips.map((t) => t.message), contains(en.monitorAgentlessLimitReached(freeMonitorLimit)));
    // The header counts the hosts the plan checks, not every watched one.
    expect(find.text(en.monitorTableBackgroundOn(freeMonitorLimit)), findsOneWidget);
    await finish(tester);
  });

  desktopTest('a gauge has a tick where its warning starts, and its value turns amber over it', (tester) async {
    await pump(tester);
    expect(find.text(en.monitorTableBackgroundOn(10)), findsOneWidget);
    // hypervisor-a's RAM, 89%, over the 85% warning.
    final bar = tester.getRect(inRow('hva', find.byKey(const ValueKey('monitor-bar-ram'))));
    final tick = tester.getRect(inRow('hva', find.byKey(const ValueKey('monitor-tick-ram'))));
    expect(tick.left - bar.left, closeTo(0.85 * (bar.width - 1), 0.5));
    final cpuTick = tester.getRect(inRow('hva', find.byKey(const ValueKey('monitor-tick-cpu'))));
    final cpuBar = tester.getRect(inRow('hva', find.byKey(const ValueKey('monitor-bar-cpu'))));
    expect(cpuTick.left - cpuBar.left, closeTo(0.90 * (cpuBar.width - 1), 0.5));
    Color? colour(String id, String metric) =>
        tester.widget<Text>(inRow(id, find.byKey(ValueKey('monitor-value-$metric')))).style?.color;
    expect(colour('hva', 'ram'), ZestTokens.statusWarning);
    expect(colour('hvb', 'ram'), isNot(ZestTokens.statusWarning)); // 71%, under it
    expect(find.text(en.monitorTableWarnAt('90', '85', '85')), findsOneWidget);
    await finish(tester);
  });

  test('the last 24 checks come from the stored checks, newest on the right', () {
    final fleet = MonitorFleet();
    final limits = {...kDefaultThresholds}..[MonitorMetric.ram] = const MetricThreshold(85, 95);
    final hva = monitorCheckMarks(fleet.samplesFor('hva'), limits);
    expect(hva, hasLength(24));
    expect(hva.take(18), everyElement(MonitorCheckMark.ok));
    expect(hva.skip(18), everyElement(MonitorCheckMark.warning));
    // Six failed checks: no data, after 18 slots no check has filled.
    final vpn = monitorCheckMarks(fleet.samplesFor('vpn'), limits);
    expect(vpn.take(18), everyElement(MonitorCheckMark.empty));
    expect(vpn.skip(18), everyElement(MonitorCheckMark.noData));
    expect(monitorCheckMarks(const [], limits), everyElement(MonitorCheckMark.empty));
  });

  desktopTest('the bars of a row show its stored checks', (tester) async {
    await pump(tester);
    int count(String id, String mark) => inRow(
            id,
            find.byWidgetPredicate((w) =>
                w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('monitor-check-') &&
                (w.key! as ValueKey<String>).value.endsWith('-$mark')))
        .evaluate()
        .length;
    expect(count('hva', 'warning'), 6);
    expect(count('hva', 'ok'), 18);
    expect(count('build', 'empty'), 24);
    expect(count('vpn', 'noData'), 6);
    await finish(tester);
  });

  desktopTest('a row says "none" for no swap, what a partly read host gives, a restart asked for, and a missing login',
      (tester) async {
    await pump(tester);
    expect(inRow('mon', find.byKey(const ValueKey('monitor-swap-none'))), findsOneWidget);
    // mac-studio's swap was never read (no /proc): nothing, not "none".
    expect(inRow('mac', find.byKey(const ValueKey('monitor-swap-none'))), findsNothing);
    expect(inRow('edge', find.text(en.monitorTablePartial('FreeBSD', en.monitorTableListAnd('disk', 'ping')))), findsOneWidget);
    expect(inRow('web2', find.byKey(const ValueKey('monitor-reboot-web2'))), findsOneWidget);
    expect(inRow('mon', find.text(en.hostRebootNeeded)), findsNothing);
    expect(inRow('vpn', find.text(en.monitorTableNoLogin)), findsOneWidget);
    expect(inRow('vpn', find.text(en.monitorTableAddKey)), findsOneWidget);
    // Updates where the host counts them, nothing where it does not.
    expect(inRow('web2', find.text('23')), findsOneWidget);
    await finish(tester);
  });

  test('the partial-read note names what was read, and only where processor and memory were not', () {
    final at = DateTime(2026, 1, 1);
    expect(
        monitorPartialReadNote(
            ServerStats(collectedAt: at, diskPercent: 3, pingMs: 1, osName: 'FreeBSD 14.1-RELEASE'), en),
        'FreeBSD: disk and ping only');
    expect(monitorPartialReadNote(ServerStats(collectedAt: at, diskPercent: 3), en), 'Disk only');
    expect(monitorPartialReadNote(ServerStats(collectedAt: at, cpuPercent: 3, diskPercent: 3), en), isNull);
    expect(monitorPartialReadNote(ServerStats(collectedAt: at), en), isNull);
  });
}
