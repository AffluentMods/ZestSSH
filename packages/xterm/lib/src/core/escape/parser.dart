import 'package:xterm/src/core/color.dart';
import 'package:xterm/src/core/mouse/mode.dart';
import 'package:xterm/src/core/escape/handler.dart';
import 'package:xterm/src/utils/ascii.dart';
import 'package:xterm/src/utils/byte_consumer.dart';
import 'package:xterm/src/utils/char_code.dart';
import 'package:xterm/src/utils/lookup_table.dart';

/// [EscapeParser] translates control characters and escape sequences into
/// function calls that the terminal can handle.
///
/// Design goals:
///  * Zero object allocation during processing.
///  * No internal state. Same input will always produce same output. (One
///    exception: the end of a sequence given up for its length, still to
///    come in a later chunk, see [_dropping].)
class EscapeParser {
  final EscapeHandler handler;

  EscapeParser(this.handler);

  final _queue = ByteConsumer();

  /// Start of sequence or character being processed. Useful for debugging.
  var tokenBegin = 0;

  /// End of sequence or character being processed. Useful for debugging.
  int get tokenEnd => _queue.totalConsumed;

  /// Carries out [chunk]. A code that cannot be carried out costs that code
  /// and no more: what it threw goes to [onError], and what follows it in the
  /// chunk is carried out as if it had not been there. (What follows used to
  /// wait for the next chunk, and what threw reached whoever wrote the chunk,
  /// which in the app was the timer that draws a session: its screen stopped
  /// for good.)
  void write(
    String chunk, {
    void Function(Object error, StackTrace stack)? onError,
  }) {
    _queue.unrefConsumedBlocks();
    _queue.add(chunk);
    var failures = 0;
    while (true) {
      try {
        _process();
        return;
      } catch (error, stack) {
        onError?.call(error, stack);
        // A code is consumed before it is carried out, so this always moves
        // on. Throwing at every character, it would still take seconds per
        // chunk: past this many, the rest of the chunk is given up.
        if (++failures >= _maxFailuresPerChunk) {
          _queue.reset();
          return;
        }
      }
    }
  }

  static const int _maxFailuresPerChunk = 64;

  /// The largest number a code's number is taken for, as in xterm and VTE.
  /// A number goes on for as many digits as a host sends, and read as it
  /// comes it wrapped around: past 19 digits it could be negative, and a
  /// count below zero threw where a count is taken for what it says.
  static const int _maxParam = 65535;

  /// Largest incomplete escape sequence we will buffer waiting for its
  /// terminator. A real OSC/CSI/DCS sequence (even a clipboard payload) is
  /// far smaller; past this the server is either broken or hostile.
  ///
  /// Without a bound, a sequence that NEVER terminates (`ESC ]` with no
  /// ST) makes every subsequent chunk roll the whole pending buffer back
  /// and re-parse it, which is unbounded memory AND O(n²) CPU: a trivial
  /// remote denial of service from any server the terminal is attached to.
  static const int _maxPendingSequence = 512 * 1024;

  /// The character after ESC of the escape being read (`]`, `[`, `P`, ...).
  int _introducer = 0;

  /// A sequence given up for its length (past [_maxPendingSequence]) whose
  /// end has not come yet: the character after its ESC, or 0 when there is
  /// none. What is left of it is dropped as it comes, up to its end, never
  /// shown: a picture of a megabyte (imgcat, OSC 1337) or an OSC 52 copy of
  /// a large selection, sent in several writes, filled the screen with its
  /// base64 once the part held when the cap was passed had been dropped.
  int _dropping = 0;

  void _process() {
    while (_queue.isNotEmpty) {
      if (_dropping != 0) {
        if (!_dropRest()) return;
        continue;
      }
      tokenBegin = _queue.totalConsumed;
      final char = _queue.consume();

      if (char == Ascii.ESC) {
        final processed = _processEscape();
        if (!processed) {
          final pending = tokenEnd - tokenBegin;
          if (pending > _maxPendingSequence) {
            // Abandon the runaway sequence: its bytes stay consumed (and are
            // dropped) rather than rolled back, so the buffer drains and we
            // resync on the following input instead of re-parsing forever.
            // A sequence is only left unfinished where the chunk ends, so
            // the rest of it comes in the next ones: [_dropRest] drops it.
            handler.unkownEscape(Ascii.ESC);
            _dropping = _introducer;
            continue;
          }
          _queue.rollback(pending);
          return;
        }
      } else {
        _processChar(char);
      }
    }
  }

  /// Drops what is left of the sequence [_dropping] names, up to its end as
  /// that sequence would have ended: a CSI at its last letter, a string for
  /// the terminal (OSC) at BEL, any at the string end (`ESC \`), CAN or SUB.
  /// Another escape ends it too and is carried out, as it is for a string
  /// that lost its end. Returns false when the input ran out first.
  bool _dropRest() {
    final csi = _dropping == Ascii.openBracket;
    final osc = _dropping == Ascii.closeBracket;
    while (_queue.isNotEmpty) {
      final char = _queue.consume();
      if (char == Ascii.ESC) {
        if (_queue.isEmpty) {
          // Whether it is the string end is told by the next chunk.
          _queue.rollback();
          return false;
        }
        if (_queue.consume() != Ascii.backslash) _queue.rollback(2);
      } else if (char != Ascii.CAN &&
          char != Ascii.SUB &&
          !(csi && char >= 0x40 && char <= 0x7e) &&
          !(osc && char == Ascii.BEL)) {
        continue;
      }
      _dropping = 0;
      return true;
    }
    return false;
  }

  void _processChar(int char) {
    if (char > _sbcHandlers.maxIndex) {
      handler.writeChar(char);
      return;
    }

    final sbcHandler = _sbcHandlers[char];
    if (sbcHandler == null) {
      handler.unkownEscape(char);
      return;
    }

    sbcHandler();
  }

  /// Processes a sequence of characters that starts with an escape character.
  /// Returns [true] if the sequence was processed, [false] if it was not.
  bool _processEscape() {
    if (_queue.isEmpty) return false;

    final escapeChar = _queue.consume();
    _introducer = escapeChar;
    final escapeHandler = _escHandlers[escapeChar];

    if (escapeHandler == null) {
      handler.unkownEscape(escapeChar);
      return true;
    }

    return escapeHandler();
  }

