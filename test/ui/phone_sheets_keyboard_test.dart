import 'dart:async';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/broadcast/broadcast_to_hosts.dart';
import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:zestssh/features/monitoring/monitor_thresholds.dart';
import 'package:zestssh/features/run/run_on_hosts_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/monitor_thresholds_provider.dart';
import 'package:zestssh/ui/screens/monitoring/monitor_thresholds_dialog.dart';
import 'package:zestssh/ui/widgets/connection_picker_dialog.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

import '../helpers/monitor_table_fixture.dart';
import '../visual/shots_util.dart';

/// A phone's sheets with a keyboard up or on its side, in the real fonts: the
/// thresholds overflowed and left the limits a slit of a pixel between the head
/// and the buttons, and Run on hosts overflowed by as much as 124 pixels.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  setUpAll(() => L10nGlobal.update(en));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  const places = <(String, Size, double)>[
    ('on its side', Size(844, 390), 0),
    ('on its side, the keyboard up', Size(844, 390), 190),
    ('upright', Size(390, 844), 0),
    ('upright, the keyboard up', Size(390, 844), 340),
    ('small, the keyboard up', Size(360, 640), 280),
    ('smaller, the keyboard up', Size(320, 568), 260),
  ];

  /// The thing opened on a phone of [size], [insets] of it under a keyboard.
  Future<AppDatabase> pump(
    WidgetTester tester,
    Size size,
    double insets,
    void Function(BuildContext context) open,
  ) async {
    await tester.runAsync(loadShotFonts);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = FakeViewPadding(bottom: insets);
    addTearDown(tester.view.reset);
    final fleet = MonitorFleet();
    final db = (await tester.runAsync(fleet.database))!;
    await tester.runAsync(() => (db.update(db.connections)..where((t) => t.id.equals('build')))
        .write(const ConnectionsCompanion(protocol: Value('sftp'))));
    final prefs = await fleet.preferences();
    await tester.pumpWidget(fleet.app(
      fleet.overrides(db, prefs),
      Builder(builder: (context) => TextButton(onPressed: () => open(context), child: const Text('open'))),
      theme: ThemeData(fontFamily: 'GeistSans'),
    ));
    await settle(tester);
    await tester.tap(find.text('open'));
    await settle(tester);
    return db;
  }

  Future<void> finish(WidgetTester tester, AppDatabase db) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    await db.close();
  }

  final sheet = find.byKey(const ValueKey('zest-sheet'));

  /// What scrolls in the sheet: tall enough to read, not a slit.
  void expectRoomToRead(WidgetTester tester, String where) {
    final scroll = find.descendant(of: sheet, matching: find.byType(SingleChildScrollView)).first;
    expect((tester.renderObject(scroll) as RenderBox).size.height, greaterThan(60), reason: where);
  }

  for (final (name, size, insets) in places) {
    testWidgets('the thresholds, $name: nothing overflows, and there is room to read', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final db = await pump(tester, size, insets, (context) => showMonitorThresholds(context, hostId: 'hva'));
        expect(tester.takeException(), isNull, reason: name);
        expect(sheet, findsOneWidget);
        expectRoomToRead(tester, name);
        expect(find.byKey(const ValueKey('thresholds-host-select')), findsOneWidget);
        expect(find.byKey(const ValueKey('thresholds-all-hosts')), findsNothing, reason: 'no two panes on a sheet, however wide');
        await finish(tester, db);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Run on hosts, $name: nothing overflows', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final db = await pump(tester, size, insets, (context) => showRunOnHosts(context, preselected: const {'web1'}));
        expect(tester.takeException(), isNull, reason: name);
        expectRoomToRead(tester, name);
        await finish(tester, db);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Broadcast, $name: nothing overflows', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final db = await pump(tester, size, insets, (context) {
          showZestModal<void>(context: context, size: ZestModalSize.large, child: const BroadcastToHostsDialog());
        });
        expect(tester.takeException(), isNull, reason: name);
        await finish(tester, db);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('the picker, $name: nothing overflows', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final db = await pump(tester, size, insets, (context) {
          ConnectionPickerDialog.show(context, title: 'Run on', needsTerminal: true, place: HostListPlace.runSnippet);
        });
        expect(tester.takeException(), isNull, reason: name);
        await finish(tester, db);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  // A confirm whose name is only in its title read "This cannot be undone.
  // [Delete]", with no name, where a short sheet gave up its head.
  for (final (name, size, insets) in const <(String, Size, double)>[
    ('a small phone on its side', Size(568, 320), 0.0),
    ('split screen', Size(800, 330), 0.0),
    ('on its side, the keyboard up', Size(844, 390), 190.0),
    ('small, the keyboard up', Size(320, 568), 260.0),
    ('a tall keyboard', Size(360, 640), 310.0),
  ]) {
    testWidgets('a short sheet keeps its title on one line, with no icon: $name', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        const title = 'Delete prod-db and everything that was ever kept in it, with a name far too long for one line?';
        final db = await pump(tester, size, insets, (context) {
          unawaited(ZestConfirmDialog.show(context,
              tone: ZestDialogTone.destructive, title: title, body: 'This cannot be undone.', confirmLabel: 'Delete'));
        });
        expect(tester.takeException(), isNull, reason: name);
        final head = find.byKey(const ValueKey('zest-dialog-short-title'));
        expect(head, findsOneWidget);
        final text = tester.widget<Text>(find.descendant(of: head, matching: find.text(title)));
        expect(text.maxLines, 1);
        expect(tester.getSize(head).height, lessThanOrEqualTo(32));
        expect(find.descendant(of: head, matching: find.byType(Icon)), findsNothing);
        expect(find.text('This cannot be undone.'), findsOneWidget);
        expect(find.text('Delete'), findsOneWidget);
        await finish(tester, db);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('a sheet with room has its whole head, and not the short title', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final db = await pump(tester, const Size(390, 844), 0, (context) {
        unawaited(ZestConfirmDialog.show(context,
            tone: ZestDialogTone.destructive, title: 'Delete prod-db?', body: 'This cannot be undone.', confirmLabel: 'Delete'));
      });
      expect(find.byKey(const ValueKey('zest-dialog-short-title')), findsNothing);
      expect(find.text('Delete prod-db?'), findsOneWidget);
      await finish(tester, db);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a keyboard that comes up on a phone on its side keeps the field it came up for, and what is in it', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final db = await pump(tester, const Size(844, 390), 0, (context) => showMonitorThresholds(context, hostId: 'web1'));
      final field = find.descendant(of: find.byKey(const ValueKey('thresholds-band-ram')), matching: find.byType(TextField)).first;
      await tester.ensureVisible(field);
      await settle(tester);
      await tester.tap(field);
      await settle(tester);
      await tester.enterText(field, '55');
      await settle(tester);
      final before = tester.state<EditableTextState>(find.descendant(of: field, matching: find.byType(EditableText)));
      expect(find.byKey(const ValueKey('zest-dialog-primary')), findsOneWidget);

      tester.view.viewInsets = const FakeViewPadding(bottom: 190);
      await settle(tester);
      expect(tester.takeException(), isNull);
      final after = tester.state<EditableTextState>(find.descendant(of: field, matching: find.byType(EditableText)));
      expect(identical(before, after), isTrue, reason: 'the same field, not a new one');
      expect(after.widget.focusNode.hasFocus, isTrue);
      expect(after.textEditingValue.text, '55');
      expect(find.byKey(const ValueKey('zest-dialog-primary')), findsOneWidget, reason: 'its buttons stay');
      await finish(tester, db);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('on a phone a number being typed, then a menu over the sheet: it counts, the sheet being still there', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      late ProviderContainer container;
      final db = await pump(tester, const Size(390, 844), 0, (context) {
        container = ProviderScope.containerOf(context);
        showMonitorThresholds(context);
      });
      final field = find.descendant(of: find.byKey(const ValueKey('thresholds-band-ram')), matching: find.byType(TextField)).first;
      await tester.ensureVisible(field);
      await settle(tester);
      await tester.tap(field);
      await settle(tester);
      await tester.enterText(field, '55');
      await settle(tester);
      final menu = find.byType(PopupMenuButton<int>).first;
      await tester.ensureVisible(menu);
      await settle(tester);
      await tester.tap(menu);
      await settle(tester);
      expect(container.read(monitorThresholdsProvider).global.forMetric(MonitorMetric.ram).warn, 55);
      await finish(tester, db);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('on a phone a tap on Done keeps the number being typed: the focus stays where it is', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      late ProviderContainer container;
      final db = await pump(tester, const Size(390, 844), 0, (context) {
        container = ProviderScope.containerOf(context);
        showMonitorThresholds(context, hostId: 'web1');
      });
      final field = find.descendant(of: find.byKey(const ValueKey('thresholds-band-ram')), matching: find.byType(TextField)).first;
      await tester.tap(field);
      await settle(tester);
      await tester.enterText(field, '55');
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('zest-dialog-primary')));
      await settle(tester);
      expect(container.read(monitorThresholdsProvider).overrideFor('web1')?.metrics[MonitorMetric.ram]?.warn, 55);
      await finish(tester, db);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
