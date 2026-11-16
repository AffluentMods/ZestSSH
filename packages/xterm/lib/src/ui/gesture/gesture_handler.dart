import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/mouse/button.dart';
import 'package:xterm/src/core/mouse/button_state.dart';
import 'package:xterm/src/core/mouse/mode.dart';
import 'package:xterm/src/terminal_view.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/gesture/gesture_detector.dart';
import 'package:xterm/src/ui/pointer_input.dart';
import 'package:xterm/src/ui/render.dart';

class TerminalGestureHandler extends StatefulWidget {
  const TerminalGestureHandler({
    super.key,
    required this.terminalView,
    required this.terminalController,
    this.child,
    this.onTapUp,
    this.onSingleTapUp,
    this.onTapDown,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.onTertiaryTapDown,
    this.onTertiaryTapUp,
    this.onUrlLongPress,
    this.onUrlClick,
    this.readOnly = false,
  });

  final TerminalViewState terminalView;

  final TerminalController terminalController;

  final Widget? child;

  final GestureTapUpCallback? onTapUp;

  final GestureTapUpCallback? onSingleTapUp;

  final GestureTapDownCallback? onTapDown;

  final GestureTapDownCallback? onSecondaryTapDown;

  final GestureTapUpCallback? onSecondaryTapUp;

  final GestureTapDownCallback? onTertiaryTapDown;

  final GestureTapUpCallback? onTertiaryTapUp;

  /// Called when the user long-presses on the terminal. If the callback returns
  /// true (URL found and handled), the default word selection is skipped.
  final bool Function(Offset localPosition)? onUrlLongPress;

  /// Called with the place of every single click. The view opens the link
  /// there when the click was one with Ctrl (or Command) held.
  final void Function(Offset localPosition)? onUrlClick;

  final bool readOnly;

  @override
  State<TerminalGestureHandler> createState() => _TerminalGestureHandlerState();
}

class _TerminalGestureHandlerState extends State<TerminalGestureHandler> {
  TerminalViewState get terminalView => widget.terminalView;

  RenderTerminal get renderTerminal => terminalView.renderTerminal;

  DragStartDetails? _lastDragStartDetails;

  LongPressStartDetails? _lastLongPressStartDetails;

  // ── Drag-select auto-scroll ───────────────────────────────────────
  //
  // While a mouse drag-select sits within an edge zone of the viewport,
  // scroll the terminal toward that edge and keep extending the
  // selection, so you can select far beyond one screen of scrollback.
  Timer? _autoScrollTimer;

  /// The selection's fixed origin, resolved to a buffer cell at drag
  /// start. Held as a cell (not a screen offset) so auto-scrolling
  /// doesn't drift the anchor.
  CellOffset? _dragStartCell;

  /// Latest pointer position during a mouse drag (local/screen space).
  Offset? _dragPosition;

  /// Pixels from the top/bottom edge within which auto-scroll engages.
  static const double _autoScrollEdge = 28.0;

  // ── A drag the program takes ──────────────────────────────────────
  //
  // A program that asked for button events (mode 1002) or for every move
  // (1003), tmux, vim and htop among them, is told of a drag as xterm tells
  // it: the press, each cell the pointer moves to with the button held, the
  // release. Shift held as the drag starts keeps it a selection here, as
  // xterm has it. (A drag always selected here: dragging a tmux pane's
  // border or selecting in vim did nothing.)

  /// The left button was reported pressed to the program (by the tap
  /// recognizer, or by the drag that won over it before it could).
  bool _pressReported = false;

  /// The drag now going on is the program's, and the last cell it was told
  /// of (a move within one cell is not told again).
  bool _dragReported = false;
  CellOffset? _lastReportedCell;

