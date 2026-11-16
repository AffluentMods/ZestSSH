/// Turns the byte stream a terminal shows into plain text for a log file:
/// every escape sequence (CSI, OSC, DCS and the other string controls, the
/// two-byte ESC forms) and every control character except newline and tab
/// is dropped, so what remains is what a person would read on screen.
///
/// The filter is a state machine that carries its state ACROSS calls, so a
/// sequence split between two network chunks is still removed whole. It is
/// what PuTTY calls "printable output" logging: full-screen programs (vim,
/// htop) still leave their text, just without the cursor movement that laid
/// it out.
class TerminalTextFilter {
  _State _state = _State.normal;

  /// A bare CR (progress bars redraw a line with `\r`) becomes its own line
  /// so each redraw stays readable; CR LF is one line break.
  bool _pendingCr = false;

  /// Bytes seen inside the current string control. A string that never
  /// terminates (binary junk after `ESC ]`) would otherwise eat the rest of
  /// the session; past this it is abandoned and text resumes.
  int _stringLength = 0;
  static const int maxStringLength = 64 * 1024;

  /// Feed a decoded chunk and get back the printable text it contains
  /// (possibly empty).
  String feed(String chunk) {
    if (chunk.isEmpty) return '';
    final out = StringBuffer();
    for (final rune in chunk.runes) {
      _step(rune, out);
    }
    return out.toString();
  }

  /// Text a caller should emit at the very end (a dangling CR becomes a
  /// line break) and reset for reuse.
  String finish() {
    final tail = _pendingCr ? '\n' : '';
    _pendingCr = false;
    _state = _State.normal;
    _stringLength = 0;
    return tail;
  }

  void _step(int c, StringBuffer out) {
    switch (_state) {
      case _State.normal:
        _normal(c, out);
      case _State.esc:
        _afterEsc(c);
      case _State.escIntermediate:
        // `ESC ( B` and friends: one more byte, then done.
        _state = _State.normal;
      case _State.csi:
        // Parameters and intermediates are 0x20..0x3F; the final byte is
        // 0x40..0x7E. Anything else is a broken sequence: abandon it.
        if (c >= 0x40 && c <= 0x7e) {
          _state = _State.normal;
        } else if (c < 0x20 || c > 0x3f) {
          _state = _State.normal;
          _normal(c, out);
        }
      case _State.string:
        _inString(c);
      case _State.stringEsc:
        // ESC inside a string: `ESC \` ends it; anything else abandons the
        // string and starts a new escape sequence.
        _stringLength = 0;
        if (c == 0x5c) {
          _state = _State.normal;
        } else {
          _state = _State.esc;
          _afterEsc(c);
        }
    }
  }

  void _normal(int c, StringBuffer out) {
    if (c == 0x0d) {
      // Decide when the next character arrives (LF or not).
      if (_pendingCr) out.write('\n');
      _pendingCr = true;
      return;
    }
    if (_pendingCr) {
      _pendingCr = false;
      out.write('\n');
      if (c == 0x0a) return;
    }
    if (c == 0x1b) {
      _state = _State.esc;
      return;
    }
    if (c == 0x0a || c == 0x09) {
      out.writeCharCode(c);
      return;
    }
    // Other C0 controls (BEL, BS, ...) and DEL are dropped.
    if (c < 0x20 || c == 0x7f) return;
    // C1 controls as code points: 0x9B is a one-byte CSI, 0x9D OSC, 0x90
    // DCS, 0x98 / 0x9E / 0x9F the other strings; the rest are dropped.
    if (c >= 0x80 && c <= 0x9f) {
      if (c == 0x9b) {
        _state = _State.csi;
      } else if (c == 0x9d || c == 0x90 || c == 0x98 || c == 0x9e || c == 0x9f) {
        _stringLength = 0;
        _state = _State.string;
      }
      return;
    }
    out.writeCharCode(c);
  }

  void _afterEsc(int c) {
    switch (c) {
      case 0x5b: // [
        _state = _State.csi;
      case 0x5d: // ]  OSC
      case 0x50: // P  DCS
      case 0x58: // X  SOS
      case 0x5e: // ^  PM
      case 0x5f: // _  APC
        _stringLength = 0;
        _state = _State.string;
      case 0x28: // (
      case 0x29: // )
      case 0x2a: // *
      case 0x2b: // +
      case 0x23: // #
      case 0x25: // %
        _state = _State.escIntermediate;
      default:
        // Single-byte ESC sequences (`ESC 7`, `ESC =`, `ESC M`, ...): the
        // byte we just consumed was the whole sequence.
        _state = _State.normal;
    }
  }

  void _inString(int c) {
    if (c == 0x07 || c == 0x9c) {
      // BEL (OSC's usual terminator) or a one-byte ST.
      _state = _State.normal;
      _stringLength = 0;
      return;
    }
    if (c == 0x1b) {
      _state = _State.stringEsc;
      return;
    }
    if (++_stringLength > maxStringLength) {
      _state = _State.normal;
      _stringLength = 0;
    }
  }
}

enum _State { normal, esc, escIntermediate, csi, string, stringEsc }
