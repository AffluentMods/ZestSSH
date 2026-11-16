import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/providers/theme_sync_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/terminal_themes.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/theme/zest_theme.dart';

/// The five looks of the editors people come from (3.0): Atom's One Dark and
/// One Light, and the JetBrains IDEs' Darcula, IntelliJ Dark and IntelliJ
/// Light.
const _editorThemes = ['one_dark', 'one_light', 'darcula', 'intellij_dark', 'intellij_light'];

/// Ember, Graphite and Daylight: the app's own, whose schemes keep the few
/// colours they have had since before their steps were spelled out.
const _houseThemes = ['default_dark', 'graphite', 'default_light'];

double _c(Color a, Color b) => ZestColors.contrast(a, b);

/// The built-in app themes (3.0): every one spells out each step of its
/// surfaces and its text, and is held to what can be read. Worked out from a
/// scheme's few colours, the steps of the palettes that have one quiet
/// colour (a comment grey) came out too dim to read: Nord's muted text stood
/// at 1.4 to 1 on its cards.
void main() {
  tearDown(() => AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme));

  test('no two built-in themes share an id or a name, and a scheme carries its theme\'s', () {
    expect(BuiltInThemes.ids.toSet(), hasLength(BuiltInThemes.all.length));
    expect(BuiltInThemes.names.values.toSet(), hasLength(BuiltInThemes.all.length));
    for (final theme in BuiltInThemes.all) {
      expect(theme.colorScheme.id, theme.id);
      expect(theme.colorScheme.name, theme.name);
      expect(theme.brightness == Brightness.dark, theme.colorScheme.isDark, reason: theme.id);
      expect(theme.colorScheme.background.computeLuminance() < 0.2, theme.colorScheme.isDark, reason: theme.id);
    }
  });

  test('the five are there, after the others, under the names they are known by', () {
    expect(BuiltInThemes.ids.sublist(BuiltInThemes.ids.length - 5), _editorThemes);
    expect(BuiltInThemes.ids.first, 'default_dark', reason: 'the default stays first');
    expect([for (final id in _editorThemes) BuiltInThemes.names[id]],
        ['One Dark', 'One Light', 'Darcula', 'IntelliJ Dark', 'IntelliJ Light']);
    expect([for (final id in _editorThemes) BuiltInThemes.getById(id).colorScheme.isDark],
        [true, false, true, true, false]);
  });

  test('the themes there were keep their ids and their names', () {
    expect(BuiltInThemes.names, containsPair('default_dark', 'Ember'));
    expect(BuiltInThemes.ids.sublist(0, 12), [
      'default_dark',
      'graphite',
      'default_light',
      'amoled',
      'midnight',
      'dracula',
      'nord',
      'monokai',
      'solarized_dark',
      'catppuccin_mocha',
      'tokyo_night',
      'gruvbox_dark',
    ]);
    expect([
      for (final id in ['amoled', 'midnight', 'dracula', 'nord', 'monokai', 'solarized_dark', 'catppuccin_mocha', 'tokyo_night', 'gruvbox_dark'])
        BuiltInThemes.names[id],
    ], [
      'AMOLED Black',
      'Midnight',
      'Dracula',
      'Nord',
      'Monokai Pro',
      'Solarized Dark',
      'Catppuccin Mocha',
      'Tokyo Night',
      'Gruvbox Dark',
    ]);
  });

  test('each has the colours it is known by', () {
    ZestTheme of(String id) => BuiltInThemes.getById(id);

    final oneDark = of('one_dark').colorScheme;
    expect(oneDark.background, const Color(0xFF21252B));
    expect(oneDark.surface, const Color(0xFF282C34), reason: 'the grey One Dark is known by');
    expect(oneDark.onSurfaceMuted, const Color(0xFFABB2BF));
    expect(oneDark.primary, const Color(0xFF568AF2));
    expect([oneDark.success, oneDark.warning, oneDark.error, oneDark.info],
        const [Color(0xFF98C379), Color(0xFFE5C07B), Color(0xFFE06C75), Color(0xFF61AFEF)]);

    final oneLight = of('one_light').colorScheme;
    expect(oneLight.background, const Color(0xFFEAEAEB));
    expect(oneLight.surface, const Color(0xFFFAFAFA));
    expect(oneLight.onSurface, const Color(0xFF232324));
    expect(oneLight.onSurfaceMuted, const Color(0xFF383A42));
    expect(oneLight.effectiveSurfaces.chip, const Color(0xFFDBDBDC), reason: 'the grey of its borders and selected rows');

    final darcula = of('darcula').colorScheme;
    expect(darcula.background, const Color(0xFF2B2B2B), reason: 'the grey Darcula is known by');
    expect(darcula.surface, const Color(0xFF313335));
    expect(darcula.onSurfaceMuted, const Color(0xFFBBBBBB));
    expect(darcula.effectiveSurfaces.text3, const Color(0xFFA9B7C6), reason: 'the text of its editor');
    expect(darcula.effectiveSurfaces.chip, const Color(0xFF3C3F41), reason: 'the grey of its tool windows');
    expect([darcula.primary, darcula.warning, darcula.error],
        const [Color(0xFF589DF6), Color(0xFFFFC66D), Color(0xFFFF6B68)]);

    final dark = of('intellij_dark').colorScheme;
    expect(dark.background, const Color(0xFF1E1F22));
    expect(dark.surface, const Color(0xFF2B2D30));
    expect(dark.onSurface, const Color(0xFFDFE1E5));
    expect(dark.focus, const Color(0xFF3574F0), reason: 'the blue of the IDE');
    expect(dark.primaryHover, const Color(0xFF3574F0));

    final light = of('intellij_light').colorScheme;
    expect(light.background, const Color(0xFFF7F8FA));
    expect(light.surface, const Color(0xFFFFFFFF));
    expect(light.onSurface, const Color(0xFF000000));
    expect(light.focus, const Color(0xFF3574F0));
  });

  test('the older themes keep the colours of their palettes: the pane, the card and the accent', () {
    // id: pane, card, the strongest chip, the first step of text, the accent.
    const palettes = <String, List<Color>>{
      'dracula': [Color(0xFF282A36), Color(0xFF343746), Color(0xFF44475A), Color(0xFFF8F8F2), Color(0xFFBD93F9)],
      'nord': [Color(0xFF2E3440), Color(0xFF3B4252), Color(0xFF4C566A), Color(0xFFECEFF4), Color(0xFF88C0D0)],
      'monokai': [Color(0xFF272822), Color(0xFF2D2E27), Color(0xFF49483E), Color(0xFFF8F8F2), Color(0xFFF92672)],
      'catppuccin_mocha': [Color(0xFF1E1E2E), Color(0xFF313244), Color(0xFF45475A), Color(0xFFCDD6F4), Color(0xFFCBA6F7)],
      'tokyo_night': [Color(0xFF1A1B26), Color(0xFF24283B), Color(0xFF343A55), Color(0xFFC0CAF5), Color(0xFF7AA2F7)],
      'gruvbox_dark': [Color(0xFF282828), Color(0xFF3C3836), Color(0xFF504945), Color(0xFFEBDBB2), Color(0xFFFE8019)],
      'midnight': [Color(0xFF0B1021), Color(0xFF131A2E), Color(0xFF222C4A), Color(0xFFDDE3F0), Color(0xFF5B9CF5)],
      'amoled': [Color(0xFF000000), Color(0xFF0D0D0D), Color(0xFF1F1F1F), Color(0xFFE0E0E0), Color(0xFFFF7A1A)],
    };
    for (final entry in palettes.entries) {
      final scheme = BuiltInThemes.getById(entry.key).colorScheme;
      final l = scheme.effectiveSurfaces;
      expect([l.panel, l.raised, l.chipStrong, l.text, scheme.primary], entry.value, reason: entry.key);
    }
    // Solarized keeps its two base tones and its blue; its text is the hue
    // of its content tones, lighter (base1 could not be read on a card).
    final solarized = BuiltInThemes.getById('solarized_dark').colorScheme;
    expect(solarized.background, const Color(0xFF002B36));
    expect(solarized.surface, const Color(0xFF073642));
    expect(solarized.primary, const Color(0xFF268BD2));
    expect(solarized.onSurface.computeLuminance(), greaterThan(const Color(0xFF93A1A1).computeLuminance()));
    // Palette colours that could be kept as a step of text are that step.
    expect(BuiltInThemes.getById('nord').colorScheme.effectiveSurfaces.text2, const Color(0xFFD8DEE9), reason: 'nord4');
    final mocha = BuiltInThemes.getById('catppuccin_mocha').colorScheme.effectiveSurfaces;
    expect([mocha.text2, mocha.muted2, mocha.dim], const [Color(0xFFBAC2DE), Color(0xFF9399B2), Color(0xFF6C7086)],
        reason: 'Subtext1, Overlay2, Overlay0');
    final gruvbox = BuiltInThemes.getById('gruvbox_dark').colorScheme.effectiveSurfaces;
    expect([gruvbox.text2, gruvbox.dim], const [Color(0xFFD5C4A1), Color(0xFF7C6F64)], reason: 'fg2, bg4');
  });

  for (final theme in BuiltInThemes.all) {
    final id = theme.id;
    group(id, () {
      final scheme = theme.colorScheme;
      final l = scheme.effectiveSurfaces;
      // What text is drawn on, from the pane to a hovered row, and the chips.
      final ordinary = {'the pane': l.panel, 'a card': l.raised, 'a menu': l.raised2, 'a hovered row': l.cell};
      final chips = {'a chip': l.chip, 'a count': l.chipStrong};

      test('spells out its steps', () {
        expect(scheme.surfaces, isNotNull, reason: 'worked out from a scheme, the steps of text come out too dim');
        expect(scheme.focus.a, 1.0);
        expect(scheme.selected.a, lessThan(0.3), reason: 'a tint over the row, not a fill');
        expect(scheme.hover.a, lessThan(0.1));
      });

      test('the few colours of its scheme are steps of them', () {
        expect(scheme.background, l.panel);
        expect(scheme.surface, l.raised);
        expect(scheme.surfaceElevated, l.raised2, reason: 'a dialog is drawn on it: text must hold there');
        expect(scheme.onBackground, l.text);
        expect(scheme.onSurface, l.text);
        expect(scheme.onSurfaceMuted, l.text2);
        expect(scheme.divider, l.border);
        expect(scheme.border, l.borderStrong);
        expect([l.text3, l.muted], contains(scheme.onBackgroundMuted));
        expect([l.muted, l.muted2], contains(scheme.onBackgroundSubtle));
      }, skip: _houseThemes.contains(id) ? 'its scheme keeps the colours it has had since 1.7' : null);

      test('every step of text can be read on what it is drawn on', () {
        void reads(String what, Color ink, Map<String, Color> on, double atLeast) {
          for (final surface in on.entries) {
            expect(_c(ink, surface.value), greaterThanOrEqualTo(atLeast), reason: '$id: $what on ${surface.key}');
          }
        }

        reads('text', l.text, ordinary, 7.0);
        reads('text', l.text, chips, 4.5);
        reads('the second step', l.text2, {...ordinary, ...chips}, 4.5);
        reads('the third step', l.text3, {...ordinary, ...chips}, 4.5);
        reads('muted text', l.muted, ordinary, 4.5);
        reads('a section label', l.muted2, ordinary, 3.5);
        reads('a placeholder', l.dim, ordinary, 2.0);

        // Each step is dimmer than the one above it, on the pane.
        final steps = [l.text, l.text2, l.text3, l.muted, l.muted2, l.dim].map((ink) => _c(ink, l.panel)).toList();
        for (var i = 1; i < steps.length; i++) {
          expect(steps[i], lessThan(steps[i - 1]), reason: '$id: step ${i + 1} of the text');
        }
      });

      test('the colours of a state can be made out on it', () {
        for (final state in {
          'success': scheme.success,
          'a warning': scheme.warning,
          'an error': scheme.error,
          'information': scheme.info,
        }.entries) {
          for (final surface in ordinary.entries) {
            expect(_c(state.value, surface.value), greaterThanOrEqualTo(3.5),
                reason: '$id: ${state.key} on ${surface.key}');
          }
        }
      });

      test('what is written on the accent can be read, by the scheme and by the app alike', () {
        final worked = ZestColors.onFill(scheme.primary);
        expect(_c(worked, scheme.primary), greaterThanOrEqualTo(4.5), reason: 'the ink the app works out');
        expect(_c(scheme.onPrimary, scheme.primary), greaterThanOrEqualTo(4.5), reason: 'the ink the scheme names');
        expect(worked.computeLuminance() > 0.5, scheme.onPrimary.computeLuminance() > 0.5,
            reason: 'both dark or both light: a button is not dark on blue in one place and white in the next');

        AppColors.applyTheme(scheme);
        for (final surface in {...ordinary, ...chips}.entries) {
          expect(_c(AppColors.v3AccentInk, surface.value), greaterThanOrEqualTo(4.5),
              reason: '$id: text in the accent on ${surface.key}');
          expect(_c(ZestColors.accentInk, surface.value), greaterThanOrEqualTo(4.5),
              reason: '$id: the components\' accent text on ${surface.key}');
        }
      });

      test('its surfaces are told apart, and a border is seen on a card', () {
        expect(_c(l.raised, l.panel), greaterThanOrEqualTo(1.05), reason: 'a card on the pane');
        if (scheme.isDark || l.cell != l.raised) {
          expect(_c(l.cell, l.raised), greaterThanOrEqualTo(1.05), reason: 'a hovered row on a card');
          expect(_c(l.cell, l.panel), greaterThanOrEqualTo(1.10), reason: 'the card of a host on the pane');
        } else {
          // A light theme that lifts its cards (Daylight): white cards on
          // the grey page, never darker than it, and a hovered row a step
          // off the white.
          expect(l.raised.computeLuminance(), greaterThan(l.panel.computeLuminance()), reason: 'cards above the page');
          expect(_c(l.cell, l.panel), greaterThanOrEqualTo(1.05), reason: 'the card of a host on the pane');
          expect(_c(l.raised2, l.raised), greaterThanOrEqualTo(1.03), reason: 'a hovered row on a card');
        }
        expect(_c(l.sunken, l.raised), greaterThanOrEqualTo(1.03), reason: 'a field in a card');
        expect(_c(l.sunken, l.panel), greaterThanOrEqualTo(1.03), reason: 'a field on the pane');
        expect(_c(l.line, l.raised), greaterThanOrEqualTo(1.12), reason: 'the softest line');
        expect(_c(l.border, l.raised), greaterThanOrEqualTo(1.2), reason: 'a border on a card');
        expect(_c(l.border, l.panel), greaterThanOrEqualTo(1.12), reason: 'a border on the pane');
        expect(_c(l.borderStrong, l.raised), greaterThanOrEqualTo(1.5), reason: 'a divider');
        expect(_c(l.borderStrong, l.raised), greaterThan(_c(l.border, l.raised)));
      });

      test('a tag is seen on the pane and on a card, and a count stands out more than a tag', () {
        // A tag and a badge are a fill with no border: the fill is all there
        // is to see of them.
        expect(_c(l.chip, l.panel), greaterThanOrEqualTo(1.10), reason: 'a tag on the pane');
        expect(_c(l.chip, l.raised), greaterThanOrEqualTo(1.10), reason: 'a tag on a card');
        expect(_c(l.chipStrong, l.raised), greaterThan(_c(l.chip, l.raised)), reason: 'the count of a section');
        expect(_c(l.chipStrong, l.panel), greaterThan(_c(l.chip, l.panel)), reason: 'the count of a section');
      });

      if (_editorThemes.contains(id)) {
        test('picking it for the app picks its terminal theme, and the other way', () {
          expect(kAppToTerminalThemeId[id], id);
          expect(kTerminalToAppThemeId[id], id);
          final terminal = TerminalThemes.builtIn[id]!;
          expect(terminal.background.computeLuminance() < 0.2, scheme.isDark, reason: 'dark with dark, light with light');
          expect(TerminalThemes.builtInNames[id], BuiltInThemes.names[id], reason: 'one name for both');
        });
      }
    });
  }

  test('a paired theme is a theme: no pair names one that is not there', () {
    final app = BuiltInThemes.ids.toSet();
    final terminal = TerminalThemes.builtIn.keys.toSet();
    // (Two app themes may share a terminal theme, and the other way.)
    expect(app, containsAll(kAppToTerminalThemeId.keys));
    expect(terminal, containsAll(kAppToTerminalThemeId.values.toSet()));
    expect(terminal, containsAll(kTerminalToAppThemeId.keys));
    expect(app, containsAll(kTerminalToAppThemeId.values.toSet()));
    for (final pair in kAppToTerminalThemeId.entries) {
      final dark = BuiltInThemes.getById(pair.key).colorScheme.isDark;
      expect(TerminalThemes.builtIn[pair.value]!.background.computeLuminance() < 0.2, dark,
          reason: '${pair.key} with ${pair.value}: dark with dark, light with light');
    }
  });

  test('a theme made from a built-in one has its steps worked out anew from its own colours', () {
    // (The theme designer copies a built-in, then edits it: a ladder spelled
    // out for the original must not paint the copy.)
    final nord = BuiltInThemes.getById('nord').colorScheme;
    final mine = nord.copyWith(id: 'custom_1', name: 'Mine', background: const Color(0xFF101418));
    expect(mine.surfaces, isNull);
    expect(mine.effectiveSurfaces.panel, isNot(nord.effectiveSurfaces.panel));
    // What it works them out from is what can be read: the copy's muted text
    // is the original's, not the grey of a comment.
    expect(_c(mine.effectiveSurfaces.muted, mine.effectiveSurfaces.raised), greaterThanOrEqualTo(4.5));
    expect(_c(mine.effectiveSurfaces.text2, mine.effectiveSurfaces.raised), greaterThanOrEqualTo(4.5));
  });
}
