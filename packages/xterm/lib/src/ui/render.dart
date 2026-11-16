import 'dart:async';
import 'dart:math' show max;
import 'dart:ui';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/range.dart';
import 'package:xterm/src/core/buffer/segment.dart';
import 'package:xterm/src/core/mouse/button.dart';
import 'package:xterm/src/core/mouse/button_state.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/cursor_type.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/src/ui/resize_hold.dart';
import 'package:xterm/src/ui/selection_mode.dart';
import 'package:xterm/src/ui/terminal_size.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/terminal_theme.dart';
import 'package:xterm/src/ui/url_detector.dart';

typedef EditableRectCallback = void Function(Rect rect, Rect caretRect);

class RenderTerminal extends RenderBox with RelayoutWhenSystemFontsChangeMixin {
  RenderTerminal({
    required Terminal terminal,
    required TerminalController controller,
    required ViewportOffset offset,
    required EdgeInsets padding,
    required bool autoResize,
    required TerminalStyle textStyle,
    required TextScaler textScaler,
    required TerminalTheme theme,
    required FocusNode focusNode,
    required TerminalCursorType cursorType,
    required bool alwaysShowCursor,
    bool cursorBlink = false,
    bool hideCursor = false,
    bool hideCursorWhileOutput = false,
    EditableRectCallback? onEditableRect,
    String? composingText,
    bool enableUrlDetection = false,
    Color urlColor = const Color(0xFF5599DD),
  })  : _terminal = terminal,
        _controller = controller,
        _offset = offset,
        _padding = padding,
        _autoResize = autoResize,
        _focusNode = focusNode,
        _cursorType = cursorType,
        _alwaysShowCursor = alwaysShowCursor,
        _cursorBlink = cursorBlink,
        _hideCursor = hideCursor,
        _hideCursorWhileOutput = hideCursorWhileOutput,
        _onEditableRect = onEditableRect,
        _composingText = composingText,
        _enableUrlDetection = enableUrlDetection,
        _urlColor = urlColor,
        _painter = TerminalPainter(
          theme: theme,
          textStyle: textStyle,
          textScaler: textScaler,
        );

  Terminal _terminal;
  set terminal(Terminal terminal) {
    if (_terminal == terminal) return;
    if (attached) _terminal.removeListener(_onTerminalChange);
    _terminal = terminal;
    if (attached) _terminal.addListener(_onTerminalChange);
    _resizeTerminalIfNeeded();
    markNeedsLayout();
  }

  TerminalController _controller;
  set controller(TerminalController controller) {
    if (_controller == controller) return;
    if (attached) _controller.removeListener(_onControllerUpdate);
    _controller = controller;
    if (attached) _controller.addListener(_onControllerUpdate);
    markNeedsLayout();
  }

  ViewportOffset _offset;
  set offset(ViewportOffset value) {
    if (value == _offset) return;
    if (attached) _offset.removeListener(_onScroll);
    _offset = value;
    if (attached) _offset.addListener(_onScroll);
    markNeedsLayout();
  }

  EdgeInsets _padding;
  set padding(EdgeInsets value) {
    if (value == _padding) return;
    _padding = value;
    markNeedsLayout();
  }

  bool _autoResize;
  set autoResize(bool value) {
    if (value == _autoResize) return;
    _autoResize = value;
    markNeedsLayout();
  }

  set textStyle(TerminalStyle value) {
    if (value == _painter.textStyle) return;
    _painter.textStyle = value;
    markNeedsLayout();
  }

  set textScaler(TextScaler value) {
    if (value == _painter.textScaler) return;
    _painter.textScaler = value;
    markNeedsLayout();
  }

  set theme(TerminalTheme value) {
    if (value == _painter.theme) return;
    _painter.theme = value;
    markNeedsPaint();
  }

  FocusNode _focusNode;
  set focusNode(FocusNode value) {
    if (value == _focusNode) return;
    if (attached) _focusNode.removeListener(_onFocusChange);
    _focusNode = value;
    if (attached) _focusNode.addListener(_onFocusChange);
    _syncBlinkTimer();
    markNeedsPaint();
  }

