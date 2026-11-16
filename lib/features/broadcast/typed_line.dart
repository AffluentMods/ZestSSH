/// A line that is entered in a terminal: [text] as it was typed, and whether
/// the typing alone tells what the line is ([followed]). It does not after
/// Tab, an arrow, the history or any other key that edits the line in a way
/// only the shell knows: then the line is what the screen shows, and [text]
/// is at best a part of it.
typedef EnteredLine = ({String text, bool followed});

/// The line typed into ONE terminal since its last line end, as far as it
/// can be told from what was typed there: by the person, or by a broadcast
/// from another terminal.
///
/// Broadcast asks before a risky command is run on every terminal that types
/// together. The line that Enter runs is the receiving terminal's own, so it
/// is followed per terminal. (It used to be followed per terminal typed
/// INTO, and only while that one broadcast: half a command typed into one
/// pane and the rest into another ran everywhere unasked, an arrow key left
/// its own letters in the line, so that a command typed after one was no
/// longer recognised, and a line someone began before a broadcast started,
/// or after it stopped, was half missing.)
class TypedLine {
  final StringBuffer _text = StringBuffer();
  bool _followed = true;

  /// As much of a line as is kept. One that goes on (a paste without a line
  /// end) is followed no further.
  static const maxLength = 8192;

  /// The line so far.
  String get text => _text.toString();

  /// Whether [text] is the whole line.
  bool get followed => _followed;

  /// Follows [input], typed into the terminal, and returns the lines it
  /// enters, in order.
  List<EnteredLine> feed(String input) {
    final entered = <EnteredLine>[];
    _run(input, entered.add);
    return entered;
  }

  /// The first line [input] would enter were it typed now, or null when it
  /// enters none. Changes nothing.
  EnteredLine? firstEntered(String input) {
    if (!input.contains('\r') && !input.contains('\n')) return null;
    final probe = TypedLine()
      .._text.write(_text)
      .._followed = _followed;
    EnteredLine? first;
    probe._run(input, (line) => first ??= line, stopAtFirst: true);
    return first;
  }

  void _run(String input, void Function(EnteredLine line) onEntered, {bool stopAtFirst = false}) {
    var i = 0;
    while (i < input.length) {
      final c = input.codeUnitAt(i);
      i++;
      if (c == 0x1b) {
        i = _escape(input, i);
      } else if (c == 0x0d || c == 0x0a) {
        onEntered((text: _text.toString(), followed: _followed));
        _text.clear();
        _followed = true;
        if (stopAtFirst) return;
      } else if (c == 0x7f || c == 0x08) {
        // Backspace takes the last character away (at the end of the line:
        // where the cursor is no longer known, so is what it took).
        final s = _text.toString();
        _text.clear();
        if (s.isNotEmpty) _text.write(s.substring(0, s.length - 1));
      } else if (c == 0x15) {
        // Ctrl+U clears the line up to the cursor: all of it, unless the
        // cursor was moved, and then what stands after it is not known.
        _text.clear();
      } else if (c == 0x03) {
        // Ctrl+C gives the line up.
        _text.clear();
        _followed = true;
      } else if (c < 0x20) {
        // Tab completes, Ctrl+A, E, W, K, R and the like edit: only the
        // shell knows what the line is now.
        _followed = false;
      } else if (_text.length < maxLength) {
        _text.writeCharCode(c);
      } else {
        _followed = false;
      }
    }
  }

  /// Passes over the escape sequence that begins before [at] (the ESC is
  /// read) and returns where it ends. An arrow, Home, the history, a key
  /// with Alt: the line is not followed any more. The two marks a paste is
  /// wrapped in change nothing: what is between them is the text itself.
  int _escape(String input, int at) {
    if (at >= input.length) {
      _followed = false;
      return at;
    }
    final kind = input.codeUnitAt(at);
    if (kind == 0x5b) {
      // CSI: parameters, intermediates, one final byte.
      var i = at + 1;
      while (i < input.length) {
        final c = input.codeUnitAt(i);
        // (A sequence never holds a line end or another control character:
        // one that turns up ends it, and is read as itself.)
        if (c < 0x20) break;
        i++;
        if (c >= 0x40 && c <= 0x7e) {
          final sequence = input.substring(at + 1, i);
          if (sequence != '200~' && sequence != '201~') _followed = false;
          return i;
        }
      }
      _followed = false;
      return i;
    }
    _followed = false;
    // SS3 (a key in application mode) is ESC O and one more; anything else
    // is ESC and one character (a key with Alt).
    if (kind == 0x4f && at + 1 < input.length) return at + 2;
    return at + 1;
  }
}
