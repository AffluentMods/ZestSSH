import 'dart:math' show max;

import 'package:xterm/src/base/observable.dart';
import 'package:xterm/src/core/buffer/buffer.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/cursor.dart';
import 'package:xterm/src/core/escape/emitter.dart';
import 'package:xterm/src/core/escape/handler.dart';
import 'package:xterm/src/core/escape/parser.dart';
import 'package:xterm/src/core/input/handler.dart';
import 'package:xterm/src/core/input/keys.dart';
import 'package:xterm/src/core/mouse/button.dart';
import 'package:xterm/src/core/mouse/button_state.dart';
import 'package:xterm/src/core/mouse/handler.dart';
import 'package:xterm/src/core/mouse/mode.dart';
import 'package:xterm/src/core/mouse/reporter.dart';
import 'package:xterm/src/core/platform.dart';
import 'package:xterm/src/core/state.dart';
import 'package:xterm/src/core/tabs.dart';
import 'package:xterm/src/utils/ascii.dart';
import 'package:xterm/src/utils/circular_buffer.dart';

/// [Terminal] is an interface to interact with command line applications. It
/// translates escape sequences from the application into updates to the
/// [buffer] and events such as [onTitleChange] or [onBell], as well as
/// translating user input into escape sequences that the application can
/// understand.
class Terminal with Observable implements TerminalState, EscapeHandler {
  /// The number of lines that the scrollback buffer can hold. If the buffer
  /// exceeds this size, the lines at the top of the buffer will be removed.
  final int maxLines;

  /// Function that is called when the program requests the terminal to ring
  /// the bell. If not set, the terminal will do nothing.
  void Function()? onBell;

  /// Function that is called when the program requests the terminal to change
  /// the title of the window to [title].
  void Function(String title)? onTitleChange;

  /// Function that is called when the program requests the terminal to change
  /// the icon of the window. [icon] is the name of the icon.
  void Function(String icon)? onIconChange;

  /// Function that is called when the terminal emits data to the underlying
  /// program. This is typically caused by user inputs from [textInput],
  /// [keyInput], [mouseInput], or [paste]; the terminal's own answers to what
  /// the program asks come through it as well. While it is called,
  /// [outputOrigin] says which of these it is, and [outputTyped] is what was
  /// typed.
  void Function(String data)? onOutput;

  TerminalOutputOrigin _outputOrigin = TerminalOutputOrigin.typed;
  TerminalTyped? _outputTyped;

  /// While [onOutput] is being called: where what it is given comes from.
  /// What a person types is theirs to send wherever they mean it to go; what
  /// the terminal answers by itself belongs to the one program that asked.
  TerminalOutputOrigin get outputOrigin => _outputOrigin;

  /// While [onOutput] is being called for something typed: what was typed,
  /// to type the same into another terminal ([TerminalTyped.typeInto]).
  /// Null for the mouse and for the terminal's own answers.
  TerminalTyped? get outputTyped => _outputTyped;

  void _emit(String data, TerminalOutputOrigin origin, [TerminalTyped? typed]) {
    final handler = onOutput;
    if (handler == null) return;
    final wasOrigin = _outputOrigin;
    final wasTyped = _outputTyped;
    _outputOrigin = origin;
    _outputTyped = typed;
    try {
      handler(data);
    } finally {
      _outputOrigin = wasOrigin;
      _outputTyped = wasTyped;
    }
  }

  /// Function that is called when the dimensions of the terminal change.
  void Function(int width, int height, int pixelWidth, int pixelHeight)?
      onResize;

  String? _ghostText;

  /// Text drawn dimmed from the cursor on, NOT part of the buffer and never
  /// sent anywhere: a suggestion the user may accept (ZestSSH 3.0: history
  /// suggestions). Null or empty shows nothing. Setting a different value
  /// repaints; the full-screen (alternate) buffer never shows it.
  String? get ghostText => _ghostText;

  set ghostText(String? value) {
    final next = value == null || value.isEmpty ? null : value;
    if (next == _ghostText) return;
    _ghostText = next;
    notifyListeners();
  }

