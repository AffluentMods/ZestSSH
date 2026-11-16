import 'package:flutter/services.dart';

/// The editor's nano-style edits, on plain [TextEditingValue]s so they can be
/// tested without a widget. Lines are logical lines (split on '\n'), as in
/// nano and the shell, not the rows word wrap draws.
abstract final class NanoEdits {
  /// Where the line holding [offset] starts.
  static int lineStart(String text, int offset) {
    if (offset <= 0) return 0;
    return text.lastIndexOf('\n', offset - 1) + 1;
  }

  /// Where the line holding [offset] ends (before its '\n').
  static int lineEnd(String text, int offset) {
    final nl = text.indexOf('\n', offset);
    return nl == -1 ? text.length : nl;
  }

  /// Ctrl+A / Ctrl+E: the caret moved to the start or end of its line.
  static TextEditingValue moveToLineEdge(TextEditingValue v,
      {required bool end}) {
    final sel = v.selection;
    if (!sel.isValid) return v;
    final at = sel.extentOffset;
    final to = end ? lineEnd(v.text, at) : lineStart(v.text, at);
    return v.copyWith(selection: TextSelection.collapsed(offset: to));
  }

  /// Ctrl+K: cut the caret's whole line with its line break, or the selection
  /// when there is one. The cut text of a line always ends in '\n', so pasting
  /// it back gives whole lines, as nano does. Nothing to cut returns an empty
  /// string and the value unchanged.
  static ({TextEditingValue value, String cut}) cutLine(TextEditingValue v) {
    final text = v.text;
    final sel = v.selection;
    if (!sel.isValid || text.isEmpty) return (value: v, cut: '');
    if (!sel.isCollapsed) {
      return (
        value: TextEditingValue(
          text: sel.textBefore(text) + sel.textAfter(text),
          selection: TextSelection.collapsed(offset: sel.start),
        ),
        cut: sel.textInside(text),
      );
    }
    final start = lineStart(text, sel.baseOffset);
    final nl = text.indexOf('\n', sel.baseOffset);
    final end = nl == -1 ? text.length : nl + 1;
    if (start == end) return (value: v, cut: '');
    final line = text.substring(start, end);
    return (
      value: TextEditingValue(
        text: text.replaceRange(start, end, ''),
        selection: TextSelection.collapsed(offset: start),
      ),
      cut: line.endsWith('\n') ? line : '$line\n',
    );
  }

  /// Ctrl+U: [pasted] in place of the selection, caret after it.
  static TextEditingValue paste(TextEditingValue v, String pasted) {
    final sel = v.selection;
    if (!sel.isValid || pasted.isEmpty) return v;
    return TextEditingValue(
      text: v.text.replaceRange(sel.start, sel.end, pasted),
      selection: TextSelection.collapsed(offset: sel.start + pasted.length),
    );
  }

  /// Where 1-based [line] starts, clamped to the text's lines.
  static int offsetOfLine(String text, int line) {
    var offset = 0;
    for (var i = 1; i < line; i++) {
      final nl = text.indexOf('\n', offset);
      if (nl == -1) break;
      offset = nl + 1;
    }
    return offset;
  }
}
