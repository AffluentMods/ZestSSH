import 'package:flutter/widgets.dart';

/// How solid the copy of a tab or a pane is while it is dragged: enough to
/// read, and see-through enough to show what it is held over.
const double kDragGhostOpacity = 0.6;

/// How far under the pointer the copy hangs while it is dragged.
const double kDragGhostDrop = 18;

/// Where the see-through copy of what is dragged is put: just under the
/// pointer, not on it, so that what the pointer is over is not covered (the
/// name of the tab it would join, the mark of where it would land), and as
/// far to the side as it was grabbed, but no further than [reach], so that a
/// copy narrower than what was grabbed still stands at the pointer.
DragAnchorStrategy hangingDragAnchor({required double reach}) {
  return (Draggable<Object> draggable, BuildContext context, Offset position) {
    final box = context.findRenderObject()! as RenderBox;
    final grabbed = box.globalToLocal(position).dx;
    return Offset(grabbed.clamp(0.0, reach), -kDragGhostDrop);
  };
}
