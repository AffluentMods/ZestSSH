import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/desktop_dimensions.dart';
import 'package:zestssh/ui/screens/desktop/widgets/pill_bar.dart';
import 'package:zestssh/ui/widgets/drag_ghost.dart';

SessionState _state(String label) => SessionState(
      status: SessionStatus.connected,
      connectionId: 'c-$label',
      connectionLabel: label,
      host: '10.50.0.5',
      port: 22,
      username: 'deploy',
    );

/// Dragging along the tab strip (3.0): it
/// was hard to tell "put it beside that tab" from "join that tab's group".
/// The bar that marks the first was two pixels at the tab's left whichever
/// side the tab would land on, and under the tab's body, so it was never
/// seen. A tab's edges put what is dragged beside it, with a bar on that
/// side; its middle puts it into the tab's group, with the tab tinted. The
/// same for a tab and for a terminal dragged up out of a split.
void main() {
  late SharedPreferences prefs;
  final moves = <(String, String, bool)>[];
  final merges = <(String, String)>[];
  final joins = <(String, String)>[];
  final popOuts = <(String, String?, bool)>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    moves.clear();
    merges.clear();
    joins.clear();
    popOuts.clear();
  });

  /// The strip with the tabs t1 (web-01, in front), t2 (db-01), t3
  /// (cache-01) and t4 (queue-01), and under it the header of a pane of the
  /// tab in front, which can be dragged up.
  Future<void> pumpStrip(
    WidgetTester tester, {
    Set<String> pinned = const {},
    double width = 1600,
    List<String> tabs = const ['t1', 't2', 't3', 't4'],
  }) async {
    tester.view.physicalSize = Size(width, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const names = {'t1': 'web-01', 't2': 'db-01', 't3': 'cache-01', 't4': 'queue-01'};
    final sessions = [for (final id in tabs) MapEntry(id, _state(names[id]!))];
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        // The strip's sync glyph ticks every 30 seconds: no clock here.
        syncHealthClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Column(
            children: [
              PillBar(
                activeNav: NavSection.hosts,
                activeSessionId: 't1',
                sessions: sessions,
                pinnedTabIds: pinned,
                onNavChanged: (_) {},
                onSessionSelected: (_) {},
                onSessionClosed: (_) {},
                onNewSession: () {},
                onCommandPalette: () {},
                onHelp: () {},
                onTabMove: (tab, beside, after) => moves.add((tab, beside, after)),
                onTabMerge: (from, to) => merges.add((from, to)),
                onLeafMoveToTab: (leaf, tab) => joins.add((leaf, tab)),
                onLeafPopOut: (leaf, beside, after) => popOuts.add((leaf, beside, after)),
              ),
              const SizedBox(height: 120),
              const Draggable<String>(
                data: 'leaf-1',
                feedback: SizedBox(width: 60, height: 20),
                child: SizedBox(width: 200, height: 30, child: Text('a pane of web-01')),
              ),
              // Something else that can be dragged in the app (a host's card).
              const Draggable<int>(
                data: 7,
                feedback: SizedBox(width: 60, height: 20),
                child: SizedBox(width: 200, height: 30, child: Text('a host card')),
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  final after = find.byKey(const ValueKey('tab-lands-after'));
  final before = find.byKey(const ValueKey('tab-lands-before'));
  final joining = find.byKey(const ValueKey('tab-joins'));

  /// The tint itself (the mark's own box is the tab's whole place).
  final tint = find.descendant(of: joining, matching: find.byType(Container));

  /// Where the tab [id] is: its box, with the gap after it.
  Rect tabRect(WidgetTester tester, String id) => tester.getRect(find.byKey(ValueKey(id)));

  /// Picks up what is at [from] and holds it over [where].
  Future<TestGesture> dragTo(WidgetTester tester, Offset from, Offset where) async {
    final gesture = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveTo(where);
    await tester.pump();
    await tester.pump();
    return gesture;
  }

  Future<TestGesture> dragTab(WidgetTester tester, String id, Offset where) =>
      dragTo(tester, tabRect(tester, id).center, where);

  Future<TestGesture> dragPane(WidgetTester tester, Offset where) =>
      dragTo(tester, tester.getCenter(find.text('a pane of web-01')), where);

  Future<void> letGo(WidgetTester tester, TestGesture gesture) async {
    await gesture.up();
    await tester.pump();
  }

  void nothingCalled() {
    expect(moves, isEmpty);
    expect(merges, isEmpty);
    expect(joins, isEmpty);
    expect(popOuts, isEmpty);
  }

  group('a tab dragged over another', () {
    testWidgets('over its right edge: a bar after it, and letting go puts the tab there', (tester) async {
      await pumpStrip(tester);
      final t3 = tabRect(tester, 't3');
      final gesture = await dragTab(tester, 't1', Offset(t3.right - 12, t3.center.dy));
      expect(after, findsOneWidget);
      expect(before, findsNothing);
      expect(joining, findsNothing, reason: 'the one mark or the other, never both');
      final bar = tester.getRect(after);
      expect(bar.width, 3);
      expect(bar.right, t3.right, reason: 'on the side the tab will stand at, in the gap after this one');
      expect(bar.top, lessThan(t3.top), reason: 'taller than the tabs: the copy being dragged does not hide it');
      expect(bar.bottom, greaterThan(t3.bottom));
      await letGo(tester, gesture);
      expect(moves, [('t1', 't3', true)]);
      expect(merges, isEmpty);
      expect(after, findsNothing, reason: 'gone once it is let go');
    });

    testWidgets('over its left edge: a bar before it, in the same gap as "after the one before"', (tester) async {
      await pumpStrip(tester);
      final t2 = tabRect(tester, 't2');
      final t3 = tabRect(tester, 't3');
      expect(t3.left, t2.right, reason: 'the tabs stand side by side');
      final gesture = await dragTab(tester, 't1', Offset(t3.left + 12, t3.center.dy));
      expect(before, findsOneWidget);
      expect(after, findsNothing);
      expect(joining, findsNothing);
      final bar = tester.getRect(before);
      expect(bar.right, t3.left, reason: 'before this tab: where "after db-01" is marked too');
      expect(bar.width, 3);
      await letGo(tester, gesture);
      expect(moves, [('t1', 't3', false)]);
      expect(merges, isEmpty);
      expect(before, findsNothing);
    });

    testWidgets('dragged to the left it is the same: the side of the tab it is held over', (tester) async {
      await pumpStrip(tester);
      final t1 = tabRect(tester, 't1');
      var gesture = await dragTab(tester, 't4', Offset(t1.left + 12, t1.center.dy));
      expect(before, findsOneWidget);
      expect(tester.getRect(before).right, t1.left, reason: 'before the first tab');
      await letGo(tester, gesture);
      expect(moves, [('t4', 't1', false)]);

      gesture = await dragTab(tester, 't4', Offset(t1.right - 12, t1.center.dy));
      expect(after, findsOneWidget);
      expect(before, findsNothing);
      await letGo(tester, gesture);
      expect(moves, [('t4', 't1', false), ('t4', 't1', true)]);
    });

    testWidgets('over its middle it joins that tab\'s group: the tab is tinted, no bar, and letting go merges', (tester) async {
      await pumpStrip(tester);
      final t3 = tabRect(tester, 't3');
      final gesture = await dragTab(tester, 't1', t3.center);
      expect(joining, findsOneWidget);
      expect(after, findsNothing);
      expect(before, findsNothing);
      final tinted = tester.getRect(tint);
      expect(tinted.left, t3.left);
      expect(tinted.right, t3.right - 2, reason: 'the tab, not the gap after it');
      expect(tinted.top, t3.top);
      expect(tinted.bottom, t3.bottom);
      await letGo(tester, gesture);
      expect(merges, [('t1', 't3')]);
      expect(moves, isEmpty);
      expect(joining, findsNothing);
    });

    testWidgets('a quarter of the tab\'s own width at each edge is "beside", the half between is "join"', (tester) async {
      await pumpStrip(tester, width: 2400);
      final t3 = tabRect(tester, 't3');
      expect(t3.width, 236, reason: 'a tab at its widest: its edges were 40 pixels whatever its width');
      final quarter = t3.width / 4;
      final gesture = await dragTab(tester, 't1', Offset(t3.left + quarter - 4, t3.center.dy));
      expect(before, findsOneWidget, reason: 'just inside the first quarter');
      await gesture.moveTo(Offset(t3.left + quarter + 4, t3.center.dy));
      await tester.pump();
      expect(before, findsNothing);
      expect(joining, findsOneWidget, reason: 'just past it');
      await gesture.moveTo(Offset(t3.right - quarter - 4, t3.center.dy));
      await tester.pump();
      expect(joining, findsOneWidget);
      await gesture.moveTo(Offset(t3.right - quarter + 4, t3.center.dy));
      await tester.pump();
      expect(joining, findsNothing);
      expect(after, findsOneWidget, reason: 'the last quarter');
      await letGo(tester, gesture);
      expect(moves, [('t1', 't3', true)]);
      expect(merges, isEmpty);
    });

    testWidgets('the tab is found over the strip\'s whole height, from the window\'s top edge', (tester) async {
      await pumpStrip(tester);
      final t3 = tabRect(tester, 't3');
      expect(t3.top, greaterThan(4), reason: 'the tab does not reach the top');
      var gesture = await dragTab(tester, 't1', Offset(t3.center.dx, 1));
      expect(joining, findsOneWidget);
      await letGo(tester, gesture);
      expect(merges, [('t1', 't3')]);
      gesture = await dragTab(tester, 't1', Offset(t3.right - 12, DesktopDimensions.pillBarHeight - 3));
      expect(after, findsOneWidget);
      await letGo(tester, gesture);
      expect(moves, [('t1', 't3', true)]);
    });

    testWidgets('a see-through copy of the tab hangs under the pointer, so the tab it is held over is not covered', (tester) async {
      await pumpStrip(tester, width: 2400);
      // The copy: the same tab, see-through, in the layer above the strip.
      final copy = find.ancestor(
        of: find.byKey(const ValueKey('t1')),
        matching: find.byWidgetPredicate((w) => w is Opacity && w.opacity == kDragGhostOpacity),
      );
      expect(copy, findsNothing);
      final t1 = tabRect(tester, 't1');
      final t3 = tabRect(tester, 't3');

      // Grabbed 50 pixels from its left: the copy stands as far to the side.
      var gesture = await dragTo(tester, Offset(t1.left + 50, t1.center.dy), t3.center);
      expect(copy, findsOneWidget);
      var rect = tester.getRect(copy);
      expect(rect.top, t3.center.dy + kDragGhostDrop, reason: 'under the pointer, not on it');
      expect(rect.top, greaterThanOrEqualTo(t3.bottom), reason: 'clear of the tab it is held over');
      expect(rect.left, t3.center.dx - 50);
      expect(rect.width, 160);
      await letGo(tester, gesture);
      expect(copy, findsNothing, reason: 'gone once it is let go');

      // Grabbed at its far end, further in than the copy is wide: the copy
      // still stands at the pointer.
      gesture = await dragTo(tester, Offset(t1.left + 210, t1.center.dy), t3.center);
      rect = tester.getRect(copy);
      expect(rect.left, t3.center.dx - 136);
      expect(rect.right, greaterThan(t3.center.dx));
      await letGo(tester, gesture);
    });

    testWidgets('taken off the tab again, the mark goes, and letting go beside the strip does nothing', (tester) async {
      await pumpStrip(tester);
      final t3 = tabRect(tester, 't3');
      final gesture = await dragTab(tester, 't1', Offset(t3.right - 12, t3.center.dy));
      expect(after, findsOneWidget);
      await gesture.moveTo(Offset(t3.center.dx, t3.bottom + 90));
      await tester.pump();
      expect(after, findsNothing);
      expect(joining, findsNothing);
      await letGo(tester, gesture);
      nothingCalled();
    });

    testWidgets('held over its own place: no mark, and letting go does nothing', (tester) async {
      await pumpStrip(tester);
      final t2 = tabRect(tester, 't2');
      for (final where in [t2.center, Offset(t2.left + 12, t2.center.dy), Offset(t2.right - 12, t2.center.dy)]) {
        final gesture = await dragTab(tester, 't2', where);
        expect(joining, findsNothing);
        expect(before, findsNothing);
        expect(after, findsNothing);
        await letGo(tester, gesture);
        nothingCalled();
      }
    });

    testWidgets('a tab that is not pinned is not put beside a pinned one, but may join it', (tester) async {
      await pumpStrip(tester, pinned: {'t1'});
      final t1 = tabRect(tester, 't1');
      var gesture = await dragTab(tester, 't3', Offset(t1.right - 12, t1.center.dy));
      expect(after, findsNothing, reason: 'the strip keeps pinned tabs first: it would not stay there');
      expect(before, findsNothing);
      expect(joining, findsNothing);
      await letGo(tester, gesture);
      nothingCalled();

      gesture = await dragTab(tester, 't3', Offset(t1.left + 12, t1.center.dy));
      expect(before, findsNothing);
      await letGo(tester, gesture);
      nothingCalled();

      gesture = await dragTab(tester, 't3', t1.center);
      expect(joining, findsOneWidget);
      await letGo(tester, gesture);
      expect(merges, [('t3', 't1')]);
      expect(moves, isEmpty);
    });

    testWidgets('a pinned tab is put beside another pinned one, and not beside one that is not', (tester) async {
      await pumpStrip(tester, pinned: {'t1', 't2'});
      final t1 = tabRect(tester, 't1');
      final t4 = tabRect(tester, 't4');
      var gesture = await dragTab(tester, 't2', Offset(t1.left + 12, t1.center.dy));
      expect(before, findsOneWidget);
      await letGo(tester, gesture);
      expect(moves, [('t2', 't1', false)]);

      gesture = await dragTab(tester, 't2', Offset(t4.right - 12, t4.center.dy));
      expect(after, findsNothing);
      expect(before, findsNothing);
      await letGo(tester, gesture);
      expect(moves, [('t2', 't1', false)], reason: 'nothing more');
      expect(merges, isEmpty);
    });
  });

  group('a terminal dragged up out of a split', () {
    testWidgets('over a tab\'s middle it joins that tab\'s group', (tester) async {
      await pumpStrip(tester);
      final t2 = tabRect(tester, 't2');
      final gesture = await dragPane(tester, t2.center);
      expect(joining, findsOneWidget);
      expect(tester.getRect(tint).left, t2.left);
      expect(after, findsNothing);
      expect(before, findsNothing);
      await letGo(tester, gesture);
      expect(joins, [('leaf-1', 't2')]);
      expect(popOuts, isEmpty);
      expect(joining, findsNothing);
    });

    testWidgets('over a tab\'s edge it becomes a tab of its own beside that one', (tester) async {
      await pumpStrip(tester);
      final t2 = tabRect(tester, 't2');
      var gesture = await dragPane(tester, Offset(t2.right - 12, t2.center.dy));
      expect(after, findsOneWidget);
      expect(tester.getRect(after).right, t2.right);
      expect(joining, findsNothing);
      await letGo(tester, gesture);
      expect(popOuts, [('leaf-1', 't2', true)]);
      expect(after, findsNothing);

      gesture = await dragPane(tester, Offset(t2.left + 12, t2.center.dy));
      expect(before, findsOneWidget);
      await letGo(tester, gesture);
      expect(popOuts, [('leaf-1', 't2', true), ('leaf-1', 't2', false)]);
      expect(joins, isEmpty);
    });

    testWidgets('over the middle of the tab it is in: no mark, and it stays where it is', (tester) async {
      await pumpStrip(tester);
      final t1 = tabRect(tester, 't1');
      final gesture = await dragPane(tester, t1.center);
      expect(joining, findsNothing);
      expect(after, findsNothing, reason: 'not taken for the open space either');
      expect(before, findsNothing);
      await letGo(tester, gesture);
      nothingCalled();
    });

    testWidgets('over the edge of the tab it is in, it becomes a tab beside its group', (tester) async {
      await pumpStrip(tester);
      final t1 = tabRect(tester, 't1');
      final gesture = await dragPane(tester, Offset(t1.right - 12, t1.center.dy));
      expect(after, findsOneWidget);
      await letGo(tester, gesture);
      expect(popOuts, [('leaf-1', 't1', true)]);
    });

    testWidgets('over the strip\'s open space it becomes the last tab: the bar is after the last one', (tester) async {
      // (Wide enough for the tabs to leave room: at their widest they fill
      // a narrower strip, and then the tabs' edges are the way out.)
      await pumpStrip(tester, width: 2400);
      final t4 = tabRect(tester, 't4');
      final gesture = await dragPane(tester, Offset(t4.right + 200, t4.center.dy));
      expect(after, findsOneWidget);
      expect(tester.getRect(after).right, t4.right, reason: 'after the last tab, where the new one will stand');
      expect(joining, findsNothing);
      await letGo(tester, gesture);
      expect(popOuts, [('leaf-1', null, true)]);
      expect(after, findsNothing);
    });

    testWidgets('beside a pinned tab: no mark, and it stays where it is', (tester) async {
      await pumpStrip(tester, pinned: {'t2'});
      final t2 = tabRect(tester, 't2');
      var gesture = await dragPane(tester, Offset(t2.right - 12, t2.center.dy));
      expect(after, findsNothing, reason: 'not beside it, and not taken for the open space');
      expect(before, findsNothing);
      await letGo(tester, gesture);
      nothingCalled();

      gesture = await dragPane(tester, t2.center);
      expect(joining, findsOneWidget, reason: 'its group can still be joined');
      await letGo(tester, gesture);
      expect(joins, [('leaf-1', 't2')]);
    });
  });

  testWidgets('the last tabs closed while a terminal was held over the open space: no mark is left for the next ones', (tester) async {
    await pumpStrip(tester, width: 2400);
    final t4 = tabRect(tester, 't4');
    final gesture = await dragPane(tester, Offset(t4.right + 200, t4.center.dy));
    expect(after, findsOneWidget);
    await pumpStrip(tester, width: 2400, tabs: const []);
    expect(after, findsNothing);
    await letGo(tester, gesture);
    nothingCalled();
    await pumpStrip(tester, width: 2400);
    expect(after, findsNothing, reason: 'the mark went with what held it');
    expect(before, findsNothing);
    expect(joining, findsNothing);
  });

  testWidgets('something else dragged over the strip is not the strip\'s: no mark, and nothing done', (tester) async {
    await pumpStrip(tester, width: 2400);
    final t2 = tabRect(tester, 't2');
    final t4 = tabRect(tester, 't4');
    final card = tester.getCenter(find.text('a host card'));
    for (final where in [t2.center, Offset(t2.right - 12, t2.center.dy), Offset(t4.right + 200, t4.center.dy)]) {
      final gesture = await dragTo(tester, card, where);
      expect(joining, findsNothing);
      expect(before, findsNothing);
      expect(after, findsNothing);
      await letGo(tester, gesture);
      nothingCalled();
    }
  });

  testWidgets('a click on a tab still selects it: the parts that take a drag do not take the click', (tester) async {
    final selected = <String>[];
    tester.view.physicalSize = const Size(1600, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        syncHealthClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: PillBar(
              activeNav: NavSection.hosts,
              activeSessionId: 't1',
              sessions: [MapEntry('t1', _state('web-01')), MapEntry('t2', _state('db-01'))],
              onNavChanged: (_) {},
              onSessionSelected: selected.add,
              onSessionClosed: (_) {},
              onNewSession: () {},
              onCommandPalette: () {},
              onHelp: () {},
              onTabMove: (_, _, _) {},
              onTabMerge: (_, _) {},
              onLeafMoveToTab: (_, _) {},
              onLeafPopOut: (_, _, _) {},
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    final t2 = tabRect(tester, 't2');
    await tester.tapAt(Offset(t2.left + 12, t2.center.dy));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(Offset(t2.center.dx - 20, t2.center.dy));
    await tester.pump(const Duration(milliseconds: 400));
    expect(selected, ['t2', 't2'], reason: 'at its edge and at its middle');
  });
}