  /// Whether the terminal answers queries from the program itself (device
  /// attributes, cursor position, operating status, window size). Set to false
  /// when the emulator mirrors a screen that another terminal already answers
  /// for (a tmux pane in control mode): a second reply would reach the program
  /// as if the user had typed it.
  bool respondToQueries = true;

  /// The [TerminalInputHandler] used by this terminal. [defaultInputHandler] is
  /// used when not specified. User of this class can provide their own
  /// implementation of [TerminalInputHandler] or extend [defaultInputHandler]
  /// with [CascadeInputHandler].
  TerminalInputHandler? inputHandler;

  TerminalMouseHandler? mouseHandler;

  /// The callback that is called when the terminal receives a unrecognized
  /// escape sequence.
  void Function(String code, List<String> args)? onPrivateOSC;

  /// What a code in the program's output threw when it was carried out, for a
  /// log: [write] passes over such a code and goes on. Not set, nobody hears.
  void Function(Object error, StackTrace stack)? onWriteError;

  /// Flag to toggle os specific behaviors.
  final TerminalTargetPlatform platform;

  /// Characters that break selection when double clicking. If not set, the
  /// [Buffer.defaultWordSeparators] will be used.
  final Set<int>? wordSeparators;

  Terminal({
    this.maxLines = 1000,
    this.onBell,
    this.onTitleChange,
    this.onIconChange,
    this.onOutput,
    this.onResize,
    this.platform = TerminalTargetPlatform.unknown,
    this.inputHandler = defaultInputHandler,
    this.mouseHandler = defaultMouseHandler,
    this.onPrivateOSC,
    this.reflowEnabled = true,
    this.wordSeparators,
  });

  late final _parser = EscapeParser(this);

  final _emitter = const EscapeEmitter();

  late var _buffer = _mainBuffer;

  late final _mainBuffer = Buffer(
    this,
    maxLines: maxLines,
    isAltBuffer: false,
    wordSeparators: wordSeparators,
  );

  late final _altBuffer = Buffer(
    this,
    maxLines: maxLines,
    isAltBuffer: true,
    wordSeparators: wordSeparators,
  );

  final _tabStops = TabStops();

  /// The last character written to the buffer. Used to implement some escape
  /// sequences that repeat the last character.
  var _precedingCodepoint = 0;

  /* TerminalState */

  int _viewWidth = 80;

  int _viewHeight = 24;

  final _cursorStyle = CursorStyle();

  bool _insertMode = false;

  bool _lineFeedMode = false;

  bool _cursorKeysMode = false;

  bool _reverseDisplayMode = false;

  bool _originMode = false;

  bool _autoWrapMode = true;

  MouseMode _mouseMode = MouseMode.none;

  MouseReportMode _mouseReportMode = MouseReportMode.normal;

  bool _cursorBlinkMode = false;

  bool _cursorVisibleMode = true;

  bool _appKeypadMode = false;

  bool _reportFocusMode = false;

  bool _altBufferMouseScrollMode = false;

  bool _bracketedPasteMode = false;

  /* State getters */

  /// Number of cells in a terminal row.
  @override
  int get viewWidth => _viewWidth;

  /// Number of rows in this terminal.
  @override
  int get viewHeight => _viewHeight;

  @override
  CursorStyle get cursor => _cursorStyle;

  @override
  bool get insertMode => _insertMode;

  @override
  bool get lineFeedMode => _lineFeedMode;

  @override
  bool get cursorKeysMode => _cursorKeysMode;

  @override
  bool get reverseDisplayMode => _reverseDisplayMode;

  @override
  bool get originMode => _originMode;

  @override
  bool get autoWrapMode => _autoWrapMode;

  @override
  MouseMode get mouseMode => _mouseMode;

  @override
  MouseReportMode get mouseReportMode => _mouseReportMode;

  @override
  bool get cursorBlinkMode => _cursorBlinkMode;

  @override
  bool get cursorVisibleMode => _cursorVisibleMode;

  @override
  bool get appKeypadMode => _appKeypadMode;

  @override
  bool get reportFocusMode => _reportFocusMode;

  @override
  bool get altBufferMouseScrollMode => _altBufferMouseScrollMode;

  @override
  bool get bracketedPasteMode => _bracketedPasteMode;

