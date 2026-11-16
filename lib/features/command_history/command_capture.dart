/// Pure, dependency-free core for client-side command-history capture.
///
/// ZestSSH has no shell integration, so we reconstruct the command the user ran
/// by watching the keystrokes they send and confirming, at Enter, that the line
/// was actually echoed back to the screen. Two safety properties fall out of
/// that echo check:
///  * PASSWORDS ARE NEVER RECORDED. A password prompt turns echo off, so the
///    typed characters do not appear on the display line and the entry is
///    dropped.
///  * garbled lines are dropped. Any escape sequence (arrow keys, history
///    recall, bracketed paste) marks the in-progress line untrusted, so a line
///    the user edited in ways we cannot track is never recorded.
///
/// [commandLooksSensitive] additionally flags commands that carry an inline
/// secret in their arguments (e.g. `mysql -psecret`, `export TOKEN=...`), which
/// the echo check alone would not catch because those ARE echoed. The CALLER
/// decides whether to drop them: by default they are dropped, but the user can
/// opt in to keeping secret-bearing commands. The echo check above is never
/// affected by that opt-in, so hidden-prompt passwords stay unrecorded.
library;

/// Commands whose arguments obviously carry a secret. Recorded history is
/// synced, so err on the side of NOT storing these.
final RegExp _inlineSecret = RegExp(
  r'(?:'
  r'--?password[=\s]\S|--?pass[=\s]\S|-p\S|' // password flags (incl. mysql -p)
  r'(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|auth[_-]?token|bearer)\s*[=:]\s*\S|'
  r'Authorization:\s*\S|'
  r'(?:^|[\s/])sshpass(?=\s).*\s-p\s*\S|' // sshpass -p secret
  r'(?:^|\s)login(?=\s).*\s-p\s+\S|' // docker, podman, oc, az, cf login -p secret
  r'(?:^|[\s/])curl(?=\s).*\s(?:-u|--user|-U|--proxy-user)[=\s]*[^\s:]*:\S|' // curl -u user:secret
  r'[a-z][a-z0-9+.-]*://[^\s/:@]*:[^\s/@]+@' // scheme://user:secret@host
  r')',
  caseSensitive: false,
);

/// Whether [command] looks like it carries an inline secret and so must not be
/// recorded into synced history.
bool commandLooksSensitive(String command) => _inlineSecret.hasMatch(command);

/// Reconstructs the FULL logical text of the cursor's line by joining wrapped
/// continuation rows. A terminal row flagged wrapped is a continuation of the
/// row above it, so a command longer than the terminal is wide spans several
/// rows; the echo check needs the whole line, not just the last row (reading
/// only the last row dropped every wrapped command from history).
///
/// [cursorY] is the absolute row of the cursor; [row] returns a row's text and
/// [isWrapped] whether that row continues the one above it. Pure so it can be
/// unit-tested without a real terminal buffer.
String joinLogicalLine(
  int cursorY,
  String Function(int y) row,
  bool Function(int y) isWrapped,
) {
  var start = cursorY;
  while (start > 0 && isWrapped(start)) {
    start--;
  }
  final sb = StringBuffer();
  for (var y = start; y <= cursorY; y++) {
    sb.write(row(y));
  }
  return sb.toString();
}

/// Reconstructs commands from a single session's keystroke stream. Feed raw
/// input via [onInput]; it returns a command when Enter completes a trusted,
/// echoed, non-sensitive line, or null otherwise.
class CommandCapture {
  final StringBuffer _line = StringBuffer();
  bool _untrusted = false;
  String? _lastRecorded;

  /// Process a chunk of raw input the user sent to the shell. [readDisplayLine]
  /// is called lazily at Enter to fetch the terminal's current cursor-line text
  /// (what is on screen) for the echo check.
  String? onInput(String data, String Function() readDisplayLine) =>
      _follow(data, () => _finalize(readDisplayLine));

  /// Input that reached the shell without the person typing it into this
  /// terminal (a broadcast from another one). The line is followed, so that
  /// what is typed here next is read right, but nothing of it is a command
  /// of this terminal's: an Enter in it ends the line and records nothing.
  void onReceived(String data) {
    _follow(data, () {
      _line.clear();
      _untrusted = false;
      return null;
    });
  }

  String? _follow(String data, String? Function() onEnter) {
    String? result;
    for (var i = 0; i < data.length; i++) {
      final c = data.codeUnitAt(i);
      if (c == 0x1b) {
        // Escape sequence (arrows / history / bracketed paste): we can no longer
        // trust our reconstruction of this line.
        _untrusted = true;
        break;
      } else if (c == 0x0d || c == 0x0a) {
        result = onEnter() ?? result;
      } else if (c == 0x7f || c == 0x08) {
        final s = _line.toString();
        _line.clear();
        if (s.isNotEmpty) _line.write(s.substring(0, s.length - 1));
      } else if (c == 0x15 || c == 0x03 || c == 0x1a) {
        // Ctrl+U (kill line) / Ctrl+C / Ctrl+Z: abandon the line.
        _line.clear();
        _untrusted = false;
      } else if (c >= 0x20 && c != 0x7f) {
        _line.write(String.fromCharCode(c));
      }
      // Other control bytes are ignored (they don't change the visible line).
    }
    return result;
  }

  String? _finalize(String Function() readDisplayLine) {
    final cmd = _line.toString().trim();
    final wasUntrusted = _untrusted;
    _line.clear();
    _untrusted = false;
    if (cmd.isEmpty || wasUntrusted) return null;

    // Echo check: a real command sits at the END of the current input line
    // ("user@host:~$ ls -la"). A password prompt line ends with the prompt
    // (": "), never the secret, so it fails this and is dropped.
    final display = readDisplayLine().trimRight();
    if (!display.endsWith(cmd)) return null;

    // Skip an immediate duplicate (holding Enter, or re-running the last line).
    if (cmd == _lastRecorded) return null;
    _lastRecorded = cmd;
    return cmd;
  }

  /// The line typed since the last Enter, as far as it can be followed.
  String get line => _line.toString();

  /// Whether [line] is still what the shell has (no arrow keys, history
  /// recall or pasted escapes since the last Enter).
  bool get trusted => !_untrusted;

  /// Reset all in-progress state (e.g. when the session closes).
  void reset() {
    _line.clear();
    _untrusted = false;
    _lastRecorded = null;
  }
}
