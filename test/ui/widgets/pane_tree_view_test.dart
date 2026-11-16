import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/ui/widgets/pane_tree_view.dart';

/// The dividers between the panes of a tab: where one is dragged to is told
/// to whoever keeps the tree, a double click shares evenly again, and a
/// divider belongs to its split and to no other.
///
/// In 2.2.1, panes of a tab ended up skewed. One way there: a
/// dragged divider was kept by the widget that happened to stand in its
/// place, so the next tab's split, or the split a new pane made, took it
/// over.
/// What [parent] finds, from the top left: by its top, then its left.
class _ByPlace extends ChainedFinder {
  _ByPlace(super.parent);

  @override
  String describeMatch(Plurality plurality) => '${parent.describeMatch(plurality)} by place';

  @override
  String get description => 'dividers by place';

  @override
  Iterable<Element> filter(Iterable<Element> parentCandidates) {
    Offset at(Element e) => (e.renderObject! as RenderBox).localToGlobal(Offset.zero);
    return parentCandidates.toList()
      ..sort((a, b) {
        final pa = at(a), pb = at(b);
        return pa.dy != pb.dy ? pa.dy.compareTo(pb.dy) : pa.dx.compareTo(pb.dx);
      });
  }
}

void main() {
  const width = 1000.0;
  const height = 600.0;

  PaneLeaf t(String id) => PaneLeaf.single(sessionId: 's-$id', id: id);
  PaneSplit h(PaneNode a, PaneNode b, {double ratio = 0.5, String? id}) =>
      PaneSplit(first: a, second: b, axis: Axis.horizontal, ratio: ratio, id: id);
  PaneSplit v(PaneNode a, PaneNode b, {double ratio = 0.5, String? id}) =>
      PaneSplit(first: a, second: b, axis: Axis.vertical, ratio: ratio, id: id);

  Future<void> show(
    WidgetTester tester,
    PaneNode tree, {
    void Function(PaneSplit split, double ratio)? onRatioChanged,
  }) async {
    tester.view.physicalSize = const Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: PaneTreeView(
            node: tree,
            onRatioChanged: onRatioChanged,
            leafBuilder: (leaf, focused) => ColoredBox(
              key: ValueKey('pane-${leaf.id}'),
              color: const Color(0xFF101010),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    ));
  }

  Size pane(WidgetTester tester, String id) => tester.getSize(find.byKey(ValueKey('pane-$id')));

  /// The dividers on screen, left to right and top to bottom. (By where
  /// they stand: a divider lies over its split's panes, so it comes after
  /// the dividers inside them in the tree.)
  Finder dividers(Axis axis) => _ByPlace(find.byWidgetPredicate((w) =>
      w is MouseRegion &&
      w.cursor == (axis == Axis.horizontal ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow)));

  /// (A press also starts the wait for a second click, which runs out by
  /// itself.)
  Future<void> settle(WidgetTester tester) => tester.pump(kDoubleTapTimeout);

  Future<void> drag(WidgetTester tester, Finder divider, Offset by) async {
    await tester.drag(divider, by, kind: PointerDeviceKind.mouse);
    await settle(tester);
  }

  Future<void> doubleClick(WidgetTester tester, Finder divider) async {
    await tester.tap(divider, kind: PointerDeviceKind.mouse);
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(divider, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
  }

  /// How wide the first pane of a split of [total] is at [ratio]: its share,
  /// less half the 1px line the panes meet at (the divider's 6px hit area
  /// lies over that line, taking no room of its own).
  double first(double ratio, [double total = width]) => ratio * total - 0.5;

  testWidgets('the panes take the room the tree gives them', (tester) async {
    await show(tester, h(t('a'), v(t('b'), t('c'), ratio: 0.25), ratio: 0.4));
    expect(pane(tester, 'a').width, closeTo(first(0.4), 0.01));
    expect(pane(tester, 'a').height, height);
    expect(pane(tester, 'b').width, closeTo(first(0.6), 0.01));
    expect(pane(tester, 'b').height, closeTo(0.25 * height - 0.5, 0.01));
    expect(pane(tester, 'c').height, closeTo(0.75 * height - 0.5, 0.01));
    expect(dividers(Axis.horizontal), findsOneWidget);
    expect(dividers(Axis.vertical), findsOneWidget);
  });

  testWidgets('a divider that is dragged tells where it was let go, once', (tester) async {
    final tree = h(t('a'), t('b'));
    final told = <(String, double)>[];
    await show(tester, tree, onRatioChanged: (split, ratio) => told.add((split.id, ratio)));
    await drag(tester, dividers(Axis.horizontal), const Offset(100, 0));
    expect(told, hasLength(1));
    expect(told.single.$1, tree.id);
    expect(told.single.$2, closeTo(0.6, 1e-9));
    expect(pane(tester, 'a').width, closeTo(first(0.6), 0.01));
    expect(pane(tester, 'b').width, closeTo(first(0.4), 0.01));
    // To the left as well; a move up or down is no move of this divider.
    await drag(tester, dividers(Axis.horizontal), const Offset(-250, 40));
    expect(told.last.$2, closeTo(0.35, 1e-9));
    expect(told, hasLength(2));
  });

  testWidgets('one between rows is dragged up and down', (tester) async {
    final tree = v(t('a'), t('b'));
    final told = <double>[];
    await show(tester, tree, onRatioChanged: (split, ratio) => told.add(ratio));
    await drag(tester, dividers(Axis.vertical), const Offset(30, -60));
    expect(told.single, closeTo(0.4, 1e-9));
    expect(pane(tester, 'a').height, closeTo(0.4 * height - 0.5, 0.01));
  });

  testWidgets('it is told while it is still down only when it is let go', (tester) async {
    final told = <double>[];
    await show(tester, h(t('a'), t('b')), onRatioChanged: (split, ratio) => told.add(ratio));
    final gesture = await tester.startGesture(
      tester.getCenter(dividers(Axis.horizontal)),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(40, 0));
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(pane(tester, 'a').width, closeTo(first(0.6), 0.01), reason: 'the panes follow the pointer');
    expect(told, isEmpty);
    await gesture.up();
    await settle(tester);
    expect(told.single, closeTo(0.6, 1e-9));
  });

  testWidgets('a drag the system takes away is told where it had come to', (tester) async {
    final told = <double>[];
    await show(tester, h(t('a'), t('b')), onRatioChanged: (split, ratio) => told.add(ratio));
    final gesture = await tester.startGesture(
      tester.getCenter(dividers(Axis.horizontal)),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(100, 0));
    await gesture.cancel();
    await settle(tester);
    expect(told.single, closeTo(0.6, 1e-9));
    expect(pane(tester, 'a').width, closeTo(first(0.6), 0.01));
  });

  testWidgets('a press that moves nothing tells nothing', (tester) async {
    final told = <double>[];
    await show(tester, h(t('a'), t('b')), onRatioChanged: (split, ratio) => told.add(ratio));
    final gesture = await tester.startGesture(
      tester.getCenter(dividers(Axis.horizontal)),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.up();
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(told, isEmpty);
    // Dragged away and back to the very place it stood.
    final back = await tester.startGesture(
      tester.getCenter(dividers(Axis.horizontal)),
      kind: PointerDeviceKind.mouse,
    );
    await back.moveBy(const Offset(64, 0));
    await back.moveBy(const Offset(-64, 0));
    await back.up();
    await settle(tester);
    expect(told, isEmpty);
  });

  testWidgets('neither side is dragged under 15 % of the split', (tester) async {
    final told = <double>[];
    await show(tester, h(t('a'), t('b')), onRatioChanged: (split, ratio) => told.add(ratio));
    await drag(tester, dividers(Axis.horizontal), const Offset(480, 0));
    expect(told.last, 0.85);
    await drag(tester, dividers(Axis.horizontal), const Offset(-900, 0));
    expect(told.last, 0.15);
    expect(pane(tester, 'a').width, closeTo(first(0.15), 0.01));
  });

  testWidgets('one that already stands further out is dragged from where it stands, and no further out',
      (tester) async {
    // The first of eight columns is an eighth.
    PaneSplit eight() {
      PaneNode rest = t('p7');
      for (var i = 6; i >= 1; i--) {
        rest = PaneSplit.even(first: t('p$i'), second: rest, axis: Axis.horizontal);
      }
      return PaneSplit.even(first: t('p0'), second: rest, axis: Axis.horizontal);
    }

    final tree = eight();
    expect(tree.ratio, 0.125);
    final told = <(String, double)>[];
    await show(tester, tree, onRatioChanged: (split, ratio) => told.add((split.id, ratio)));
    await drag(tester, dividers(Axis.horizontal).first, const Offset(10, 0));
    expect(told.single.$1, tree.id);
    expect(told.single.$2, closeTo(0.135, 1e-9), reason: 'no jump to 15 % at the first pixel');
    // Another eight, dragged outwards: it stays where it stands.
    await show(tester, eight(), onRatioChanged: (split, ratio) => told.add((split.id, ratio)));
    expect(pane(tester, 'p0').width, closeTo(first(0.125), 0.01));
    await drag(tester, dividers(Axis.horizontal).first, const Offset(-60, 0));
    expect(told, hasLength(1), reason: 'it did not move');
    expect(pane(tester, 'p0').width, closeTo(first(0.125), 0.01));
    // Within one drag it goes back as far as it stood, and no further.
    await show(tester, eight(), onRatioChanged: (split, ratio) => told.add((split.id, ratio)));
    final gesture = await tester.startGesture(
      tester.getCenter(dividers(Axis.horizontal).first),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(15, 0));
    await gesture.moveBy(const Offset(-5, 0));
    await tester.pump();
    expect(pane(tester, 'p0').width, closeTo(first(0.135), 0.01));
    await gesture.moveBy(const Offset(-40, 0));
    await gesture.up();
    await settle(tester);
    expect(pane(tester, 'p0').width, closeTo(first(0.125), 0.01));
    expect(told, hasLength(1), reason: 'back where it stood');
    // Once it was let go further in, the next drag stops at 15 %.
    await drag(tester, dividers(Axis.horizontal).first, const Offset(175, 0));
    expect(told.last.$2, closeTo(0.3, 1e-9));
    await drag(tester, dividers(Axis.horizontal).first, const Offset(-250, 0));
    expect(told.last.$2, 0.15);
    told.removeRange(1, told.length);
    // The same at the far end: the last of eight has an eighth, its split a half.
    final farthest = PaneSplit(first: t('a'), second: t('b'), axis: Axis.horizontal, ratio: 0.9);
    await show(tester, farthest, onRatioChanged: (split, ratio) => told.add((split.id, ratio)));
    await drag(tester, dividers(Axis.horizontal), const Offset(60, 0));
    expect(told, hasLength(1));
    await drag(tester, dividers(Axis.horizontal), const Offset(-20, 0));
    expect(told.last.$2, closeTo(0.88, 1e-9));
  });

  testWidgets('a double click shares the split evenly again: by the panes each side holds', (tester) async {
    final tree = h(t('a'), h(t('b'), t('c')), ratio: 0.6);
    final told = <(String, double)>[];
    await show(tester, tree, onRatioChanged: (split, ratio) => told.add((split.id, ratio)));
    await doubleClick(tester, dividers(Axis.horizontal).first);
    expect(told.single.$1, tree.id);
    expect(told.single.$2, closeTo(1 / 3, 1e-9), reason: 'one column beside two');
    expect(pane(tester, 'a').width, closeTo(first(1 / 3), 0.01));
    // One that shares evenly already has nothing to tell.
    final even = h(t('a'), t('b'));
    await show(tester, even, onRatioChanged: (split, ratio) => told.add((split.id, ratio)));
    await doubleClick(tester, dividers(Axis.horizontal));
    expect(told, hasLength(1));
    // One that was dragged and not kept by anyone is put back on screen.
    await show(tester, even);
    await drag(tester, dividers(Axis.horizontal), const Offset(200, 0));
    expect(pane(tester, 'a').width, closeTo(first(0.7), 0.01));
    await doubleClick(tester, dividers(Axis.horizontal));
    expect(pane(tester, 'a').width, closeTo(first(0.5), 0.01));
  });

  testWidgets('the divider of a split inside another tells of that split, by its own room', (tester) async {
    final inner = h(t('b'), t('c'));
    final tree = h(t('a'), inner);
    final told = <(String, double)>[];
    await show(tester, tree, onRatioChanged: (split, ratio) => told.add((split.id, ratio)));
    // The two panes and the line they meet at.
    final room = pane(tester, 'b').width + pane(tester, 'c').width + 1;
    await drag(tester, dividers(Axis.horizontal).last, Offset(room / 10, 0));
    expect(told.single.$1, inner.id);
    expect(told.single.$2, closeTo(0.6, 1e-6));
    expect(pane(tester, 'a').width, closeTo(first(0.5), 0.01), reason: 'the outer divider did not move');
  });

  testWidgets('the divider stands where the tree says, when the tree says otherwise', (tester) async {
    final tree = h(t('a'), t('b'));
    await show(tester, tree);
    expect(pane(tester, 'a').width, closeTo(first(0.5), 0.01));
    await show(tester, tree.copyWith(ratio: 0.25));
    expect(pane(tester, 'a').width, closeTo(first(0.25), 0.01));
    // Also over one that was dragged on screen.
    await drag(tester, dividers(Axis.horizontal), const Offset(300, 0));
    expect(pane(tester, 'a').width, closeTo(first(0.55), 0.01));
    await show(tester, tree.copyWith(ratio: 0.4));
    expect(pane(tester, 'a').width, closeTo(first(0.4), 0.01));
  });

  testWidgets('a divider someone dragged is its split\'s: another split in its place stands where its own tree says',
      (tester) async {
    // Nobody keeps the tree here: where it was dragged to is kept on screen.
    final mine = h(t('a'), t('b'));
    await show(tester, mine);
    await drag(tester, dividers(Axis.horizontal), const Offset(200, 0));
    expect(pane(tester, 'a').width, closeTo(first(0.7), 0.01));
    // Another tab is shown: its split is another split.
    await show(tester, h(t('c'), t('d')));
    expect(pane(tester, 'c').width, closeTo(first(0.5), 0.01));
    // Back to the first: as its tree says (nobody kept the drag).
    await show(tester, mine);
    expect(pane(tester, 'a').width, closeTo(first(0.5), 0.01));
  });

  testWidgets('while it is the split it was, a dragged divider stays through what changes inside its sides',
      (tester) async {
    final tree = h(t('a'), t('b'));
    await show(tester, tree);
    await drag(tester, dividers(Axis.horizontal), const Offset(200, 0));
    // The pane on the right is split in two: the split above it is the same.
    await show(tester, tree.copyWith(second: v(t('b'), t('c'))));
    expect(pane(tester, 'a').width, closeTo(first(0.7), 0.01));
    expect(pane(tester, 'c').width, closeTo(first(0.3), 0.01));
  });
}
