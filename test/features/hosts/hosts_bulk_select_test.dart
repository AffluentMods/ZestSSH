import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/features/hosts/state/host_multi_select.dart';
import 'package:zestssh/features/hosts/widgets/host_card.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/providers/settings_providers.dart';

/// Selecting many hosts on a computer's Hosts page at once:
/// Ctrl-click, Shift-click, Ctrl+A, a band from any empty
/// space, and dragging the selection onto a group; and no per-host size left.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  // The messages shown as on a phone, in the page, where a test finds them.
  setUp(() => debugTopSnackBarOnPhone = true);
  tearDown(() => debugTopSnackBarOnPhone = null);

  late AppDatabase db;
  late ProviderContainer container;
  late List<String> connected;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pump(WidgetTester tester, {bool list = false}) async {
    tester.view.physicalSize = const Size(1500, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'hosts_view_list': list});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    // Closed after the test, outside its fake clock (inside it, drift's
    // close never finishes).
    addTearDown(db.close);
    final at = DateTime(2026, 10, 22);
    for (final (id, name) in [('g-web', 'Web'), ('g-db', 'Databases')]) {
      await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(id: id, name: name, createdAt: at));
    }
    for (var i = 1; i <= 6; i++) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'h$i',
            label: 'host-$i',
            host: '10.50.0.$i',
            groupId: Value(i <= 3 ? 'g-web' : null),
            sortOrder: Value(i),
            createdAt: at,
            updatedAt: at,
          ));
    }
    connected = [];
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      healthChecksEnabledProvider.overrideWith((ref) => false),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: HostsHomePage(onConnectTo: (c) => connected.add(c.connection.id))),
      ),
    ));
    await settle(tester);
    // The test font draws every glyph one em wide: some labels overflow here
    // that fit with the real one, which is not what this is about.
    Object? ex;
    while ((ex = tester.takeException()) != null) {
      expect(ex.toString(), contains('overflowed'));
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  Finder card(String id) => find.byWidgetPredicate((w) => w is HostCard && w.data.id == id);
  Finder row(String id) => find.byKey(ValueKey('hosts-row-$id'));
  Set<String> selected() => container.read(hostMultiSelectProvider).selected;
  bool selecting() => container.read(hostMultiSelectProvider).active;
  Finder panel(String id) => find.byKey(ValueKey('host-panel-$id'));

  /// A click with [keys] held, answered as the page answers one (past the
  /// wait for a second click).
  Future<void> clickWith(WidgetTester tester, Finder target, List<LogicalKeyboardKey> keys) async {
    for (final k in keys) {
      await tester.sendKeyDownEvent(k);
    }
    await tester.pump();
    await tester.tap(target, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 400));
    for (final k in keys.reversed) {
      await tester.sendKeyUpEvent(k);
    }
    await tester.pump();
  }

  /// The hosts in the order the grid shows them.
  List<String> shownOrder(WidgetTester tester) =>
      [for (final c in tester.widgetList<HostCard>(find.byType(HostCard))) c.data.id];

  group('Ctrl-click', () {
    testWidgets('adds a host to the selection and takes it out again, and never opens it', (tester) async {
      await pump(tester);
      await clickWith(tester, card('h2'), [LogicalKeyboardKey.controlLeft]);
      expect(selecting(), isTrue);
      expect(selected(), {'h2'});
      await clickWith(tester, card('h4'), [LogicalKeyboardKey.controlLeft]);
      expect(selected(), {'h2', 'h4'});
      await clickWith(tester, card('h2'), [LogicalKeyboardKey.controlLeft]);
      expect(selected(), {'h4'});
      expect(panel('h2'), findsNothing, reason: 'not opened in the panel');
      expect(panel('h4'), findsNothing);
      expect(connected, isEmpty, reason: 'not connected');
      // The bulk bar is there for them.
      expect(find.byKey(const ValueKey('host-bulk-actions')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('after a plain click, takes the host open in the panel with it', (tester) async {
      await pump(tester);
      await tester.tap(card('h1'), kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 400));
      expect(panel('h1'), findsOneWidget, reason: 'a plain click opens the panel, as before');
      expect(selecting(), isFalse);
      await clickWith(tester, card('h3'), [LogicalKeyboardKey.controlLeft]);
      expect(selected(), {'h1', 'h3'});
      await finish(tester);
    });

    testWidgets('a plain click in selection mode toggles, and Esc ends the selection', (tester) async {
      await pump(tester);
      await clickWith(tester, card('h1'), [LogicalKeyboardKey.controlLeft]);
      await clickWith(tester, card('h5'), []);
      expect(selected(), {'h1', 'h5'});
      expect(connected, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(selecting(), isFalse);
      await finish(tester);
    });
  });

  group('Shift-click', () {
    testWidgets('selects the range from the host clicked last to this one, in the order shown', (tester) async {
      await pump(tester);
      final order = shownOrder(tester);
      expect(order, hasLength(6));
      await clickWith(tester, card(order[1]), [LogicalKeyboardKey.controlLeft]);
      await clickWith(tester, card(order[4]), [LogicalKeyboardKey.shiftLeft]);
      expect(selected(), order.sublist(1, 5).toSet());
      // The range runs from the same host: a second Shift-click changes it.
      await clickWith(tester, card(order[2]), [LogicalKeyboardKey.shiftLeft]);
      expect(selected(), order.sublist(1, 3).toSet());
      expect(connected, isEmpty);
      await finish(tester);
    });

    testWidgets('from the host open in the panel; with Ctrl too it adds the range', (tester) async {
      await pump(tester);
      final order = shownOrder(tester);
      await tester.tap(card(order[0]), kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 400));
      await clickWith(tester, card(order[2]), [LogicalKeyboardKey.shiftLeft]);
      expect(selected(), order.sublist(0, 3).toSet());
      await clickWith(tester, card(order[5]), [LogicalKeyboardKey.controlLeft]);
      await clickWith(tester, card(order[4]), [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.shiftLeft]);
      expect(selected(), {...order.sublist(0, 3), order[4], order[5]});
      await finish(tester);
    });
  });

  group('Ctrl+A', () {
    testWidgets('selects every host shown', (tester) async {
      await pump(tester);
      await clickWith(tester, card('h1'), [LogicalKeyboardKey.controlLeft]);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(selected(), {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'});
      await finish(tester);
    });

    testWidgets('in the search field, selects its text and no host', (tester) async {
      await pump(tester);
      await tester.tap(find.byType(TextField).first);
      await tester.enterText(find.byType(TextField).first, 'host');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(selecting(), isFalse);
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller!.selection, const TextSelection(baseOffset: 0, extentOffset: 4));
      await finish(tester);
    });
  });

  group('The band', () {
    testWidgets('starts in the empty space below the last row and selects what it covers', (tester) async {
      await pump(tester);
      final order = shownOrder(tester);
      final last = tester.getRect(card(order.last));
      final first = tester.getRect(card(order.first));
      // Below every card, inside the window.
      final start = Offset(first.left + 20, last.bottom + 60);
      expect(start.dy, lessThan(1100 - 50), reason: 'precondition: room below the cards');
      final gesture = await tester.startGesture(start, kind: PointerDeviceKind.mouse, buttons: kPrimaryButton);
      await gesture.moveTo(Offset(first.left + 30, last.center.dy));
      await tester.pump();
      await gesture.moveTo(Offset(first.left + 40, last.center.dy - 2));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(selecting(), isTrue);
      // The card of the last row in the first column, and no other.
      final covered = [
        for (final id in order)
          if (tester.getRect(card(id)).left == first.left && tester.getRect(card(id)).top == last.top) id,
      ];
      expect(covered, hasLength(1));
      expect(selected(), covered.toSet());
      await finish(tester);
    });

    testWidgets('with Ctrl held, adds to what was selected', (tester) async {
      await pump(tester);
      final order = shownOrder(tester);
      await clickWith(tester, card(order.first), [LogicalKeyboardKey.controlLeft]);
      final last = tester.getRect(card(order.last));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      final gesture = await tester.startGesture(Offset(last.left + 10, last.bottom + 40),
          kind: PointerDeviceKind.mouse, buttons: kPrimaryButton);
      await gesture.moveTo(Offset(last.left + 30, last.center.dy));
      await tester.pump();
      await gesture.moveTo(Offset(last.left + 40, last.center.dy - 2));
      await tester.pump();
      await gesture.up();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(selected(), containsAll([order.first, order.last]));
      await finish(tester);
    });
  });

  group('Dragging a selection', () {
    testWidgets('onto a group moves every selected host there, says how many, and Undo puts them back', (tester) async {
      await pump(tester);
      await clickWith(tester, card('h4'), [LogicalKeyboardKey.controlLeft]);
      await clickWith(tester, card('h5'), [LogicalKeyboardKey.controlLeft]);
      await clickWith(tester, card('h1'), [LogicalKeyboardKey.controlLeft]);
      expect(selected(), {'h1', 'h4', 'h5'});
      final gesture = await tester.startGesture(tester.getCenter(card('h4')));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      // The chip under the pointer says how many.
      expect(find.text(l10n.hostsSelDragCount(3)), findsOneWidget);
      await gesture.moveTo(tester.getCenter(find.byKey(const ValueKey('group-tile-g-db'))));
      await tester.pump();
      expect(find.text(l10n.hostsSelDropTipMany(3, 'Databases')), findsOneWidget);
      await gesture.up();
      await settle(tester);
      Future<Map<String, String?>> groups() async =>
          {for (final c in await db.connectionsDao.getAll()) c.id: c.groupId};
      final moved = (await tester.runAsync(groups))!;
      expect(moved['h1'], 'g-db');
      expect(moved['h4'], 'g-db');
      expect(moved['h5'], 'g-db');
      expect(moved['h2'], 'g-web', reason: 'not selected, not moved');
      expect(find.text(l10n.hostsSelMovedToast(3, 'Databases')), findsOneWidget);
      expect(selecting(), isFalse, reason: 'the move ends the selection, as the bar does');
      await tester.tap(find.text(l10n.hostsSelUndo));
      await settle(tester);
      final back = (await tester.runAsync(groups))!;
      expect(back['h1'], 'g-web');
      expect(back['h4'], isNull);
      expect(back['h5'], isNull);
      await finish(tester);
    });

    testWidgets('a host not in the selection drags alone', (tester) async {
      await pump(tester);
      await clickWith(tester, card('h4'), [LogicalKeyboardKey.controlLeft]);
      await clickWith(tester, card('h5'), [LogicalKeyboardKey.controlLeft]);
      final gesture = await tester.startGesture(tester.getCenter(card('h6')));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveTo(tester.getCenter(find.byKey(const ValueKey('group-tile-g-db'))));
      await tester.pump();
      expect(find.text(l10n.hostsGroupDropTip('host-6', 'Databases')), findsOneWidget);
      await gesture.up();
      await settle(tester);
      final rows = {for (final c in (await tester.runAsync(db.connectionsDao.getAll))!) c.id: c.groupId};
      expect(rows['h6'], 'g-db');
      expect(rows['h4'], isNull);
      expect(rows['h5'], isNull);
      await finish(tester);
    });
  });

  group('The list', () {
    testWidgets('Ctrl-click, Shift-click and Ctrl+A select as on the cards', (tester) async {
      await pump(tester, list: true);
      expect(find.byKey(const ValueKey('hosts-table')), findsOneWidget);
      final order = [
        for (final e in find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('hosts-row-')).evaluate())
          (e.widget.key! as ValueKey<String>).value.substring('hosts-row-'.length),
      ];
      expect(order, hasLength(6));
      await clickWith(tester, row(order[0]), [LogicalKeyboardKey.controlLeft]);
      expect(selected(), {order[0]});
      expect(panel(order[0]), findsNothing);
      await clickWith(tester, row(order[3]), [LogicalKeyboardKey.shiftLeft]);
      expect(selected(), order.sublist(0, 4).toSet());
      await clickWith(tester, row(order[1]), []);
      expect(selected(), {order[0], order[2], order[3]}, reason: 'a plain click toggles in selection mode');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(selected(), order.toSet());
      expect(connected, isEmpty);
      await finish(tester);
    });
  });

  testWidgets('no size choice is left: a host\'s menu offers none', (tester) async {
    await pump(tester);
    await tester.tap(card('h1'), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('host-menu-organize')), findsOneWidget, reason: 'the menu is open');
    expect(find.text('Size'), findsNothing);
    for (final t in ['Small - compact square (icon + name)', 'Medium - half-height row', 'Large - full card with details']) {
      expect(find.byTooltip(t), findsNothing);
    }
    expect(find.text('S'), findsNothing);
    expect(find.text('M'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    await finish(tester);
  });
}
