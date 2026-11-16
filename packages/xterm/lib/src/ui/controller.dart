import 'dart:math' show max, min;

import 'package:flutter/material.dart';
import 'package:meta/meta.dart';
import 'package:xterm/src/base/disposable.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/buffer/range.dart';
import 'package:xterm/src/core/buffer/range_block.dart';
import 'package:xterm/src/core/buffer/range_line.dart';
import 'package:xterm/src/ui/pointer_input.dart';
import 'package:xterm/src/ui/selection_mode.dart';

class TerminalController with ChangeNotifier {
  // Taps, drags and moves go to a program that asks for them (its mouse
  // modes: presses, button events 1002, every move 1003). Taps only, as it
  // was, and a drag in tmux, vim or htop selected text here instead.
  TerminalController({
    SelectionMode selectionMode = SelectionMode.line,
    PointerInputs pointerInputs = const PointerInputs({PointerInput.tap, PointerInput.drag, PointerInput.move}),
    bool suspendPointerInput = false,
  })  : _selectionMode = selectionMode,
        _pointerInputs = pointerInputs,
        _suspendPointerInputs = suspendPointerInput;

  CellAnchor? _selectionBase;
  CellAnchor? _selectionExtent;

  /// The clock of the terminal's text ([BufferLine.textClock]) when the
  /// selection was made, and how many rows lay between its two ends. A
  /// selection is of text: when a line under it changed since, or a line
  /// came in between or left, what is there is not what was selected.
  int _selectionStamp = 0;
  int _selectionRows = 0;

  /// Whether a selection is being made right now, with the pointer held.
  bool _selecting = false;

  SelectionMode get selectionMode => _selectionMode;
  SelectionMode _selectionMode;

  /// The set of pointer events which will be used as mouse input for the terminal.
  PointerInputs get pointerInput => _pointerInputs;
  PointerInputs _pointerInputs;

  /// True if sending pointer events to the terminal is suspended.
  bool get suspendedPointerInputs => _suspendPointerInputs;
  bool _suspendPointerInputs;

  List<TerminalHighlight> get highlights => _highlights;
  final _highlights = <TerminalHighlight>[];

  BufferRange? get selection {
    final base = _selectionBase;
    final extent = _selectionExtent;

    if (base == null || extent == null) {
      return null;
    }

    if (!base.attached || !extent.attached) {
      return null;
    }

    if (!_selecting && _textChanged(base, extent)) {
      return null;
    }

    return _createRange(base.offset, extent.offset);
  }

  /// There was a selection and it is over: its text changed, was cleared
  /// away, scrolled out of what is kept, or is on a screen that is no longer
  /// shown. [selection] reads as none from then on; [clearSelection] forgets
  /// it and tells the listeners (the view does that when the terminal
  /// changes).
  bool get selectionEnded => _selectionBase != null && _selectionExtent != null && selection == null;

  /// Whether the text between [base] and [extent] is no longer what it was
  /// when the selection was made.
  bool _textChanged(CellAnchor base, CellAnchor extent) {
    final lines = base.line?.owner;
    if (lines == null || !identical(lines, extent.line?.owner)) return true;
    final first = min(base.y, extent.y);
    final last = max(base.y, extent.y);
    if (last - first != _selectionRows) return true;
    for (var y = first; y <= last; y++) {
      if ((lines[y] as BufferLine).textStamp > _selectionStamp) return true;
    }
    return false;
  }

  void _noteSelection() {
    final base = _selectionBase;
    final extent = _selectionExtent;
    _selectionStamp = BufferLine.textClock;
    _selectionRows = base != null && extent != null && base.attached && extent.attached ? (extent.y - base.y).abs() : 0;
  }

  /// A selection is being made with the pointer held, from here to
  /// [stopSelecting]. For that long it is whatever the pointer covers, also
  /// while output changes the text under it (selecting in a screen that is
  /// being written to must not lose the selection under the pointer); it is
  /// held to its text from the moment the pointer is let go.
  void startSelecting() {
    _selecting = true;
  }