  late final _sbcHandlers = FastLookupTable<_SbcHandler>({
    0x07: handler.bell,
    0x08: handler.backspaceReturn,
    0x09: handler.tab,
    0x0a: handler.lineFeed,
    0x0b: handler.lineFeed,
    0x0c: handler.lineFeed,
    0x0d: handler.carriageReturn,
    0x0e: handler.shiftOut,
    0x0f: handler.shiftIn,
  });

  late final _escHandlers = FastLookupTable<_EscHandler>({
    '['.charCode: _escHandleCSI,
    ']'.charCode: _escHandleOSC,
    '7'.charCode: _escHandleSaveCursor,
    '8'.charCode: _escHandleRestoreCursor,
    'D'.charCode: _escHandleIndex,
    'E'.charCode: _escHandleNextLine,
    'H'.charCode: _escHandleTabSet,
    'M'.charCode: _escHandleReverseIndex,
    'P'.charCode: _escHandleDeviceString, // DCS
    'X'.charCode: _escHandleString, // SOS
    '^'.charCode: _escHandleString, // PM
    '_'.charCode: _escHandleString, // APC
    'c'.charCode: _escHandleFullReset, // RIS
    // '#'.charCode: _unsupportedHandler,
    '('.charCode: _escHandleDesignateCharset0, //  SCS - G0
    ')'.charCode: _escHandleDesignateCharset1, //  SCS - G1
    '*'.charCode: _escHandleDesignateCharset2, //  SCS - G2 (VT220)
    '+'.charCode: _escHandleDesignateCharset3, //  SCS - G3 (VT220)
    '>'.charCode: _escHandleResetAppKeypadMode, // DECKPNM: Normal Keypad
    '='.charCode: _escHandleSetAppKeypadMode, // DECKPAM: Application Keypad
  });

  /// `ESC c` Reset to Initial State (RIS): everything as when the terminal
  /// was new. It is what `reset` sends first.
  bool _escHandleFullReset() {
    handler.fullReset();
    return true;
  }

  /// `ESC X`, `ESC ^`, `ESC _` (and `ESC P`, see [_escHandleDeviceString]): a
  /// string for the terminal itself, the application or private use, up to
  /// its end (`ESC \`). Nothing of it is shown, and none is acted on here:
  /// shown, it was text on the screen the program never meant to be there.
  ///
  /// CAN and SUB give the string up. Another escape gives it up too and is
  /// carried out: a string that lost its end must not take the next code
  /// with it. BEL is part of the string, not its end.
  bool _escHandleString() {
    while (true) {
      if (_queue.isEmpty) return false;
      final char = _queue.consume();
      if (char == Ascii.CAN || char == Ascii.SUB) return true;
      if (char == Ascii.ESC) {
        if (_queue.isEmpty) return false;
        if (_queue.consume() != Ascii.backslash) _queue.rollback(2);
        return true;
      }
    }
  }

  /// What tmux writes when it is started in control mode (`tmux -CC`):
  /// `ESC P 1000 p`. It begins a string that lasts as long as tmux runs.
  static const _tmuxControlMarker = [0x31, 0x30, 0x30, 0x30, 0x70];

  /// `ESC P` Device Control String (DCS): a string as in [_escHandleString],
  /// with one exception. After tmux's marker for its control mode the lines
  /// that follow are shown: the app itself takes that mode over before the
  /// bytes reach this parser, so where they do reach it the app has chosen
  /// not to (a session someone watches), and the person should see what the
  /// host says rather than a screen that looks frozen until tmux ends.
  bool _escHandleDeviceString() {
    for (var i = 0; i < _tmuxControlMarker.length; i++) {
      if (_queue.isEmpty) return false;
      if (_queue.consume() != _tmuxControlMarker[i]) {
        // Not the marker: what was looked at is the start of a string.
        _queue.rollback(i + 1);
        return _escHandleString();
      }
    }
    return true;
  }

  /// `ESC 7` Save Cursor (DECSC)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_a7/
  bool _escHandleSaveCursor() {
    handler.saveCursor();
    return true;
  }

  /// `ESC 8` Restore Cursor (DECRC)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_a8/
  bool _escHandleRestoreCursor() {
    handler.restoreCursor();
    return true;
  }

  /// `ESC D` Index (IND)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_cd/
  bool _escHandleIndex() {
    handler.index();
    return true;
  }

  /// `ESC E` Next Line (NEL)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_ce/
  bool _escHandleNextLine() {
    handler.nextLine();
    return true;
  }

  /// `ESC H` Horizontal Tab Set (HTS)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_ch/
  bool _escHandleTabSet() {
    handler.setTapStop();
    return true;
  }

  /// `ESC M` Reverse Index (RI)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_cm/
  bool _escHandleReverseIndex() {
    handler.reverseIndex();
    return true;
  }

  bool _escHandleDesignateCharset0() {
    if (_queue.isEmpty) return false;
    int name = _queue.consume();
    handler.designateCharset(0, name);
    return true;
  }

  bool _escHandleDesignateCharset1() {
    if (_queue.isEmpty) return false;
    int name = _queue.consume();
    handler.designateCharset(1, name);
    return true;
  }

  /// `ESC *` and `ESC +` choose the G2 and G3 character sets (a VT220's,
  /// which some programs send on its terminfo). The set they name is taken
  /// and kept, as for G0 and G1; only a shift to them (SS2, SS3, LS2, LS3)
  /// would show it, and none is carried out. Unknown, the name was shown as
  /// a character (3.4.2 sweep, L12).
  bool _escHandleDesignateCharset2() {
    if (_queue.isEmpty) return false;
    handler.designateCharset(2, _queue.consume());
    return true;
  }

  bool _escHandleDesignateCharset3() {
    if (_queue.isEmpty) return false;
    handler.designateCharset(3, _queue.consume());
    return true;
  }

