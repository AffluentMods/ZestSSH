import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/models/host_icon_color.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/state/host_multi_select.dart';
import 'package:zestssh/features/hosts/widgets/host_bulk_action_bar.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/widgets/zest_color_picker.dart';

/// The bar that shows while hosts are selected (3.0; remade in
/// 3.4): "Icon color" for all of them at once
/// (behind its ⋯), and no action cut off, in any language and in a narrow
/// window. (Measured with the font the app ships: the test font draws every
/// letter as a square as wide as the text is high.)
Future<void> _loadGeistSans() async {
  final loader = FontLoader('GeistSans');
  for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    final bytes = File('assets/fonts/GeistSans-$w.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load().timeout(const Duration(seconds: 30));
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const green = 0xFF22C55E;

  late AppDatabase db;
  late ProviderContainer container;

  Future<void> pump(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    double width = 1500,
    Set<String> selected = const {'a', 'b'},
  }) async {
    await tester.runAsync(_loadGeistSans);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    for (final (id, iconColor) in <(String, int?)>[('a', green), ('b', null), ('c', green), ('d', HostIconColor.followsLabel)]) {
      await db.connectionsDao.insertConnection(ConnectionsCompanion(
        id: Value(id),
        label: Value('web-0$id'),
        host: Value('192.168.10.2${id.codeUnitAt(0) - 96}'),
        port: const Value(22),
        protocol: const Value('ssh'),
        iconId: const Value('debian'),
        iconColor: Value(iconColor),
        createdAt: Value(DateTime.utc(2026)),
        updatedAt: Value(DateTime.utc(2026)),
      ));
    }
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
    ]);
    addTearDown(container.dispose);
    final select = container.read(hostMultiSelectProvider.notifier)..enter();
    selected.forEach(select.toggle);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: Align(alignment: Alignment.bottomCenter, child: HostBulkActionBar(groups: []))),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<Map<String, int?>> stored() async => {for (final c in await db.connectionsDao.getAll()) c.id: c.iconColor};

  /// Lets the writes of an action, which are real database work, finish.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  /// Opens the bar's ⋯ and picks [label] there.
  Future<void> fromMore(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(const ValueKey('bulk-more')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text(label));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> openIconColor(WidgetTester tester) async {
    await fromMore(tester, 'Icon color');
    expect(find.text('Icon color of 2 hosts'), findsOneWidget);
  }

  group('"Icon color" for the selected hosts', () {
    testWidgets('the icon\'s own colour: written to every selected host, and to no other', (tester) async {
      await pump(tester);
      await openIconColor(tester);
      await tester.tap(find.byKey(const ValueKey('bulk-icon-color-own')));
      await settle(tester);
      expect(await stored(), {'a': null, 'b': null, 'c': green, 'd': HostIconColor.followsLabel});
      expect(container.read(hostMultiSelectProvider).active, isFalse, reason: 'done: the selection is over');
      expect(find.text('Icon color of 2 hosts'), findsNothing);
    });

    testWidgets('the group\'s colour', (tester) async {
      await pump(tester);
      await openIconColor(tester);
      expect(find.text("Group color: each host's color label, or its group's color."), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bulk-icon-color-group')));
      await settle(tester);
      expect(await stored(), {'a': 0, 'b': 0, 'c': green, 'd': 0});
    });

    testWidgets('one colour for all of them, from the label colours', (tester) async {
      await pump(tester, selected: {'b', 'd'});
      await openIconColor(tester);
      expect(find.text('Or one color for all of them:'), findsOneWidget);
      final swatches = find.descendant(of: find.byType(ZestColorPicker), matching: find.byType(GestureDetector));
      expect(swatches, findsNWidgets(AppColors.labelPalette.length), reason: 'the label colours and nothing else');
      await tester.tap(swatches.at(4));
      await settle(tester);
      final blue = HostIconColor.custom(AppColors.labelPalette[4]);
      expect(await stored(), {'a': green, 'b': blue, 'c': green, 'd': blue});
      expect(blue, 0xFF3B82F6);
    });

    testWidgets('closed with nothing chosen, nothing is changed and the hosts stay selected', (tester) async {
      await pump(tester);
      await openIconColor(tester);
      await tester.tapAt(const Offset(5, 5));
      await settle(tester);
      expect(find.text('Icon color of 2 hosts'), findsNothing);
      expect(await stored(), {'a': green, 'b': null, 'c': green, 'd': HostIconColor.followsLabel});
      expect(container.read(hostMultiSelectProvider).selected, {'a', 'b'});
    });

    testWidgets('with no host selected its ⋯ is there, shown as off, and does nothing', (tester) async {
      await pump(tester, selected: {});
      Color? drawn(String label) => tester.widget<Text>(find.text(label)).style?.color;
      Color? more() => tester.widget<Icon>(find.descendant(of: find.byKey(const ValueKey('bulk-more')), matching: find.byType(Icon))).color;
      expect(more(), ZestColors.textTertiary, reason: 'off, like the actions beside it');
      expect(drawn('Tags'), ZestColors.textTertiary);
      final close = tester.widget<Icon>(find.descendant(of: find.byKey(const ValueKey('bulk-done')), matching: find.byType(Icon)));
      expect(close.color, ZestColors.textPrimary, reason: 'what can be done is not greyed');
      await tester.tap(find.byKey(const ValueKey('bulk-more')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Icon color'), findsNothing);

      // With hosts selected it is on.
      await tester.pumpWidget(const SizedBox.shrink());
      await pump(tester);
      expect(more(), ZestColors.textPrimary);
    });

    testWidgets('for one host the title says one', (tester) async {
      await pump(tester, selected: {'c'});
      await fromMore(tester, 'Icon color');
      expect(find.text('Icon color of 1 host'), findsOneWidget);
    });
  });

  group('the two colours are told apart', () {
    testWidgets('the action for the label is named for the label, as the editor names it, and still sets the label',
        (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('bulk-more')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Color label'), findsOneWidget);
      expect(find.text('Icon color'), findsOneWidget);
      expect(find.text('Set colour'), findsNothing);
      await tester.tap(find.text('Color label'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Color label · 2'), findsOneWidget);
      final swatches = find.descendant(of: find.byType(ZestColorPicker), matching: find.byType(GestureDetector));
      // None, then the label colours.
      expect(swatches, findsNWidgets(AppColors.labelPalette.length + 1));
      await tester.tap(swatches.at(4));
      await settle(tester);
      final rows = {for (final c in await db.connectionsDao.getAll()) c.id: c.colorValue};
      expect(rows, {'a': 0xFF10B981, 'b': 0xFF10B981, 'c': null, 'd': null});
      expect(await stored(), {'a': green, 'b': null, 'c': green, 'd': HostIconColor.followsLabel},
          reason: 'the colour of the label is not the colour of the icon');
    });
  });

  group('no action is cut off', () {
    for (final width in [1500.0, 620.0, 380.0]) {
      testWidgets('in any language, in a window ${width.toInt()} wide', (tester) async {
        for (final locale in AppLocalizations.supportedLocales) {
          await tester.pumpWidget(const SizedBox.shrink());
          await pump(tester, locale: locale, width: width);
          expect(tester.takeException(), isNull, reason: '${locale.languageCode}: something did not fit');
          final l10n = lookupAppLocalizations(locale);
          final bar = tester.getRect(find.byKey(const ValueKey('host-bulk-actions')));
          expect(bar.right, lessThanOrEqualTo(width - 24), reason: '${locale.languageCode}: the bar is inside the window');
          expect(bar.left, greaterThanOrEqualTo(24));
          // What the bar shows (as designed: the rest is behind its ⋯).
          for (final label in [
            l10n.hostBulkActionSelectedCount(2),
            l10n.bulkOpen,
            l10n.bulkTags,
            l10n.hostBulkActionMoveToGroup,
            l10n.delete,
          ]) {
            final at = tester.getRect(find.text(label));
            expect(at.left, greaterThanOrEqualTo(bar.left - 0.5), reason: '${locale.languageCode}: $label');
            expect(at.right, lessThanOrEqualTo(bar.right + 0.5), reason: '${locale.languageCode}: $label');
            expect(at.top, greaterThanOrEqualTo(bar.top - 0.5), reason: '${locale.languageCode}: $label');
            expect(at.bottom, lessThanOrEqualTo(bar.bottom + 0.5), reason: '${locale.languageCode}: $label');
          }
        }
      });
    }

    testWidgets('the design\'s actions stand on one line, in a wide window and a narrower one; the rest in ⋯',
        (tester) async {
      double lines(WidgetTester tester, List<String> labels) =>
          {for (final label in labels) tester.getCenter(find.text(label)).dy.round()}.length.toDouble();
      const all = ['2 selected', 'Open…', 'Tags', 'Move to group', 'Delete'];
      for (final width in [1500.0, 1000.0]) {
        await tester.pumpWidget(const SizedBox.shrink());
        await pump(tester, width: width);
        expect(lines(tester, all), 1, reason: 'English, $width wide');
        expect(find.byKey(const ValueKey('bulk-more')), findsOneWidget);
        for (final l in ['Pin', 'Save as workspace', 'Icon color', 'Color label']) {
          expect(find.text(l), findsNothing, reason: '$l is behind ⋯');
        }
      }
    });

    testWidgets('a divider never stands alone at the end or the start of a line', (tester) async {
      // At every width from wide to narrow, the divider before Delete is on
      // Delete's line, just before it.
      for (var width = 1100.0; width >= 380; width -= 40) {
        await tester.pumpWidget(const SizedBox.shrink());
        await pump(tester, width: width);
        expect(tester.takeException(), isNull, reason: 'at $width');
        final delete = tester.getRect(find.text('Delete'));
        final dividers = find.byWidgetPredicate(
            (w) => w is Container && w.constraints?.maxWidth == 1 && w.constraints?.maxHeight == 22);
        final before = [
          for (final e in dividers.evaluate())
            if ((tester.getRect(find.byWidget(e.widget)).center.dy - delete.center.dy).abs() < 1 &&
                tester.getRect(find.byWidget(e.widget)).right <= delete.left)
              e,
        ];
        expect(before, isNotEmpty, reason: 'at $width');
      }
    });
  });

  // 3.0 UI: the question was a plain dialog.
  group('"Delete" for the selected hosts', () {
    final en = lookupAppLocalizations(const Locale('en'));

    Future<Set<String>> left() async => {for (final c in await db.connectionsDao.getAll()) c.id};

    testWidgets('asks in the dialog of the app, saying how many and that it cannot be undone; Cancel deletes nothing',
        (tester) async {
      await pump(tester);
      await tester.tap(find.text('Delete'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ZestConfirmDialog), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(en.hostBulkActionDeleteTitle), findsOneWidget);
      expect(find.text(en.hostBulkActionDeleteConfirm(2)), findsOneWidget);
      expect(
        find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(en.hostBulkActionDeleteButton(2))),
        findsOneWidget,
      );
      await tester.tap(find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(en.cancel)));
      await settle(tester);
      expect(find.byType(ZestConfirmDialog), findsNothing);
      expect(await tester.runAsync(left), {'a', 'b', 'c', 'd'});
    });

    testWidgets('a yes deletes the selected hosts and no other', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Delete'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(
          find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(en.hostBulkActionDeleteButton(2))));
      await settle(tester);
      expect(find.byType(ZestConfirmDialog), findsNothing);
      expect(await tester.runAsync(left), {'c', 'd'});
      expect(container.read(hostMultiSelectProvider).active, isFalse, reason: 'everything went: the selection is over');
      // As every list's selection, it says what was deleted (a toast that goes by itself).
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('for one host the question says one', (tester) async {
      await pump(tester, selected: {'c'});
      await tester.tap(find.text('Delete'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(en.hostBulkActionDeleteConfirm(1)), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(en.cancel)));
      await settle(tester);
    });
  });

  // The dialog rules of 3.4 (as they landed on the remade bar): the
  // bar's own dialogs (a tag, a group, the colour label, the icon colour)
  // were raw Material ones; each is the app's shell, its title and Cancel in
  // its footer, and Cancel changes nothing.
  group('the bar\'s dialogs are the app\'s own', () {
    final en = lookupAppLocalizations(const Locale('en'));

    Future<void> isTheShell(WidgetTester tester, String title) async {
      final shell = find.byType(ZestDialogShell);
      expect(shell, findsOneWidget, reason: title);
      expect(find.byType(AlertDialog), findsNothing, reason: title);
      expect(find.descendant(of: shell, matching: find.text(title)), findsOneWidget);
      await tester.tap(find.descendant(of: shell, matching: find.text(en.cancel)));
      await settle(tester);
      expect(find.byType(ZestDialogShell), findsNothing, reason: '$title: Cancel closes it');
      expect(await stored(), {'a': green, 'b': null, 'c': green, 'd': HostIconColor.followsLabel});
      expect(container.read(hostMultiSelectProvider).selected, {'a', 'b'}, reason: '$title: nothing done');
    }

    testWidgets('a tag for the selected hosts', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('bulk-tag')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text(en.hostBulkActionAddTagButton(2)), findsOneWidget, reason: 'its main button says what it does');
      await isTheShell(tester, en.hostBulkActionTagHostsTitle(2));
    });

    testWidgets('a group for the selected hosts', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('bulk-move')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(en.hostBulkActionUngrouped), findsOneWidget);
      await isTheShell(tester, en.hostBulkActionMoveHostsTo(2));
    });

    testWidgets('the colour label and the icon colour', (tester) async {
      await pump(tester);
      await fromMore(tester, en.zestHostFieldColor);
      expect(find.byType(ZestColorPicker), findsOneWidget);
      await isTheShell(tester, '${en.zestHostFieldColor} · 2');
      await fromMore(tester, en.hostIconColorLabel);
      expect(find.byKey(const ValueKey('bulk-icon-color-own')), findsOneWidget);
      await isTheShell(tester, en.hostIconColorBulkTitle(2));
    });
  });
}
