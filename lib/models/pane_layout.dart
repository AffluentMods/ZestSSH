import 'package:flutter/widgets.dart';
import 'package:zestssh/models/pane_tree.dart';

// How the terminals of a tab are arranged (3.0): the arrangements a person
// can choose, the one the app keeps by itself, and what happens to either
// when a terminal joins the tab or leaves it.
//
// Four rules run through it.
//
//  * The room is shared by rows and columns ([rebalancePaneTree]): panes
//    side by side are as wide as each other, whatever was split to get
//    there. No pane ends up a sliver because it was added last.
//  * What someone arranged is theirs. A divider that was moved stays where
//    it was put while panes come and go elsewhere, and so do the shares of
//    an arrangement that is not even by design (a large pane beside a
//    stack). The app shares again only the room nobody arranged.
//  * A tab nobody arranged stands in a grid that grows with it ([tileRows]):
//    up to three terminals side by side, from four on in two rows, from nine
//    in three. A terminal that joins such a tab, or leaves it, has the grid
//    made again for the new number. A tab someone arranged otherwise keeps
//    its arrangement, and a terminal that joins it joins it the way that
//    arrangement grows ([withTreeAdded]): a row gets longer, a stack
//    taller, a grid's shortest row gets one more, and beside a large pane
//    the stack does.
//  * An arrangement holds every terminal of the tab or it is not offered
//    ([LayoutPreset.fits]): choosing one never moves a terminal out of
//    sight.
//
// SFTP is no pane (it shows in its dock): its leaf is carried along at the
// side of the tree, and counts for nothing here.

/// The shape of an arrangement: a pane, or parts side by side
/// ([Axis.horizontal]) or one above the other ([Axis.vertical]).
sealed class PaneShape {
  const PaneShape();

  /// How many panes it holds.
  int get panes;

  /// How many of its panes stand along [axis] where it is at its fullest.
  int tracks(Axis axis);
}

class ShapePane extends PaneShape {
  const ShapePane();

  @override
  int get panes => 1;

  @override
  int tracks(Axis axis) => 1;
}

class ShapeSplit extends PaneShape {
  const ShapeSplit(this.axis, this.parts, {this.weights});

  final Axis axis;
  final List<PaneShape> parts;

  /// How the parts share the room along [axis]; left out, each takes room
  /// by the panes it holds along it, so that all of them come out equal.
  final List<int>? weights;

  /// The room part [i] takes, in parts of [weightSum].
  int weight(int i) => weights?[i] ?? parts[i].tracks(axis);

  int get weightSum {
    var sum = 0;
    for (var i = 0; i < parts.length; i++) {
      sum += weight(i);
    }
    return sum;
  }

  @override
  int get panes {
    var sum = 0;
    for (final p in parts) {
      sum += p.panes;
    }
    return sum;
  }

  @override
  int tracks(Axis axis) {
    var most = 0, sum = 0;
    for (final p in parts) {
      final t = p.tracks(axis);
      sum += t;
      if (t > most) most = t;
    }
    return axis == this.axis ? sum : most;
  }
}

const _pane = ShapePane();
const _two = [_pane, _pane];
const _three = [_pane, _pane, _pane];
const _four = [_pane, _pane, _pane, _pane];
const _rowOf2 = ShapeSplit(Axis.horizontal, _two);
const _rowOf3 = ShapeSplit(Axis.horizontal, _three);
const _rowOf4 = ShapeSplit(Axis.horizontal, _four);
const _stackOf2 = ShapeSplit(Axis.vertical, _two);
const _stackOf3 = ShapeSplit(Axis.vertical, _three);

