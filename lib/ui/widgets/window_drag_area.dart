import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

/// A frameless-window move region that cannot strand the pointer.
///
/// `windowManager.startDragging()` hands the drag to the Win32 modal move loop,
/// which consumes the matching pointer-up. Left as-is, Flutter keeps the
/// initiating pointer flagged "down" forever, which freezes the cursor (often
/// on a stuck resize glyph) and kills all mouse input after the drag, the
/// "dead mouse after a drag" bug.
///
/// This region starts the native drag on pan-start (so plain taps on child
/// controls still register, unlike an immediate pointer-down handoff) and then
/// immediately cancels the initiating pointer so nothing is left stuck. Pairs
/// with [PointerRecovery], which also unsticks the non-drag focus-loss case.
class WindowDragArea extends StatefulWidget {
  const WindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  State<WindowDragArea> createState() => _WindowDragAreaState();
}

class _WindowDragAreaState extends State<WindowDragArea> {
  int? _pointer;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      // Record the initiating pointer WITHOUT consuming the event, so taps on
      // child controls still work and only a real pan starts a window move.
      onPointerDown: (e) => _pointer = e.pointer,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (_) {
          windowManager.startDragging();
          final pointer = _pointer;
          if (pointer != null) {
            // The Win32 modal move loop ate the pointer-up; cancel the Flutter
            // pointer so it is not left stranded "down".
            GestureBinding.instance.cancelPointer(pointer);
          }
        },
        child: widget.child,
      ),
    );
  }
}