  /// Current active buffer of the terminal. This is initially [mainBuffer] and
  /// can be switched back and forth from [altBuffer] to [mainBuffer] when
  /// the underlying program requests it.
  Buffer get buffer => _buffer;

  Buffer get mainBuffer => _mainBuffer;

  Buffer get altBuffer => _altBuffer;

  bool get isUsingAltBuffer => _buffer == _altBuffer;

  /// Lines of the active buffer.
  IndexAwareCircularBuffer<BufferLine> get lines => _buffer.lines;

  /// Whether the terminal performs reflow when the viewport size changes or
  /// simply truncates lines. true by default.
  @override
  bool reflowEnabled;

  /// Writes the data from the underlying program to the terminal. Calling this
  /// updates the states of the terminal and emits events such as [onBell] or
  /// [onTitleChange] when the escape sequences in [data] request it.
  ///
  /// Never throws for what is in [data]: a code that cannot be carried out is
  /// passed over ([onWriteError] hears of it), so one line of a program's
  /// output cannot stop what shows its session.
  void write(String data) {
    _parser.write(data, onError: onWriteError);
    notifyListeners();
  }

  /// Sends a key event to the underlying program.
  ///
  /// See also:
  /// - [charInput]
  /// - [textInput]
  /// - [paste]
  ///
  /// [altIsMeta] says whether Alt (Option) held with a key that types a
  /// character sends ESC and that character ([TerminalKeyboardEvent.altIsMeta];
  /// unless told, everywhere but on a Mac); [character] is the character the
  /// key typed in the keyboard's layout, where Alt did not change it
  /// ([TerminalKeyboardEvent.character]).
  bool keyInput(
    TerminalKey key, {
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
    bool? altIsMeta,
    String? character,
  }) {
    final output = inputHandler?.call(
      TerminalKeyboardEvent(
        key: key,
        shift: shift,
        alt: alt,
        ctrl: ctrl,
        state: this,
        altBuffer: isUsingAltBuffer,
        platform: platform,
        altIsMeta: altIsMeta,
        character: character,
      ),
    );

    if (output != null) {
      _emit(
        output,
        TerminalOutputOrigin.typed,
        TypedKey(key, shift: shift, alt: alt, ctrl: ctrl, altIsMeta: altIsMeta, character: character),
      );
      return true;
    }

    return false;
  }

  /// Similary to [keyInput], but takes a character as input instead of a
  /// [TerminalKey].
  ///
  /// See also:
  /// - [keyInput]
  /// - [textInput]
  /// - [paste]
  bool charInput(
    int charCode, {
    bool alt = false,
    bool ctrl = false,
  }) {
    final typed = TypedChar(charCode, alt: alt, ctrl: ctrl);
    if (ctrl) {
      // a(97) ~ z(122)
      if (charCode >= Ascii.a && charCode <= Ascii.z) {
        final output = charCode - Ascii.a + 1;
        _emit(String.fromCharCode(output), TerminalOutputOrigin.typed, typed);
        return true;
      }

      // [(91) ~ _(95)
      if (charCode >= Ascii.openBracket && charCode <= Ascii.underscore) {
        final output = charCode - Ascii.openBracket + 27;
        _emit(String.fromCharCode(output), TerminalOutputOrigin.typed, typed);
        return true;
      }
    }

    // ESC and the character as it is, any printable one: it sent ESC and the
    // letter made uppercase, and nothing for a digit or a mark (Alt+b went
    // to the shell as Alt+Shift+B), as the keys' Alt did ([AltInputHandler]).
    if (alt && platform != TerminalTargetPlatform.macos) {
      if (charCode >= 0x20 && charCode <= 0x7e) {
        _emit(String.fromCharCodes([0x1b, charCode]), TerminalOutputOrigin.typed, typed);
        return true;
      }
    }

    return false;
  }

  /// Sends regular text input to the underlying program.
  ///
  /// See also:
  /// - [keyInput]
  /// - [charInput]
  /// - [paste]
  void textInput(String text) {
    _emit(text, TerminalOutputOrigin.typed, TypedText(text));
  }

