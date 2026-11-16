/// Calls in Dart source, read past strings (single, double, triple, raw,
/// with their interpolations) and comments, for the tests that look through
/// the app's code for a call made a certain way.
library;

/// Each call in [text] that [start] finds (it must end at the call's opening
/// parenthesis), outside comments and strings: the line it is on and the
/// text between its parentheses.
List<({int line, String args})> callsIn(String text, RegExp start) {
  final noise = _noise(text);
  final found = <({int line, String args})>[];
  for (final m in start.allMatches(text)) {
    if (_inside(noise, m.start)) continue;
    final open = m.end - 1;
    final close = _closing(text, open);
    if (close == null) continue;
    found.add((line: '\n'.allMatches(text.substring(0, m.start)).length + 1, args: text.substring(open + 1, close)));
  }
  return found;
}

/// Each string written in [text] outside comments (single, double, triple or
/// raw), with its interpolations as they are written: the line it starts on
/// and what is between its quotes.
List<({int line, String text})> stringsIn(String text) {
  final found = <({int line, String text})>[];
  var line = 1;
  var counted = 0;
  var i = 0;
  while (i < text.length) {
    final skip = _skipNoise(text, i);
    if (skip == null) {
      i++;
      continue;
    }
    if (!text.startsWith('//', i) && !text.startsWith('/*', i)) {
      line += '\n'.allMatches(text.substring(counted, i)).length;
      counted = i;
      final open = text[i] == 'r' ? i + 1 : i;
      final quotes = text.startsWith(text[open] * 3, open) ? 3 : 1;
      final start = open + quotes;
      final end = skip - quotes;
      found.add((line: line, text: end > start ? text.substring(start, end) : ''));
    }
    i = skip;
  }
  return found;
}

/// The arguments in [args] (what [callsIn] gives as a call's), split at the
/// commas outside brackets, strings and comments, each trimmed.
List<String> argsOf(String args) {
  final out = <String>[];
  var depth = 0;
  var start = 0;
  var i = 0;
  while (i < args.length) {
    final skip = _skipNoise(args, i);
    if (skip != null) {
      i = skip;
      continue;
    }
    final c = args[i];
    if ('([{'.contains(c)) {
      depth++;
    } else if (')]}'.contains(c)) {
      depth--;
    } else if (depth == 0 && c == ',') {
      out.add(args.substring(start, i).trim());
      start = i + 1;
    }
    i++;
  }
  final last = args.substring(start).trim();
  if (last.isNotEmpty) out.add(last);
  return out;
}

/// The expression of the named argument [name] at the top level of [args],
/// or null.
String? namedArg(String args, String name) {
  var depth = 0;
  int? start;
  var i = 0;
  while (i < args.length) {
    final skip = _skipNoise(args, i);
    if (skip != null) {
      i = skip;
      continue;
    }
    final c = args[i];
    if ('([{'.contains(c)) {
      depth++;
    } else if (')]}'.contains(c)) {
      depth--;
    } else if (depth == 0 && start == null && args.startsWith('$name:', i) && (i == 0 || !_word(args[i - 1]))) {
      start = i + name.length + 1;
    } else if (depth == 0 && c == ',' && start != null) {
      return args.substring(start, i).trim();
    }
    i++;
  }
  return start == null ? null : args.substring(start).trim();
}

bool _word(String c) => RegExp(r'[A-Za-z0-9_$]').hasMatch(c);

/// The index of the bracket that closes the one at [open], or null.
int? _closing(String text, int open) {
  var depth = 0;
  var i = open;
  while (i < text.length) {
    final skip = _skipNoise(text, i);
    if (skip != null) {
      i = skip;
      continue;
    }
    final c = text[i];
    if ('([{'.contains(c)) {
      depth++;
    } else if (')]}'.contains(c)) {
      depth--;
      if (depth == 0) return i;
    }
    i++;
  }
  return null;
}

/// The index after the comment or string at [i], or null where there is
/// none.
int? _skipNoise(String text, int i) {
  if (text.startsWith('//', i)) {
    final end = text.indexOf('\n', i);
    return end < 0 ? text.length : end + 1;
  }
  if (text.startsWith('/*', i)) {
    final end = text.indexOf('*/', i + 2);
    return end < 0 ? text.length : end + 2;
  }
  final c = text[i];
  if (c == "'" || c == '"') return _skipString(text, i);
  if (c == 'r' && i + 1 < text.length && (text[i + 1] == "'" || text[i + 1] == '"') && (i == 0 || !_word(text[i - 1]))) {
    return _skipString(text, i);
  }
  return null;
}

int _skipString(String text, int i) {
  final raw = text[i] == 'r';
  if (raw) i++;
  final q = text[i];
  final triple = text.startsWith(q * 3, i);
  final end = triple ? q * 3 : q;
  i += end.length;
  while (i < text.length) {
    if (!raw && text[i] == r'\') {
      i += 2;
      continue;
    }
    if (!raw && text.startsWith(r'${', i)) {
      i = (_closing(text, i + 1) ?? text.length - 1) + 1;
      continue;
    }
    if (text.startsWith(end, i)) return i + end.length;
    if (!triple && text[i] == '\n') return i + 1;
    i++;
  }
  return i;
}

List<(int, int)> _noise(String text) {
  final spans = <(int, int)>[];
  var i = 0;
  while (i < text.length) {
    final skip = _skipNoise(text, i);
    if (skip != null) {
      spans.add((i, skip));
      i = skip;
    } else {
      i++;
    }
  }
  return spans;
}

bool _inside(List<(int, int)> spans, int pos) {
  var lo = 0;
  var hi = spans.length;
  while (lo < hi) {
    final mid = (lo + hi) ~/ 2;
    if (spans[mid].$2 <= pos) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo < spans.length && spans[lo].$1 <= pos && pos < spans[lo].$2;
}