  /// `ESC >` Reset Application Keypad Mode (DECKPNM)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_x3c_greater_than/
  bool _escHandleSetAppKeypadMode() {
    handler.setAppKeypadMode(true);
    return true;
  }

  /// `ESC =` Set Application Keypad Mode (DECKPAM)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_x3d_equals/
  bool _escHandleResetAppKeypadMode() {
    handler.setAppKeypadMode(false);
    return true;
  }

  bool _escHandleCSI() {
    final consumed = _consumeCsi();
    if (!consumed) return false;

    // A number left out after a colon keeps its place as -1 for a colour
    // (`38:2::255:0:0`). In any other code it is 0, as a number left out is:
    // `ESC [ : P` was a count of -1, which no count can be.
    if (_csi.finalByte != Ascii.m) {
      final params = _csi.params;
      for (var i = 0; i < params.length; i++) {
        if (params[i] < 0) params[i] = 0;
      }
    }

    // A sign in front of the numbers (`?`, `>`, `=`, `<`) or between them
    // and the last letter (a space, `!`, `"`, `$`, ...) makes it another
    // code than the plain one that ends in the same letter. Only a handler
    // that knows such forms gets them: `ESC [ > 4 ; 2 m` sets a keyboard
    // option and is no underline, `ESC [ ? 2 ; 1 ; 0 S` asks about pictures
    // and scrolls nothing.
    final plain = _csi.prefix == null && _csi.intermediate == 0;
    final csiHandler = plain
        ? _csiHandlers[_csi.finalByte]
        : _csiFormHandlers[_csi.finalByte];

    if (csiHandler == null) {
      handler.unknownCSI(_csi.finalByte);
    } else {
      csiHandler();
    }

    return true;
  }

  /// The last parsed [_Csi]. This is a mutable singletion by design to reduce
  /// object allocations.
  final _csi = _Csi(finalByte: 0, params: []);

  /// Parse a CSI from the head of the queue. Return false if the CSI isn't
  /// complete. After a CSI is successfully parsed, [_csi] is updated.
  bool _consumeCsi() {
    if (_queue.isEmpty) {
      return false;
    }

    _csi.params.clear();
    _csi.intermediate = 0;
    _csi.colonMask = 0;

    // A sign in front of the numbers: `CSI ? Ps ...`, `CSI > Ps ...`,
    // `CSI = Ps ...`, `CSI < Ps ...`. (A colon or a semicolon there is no
    // such sign: it parts numbers, the first of which is left out.)
    final prefix = _queue.peek();
    if (prefix >= Ascii.lessThan && prefix <= Ascii.questionMark) {
      _csi.prefix = prefix;
      _queue.consume();
    } else {
      _csi.prefix = null;
    }

    var param = 0;
    // A digit was read in this code. From then on a number that is left
    // out counts as 0; before it, it is passed over.
    var hasParam = false;
    // A digit was read in the number that is being read.
    var digits = false;
    // The number that is being read stands after a colon: it belongs to the
    // number before it (`4:3`, `38:2::255:0:0`).
    var sub = false;

    while (true) {
      // The sequence isn't completed, just ignore it.
      if (_queue.isEmpty) {
        return false;
      }

      final char = _queue.consume();

      if (char == Ascii.semicolon) {
        _closeParam(param, digits, sub, hasParam);
        param = 0;
        digits = false;
        sub = false;
        continue;
      }

      if (char == Ascii.colon) {
        _closeParam(param, digits, sub, hasParam);
        param = 0;
        digits = false;
        sub = true;
        continue;
      }

      if (char >= Ascii.num0 && char <= Ascii.num9) {
        hasParam = true;
        digits = true;
        param = param * 10 + (char - Ascii.num0);
        if (param > _maxParam) param = _maxParam;
        continue;
      }

      if (char >= Ascii.space && char < Ascii.num0) {
        // A sign between the numbers and the last letter. More than one is
        // no code this terminal knows.
        _csi.intermediate = _csi.intermediate == 0 ? char : -1;
        continue;
      }

      if (char == Ascii.ESC || char == Ascii.CAN || char == Ascii.SUB) {
        // The code lost its end. It is given up; an escape that cut it
        // short is carried out (it used to be taken into the code, whose
        // "last letter" was then the next code's first, and the rest of
        // that code was shown as text).
        if (char == Ascii.ESC) _queue.rollback();
        _csi.params.clear();
        _csi.prefix = null;
        _csi.intermediate = 0;
        _csi.finalByte = 0;
        return true;
      }

      if (char > Ascii.NULL && char < Ascii.space) {
        continue;
      }

      if (char >= Ascii.atSign && char <= Ascii.tilde) {
        _closeParam(param, digits, sub, hasParam);

        _csi.finalByte = char;
        return true;
      }
    }
  }

  /// Adds the number that was being read to the code: at `;`, at `:` and
  /// at the last letter. [any] says a digit was read in this code before
  /// (from then on a number that is left out counts as 0), [digits] that
  /// one was read in this number, [sub] that the number stands after a
  /// colon (one that is left out there keeps its place, as -1).
  void _closeParam(int param, bool digits, bool sub, bool any) {
    if (sub) {
      final at = _csi.params.length;
      if (at < 63) _csi.colonMask |= 1 << at;
      _csi.params.add(digits ? param : -1);
    } else if (any) {
      _csi.params.add(param);
    }
  }

  /// The handlers that know a code with a sign in front of its numbers or
  /// between them and its last letter. Each looks at the form it was given
  /// and does nothing for one it does not know.
  late final _csiFormHandlers = FastLookupTable<_CsiHandler>({
    'c'.codeUnitAt(0): _csiHandleSendDeviceAttributes,
    'h'.codeUnitAt(0): _csiHandleMode,
    'l'.codeUnitAt(0): _csiHandleMode,
    'n'.codeUnitAt(0): _csiHandleDeviceStatusReport,
    'p'.codeUnitAt(0): _csiHandleSoftReset,
    'J'.codeUnitAt(0): _csiHandleEraseDisplay,
    'K'.codeUnitAt(0): _csiHandleEraseLine,
  });

