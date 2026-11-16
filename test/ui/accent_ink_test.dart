import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/theme/zest_tokens.dart';

/// The accent ink (3.0): text and icons in the accent colour
/// read at 4.5:1 or better on every built-in theme's surfaces, and the dark
/// themes keep the brand orange exactly (they already read well).
void main() {
  tearDown(() => AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme));

  test('an accent that reads well enough stays as it is', () {
    const orange = Color(0xFFFF7A1A);
    expect(ZestColors.inkOn(orange, const Color(0xFF26262A)), orange);
  });

  test('on a light surface it deepens just enough', () {
    const orange = Color(0xFFFF7A1A);
    const light = Color(0xFFDDE0E6);
    final ink = ZestColors.inkOn(orange, light);
    expect(ZestColors.contrast(ink, light), greaterThanOrEqualTo(4.5));
    expect(ink.computeLuminance(), lessThan(orange.computeLuminance()));
    // Still the same hue: an orange, not a brown-grey.
    expect(HSLColor.fromColor(ink).hue, closeTo(HSLColor.fromColor(orange).hue, 1.5));
  });

  test('on a dark surface a dark accent lightens', () {
    const navy = Color(0xFF1B2A6B);
    const dark = Color(0xFF26262A);
    final ink = ZestColors.inkOn(navy, dark);
    expect(ZestColors.contrast(ink, dark), greaterThanOrEqualTo(4.5));
    expect(ink.computeLuminance(), greaterThan(navy.computeLuminance()));
  });

  for (final id in ['default_dark', 'graphite', 'default_light']) {
    test('$id: the inks read on the theme\'s surfaces', () {
      final scheme = BuiltInThemes.getById(id).colorScheme;
      AppColors.applyTheme(scheme);
      final surfaces = scheme.effectiveSurfaces;
      for (final surface in [surfaces.panel, surfaces.raised, surfaces.cell, surfaces.chipStrong]) {
        expect(ZestColors.contrast(AppColors.accentInk, surface), greaterThanOrEqualTo(4.5), reason: '$id legacy ink');
        expect(ZestColors.contrast(AppColors.v3AccentInk, surface), greaterThanOrEqualTo(4.5), reason: '$id v3 ink');
        expect(ZestColors.contrast(ZestTokens.brandInk, surface), greaterThanOrEqualTo(4.5), reason: '$id token ink');
      }
      if (scheme.isDark) {
        expect(AppColors.accentInk, AppColors.brandOrange, reason: 'dark themes keep the brand exactly');
        expect(ZestColors.accentInk, ZestColors.accentPrimary);
      } else {
        expect(AppColors.accentInk, isNot(AppColors.brandOrange), reason: 'the brand is too light to read here');
        expect(AppColors.brandOrange, const Color(0xFFFF7A1A), reason: 'fills keep the brand');
      }
    });
  }
}
