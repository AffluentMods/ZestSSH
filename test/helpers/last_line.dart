import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// How the paragraph [finder] holds (a Text or a RichText) is drawn: its
/// lines, and the words on its last one; with [firstParagraph], of the words
/// before its first line break only (what a command under them leaves). Only
/// true with the app's own fonts loaded (loadShotFonts): the test font draws
/// every letter as a square.
({int lines, String lastLine}) linesOf(WidgetTester tester, Finder finder, {bool firstParagraph = false}) {
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  final text = paragraph.text.toPlainText(includeSemanticsLabels: false);
  final cut = firstParagraph ? text.indexOf('\n') : -1;
  final end = (cut < 0 ? text : text.substring(0, cut)).trimRight().length;
  final boxes = paragraph.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: end));
  final tops = {for (final b in boxes) b.top.round()};
  final lastTop = tops.reduce(math.max);
  final firstTop = tops.reduce(math.min);
  final first = boxes.where((b) => b.top.round() == firstTop);
  // The app's font, not the test font's squares (one letter as wide as the
  // font is high): a fallback measures nothing real, so it fails here.
  final firstStart = paragraph.getPositionForOffset(Offset(first.map((b) => b.left).reduce(math.min) + 0.5, firstTop + 2.0));
  final firstEnd = paragraph.getPositionForOffset(Offset(first.map((b) => b.right).reduce(math.max) - 0.5, firstTop + 2.0));
  final firstWidth = first.map((b) => b.right).reduce(math.max) - first.map((b) => b.left).reduce(math.min);
  final fontSize = paragraph.text.style?.fontSize ?? 14;
  final letters = math.max(1, firstEnd.offset - firstStart.offset);
  expect(firstWidth / letters, lessThan(fontSize * 0.75),
      reason: 'measured in the test font: load the app\'s fonts and give the app\'s theme');
  final last = boxes.where((b) => b.top.round() == lastTop);
  final start = paragraph.getPositionForOffset(Offset(last.map((b) => b.left).reduce(math.min) + 0.5, lastTop + 2.0));
  return (lines: tops.length, lastLine: text.substring(start.offset, end));
}

/// The Text that says [words], its non-breaking spaces read as spaces (the
/// way noOrphan and keepTogether keep words on one line).
Finder findWords(String words) =>
    find.byWidgetPredicate((w) => w is Text && w.data?.replaceAll('\u00A0', ' ') == words, description: 'Text "$words"');

/// Expects the paragraph [finder] holds to wrap with more than one word on
/// its last line: no word left alone under the rest (a design review's
/// "Orphan words").
void expectNoOrphan(WidgetTester tester, Finder finder, {String? reason, bool firstParagraph = false}) {
  final (:lines, :lastLine) = linesOf(tester, finder, firstParagraph: firstParagraph);  expect(lines, greaterThan(1), reason: 'on one line, so nothing to check (${reason ?? ''})');
  final words = lastLine.trim().split(RegExp('[ \u00A0]+')).where((w) => w.isNotEmpty);
  expect(words.length, greaterThan(1), reason: 'alone on the last line: "$lastLine" (${reason ?? ''})');
}