  /// `ESC [ ! p` Soft Terminal Reset (DECSTR): the modes as when the
  /// terminal was new, the screen as it is. It is what `tput init` sends,
  /// and `reset` after its full reset.
  void _csiHandleSoftReset() {
    if (_csi.prefix == null &&
        _csi.intermediate == Ascii.exclamationMark &&
        _csi.params.isEmpty) {
      handler.softReset();
    }
  }

  late final _csiHandlers = FastLookupTable<_CsiHandler>({
    // 'a'.codeUnitAt(0): _csiHandleCursorHorizontalRelative,
    'b'.codeUnitAt(0): _csiHandleRepeatPreviousCharacter,
    'c'.codeUnitAt(0): _csiHandleSendDeviceAttributes,
    'd'.codeUnitAt(0): _csiHandleLinePositionAbsolute,
    'f'.codeUnitAt(0): _csiHandleCursorPosition,
    'g'.codeUnitAt(0): _csiHandelClearTabStop,
    'h'.codeUnitAt(0): _csiHandleMode,
    'l'.codeUnitAt(0): _csiHandleMode,
    'm'.codeUnitAt(0): _csiHandleSgr,
    'n'.codeUnitAt(0): _csiHandleDeviceStatusReport,
    'r'.codeUnitAt(0): _csiHandleSetMargins,
    't'.codeUnitAt(0): _csiWindowManipulation,
    'A'.codeUnitAt(0): _csiHandleCursorUp,
    'B'.codeUnitAt(0): _csiHandleCursorDown,
    'C'.codeUnitAt(0): _csiHandleCursorForward,
    'D'.codeUnitAt(0): _csiHandleCursorBackward,
    'E'.codeUnitAt(0): _csiHandleCursorNextLine,
    'F'.codeUnitAt(0): _csiHandleCursorPrecedingLine,
    'G'.codeUnitAt(0): _csiHandleCursorHorizontalAbsolute,
    'H'.codeUnitAt(0): _csiHandleCursorPosition,
    'J'.codeUnitAt(0): _csiHandleEraseDisplay,
    'K'.codeUnitAt(0): _csiHandleEraseLine,
    'L'.codeUnitAt(0): _csiHandleInsertLines,
    'M'.codeUnitAt(0): _csiHandleDeleteLines,
    'P'.codeUnitAt(0): _csiHandleDelete,
    'S'.codeUnitAt(0): _csiHandleScrollUp,
    'T'.codeUnitAt(0): _csiHandleScrollDown,
    'X'.codeUnitAt(0): _csiHandleEraseCharacters,
    '@'.codeUnitAt(0): _csiHandleInsertBlankCharacters,
  });

  /// `ESC [ Ps a` Cursor Horizontal Position Relative (HPR)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sa/
  // void _csiHandleCursorHorizontalRelative() {
  //   if (_csi.params.isEmpty) {
  //     handler.cursorHorizontal(1);
  //   } else {
  //     handler.cursorHorizontal(_csi.params[0]);
  //   }
  // }

