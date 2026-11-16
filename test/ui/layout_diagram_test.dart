import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/models/pane_layout.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/ui/widgets/layout_preset_picker.dart';

/// The small picture of an arrangement shows the panes where the
/// arrangement puts them: it is drawn from the same shape the panes are
/// made from, so the two cannot differ.
void main() {
  const width = 260.0;
  const height = 170.0;

  /// The boxes of the picture, each as left, top, width and height in parts
  /// of the whole, in reading order.
  Future<List<Rect>> drawn(WidgetTester tester, PaneShape shape, {TextDirection reading = TextDirection.ltr}) async {
    await tester.pumpWidget(Directionality(
      textDirection: reading,
      child: Center(
        child: SizedBox(width: width, height: height, child: LayoutDiagram(shape: shape)),
      ),
    ));
    final whole = tester.getRect(find.byType(LayoutDiagram));
    final boxes = find.descendant(
      of: find.byType(LayoutDiagram),
      matching: find.byWidgetPredicate((w) => w is Container && w.decoration is BoxDecoration),
    );
    final rects = [
      for (final e in boxes.evaluate())
        () {
          final r = tester.getRect(find.byWidget(e.widget));
          return Rect.fromLTWH(
            (r.left - whole.left) / whole.width,
            (r.top - whole.top) / whole.height,
            r.width / whole.width,
            r.height / whole.height,
          );
        }(),
    ]..sort((a, b) => (a.top - b.top).abs() > 0.02 ? a.top.compareTo(b.top) : a.left.compareTo(b.left));
    return rects;
  }

  /// Where the panes of [tree] stand, in parts of the whole, in reading order.
  List<Rect> stands(PaneNode tree) {
    final out = <Rect>[];
    void place(PaneNode node, Rect room) {
      if (node is! PaneSplit) {
        out.add(room);
        return;
      }
      if (node.axis == Axis.horizontal) {
        final w = room.width * node.ratio;
        place(node.first, Rect.fromLTWH(room.left, room.top, w, room.height));
        place(node.second, Rect.fromLTWH(room.left + w, room.top, room.width - w, room.height));
      } else {
        final h = room.height * node.ratio;
        place(node.first, Rect.fromLTWH(room.left, room.top, room.width, h));
        place(node.second, Rect.fromLTWH(room.left, room.top + h, room.width, room.height - h));
      }
    }

    place(tree, const Rect.fromLTWH(0, 0, 1, 1));
    out.sort((a, b) => (a.top - b.top).abs() > 0.02 ? a.top.compareTo(b.top) : a.left.compareTo(b.left));
    return out;
  }

  // (The picture leaves two points between its boxes.)
  const slack = 0.02;

  void expectSame(List<Rect> picture, List<Rect> panes, String what) {
    expect(picture, hasLength(panes.length), reason: what);
    for (var i = 0; i < panes.length; i++) {
      expect(picture[i].left, closeTo(panes[i].left, slack), reason: '$what, pane $i from the left');
      expect(picture[i].top, closeTo(panes[i].top, slack), reason: '$what, pane $i from the top');
      expect(picture[i].width, closeTo(panes[i].width, slack), reason: '$what, how wide pane $i is');
      expect(picture[i].height, closeTo(panes[i].height, slack), reason: '$what, how high pane $i is');
    }
  }

  testWidgets('every arrangement a person can choose is pictured as it is made', (tester) async {
    for (final preset in LayoutPreset.values) {
      final tree = treeOfPreset(preset, [
        for (var i = 0; i < preset.panes; i++) PaneLeaf.single(sessionId: 's$i'),
      ])!;
      expectSame(await drawn(tester, preset.shape), stands(tree), preset.name);
    }
  });

  testWidgets('the grid a tab stands in by itself is pictured as it is made, for any number', (tester) async {
    for (var n = 1; n <= 12; n++) {
      final tree = tilePanes([for (var i = 0; i < n; i++) PaneLeaf.single(sessionId: 's$i')]);
      expectSame(await drawn(tester, shapeOfRows(tileRows(n))), stands(tree), '$n');
    }
  });

  testWidgets('left is left in the picture whichever way the language reads', (tester) async {
    final shape = LayoutPreset.oneAndTwo.shape;
    final ltr = await drawn(tester, shape);
    await tester.pumpWidget(const SizedBox.shrink());
    final rtl = await drawn(tester, shape, reading: TextDirection.rtl);
    expect(rtl, hasLength(3));
    for (var i = 0; i < 3; i++) {
      expect(rtl[i].left, closeTo(ltr[i].left, 0.001));
      expect(rtl[i].width, closeTo(ltr[i].width, 0.001));
    }
    expect(ltr.first.width, greaterThan(0.6), reason: 'the large pane is the one on the left');
    expect(ltr.first.left, 0);
  });
}