  /// The pointer was let go: what is selected now is what the selection is
  /// of.
  void stopSelecting() {
    if (!_selecting) return;
    _selecting = false;
    _noteSelection();
  }

  /// Runs [change], which lays the terminal's text out afresh without
  /// changing it (a new width breaks long lines elsewhere), and keeps the
  /// selection: it is of the same text, in other rows.
  void keepSelectionThrough(void Function() change) {
    final held = selection != null;
    change();
    final base = _selectionBase;
    final extent = _selectionExtent;
    if (!held || base == null || extent == null || !base.attached || !extent.attached) return;
    _noteSelection();
  }

  /// Set selection on the terminal from [base] to [extent]. This method takes
  /// the ownership of [base] and [extent] and will dispose them when the
  /// selection is cleared or changed.
  void setSelection(CellAnchor base, CellAnchor extent, {SelectionMode? mode}) {
    _selectionBase?.dispose();
    _selectionBase = base;

    _selectionExtent?.dispose();
    _selectionExtent = extent;

    if (mode != null) {
      _selectionMode = mode;
    }

    _noteSelection();

    notifyListeners();
  }

  BufferRange _createRange(CellOffset begin, CellOffset end) {
    switch (selectionMode) {
      case SelectionMode.line:
        return BufferRangeLine(begin, end);
      case SelectionMode.block:
        return BufferRangeBlock(begin, end);
    }
  }

  /// Controls how the terminal behaves when the user selects a range of text.
  /// The default is [SelectionMode.line]. Setting this to [SelectionMode.block]
  /// enables block selection mode.
  void setSelectionMode(SelectionMode newSelectionMode) {
    // If the new mode is the same as the old mode,
    // nothing has to be changed.
    if (_selectionMode == newSelectionMode) {
      return;
    }
    // Set the new mode.
    _selectionMode = newSelectionMode;
    notifyListeners();
  }

  /// Clears the current selection.
  void clearSelection() {
    _selectionBase?.dispose();
    _selectionBase = null;
    _selectionExtent?.dispose();
    _selectionExtent = null;
    notifyListeners();
  }

  // Select which type of pointer events are send to the terminal.
  void setPointerInputs(PointerInputs pointerInput) {
    _pointerInputs = pointerInput;
    notifyListeners();
  }

  // Toggle sending pointer events to the terminal.
  void setSuspendPointerInput(bool suspend) {
    _suspendPointerInputs = suspend;
    notifyListeners();
  }

  // Returns true if this type of PointerInput should be send to the Terminal.
  @internal
  bool shouldSendPointerInput(PointerInput pointerInput) {
    // Always return false if pointer input is suspended.
    return _suspendPointerInputs
        ? false
        : _pointerInputs.inputs.contains(pointerInput);
  }

  /// Creates a new highlight on the terminal from [p1] to [p2] with the given
  /// [color]. The highlight will be removed when the returned object is
  /// disposed.
  TerminalHighlight highlight({
    required CellAnchor p1,
    required CellAnchor p2,
    required Color color,
  }) {
    final highlight = TerminalHighlight(
      this,
      p1: p1,
      p2: p2,
      color: color,
    );

    _highlights.add(highlight);
    notifyListeners();

    highlight.registerCallback(() {
      _highlights.remove(highlight);
      notifyListeners();
    });

    return highlight;
  }
}

class TerminalHighlight with Disposable {
  final TerminalController owner;

  final CellAnchor p1;

  final CellAnchor p2;

  final Color color;

  TerminalHighlight(
    this.owner, {
    required this.p1,
    required this.p2,
    required this.color,
  });

  /// Returns the range of the highlight. May be null if the anchors that
  /// define the highlight are not attached to the terminal.
  BufferRange? get range {
    if (!p1.attached || !p2.attached) {
      return null;
    }
    return BufferRangeLine(p1.offset, p2.offset);
  }
}