  /// Similar to [textInput], except that when the program tells the terminal
  /// that it supports [bracketedPasteMode], the text is wrapped in escape
  /// sequences to indicate that it is a paste operation. Prefer this method
  /// over [textInput] when pasting text.
  ///
  /// See also:
  /// - [textInput]
  void paste(String text) {
    // What a paste may type ([pasteable]): no control character but a tab
    // and a line break.
    final clean = pasteable(text);
    // Normalize line endings to a single carriage return, the way
    // xterm.js / iTerm2 / gnome-terminal do. Pasting CRLF content
    // (anything copied from a Windows app) used to send each line break
    // as `\r\n`; the PTY's icrnl then turned the `\r` into a SECOND
    // newline, double-spacing every pasted line. Collapsing `\r\n`,
    // lone `\r`, and lone `\n` all to one `\r` (which the line
    // discipline maps to `\n` for cooked-mode apps, and editors handle
    // as a line break under bracketed paste) fixes it for every source.
    final normalized = clean.replaceAll(RegExp(r'\r\n|\r|\n'), '\r');
    // (Typed again into another terminal it is a paste there as well, with
    // or without its brackets as that one's program asked.)
    _emit(
      _bracketedPasteMode ? _emitter.bracketedPaste(normalized) : normalized,
      TerminalOutputOrigin.typed,
      TypedPaste(clean),
    );
  }

  /// [text] as a paste may type it: every control character taken out but a
  /// tab and a line break (C0, DEL and C1), as hardened terminals do. A paste
  /// typed them as they were: ESC above all, with which pasted text closed
  /// the brackets of a bracketed paste (its end marker rebuilt from its own
  /// pieces) and had the rest run as if typed, Enter and all; and Ctrl+C,
  /// Ctrl+Z and the rest acted on the program (found 16 October 2026 in a
  /// security review).
  static String pasteable(String text) => text.replaceAll(_unpasteable, '');