/// The arrangements a person can choose. [number] is what is kept for the
/// next launch: the first ten keep the numbers they always had.
enum LayoutPreset {
  single(5, _pane),
  sideBySide(1, _rowOf2),
  stacked(2, _stackOf2),
  threeColumns(3, _rowOf3),
  threeRows(8, _stackOf3),
  oneAndTwo(6, ShapeSplit(Axis.horizontal, [_pane, _stackOf2], weights: [2, 1])),
  twoAndOne(7, ShapeSplit(Axis.horizontal, [_stackOf2, _pane], weights: [1, 2])),
  grid2x2(4, ShapeSplit(Axis.vertical, [_rowOf2, _rowOf2])),
  fourColumns(11, _rowOf4),
  oneAndThree(12, ShapeSplit(Axis.horizontal, [_pane, _stackOf3], weights: [2, 1])),
  threeAndTwo(13, ShapeSplit(Axis.vertical, [_rowOf3, _rowOf2])),
  twoAndThree(14, ShapeSplit(Axis.vertical, [_rowOf2, _rowOf3])),
  oneAndFour(15, ShapeSplit(Axis.horizontal, [_pane, ShapeSplit(Axis.vertical, [_rowOf2, _rowOf2])], weights: [1, 1])),
  grid3x2(9, ShapeSplit(Axis.vertical, [_rowOf3, _rowOf3])),
  grid2x3(10, ShapeSplit(Axis.vertical, [_rowOf2, _rowOf2, _rowOf2])),
  fourAndThree(16, ShapeSplit(Axis.vertical, [_rowOf4, _rowOf3])),
  threeAndFour(17, ShapeSplit(Axis.vertical, [_rowOf3, _rowOf4])),
  grid4x2(18, ShapeSplit(Axis.vertical, [_rowOf4, _rowOf4])),
  grid2x4(19, ShapeSplit(Axis.vertical, [_rowOf2, _rowOf2, _rowOf2, _rowOf2]));

  const LayoutPreset(this.number, this.shape);

  final int number;
  final PaneShape shape;

  /// How many terminals it holds.
  int get panes => shape.panes;

  /// Whether a tab with [terminals] in it can take this arrangement: it has
  /// a pane for each of them. (One with panes to spare shows those as places
  /// to connect.)
  bool fits(int terminals) => panes >= terminals;

  /// The arrangement kept or typed as [number]; null for a number that is
  /// none.
  static LayoutPreset? byNumber(int number) {
    for (final p in values) {
      if (p.number == number) return p;
    }
    return null;
  }
}

/// The desktop shell's number for [p]: what is kept for the next launch.
int layoutPresetNumber(LayoutPreset p) => p.number;

/// How many panes more than the tab has terminals an arrangement may have
/// and still be offered in the Layout popover: room for a few more, not
/// every arrangement there is.
const int kLayoutRoomOffered = 3;

/// The arrangement a person can choose that is the grid a tab of
/// [terminals] stands in by itself ([tileRows]): three columns for three,
/// "3 + 2" for five. Null where there is none (one terminal, or more than
/// the arrangements hold).
LayoutPreset? automaticTwin(int terminals) {
  if (terminals < 2) return null;
  final rows = tileRows(terminals);
  for (final p in LayoutPreset.values) {
    final its = rowsOfShape(p.shape);
    if (its != null && _sameRows(its, rows)) return p;
  }
  return null;
}

/// How many panes each row of [shape] holds, top to bottom, when it is rows
/// of panes sharing evenly and nothing else. Null for any other shape: one
/// with a stack beside a pane, or one whose rows or panes share the room by
/// weights of their own.
List<int>? rowsOfShape(PaneShape shape) {
  int? row(PaneShape s) {
    if (s is! ShapeSplit) return 1;
    if (s.axis != Axis.horizontal || s.weights != null) return null;
    return s.parts.every((p) => p is ShapePane) ? s.parts.length : null;
  }

  final one = row(shape);
  if (one != null) return [one];
  final split = shape as ShapeSplit;
  if (split.axis != Axis.vertical || split.weights != null) return null;
  final rows = [for (final part in split.parts) row(part)];
  return rows.contains(null) ? null : rows.cast<int>();
}