  /// `ESC [ Ps b` Repeat Previous Character (REP)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sb/
  void _csiHandleRepeatPreviousCharacter() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.repeatPreviousCharacter(amount);
  }

  /// `ESC [ Ps c` Device Attributes (DA)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sc/
  ///
  /// A question only with no number or with 0, and with nothing in front
  /// (what are you), `>` (which version) or `=` (which unit). Anything else
  /// that ends in `c` is no question and gets no answer. An answer reaches
  /// the host the way typing does, so answering what was not asked types
  /// into whatever program is reading the keyboard there.
  ///
  /// `ESC [ ? Ps c` in particular is how a Linux console is told the shape
  /// of its cursor: with TERM=linux, "hide the cursor" is `ESC [ ? 25 l`
  /// followed by `ESC [ ? 1 c`, and "show it" ends in `ESC [ ? 0 c`. Taking
  /// those for the question typed `ESC [ ? 1 ; 2 c` into every full-screen
  /// program of such a session each time it hid or showed its cursor: a
  /// dialog read the Escape and closed before it could be used.
  void _csiHandleSendDeviceAttributes() {
    final asked = _csi.params.isEmpty ||
        (_csi.params.length == 1 && _csi.params.first == 0);
    if (!asked || _csi.intermediate != 0) return;
    switch (_csi.prefix) {
      case null:
        return handler.sendPrimaryDeviceAttributes();
      case Ascii.greaterThan:
        return handler.sendSecondaryDeviceAttributes();
      case Ascii.equal:
        return handler.sendTertiaryDeviceAttributes();
    }
  }

  /// `ESC [ Ps d` Cursor Vertical Position Absolute (VPA)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sd/
  void _csiHandleLinePositionAbsolute() {
    var y = 1;

    if (_csi.params.isNotEmpty) {
      y = _csi.params[0];
    }

    handler.setCursorY(y - 1);
  }

  /// `ESC [ Ps ; Ps f` Alias: Set Cursor Position
  ///
  /// https://terminalguide.namepad.de/seq/csi_sf/
  void _csiHandleCursorPosition() {
    var row = 1;
    var col = 1;

    if (_csi.params.length == 2) {
      row = _csi.params[0];
      col = _csi.params[1];
    }

    handler.setCursor(col - 1, row - 1);
  }

  /// `ESC [ Ps g` Tab Clear (TBC)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sg/
  void _csiHandelClearTabStop() {
    var cmd = 0;

    if (_csi.params.length == 1) {
      cmd = _csi.params[0];
    }

    switch (cmd) {
      case 0:
        return handler.clearTabStopUnderCursor();
      default:
        return handler.clearAllTabStops();
    }
  }

  /// - `ESC [ [ Pm ] h Set Mode (SM)` https://terminalguide.namepad.de/seq/csi_sm/
  /// - `ESC [ ? [ Pm ] h` Set Mode (?) (SM) https://terminalguide.namepad.de/seq/csi_sh__p/
  /// - `ESC [ [ Pm ] l` Reset Mode (RM) https://terminalguide.namepad.de/seq/csi_rm/
  /// - `ESC [ ? [ Pm ] l` Reset Mode (?) (RM) https://terminalguide.namepad.de/seq/csi_sl__p/
  void _csiHandleMode() {
    final isEnabled = _csi.finalByte == Ascii.h;

    if (_csi.intermediate != 0) return;

    if (_csi.prefix == Ascii.questionMark) {
      for (var mode in _csi.params) {
        _setDecMode(mode, isEnabled);
      }
    } else if (_csi.prefix == null) {
      for (var mode in _csi.params) {
        _setMode(mode, isEnabled);
      }
    }
  }

  /// `ESC [ [ Ps ] m` Select Graphic Rendition (SGR)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sm/
  void _csiHandleSgr() {
    final params = _csi.params;

    if (params.isEmpty) {
      return handler.resetCursorStyle();
    }

    // This is a workaround for a bug in the analyzer.
    // ignore: dead_code
    for (var i = 0; i < _csi.params.length; i++) {
      final param = params[i];
      // A number after a colon belongs to the number before it, which took
      // it if it knows it (a kind of underline, a colour). Left over here,
      // it means nothing to this terminal.
      if (_isSub(i)) continue;
      switch (param) {
        case 0:
          handler.resetCursorStyle();
          continue;
        case 1:
          handler.setCursorBold();
          continue;
        case 2:
          handler.setCursorFaint();
          continue;
        case 3:
          handler.setCursorItalic();
          continue;
        case 4:
          // `4:0` is no underline; any other kind of underline (`4:3` is a
          // curly one) is drawn as an underline.
          if (_isSub(i + 1) && params[i + 1] == 0) {
            handler.unsetCursorUnderline();
          } else {
            handler.setCursorUnderline();
          }
          continue;
        case 5:
          handler.setCursorBlink();
          continue;
        case 7:
          handler.setCursorInverse();
          continue;
        case 8:
          handler.setCursorInvisible();
          continue;
        case 9:
          handler.setCursorStrikethrough();
          continue;

        case 21:
          handler.unsetCursorBold();
          continue;
        case 22:
          handler.unsetCursorFaint();
          continue;
        case 23:
          handler.unsetCursorItalic();
          continue;
        case 24:
          handler.unsetCursorUnderline();
          continue;
        case 25:
          handler.unsetCursorBlink();
          continue;
        case 27:
          handler.unsetCursorInverse();
          continue;
        case 28:
          handler.unsetCursorInvisible();
          continue;
        case 29:
          handler.unsetCursorStrikethrough();
          continue;

        case 30:
          handler.setForegroundColor16(NamedColor.black);
          continue;
        case 31:
          handler.setForegroundColor16(NamedColor.red);
          continue;
        case 32:
          handler.setForegroundColor16(NamedColor.green);
          continue;
        case 33:
          handler.setForegroundColor16(NamedColor.yellow);
          continue;
        case 34:
          handler.setForegroundColor16(NamedColor.blue);
          continue;
        case 35:
          handler.setForegroundColor16(NamedColor.magenta);
          continue;
        case 36:
          handler.setForegroundColor16(NamedColor.cyan);
          continue;
        case 37:
          handler.setForegroundColor16(NamedColor.white);
          continue;
        case 38:
          if (_isSub(i + 1)) {
            final colour = _colonColour(i);
            if (colour >= _rgb) {
              handler.setForegroundColorRgb(
                  (colour >> 16) & 0xff, (colour >> 8) & 0xff, colour & 0xff);
            } else if (colour >= 0) {
              handler.setForegroundColor256(colour);
            }
            continue;
          }
          // A colour that is cut short is no colour, and what stands after
          // it is part of it: nothing more of this code is carried out.
          if (i + 1 >= params.length) return;
          switch (params[i + 1]) {
            case 2:
              if (i + 4 >= params.length) return;
              final r = params[i + 2];
              final g = params[i + 3];
              final b = params[i + 4];
              if (_isByte(r) && _isByte(g) && _isByte(b)) {
                handler.setForegroundColorRgb(r, g, b);
              }
              i += 4;
              break;
            case 5:
              if (i + 2 >= params.length) return;
              final index = params[i + 2];
              if (_isByte(index)) handler.setForegroundColor256(index);
              i += 2;
              break;
          }
          continue;
        case 39:
          handler.resetForeground();
          continue;

        case 40:
          handler.setBackgroundColor16(NamedColor.black);
          continue;
        case 41:
          handler.setBackgroundColor16(NamedColor.red);
          continue;
        case 42:
          handler.setBackgroundColor16(NamedColor.green);
          continue;
        case 43:
          handler.setBackgroundColor16(NamedColor.yellow);
          continue;
        case 44:
          handler.setBackgroundColor16(NamedColor.blue);
          continue;
        case 45:
          handler.setBackgroundColor16(NamedColor.magenta);
          continue;
        case 46:
          handler.setBackgroundColor16(NamedColor.cyan);
          continue;
        case 47:
          handler.setBackgroundColor16(NamedColor.white);
          continue;
        case 48:
          if (_isSub(i + 1)) {
            final colour = _colonColour(i);
            if (colour >= _rgb) {
              handler.setBackgroundColorRgb(
                  (colour >> 16) & 0xff, (colour >> 8) & 0xff, colour & 0xff);
            } else if (colour >= 0) {
              handler.setBackgroundColor256(colour);
            }
            continue;
          }
          if (i + 1 >= params.length) return;
          switch (params[i + 1]) {
            case 2:
              if (i + 4 >= params.length) return;
              final r = params[i + 2];
              final g = params[i + 3];
              final b = params[i + 4];
              if (_isByte(r) && _isByte(g) && _isByte(b)) {
                handler.setBackgroundColorRgb(r, g, b);
              }
              i += 4;
              break;
            case 5:
              if (i + 2 >= params.length) return;
              final index = params[i + 2];
              if (_isByte(index)) handler.setBackgroundColor256(index);
              i += 2;
              break;
          }
          continue;
        case 58:
          // The colour of an underline, written like a colour of the text.
          // Underlines are drawn in the colour of the text here: its
          // numbers are passed over, so they are not taken for codes of
          // their own (the 5 of `58;5;n` for blinking).
          if (_isSub(i + 1)) continue;
          if (i + 1 >= params.length) return;
          switch (params[i + 1]) {
            case 2:
              if (i + 4 >= params.length) return;
              i += 4;
              break;
            case 5:
              if (i + 2 >= params.length) return;
              i += 2;
              break;
          }
          continue;
        case 49:
          handler.resetBackground();
          continue;

        case 90:
          handler.setForegroundColor16(NamedColor.brightBlack);
          continue;
        case 91:
          handler.setForegroundColor16(NamedColor.brightRed);
          continue;
        case 92:
          handler.setForegroundColor16(NamedColor.brightGreen);
          continue;
        case 93:
          handler.setForegroundColor16(NamedColor.brightYellow);
          continue;
        case 94:
          handler.setForegroundColor16(NamedColor.brightBlue);
          continue;
        case 95:
          handler.setForegroundColor16(NamedColor.brightMagenta);
          continue;
        case 96:
          handler.setForegroundColor16(NamedColor.brightCyan);
          continue;
        case 97:
          handler.setForegroundColor16(NamedColor.brightWhite);
          continue;

        case 100:
          handler.setBackgroundColor16(NamedColor.brightBlack);
          continue;
        case 101:
          handler.setBackgroundColor16(NamedColor.brightRed);
          continue;
        case 102:
          handler.setBackgroundColor16(NamedColor.brightGreen);
          continue;
        case 103:
          handler.setBackgroundColor16(NamedColor.brightYellow);
          continue;
        case 104:
          handler.setBackgroundColor16(NamedColor.brightBlue);
          continue;
        case 105:
          handler.setBackgroundColor16(NamedColor.brightMagenta);
          continue;
        case 106:
          handler.setBackgroundColor16(NamedColor.brightCyan);
          continue;
        case 107:
          handler.setBackgroundColor16(NamedColor.brightWhite);
          continue;

        default:
          handler.unsupportedStyle(param);
          continue;
      }
    }
  }

  /// Whether the number at [i] of the code being read stands after a colon.
  bool _isSub(int i) =>
      _csi.colonMask != 0 &&
      i < _csi.params.length &&
      i < 63 &&
      (_csi.colonMask >> i) & 1 == 1;

  /// Whether [n] is a number a colour is made of: one of the 256, or a share
  /// of red, green or blue. Any other is ignored, as the colon form ignores it
  /// ([_colonColour]): `38;5;99999` was kept as the colour of the text, and
  /// drawing a letter in it threw, on every frame.
  static bool _isByte(int n) => n >= 0 && n <= 255;

  /// Added to red, green and blue by [_colonColour], so such a colour can be
  /// told from the number of one of the 256.
  static const _rgb = 0x1000000;

  /// The colour written with colons after the 38 or 48 at [i]: `:5:n` is
  /// one of the 256, `:2:r:g:b` and `:2::r:g:b` (with a place for a colour
  /// space, mostly left empty) are red, green and blue. One of the 256 comes
  /// back as its number, the other as [_rgb] and the three. -1 for anything
  /// else, which is no colour.
  int _colonColour(int i) {
    final params = _csi.params;
    var count = 0;
    while (_isSub(i + 1 + count)) {
      count++;
    }
    final kind = params[i + 1];
    if (kind == 5 && count >= 2) {
      final index = params[i + 2];
      return index >= 0 && index <= 255 ? index : -1;
    }
    if (kind == 2 && count >= 4) {
      final r = params[i + count - 2];
      final g = params[i + count - 1];
      final b = params[i + count];
      if (r < 0 || g < 0 || b < 0 || r > 255 || g > 255 || b > 255) return -1;
      return _rgb | (r << 16) | (g << 8) | b;
    }
    return -1;
  }

  /// `ESC [ Ps n` Device Status Report [Dispatch] (DSR)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sn/
  void _csiHandleDeviceStatusReport() {
    if (_csi.params.length != 1 || _csi.intermediate != 0) return;

    // Two questions, asked with nothing in front: are you all right (5) and
    // where is the cursor (6). The cursor can also be asked for the DEC way,
    // with `?` in front, and is then answered that way. Nothing else that
    // ends in `n` is a question (`ESC [ > Ps n` switches a keyboard option).
    switch (_csi.prefix) {
      case null:
        switch (_csi.params[0]) {
          case 5:
            return handler.sendOperatingStatus();
          case 6:
            return handler.sendCursorPosition();
        }
      case Ascii.questionMark:
        if (_csi.params[0] == 6) {
          return handler.sendCursorPosition(extended: true);
        }
    }
  }

  /// `ESC [ Ps ; Ps r` Set Top and Bottom Margins (DECSTBM)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sr/
  void _csiHandleSetMargins() {
    var top = 1;
    int? bottom;

    if (_csi.params.length > 2) return;

    if (_csi.params.isNotEmpty) {
      top = _csi.params[0];

      if (_csi.params.length == 2) {
        bottom = _csi.params[1] - 1;
      }
    }

    handler.setMargins(top - 1, bottom);
  }

  /// `ESC [ Ps t` Window operations [DISPATCH]
  ///
  /// https://terminalguide.namepad.de/seq/csi_st/
  void _csiWindowManipulation() {
    // The sequence needs at least one parameter.
    if (_csi.params.isEmpty) {
      return;
    }
    // Most the commands in this group are either of the scope of this package,
    // or should be disabled for security risks.
    switch (_csi.params.first) {
      // Window handling is currently not in the scope of the package.
      case 1: // Restore Terminal Window (show window if minimized)
      case 2: // Minimize Terminal Window
      case 3: // Set Terminal Window Position
      case 4: // Set Terminal Window Size in Pixels
      case 5: // Raise Terminal Window
      case 6: // Lower Terminal Window
      case 7: // Refresh/Redraw Terminal Window
        return;
      case 8: // Set Terminal Window Size (in characters)
        // Ignored, as xterm ignores it unless window operations are allowed:
        // the terminal is as large as the pane it is shown in, and the host is
        // told so; a host does not size it. Taken, a size of any number of
        // columns and rows made every line of the scrollback that wide at once,
        // and one line of a host's output stopped the app.
        return;
      // Window handling is currently no in the scope of the package.
      case 9: // Maximize Terminal Window
      case 10: // Alias: Maximize Terminal Window
      case 11: // Report Terminal Window State
      case 13: // Report Terminal Window Position
      case 14: // Report Terminal Window Size in Pixels
      case 15: // Report Screen Size in Pixels
      case 16: // Report Cell Size in Pixels
        return;
      case 18: // Report Terminal Size (in characters)
        handler.sendSize();
        return;
      // Screen handling is currently no in the scope of the package.
      case 19: // Report Screen Size (in characters)
      // Disabled as these can a security risk.
      case 20: // Get Icon Title
      case 21: // Get Terminal Title
      // Not implemented.
      case 22: // Push Terminal Title
      case 23: // Pop Terminal Title
        return;
      // Unknown CSI.
      default:
        return;
    }
  }

  /// `ESC [ Ps A` Cursor Up (CUU)
  ///
  /// https://terminalguide.namepad.de/seq/csi_ca/
  void _csiHandleCursorUp() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.moveCursorY(-amount);
  }

  /// `ESC [ Ps B` Cursor Down (CUD)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cb/
  void _csiHandleCursorDown() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.moveCursorY(amount);
  }

  /// `ESC [ Ps C` Cursor Right (CUF)
  ///
  /// Cursor Right (CUF)
  void _csiHandleCursorForward() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.moveCursorX(amount);
  }

  /// `ESC [ Ps D` Cursor Left (CUB)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cd/
  void _csiHandleCursorBackward() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.moveCursorX(-amount);
  }

  /// `ESC [ Ps E` Cursor Next Line (CNL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_ce/
  void _csiHandleCursorNextLine() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.cursorNextLine(amount);
  }

  /// `ESC [ Ps F` Cursor Previous Line (CPL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cf/
  void _csiHandleCursorPrecedingLine() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.cursorPrecedingLine(amount);
  }

  void _csiHandleCursorHorizontalAbsolute() {
    var x = 1;

    if (_csi.params.isNotEmpty) {
      x = _csi.params[0];
      if (x == 0) x = 1;
    }

    handler.setCursorX(x - 1);
  }

  /// An erase as it is, or with `?` in front: erase what is not protected
  /// (DECSED, DECSEL). Nothing is protected in this terminal, so that is the
  /// same erase.
  bool get _plainOrSelective =>
      _csi.intermediate == 0 &&
      (_csi.prefix == null || _csi.prefix == Ascii.questionMark);

  /// ESC [ Ps J Erase Display [Dispatch] (ED)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cj/
  void _csiHandleEraseDisplay() {
    if (!_plainOrSelective) return;
    var cmd = 0;

    if (_csi.params.length == 1) {
      cmd = _csi.params[0];
    }

    switch (cmd) {
      case 0:
        return handler.eraseDisplayBelow();
      case 1:
        return handler.eraseDisplayAbove();
      case 2:
        return handler.eraseDisplay();
      case 3:
        return handler.eraseScrollbackOnly();
    }
  }

  /// `ESC [ Ps K` Erase Line [Dispatch] (EL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_ck/
  void _csiHandleEraseLine() {
    if (!_plainOrSelective) return;
    var cmd = 0;

    if (_csi.params.length == 1) {
      cmd = _csi.params[0];
    }

    switch (cmd) {
      case 0:
        return handler.eraseLineRight();
      case 1:
        return handler.eraseLineLeft();
      case 2:
        return handler.eraseLine();
    }
  }

  /// `ESC [ Ps L` Insert Line (IL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cl/
  void _csiHandleInsertLines() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.insertLines(amount);
  }

  /// ESC [ Ps M Delete Line (DL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cm/
  void _csiHandleDeleteLines() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.deleteLines(amount);
  }

  /// ESC [ Ps P Delete Character (DCH)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cp/
  void _csiHandleDelete() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.deleteChars(amount);
  }

  /// `ESC [ Ps S` Scroll Up (SU)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cs/
  void _csiHandleScrollUp() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.scrollUp(amount);
  }

  /// `ESC [ Ps T `Scroll Down (SD)
  ///
  /// https://terminalguide.namepad.de/seq/csi_ct_1param/
  void _csiHandleScrollDown() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.scrollDown(amount);
  }

  /// `ESC [ Ps X` Erase Character (ECH)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cx/
  void _csiHandleEraseCharacters() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.eraseChars(amount);
  }

  /// `ESC [ Ps @` Insert Blanks (ICH)
  ///
  /// https://terminalguide.namepad.de/seq/csi_x40_at/
  ///
  /// Inserts amount spaces at current cursor position moving existing cell
  /// contents to the right. The contents of the amount right-most columns in
  /// the scroll region are lost. The cursor position is not changed.
  void _csiHandleInsertBlankCharacters() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.insertBlankChars(amount);
  }

  void _setMode(int mode, bool enabled) {
    switch (mode) {
      case 4:
        return handler.setInsertMode(enabled);
      case 20:
        return handler.setLineFeedMode(enabled);
      default:
        return handler.setUnknownMode(mode, enabled);
    }
  }

  void _setDecMode(int mode, bool enabled) {
    switch (mode) {
      case 1:
        return handler.setCursorKeysMode(enabled);
      case 3:
        return handler.setColumnMode(enabled);
      case 5:
        return handler.setReverseDisplayMode(enabled);
      case 6:
        return handler.setOriginMode(enabled);
      case 7:
        return handler.setAutoWrapMode(enabled);
      case 9:
        return enabled
            ? handler.setMouseMode(MouseMode.clickOnly)
            : handler.setMouseMode(MouseMode.none);
      case 12:
      case 13:
        return handler.setCursorBlinkMode(enabled);
      case 25:
        return handler.setCursorVisibleMode(enabled);
      case 47:
        if (enabled) {
          return handler.useAltBuffer();
        } else {
          return handler.useMainBuffer();
        }
      case 66:
        return handler.setAppKeypadMode(enabled);
      case 1000:
        return enabled
            ? handler.setMouseMode(MouseMode.upDownScroll)
            : handler.setMouseMode(MouseMode.none);
      case 1001:
        return enabled
            ? handler.setMouseMode(MouseMode.upDownScroll)
            : handler.setMouseMode(MouseMode.none);
      case 1002:
        return enabled
            ? handler.setMouseMode(MouseMode.upDownScrollDrag)
            : handler.setMouseMode(MouseMode.none);
      case 1003:
        return enabled
            ? handler.setMouseMode(MouseMode.upDownScrollMove)
            : handler.setMouseMode(MouseMode.none);
      case 1004:
        return handler.setReportFocusMode(enabled);
      case 1005:
        return enabled
            ? handler.setMouseReportMode(MouseReportMode.utf)
            : handler.setMouseReportMode(MouseReportMode.normal);
      case 1006:
        return enabled
            ? handler.setMouseReportMode(MouseReportMode.sgr)
            : handler.setMouseReportMode(MouseReportMode.normal);
      case 1007:
        return handler.setAltBufferMouseScrollMode(enabled);
      case 1015:
        return enabled
            ? handler.setMouseReportMode(MouseReportMode.urxvt)
            : handler.setMouseReportMode(MouseReportMode.normal);
      case 1047:
        if (enabled) {
          handler.useAltBuffer();
        } else {
          handler.clearAltBuffer();
          handler.useMainBuffer();
        }
        return;
      case 1048:
        if (enabled) {
          return handler.saveCursor();
        } else {
          return handler.restoreCursor();
        }
      case 1049:
        if (enabled) {
          handler.saveCursor();
          handler.clearAltBuffer();
          handler.useAltBuffer();
        } else {
          handler.useMainBuffer();
        }
        return;
      case 2004:
        return handler.setBracketedPasteMode(enabled);
      default:
        return handler.setUnknownDecMode(mode, enabled);
    }
  }

  /// Parse a OSC sequence from the queue. Returns true if a sequence was
  /// found and handled.
  bool _escHandleOSC() {
    if (_queue.isEmpty) return false;

    // Two codes of the Linux console begin like a string for the terminal
    // and are none: no end follows them. `ESC ] R` puts the colours back as
    // they were (`reset` sends it there), `ESC ] P` and seven digits sets
    // one. Taken for a string, they swallowed whatever came after them,
    // until something happened to end it: after `reset` on such a session,
    // nothing showed any more. The colours themselves are not changed here.
    final first = _queue.peek();
    if (first == _linuxPaletteReset) {
      _queue.consume();
      return true;
    }
    if (first == _linuxPaletteSet) return _consumeLinuxPalette();

    final consumed = _consumeOsc();
    if (!consumed) {
      return false;
    }

    if (_osc.isEmpty) {
      return true;
    }

    // Common OSCs
    if (_osc.length >= 2) {
      final ps = _osc[0];
      // A title is everything after the first semicolon, with any
      // semicolons of its own.
      final pt = _osc.length == 2 ? _osc[1] : _osc.sublist(1).join(';');

      switch (ps) {
        case '0':
          handler.setTitle(pt);
          handler.setIconName(pt);
          return true;
        case '1':
          handler.setIconName(pt);
          return true;
        case '2':
          handler.setTitle(pt);
          return true;
      }
    }

    // Private extensions
    handler.unknownOSC(_osc[0], _osc.sublist(1));

    return true;
  }

  static const _linuxPaletteReset = 0x52; // R
  static const _linuxPaletteSet = 0x50; // P

  /// `ESC ] P n rr gg bb`: the Linux console's code for one colour, seven
  /// digits and no end. Cut short, the console gives it up at the first
  /// character that is no digit of it, and that character goes with it; a
  /// control character is left to be carried out.
  bool _consumeLinuxPalette() {
    _queue.consume();
    for (var i = 0; i < 7; i++) {
      if (_queue.isEmpty) return false;
      final char = _queue.consume();
      final digit = (char >= Ascii.num0 && char <= Ascii.num9) ||
          (char >= 0x41 && char <= 0x46) ||
          (char >= 0x61 && char <= 0x66);
      if (digit) continue;
      if (char < Ascii.space) _queue.rollback();
      return true;
    }
    return true;
  }

  final _osc = <String>[];

  bool _consumeOsc() {
    _osc.clear();
    final param = StringBuffer();

    while (true) {
      if (_queue.isEmpty) {
        return false;
      }

      final char = _queue.consume();

      // OSC terminates with BEL
      if (char == Ascii.BEL) {
        _osc.add(param.toString());
        return true;
      }

      // CAN and SUB give the string up: nothing of it is carried out.
      if (char == Ascii.CAN || char == Ascii.SUB) {
        _osc.clear();
        return true;
      }

      /// OSC terminates with ST
      if (char == Ascii.ESC) {
        if (_queue.isEmpty) {
          return false;
        }

        if (_queue.consume() == Ascii.backslash) {
          _osc.add(param.toString());
          return true;
        }

        // Another code begins: the string lost its end. It is given up, and
        // that code is carried out (its first two characters used to go
        // with the string, and the rest of it was shown as text).
        _queue.rollback(2);
        _osc.clear();
        return true;
      }

      /// Parse next parameter
      if (char == Ascii.semicolon) {
        _osc.add(param.toString());
        param.clear();
        continue;
      }

      param.writeCharCode(char);
    }
  }
}

class _Csi {
  _Csi({
    required this.params,
    required this.finalByte,
    // required this.intermediates,
  });

  int? prefix;

  List<int> params;

  int finalByte;

  /// The sign between the numbers and the last letter (a space, `!`, `"`,
  /// `$`, ...): 0 when there is none, -1 when there is more than one.
  int intermediate = 0;

  /// Which of [params] stand after a colon (bit n for the nth): they belong
  /// to the number before them.
  int colonMask = 0;

  @override
  String toString() {
    return params.join(';') + String.fromCharCode(finalByte);
  }
}

/// Function that handles a sequence of characters that starts with an escape.
/// Returns [true] if the sequence was processed, [false] if it was not.
typedef _EscHandler = bool Function();

typedef _SbcHandler = void Function();

typedef _CsiHandler = void Function();