  /// The last cell a move with no button was told of (mode 1003).
  CellOffset? _lastHoverCell;

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    widget.terminalController.stopSelecting();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final detector = TerminalGestureDetector(
      child: widget.child,
      onTapUp: widget.onTapUp,
      onSingleTapUp: onSingleTapUp,
      onTapDown: onTapDown,
      onSecondaryTapDown: onSecondaryTapDown,
      onSecondaryTapUp: onSecondaryTapUp,
      // The middle button is its own: handed on as the right one, as it once
      // was, a middle click ran whatever a right click runs (a paste, in an
      // app that pastes on right click) and a program that takes the mouse
      // was told of a right click.
      onTertiaryTapDown: onTertiaryTapDown,
      onTertiaryTapUp: onTertiaryTapUp,
      onLongPressStart: onLongPressStart,
      onLongPressMoveUpdate: onLongPressMoveUpdate,
      // onLongPressUp: onLongPressUp,
      onDragStart: onDragStart,
      onDragUpdate: onDragUpdate,
      onDragEnd: onDragEnd,
      onDoubleTapDown: onDoubleTapDown,
      onTripleTapDown: onTripleTapDown,
    );
    // A mouse moved with no button held: told to a program that asked for
    // every move (mode 1003).
    return Listener(
      onPointerHover: _onHover,
      child: detector,
    );
  }

  /// Whether the program takes drags of the mouse now: it asked for button
  /// events or for every move, and the view sends it pointer input.
  bool get _programTakesDrags {
    if (widget.readOnly || !widget.terminalController.shouldSendPointerInput(PointerInput.drag)) return false;
    final mode = terminalView.widget.terminal.mouseMode;
    return mode == MouseMode.upDownScrollDrag || mode == MouseMode.upDownScrollMove;
  }

  void _onHover(PointerHoverEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    if (widget.readOnly ||
        !widget.terminalController.shouldSendPointerInput(PointerInput.move) ||
        terminalView.widget.terminal.mouseMode != MouseMode.upDownScrollMove) {
      _lastHoverCell = null;
      return;
    }
    final cell = renderTerminal.getCellOffset(renderTerminal.globalToLocal(event.position));
    if (cell == _lastHoverCell) return;
    _lastHoverCell = cell;
    terminalView.widget.terminal.mouseMotion(cell);
  }

  bool get _shouldSendTapEvent =>
      !widget.readOnly &&
      widget.terminalController.shouldSendPointerInput(PointerInput.tap);

  void _tapDown(
    GestureTapDownCallback? callback,
    TapDownDetails details,
    TerminalMouseButton button, {
    bool forceCallback = false,
  }) {
    // Check if the terminal should and can handle the tap down event.
    var handled = false;
    if (_shouldSendTapEvent) {
      handled = renderTerminal.mouseEvent(
        button,
        TerminalMouseButtonState.down,
        details.localPosition,
      );
    }
    if (button == TerminalMouseButton.left) _pressReported = handled;
    // If the event was not handled by the terminal, use the supplied callback.
    if (!handled || forceCallback) {
      callback?.call(details);
    }
  }

  void _tapUp(
    GestureTapUpCallback? callback,
    TapUpDetails details,
    TerminalMouseButton button, {
    bool forceCallback = false,
  }) {
    // Check if the terminal should and can handle the tap up event.
    var handled = false;
    if (_shouldSendTapEvent) {
      handled = renderTerminal.mouseEvent(
        button,
        TerminalMouseButtonState.up,
        details.localPosition,
      );
    }
    if (button == TerminalMouseButton.left) _pressReported = false;
    // If the event was not handled by the terminal, use the supplied callback.
    if (!handled || forceCallback) {
      callback?.call(details);
    }
  }

  void onTapDown(TapDownDetails details) {
    // onTapDown is special, as it will always call the supplied callback.
    // The TerminalView depends on it to bring the terminal into focus.
    _tapDown(
      widget.onTapDown,
      details,
      TerminalMouseButton.left,
      forceCallback: true,
    );
  }

  void onSingleTapUp(TapUpDetails details) {
    // Always called back as well, as the press is (onTapDown): a finger's tap
    // brings the on-screen keyboard up as it is let go, a program that takes
    // clicks (tmux, vim) or not.
    _tapUp(
      widget.onSingleTapUp,
      details,
      TerminalMouseButton.left,
      forceCallback: true,
    );
    // After the program had its click, if it takes clicks: a link opens
    // whatever the program does with the mouse.
    widget.onUrlClick?.call(details.localPosition);
  }

  void onSecondaryTapDown(TapDownDetails details) {
    _tapDown(widget.onSecondaryTapDown, details, TerminalMouseButton.right);
  }

  void onSecondaryTapUp(TapUpDetails details) {
    _tapUp(widget.onSecondaryTapUp, details, TerminalMouseButton.right);
  }

  void onTertiaryTapDown(TapDownDetails details) {
    _tapDown(widget.onTertiaryTapDown, details, TerminalMouseButton.middle);
  }

  void onTertiaryTapUp(TapUpDetails details) {
    _tapUp(widget.onTertiaryTapUp, details, TerminalMouseButton.middle);
  }

  void onDoubleTapDown(TapDownDetails details) {
    renderTerminal.selectWord(details.localPosition);
  }

  /// A triple click: the line (xterm's), where a double click is the word.
  void onTripleTapDown(TapDownDetails details) {
    renderTerminal.selectLine(details.localPosition);
  }

  void onLongPressStart(LongPressStartDetails details) {
    // Check if a URL was long-pressed. If so, skip word selection.
    if (widget.onUrlLongPress != null) {
      final handled = widget.onUrlLongPress!(details.localPosition);
      if (handled) return;
    }

    _lastLongPressStartDetails = details;
    renderTerminal.selectWord(details.localPosition);
  }

  void onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    renderTerminal.selectWord(
      _lastLongPressStartDetails!.localPosition,
      details.localPosition,
    );
  }

  // void onLongPressUp() {}

  void onDragStart(DragStartDetails details) {
    // The program's drag: told to it, nothing selected here. With Shift
    // held it is a selection here, whatever the program asked for.
    if (details.kind == PointerDeviceKind.mouse && _programTakesDrags && !HardwareKeyboard.instance.isShiftPressed) {
      _dragReported = true;
      final cell = renderTerminal.getCellOffset(details.localPosition);
      if (!_pressReported) {
        // The drag won before the tap recognizer said the press: said now,
        // where the button went down.
        renderTerminal.mouseEvent(TerminalMouseButton.left, TerminalMouseButtonState.down, details.localPosition);
        _pressReported = true;
      }
      _lastReportedCell = cell;
      return;
    }
    _lastDragStartDetails = details;
    // Until the pointer is let go the selection is what the pointer covers,
    // whatever is written there meanwhile.
    widget.terminalController.startSelecting();

    if (details.kind == PointerDeviceKind.mouse) {
      // Pin the selection origin to a buffer cell now, so it stays put
      // while auto-scroll (or wheel-scroll) moves the viewport mid-drag.
      _dragStartCell = renderTerminal.getCellOffset(details.localPosition);
      _dragPosition = details.localPosition;
      renderTerminal.selectCharacters(details.localPosition);
      // Re-extend the selection if the viewport scrolls (wheel) while
      // the button is held: lets the user grab beyond one screen by
      // holding and scrolling, the same way drag-to-edge auto-scroll
      // does. The pointer hasn't moved, so the live position now maps
      // to a scrolled cell → the selection grows into scrollback.
      renderTerminal.onViewportScrolled = _reExtendOnScroll;
    } else {
      renderTerminal.selectWord(details.localPosition);
    }
  }

  void _reExtendOnScroll() {
    final pos = _dragPosition;
    final startCell = _dragStartCell;
    if (pos != null && startCell != null) {
      renderTerminal.selectCharactersFromCell(startCell, pos);
    }
  }

  void onDragUpdate(DragUpdateDetails details) {
    if (_dragReported) {
      final cell = renderTerminal.getCellOffset(details.localPosition);
      if (cell != _lastReportedCell) {
        _lastReportedCell = cell;
        terminalView.widget.terminal.mouseMotion(cell, button: TerminalMouseButton.left);
      }
      return;
    }
    _dragPosition = details.localPosition;
    if (_dragStartCell != null) {
      renderTerminal.selectCharactersFromCell(
        _dragStartCell!,
        details.localPosition,
      );
      _updateAutoScroll();
    } else {
      // Touch / word-drag path: unchanged.
      renderTerminal.selectCharacters(
        _lastDragStartDetails!.localPosition,
        details.localPosition,
      );
    }
  }

  void onDragEnd(DragEndDetails details) {
    if (_dragReported) {
      // The release, where the pointer was last.
      final cell = _lastReportedCell;
      _dragReported = false;
      _lastReportedCell = null;
      if (cell != null && _pressReported) {
        terminalView.widget.terminal.mouseInput(TerminalMouseButton.left, TerminalMouseButtonState.up, cell);
      }
      _pressReported = false;
      return;
    }
    // A press the program was told of (it takes clicks, not drags): its
    // release as well, where the drag ended, so no button stays held there.
    if (_pressReported && _dragPosition != null) {
      terminalView.widget.terminal.mouseInput(
        TerminalMouseButton.left,
        TerminalMouseButtonState.up,
        renderTerminal.getCellOffset(_dragPosition!),
      );
    }
    _pressReported = false;
    widget.terminalController.stopSelecting();
    _stopAutoScroll();
    // Detach the wheel-scroll re-extend hook: only active during a drag.
    if (renderTerminal.onViewportScrolled == _reExtendOnScroll) {
      renderTerminal.onViewportScrolled = null;
    }
    _dragStartCell = null;
    _dragPosition = null;
  }

  /// Engage / disengage the auto-scroll timer based on whether the live
  /// pointer sits within an edge zone of the viewport.
  void _updateAutoScroll() {
    final pos = _dragPosition;
    if (pos == null || _dragStartCell == null) {
      _stopAutoScroll();
      return;
    }
    final height = renderTerminal.viewportHeight;
    final nearTop = pos.dy < _autoScrollEdge;
    final nearBottom = pos.dy > height - _autoScrollEdge;
    if (!nearTop && !nearBottom) {
      _stopAutoScroll();
      return;
    }
    _autoScrollTimer ??= Timer.periodic(
      const Duration(milliseconds: 30),
      (_) => _autoScrollTick(),
    );
  }

  void _autoScrollTick() {
    final pos = _dragPosition;
    final startCell = _dragStartCell;
    if (pos == null || startCell == null) {
      _stopAutoScroll();
      return;
    }
    final height = renderTerminal.viewportHeight;
    final lineH = renderTerminal.cellSize.height;

    double delta;
    if (pos.dy < _autoScrollEdge) {
      // Deeper into the edge → faster. 1 to 3 lines per tick.
      final depth = (_autoScrollEdge - pos.dy) / _autoScrollEdge;
      delta = -lineH * (1 + 2 * depth.clamp(0.0, 1.0));
    } else if (pos.dy > height - _autoScrollEdge) {
      final depth = (pos.dy - (height - _autoScrollEdge)) / _autoScrollEdge;
      delta = lineH * (1 + 2 * depth.clamp(0.0, 1.0));
    } else {
      _stopAutoScroll();
      return;
    }

    final moved = terminalView.scrollByPixels(delta);
    // Re-extend the selection against the new scroll position. The start
    // cell is fixed; the end re-resolves from the live pointer offset.
    renderTerminal.selectCharactersFromCell(startCell, pos);
    if (!moved) {
      // Hit the scroll boundary: nothing more to reveal, stop ticking.
      _stopAutoScroll();
    }
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }
}
