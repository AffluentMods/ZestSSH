import 'package:flutter/painting.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/utils/fuzzy_search.dart';

// Where what was typed is found in a text, marked (the command palette's
// search, 4.0): the place it stands whole, in any case, or
// where it stands whole nowhere, the letters of it a fuzzy search matched, in
// their order. Marked in bold, underlined in the accent: never by colour
// alone. Ranges are of the text's own UTF-16 units.

/// Every place [text] holds [query] whole, in any case, one after another.
List<TextRange> wholeMatches(String text, String query) {
  final q = _lower(query.trim());
  if (q.isEmpty || text.isEmpty) return const [];
  final t = _lower(text);
  final out = <TextRange>[];
  var from = 0;
  while (from <= t.length - q.length) {
    final i = t.indexOf(q, from);
    if (i < 0) break;
    out.add(TextRange(start: i, end: i + q.length));
    from = i + q.length;
  }
  return out;
}

/// The letters of [query] in [text], in their order, each the first after
/// the one before (as [bestFuzzyScore] finds them), in runs. None where not
/// every letter is there.
List<TextRange> fuzzyMatches(String text, String query) {
  final q = _lower(query.trim());
  if (q.isEmpty || text.isEmpty) return const [];
  final t = _lower(text);
  final at = <int>[];
  var j = 0;
  for (var i = 0; i < t.length && j < q.length; i++) {
    if (t[i] == q[j]) {
      at.add(i);
      j++;
    }
  }
  if (j < q.length) return const [];
  final out = <TextRange>[];
  var start = at.first;
  var end = start + 1;
  for (final i in at.skip(1)) {
    if (i == end) {
      end++;
    } else {
      out.add(TextRange(start: start, end: end));
      start = i;
      end = i + 1;
    }
  }
  out.add(TextRange(start: start, end: end));
  return out;
}

/// What to mark in each of [texts] for [query]: every whole match in each
/// text that has one; where none has, the fuzzy match in the one of those
/// marked [TextToMark.fuzzy] that matches best. Empty lists where nothing is
/// marked, one for each text.
List<List<TextRange>> matchesIn(List<TextToMark> texts, String query) {
  if (query.trim().isEmpty) return [for (final _ in texts) const <TextRange>[]];
  final whole = [for (final t in texts) wholeMatches(t.text, query)];
  if (whole.any((w) => w.isNotEmpty)) return whole;
  var best = -1;
  var score = 0.0;
  for (var i = 0; i < texts.length; i++) {
    if (!texts[i].fuzzy || texts[i].text.isEmpty) continue;
    final s = bestFuzzyScore(query.trim(), [texts[i].text]);
    if (s > score) {
      score = s;
      best = i;
    }
  }
  return [
    for (var i = 0; i < texts.length; i++) i == best ? fuzzyMatches(texts[i].text, query) : const <TextRange>[],
  ];
}

/// A text shown, and whether a fuzzy match may be marked in it.
typedef TextToMark = ({String text, bool fuzzy});

/// [text] with [marks] marked ([matchMarkStyle]), in [style].
TextSpan markedText(String text, List<TextRange> marks, {TextStyle? style}) {
  if (marks.isEmpty) return TextSpan(text: text, style: style);
  final mark = matchMarkStyle();
  final children = <TextSpan>[];
  var at = 0;
  for (final m in marks) {
    if (m.start < at || m.end > text.length) continue;
    if (m.start > at) children.add(TextSpan(text: text.substring(at, m.start)));
    children.add(TextSpan(text: text.substring(m.start, m.end), style: mark));
    at = m.end;
  }
  if (at < text.length) children.add(TextSpan(text: text.substring(at)));
  return TextSpan(style: style, children: children);
}

/// How a match is marked: bold, in the strongest text colour, underlined in
/// the accent.
TextStyle matchMarkStyle() => TextStyle(
      fontWeight: FontWeight.w600,
      color: ZestTokens.textPrimary,
      decoration: TextDecoration.underline,
      decorationColor: ZestTokens.brand,
      decorationThickness: 2,
    );

/// [text] in lower case one unit at a time, so its indexes stay [text]'s.
String _lower(String text) {
  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    final l = c.toLowerCase();
    out.write(l.length == 1 ? l : c);
  }
  return out.toString();
}
