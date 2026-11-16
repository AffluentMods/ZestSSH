import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/server_stats_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/monitoring/server_monitor_screen.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

import '../helpers/monitor_table_fixture.dart';
import '../visual/shots_util.dart' show loadShotFonts;

/// A fleet whose hypervisor-b is read through Prometheus, the others over SSH.
class _MixedFleet extends MonitorFleet {
  @override
  Map<String, ServerStats> get stats {
    final all = super.stats;
    final hvb = all['hvb']!;
    return {
      ...all,
      'hvb': ServerStats(
        cpuPercent: hvb.cpuPercent,
        ramUsedMB: hvb.ramUsedMB,
        ramTotalMB: hvb.ramTotalMB,
        diskPercent: hvb.diskPercent,
        loadAverage: hvb.loadAverage,
        collectedAt: hvb.collectedAt,
        source: MetricSource.prometheus,
      ),
    };
  }
}

/// The phone's Server monitor cards read at 13 at the least, and say "via
/// SSH" only where the hosts' sources differ (a 4.0 review found
/// CPU, RAM and Disk read at 11, RAM's megabytes at 9, and every card
/// said "via SSH").
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  /// Runs [body] drawn as a phone's ([touch]) or a computer's.
  void drawn(String name, Future<void> Function(WidgetTester tester) body, {bool touch = true}) {
    testWidgets(name, (tester) async {
      debugTouchLayout = touch;
      debugDefaultTargetPlatformOverride = touch ? TargetPlatform.android : TargetPlatform.windows;
      try {
        await body(tester);
      } finally {
        debugTouchLayout = null;
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  Future<void> pumpMonitor(WidgetTester tester, MonitorFleet fleet, {Size size = const Size(390, 2400)}) async {
    final theme = BuiltInThemes.getById('graphite');
    AppColors.applyTheme(theme.colorScheme);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = (await tester.runAsync(fleet.database))!;
    final prefs = (await tester.runAsync(fleet.preferences))!;
    addTearDown(() => tester.runAsync(db.close));
    await tester.pumpWidget(fleet.app(fleet.overrides(db, prefs), const ServerMonitorScreen(), theme: theme.toThemeData()));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> unpump(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  Finder cardOf(String host) => find.ancestor(of: find.text(host), matching: find.byType(Card)).first;

  drawn('on a phone a card reads at 13 at the least, its readings whole, RAM in GB', (tester) async {
    // The real fonts: whether a reading fits is a matter of their widths.
    await tester.runAsync(loadShotFonts);
    await pumpMonitor(tester, MonitorFleet());
    final card = cardOf('hypervisor-b');
    // Every line of the card at 13 or more but its address, which is
    // monospace and keeps 12 (at 13 a status pill cut its port off).
    final paragraphs = tester.renderObjectList<RenderParagraph>(find.descendant(of: card, matching: find.byType(RichText)));
    expect(paragraphs, isNotEmpty);
    for (final p in paragraphs) {
      final text = p.text.toPlainText();
      if (text == '192.168.20.12:22' || text.trim().isEmpty) continue;
      final sizes = <double?>[];
      p.text.visitChildren((span) {
        // (An icon is drawn as text too, in its icon font: not words.)
        final iconFont = span.style?.fontFamily?.toLowerCase().contains('lucide') ?? false;
        if (span is TextSpan && span.text != null && !iconFont) sizes.add(span.style?.fontSize);
        return true;
      });
      for (final size in sizes) {
        expect(size, greaterThanOrEqualTo(13), reason: '"$text"');
      }
    }
    // CPU, RAM and Disk whole (a Spacer beside the value took half its room
    // and cut "89%" short), each at 13.
    for (final (label, value) in [('CPU', '24%'), ('RAM', '71%'), ('Disk', '47%')]) {
      final finder = find.descendant(of: card, matching: find.byKey(ValueKey('monitor-gauge-value-$label')));
      expect(tester.widget<Text>(finder).data, value);
      expect(tester.widget<Text>(finder).style?.fontSize, 13);
      expect(tester.renderObject<RenderParagraph>(find.descendant(of: finder, matching: find.byType(RichText))).didExceedMaxLines,
          isFalse,
          reason: label);
    }
    final hva = find.descendant(of: cardOf('hypervisor-a'), matching: find.byKey(const ValueKey('monitor-gauge-value-RAM')));
    expect(tester.renderObject<RenderParagraph>(find.descendant(of: hva, matching: find.byType(RichText))).didExceedMaxLines,
        isFalse,
        reason: '89% whole');
    // RAM in use in GB, which fits a third of a card at 13.
    expect(find.descendant(of: card, matching: find.text('11.1 / 15.6 GB')), findsOneWidget);
    expect(find.textContaining('MB'), findsNothing);
    await unpump(tester);
  });

  drawn('on a phone no card says "via SSH" when every card would', (tester) async {
    await pumpMonitor(tester, MonitorFleet());
    expect(find.text('via SSH', skipOffstage: false), findsNothing);
    expect(
        find.byWidgetPredicate(
            (w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('monitor-source-text-'),
            skipOffstage: false),
        findsNothing);
    await unpump(tester);
  });

  drawn('on a phone, where the sources differ, each card says its own', (tester) async {
    await pumpMonitor(tester, _MixedFleet());
    expect(find.descendant(of: cardOf('hypervisor-b'), matching: find.byKey(const ValueKey('monitor-source-text-hvb'))),
        findsOneWidget);
    expect(find.text('via Prometheus'), findsOneWidget);
    expect(find.descendant(of: cardOf('hypervisor-a'), matching: find.text('via SSH')), findsOneWidget);
    await unpump(tester);
  });

  drawn("a computer's cards keep their sizes and their via SSH chips", (tester) async {
    await pumpMonitor(tester, MonitorFleet(), size: const Size(1440, 2400));
    expect(find.text('via SSH'), findsWidgets);
    final cpu = find.descendant(of: cardOf('hypervisor-b'), matching: find.byKey(const ValueKey('monitor-gauge-value-CPU')));
    expect(tester.widget<Text>(cpu).style?.fontSize, 11);
    expect(find.descendant(of: cardOf('hypervisor-b'), matching: find.text('11360 / 16000 MB')), findsOneWidget);
    await unpump(tester);
  }, touch: false);
}