  TerminalCursorType _cursorType;
  set cursorType(TerminalCursorType value) {
    if (value == _cursorType) return;
    _cursorType = value;
    markNeedsPaint();
  }

  bool _alwaysShowCursor;
  set alwaysShowCursor(bool value) {
    if (value == _alwaysShowCursor) return;
    _alwaysShowCursor = value;
    markNeedsPaint();
  }

  // The cursor hidden by the person's choice (ZestSSH, 4.0): never, or
  // while output that moves it about is arriving. A program's own hide
  // request (DECTCEM, ESC [ ? 25 l) is obeyed either way: see
  // [_shouldShowCursor].

  bool _hideCursor;
  set hideCursor(bool value) {
    if (value == _hideCursor) return;
    _hideCursor = value;
    markNeedsPaint();
  }

  bool _hideCursorWhileOutput;
  set hideCursorWhileOutput(bool value) {
    if (value == _hideCursorWhileOutput) return;
    _hideCursorWhileOutput = value;
    if (!value) _endOutputHide();
    markNeedsPaint();
  }

  /// How long no output must come before a cursor hidden while output
  /// arrived is drawn again.
  static const cursorOutputQuiet = Duration(milliseconds: 200);

  Timer? _outputQuietTimer;

  /// Hidden now because output is arriving ([hideCursorWhileOutput]).
  bool _outputHidden = false;

  /// Where the cursor was at the last output, to tell typing (a cell or two
  /// along the line) from a program drawing all over the screen.
  int _lastOutputCursorX = 0;
  int _lastOutputCursorY = 0;

  /// Whether the cursor is drawn now, blink and all: false while a program
  /// hid it, while the person chose to hide it, while output arrives (where
  /// they chose that), and in the hidden phase of a blink.
  bool get isCursorDrawn =>
      _shouldShowCursor && _blinkVisible && !_hideCursor && !_outputHidden;

  void _noteOutputForCursor() {
    final x = _terminal.buffer.cursorX;
    final y = _terminal.buffer.absoluteCursorY;
    final jumped = y != _lastOutputCursorY || (x - _lastOutputCursorX).abs() > 2;
    _lastOutputCursorX = x;
    _lastOutputCursorY = y;
    if (!_hideCursorWhileOutput) return;
    // What was typed, echoed: the cursor stays where the eye is. Output that
    // goes on while it is hidden keeps it hidden.
    if (!jumped && !_outputHidden) return;
    _outputHidden = true;
    _outputQuietTimer?.cancel();
    _outputQuietTimer = Timer(cursorOutputQuiet, () {
      _outputQuietTimer = null;
      _outputHidden = false;
      if (attached) markNeedsPaint();
    });
  }

  void _endOutputHide() {
    _outputQuietTimer?.cancel();
    _outputQuietTimer = null;
    _outputHidden = false;
  }

  // Cursor blink.
  //
  // The timer lives on the render object so a tick costs exactly one
  // markNeedsPaint on this repaint boundary: no widget rebuild, no relayout.
  // Rule: the cursor blinks only while [cursorBlink] is on, the view has
  // keyboard focus and the render object is attached. Any key input or
  // terminal output shows the cursor and restarts the period, so it never
  // blinks off while the user is typing. Stopping (focus lost, flag turned
  // off, detach) always leaves the cursor shown solid.

  /// Length of one blink phase (shown or hidden).
  static const cursorBlinkInterval = Duration(milliseconds: 530);

  bool _cursorBlink;
  set cursorBlink(bool value) {
    if (value == _cursorBlink) return;
    _cursorBlink = value;
    _syncBlinkTimer();
  }

  Timer? _blinkTimer;

  /// False during the hidden half of a blink period. Always true while the
  /// cursor is not blinking.
  bool _blinkVisible = true;

  /// Whether the cursor is in its shown blink phase.
  bool get cursorBlinkVisible => _blinkVisible;

  /// Whether the blink timer is running.
  bool get isCursorBlinking => _blinkTimer != null;

