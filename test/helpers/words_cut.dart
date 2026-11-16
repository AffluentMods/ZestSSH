import 'dart:math' as math;

import 'package:flutter/rendering.dart';

/// Where a paragraph drawn on screen breaks a line inside a word, which no
/// overflow reports: a column too narrow for its words is drawn a few letters
/// a line, and a word longer than its column loses its last letters to the
/// next line. Each is given as the text around the break, with a bar where
/// it falls ("navigat|eur"). A line may break at a space, after a hyphen or
/// a slash, beside a widget in the sentence (a button after a name),
/// anywhere in Chinese, Japanese and Korean, which break between their
/// characters, and anywhere in an address (a host, an email or an IP
/// address: a run with a dot, an at sign or a colon between two letters or
/// digits, or a placeholder after it: `localhost:<port>`), which has no
/// syllables to break at.
///
/// The paragraph is laid out again from what it was given, as it was, and
/// its breaks read from that. One drawn on a single line is left out, and so
/// is one given no width at all, which is not shown (the closed side of an
/// [AnimatedCrossFade]).
List<String> wordsCut(RenderParagraph paragraph) {
  if (!paragraph.softWrap || paragraph.maxLines == 1) return const [];
  if (paragraph.constraints.maxWidth < 1) return const [];
  final text = paragraph.text.toPlainText(includeSemanticsLabels: false);
  final painter = TextPainter(
    text: paragraph.text,
    textAlign: paragraph.textAlign,
    textDirection: paragraph.textDirection,
    locale: paragraph.locale,
    maxLines: paragraph.maxLines,
    ellipsis: paragraph.overflow == TextOverflow.ellipsis ? _ellipsis : null,
    strutStyle: paragraph.strutStyle,
    textWidthBasis: paragraph.textWidthBasis,
    textHeightBehavior: paragraph.textHeightBehavior,
    textScaler: paragraph.textScaler,
  );
  try {
    if (text.contains(_placeholder)) {
      final dimensions = _placeholders(paragraph);
      if (dimensions == null) return const [];
      painter.setPlaceholderDimensions(dimensions);
    }
    painter.layout(minWidth: paragraph.constraints.minWidth, maxWidth: paragraph.constraints.maxWidth);
    final shown = painter.computeLineMetrics().length;
    final cuts = <String>[];
    var start = 0;
    var line = 0;
    // Each line but the last one shown ends at a break.
    while (start < text.length && line < shown - 1) {
      final range = painter.getLineBoundary(TextPosition(offset: start));
      if (range.end <= start) {
        start++;
        continue;
      }
      final end = range.end;
      if (end >= text.length) break;
      if (!_mayBreak(text.codeUnitAt(end - 1), text.codeUnitAt(end)) && !_inAddress(text, end)) {
        cuts.add('${text.substring(math.max(0, end - 14), end)}|${text.substring(end, math.min(text.length, end + 14))}');
      }
      line++;
      start = end;
    }
    return cuts;
  } finally {
    painter.dispose();
  }
}

/// Where a paragraph drawn on screen is less tall than its lines, which no
/// overflow reports either: a box of a fixed height (a dropdown's field, a
/// button's) gives words that take two lines the height of one, and cuts them
/// at their top and bottom. Given as the words, the height they were given
/// and the height their lines need in their width, or null where they have
/// it. One given no width at all is left out, as [wordsCut] leaves it.
String? cutTopAndBottom(RenderParagraph paragraph) {
  if (!paragraph.hasSize || paragraph.constraints.maxWidth < 1) return null;
  final needs = paragraph.getMinIntrinsicHeight(paragraph.constraints.maxWidth);
  if (needs <= paragraph.size.height + 0.5) return null;
  return '"${paragraph.text.toPlainText(includeSemanticsLabels: false)}" in '
      '${paragraph.size.height.toStringAsFixed(0)} of the ${needs.toStringAsFixed(0)} it needs';
}

/// The sizes of the widgets a paragraph holds, as it laid them out.
List<PlaceholderDimensions>? _placeholders(RenderParagraph paragraph) {
  final spans = <PlaceholderSpan>[];
  paragraph.text.visitChildren((span) {
    if (span is PlaceholderSpan) spans.add(span);
    return true;
  });
  final boxes = <RenderBox>[];
  for (var child = paragraph.firstChild; child != null; child = paragraph.childAfter(child)) {
    boxes.add(child);
  }
  if (boxes.length != spans.length || boxes.any((b) => !b.hasSize)) return null;
  return [
    for (var i = 0; i < spans.length; i++)
      PlaceholderDimensions(
        size: boxes[i].size,
        alignment: spans[i].alignment,
        baseline: spans[i].baseline,
        baselineOffset: spans[i].baseline == null ? null : boxes[i].getDistanceToBaseline(spans[i].baseline!),
      ),
  ];
}

const _placeholder = '￼';
const _ellipsis = '…';

bool _mayBreak(int before, int after) {
  if (_space(before) || _space(after)) return true;
  if (before == _placeholder.codeUnitAt(0) || after == _placeholder.codeUnitAt(0)) return true;
  // After a hyphen, its Unicode kin and a slash.
  if (before == 0x2D || before == 0x2010 || before == 0x2F) return true;
  return _breaksAnywhere(before) || _breaksAnywhere(after);
}

/// Whether the run of characters around [at], from space to space, is an
/// address: a host, an email or an IP address.
bool _inAddress(String text, int at) {
  var start = at;
  var end = at;
  while (start > 0 && !_space(text.codeUnitAt(start - 1))) {
    start--;
  }
  while (end < text.length && !_space(text.codeUnitAt(end))) {
    end++;
  }
  return _address.hasMatch(text.substring(start, end));
}

final _address = RegExp('[A-Za-z0-9][.@:][A-Za-z0-9<]');

bool _space(int c) => c == 0x20 || c == 0x0A || c == 0x09 || c == 0xA0 || c == 0x200B || c == 0x3000;

/// Chinese, Japanese and Korean, with their punctuation and full-width
/// forms.
bool _breaksAnywhere(int c) =>
    (c >= 0x2E80 && c <= 0x9FFF) ||
    (c >= 0xAC00 && c <= 0xD7AF) ||
    (c >= 0xF900 && c <= 0xFAFF) ||
    (c >= 0xFF00 && c <= 0xFFEF);

/// The words of a one-line paragraph cut at its box's edge with nothing to
/// say so (an ellipsis or a fade does), or null.
String? clippedAtEdge(RenderParagraph paragraph) {
  if (paragraph.maxLines != 1 && paragraph.softWrap) return null;
  if (paragraph.overflow == TextOverflow.ellipsis || paragraph.overflow == TextOverflow.fade) return null;
  if (paragraph.constraints.maxWidth < 1) return null;
  final full = paragraph.getMaxIntrinsicWidth(double.infinity);
  if (full <= paragraph.size.width + 0.5) return null;
  return '"${paragraph.text.toPlainText(includeSemanticsLabels: false)}" in ${paragraph.size.width.toStringAsFixed(0)}';
}
