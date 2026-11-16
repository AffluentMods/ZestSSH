import 'package:flutter/widgets.dart' show Axis;
import 'package:zestssh/models/pane_tree.dart';

/// Where each pane of [tree] stands in a room one wide and one high, as
/// "id x,y w×h" in hundredths, in reading order (top to bottom, left to
/// right). A place to connect that stands empty is "-". With [bySession] a
/// pane goes by the session it shows instead of by its own id.
List<String> rooms(PaneNode? tree, {bool bySession = false}) {
  final out = <({String id, double x, double y, double w, double h})>[];
  void place(PaneNode node, double x, double y, double w, double hh) {
    if (node is PaneLeaf) {
      final name = node.isPlaceholder ? '-' : (bySession ? node.sessionId : node.id);
      out.add((id: name, x: x, y: y, w: w, h: hh));
      return;
    }
    final s = node as PaneSplit;
    if (s.axis == Axis.horizontal) {
      place(s.first, x, y, w * s.ratio, hh);
      place(s.second, x + w * s.ratio, y, w * (1 - s.ratio), hh);
    } else {
      place(s.first, x, y, w, hh * s.ratio);
      place(s.second, x, y + hh * s.ratio, w, hh * (1 - s.ratio));
    }
  }

  if (tree != null) place(tree, 0, 0, 1, 1);
  String n(double d) => (d * 100).round().toString();
  out.sort((a, b) => (a.y - b.y).abs() > 0.001 ? a.y.compareTo(b.y) : a.x.compareTo(b.x));
  return [for (final r in out) '${r.id} ${n(r.x)},${n(r.y)} ${n(r.w)}x${n(r.h)}'];
}

/// The share of the room each pane of [tree] has, by id (or by session), in
/// hundredths of its width.
Map<String, int> widths(PaneNode? tree, {bool bySession = false}) => {
      for (final r in rooms(tree, bySession: bySession))
        r.split(' ').first: int.parse(r.split(' ').last.split('x').first),
    };
