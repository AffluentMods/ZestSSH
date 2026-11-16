import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/theme/zest_color_scheme.dart';
import 'package:zestssh/theme/zest_tokens.dart';

String _hex(Color c) => '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

/// Every built-in theme reads (the 4.0 accessibility pass):
/// body, secondary and muted text, error words and the accent as a label at
/// 4.5:1 or better on every ground the app draws them on; the status colours,
/// which say things in words as well as in dots, at 4.5:1 too; placeholders
/// at 3:1; the words on the accent's fill at 4.5:1. Before it, the muted
/// words of labels and helper lines were 3.2 to 4.4:1 on the cards of eleven
/// dark themes, Daylight's tertiary text 4.2:1 on its page, the error red
/// 3.4 to 4.4:1 on the cards of nine themes, Solarized Dark's green, amber
/// and blue and One Light's under 4:1 on theirs, and placeholders 1.9 to
/// 2.9:1 nearly everywhere. The muted words read on a chip too (Ember's
/// were 4.41:1 on its chip and 4.25:1 on its strong chip, Daylight's 4.32
/// and 4.04:1).
void main() {
  tearDown(() => AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme));

  List<String> failures() {
    final grounds = <String, Color>{
      'background': AppColors.v3Background,
      'surface': AppColors.v3Surface,
      'elevated': AppColors.v3Elevated,
      'panel': ZestTokens.surfaceBase,
      'raised cell': ZestTokens.surfaceRaised,
      'field well': ZestTokens.surfaceSunken,
      'menu': ZestTokens.surfaceRaisedAlt,
      'card': ZestTokens.surfaceElevated,
    };
    final chips = {'chip': ZestTokens.surfaceChip, 'strong chip': ZestTokens.surfaceChipStrong};
    final inks = <String, (Color, double, bool)>{
      // name: (colour, least ratio, also on chips)
      'v3TextPrimary': (AppColors.v3TextPrimary, 4.5, true),
      'v3TextSecondary': (AppColors.v3TextSecondary, 4.5, true),
      'v3TextTertiary': (AppColors.v3TextTertiary, 4.5, false),
      'textPrimary': (ZestTokens.textPrimary, 4.5, true),
      'textSecondary': (ZestTokens.textSecondary, 4.5, true),
      'textFaint': (ZestTokens.textFaint, 4.5, false),
      'textTertiary': (ZestTokens.textTertiary, 4.5, true),
      'textMuted': (ZestTokens.textMuted, 4.5, true),
      'textPlaceholder': (ZestTokens.textPlaceholder, 3.0, false),
      'error': (AppColors.v3Error, 4.5, false),
      'success': (AppColors.v3Success, 4.5, false),
      'warning': (AppColors.v3Warning, 4.5, false),
      'info': (AppColors.v3Info, 4.5, false),
      'statusError': (ZestColors.statusError, 4.5, false),
      'statusSuccess': (ZestColors.statusSuccess, 4.5, false),
      'statusWarning': (ZestColors.statusWarning, 4.5, false),
      'statusInfo': (ZestColors.statusInfo, 4.5, false),
      'brandInk': (ZestTokens.brandInk, 4.5, true),
      'v3AccentInk': (AppColors.v3AccentInk, 4.5, true),
    };
    final out = <String>[];
    for (final MapEntry(key: name, value: (ink, least, onChips)) in inks.entries) {
      for (final MapEntry(key: where, value: ground) in {...grounds, if (onChips) ...chips}.entries) {
        final r = AppColors.contrastRatio(ink, ground);
        if (r < least) out.add('$name ${_hex(ink)} on $where ${_hex(ground)}: ${r.toStringAsFixed(2)}:1, under $least');
      }
    }
    final onBrand = AppColors.contrastRatio(ZestColors.onBrand, ZestTokens.brand);
    if (onBrand < 4.5) out.add('the words on the accent: ${onBrand.toStringAsFixed(2)}:1');
    return out;
  }

  for (final theme in BuiltInThemes.all) {
    test('${theme.name}: every colour that is read reads on every ground', () {
      AppColors.applyTheme(theme.colorScheme);
      expect(failures(), isEmpty);
    });
  }

  test('Ember, Graphite and Daylight read as they are authored (their files are what is painted)', () {
    for (final id in ['default_dark', 'graphite', 'default_light']) {
      final cs = BuiltInThemes.getById(id).colorScheme;
      expect(identical(cs.readable, cs), isTrue, reason: '$id: a colour of it was made readable at runtime');
    }
  });

  test('a scheme made in the theme designer is painted readable too', () {
    const grey = Color(0xFF777777);
    final made = BuiltInThemes.getById('default_dark')
        .colorScheme
        .copyWith(id: 'custom_x', onSurfaceMuted: grey, onBackgroundSubtle: grey, error: const Color(0xFF992222));
    AppColors.applyTheme(made);
    expect(failures(), isEmpty);
    // What was authored stays in the scheme, for the designer to show.
    expect(made.onSurfaceMuted, grey);
    expect(made.readable.onSurfaceMuted, isNot(grey));
  });

  test('a shade is the same hue, only lighter on dark grounds and darker on light ones', () {
    const ground = Color(0xFF202020);
    final cs = ZestColorScheme.fromJson(BuiltInThemes.getById('default_dark').colorScheme.toJson())!;
    final shaded = cs.copyWith(error: const Color(0xFF993333), surfaces: null).readable.error;
    expect(HSLColor.fromColor(shaded).hue, closeTo(HSLColor.fromColor(const Color(0xFF993333)).hue, 1));
    expect(shaded.computeLuminance(), greaterThan(const Color(0xFF993333).computeLuminance()));
    expect(AppColors.contrastRatio(shaded, ground), greaterThanOrEqualTo(4.5));
  });
}
