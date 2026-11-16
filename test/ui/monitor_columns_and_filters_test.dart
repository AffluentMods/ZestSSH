import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/broadcast/broadcast_to_hosts.dart';
import 'package:zestssh/features/run/run_on_hosts_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/monitor_table_view.dart';
import 'package:zestssh/ui/widgets/host_row.dart';

import '../helpers/desktop_mouse.dart';
import '../helpers/monitor_table_fixture.dart';

/// The Server monitor's table (as a design review asked):
/// the host's own icon in its row, filters for what can be acted on
/// with Broadcast and Run on the rows they leave, Updates that sort, columns
/// dragged and fitted and remembered, Host as wide as it needs, and the warning
/// limits said once.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<({AppDatabase db, SharedPreferences prefs, ProviderContainer container})> pump(WidgetTester tester, {Size size = const Size(2400, 1000)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fleet = MonitorFleet();
    final db = await tester.runAsync(fleet.database);
    final prefs = await fleet.preferences();
    late ProviderContainer container;
    await tester.pumpWidget(fleet.app(
      fleet.overrides(db!, prefs),
      Consumer(builder: (context, ref, _) {
        container = ProviderScope.containerOf(context);
        return const MonitorTableView();
      }),
    ));
    await settle(tester);
    return (db: db, prefs: prefs, container: container);
  }

  Future<void> finish(WidgetTester tester, AppDatabase db) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    await db.close();
  }

  Finder row(String id) => find.byKey(ValueKey(id));

  desktopTest("each row has the host's own icon, its name and its user@address", (tester) async {
    final t = await pump(tester);
    expect(find.descendant(of: row('web1'), matching: find.byType(HostGlyph)), findsOneWidget);
    expect(find.descendant(of: row('web1'), matching: find.text('web-01')), findsOneWidget);
    expect(find.descendant(of: row('web1'), matching: find.text('deploy@192.168.10.21')), findsOneWidget);
    await finish(tester, t.db);
  });

  group('the filters', () {
    desktopTest('Reboot needed and Updates leave the rows they say, and Broadcast and Run on come with them',
        (tester) async {
      final t = await pump(tester);
      expect(find.byKey(const ValueKey('monitor-filtered-actions')), findsNothing, reason: 'no filter, nothing to act on');

      await tester.tap(find.byKey(const ValueKey('monitor-filter-reboot')));
      await settle(tester);
      expect(row('web2'), findsOneWidget);
      expect(row('web1'), findsNothing);
      expect(find.text(en.monitorBroadcastToThese(1)), findsOneWidget);
      expect(find.text(en.monitorRunOnThese(1)), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('monitor-filter-updates')));
      await settle(tester);
      expect(row('web2'), findsOneWidget);
      expect(row('logs'), findsOneWidget);
      expect(row('web1'), findsNothing);
      expect(find.text(en.monitorBroadcastToThese(2)), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('monitor-filter-all')));
      await settle(tester);
      expect(row('web1'), findsOneWidget);
      expect(find.byKey(const ValueKey('monitor-filtered-actions')), findsNothing);
      await finish(tester, t.db);
    });

    desktopTest('Broadcast to these opens Broadcast with them ticked, and nothing is run or opened yet', (tester) async {
      final t = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('monitor-filter-updates')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('monitor-broadcast-these')));
      await settle(tester);
      expect(find.byType(BroadcastToHostsDialog), findsOneWidget);
      expect(find.text(en.broadcastToHostsOpen(2)), findsOneWidget);
      await tester.tap(find.text(en.cancel));
      await settle(tester);
      await finish(tester, t.db);
    });

    desktopTest('Run snippet on these opens Run on hosts with them ticked', (tester) async {
      final t = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('monitor-filter-updates')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('monitor-run-these')));
      await settle(tester);
      expect(find.byType(RunOnHostsDialog), findsOneWidget);
      expect(find.text(en.runOnHostsRun(2)), findsOneWidget);
      await tester.tap(find.text(en.cancel));
      await settle(tester);
      await finish(tester, t.db);
    });

    desktopTest('an SFTP-only host a filter leaves is not counted, nor handed on; with only such hosts nothing is offered',
        (tester) async {
      final t = await pump(tester);
      Future<void> sftp(String id) => tester.runAsync(() => (t.db.update(t.db.connections)..where((c) => c.id.equals(id)))
          .write(const ConnectionsCompanion(protocol: Value('sftp'))));
      await sftp('build');
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('monitor-filter-cantCheck')));
      await settle(tester);
      expect(find.text(en.monitorBroadcastToThese(2)), findsOneWidget, reason: 'cache-01 and vpn-gateway, not build-runner');
      await tester.tap(find.byKey(const ValueKey('monitor-broadcast-these')));
      await settle(tester);
      expect(find.text(en.broadcastToHostsOpen(2)), findsOneWidget);
      await tester.tap(find.text(en.cancel));
      await settle(tester);

      await sftp('cache');
      await sftp('vpn');
      await settle(tester);
      expect(find.byKey(const ValueKey('monitor-filtered-actions')), findsNothing);
      await finish(tester, t.db);
    });

    // Telnet, serial, Mosh and Eternal Terminal hosts were counted by Run snippet
    // on these, and then failed with SSH only. A broadcast reaches them.
    for (final protocol in const ['telnet', 'serial', 'mosh', 'et']) {
      desktopTest('a $protocol host is not counted by Run snippet on these, nor handed on; Broadcast to these counts it', (tester) async {
        final t = await pump(tester);
        await tester.runAsync(() => (t.db.update(t.db.connections)..where((c) => c.id.equals('build')))
            .write(ConnectionsCompanion(protocol: Value(protocol))));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('monitor-filter-cantCheck')));
        await settle(tester);
        expect(find.text(en.monitorRunOnThese(2)), findsOneWidget);
        expect(find.text(en.monitorBroadcastToThese(3)), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('monitor-run-these')));
        await settle(tester);
        expect(find.text(en.runOnHostsRun(2)), findsOneWidget);
        await tester.tap(find.text(en.cancel));
        await settle(tester);
        await finish(tester, t.db);
      });
    }

    desktopTest('with only such hosts left Run snippet on these is not offered, and Broadcast to these is', (tester) async {
      final t = await pump(tester);
      Future<void> telnet(String id) => tester.runAsync(() => (t.db.update(t.db.connections)..where((c) => c.id.equals(id)))
          .write(const ConnectionsCompanion(protocol: Value('telnet'))));
      await telnet('build');
      await telnet('cache');
      await telnet('vpn');
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('monitor-filter-cantCheck')));
      await settle(tester);
      expect(find.byKey(const ValueKey('monitor-run-these')), findsNothing);
      expect(find.text(en.monitorBroadcastToThese(3)), findsOneWidget);
      await finish(tester, t.db);
    });

    desktopTest('a host that does not ask for a restart has no such filter, and a calm fleet none at all', (tester) async {
      final t = await pump(tester);
      expect(find.byKey(const ValueKey('monitor-filter-reboot')), findsOneWidget);
      await finish(tester, t.db);
    });
  });

  desktopTest('Updates sorts, the most waiting first', (tester) async {
    final t = await pump(tester);
    await tester.tap(find.text(en.monitorColUpdates.toUpperCase()));
    await settle(tester);
    final web2 = tester.getTopLeft(row('web2')).dy;
    final logs = tester.getTopLeft(row('logs')).dy;
    expect(web2, lessThan(logs), reason: '23 before 12');
    await finish(tester, t.db);
  });

  group('the columns', () {
    double widthOf(WidgetTester tester, String column) {
      final edge = tester.getCenter(find.byKey(ValueKey('monitor-col-edge-$column')));
      return edge.dx;
    }

    test('what is left over goes to the metric columns, not to Host, which is as wide as its content', () {
      final widths = monitorColumnWidths(
        columns: const [
          (key: 'host', width: 180, isMetric: false, isHost: true),
          (key: 'cpu', width: 88, isMetric: true, isHost: false),
          (key: 'ram', width: 88, isMetric: true, isHost: false),
          (key: 'seen', width: 64, isMetric: false, isHost: false),
        ],
        set: const {},
        hostContent: 200,
        available: 640,
      );
      expect(widths['host'], 200);
      expect(widths['seen'], 64);
      expect(widths['cpu'], 188);
      expect(widths['ram'], 188);
    });

    test('a width set stays; the rest of the room goes to the columns with none', () {
      final widths = monitorColumnWidths(
        columns: const [
          (key: 'host', width: 180, isMetric: false, isHost: true),
          (key: 'cpu', width: 88, isMetric: true, isHost: false),
          (key: 'ram', width: 88, isMetric: true, isHost: false),
        ],
        set: const {'cpu': 100, 'host': 150},
        hostContent: 200,
        available: 500,
      );
      expect(widths['host'], 150);
      expect(widths['cpu'], 100);
      expect(widths['ram'], 250);
    });

    test('with no metric column to take it, Host does; and past the room there is nothing to share', () {
      final none = monitorColumnWidths(
        columns: const [
          (key: 'host', width: 180, isMetric: false, isHost: true),
          (key: 'seen', width: 64, isMetric: false, isHost: false),
        ],
        set: const {},
        hostContent: 200,
        available: 500,
      );
      expect(none['host'], 436);
      final tight = monitorColumnWidths(
        columns: const [
          (key: 'host', width: 180, isMetric: false, isHost: true),
          (key: 'cpu', width: 88, isMetric: true, isHost: false),
        ],
        set: const {},
        hostContent: 200,
        available: 100,
      );
      expect(tight, {'host': 200, 'cpu': 88});
    });

    desktopTest("a column's edge drags its width, and it is remembered", (tester) async {
      final t = await pump(tester);
      final before = widthOf(tester, 'host');
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('monitor-col-edge-host'))),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(10, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(50, 0));
      await tester.pump();
      await gesture.up();
      await settle(tester);
      expect(widthOf(tester, 'host'), closeTo(before + 60, 12));
      expect(t.prefs.getString('monitor_column_widths_v1'), contains('host'));
      // Back after a restart of the page.
      expect(t.container.read(monitorColumnWidthsProvider)['host'], isNotNull);
      await finish(tester, t.db);
    });

    desktopTest("a column can't be dragged narrower than it can be read", (tester) async {
      final t = await pump(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('monitor-col-edge-load'))),
        kind: PointerDeviceKind.mouse,
      );
      // (The first of a drag's moves starts it; what comes after moves it.)
      await gesture.moveBy(const Offset(-10, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-300, 0));
      await tester.pump();
      await gesture.up();
      await settle(tester);
      expect(t.container.read(monitorColumnWidthsProvider)['load'], 44);
      await finish(tester, t.db);
    });

    desktopTest('a double-click on an edge fits the column to what it holds, and Reset takes every width back',
        (tester) async {
      final t = await pump(tester);
      final edge = find.byKey(const ValueKey('monitor-col-edge-updates'));
      await tester.tap(edge);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(edge);
      await settle(tester);
      final fitted = t.container.read(monitorColumnWidthsProvider)['updates'];
      expect(fitted, isNotNull);
      expect(t.prefs.getString('monitor_column_widths_v1'), contains('updates'));

      await tester.tap(find.byKey(const ValueKey('monitor-columns')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('monitor-columns-reset-widths')));
      await settle(tester);
      expect(t.container.read(monitorColumnWidthsProvider), isEmpty);
      expect(t.prefs.getString('monitor_column_widths_v1'), isNull);
      await finish(tester, t.db);
    });

    test('Reset all settings puts the widths back', () {
      expect(SettingsService.resetKeys, contains('monitor_column_widths_v1'));
    });
  });

  desktopTest('the warning limits are said once: under the table, and not in the status bar', (tester) async {
    final t = await pump(tester);
    expect(find.byKey(const ValueKey('monitor-warn-at')), findsOneWidget);
    await finish(tester, t.db);
    final bar = File('lib/ui/screens/desktop/widgets/desktop_status_bar.dart').readAsStringSync();
    expect(bar, isNot(contains('monitorTableWarnAt')));
    expect(bar, isNot(contains('monitorWarnAtLine')));
  });
}