  void _syncBlinkTimer() {
    if (_cursorBlink && _focusNode.hasFocus && attached) {
      _blinkTimer ??= Timer.periodic(cursorBlinkInterval, _onBlinkTick);
      return;
    }
    _blinkTimer?.cancel();
    _blinkTimer = null;
    _showCursorNow();
  }

  void _onBlinkTick(Timer _) {
    _blinkVisible = !_blinkVisible;
    markNeedsPaint();
  }

  void _showCursorNow() {
    if (_blinkVisible) return;
    _blinkVisible = true;
    if (attached) markNeedsPaint();
  }

  /// Shows the cursor and restarts its blink period. Called on key input and
  /// on terminal output; a no-op while the cursor is not blinking.
  void resetCursorBlink() {
    final timer = _blinkTimer;
    if (timer == null) return;
    timer.cancel();
    _blinkTimer = Timer.periodic(cursorBlinkInterval, _onBlinkTick);
    _showCursorNow();
  }

  EditableRectCallback? _onEditableRect;
  set onEditableRect(EditableRectCallback? value) {
    if (value == _onEditableRect) return;
    _onEditableRect = value;
    markNeedsLayout();
  }

  String? _composingText;
  set composingText(String? value) {
    if (value == _composingText) return;
    _composingText = value;
    markNeedsPaint();
  }

  bool _enableUrlDetection;
  set enableUrlDetection(bool value) {
    if (value == _enableUrlDetection) return;
    _enableUrlDetection = value;
    if (!value) _urlDetector.invalidate();
    markNeedsPaint();
  }

  Color _urlColor;
  set urlColor(Color value) {
    if (value == _urlColor) return;
    _urlColor = value;
    markNeedsPaint();
  }

  TerminalSize? _viewportSize;

  final TerminalPainter _painter;

  final UrlDetector _urlDetector = UrlDetector();

  var _stickToBottom = true;

  /// Whether the terminal is currently scrolled to the bottom. When false,
  /// the user is viewing scrollback history.
  bool get isAtBottom => _stickToBottom;

  /// Whether new output has arrived while the user is scrolled up viewing
  /// history. Reset when the user scrolls back to the bottom.
  bool _hasNewOutput = false;
  bool get hasNewOutput => _hasNewOutput;

  /// Invoked whenever the viewport scrolls. The gesture layer uses this
  /// to re-extend an in-progress drag-selection when the user wheel-
  /// scrolls mid-drag, so the selection grows into scrollback instead of
  /// staying frozen at one screen.
  VoidCallback? onViewportScrolled;

  void _onScroll() {
    _stickToBottom = _scrollOffset >= _maxScrollExtent - 1.0;
    if (_stickToBottom && _hasNewOutput) {
      _hasNewOutput = false;
      onScrollStateChanged?.call();
    }
    markNeedsLayout();
    _notifyEditableRect();
    onViewportScrolled?.call();
  }

  void _onFocusChange() {
    _syncBlinkTimer();
    markNeedsPaint();
  }

  /// Callback invoked when isAtBottom or hasNewOutput changes.
  VoidCallback? onScrollStateChanged;

  void _onTerminalChange() {
    // The text under the selection is not what was selected any more (it was
    // cleared away, written over, or the program took the whole screen): the
    // selection is over. Said through the controller, so that whatever shows
    // something for a selection hears of it.
    if (_controller.selectionEnded) _controller.clearSelection();
    resetCursorBlink();
    _noteOutputForCursor();
    if (!_stickToBottom) {
      final hadNewOutput = _hasNewOutput;
      _hasNewOutput = true;
      if (!hadNewOutput) {
        onScrollStateChanged?.call();
      }
    }
    markNeedsLayout();
    _notifyEditableRect();
  }

  void _onControllerUpdate() {
    markNeedsLayout();
  }