bool _sameRows(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// What is offered to a tab with [terminals] in it.
///
/// [automatic]: the grid the tab stands in by itself, from two terminals
/// on. [exact]: the arrangements that hold exactly that many; the one that
/// is the automatic grid is not among them where that grid is offered
/// ([automaticTwin]: it would be the same choice twice). [roomier]: the
/// ones with room for more; with [room], none with more than that many
/// panes to spare. Both in the order of [LayoutPreset.values], which lists
/// the arrangements by how many they hold. A tab with no terminal yet is
/// offered what a tab with one is.
({bool automatic, List<LayoutPreset> exact, List<LayoutPreset> roomier}) presetsFor(int terminals, {int? room}) {
  final n = terminals < 1 ? 1 : terminals;
  final twin = automaticTwin(n);
  final exact = [
    for (final p in LayoutPreset.values)
      if (p.panes == n && p != twin) p,
  ];
  final roomier = [
    for (final p in LayoutPreset.values)
      if (p.panes > n && (room == null || p.panes <= n + room)) p,
  ];
  return (automatic: n >= 2, exact: exact, roomier: roomier);
}

/// What the command palette lists for a tab with [terminals] in it: the
/// automatic grid first (null), then the arrangements that hold exactly
/// that many. (The ones with room for more are in the Layout popover, where
/// their pictures are.)
List<LayoutPreset?> paletteLayouts(int terminals) {
  if (terminals < 1) return const [];
  final offer = presetsFor(terminals);
  return [if (offer.automatic) null, ...offer.exact];
}

/// The tree of [shape], its panes taken from [next] in reading order (left
/// to right, top to bottom). Parts side by side or stacked become a chain of
/// splits, each sharing its room by the parts' weights.
PaneNode treeOfShape(PaneShape shape, PaneLeaf Function() next) {
  if (shape is! ShapeSplit) return next();
  final nodes = [for (final part in shape.parts) treeOfShape(part, next)];
  var rest = shape.weightSum;
  PaneNode chain(int from) {
    if (from == nodes.length - 1) return nodes[from];
    final mine = shape.weight(from);
    final ratio = mine / rest;
    rest -= mine;
    return PaneSplit(first: nodes[from], second: chain(from + 1), axis: shape.axis, ratio: ratio);
  }

  return chain(0);
}

/// The rows a tab's terminals stand in when nobody arranged them: how many
/// in each row, top to bottom. Up to three stand side by side; from four on
/// there are two rows, from nine three, the upper rows taking the odd ones.
List<int> tileRows(int count) {
  if (count <= 0) return const [];
  final rows = count <= 3 ? 1 : (count <= 8 ? 2 : 3);
  final each = count ~/ rows;
  final over = count % rows;
  return [for (var r = 0; r < rows; r++) each + (r < over ? 1 : 0)];
}

/// The shape of [rows] of panes (how many in each, top to bottom).
PaneShape shapeOfRows(List<int> rows) {
  PaneShape row(int n) => n == 1 ? _pane : ShapeSplit(Axis.horizontal, [for (var i = 0; i < n; i++) _pane]);
  if (rows.length == 1) return row(rows.single);
  return ShapeSplit(Axis.vertical, [for (final n in rows) row(n)]);
}

/// [leaves] in the grid a tab nobody arranged stands in ([tileRows]), in
/// their order. Each leaf stays the leaf it was.
PaneNode tilePanes(List<PaneLeaf> leaves) {
  assert(leaves.isNotEmpty, 'a grid of no panes');
  var i = 0;
  return treeOfShape(shapeOfRows(tileRows(leaves.length)), () => leaves[i++]);
}

/// How many panes each row of [tree] holds, top to bottom, when it is rows
/// of panes and nothing else (one pane; panes side by side; such rows one
/// above the other). Null for any other arrangement. Which way the splits
/// were nested to get there does not matter, nor how the room is shared.
List<int>? rowsOf(PaneNode tree) {
  int? row(PaneNode node) {
    if (node is PaneLeaf) return 1;
    final split = node as PaneSplit;
    if (split.axis != Axis.horizontal) return null;
    final a = row(split.first), b = row(split.second);
    return a == null || b == null ? null : a + b;
  }

  final one = row(tree);
  if (one != null) return [one];
  final split = tree as PaneSplit;
  // (Not a row, so it is split above and below: rows, or stacks of rows.)
  if (split.axis != Axis.vertical) return null;
  final a = rowsOf(split.first), b = rowsOf(split.second);
  if (a == null || b == null) return null;
  return [...a, ...b];
}

/// Whether the terminals of [tree] stand in the grid a tab nobody arranged
/// stands in: in its rows, the room shared evenly. Once someone moved a
/// divider the tab is theirs, and keeps what they made of it.
bool isTiled(PaneNode? tree) {
  final terminals = withoutSftp(tree);
  if (terminals == null) return false;
  final rows = rowsOf(terminals);
  if (rows == null) return false;
  return _sameRows(rows, tileRows(terminals.allLeaves.length)) && sharedEvenly(terminals);
}

/// [terminals] with the SFTP leaves of a tab carried at its side, as the
/// tab keeps them: they show in the dock, and where they hang in the tree
/// is seen nowhere. Null [terminals] leaves the SFTP leaves alone.
PaneNode? withSftpAside(PaneNode? terminals, List<PaneLeaf> sftp) {
  if (sftp.isEmpty) return terminals;
  PaneNode stack = sftp.first;
  for (final leaf in sftp.skip(1)) {
    stack = PaneSplit(first: stack, second: leaf, axis: Axis.vertical);
  }
  if (terminals == null) return stack;
  return PaneSplit(first: terminals, second: stack, axis: Axis.horizontal);
}

/// [tree] with the pane [added] in it, where nobody said on which side of
/// what. See [withTreeAdded].
PaneNode withPaneAdded(PaneNode tree, PaneLeaf added) => withTreeAdded(tree, added);

/// [tree] with the panes of [added] in it (one pane, or the whole of a tab
/// that joins this one), where nobody said on which side of what.
///
/// A place to connect that stands empty is filled first. Then:
///
///  * where both stand in their grid (a single pane does), they stand in
///    the grid for all of them together, in order;
///  * one pane that joins an arrangement someone made joins it the way that
///    arrangement grows ([_withPaneBeside]);
///  * a tab of several panes that joins stands at the right of what was
///    there, each keeping its arrangement.
///
/// What nobody arranged shares its room evenly; a divider someone moved
/// stays where it was put.
///
/// A tab shows one SFTP dock: the one it had stays; one that comes to a tab
/// without is taken along.
PaneNode withTreeAdded(PaneNode tree, PaneNode added) {
  final own = sftpLeavesOf(tree);
  final sftp = own.isNotEmpty ? own : sftpLeavesOf(added);
  var terminals = withoutSftp(tree);
  // (Places to connect that stood empty where they come from stay behind.)
  final arrived = withoutSftp(added);
  var incoming = _withoutEmptyPlaces(arrived);
  if (incoming == null) return withSftpAside(terminals, sftp) ?? tree;
  incoming = rebalancePaneTree(incoming, since: arrived);
  if (terminals == null) return withSftpAside(incoming, sftp)!;

  final empty = [
    for (final leaf in terminals.allLeaves)
      if (leaf.isPlaceholder) leaf,
  ];
  if (empty.isNotEmpty) {
    final arriving = incoming.allLeaves;
    var filled = 0;
    while (filled < empty.length && filled < arriving.length) {
      terminals = replacePaneLeaf(terminals!, empty[filled].id, arriving[filled]);
      filled++;
    }
    final left = arriving.sublist(filled);
    if (left.isEmpty) return withSftpAside(terminals, sftp)!;
    // (What found no empty place joins as panes of its own.)
    incoming = tilePanes(left);
  }

  if (isTiled(terminals) && isTiled(incoming)) {
    return withSftpAside(tilePanes([...terminals!.allLeaves, ...incoming.allLeaves]), sftp)!;
  }
  // (One pane joins what is no grid, so no single pane: an arrangement.)
  if (incoming is PaneLeaf) return withSftpAside(_withPaneBeside(terminals! as PaneSplit, incoming), sftp)!;
  // (Nothing changes inside either: only the two share what there is.)
  return withSftpAside(PaneSplit.even(first: terminals!, second: incoming, axis: Axis.horizontal), sftp)!;
}

/// [terminals], an arrangement someone made, with the pane [added] in it,
/// the way that arrangement grows:
///
///  * rows of panes, at least one of them with more than one pane (one row
///    alone is such): the shortest row gets it at its end, the topmost of
///    equals, as the grid a tab stands in by itself fills. A row gets
///    longer;
///  * anything else: it stands after the last pane, the way that pane and
///    its neighbours stand. A stack gets taller, and beside a large pane
///    the stack gets one more.
PaneNode _withPaneBeside(PaneSplit terminals, PaneLeaf added) {
  final rows = _partsAlong(terminals, Axis.vertical);
  final PaneLeaf last;
  final Axis axis;
  if (rowsOf(terminals) != null && rows.any((row) => row is PaneSplit)) {
    var shortest = rows.first;
    for (final row in rows) {
      if (row.allLeaves.length < shortest.allLeaves.length) shortest = row;
    }
    last = shortest.allLeaves.last;
    axis = Axis.horizontal;
  } else {
    last = terminals.allLeaves.last;
    // The split the last pane is a side of: down the second sides.
    var over = terminals;
    while (over.second is PaneSplit) {
      over = over.second as PaneSplit;
    }
    axis = over.axis;
  }
  final grown = replacePaneLeaf(terminals, last.id, PaneSplit(first: last, second: added, axis: axis));
  return rebalancePaneTree(grown, since: terminals);
}

/// [tree] without its places to connect that stand empty; a split left
/// with one side becomes that side. Null when nothing else was there.
PaneNode? _withoutEmptyPlaces(PaneNode? tree) {
  if (tree == null) return null;
  if (tree is PaneLeaf) return tree.isPlaceholder ? null : tree;
  final split = tree as PaneSplit;
  final first = _withoutEmptyPlaces(split.first);
  final second = _withoutEmptyPlaces(split.second);
  if (first == null) return second;
  if (second == null) return first;
  return split.copyWith(first: first, second: second);
}

/// [after] as it stands once panes were taken out of [before]: a tab that
/// stood in its grid stands in the grid for what is left; any other keeps
/// its arrangement, the room nobody arranged shared evenly again and a
/// divider someone moved left where it was put.
PaneNode settledAfterRemoval(PaneNode before, PaneNode after) {
  if (!isTiled(before)) return rebalancePaneTree(after, since: before);
  final terminals = withoutSftp(after);
  if (terminals == null) return after;
  return withSftpAside(tilePanes(terminals.allLeaves), sftpLeavesOf(after))!;
}

/// The tree of [preset] for a tab whose terminal panes are [leaves], in
/// their order; panes the arrangement has to spare are places to connect.
/// Null when it does not hold them all ([LayoutPreset.fits]).
PaneNode? treeOfPreset(LayoutPreset preset, List<PaneLeaf> leaves) {
  if (!preset.fits(leaves.length)) return null;
  var i = 0;
  return treeOfShape(
    preset.shape,
    () => i < leaves.length ? leaves[i++] : PaneLeaf.placeholder(type: 'terminal'),
  );
}

/// The arrangement the terminals of [tree] stand in, when it is one a
/// person can choose (however its room is shared): the one to mark in the
/// list of arrangements. Null for any other.
LayoutPreset? presetOf(PaneNode? tree) {
  final terminals = withoutSftp(tree);
  if (terminals == null) return null;
  for (final p in LayoutPreset.values) {
    if (_sameShape(terminals, p.shape)) return p;
  }
  return null;
}

/// Whether [node] is arranged as [shape]: the same parts the same way
/// round, however the splits were nested to get there.
bool _sameShape(PaneNode node, PaneShape shape) {
  if (shape is! ShapeSplit) return node is PaneLeaf;
  if (node is! PaneSplit) return false;
  // (A split the other way is one part along this one, never as many.)
  final parts = _partsAlong(node, shape.axis);
  if (parts.length != shape.parts.length) return false;
  for (var i = 0; i < parts.length; i++) {
    if (!_sameShape(parts[i], shape.parts[i])) return false;
  }
  return true;
}

/// The sides of [node] and of the splits in it that run the same way: what
/// stands along [axis], in order.
List<PaneNode> _partsAlong(PaneNode node, Axis axis) {
  if (node is PaneSplit && node.axis == axis) {
    return [..._partsAlong(node.first, axis), ..._partsAlong(node.second, axis)];
  }
  return [node];
}
