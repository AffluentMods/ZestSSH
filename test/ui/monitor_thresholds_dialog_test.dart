import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/monitoring/monitor_thresholds.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitor_thresholds_provider.dart';
import 'package:zestssh/ui/screens/monitoring/monitor_thresholds_dialog.dart';
import 'package:zestssh/ui/widgets/host_row.dart';

import '../helpers/desktop_mouse.dart';
import '../helpers/monitor_table_fixture.dart';

/// Monitor thresholds in two panes (its host picker
/// was an old dropdown over the whole dialog): All hosts (defaults) and the
/// hosts with a mark on those with their own on the left, their limits on the
/// right, each against where the host stands now, Copy from… and Reset to
/// defaults per host, and the reason under a small Why.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<({AppDatabase db, ProviderContainer container})> open(WidgetTester tester, {String? hostId}) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fleet = MonitorFleet();
    final db = (await tester.runAsync(fleet.database))!;
    final prefs = await fleet.preferences();
    late ProviderContainer container;
    await tester.pumpWidget(fleet.app(
      fleet.overrides(db, prefs),
      Consumer(builder: (context, ref, _) {
        container = ProviderScope.containerOf(context);
        return TextButton(onPressed: () => showMonitorThresholds(context, hostId: hostId), child: const Text('open'));
      }),
    ));
    await settle(tester);
    await tester.tap(find.text('open'));
    await settle(tester);
    return (db: db, container: container);
  }

  Future<void> finish(WidgetTester tester, AppDatabase db) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    await db.close();
  }

  Finder host(String id) => find.byKey(ValueKey('thresholds-host-$id'));

  desktopTest('it opens on the defaults, with the hosts beside them; the defaults have Checking, and no figure of any host',
      (tester) async {
    final t = await open(tester);
    expect(find.byKey(const ValueKey('thresholds-all-hosts')), findsOneWidget);
    expect(find.text(en.zestThresholdAllHostsDefaults), findsNWidgets(2), reason: 'the row, and the head of its pane');
    expect(host('web1'), findsOneWidget);
    expect(find.descendant(of: host('web1'), matching: find.byType(HostGlyph)), findsOneWidget);
    expect(find.text(en.zestThresholdCheckingTitle.toUpperCase()), findsOneWidget);
    expect(find.byKey(const ValueKey('thresholds-now-ram')), findsNothing);
    expect(find.text(en.zestThresholdReset), findsOneWidget, reason: 'for everything, in the foot');
    await finish(tester, t.db);
  });

  desktopTest('a host: its limits, each with where it stands now, and no Checking', (tester) async {
    final t = await open(tester);
    await tester.tap(host('hva'));
    await settle(tester);
    expect(tester.widget<Text>(find.byKey(const ValueKey('thresholds-now-ram'))).data, '89%');
    expect(tester.widget<Text>(find.byKey(const ValueKey('thresholds-now-disk'))).data, '54%');
    expect(find.byKey(const ValueKey('thresholds-now-temp')), findsNothing, reason: 'it reports none');
    expect(find.text(en.zestThresholdCheckingTitle.toUpperCase()), findsNothing);
    expect(find.text(en.zestThresholdFollowsDefaults), findsOneWidget);
    expect(find.text(en.zestThresholdWhyLabel), findsOneWidget);
    await finish(tester, t.db);
  });

  desktopTest('a host with its own has a mark in the list; Reset to defaults takes them away', (tester) async {
    final t = await open(tester, hostId: 'hva');
    final notifier = t.container.read(monitorThresholdsProvider.notifier);
    expect(find.byKey(const ValueKey('thresholds-own-hva')), findsNothing);
    expect(find.byKey(const ValueKey('thresholds-reset-host')), findsNothing);
    notifier.setOverrideMetric('hva', MonitorMetric.ram, const MetricThreshold(92, 97));
    await settle(tester);
    expect(find.byKey(const ValueKey('thresholds-own-hva')), findsOneWidget);
    expect(find.text(en.zestThresholdHasOwn), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('thresholds-reset-host')));
    await settle(tester);
    expect(find.byKey(const ValueKey('thresholds-own-hva')), findsNothing);
    expect(t.container.read(monitorThresholdsProvider).overrideFor('hva'), isNull);
    await finish(tester, t.db);
  });

  desktopTest('Copy from… takes what another host has of its own, with why; with no other host, there is nothing to copy',
      (tester) async {
    final t = await open(tester, hostId: 'web1');
    final notifier = t.container.read(monitorThresholdsProvider.notifier);
    expect(find.byTooltip(en.zestThresholdCopyNone), findsOneWidget);

    notifier.setOverrideMetric('hva', MonitorMetric.ram, const MetricThreshold(92, 97));
    notifier.setOverrideReason('hva', 'Runs VMs');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('thresholds-copy-from')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('thresholds-copy-hva')));
    await settle(tester);
    final copied = t.container.read(monitorThresholdsProvider).overrideFor('web1')!;
    expect(copied.metrics[MonitorMetric.ram]!.warn, 92);
    expect(copied.reason, 'Runs VMs');
    expect(find.byKey(const ValueKey('thresholds-own-web1')), findsOneWidget);
    await finish(tester, t.db);
  });

  desktopTest('Cancel puts everything back; Done keeps it', (tester) async {
    final t = await open(tester, hostId: 'web1');
    final notifier = t.container.read(monitorThresholdsProvider.notifier);
    notifier.setOverrideMetric('web1', MonitorMetric.ram, const MetricThreshold(92, 97));
    await settle(tester);
    await tester.tap(find.text(en.cancel));
    await settle(tester);
    expect(t.container.read(monitorThresholdsProvider).overrideFor('web1'), isNull);

    await tester.tap(find.text('open'));
    await settle(tester);
    notifier.setOverrideMetric('web1', MonitorMetric.ram, const MetricThreshold(92, 97));
    await settle(tester);
    await tester.tap(find.text(en.done));
    await settle(tester);
    expect(t.container.read(monitorThresholdsProvider).overrideFor('web1'), isNotNull);
    await finish(tester, t.db);
  });

  Finder number(String metric) =>
      find.descendant(of: find.byKey(ValueKey('thresholds-band-$metric')), matching: find.byType(TextField)).first;

  /// Whether what is saved has [hostId] in it.
  bool savedWith(ProviderContainer c, String hostId) =>
      c.read(sharedPreferencesProvider).getString('monitor_threshold_config_v1')!.contains(hostId);

  group('what is typed, and leaving', () {
    for (final (name, typed) in const [('nothing typed', null), ('55 typed', '55')]) {
      desktopTest('Esc with the keyboard in a number, $name: nothing of it stays', (tester) async {
        final t = await open(tester, hostId: 'web1');
        await tester.tap(number('ram'));
        await settle(tester);
        if (typed != null) {
          await tester.enterText(number('ram'), typed);
          await settle(tester);
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
        await tester.pump(const Duration(seconds: 1));
        expect(find.byKey(const ValueKey('thresholds-host-web1')), findsNothing, reason: 'it closed');
        expect(t.container.read(monitorThresholdsProvider).overrideFor('web1'), isNull);
        expect(savedWith(t.container, 'web1'), isFalse);
        await finish(tester, t.db);
      });
    }

    desktopTest('Esc with the keyboard in the reason: nothing of it stays', (tester) async {
      final t = await open(tester, hostId: 'web1');
      await tester.tap(find.byKey(const ValueKey('thresholds-why')));
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('thresholds-why')), 'Runs VMs');
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(t.container.read(monitorThresholdsProvider).overrideFor('web1'), isNull);
      expect(savedWith(t.container, 'web1'), isFalse);
      await finish(tester, t.db);
    });

    desktopTest('a number typed, then Cancel: gone; then Done: kept', (tester) async {
      final t = await open(tester, hostId: 'web1');
      await tester.tap(number('ram'));
      await settle(tester);
      await tester.enterText(number('ram'), '55');
      await settle(tester);
      await tester.tap(find.text(en.cancel));
      await settle(tester);
      expect(t.container.read(monitorThresholdsProvider).overrideFor('web1'), isNull);

      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.tap(number('ram'));
      await settle(tester);
      await tester.enterText(number('ram'), '55');
      await settle(tester);
      await tester.tap(find.text(en.done));
      await settle(tester);
      expect(t.container.read(monitorThresholdsProvider).overrideFor('web1')?.metrics[MonitorMetric.ram]?.warn, 55);
      await finish(tester, t.db);
    });

    desktopTest('a number typed, then another host: it stays with the one it was typed for', (tester) async {
      final t = await open(tester, hostId: 'web1');
      await tester.tap(number('ram'));
      await settle(tester);
      await tester.enterText(number('ram'), '55');
      await settle(tester);
      await tester.tap(host('hva'));
      await settle(tester);
      final config = t.container.read(monitorThresholdsProvider);
      expect(config.overrideFor('web1')?.metrics[MonitorMetric.ram]?.warn, 55);
      expect(config.overrideFor('hva'), isNull);
      await finish(tester, t.db);
    });

    desktopTest('a number typed, then a menu over the dialog: it is kept (the dialog is still there)', (tester) async {
      final t = await open(tester);
      await tester.tap(number('ram'));
      await settle(tester);
      await tester.enterText(number('ram'), '55');
      await settle(tester);
      await tester.tap(find.byType(PopupMenuButton<int>).first);
      await settle(tester);
      expect(t.container.read(monitorThresholdsProvider).global.forMetric(MonitorMetric.ram).warn, 55);
      await finish(tester, t.db);
    });

    desktopTest("a click into a number or the reason and out is nothing of the host's own", (tester) async {
      final t = await open(tester, hostId: 'web1');
      await tester.tap(number('ram'));
      await settle(tester);
      await tester.tap(number('disk'));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('thresholds-why')));
      await settle(tester);
      await tester.tap(number('cpu'));
      await settle(tester);
      expect(t.container.read(monitorThresholdsProvider).overrideFor('web1'), isNull);
      expect(find.text(en.zestThresholdHasOwn), findsNothing);
      await finish(tester, t.db);
    });

    desktopTest('a number changed is the host\'s own; the same number typed again is not', (tester) async {
      final t = await open(tester, hostId: 'web1');
      await tester.tap(number('ram'));
      await settle(tester);
      await tester.enterText(number('ram'), '85');
      await settle(tester);
      await tester.tap(number('disk'));
      await settle(tester);
      expect(t.container.read(monitorThresholdsProvider).overrideFor('web1'), isNull);
      await tester.tap(number('ram'));
      await settle(tester);
      await tester.enterText(number('ram'), '70');
      await settle(tester);
      await tester.tap(number('disk'));
      await settle(tester);
      expect(t.container.read(monitorThresholdsProvider).overrideFor('web1')?.metrics[MonitorMetric.ram]?.warn, 70);
      await finish(tester, t.db);
    });
  });

  desktopTest("Reset to defaults at All hosts: the defaults alone; every host's own stays, a deleted host's too", (tester) async {
    final t = await open(tester);
    final notifier = t.container.read(monitorThresholdsProvider.notifier);
    notifier.setOverrideMetric('web1', MonitorMetric.ram, const MetricThreshold(92, 97));
    notifier.setOverrideMetric('a-host-gone', MonitorMetric.disk, const MetricThreshold(70, 80));
    notifier.setOverrideReason('web1', 'Runs VMs');
    notifier.setGlobalMetric(MonitorMetric.cpu, const MetricThreshold(11, 22));
    await settle(tester);
    await tester.tap(find.text(en.zestThresholdReset));
    await settle(tester);
    await tester.tap(find.text(en.done));
    await settle(tester);
    final config = t.container.read(monitorThresholdsProvider);
    expect(config.global.forMetric(MonitorMetric.cpu).warn, MonitorThresholdConfig.defaults.global.forMetric(MonitorMetric.cpu).warn);
    expect(config.overrideFor('web1')?.metrics[MonitorMetric.ram]?.warn, 92);
    expect(config.overrideFor('web1')?.reason, 'Runs VMs');
    expect(config.overrideFor('a-host-gone')?.metrics[MonitorMetric.disk]?.warn, 70);
    await finish(tester, t.db);
  });

  desktopTest('the search narrows the hosts', (tester) async {
    final t = await open(tester);
    await tester.enterText(find.byKey(const ValueKey('thresholds-hosts-search')), 'web-02');
    await settle(tester);
    expect(host('web2'), findsOneWidget);
    expect(host('web1'), findsNothing);
    await finish(tester, t.db);
  });

  desktopTest('with no room for two panes, a select above the limits', (tester) async {
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fleet = MonitorFleet();
    final db = (await tester.runAsync(fleet.database))!;
    final prefs = await fleet.preferences();
    await tester.pumpWidget(fleet.app(
      fleet.overrides(db, prefs),
      Builder(builder: (context) => TextButton(onPressed: () => showMonitorThresholds(context), child: const Text('open'))),
    ));
    await settle(tester);
    await tester.tap(find.text('open'));
    await settle(tester);
    expect(find.byKey(const ValueKey('thresholds-host-select')), findsOneWidget);
    expect(find.byKey(const ValueKey('thresholds-all-hosts')), findsNothing);
    expect(tester.takeException(), isNull);
    await finish(tester, db);
  });

  testWidgets('on a phone: a sheet, one pane, the numbers above a track as wide as the sheet', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fleet = MonitorFleet();
      final db = (await tester.runAsync(fleet.database))!;
      final prefs = await fleet.preferences();
      late ProviderContainer container;
      await tester.pumpWidget(fleet.app(
        fleet.overrides(db, prefs),
        Builder(builder: (context) {
          container = ProviderScope.containerOf(context);
          return TextButton(onPressed: () => showMonitorThresholds(context, hostId: 'hva'), child: const Text('open'));
        }),
      ));
      await settle(tester);
      await tester.tap(find.text('open'));
      await settle(tester);
      container.read(monitorThresholdsProvider.notifier).setOverrideMetric('hva', MonitorMetric.ram, const MetricThreshold(92, 97));
      await settle(tester);

      expect(find.byKey(const ValueKey('zest-sheet')), findsOneWidget);
      expect(find.byKey(const ValueKey('thresholds-host-select')), findsOneWidget);
      // The figure of where it stands is on the track, under the row of its name and numbers.
      final band = find.byKey(const ValueKey('thresholds-band-ram'));
      final name = find.descendant(of: band, matching: find.text(en.monitorRam));
      final figure = find.byKey(const ValueKey('thresholds-now-ram'));
      expect(tester.getTopLeft(figure).dy, greaterThanOrEqualTo(tester.getBottomLeft(name).dy));
      // RAM at 89%: near the far end of a track as wide as the band.
      expect(tester.getCenter(figure).dx - tester.getTopLeft(band).dx, greaterThan(tester.getSize(band).width * 0.8));
      // Both buttons of the head are there, under the name.
      expect(find.byKey(const ValueKey('thresholds-copy-from')), findsOneWidget);
      expect(find.byKey(const ValueKey('thresholds-reset-host')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finish(tester, db);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
