import 'package:flutter/foundation.dart';

/// While held, terminal views keep their rows and columns: a pane dragged to
/// a new size lays its text out afresh (every line of the scrollback, and the
/// host told of the new size) once, when the drag ends, not at every step of
/// it. Each [hold] is matched by one [release].
abstract final class TerminalResizeHold {
  static final ValueNotifier<int> _holds = ValueNotifier(0);

  static bool get held => _holds.value > 0;

  /// Told when the last hold is released (and when a hold begins).
  static Listenable get listenable => _holds;

  static void hold() => _holds.value++;

  static void release() {
    if (_holds.value > 0) _holds.value--;
  }
}