  static final _unpasteable = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]');

  /// Whether [text], committed at once by a keyboard, is a paste and no
  /// typing: several characters with a control character among them (C0, DEL
  /// or C1; a tab and a line break are control characters too), as a phone
  /// keyboard's clipboard chip or clipboard history commits them. Nobody types
  /// that, and sent as typing it skipped every rule a paste goes by: it ended
  /// a bracketed paste, and its line breaks ran. Line ends alone are Enter.
  static bool isCommittedPaste(String text) =>
      text.length > 1 && _controlCharacter.hasMatch(text) && text.trim().isNotEmpty;

  static final _controlCharacter = RegExp(r'[\x00-\x1F\x7F-\x9F]');

  // Handle a mouse event and return true if it was handled.
  bool mouseInput(
    TerminalMouseButton button,
    TerminalMouseButtonState buttonState,
    CellOffset position,
  ) {
    final output = mouseHandler?.call(TerminalMouseEvent(
      button: button,
      buttonState: buttonState,
      position: position,
      state: this,
      platform: platform,
    ));
    if (output != null) {
      _emit(output, TerminalOutputOrigin.mouse);
      return true;
    }
    return false;
  }

  /// A move of the mouse to [position], reported to the program where it
  /// asked for moves: with [button] held where it asked for button events
  /// (mode 1002, a drag) or for every move (1003), with no button (null)
  /// only where it asked for every move. True when it was reported.
  /// (ZestSSH: only presses and releases were, so a drag in tmux, vim or
  /// htop never reached them.)
  bool mouseMotion(CellOffset position, {TerminalMouseButton? button}) {
    final reported = switch (_mouseMode) {
      MouseMode.upDownScrollDrag => button != null,
      MouseMode.upDownScrollMove => true,
      MouseMode.none || MouseMode.clickOnly || MouseMode.upDownScroll => false,
    };
    if (!reported) return false;
    _emit(MouseReporter.reportMotion(button, position, _mouseReportMode), TerminalOutputOrigin.mouse);
    return true;
  }

  /// Resize the terminal screen. [newWidth] and [newHeight] should be greater
  /// than 0. Text reflow is currently not implemented and will be avaliable in
  /// the future.
  @override
  void resize(
    int newWidth,
    int newHeight, [
    int? pixelWidth,
    int? pixelHeight,
  ]) {
    newWidth = max(newWidth, 1);
    newHeight = max(newHeight, 1);

    onResize?.call(newWidth, newHeight, pixelWidth ?? 0, pixelHeight ?? 0);

    //we need to resize both buffers so that they are ready when we switch between them
    _altBuffer.resize(_viewWidth, _viewHeight, newWidth, newHeight);
    _mainBuffer.resize(_viewWidth, _viewHeight, newWidth, newHeight);

    _viewWidth = newWidth;
    _viewHeight = newHeight;

    if (buffer == _altBuffer) {
      buffer.clearScrollback();
    }

    _altBuffer.resetVerticalMargins();
    _mainBuffer.resetVerticalMargins();
  }

  @override
  String toString() {
    return 'Terminal(#$hashCode, $_viewWidth x $_viewHeight, ${_buffer.height} lines)';
  }

  /* Handlers */

  @override
  void writeChar(int char) {
    _precedingCodepoint = char;
    _buffer.writeChar(char);
  }

  /* SBC */

  @override
  void bell() {
    onBell?.call();
  }

  @override
  void backspaceReturn() {
    _buffer.moveCursorX(-1);
  }

  @override
  void tab() {
    final nextStop = _tabStops.find(_buffer.cursorX + 1, _viewWidth);

    if (nextStop != null) {
      _buffer.setCursorX(nextStop);
    } else {
      _buffer.setCursorX(_viewWidth);
      _buffer.cursorGoForward(); // Enter pending-wrap state
    }
  }

  @override
  void lineFeed() {
    _buffer.lineFeed();
  }

  @override
  void carriageReturn() {
    _buffer.setCursorX(0);
  }

  @override
  void shiftOut() {
    _buffer.charset.use(1);
  }

  @override
  void shiftIn() {
    _buffer.charset.use(0);
  }

  @override
  void unknownSBC(int char) {
    // no-op
  }

  /* ANSI sequence */

  @override
  void saveCursor() {
    _buffer.saveCursor();
  }

  @override
  void restoreCursor() {
    _buffer.restoreCursor();
  }

  @override
  void index() {
    _buffer.index();
  }

  @override
  void nextLine() {
    _buffer.index();
    _buffer.setCursorX(0);
  }

  @override
  void setTapStop() {
    _tabStops.isSetAt(_buffer.cursorX);
  }

  @override
  void reverseIndex() {
    _buffer.reverseIndex();
  }

  @override
  void designateCharset(int charset, int name) {
    _buffer.charset.designate(charset, name);
  }

  @override
  void unkownEscape(int char) {
    // no-op
  }

  /// `ESC c`: everything as when the terminal was new. The first screen is
  /// the one shown, both are empty and nothing is kept above them, every
  /// mode is as at the start, the pen is plain, tab stops are every eight
  /// columns. The size and the title stay.
  ///
  /// It was not known: `reset`, which people type when a program has left
  /// the terminal in a state (letters shown as lines after a binary file was
  /// printed, a hidden cursor, a screen that no longer scrolls), did nothing.
  @override
  void fullReset() {
    if (_buffer != _mainBuffer) _buffer.leave();
    _buffer = _mainBuffer;
    _mainBuffer.reset();
    _altBuffer.reset();
    _tabStops.reset();
    _precedingCodepoint = 0;
    _resetModes();
    _reverseDisplayMode = false;
    _lineFeedMode = false;
    _mouseMode = MouseMode.none;
    _mouseReportMode = MouseReportMode.normal;
    _reportFocusMode = false;
    _altBufferMouseScrollMode = false;
    _bracketedPasteMode = false;
    _cursorBlinkMode = false;
  }

  /// `ESC [ ! p`: the modes a program sets while it draws are as when the
  /// terminal was new, on both screens. What is on the screens stays, and
  /// so do the screen that is shown, the mouse and paste modes.
  @override
  void softReset() {
    _mainBuffer.resetState();
    _altBuffer.resetState();
    _resetModes();
  }

  void _resetModes() {
    _cursorStyle.reset();
    _insertMode = false;
    _originMode = false;
    _autoWrapMode = true;
    _cursorVisibleMode = true;
    _cursorKeysMode = false;
    _appKeypadMode = false;
  }

  /* CSI */

  @override
  void repeatPreviousCharacter(int count) {
    if (_precedingCodepoint == 0) {
      return;
    }

    // Clamp REP: a hostile server can send `CSI <huge>b` (the count is an
    // unbounded decimal), and an unbounded loop here freezes the UI isolate.
    // xterm.js caps REP at the columns remaining on the line; a couple of
    // screen-widths is a safe upper bound that never truncates legitimate use.
    final clamped = count.clamp(0, _viewWidth * 2);
    for (var i = 0; i < clamped; i++) {
      _buffer.writeChar(_precedingCodepoint);
    }
  }

  @override
  void setCursor(int x, int y) {
    _buffer.setCursor(x, y);
  }

  @override
  void setCursorX(int x) {
    _buffer.setCursorX(x);
  }

  @override
  void setCursorY(int y) {
    _buffer.setCursorY(y);
  }

  @override
  void moveCursorX(int offset) {
    _buffer.moveCursorX(offset);
  }

  @override
  void moveCursorY(int n) {
    _buffer.moveCursorY(n);
  }

  @override
  void clearTabStopUnderCursor() {
    _tabStops.clearAt(_buffer.cursorX);
  }

  @override
  void clearAllTabStops() {
    _tabStops.clearAll();
  }

  @override
  void sendPrimaryDeviceAttributes() {
    if (!respondToQueries) return;
    _emit(_emitter.primaryDeviceAttributes(), TerminalOutputOrigin.reply);
  }

  @override
  void sendSecondaryDeviceAttributes() {
    if (!respondToQueries) return;
    _emit(_emitter.secondaryDeviceAttributes(), TerminalOutputOrigin.reply);
  }

  @override
  void sendTertiaryDeviceAttributes() {
    if (!respondToQueries) return;
    _emit(_emitter.tertiaryDeviceAttributes(), TerminalOutputOrigin.reply);
  }

  @override
  void sendOperatingStatus() {
    if (!respondToQueries) return;
    _emit(_emitter.operatingStatus(), TerminalOutputOrigin.reply);
  }

  @override
  void sendCursorPosition({bool extended = false}) {
    if (!respondToQueries) return;
    // Counted from 1, the way the cursor is set: a program that put it at
    // row 5, column 10 is told 5;10. (It used to be told 4;9, so a program
    // that asks where the cursor is drew one row up and one column left, and
    // one that asks for the corner to learn the size got a screen one row
    // and one column too small.) While rows are counted from the top margin
    // (origin mode), so is the answer. After a full line the cursor waits
    // past the last column: the buffer says the last column for it.
    final row = _buffer.cursorY - (_originMode ? _buffer.marginTop : 0) + 1;
    final column = _buffer.cursorX + 1;
    _emit(_emitter.cursorPosition(row, column, extended: extended), TerminalOutputOrigin.reply);
  }

  @override
  void setMargins(int top, [int? bottom]) {
    _buffer.setVerticalMargins(top, bottom ?? viewHeight - 1);
  }

  @override
  void cursorNextLine(int amount) {
    _buffer.moveCursorY(amount);
    _buffer.setCursorX(0);
  }

  @override
  void cursorPrecedingLine(int amount) {
    _buffer.moveCursorY(-amount);
    _buffer.setCursorX(0);
  }

  @override
  void eraseDisplayBelow() {
    _buffer.eraseDisplayFromCursor();
  }

  @override
  void eraseDisplayAbove() {
    _buffer.eraseDisplayToCursor();
  }

  @override
  void eraseDisplay() {
    _buffer.eraseDisplay();
  }

  @override
  void eraseScrollbackOnly() {
    _buffer.clearScrollback();
  }

  @override
  void eraseLineRight() {
    _buffer.eraseLineFromCursor();
  }

  @override
  void eraseLineLeft() {
    _buffer.eraseLineToCursor();
  }

  @override
  void eraseLine() {
    _buffer.eraseLine();
  }

  @override
  void insertLines(int amount) {
    _buffer.insertLines(amount);
  }

  @override
  void deleteLines(int amount) {
    _buffer.deleteLines(amount);
  }

  @override
  void deleteChars(int amount) {
    _buffer.deleteChars(amount);
  }

  @override
  void scrollUp(int amount) {
    _buffer.scrollUp(amount);
  }

  @override
  void scrollDown(int amount) {
    _buffer.scrollDown(amount);
  }

  @override
  void eraseChars(int amount) {
    _buffer.eraseChars(amount);
  }

  @override
  void insertBlankChars(int amount) {
    _buffer.insertBlankChars(amount);
  }

  @override
  void sendSize() {
    if (!respondToQueries) return;
    _emit(_emitter.size(viewHeight, viewWidth), TerminalOutputOrigin.reply);
  }

  @override
  void unknownCSI(int finalByte) {
    // no-op
  }

  /* Modes */

  @override
  void setInsertMode(bool enabled) {
    _insertMode = enabled;
  }

  @override
  void setLineFeedMode(bool enabled) {
    _lineFeedMode = enabled;
  }

  @override
  void setUnknownMode(int mode, bool enabled) {
    // no-op
  }

  /* DEC Private modes */

  @override
  void setCursorKeysMode(bool enabled) {
    _cursorKeysMode = enabled;
  }

  @override
  void setReverseDisplayMode(bool enabled) {
    _reverseDisplayMode = enabled;
  }

  @override
  void setOriginMode(bool enabled) {
    _originMode = enabled;
  }

  @override
  void setColumnMode(bool enabled) {
    // no-op
  }

  @override
  void setAutoWrapMode(bool enabled) {
    _autoWrapMode = enabled;
  }

  @override
  void setMouseMode(MouseMode mode) {
    _mouseMode = mode;
  }

  @override
  void setCursorBlinkMode(bool enabled) {
    _cursorBlinkMode = enabled;
  }

  @override
  void setCursorVisibleMode(bool enabled) {
    _cursorVisibleMode = enabled;
  }

  @override
  void useAltBuffer() {
    if (_buffer != _altBuffer) _buffer.leave();
    _buffer = _altBuffer;
  }

  @override
  void useMainBuffer() {
    if (_buffer != _mainBuffer) _buffer.leave();
    _buffer = _mainBuffer;
  }

  @override
  void clearAltBuffer() {
    _altBuffer.clear();
  }

  @override
  void setAppKeypadMode(bool enabled) {
    _appKeypadMode = enabled;
  }

  @override
  void setReportFocusMode(bool enabled) {
    _reportFocusMode = enabled;
  }

  @override
  void setMouseReportMode(MouseReportMode mode) {
    _mouseReportMode = mode;
  }

  @override
  void setAltBufferMouseScrollMode(bool enabled) {
    _altBufferMouseScrollMode = enabled;
  }

  @override
  void setBracketedPasteMode(bool enabled) {
    _bracketedPasteMode = enabled;
  }

  @override
  void setUnknownDecMode(int mode, bool enabled) {
    // no-op
  }

  /* Select Graphic Rendition (SGR) */

  @override
  void resetCursorStyle() {
    _cursorStyle.reset();
  }

  @override
  void setCursorBold() {
    _cursorStyle.setBold();
  }

  @override
  void setCursorFaint() {
    _cursorStyle.setFaint();
  }

  @override
  void setCursorItalic() {
    _cursorStyle.setItalic();
  }

  @override
  void setCursorUnderline() {
    _cursorStyle.setUnderline();
  }

  @override
  void setCursorBlink() {
    _cursorStyle.setBlink();
  }

  @override
  void setCursorInverse() {
    _cursorStyle.setInverse();
  }

  @override
  void setCursorInvisible() {
    _cursorStyle.setInvisible();
  }

  @override
  void setCursorStrikethrough() {
    _cursorStyle.setStrikethrough();
  }

  @override
  void unsetCursorBold() {
    _cursorStyle.unsetBold();
  }

  @override
  void unsetCursorFaint() {
    _cursorStyle.unsetFaint();
  }

  @override
  void unsetCursorItalic() {
    _cursorStyle.unsetItalic();
  }

  @override
  void unsetCursorUnderline() {
    _cursorStyle.unsetUnderline();
  }

  @override
  void unsetCursorBlink() {
    _cursorStyle.unsetBlink();
  }

  @override
  void unsetCursorInverse() {
    _cursorStyle.unsetInverse();
  }

  @override
  void unsetCursorInvisible() {
    _cursorStyle.unsetInvisible();
  }

  @override
  void unsetCursorStrikethrough() {
    _cursorStyle.unsetStrikethrough();
  }

  @override
  void setForegroundColor16(int color) {
    _cursorStyle.setForegroundColor16(color);
  }

  @override
  void setForegroundColor256(int index) {
    _cursorStyle.setForegroundColor256(index);
  }

  @override
  void setForegroundColorRgb(int r, int g, int b) {
    _cursorStyle.setForegroundColorRgb(r, g, b);
  }

  @override
  void resetForeground() {
    _cursorStyle.resetForegroundColor();
  }

  @override
  void setBackgroundColor16(int color) {
    _cursorStyle.setBackgroundColor16(color);
  }

  @override
  void setBackgroundColor256(int index) {
    _cursorStyle.setBackgroundColor256(index);
  }

  @override
  void setBackgroundColorRgb(int r, int g, int b) {
    _cursorStyle.setBackgroundColorRgb(r, g, b);
  }

  @override
  void resetBackground() {
    _cursorStyle.resetBackgroundColor();
  }

  @override
  void unsupportedStyle(int param) {
    // no-op
  }

  /* OSC */

  @override
  void setTitle(String name) {
    onTitleChange?.call(name);
  }

  @override
  void setIconName(String name) {
    onIconChange?.call(name);
  }

  @override
  void unknownOSC(String ps, List<String> pt) {
    onPrivateOSC?.call(ps, pt);
  }
}

