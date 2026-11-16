import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/models/pane_layout.dart';
import 'package:zestssh/models/pane_tree.dart';

import 'pane_rooms.dart';

/// How the terminals of a tab are arranged: the room is shared by rows and
/// columns, what someone arranged is theirs, a tab nobody arranged stands in
/// a grid that grows with it, and an arrangement holds every terminal of the
/// tab or is not offered.
///
/// A bug in 2.2.1: adding terminals did not resize the others, so a fifth
/// could end up at about 10% of the width, and there was no layout for
/// a grid of five.
void main() {
  PaneLeaf t(String id) => PaneLeaf.single(sessionId: 's-$id', id: id);
  PaneLeaf sftp(String id) => PaneLeaf.single(sessionId: 's-$id', id: id, type: 'sftp');

  /// Side by side. With no [ratio] the two share evenly, as where nobody
  /// arranged anything; with one, the divider stands there.
  PaneSplit h(PaneNode a, PaneNode b, [double? ratio]) => ratio == null
      ? PaneSplit.even(first: a, second: b, axis: Axis.horizontal)
      : PaneSplit(first: a, second: b, axis: Axis.horizontal, ratio: ratio);

  /// One above the other; [ratio] as for [h].
  PaneSplit v(PaneNode a, PaneNode b, [double? ratio]) => ratio == null
      ? PaneSplit.even(first: a, second: b, axis: Axis.vertical)
      : PaneSplit(first: a, second: b, axis: Axis.vertical, ratio: ratio);

  List<PaneLeaf> panes(String ids) => [for (final id in ids.split('')) t(id)];

  group('The room is shared by rows and columns', () {
    test('panes side by side are as wide as each other, whichever way they were split off', () {
      // Each new one was split off the pane before it: a half, a quarter, an
      // eighth, a sixteenth.
      final chain = h(t('a'), h(t('b'), h(t('c'), h(t('d'), t('e'), 0.5), 0.5), 0.5), 0.5);
      expect(widths(chain), {'a': 50, 'b': 25, 'c': 13, 'd': 6, 'e': 6});
      expect(widths(rebalancePaneTree(chain)), {'a': 20, 'b': 20, 'c': 20, 'd': 20, 'e': 20});
      // Each new one was put beside all the others (tabs joined one by one).
      final joined = h(h(h(h(t('a'), t('b'), 0.5), t('c'), 0.5), t('d'), 0.5), t('e'), 0.5);
      expect(widths(joined), {'a': 6, 'b': 6, 'c': 13, 'd': 25, 'e': 50});
      expect(widths(rebalancePaneTree(joined)), {'a': 20, 'b': 20, 'c': 20, 'd': 20, 'e': 20});
    });

    test('a pane beside a stack is half the width, not a third of it', () {
      final tree = rebalancePaneTree(h(t('a'), v(t('b'), t('c'), 0.5), 0.2));
      expect(rooms(tree), ['a 0,0 50x100', 'b 50,0 50x50', 'c 50,50 50x50']);
    });

    test('rows share the height by how many there are, columns in a row the width', () {
      // Three on top, two below, one of the top ones split once more.
      final tree =
          rebalancePaneTree(v(h(h(t('a'), t('b'), 0.8), h(t('c'), t('d'), 0.3), 0.9), h(t('e'), t('f'), 0.5), 0.2));
      expect(rooms(tree), [
        'a 0,0 25x50',
        'b 25,0 25x50',
        'c 50,0 25x50',
        'd 75,0 25x50',
        'e 0,50 50x50',
        'f 50,50 50x50',
      ]);
      // A block of two columns beside one column takes two thirds.
      final block = rebalancePaneTree(h(v(h(t('a'), t('b'), 0.5), t('c'), 0.5), t('d'), 0.5));
      expect(rooms(block), ['a 0,0 33x50', 'b 33,0 33x50', 'd 67,0 33x100', 'c 0,50 67x50']);
    });

    test('eight side by side are an eighth each', () {
      PaneNode row = t('p0');
      for (var i = 1; i < 8; i++) {
        row = h(row, t('p$i'), 0.5);
      }
      final shares = widths(rebalancePaneTree(row)).values.toSet();
      expect(shares, {13, 12}, reason: 'twelve and a half, rounded either way');
      expect(kMinPaneShare, lessThanOrEqualTo(1 / 8));
      expect(kMaxPaneShare, greaterThanOrEqualTo(7 / 8), reason: 'seven beside one');
    });

    test('an SFTP leaf is no pane: it takes no room, and its split keeps its share', () {
      final tree = rebalancePaneTree(h(h(t('a'), h(t('b'), sftp('f'), 0.7), 0.5), t('c'), 0.5));
      expect(widths(withoutSftp(tree)), {'a': 33, 'b': 33, 'c': 33});
      final beside = (tree as PaneSplit).first as PaneSplit;
      expect((beside.second as PaneSplit).ratio, 0.7, reason: 'nothing to share with what is not shown');
      // Nothing but SFTP: nothing to share at all.
      final only = v(sftp('f'), sftp('g'), 0.3);
      expect((rebalancePaneTree(only) as PaneSplit).ratio, 0.3);
      expect(paneTracks(sftp('f'), Axis.horizontal), 0);
      expect(paneTracks(t('a'), Axis.vertical), 1);
      // Wherever the SFTP leaf hangs, the terminals are what is left.
      expect(withoutSftp(h(sftp('f'), t('a'), 0.5))!.allLeaves.single.id, 'a');
      expect(withoutSftp(h(t('a'), sftp('f'), 0.5))!.allLeaves.single.id, 'a');
      expect(widths(withoutSftp(h(sftp('f'), h(t('a'), t('b')), 0.5))), {'a': 50, 'b': 50});
      expect(widths(withoutSftp(h(h(t('a'), t('b')), sftp('f'), 0.5))), {'a': 50, 'b': 50});
      expect(withoutSftp(sftp('f')), isNull);
      expect(withoutSftp(only), isNull);
      expect(withoutSftp(null), isNull);
    });

    test('every split is still the split it was, and a pane the pane it was', () {
      final inner = h(t('a'), t('b'), 0.5);
      final tree = h(inner, t('c'), 0.5);
      final even = rebalancePaneTree(tree) as PaneSplit;
      expect(even.id, tree.id);
      expect((even.first as PaneSplit).id, inner.id);
      expect(even.allLeaves.map((l) => l.id), ['a', 'b', 'c']);
      expect(even.ratio, closeTo(2 / 3, 1e-9));
      expect(tree.ratio, 0.5, reason: 'the tree it was made from is not touched');
      expect(rebalancePaneTree(t('a')).allLeaves.single.id, 'a');
    });

    test('a split is told apart by its id, which it keeps when written and read', () {
      final a = h(t('a'), t('b'));
      final b = h(t('a'), t('b'));
      expect(a.id, isNot(b.id));
      expect(a.copyWith(ratio: 0.3).id, a.id);
      expect(a.copyWith(ratio: 0.3).ratio, 0.3);
      expect(a.copyWith(first: t('z')).allLeaves.map((l) => l.id), ['z', 'b']);
      final read = PaneNode.fromJson(a.toJson()) as PaneSplit;
      expect(read.id, a.id);
      // One written before splits had ids gets one when it is read.
      final old = PaneNode.fromJson(a.toJson()..remove('id')) as PaneSplit;
      expect(old.id, isNotEmpty);
      expect(old.id, isNot(a.id));
      // A share is never the whole room, nor none of it.
      expect(h(t('a'), t('b'), 0.01).ratio, kMinPaneShare);
      expect(h(t('a'), t('b'), 0.99).ratio, kMaxPaneShare);
      // Left unsaid, the two sides take half each.
      expect(PaneSplit(first: h(t('a'), t('b')), second: t('c'), axis: Axis.horizontal).ratio, 0.5);
    });

    test('what sharing evenly is: by the panes each side holds along the split', () {
      expect(evenPaneShare(t('a'), t('b'), Axis.horizontal), 0.5);
      expect(evenPaneShare(h(t('a'), t('b')), t('c'), Axis.horizontal), closeTo(2 / 3, 1e-12));
      expect(evenPaneShare(h(t('a'), t('b')), t('c'), Axis.vertical), 0.5, reason: 'two side by side are one row');
      expect(evenPaneShare(t('a'), v(t('b'), v(t('c'), t('d'))), Axis.vertical), 0.25);
      expect(evenPaneShare(t('a'), sftp('f'), Axis.horizontal), isNull);
      expect(evenPaneShare(sftp('f'), t('a'), Axis.horizontal), isNull);

      final made = PaneSplit.even(first: h(t('a'), t('b')), second: t('c'), axis: Axis.horizontal, id: 'k');
      expect(made.ratio, closeTo(2 / 3, 1e-12));
      expect(made.id, 'k');
      expect(made.axis, Axis.horizontal);
      expect(made.allLeaves.map((l) => l.id), ['a', 'b', 'c']);
      expect(PaneSplit.even(first: t('a'), second: t('b'), axis: Axis.vertical).axis, Axis.vertical);
      expect(PaneSplit.even(first: t('a'), second: sftp('f'), axis: Axis.horizontal).ratio, 0.5);
    });

    test('a split shares evenly until its divider is moved by more than a hair', () {
      expect(sharesEvenly(h(t('a'), t('b'), 0.5)), isTrue);
      expect(sharesEvenly(h(t('a'), t('b'), 0.5 + kEvenShareSlack / 2)), isTrue);
      expect(sharesEvenly(h(t('a'), t('b'), 0.5 - kEvenShareSlack / 2)), isTrue);
      expect(sharesEvenly(h(t('a'), t('b'), 0.5 + kEvenShareSlack * 1.5)), isFalse);
      expect(sharesEvenly(h(t('a'), t('b'), 0.5 - kEvenShareSlack * 1.5)), isFalse);
      expect(kEvenShareSlack, lessThan(0.005), reason: 'under what a divider is dragged by on purpose');
      expect(sharesEvenly(h(h(t('a'), t('b')), t('c'), 0.5)), isFalse, reason: 'two columns beside one are two thirds');
      expect(sharesEvenly(h(t('a'), sftp('f'), 0.9)), isTrue, reason: 'nothing to share with what is not shown');

      expect(sharedEvenly(t('a')), isTrue);
      expect(sharedEvenly(h(h(t('a'), t('b')), t('c'))), isTrue);
      expect(sharedEvenly(h(h(t('a'), t('b'), 0.6), t('c'))), isFalse, reason: 'a split of its first side');
      expect(sharedEvenly(h(t('c'), h(t('a'), t('b'), 0.6))), isFalse, reason: 'a split of its second side');
      expect(sharedEvenly(h(h(t('a'), t('b')), t('c'), 0.5)), isFalse, reason: 'itself');
    });

    test('more side by side than a share can be small: the least share counts as even', () {
      PaneNode row = t('p11');
      for (var i = 10; i >= 0; i--) {
        row = h(t('p$i'), row);
      }
      expect((row as PaneSplit).ratio, kMinPaneShare, reason: 'a twelfth is under the least');
      expect(sharedEvenly(row), isTrue);
      expect(evenPaneShare(row, t('z'), Axis.horizontal), kMaxPaneShare, reason: 'twelve beside one');
    });
  });

  group('What someone arranged is theirs', () {
    test('a divider someone moved stays where it was put when a pane is split elsewhere', () {
      final before = h(t('a'), t('b'), 0.7);
      final after = replacePaneLeaf(before, 'b', h(t('b'), t('c'), 0.5));
      expect(widths(rebalancePaneTree(after, since: before)), {'a': 70, 'b': 15, 'c': 15});
      // Not told how the tree stood, every split shares evenly.
      expect(widths(rebalancePaneTree(after)), {'a': 33, 'b': 33, 'c': 33});
    });

    test('dividers nobody moved share again', () {
      final before = h(t('a'), h(t('b'), t('c')));
      final after = replacePaneLeaf(before, 'c', h(t('c'), t('d'), 0.5));
      expect(widths(after), {'a': 33, 'b': 33, 'c': 17, 'd': 17}, reason: 'as the split alone leaves it');
      expect(widths(rebalancePaneTree(after, since: before)), {'a': 25, 'b': 25, 'c': 25, 'd': 25});
    });

    test('each divider by itself: the one that was moved stays, the others share again', () {
      // a | (b | c): the inner divider was moved, the outer one was not.
      final inner = h(t('a'), h(t('b'), t('c'), 0.75));
      expect(widths(inner), {'a': 33, 'b': 50, 'c': 17});
      final more = replacePaneLeaf(inner, 'a', h(t('a'), t('d'), 0.5));
      expect(widths(rebalancePaneTree(more, since: inner)), {'a': 25, 'd': 25, 'b': 38, 'c': 13});
      // A moved divider inside the first side is kept as well.
      const moved = 0.75;
      final first = h(h(t('a'), t('b'), moved), t('c'));
      final grown = replacePaneLeaf(first, 'c', h(t('c'), t('d'), 0.5));
      expect(widths(rebalancePaneTree(grown, since: first)), {'a': 38, 'b': 13, 'c': 25, 'd': 25});
      // The other way round: the outer was moved, the inner was not.
      final outer = h(t('a'), h(t('b'), t('c')), 0.6);
      final wider = replacePaneLeaf(outer, 'c', h(t('c'), t('d'), 0.5));
      expect(widths(rebalancePaneTree(wider, since: outer)), {'a': 60, 'b': 13, 'c': 13, 'd': 13});
    });

    test('a split that was not there before shares evenly, however it was made', () {
      final before = h(t('a'), t('b'));
      final after = replacePaneLeaf(before, 'b', h(t('b'), t('c'), 0.9));
      expect(widths(rebalancePaneTree(after, since: before)), {'a': 33, 'b': 33, 'c': 33});
    });

    test('when a pane goes, the same holds', () {
      final moved = h(t('a'), h(t('b'), t('c')), 0.6);
      expect(widths(rebalancePaneTree(removePaneLeaf(moved, 'c')!, since: moved)), {'a': 60, 'b': 40});
      final even = h(t('a'), h(t('b'), t('c')));
      expect(widths(removePaneLeaf(even, 'c')), {'a': 33, 'b': 67}, reason: 'as the removal alone leaves it');
      expect(widths(rebalancePaneTree(removePaneLeaf(even, 'c')!, since: even)), {'a': 50, 'b': 50});
    });

    test('the shares of an arrangement that is not even by design are kept', () {
      final tree = treeOfPreset(LayoutPreset.oneAndTwo, panes('abc'))!;
      final more = replacePaneLeaf(tree, 'c', h(t('c'), t('d'), 0.5));
      expect(rooms(rebalancePaneTree(more, since: tree)),
          ['a 0,0 67x100', 'b 67,0 33x50', 'c 67,50 17x50', 'd 83,50 17x50']);
    });

    test('a divider put back to even is nobody\'s again', () {
      final moved = h(t('a'), t('b'), 0.7);
      final back = withSplitRatio(moved, moved.id, 0.5);
      final after = replacePaneLeaf(back, 'b', h(t('b'), t('c'), 0.5));
      expect(widths(rebalancePaneTree(after, since: back)), {'a': 33, 'b': 33, 'c': 33});
    });

    test('opening SFTP beside a pane moves no divider', () {
      for (final before in [h(t('a'), t('b'), 0.7), h(t('a'), t('b'))]) {
        final after = replacePaneLeaf(before, 'b', h(t('b'), sftp('f'), 0.5));
        final settled = rebalancePaneTree(after, since: before);
        expect(widths(withoutSftp(settled)), widths(before));
        expect(sftpLeavesOf(settled).map((l) => l.id), ['f']);
      }
    });

    test('where a divider was dragged to is kept by its split, and by no other', () {
      final inner = h(t('b'), t('c'));
      final tree = h(t('a'), inner);
      final dragged = withSplitRatio(tree, inner.id, 0.8) as PaneSplit;
      expect((dragged.second as PaneSplit).ratio, 0.8);
      expect(dragged.ratio, tree.ratio);
      expect(dragged.id, tree.id);
      expect((withSplitRatio(tree, tree.id, 0.25) as PaneSplit).ratio, 0.25);
      expect(((withSplitRatio(tree, tree.id, 0.25) as PaneSplit).second as PaneSplit).ratio, 0.5);
      // In the first side as well as in the second.
      final left = h(inner, t('a'));
      expect(((withSplitRatio(left, inner.id, 0.3) as PaneSplit).first as PaneSplit).ratio, 0.3);
      // A split that is not there changes nothing; nor is a share ever the whole room.
      expect(widths(withSplitRatio(tree, 'nobody', 0.9)), widths(tree));
      expect((withSplitRatio(tree, tree.id, 2) as PaneSplit).ratio, kMaxPaneShare);
      expect(withSplitRatio(t('a'), 'x', 0.3).allLeaves.single.id, 'a');
    });
  });

  group('The grid of a tab nobody arranged', () {
    test('up to three stand side by side, from four on in two rows, from nine in three', () {
      expect({for (var n = 0; n <= 12; n++) n: tileRows(n)}, {
        0: <int>[],
        1: [1],
        2: [2],
        3: [3],
        4: [2, 2],
        5: [3, 2],
        6: [3, 3],
        7: [4, 3],
        8: [4, 4],
        9: [3, 3, 3],
        10: [4, 3, 3],
        11: [4, 4, 3],
        12: [4, 4, 4],
      });
      expect(tileRows(-1), isEmpty);
    });

    test('five terminals: three on top, two below, every one of a row as wide as the next', () {
      final tree = tilePanes(panes('abcde'));
      expect(rooms(tree), ['a 0,0 33x50', 'b 33,0 33x50', 'c 67,0 33x50', 'd 0,50 50x50', 'e 50,50 50x50']);
      expect(rowsOf(tree), [3, 2]);
      expect(isTiled(tree), isTrue);
    });

    test('each number of them, in reading order', () {
      List<String> ids(int n) => [for (var i = 0; i < n; i++) 'p$i'];
      PaneNode grid(int n) => tilePanes([for (final id in ids(n)) t(id)]);
      expect(rooms(grid(1)), ['p0 0,0 100x100']);
      expect(rooms(grid(2)), ['p0 0,0 50x100', 'p1 50,0 50x100']);
      expect(rooms(grid(3)), ['p0 0,0 33x100', 'p1 33,0 33x100', 'p2 67,0 33x100']);
      expect(rooms(grid(4)), ['p0 0,0 50x50', 'p1 50,0 50x50', 'p2 0,50 50x50', 'p3 50,50 50x50']);
      expect(widths(grid(7)).values, [25, 25, 25, 25, 33, 33, 33]);
      expect(widths(grid(8)).values.toSet(), {25});
      expect(rooms(grid(9)).map((r) => r.split(' ').last).toSet(), {'33x33'});
      for (var n = 1; n <= 12; n++) {
        expect(grid(n).allLeaves.map((l) => l.id), ids(n), reason: '$n in order');
        expect(isTiled(grid(n)), isTrue, reason: '$n');
      }
    });

    test('what counts as standing in the grid is the rows, not how the splits were nested', () {
      expect(rowsOf(t('a')), [1]);
      expect(rowsOf(h(h(t('a'), t('b')), t('c'))), [3]);
      expect(rowsOf(h(t('a'), h(t('b'), t('c')))), [3]);
      expect(rowsOf(v(t('a'), t('b'))), [1, 1]);
      expect(rowsOf(v(v(h(t('a'), t('b')), t('c')), h(t('d'), t('e')))), [2, 1, 2]);
      // A pane beside a stack is no rows of panes.
      expect(rowsOf(h(t('a'), v(t('b'), t('c')))), isNull);
      expect(rowsOf(v(t('a'), h(t('b'), v(t('c'), t('d'))))), isNull);
      expect(rowsOf(v(h(t('b'), v(t('c'), t('d'))), t('a'))), isNull);

      expect(isTiled(h(h(t('a'), t('b')), t('c'))), isTrue);
      expect(isTiled(h(t('a'), h(t('b'), t('c')))), isTrue);
      expect(isTiled(v(h(t('a'), t('b')), h(t('c'), t('d')))), isTrue);
      expect(isTiled(v(t('a'), t('b'))), isFalse, reason: 'two stand side by side when nobody arranged them');
      expect(isTiled(h(h(t('a'), t('b')), h(t('c'), t('d')))), isFalse, reason: 'four in one row is a choice');
      expect(isTiled(v(h(t('a'), t('b')), h(t('c'), h(t('d'), t('e'))))), isFalse, reason: 'two on top, three below');
      expect(isTiled(v(h(t('a'), t('b')), t('c'))), isFalse, reason: 'three are one row');
      expect(isTiled(h(t('a'), v(t('b'), t('c')))), isFalse);
      // The SFTP leaf at its side changes nothing; a tab of SFTP alone has no grid.
      expect(isTiled(h(h(t('a'), t('b')), sftp('f'), 0.7)), isTrue);
      expect(isTiled(sftp('f')), isFalse);
      expect(isTiled(null), isFalse);
    });

    test('a tab stands in its grid only while nobody moved a divider', () {
      final grid = tilePanes(panes('abcd')) as PaneSplit;
      expect(isTiled(grid), isTrue);
      expect(isTiled(withSplitRatio(grid, grid.id, 0.6)), isFalse, reason: 'the upper row made taller');
      expect(isTiled(withSplitRatio(grid, (grid.first as PaneSplit).id, 0.4)), isFalse, reason: 'a column made narrower');
      expect(isTiled(withSplitRatio(grid, (grid.second as PaneSplit).id, 0.4)), isFalse);
      expect(isTiled(withSplitRatio(grid, grid.id, 0.5 + kEvenShareSlack / 2)), isTrue, reason: 'a hair is no choice');
      expect(isTiled(h(t('a'), t('b'), 0.7)), isFalse);
      // Splits left at a half each are no grid of three: the first two are a third between them.
      expect(isTiled(h(h(t('a'), t('b'), 0.5), t('c'), 0.5)), isFalse);
    });
  });

  group('A terminal joins a tab', () {
    test('a tab nobody arranged grows as a grid: no pane is ever a sliver', () {
      PaneNode tab = t('p0');
      final seen = <int, List<String>>{};
      for (var n = 2; n <= 8; n++) {
        tab = withPaneAdded(tab, t('p${n - 1}'));
        expect(isTiled(tab), isTrue, reason: '$n');
        seen[n] = rooms(tab);
        expect(tab.allLeaves.map((l) => l.id), [for (var i = 0; i < n; i++) 'p$i']);
      }
      expect(seen[2], ['p0 0,0 50x100', 'p1 50,0 50x100']);
      expect(seen[5], ['p0 0,0 33x50', 'p1 33,0 33x50', 'p2 67,0 33x50', 'p3 0,50 50x50', 'p4 50,50 50x50']);
      expect(seen[8]!.map((r) => r.split(' ').last).toSet(), {'25x50'});
    });

    test('a row someone made gets longer', () {
      // Four in a row is a choice: by themselves four stand in two rows.
      final four = treeOfPreset(LayoutPreset.fourColumns, panes('abcd'))!;
      expect(rooms(withPaneAdded(four, t('e'))),
          ['a 0,0 20x100', 'b 20,0 20x100', 'c 40,0 20x100', 'd 60,0 20x100', 'e 80,0 20x100']);
      // Two side by side, the divider moved: it stays, and the newcomer
      // shares the room of the pane it stands beside.
      expect(widths(withPaneAdded(h(t('a'), t('b'), 0.7), t('c'))), {'a': 70, 'b': 15, 'c': 15});
    });

    test('a stack someone made gets taller', () {
      final stack = treeOfPreset(LayoutPreset.stacked, panes('ab'))!;
      final three = withPaneAdded(stack, t('c'));
      expect(rooms(three), ['a 0,0 100x33', 'b 0,33 100x33', 'c 0,67 100x33']);
      expect(rooms(withPaneAdded(three, t('d'))).map((r) => r.split(' ').last).toSet(), {'100x25'});
    });

    test('beside a large pane, the stack gets one more', () {
      final tree = treeOfPreset(LayoutPreset.oneAndTwo, panes('abc'))!;
      final more = withPaneAdded(tree, t('d'));
      expect(rooms(more), ['a 0,0 67x100', 'b 67,0 33x33', 'c 67,33 33x33', 'd 67,67 33x33']);
      expect(presetOf(more), LayoutPreset.oneAndThree);
      // The large pane on the right: the newcomer stands beside it.
      final right = treeOfPreset(LayoutPreset.twoAndOne, panes('abc'))!;
      expect(rooms(withPaneAdded(right, t('d'))), ['a 0,0 33x50', 'c 33,0 33x100', 'd 67,0 33x100', 'b 0,50 33x50']);
    });

    test('a grid someone made their own gets one more in its shortest row, the topmost of equals', () {
      // Two rows of two, the upper row made taller.
      final grid = tilePanes(panes('abcd')) as PaneSplit;
      final mine = withSplitRatio(grid, grid.id, 0.7);
      final five = withPaneAdded(mine, t('e'));
      expect(rooms(five), ['a 0,0 33x70', 'b 33,0 33x70', 'e 67,0 33x70', 'c 0,70 50x30', 'd 50,70 50x30']);
      // The next one goes below, where there are fewer.
      final six = withPaneAdded(five, t('f'));
      expect(rooms(six),
          ['a 0,0 33x70', 'b 33,0 33x70', 'e 67,0 33x70', 'c 0,70 33x30', 'd 33,70 33x30', 'f 67,70 33x30']);
      // Three rows, the middle one the shortest.
      final rows = v(h(t('a'), t('b')), v(t('c'), h(t('d'), t('e'))), 0.5);
      expect(rowsOf(withPaneAdded(rows, t('f'))), [2, 2, 2]);
      expect(withPaneAdded(rows, t('f')).allLeaves.map((l) => l.id), ['a', 'b', 'c', 'f', 'd', 'e']);
    });

    test('any other arrangement: the newcomer stands after the last pane, the way that one stands', () {
      // One beside four: the lower row of the four gets it.
      final tree = treeOfPreset(LayoutPreset.oneAndFour, panes('abcde'))!;
      expect(rooms(withPaneAdded(tree, t('f'))),
          ['a 0,0 50x100', 'b 50,0 25x50', 'c 75,0 25x50', 'd 50,50 17x50', 'e 67,50 17x50', 'f 83,50 17x50']);
    });

    test('a whole tab that joins: two grids become one grid, in order', () {
      final joined = withTreeAdded(h(t('a'), t('b')), h(t('c'), h(t('d'), t('e'))));
      expect(rowsOf(joined), [3, 2]);
      expect(joined.allLeaves.map((l) => l.id), ['a', 'b', 'c', 'd', 'e']);
      expect(isTiled(joined), isTrue);
    });

    test('a tab of several that joins with an arrangement of its own keeps it, at the right of what was there', () {
      // Two side by side are joined by a stack of two whose divider was moved.
      final joined = withTreeAdded(h(t('a'), t('b')), v(t('c'), t('d'), 0.8));
      expect(rooms(joined), ['a 0,0 33x100', 'b 33,0 33x100', 'c 67,0 33x80', 'd 67,80 33x20']);
      // What was there keeps its own as well.
      final mine = withTreeAdded(h(t('a'), t('b'), 0.7), v(t('c'), t('d')));
      expect(rooms(mine), ['a 0,0 47x100', 'b 47,0 20x100', 'c 67,0 33x50', 'd 67,50 33x50']);
      // A grid joined by a tab that is no grid.
      final grid = withTreeAdded(tilePanes(panes('abcd')), v(t('e'), t('f')));
      expect(rooms(grid),
          ['a 0,0 33x50', 'b 33,0 33x50', 'e 67,0 33x50', 'c 0,50 33x50', 'd 33,50 33x50', 'f 67,50 33x50']);
    });

    test('a place to connect that stands empty is filled first, where it stands', () {
      final withRoom = treeOfPreset(LayoutPreset.grid2x2, panes('ab'))!;
      expect(rooms(withRoom), ['a 0,0 50x50', 'b 50,0 50x50', '- 0,50 50x50', '- 50,50 50x50']);
      final one = withPaneAdded(withRoom, t('c'));
      expect(rooms(one), ['a 0,0 50x50', 'b 50,0 50x50', 'c 0,50 50x50', '- 50,50 50x50']);
      // A tab of three joins: two fill the places, the third gets a pane of its own.
      final more = withTreeAdded(withRoom, h(t('c'), h(t('d'), t('e'))));
      expect(more.allLeaves.where((l) => l.isPlaceholder), isEmpty);
      expect(more.allLeaves.map((l) => l.id), ['a', 'b', 'c', 'd', 'e']);
      expect(rowsOf(more), [3, 2], reason: 'a full grid of four and one more are a grid of five');
      // In an arrangement that is no grid, the place is filled and nothing else moves.
      final beside = treeOfPreset(LayoutPreset.oneAndTwo, panes('ab'))!;
      expect(rooms(withPaneAdded(beside, t('c'))), ['a 0,0 67x100', 'b 67,0 33x50', 'c 67,50 33x50']);
      // Places to connect that come along are not carried in, and what came
      // with them shares the room they leave.
      final spare = withTreeAdded(t('a'), treeOfPreset(LayoutPreset.sideBySide, [t('b')])!);
      expect(spare.allLeaves.map((l) => l.id), ['a', 'b']);
      final threeOfFour = withTreeAdded(v(t('a'), t('b')), treeOfPreset(LayoutPreset.fourColumns, panes('cde'))!);
      expect(rooms(threeOfFour),
          ['a 0,0 25x50', 'c 25,0 25x100', 'd 50,0 25x100', 'e 75,0 25x100', 'b 0,50 25x50']);
      // An empty place on either side of what joins stays behind.
      expect(withTreeAdded(t('a'), h(PaneLeaf.placeholder(), t('b'), 0.5)).allLeaves.map((l) => l.id), ['a', 'b']);
      expect(withTreeAdded(t('a'), h(t('b'), PaneLeaf.placeholder(), 0.5)).allLeaves.map((l) => l.id), ['a', 'b']);
      // Nothing but places to connect joins: nothing changes.
      final none = withTreeAdded(h(t('a'), t('b'), 0.7), treeOfPreset(LayoutPreset.sideBySide, const [])!);
      expect(widths(none), {'a': 70, 'b': 30});
    });

    test('the SFTP dock of the tab stays its dock, and is not counted', () {
      final tab = h(h(t('a'), t('b')), sftp('f'), 0.7);
      final more = withPaneAdded(tab, t('c'));
      expect(sftpLeavesOf(more).map((l) => l.id), ['f']);
      expect(rooms(withoutSftp(more)), ['a 0,0 33x100', 'b 33,0 33x100', 'c 67,0 33x100']);
      // A tab that joins with a dock of its own: the one that was here stays.
      final both = withTreeAdded(tab, h(t('c'), sftp('g'), 0.5));
      expect(sftpLeavesOf(both).map((l) => l.id), ['f']);
      expect(withoutSftp(both)!.allLeaves.map((l) => l.id), ['a', 'b', 'c']);
      // Where there was none, the newcomer's is taken along.
      final taken = withTreeAdded(h(t('a'), t('b')), h(t('c'), sftp('g'), 0.5));
      expect(sftpLeavesOf(taken).map((l) => l.id), ['g']);
      expect(withoutSftp(taken)!.allLeaves.map((l) => l.id), ['a', 'b', 'c']);
      // A tab of SFTP alone that joins brings its dock and no pane.
      final dockOnly = withTreeAdded(h(t('a'), t('b')), sftp('g'));
      expect(withoutSftp(dockOnly)!.allLeaves.map((l) => l.id), ['a', 'b']);
      expect(sftpLeavesOf(dockOnly).map((l) => l.id), ['g']);
      // A tab that was SFTP alone gets its first terminal, and a tab that
      // joins it stands as it stood.
      final first = withPaneAdded(sftp('f'), t('a'));
      expect(withoutSftp(first)!.allLeaves.map((l) => l.id), ['a']);
      expect(sftpLeavesOf(first).map((l) => l.id), ['f']);
      final asItWas = withTreeAdded(sftp('f'), h(t('a'), t('b'), 0.7));
      expect(widths(withoutSftp(asItWas)), {'a': 70, 'b': 30});
      // The dock stays at the side of an arrangement someone made, too.
      final arranged = withPaneAdded(h(v(t('a'), t('b')), sftp('f'), 0.7), t('c'));
      expect(sftpLeavesOf(arranged).map((l) => l.id), ['f']);
      expect(rooms(withoutSftp(arranged)), ['a 0,0 100x33', 'b 0,33 100x33', 'c 0,67 100x33']);
      // Nothing joins a tab of SFTP alone: it is left as it is.
      expect(withTreeAdded(sftp('f'), treeOfPreset(LayoutPreset.sideBySide, const [])!).allLeaves.single.id, 'f');
    });
  });

  group('A terminal leaves a tab', () {
    test('a tab that stood in its grid stands in the grid for what is left', () {
      final five = tilePanes(panes('abcde'));
      final settled = settledAfterRemoval(five, removePaneLeaf(five, 'e')!);
      expect(rooms(settled), ['a 0,0 50x50', 'b 50,0 50x50', 'c 0,50 50x50', 'd 50,50 50x50']);
      expect(isTiled(settled), isTrue);
      // Whichever one goes, the ones that stay keep their order.
      final other = settledAfterRemoval(five, removePaneLeaf(five, 'b')!);
      expect(rooms(other), ['a 0,0 50x50', 'c 50,0 50x50', 'd 0,50 50x50', 'e 50,50 50x50']);
    });

    test('a tab someone arranged keeps its arrangement, the room nobody arranged shared again', () {
      // One beside a stack and a third column; the column goes.
      final before = h(t('a'), h(v(t('b'), t('c')), t('d')));
      final settled = settledAfterRemoval(before, removePaneLeaf(before, 'd')!);
      expect(rooms(settled), ['a 0,0 50x100', 'b 50,0 50x50', 'c 50,50 50x50']);
      // With the first divider moved, it stays where it was put.
      final moved = withSplitRatio(before, before.id, 0.6);
      expect(rooms(settledAfterRemoval(moved, removePaneLeaf(moved, 'd')!)),
          ['a 0,0 60x100', 'b 60,0 40x50', 'c 60,50 40x50']);
      // A grid with a row made taller is no longer the app's to make again.
      final grid = tilePanes(panes('abcd')) as PaneSplit;
      final mine = withSplitRatio(grid, grid.id, 0.7);
      expect(rooms(settledAfterRemoval(mine, removePaneLeaf(mine, 'd')!)),
          ['a 0,0 50x70', 'b 50,0 50x70', 'c 0,70 100x30']);
    });

    test('the SFTP dock stays; a tab left with SFTP alone is left as it is', () {
      final before = h(h(t('a'), h(t('b'), t('c'))), sftp('f'), 0.7);
      final settled = settledAfterRemoval(before, removePaneLeaf(before, 'b')!);
      expect(sftpLeavesOf(settled).map((l) => l.id), ['f']);
      expect(widths(withoutSftp(settled)), {'a': 50, 'c': 50});
      expect(settledAfterRemoval(h(t('a'), sftp('f'), 0.5), sftp('f')).allLeaves.single.id, 'f');
    });
  });

  group('The arrangements a person can choose', () {
    test('there is one for every number of terminals up to eight, and each holds what it says', () {
      final byPanes = <int, List<String>>{};
      for (final p in LayoutPreset.values) {
        byPanes.putIfAbsent(p.panes, () => []).add(p.name);
      }
      expect(byPanes, {
        1: ['single'],
        2: ['sideBySide', 'stacked'],
        3: ['threeColumns', 'threeRows', 'oneAndTwo', 'twoAndOne'],
        4: ['grid2x2', 'fourColumns', 'oneAndThree'],
        5: ['threeAndTwo', 'twoAndThree', 'oneAndFour'],
        6: ['grid3x2', 'grid2x3'],
        7: ['fourAndThree', 'threeAndFour'],
        8: ['grid4x2', 'grid2x4'],
      });
    });

    test('the numbers kept for the next launch are the ones they always were', () {
      expect({for (final p in LayoutPreset.values.take(8)) p.name: p.number}, {
        'single': 5,
        'sideBySide': 1,
        'stacked': 2,
        'threeColumns': 3,
        'threeRows': 8,
        'oneAndTwo': 6,
        'twoAndOne': 7,
        'grid2x2': 4,
      });
      expect(LayoutPreset.grid3x2.number, 9);
      expect(LayoutPreset.grid2x3.number, 10);
      final numbers = LayoutPreset.values.map((p) => p.number).toList();
      expect(numbers.toSet(), hasLength(numbers.length), reason: 'no number stands for two');
      for (final p in LayoutPreset.values) {
        expect(LayoutPreset.byNumber(p.number), p);
        expect(layoutPresetNumber(p), p.number);
      }
      expect(LayoutPreset.byNumber(0), isNull);
      expect(LayoutPreset.byNumber(99), isNull);
    });

    test('each as it stands on screen', () {
      List<String> of(LayoutPreset p) {
        var i = 0;
        return rooms(treeOfPreset(p, [for (var n = 0; n < p.panes; n++) t('${i++}')]));
      }

      expect(of(LayoutPreset.single), ['0 0,0 100x100']);
      expect(of(LayoutPreset.sideBySide), ['0 0,0 50x100', '1 50,0 50x100']);
      expect(of(LayoutPreset.stacked), ['0 0,0 100x50', '1 0,50 100x50']);
      expect(of(LayoutPreset.threeColumns), ['0 0,0 33x100', '1 33,0 33x100', '2 67,0 33x100']);
      expect(of(LayoutPreset.threeRows), ['0 0,0 100x33', '1 0,33 100x33', '2 0,67 100x33']);
      expect(of(LayoutPreset.oneAndTwo), ['0 0,0 67x100', '1 67,0 33x50', '2 67,50 33x50']);
      expect(of(LayoutPreset.twoAndOne), ['0 0,0 33x50', '2 33,0 67x100', '1 0,50 33x50']);
      expect(of(LayoutPreset.grid2x2), ['0 0,0 50x50', '1 50,0 50x50', '2 0,50 50x50', '3 50,50 50x50']);
      expect(of(LayoutPreset.fourColumns), ['0 0,0 25x100', '1 25,0 25x100', '2 50,0 25x100', '3 75,0 25x100']);
      expect(of(LayoutPreset.oneAndThree), ['0 0,0 67x100', '1 67,0 33x33', '2 67,33 33x33', '3 67,67 33x33']);
      expect(of(LayoutPreset.threeAndTwo),
          ['0 0,0 33x50', '1 33,0 33x50', '2 67,0 33x50', '3 0,50 50x50', '4 50,50 50x50']);
      expect(of(LayoutPreset.twoAndThree),
          ['0 0,0 50x50', '1 50,0 50x50', '2 0,50 33x50', '3 33,50 33x50', '4 67,50 33x50']);
      expect(of(LayoutPreset.oneAndFour),
          ['0 0,0 50x100', '1 50,0 25x50', '2 75,0 25x50', '3 50,50 25x50', '4 75,50 25x50']);
      expect(of(LayoutPreset.grid3x2).map((r) => r.split(' ').last).toSet(), {'33x50'});
      expect(of(LayoutPreset.grid2x3).map((r) => r.split(' ').last).toSet(), {'50x33'});
      expect(of(LayoutPreset.fourAndThree).map((r) => r.split(' ').last), [
        '25x50', '25x50', '25x50', '25x50', '33x50', '33x50', '33x50', //
      ]);
      expect(of(LayoutPreset.threeAndFour).map((r) => r.split(' ').last), [
        '33x50', '33x50', '33x50', '25x50', '25x50', '25x50', '25x50', //
      ]);
      expect(of(LayoutPreset.grid4x2).map((r) => r.split(' ').last).toSet(), {'25x50'});
      expect(of(LayoutPreset.grid2x4).map((r) => r.split(' ').last).toSet(), {'50x25'});
      for (final p in LayoutPreset.values) {
        expect(of(p), hasLength(p.panes), reason: p.name);
        expect(of(p).map((r) => r.split(' ').first), unorderedEquals([for (var n = 0; n < p.panes; n++) '$n']));
      }
    });

    test('one that has panes to spare shows them as places to connect; one too small is not made', () {
      final tree = treeOfPreset(LayoutPreset.grid2x2, panes('abc'))!;
      expect(rooms(tree), ['a 0,0 50x50', 'b 50,0 50x50', 'c 0,50 50x50', '- 50,50 50x50']);
      expect(tree.allLeaves.last.isPlaceholder, isTrue);
      expect(tree.allLeaves.last.type, 'terminal');
      expect(treeOfPreset(LayoutPreset.sideBySide, panes('abc')), isNull);
      expect(treeOfPreset(LayoutPreset.single, panes('ab')), isNull);
      expect(LayoutPreset.grid2x2.fits(4), isTrue);
      expect(LayoutPreset.grid2x2.fits(5), isFalse);
      expect(LayoutPreset.grid2x2.fits(0), isTrue);
      // With nothing to put in it, it is all places to connect.
      expect(treeOfPreset(LayoutPreset.sideBySide, const [])!.allLeaves.every((l) => l.isPlaceholder), isTrue);
    });

    test('a shape knows how many panes it holds, and how many stand along each way', () {
      const pane = ShapePane();
      const row = ShapeSplit(Axis.horizontal, [pane, pane, pane]);
      const grid = ShapeSplit(Axis.vertical, [row, ShapeSplit(Axis.horizontal, [pane, pane])]);
      expect([pane.panes, pane.tracks(Axis.horizontal), pane.tracks(Axis.vertical)], [1, 1, 1]);
      expect([row.panes, row.tracks(Axis.horizontal), row.tracks(Axis.vertical)], [3, 3, 1]);
      expect([grid.panes, grid.tracks(Axis.horizontal), grid.tracks(Axis.vertical)], [5, 3, 2]);
      // Left to themselves, parts take room by the panes each holds along
      // the split; a shape that says otherwise is taken at its word.
      const beside = ShapeSplit(Axis.horizontal, [row, pane]);
      expect([beside.weight(0), beside.weight(1), beside.weightSum], [3, 1, 4]);
      const weighted = ShapeSplit(Axis.horizontal, [row, pane], weights: [1, 1]);
      expect([weighted.weight(0), weighted.weight(1), weighted.weightSum], [1, 1, 2]);
    });

    test('the shape of rows: a pane is a pane, a row a row, rows one above the other', () {
      expect(shapeOfRows([1]), isA<ShapePane>());
      final three = shapeOfRows([3]) as ShapeSplit;
      expect(three.axis, Axis.horizontal);
      expect(three.parts, hasLength(3));
      expect(three.parts, everyElement(isA<ShapePane>()));
      final rows = shapeOfRows([2, 1]) as ShapeSplit;
      expect(rows.axis, Axis.vertical);
      expect((rows.parts[0] as ShapeSplit).axis, Axis.horizontal);
      expect(rows.parts[1], isA<ShapePane>());
      for (var n = 1; n <= 12; n++) {
        expect(rowsOfShape(shapeOfRows(tileRows(n))), tileRows(n), reason: '$n');
        expect(shapeOfRows(tileRows(n)).panes, n);
      }
    });

    test('the arrangements are listed by how many they hold', () {
      final counts = [for (final p in LayoutPreset.values) p.panes];
      expect(counts, [...counts]..sort(), reason: 'what is offered follows this order');
    });

    test('the arrangement that is the grid a tab stands in by itself', () {
      expect({for (var n = 0; n <= 10; n++) n: automaticTwin(n)?.name}, {
        0: null,
        1: null,
        2: 'sideBySide',
        3: 'threeColumns',
        4: 'grid2x2',
        5: 'threeAndTwo',
        6: 'grid3x2',
        7: 'fourAndThree',
        8: 'grid4x2',
        9: null,
        10: null,
      });
      for (var n = 2; n <= 8; n++) {
        final leaves = [for (var i = 0; i < n; i++) t('p$i')];
        final chosen = treeOfPreset(automaticTwin(n)!, leaves)!;
        expect(rooms(chosen), rooms(tilePanes(leaves)), reason: '$n');
        expect(isTiled(chosen), isTrue, reason: 'choosing it by its name is choosing the grid: $n');
      }
      // Rows of panes are counted only where they share evenly: a shape
      // with weights of its own is no grid, whatever its rows.
      const pane = ShapePane();
      const row = ShapeSplit(Axis.horizontal, [pane, pane]);
      expect(rowsOfShape(pane), [1]);
      expect(rowsOfShape(row), [2]);
      expect(rowsOfShape(const ShapeSplit(Axis.vertical, [row, pane, row])), [2, 1, 2]);
      expect(rowsOfShape(const ShapeSplit(Axis.vertical, [pane, pane])), [1, 1]);
      expect(rowsOfShape(const ShapeSplit(Axis.horizontal, [pane, pane], weights: [2, 1])), isNull);
      expect(rowsOfShape(const ShapeSplit(Axis.vertical, [row, row], weights: [2, 1])), isNull);
      expect(rowsOfShape(const ShapeSplit(Axis.vertical, [row, ShapeSplit(Axis.horizontal, [pane, pane], weights: [1, 3])])),
          isNull);
      expect(rowsOfShape(const ShapeSplit(Axis.horizontal, [pane, ShapeSplit(Axis.vertical, [pane, pane])])), isNull);
      expect(rowsOfShape(const ShapeSplit(Axis.horizontal, [row, row])), isNull, reason: 'rows side by side are no rows');
      expect(rowsOfShape(const ShapeSplit(Axis.vertical, [row, ShapeSplit(Axis.horizontal, [pane, ShapeSplit(Axis.vertical, [pane, pane])])])),
          isNull);
      // No other one is the grid: not one with the same rows the other way
      // round, nor one whose rows do not share evenly.
      for (final p in LayoutPreset.values) {
        if (p == automaticTwin(p.panes)) continue;
        final leaves = [for (var i = 0; i < p.panes; i++) t('p$i')];
        expect(isTiled(treeOfPreset(p, leaves)), p == LayoutPreset.single, reason: p.name);
      }
    });

    test('what a tab is offered: the automatic grid, what else holds its terminals exactly, what has room for more',
        () {
      List<String> names(List<LayoutPreset> ps) => [for (final p in ps) p.name];
      final three = presetsFor(3);
      expect(three.automatic, isTrue);
      expect(names(three.exact), ['threeRows', 'oneAndTwo', 'twoAndOne'], reason: 'three columns are the grid');
      expect(names(three.roomier).take(4), ['grid2x2', 'fourColumns', 'oneAndThree', 'threeAndTwo']);
      expect(three.roomier.map((p) => p.panes), everyElement(greaterThan(3)));
      final five = presetsFor(5);
      expect(names(five.exact), ['twoAndThree', 'oneAndFour']);
      expect(names(five.roomier), ['grid3x2', 'grid2x3', 'fourAndThree', 'threeAndFour', 'grid4x2', 'grid2x4']);
      expect(names(presetsFor(2).exact), ['stacked']);
      expect(presetsFor(2).automatic, isTrue);
      // One terminal: itself, then everything larger, smallest first. There
      // is nothing to arrange by itself.
      final one = presetsFor(1);
      expect(one.automatic, isFalse);
      expect(names(one.exact), ['single']);
      expect(one.roomier.map((p) => p.panes).toList(), [2, 2, 3, 3, 3, 3, 4, 4, 4, 5, 5, 5, 6, 6, 7, 7, 8, 8]);
      // None yet: what one is offered.
      for (final none in [presetsFor(0), presetsFor(-1)]) {
        expect(none.automatic, isFalse);
        expect(none.exact, one.exact);
        expect(none.roomier, one.roomier);
      }
      // Eight: the grid, and the other one that holds eight. Nine and more:
      // the grid, and nothing made by hand.
      expect(names(presetsFor(8).exact), ['grid2x4']);
      expect(presetsFor(8).roomier, isEmpty);
      expect(presetsFor(9).automatic, isTrue);
      expect(presetsFor(9).exact, isEmpty);
      expect(presetsFor(9).roomier, isEmpty);
      for (var n = 1; n <= 8; n++) {
        final offer = presetsFor(n);
        expect([...offer.exact, ...offer.roomier].every((p) => p.fits(n)), isTrue, reason: '$n');
        expect(offer.exact.every((p) => p.panes == n), isTrue, reason: '$n');
        expect(offer.exact, isNot(contains(automaticTwin(n))), reason: 'never the same choice twice: $n');
        expect(offer.exact, isNotEmpty, reason: 'something else holds exactly $n');
      }
    });

    test('how much room is offered: a few panes more, not every arrangement there is', () {
      List<String> names(List<LayoutPreset> ps) => [for (final p in ps) p.name];
      expect(kLayoutRoomOffered, 3);
      expect(names(presetsFor(3, room: 3).roomier), [
        'grid2x2', 'fourColumns', 'oneAndThree', 'threeAndTwo', 'twoAndThree', //
        'oneAndFour', 'grid3x2', 'grid2x3',
      ]);
      expect(names(presetsFor(5, room: 1).roomier), ['grid3x2', 'grid2x3']);
      expect(presetsFor(5, room: 0).roomier, isEmpty);
      // One terminal, or none yet: up to four panes.
      for (final n in [1, 0]) {
        expect(presetsFor(n, room: 3).roomier.map((p) => p.panes).toSet(), {2, 3, 4}, reason: '$n');
      }
      expect(presetsFor(3, room: 3).exact, presetsFor(3).exact);
    });

    test('what the command palette lists: the grid, and what else holds the terminals exactly', () {
      List<String> names(int terminals) => [for (final p in paletteLayouts(terminals)) p?.name ?? 'automatic'];
      expect(names(0), isEmpty);
      expect(names(-1), isEmpty);
      expect(names(1), ['single']);
      expect(names(2), ['automatic', 'stacked']);
      expect(names(3), ['automatic', 'threeRows', 'oneAndTwo', 'twoAndOne']);
      expect(names(4), ['automatic', 'fourColumns', 'oneAndThree']);
      expect(names(5), ['automatic', 'twoAndThree', 'oneAndFour']);
      expect(names(9), ['automatic']);
    });

    test('which one a tab stands in, however its room is shared and its splits are nested', () {
      expect(presetOf(t('a')), LayoutPreset.single);
      expect(presetOf(h(t('a'), t('b'), 0.8)), LayoutPreset.sideBySide);
      expect(presetOf(v(t('a'), t('b'))), LayoutPreset.stacked);
      expect(presetOf(h(h(t('a'), t('b')), t('c'))), LayoutPreset.threeColumns);
      expect(presetOf(h(t('a'), v(t('b'), t('c')))), LayoutPreset.oneAndTwo);
      expect(presetOf(h(v(t('a'), t('b')), t('c'))), LayoutPreset.twoAndOne);
      expect(presetOf(v(h(t('a'), h(t('b'), t('c'))), h(t('d'), t('e')))), LayoutPreset.threeAndTwo);
      expect(presetOf(h(t('a'), v(h(t('b'), t('c')), h(t('d'), t('e'))))), LayoutPreset.oneAndFour);
      for (final p in LayoutPreset.values) {
        var i = 0;
        expect(presetOf(treeOfPreset(p, [for (var n = 0; n < p.panes; n++) t('${i++}')])), p, reason: p.name);
      }
      // The SFTP leaf at the side is not part of it.
      expect(presetOf(h(h(t('a'), t('b')), sftp('f'), 0.7)), LayoutPreset.sideBySide);
      // An arrangement nobody offers.
      expect(presetOf(v(t('a'), h(t('b'), v(t('c'), t('d'))))), isNull);
      expect(presetOf(h(h(h(h(t('a'), t('b')), t('c')), t('d')), t('e'))), isNull, reason: 'five in a row');
      expect(presetOf(sftp('f')), isNull);
      expect(presetOf(null), isNull);
    });
  });
}
