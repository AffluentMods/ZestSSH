import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zestssh/ui/widgets/pane_drop_zone.dart';

/// Represents a drop target: which pane and where within it.
class DropTarget {
  final String paneId;
  final DropPosition position;

  const DropTarget({required this.paneId, required this.position});
}

/// The phases of a unified drag operation.
enum DragPhase { idle, deadZone, rearranging, detached }

/// A unified drag controller that handles one continuous drag with two behaviors:
///
/// - **Cursor inside window**: show drop zones for rearranging panes
/// - **Cursor outside window**: detach session to a new OS window
///
/// Flow:
/// 1. `onPanStart` - record drag origin, cache window rect, enter dead zone
/// 2. `onPanUpdate` - after 10px dead zone, enter rearranging mode;
///    if cursor moves 30px outside window bounds, trigger detach
/// 3. `onPanEnd` - finalize or cancel
class UnifiedDragController {
  DragPhase phase = DragPhase.idle;
  String? draggedSessionId;
  String? draggedPaneId;
  Offset? _startGlobal;
  Rect? _windowRect;

  /// Minimum pointer movement before any drag mode activates.
  static const double kDeadZone = 10.0;

  /// Margin outside the window before detach triggers.
  static const double kDetachMargin = 30.0;

  // ── Callbacks ──────────────────────────────────────────────────

  /// Called when the dead zone is exited and drag is considered active.
  final void Function(String paneId)? onDragStarted;

  /// Called during rearranging phase with the current global position.
  final void Function(Offset globalPos)? onRearrangeUpdate;

  /// Called when the user drops on a specific pane + position.
  final void Function(DropTarget target)? onDrop;

  /// Called when the drag is cancelled (no valid drop target).
  final void Function()? onDragCancelled;

  /// Called when the cursor exits the window bounds - detach to new OS window.
  final Future<void> Function(String sessionId, Offset screenPos)? onDetach;

  UnifiedDragController({
    this.onDragStarted,
    this.onRearrangeUpdate,
    this.onDrop,
    this.onDragCancelled,
    this.onDetach,
  });

  /// Begin tracking a drag from a session header.
  void onPanStart(
    String sessionId,
    String paneId,
    DragStartDetails details,
  ) async {
    draggedSessionId = sessionId;
    draggedPaneId = paneId;
    _startGlobal = details.globalPosition;
    phase = DragPhase.deadZone;

    // Cache the window rect (desktop only)
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      try {
        final pos = await windowManager.getPosition();
        final size = await windowManager.getSize();
        _windowRect =
            Rect.fromLTWH(pos.dx, pos.dy, size.width, size.height);
      } catch (_) {
        // windowManager not available - disable detach detection
        _windowRect = null;
      }
    }
  }

  /// Update during an active drag.
  void onPanUpdate(DragUpdateDetails details) {
    if (phase == DragPhase.idle || phase == DragPhase.detached) return;
    final globalPos = details.globalPosition;

    switch (phase) {
      case DragPhase.deadZone:
        if ((globalPos - _startGlobal!).distance > kDeadZone) {
          phase = DragPhase.rearranging;
          onDragStarted?.call(draggedPaneId!);
        }
      case DragPhase.rearranging:
        if (_windowRect != null && _isOutsideWindow(globalPos)) {
          phase = DragPhase.detached;
          onDetach?.call(draggedSessionId!, globalPos);
        } else {
          onRearrangeUpdate?.call(globalPos);
        }
      default:
        break;
    }
  }

  /// End the drag gesture.
  void onPanEnd(DragEndDetails details) {
    if (phase == DragPhase.rearranging) {
      // Drop target resolution is handled by the caller via onDrop
      onDragCancelled?.call();
    }
    reset();
  }

  /// Check if the position is outside the cached window bounds + margin.
  bool _isOutsideWindow(Offset globalPos) {
    if (_windowRect == null) return false;
    return globalPos.dx < _windowRect!.left - kDetachMargin ||
        globalPos.dx > _windowRect!.right + kDetachMargin ||
        globalPos.dy < _windowRect!.top - kDetachMargin ||
        globalPos.dy > _windowRect!.bottom + kDetachMargin;
  }

  /// Reset to idle state.
  void reset() {
    phase = DragPhase.idle;
    draggedSessionId = null;
    draggedPaneId = null;
    _startGlobal = null;
    _windowRect = null;
  }
}