/// Where something a terminal sends to its host comes from. [Terminal.onOutput]
/// is given all of it; while it is called, [Terminal.outputOrigin] says which.
enum TerminalOutputOrigin {
  /// What a person typed or pasted, or had typed for them: keys, text, a
  /// paste.
  typed,

  /// A report of the mouse, to a program that asked for it.
  mouse,

  /// The terminal's own answer to something the program asked: where the
  /// cursor is, what kind of terminal this is, how large it is. It belongs
  /// to the one program that asked, and to nobody else.
  reply,
}

/// What was typed into a terminal, kept as what the person did and not as
/// the bytes one terminal made of it: [typeInto] types the same into another
/// terminal, which sends it the way ITS program asked (an arrow key in
/// application mode or not, a paste with its brackets or without).
sealed class TerminalTyped {
  const TerminalTyped();

  /// Types this into [terminal]. False when that terminal has nothing to
  /// send for it (a key it does not know).
  bool typeInto(Terminal terminal);
}

/// A key: an arrow, Enter, a function key, with the modifiers held.
class TypedKey extends TerminalTyped {
  const TypedKey(this.key, {this.shift = false, this.alt = false, this.ctrl = false, this.altIsMeta, this.character});

  final TerminalKey key;
  final bool shift;
  final bool alt;
  final bool ctrl;

  /// Whether Alt was Meta where it was typed, and the character the key
  /// typed there ([Terminal.keyInput]): typed again, Alt+b is ESC b there
  /// too.
  final bool? altIsMeta;
  final String? character;

  @override
  bool typeInto(Terminal terminal) =>
      terminal.keyInput(key, shift: shift, alt: alt, ctrl: ctrl, altIsMeta: altIsMeta, character: character);
}

/// A character with Ctrl or Alt held.
class TypedChar extends TerminalTyped {
  const TypedChar(this.charCode, {this.alt = false, this.ctrl = false});

  final int charCode;
  final bool alt;
  final bool ctrl;

  @override
  bool typeInto(Terminal terminal) => terminal.charInput(charCode, alt: alt, ctrl: ctrl);
}

/// Text as it was typed.
class TypedText extends TerminalTyped {
  const TypedText(this.text);

  final String text;

  @override
  bool typeInto(Terminal terminal) {
    terminal.textInput(text);
    return true;
  }
}

/// Text that was pasted.
class TypedPaste extends TerminalTyped {
  const TypedPaste(this.text);

  final String text;

  @override
  bool typeInto(Terminal terminal) {
    terminal.paste(text);
    return true;
  }
}
