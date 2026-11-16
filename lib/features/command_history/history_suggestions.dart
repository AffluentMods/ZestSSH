/// History suggestions (3.0): while someone types a command, the newest
/// command from their history that starts with what they typed is shown
/// dimmed after the cursor, and Right arrow takes it. Pure helpers, so the
/// rules are tested without a terminal.
///
/// A suggestion is only ever drawn on the screen, never sent: nothing reaches
/// the host until the person accepts it. It comes from the same space's
/// history the command capture recorded (an Orchard's sessions from that
/// Orchard's history, never the Tree's), so it can only offer what this
/// person already ran; and like the capture it waits for the shell to echo
/// what was typed, so it never shows at a password prompt.
library;

import 'package:zestssh/utils/command_text.dart';

/// The fewest characters typed before a suggestion shows.
const kSuggestMinChars = 2;

/// What [candidate] adds to [typed], or null when it is no suggestion (it
/// does not start with exactly what was typed, adds nothing, or holds a control
/// character).
///
/// Right arrow types what this gives, as keys, into a line editor: a control
/// character in it acts at once, and needs no Enter. A file named `readme.txt`,
/// then spaces enough to hide the rest, then `;cmd;\x0f` ran `cmd` on Right
/// arrow alone (Ctrl-O in bash). Where it comes from does not matter: a name on
/// the host, a saved host, an imported history.
String? suggestionRemainder({required String typed, required String candidate}) {
  if (!candidate.startsWith(typed) || candidate.length <= typed.length) return null;
  final rest = candidate.substring(typed.length);
  if (!CommandText.mayBeTyped(rest)) return null;
  return rest;
}

/// Whether a suggestion may show for [typed]: enough typed, the typed line
/// still trusted (no arrow keys or pasted escapes since Enter), the terminal
/// not in a full-screen program ([altBuffer]), and the shell's echo in place:
/// the text on screen before the cursor ([beforeCursor], wrapped rows
/// joined) ends with exactly what was typed. A password prompt echoes
/// nothing, so it never matches.
bool mayShowSuggestion({
  required String typed,
  required bool trusted,
  required bool altBuffer,
  required String beforeCursor,
}) =>
    trusted && !altBuffer && typed.trim().length >= kSuggestMinChars && beforeCursor.endsWith(typed);

/// The text before the cursor on its logical line: the rows it wrapped from
/// ([row], whole) and its own row up to [cursorX] ([rowUpTo]).
String textBeforeCursor({
  required int cursorY,
  required int cursorX,
  required String Function(int y) row,
  required String Function(int y, int to) rowUpTo,
  required bool Function(int y) isWrapped,
}) {
  var start = cursorY;
  while (start > 0 && isWrapped(start)) {
    start--;
  }
  final sb = StringBuffer();
  for (var y = start; y < cursorY; y++) {
    sb.write(row(y));
  }
  sb.write(rowUpTo(cursorY, cursorX));
  return sb.toString();
}

/// Whether [input] (what a key sends) accepts a suggestion: Right arrow, in
/// either cursor-key mode.
bool acceptsSuggestion(String input) => input == '\x1b[C' || input == '\x1bOC';
