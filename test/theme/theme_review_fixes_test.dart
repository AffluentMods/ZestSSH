// The theme's findings of a code review: a field's label
// that vanished once the field held a value, labels on the secondary and
// error fills picked for the orange, an invisible hover and disabled filled
// buttons on Daylight, and Ember drawn by the legacy theme instead of the one
// every other theme is drawn by.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/theme_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/theme/zest_tokens.dart';

const _houseThemes = ['default_dark', 'graphite', 'default_light'];

double _c(Color a, Color b) => ZestColors.contrast(a, b);

void main() {
  tearDown(() => AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme));

  for (final id in _houseThemes) {
    group(id, () {
      final theme = BuiltInThemes.getById(id);
      final cs = theme.colorScheme;
      final data = theme.toThemeData();

      test("a field's label rises onto its edge once it holds a value, it is not a placeholder that vanishes", () {
        final input = data.inputDecorationTheme;
        expect(input.floatingLabelBehavior, isNot(FloatingLabelBehavior.never));
        final floating = input.floatingLabelStyle! as WidgetStateTextStyle;
        expect(floating.resolve({WidgetState.focused}).color, isNot(cs.onSurfaceMuted));
        expect(floating.resolve({WidgetState.error}).color, cs.error);
        expect(_c(floating.resolve({}).color!, data.inputDecorationTheme.fillColor!), greaterThanOrEqualTo(4.5));
      });

      test('onError and onSecondary are the readable ink on their own fills', () {
        final m = data.colorScheme;
        expect(m.onError, ZestColors.onFill(m.error));
        expect(m.onSecondary, ZestColors.onFill(m.secondary));
        expect(m.onTertiary, ZestColors.onFill(m.tertiary));
        expect(_c(m.onError, m.error), greaterThanOrEqualTo(4.5));
      });

      test('with a navy secondary its label turns white, the primary\'s stays dark', () {
        const navy = Color(0xFF1E3A8A);
        final m = theme.copyWith(colorScheme: cs.copyWith(secondary: navy)).toThemeData().colorScheme;
        expect(m.onSecondary, const Color(0xFFFFFFFF));
        expect(m.onPrimary, isNot(const Color(0xFFFFFFFF)));
      });

      test('a disabled filled button is the theme\'s one turned-off fill with muted text, seen on whatever it sits on',
          () {
        const off = {WidgetState.disabled};
        final ladder = cs.effectiveSurfaces;
        for (final style in [data.filledButtonTheme.style!, data.elevatedButtonTheme.style!]) {
          final bg = style.backgroundColor!.resolve(off)!;
          final fg = style.foregroundColor!.resolve(off)!;
          expect(bg, ladder.disabledFill);
          expect(fg, ladder.disabledInk);
          // A step off the page, a card, a dialog and a sheet (on a dark
          // sheet the chip it was nearly vanished
          // as a design review found), its words readable on it, and not the accent.
          for (final under in [ladder.panel, cs.surface, cs.surfaceElevated, ladder.raised, ladder.raised2, ladder.cell]) {
            final shown = Color.alphaBlend(bg, under);
            expect(_c(shown, under), greaterThan(1.2), reason: '$under');
            expect(_c(fg, shown), greaterThan(3), reason: '$under');
          }
          expect(bg, isNot(cs.primary));
        }
      });

      test('every kind of disabled main button has that one fill: ZestButton and a dialog\'s or a sheet\'s', () {
        AppColors.applyTheme(cs);
        final ladder = cs.effectiveSurfaces;
        expect(ZestTokens.disabledFill, ladder.disabledFill);
        expect(ZestTokens.disabledInk, ladder.disabledInk);
        for (final file in ['lib/ui/widgets/zest_button.dart', 'lib/ui/widgets/zest_dialog.dart']) {
          final source = File(file).readAsStringSync();
          expect(source, contains('disabledFill'), reason: file);
        }
        // No main button keeps a turned-off fill of its own.
        final own = <String>[];
        for (final entity in Directory('lib').listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart') || entity.path.endsWith('zest_theme.dart')) continue;
          final source = entity.readAsStringSync();
          if (RegExp(r'(FilledButton|ElevatedButton)\.styleFrom\([^;]*disabledBackgroundColor').hasMatch(source)) {
            own.add(entity.path);
          }
        }
        expect(own, isEmpty);
      });

      test('a hovered row is a visible step off the card under it', () {
        AppColors.applyTheme(cs);
        final ladder = cs.effectiveSurfaces;
        for (final under in [ladder.raised, ladder.panel]) {
          final hovered = Color.alphaBlend(ZestTokens.surfaceHover, under);
          expect(_c(hovered, under), greaterThanOrEqualTo(1.05), reason: 'on $under');
          final legacy = Color.alphaBlend(AppColors.v3Hover, under);
          if (under == ladder.raised) expect(_c(legacy, under), greaterThanOrEqualTo(1.08));
        }
        // The dark themes keep the cell step they always had.
        if (cs.isDark) expect(ZestTokens.surfaceHover, ladder.cell);
      });
    });
  }

  test("Daylight's hover is not the raised cell, which is as white as its cards", () {
    AppColors.applyTheme(BuiltInThemes.getById('default_light').colorScheme);
    expect(ZestTokens.surfaceRaised, const Color(0xFFFFFFFF));
    expect(ZestTokens.surfaceHover, isNot(ZestTokens.surfaceRaised));
  });

  group('Ember is drawn by the theme builder every theme is drawn by', () {
    Future<ThemeData> appTheme(String id) async {
      SharedPreferences.setMockInitialValues({'app_theme_id': id});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
      addTearDown(c.dispose);
      return c.read(appThemeDataProvider);
    }

    test("Ember's ThemeData has Graphite's builder's make, not the legacy theme's", () async {
      final ember = await appTheme('default_dark');
      final graphite = await appTheme('graphite');
      final built = BuiltInThemes.getById('default_dark').toThemeData();
      final legacy = AppTheme.dark();
      // What only the builder sets.
      for (final t in [ember, graphite]) {
        expect(t.inputDecorationTheme.enabledBorder, isA<OutlineInputBorder>());
        expect(t.switchTheme.thumbIcon, isNotNull);
      }
      expect(ember.inputDecorationTheme.fillColor, built.inputDecorationTheme.fillColor);
      expect(ember.inputDecorationTheme.fillColor, isNot(legacy.inputDecorationTheme.fillColor));
      expect(ember.filledButtonTheme.style!.minimumSize!.resolve({}),
          graphite.filledButtonTheme.style!.minimumSize!.resolve({}));
      expect(ember.colorScheme.surface, built.colorScheme.surface);
    });

    test("the app's root takes its ThemeData from appThemeDataProvider alone, never from AppTheme", () {
      final code = File('lib/app.dart').readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join('\n');
      expect(code, contains('ref.watch(appThemeDataProvider)'));
      expect(code, isNot(contains('AppTheme.')));
      expect(code, isNot(contains("'package:zestssh/theme/app_theme.dart'")));
    });
  });
}
