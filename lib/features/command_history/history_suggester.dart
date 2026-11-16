import 'dart:async';

import 'package:xterm/xterm.dart';
import 'package:zestssh/features/command_history/command_capture.dart';
import 'package:zestssh/features/command_history/history_suggestions.dart';

/// One session's history suggestions (3.0): after each key, the newest
/// history command starting with what is typed is looked up; once the
/// shell's echo is on screen it shows dimmed after the cursor (the
/// terminal's ghost text, never sent); Right arrow sends the rest of it as
/// if typed. The session layer calls [input] before sending a key, [typed]
/// after the key went to the command capture, and [output] after the
/// terminal drew new output.
class HistorySuggester {
  HistorySuggester({required this.lookup, required this.enabled});

  /// The newest history command starting with the text given, or null.
  final Future<String?> Function(String typed) lookup;

  /// Whether suggestions show now (switched on, the screen not recorded).
  final bool Function() enabled;

  ({String typed, String? candidate})? _found;
  var _ticket = 0;

  /// What to send for [data], the key the person pressed: the rest of the
  /// suggestion on screen for Right arrow, [data] itself otherwise. Any key
  /// hides the suggestion until the next lookup.
  String input(String data, Terminal terminal) {
    final ghost = terminal.ghostText;
    terminal.ghostText = null;
    return ghost != null && acceptsSuggestion(data) ? ghost : data;
  }

  /// Looks up a suggestion for what [capture] holds now.
  void typed(CommandCapture? capture, Terminal terminal) {
    _found = null;
    final ticket = ++_ticket;
    if (!enabled() || capture == null || !capture.trusted) return;
    final typed = capture.line;
    if (typed.trim().length < kSuggestMinChars) return;
    unawaited(lookup(typed).then((candidate) {
      if (ticket != _ticket) return; // typed on meanwhile
      _found = (typed: typed, candidate: candidate);
      output(capture, terminal);
    }, onError: (Object _) {}));
  }

  /// Shows the suggestion while it still fits what is typed and the echo is
  /// on screen; hides it otherwise.
  void output(CommandCapture? capture, Terminal terminal) {
    final found = _found;
    if (found == null) return;
    final candidate = found.candidate;
    if (candidate == null || capture == null || capture.line != found.typed || !enabled()) {
      terminal.ghostText = null;
      return;
    }
    final buf = terminal.buffer;
    final show = mayShowSuggestion(
      typed: found.typed,
      trusted: capture.trusted,
      altBuffer: terminal.isUsingAltBuffer,
      beforeCursor: textBeforeCursor(
        cursorY: buf.absoluteCursorY,
        cursorX: buf.cursorX,
        row: (y) => buf.lines[y].toString(),
        rowUpTo: (y, to) => buf.lines[y].getText(0, to),
        isWrapped: (y) => buf.lines[y].isWrapped,
      ),
    );
    terminal.ghostText = show ? suggestionRemainder(typed: found.typed, candidate: candidate) : null;
  }
}
