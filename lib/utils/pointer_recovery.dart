import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Recovers from a stranded pointer.
///
/// Flutter tracks each pointer as "down" from its PointerDownEvent until the
/// matching up/cancel. On desktop that pairing can break: a window drag handed
/// to the Win32 modal move loop, or a focus loss across a monitor sleep, can
/// swallow the pointer-up so the framework still believes a mouse button is
/// held. Every later tap then opens a gesture arena that never resolves, and
/// each mouse-move is treated as a drag, so the cursor freezes (often on a
/// stuck resize glyph) and all mouse input dies, even though the app keeps
/// rendering (timers still tick, the keyboard still works).
///
/// [wrap] mounts a passive root Listener that records which pointers are down;
/// [recover] cancels any still-down pointer so the pipeline is unstuck. Call
/// [recover] whenever the window regains focus (see WindowService), which also
/// makes Alt+Tab away-and-back a reliable manual escape hatch.
class PointerRecovery {
  PointerRecovery._();

  static final Set<int> _down = <int>{};

  /// Cancel every pointer still considered down. Returns how many were cleared.
  /// Safe to call at any time; a no-op when nothing is stuck.
  static int recover() {
    if (_down.isEmpty) return 0;
    final stuck = _down.toList(growable: false);
    for (final pointer in stuck) {
      GestureBinding.instance.cancelPointer(pointer);
    }
    _down.clear();
    return stuck.length;
  }

  /// Wrap the app root so pointer down/up/cancel are tracked. Passive: it never
  /// absorbs events or joins the gesture arena, so it cannot itself break input.
  static Widget wrap({required Widget child}) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) => _down.add(e.pointer),
      onPointerUp: (e) => _down.remove(e.pointer),
      onPointerCancel: (e) => _down.remove(e.pointer),
      child: child,
    );
  }
}
