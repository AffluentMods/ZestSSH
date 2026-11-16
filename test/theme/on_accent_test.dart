// The "On accent" token: text and icons drawn on an accent
// fill are white or near-black, whichever reads better on that accent, so a
// primary button's label passes 4.5:1 with the default orange (white on it
// was 2.6:1) and with any accent a person picks, a yellow or a navy.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';

double _ratio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  const accents = {
    'default orange': Color(0xFFFF7A1A),
    'yellow': Color(0xFFFFD60A),
    'navy': Color(0xFF1E3A8A),
  };

  test('the default accent takes near-black, 6.7:1, not white (2.6:1)', () {
    const orange = Color(0xFFFF7A1A);
    final ink = ZestColors.onFill(orange);
    expect(ink, const Color(0xFF161920));
    expect(_ratio(ink, orange), greaterThan(6.5));
    expect(_ratio(Colors.white, orange), lessThan(3));
  });

  for (final themeId in ['graphite', 'default_light']) {
    for (final e in accents.entries) {
      test('$themeId with a ${e.key} accent: every primary button\'s label passes 4.5:1', () {
        final data = BuiltInThemes.getById(themeId).toThemeData(accentOverride: e.value);
        final states = <WidgetState>{};
        final filled = data.filledButtonTheme.style!;
        final elevated = data.elevatedButtonTheme.style!;
        expect(filled.backgroundColor!.resolve(states), e.value);
        for (final style in [filled, elevated]) {
          final fg = style.foregroundColor!.resolve(states)!;
          expect(_ratio(fg, e.value), greaterThanOrEqualTo(4.5), reason: '${e.key}: $fg on ${e.value}');
        }
        expect(_ratio(data.colorScheme.onPrimary, e.value), greaterThanOrEqualTo(4.5));
        expect(_ratio(data.floatingActionButtonTheme.foregroundColor!, e.value), greaterThanOrEqualTo(4.5));
      });
    }
  }
}
