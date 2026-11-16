import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/ui/widgets/middle_ellipsis_text.dart';

/// A text cut in the middle where it does not fit (tabs that say where a
/// host comes from).
void main() {
  const style = TextStyle(fontSize: 10);

  double widthOf(String s) {
    final p = TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr)..layout();
    return p.width;
  }

  test('a text that fits is left whole', () {
    expect(middleEllipsis('Personal', style, 500), 'Personal');
  });

  test('one that does not keeps both ends, as much as fits, with an ellipsis between', () {
    const text = 'Personal \u00b7 reallylonggroupname';
    final width = widthOf(text) * 0.6;
    final cut = middleEllipsis(text, style, width);
    expect(cut, contains('\u2026'));
    expect(cut, startsWith('Personal'));
    expect(cut, endsWith('name'));
    expect(widthOf(cut), lessThanOrEqualTo(width));
    // One letter more would not fit: as much as fits is kept.
    expect(cut.length, greaterThan(text.length ~/ 2));
  });

  test('very narrow: the ellipsis at least', () {
    expect(middleEllipsis('Personal \u00b7 Web servers', style, 1), '\u2026');
  });
}