  @override
  final isRepaintBoundary = true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _offset.addListener(_onScroll);
    _terminal.addListener(_onTerminalChange);
    _controller.addListener(_onControllerUpdate);
    _focusNode.addListener(_onFocusChange);
    TerminalResizeHold.listenable.addListener(_onResizeHold);
    _syncBlinkTimer();
  }

  @override
  void detach() {
    super.detach();
    _offset.removeListener(_onScroll);
    _terminal.removeListener(_onTerminalChange);
    _controller.removeListener(_onControllerUpdate);
    _focusNode.removeListener(_onFocusChange);
    TerminalResizeHold.listenable.removeListener(_onResizeHold);
    _syncBlinkTimer();
    _endOutputHide();
  }

  /// A drag that held the size has ended: take the size the view has now.
  void _onResizeHold() {
    if (TerminalResizeHold.held) return;
    _resizeTerminalIfNeeded();
    markNeedsLayout();
  }

  @override
  void dispose() {
    _blinkTimer?.cancel();
    _blinkTimer = null;
    _endOutputHide();
    super.dispose();
  }

  @override
  bool hitTestSelf(Offset position) {
    return true;
  }

  @override
  void systemFontsDidChange() {
    _painter.clearFontCache();
    super.systemFontsDidChange();
  }

  @override
  void performLayout() {
    size = constraints.biggest;

    _updateViewportSize();

    _updateScrollOffset();

    if (_stickToBottom) {
      _offset.correctBy(_maxScrollExtent - _scrollOffset);
    }
  }

  /// Total height of the terminal in pixels. Includes scrollback buffer.
  double get _terminalHeight =>
      _terminal.buffer.lines.length * _painter.cellSize.height;

  /// The distance from the top of the terminal to the top of the viewport.
  // double get _scrollOffset => _offset.pixels;
  double get _scrollOffset {
    // return _offset.pixels ~/ _painter.cellSize.height * _painter.cellSize.height;
    return _offset.pixels;
  }

  /// The height of a terminal line in pixels. This includes the line spacing.
  /// Height of the entire terminal is expected to be a multiple of this value.
  double get lineHeight => _painter.cellSize.height;

  /// Get the top-left corner of the cell at [cellOffset] in pixels.
  Offset getOffset(CellOffset cellOffset) {
    final row = cellOffset.y;
    final col = cellOffset.x;
    final x = col * _painter.cellSize.width;
    final y = row * _painter.cellSize.height;
    return Offset(x + _padding.left, y + _padding.top - _scrollOffset);
  }

  /// Get the [CellOffset] of the cell that [offset] is in.
  CellOffset getCellOffset(Offset offset) {
    final x = offset.dx - _padding.left;
    final y = offset.dy - _padding.top + _scrollOffset;
    final row = y ~/ _painter.cellSize.height;
    final col = x ~/ _painter.cellSize.width;
    return CellOffset(
      col.clamp(0, _terminal.viewWidth - 1),
      row.clamp(0, _terminal.buffer.lines.length - 1),
    );
  }

  /// Selects entire words in the terminal that contains [from] and [to].
  void selectWord(Offset from, [Offset? to]) {
    final fromOffset = getCellOffset(from);
    final fromBoundary = _terminal.buffer.getWordBoundary(fromOffset);
    if (fromBoundary == null) return;
    if (to == null) {
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(fromBoundary.begin),
        _terminal.buffer.createAnchorFromOffset(fromBoundary.end),
        mode: SelectionMode.line,
      );
    } else {
      final toOffset = getCellOffset(to);
      final toBoundary = _terminal.buffer.getWordBoundary(toOffset);
      if (toBoundary == null) return;
      final range = fromBoundary.merge(toBoundary);
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(range.begin),
        _terminal.buffer.createAnchorFromOffset(range.end),
        mode: SelectionMode.line,
      );
    }
  }

  /// Selects the whole line at [at], as a triple click does in xterm: a line
  /// as it was written, with the rows it wrapped onto, from its start to its
  /// last character (to the row's end where it is blank).
  void selectLine(Offset at) {
    final lines = _terminal.buffer.lines;
    var first = getCellOffset(at).y;
    var last = first;
    while (first > 0 && lines[first].isWrapped) {
      first--;
    }
    while (last + 1 < lines.length && lines[last + 1].isWrapped) {
      last++;
    }
    final length = lines[last].getTrimmedLength();
    final end = first == last && length == 0 ? _terminal.viewWidth : length;
    _controller.setSelection(
      _terminal.buffer.createAnchor(0, first),
      _terminal.buffer.createAnchor(end, last),
      mode: SelectionMode.line,
    );
  }

  /// Selects characters in the terminal that starts from [from] to [to]. At
  /// least one cell is selected even if [from] and [to] are same.
  void selectCharacters(Offset from, [Offset? to]) {
    final fromPosition = getCellOffset(from);
    if (to == null) {
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(fromPosition),
        _terminal.buffer.createAnchorFromOffset(fromPosition),
      );
    } else {
      var toPosition = getCellOffset(to);
      if (toPosition.x >= fromPosition.x) {
        toPosition = CellOffset(toPosition.x + 1, toPosition.y);
      }
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(fromPosition),
        _terminal.buffer.createAnchorFromOffset(toPosition),
      );
    }
  }

  /// Like [selectCharacters] but with a pre-resolved start CELL instead of
  /// a start screen offset. Used by drag-select auto-scroll: when the
  /// viewport scrolls mid-drag, a fixed start *screen* position would map
  /// to a different cell each frame (the anchor would drift). Resolving the
  /// start once into a buffer cell keeps the selection origin pinned while
  /// [to] (still a live screen offset) extends against the current scroll.
  void selectCharactersFromCell(CellOffset fromPosition, Offset to) {
    var toPosition = getCellOffset(to);
    if (toPosition.x >= fromPosition.x) {
      toPosition = CellOffset(toPosition.x + 1, toPosition.y);
    }
    _controller.setSelection(
      _terminal.buffer.createAnchorFromOffset(fromPosition),
      _terminal.buffer.createAnchorFromOffset(toPosition),
    );
  }

  /// Pixel height of the terminal viewport (excludes vertical padding).
  /// Exposed so the gesture layer can detect edge zones for auto-scroll.
  double get viewportHeight => _viewportHeight;

  /// Send a mouse event at [offset] with [button] being currently in [buttonState].
  bool mouseEvent(
    TerminalMouseButton button,
    TerminalMouseButtonState buttonState,
    Offset offset,
  ) {
    final position = getCellOffset(offset);
    return _terminal.mouseInput(button, buttonState, position);
  }

  void _notifyEditableRect() {
    final cursor = localToGlobal(cursorOffset);

    final rect = Rect.fromLTRB(
      cursor.dx,
      cursor.dy,
      size.width,
      cursor.dy + _painter.cellSize.height,
    );

    final caretRect = cursor & _painter.cellSize;

    _onEditableRect?.call(rect, caretRect);
  }

  /// Update the viewport size in cells based on the current widget size in
  /// pixels.
  void _updateViewportSize() {
    if (size <= _painter.cellSize) {
      return;
    }

    final viewportSize = TerminalSize(
      size.width ~/ _painter.cellSize.width,
      _viewportHeight ~/ _painter.cellSize.height,
    );

    if (_viewportSize != viewportSize) {
      _viewportSize = viewportSize;
      _resizeTerminalIfNeeded();
    }
  }

  /// Notify the underlying terminal that the viewport size has changed.
  void _resizeTerminalIfNeeded() {
    if (_autoResize && _viewportSize != null && !TerminalResizeHold.held) {
      // A new size lays the text out afresh; what is selected is still the
      // same text.
      _controller.keepSelectionThrough(() => _terminal.resize(
            _viewportSize!.width,
            _viewportSize!.height,
            _painter.cellSize.width.round(),
            _painter.cellSize.height.round(),
          ));
    }
  }

  /// Update the scroll offset based on the current terminal state. This should
  /// be called in [performLayout] after the viewport size has been updated.
  void _updateScrollOffset() {
    _offset.applyViewportDimension(_viewportHeight);
    _offset.applyContentDimensions(0, _maxScrollExtent);
  }

  bool get _isComposingText {
    return _composingText != null && _composingText!.isNotEmpty;
  }

  bool get _shouldShowCursor {
    return _terminal.cursorVisibleMode || _alwaysShowCursor || _isComposingText;
  }

  double get _viewportHeight {
    return size.height - _padding.vertical;
  }

  double get _maxScrollExtent {
    // In whole rows: at the bottom the first row shown starts at the top of
    // the text, and what is too little for a row is left under the last one,
    // as in other terminals. It was left above the first, which a short pane
    // (a tab of sixteen) showed cut in half under its header.
    final rowHeight = _painter.cellSize.height;
    final shown = rowHeight > 0 ? (_viewportHeight ~/ rowHeight) * rowHeight : _viewportHeight;
    return max(_terminalHeight - shown, 0.0);
  }

  double get _lineOffset {
    return -_scrollOffset + _padding.top;
  }

  /// The offset of the cursor from the top left corner of this render object.
  Offset get cursorOffset {
    return Offset(
      _terminal.buffer.cursorX * _painter.cellSize.width,
      _terminal.buffer.absoluteCursorY * _painter.cellSize.height + _lineOffset,
    );
  }

  Size get cellSize {
    return _painter.cellSize;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // Rows are drawn inside the padding: one scrolled partly out of view
    // stops at the edge of the text and never shows a slice in the margin.
    final canvas = context.canvas;
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(
      offset.dx,
      offset.dy + _padding.top,
      offset.dx + size.width,
      offset.dy + size.height - _padding.bottom,
    ));
    _paint(context, offset);
    canvas.restore();
    context.setWillChangeHint();
  }

  void _paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;

    final lines = _terminal.buffer.lines;
    final charHeight = _painter.cellSize.height;

    final firstLineOffset = _scrollOffset - _padding.top;
    final lastLineOffset = _scrollOffset + size.height + _padding.bottom;

    final firstLine = firstLineOffset ~/ charHeight;
    final lastLine = lastLineOffset ~/ charHeight;

    final effectFirstLine = firstLine.clamp(0, lines.length - 1);
    final effectLastLine = lastLine.clamp(0, lines.length - 1);

    for (var i = effectFirstLine; i <= effectLastLine; i++) {
      _painter.paintLine(
        canvas,
        offset.translate(0, (i * charHeight + _lineOffset).truncateToDouble()),
        lines[i],
      );
    }

    if (_terminal.buffer.absoluteCursorY >= effectFirstLine &&
        _terminal.buffer.absoluteCursorY <= effectLastLine) {
      if (_isComposingText) {
        _paintComposingText(canvas, offset + cursorOffset);
      } else if (_terminal.ghostText != null && !_terminal.isUsingAltBuffer) {
        // Under the cursor, so a block cursor still shows on top.
        _paintGhostText(canvas, offset, offset + cursorOffset, _terminal.ghostText!);
      }

      if (isCursorDrawn) {
        _painter.paintCursor(
          canvas,
          offset + cursorOffset,
          cursorType: _cursorType,
          hasFocus: _focusNode.hasFocus,
        );
      }
    }

    _paintHighlights(
      canvas,
      _controller.highlights,
      effectFirstLine,
      effectLastLine,
    );

    if (_enableUrlDetection) {
      _urlDetector.scan(lines, effectFirstLine, effectLastLine);
      _paintUrlUnderlines(canvas, effectFirstLine, effectLastLine);
    }

    if (_controller.selection != null) {
      _paintSelection(
        canvas,
        _controller.selection!,
        effectFirstLine,
        effectLastLine,
      );
    }
  }

  /// Paints [text], the terminal's ghost text (a suggestion), dimmed from
  /// [at] (the cursor) on, on one line and cut at the right edge of the
  /// terminal, whose top-left is [origin].
  void _paintGhostText(Canvas canvas, Offset origin, Offset at, String text) {
    final style = _painter.textStyle.toTextStyle(color: _painter.theme.brightBlack);
    final builder = ParagraphBuilder(style.getParagraphStyle(maxLines: 1));
    builder.pushStyle(style.getTextStyle(textScaler: _painter.textScaler));
    builder.addText(text.replaceAll('\n', ' ').replaceAll('\r', ' '));
    final paragraph = builder.build();
    final right = origin.dx + size.width;
    paragraph.layout(ParagraphConstraints(width: double.infinity));
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(at.dx, at.dy, right, at.dy + _painter.cellSize.height));
    canvas.drawParagraph(paragraph, at);
    canvas.restore();
    paragraph.dispose();
  }

  /// Paints the text that is currently being composed in IME to [canvas] at
  /// [offset]. [offset] is usually the cursor position.
  void _paintComposingText(Canvas canvas, Offset offset) {
    final composingText = _composingText;
    if (composingText == null) {
      return;
    }

    final style = _painter.textStyle.toTextStyle(
      color: _painter.resolveForegroundColor(_terminal.cursor.foreground),
      backgroundColor: _painter.theme.background,
      underline: true,
    );

    final builder = ParagraphBuilder(style.getParagraphStyle());
    builder.addPlaceholder(
      offset.dx,
      _painter.cellSize.height,
      PlaceholderAlignment.middle,
    );
    builder.pushStyle(
      style.getTextStyle(textScaler: _painter.textScaler),
    );
    builder.addText(composingText);

    final paragraph = builder.build();
    paragraph.layout(ParagraphConstraints(width: size.width));

    canvas.drawParagraph(paragraph, Offset(0, offset.dy));
  }

  void _paintSelection(
    Canvas canvas,
    BufferRange selection,
    int firstLine,
    int lastLine,
  ) {
    for (final segment in selection.toSegments()) {
      if (segment.line >= _terminal.buffer.lines.length) {
        break;
      }

      if (segment.line < firstLine) {
        continue;
      }

      if (segment.line > lastLine) {
        break;
      }

      _paintSegment(canvas, segment, _painter.theme.selection);
    }
  }

  void _paintHighlights(
    Canvas canvas,
    List<TerminalHighlight> highlights,
    int firstLine,
    int lastLine,
  ) {
    for (var highlight in _controller.highlights) {
      final range = highlight.range?.normalized;

      if (range == null ||
          range.begin.y > lastLine ||
          range.end.y < firstLine) {
        continue;
      }

      for (var segment in range.toSegments()) {
        if (segment.line < firstLine) {
          continue;
        }

        if (segment.line > lastLine) {
          break;
        }

        _paintSegment(canvas, segment, highlight.color);
      }
    }
  }

  @pragma('vm:prefer-inline')
  void _paintSegment(Canvas canvas, BufferSegment segment, Color color) {
    final start = segment.start ?? 0;
    final end = segment.end ?? _terminal.viewWidth;

    final startOffset = Offset(
      start * _painter.cellSize.width,
      segment.line * _painter.cellSize.height + _lineOffset,
    );

    _painter.paintHighlight(canvas, startOffset, end - start, color);
  }

  /// Paints underlines beneath detected URLs in the visible range.
  void _paintUrlUnderlines(Canvas canvas, int firstLine, int lastLine) {
    final paint = Paint()
      ..color = _urlColor
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    for (final url in _urlDetector.urls) {
      if (url.row < firstLine || url.row > lastLine) continue;

      final y = url.row * _painter.cellSize.height +
          _lineOffset +
          _painter.cellSize.height - 1;
      final startX = url.startCol * _painter.cellSize.width;
      final endX = url.endCol * _painter.cellSize.width;

      canvas.drawLine(Offset(startX, y), Offset(endX, y), paint);
    }
  }

  /// Returns the detected [TerminalUrl] at the given pixel position, or null.
  TerminalUrl? getUrlAt(Offset position) {
    if (!_enableUrlDetection) return null;
    final cellOffset = getCellOffset(position);
    _urlDetector.rescanIfStale(_terminal.buffer.lines);
    return _urlDetector.getUrlAt(cellOffset);
  }

  /// Returns the detected [TerminalUrl] at the given cell position, or null.
  TerminalUrl? getUrlAtCell(CellOffset cellOffset) {
    if (!_enableUrlDetection) return null;
    _urlDetector.rescanIfStale(_terminal.buffer.lines);
    return _urlDetector.getUrlAt(cellOffset);
  }
}
