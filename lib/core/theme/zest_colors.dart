import 'package:flutter/material.dart';

import 'package:zestssh/theme/zest_surfaces.dart';

/// Colour tokens for the 1.7 component layer (ZestButton, ZestField, the
/// master/detail shell, the Hosts page, toasts, ...).
///
/// RUNTIME-MUTABLE since 3.0: [AppColors.applyTheme] calls [applySurfaces]
/// with the active theme's ladder before every build, so these follow Ember,
/// Graphite, Daylight and every other theme instead of staying Ember's
/// charcoal. The defaults below are Ember's exact values, which is also what
/// the first frame paints before any theme is applied.
class ZestColors {
  ZestColors._();

  // Chrome (pill bar, status bar)
  static Color chromeBg = const Color(0xFF000000);
  static Color chromeDivider = const Color(0xFF1A1A1D);
  static Color chromeElevated = const Color(0xFF161619);

  // A page's header band (3.0 Blueprint): a step above the panel, with a
  // rule of its own.
  static Color band = const Color(0xFF121214);
  static Color bandLine = const Color(0xFF313136);

  // Content
  static Color bgContent = const Color(0xFF121215); // --sunken (field input bg)
  static Color bgSurface = const Color(0xFF1F1F23); // --cell (raised label cell)
  static Color bgElevated = const Color(0xFF3A3A3F); // --border-strong
  static Color bgHover = const Color(0xFF1F1F23);

  // ── Warm host-editor surfaces + accents (1.7 unified field system) ──
  static Color surfacePanel = const Color(0xFF0D0D0E); // deepest panel; text-on-brand
  static Color surfaceRaisedAlt = const Color(0xFF1A1A1D); // raised menu / pill
  static Color surfaceChip = const Color(0xFF232327);
  static Color surfaceChipStrong = const Color(0xFF26262A); // == borderSubtle value
  static Color brandFill = const Color(0xFF231A12); // brand-tinted fill
  static Color brandBadge = const Color(0xFF2D1E12); // brand-tinted badge
  static Color brandIconBg = const Color(0xFF2A1E12); // brand-tinted icon chip
  static Color varHighlight = const Color(0xFFE0B48A); // ${var} highlight

  // Borders
  static Color borderSubtle = const Color(0xFF26262A); // --line
  static Color borderDefault = const Color(0xFF2A2A2E); // --border
  static Color borderStrong = const Color(0xFF3A3A3F); // --border-strong

  // Text
  static Color textPrimary = const Color(0xFFE6E3DA); // --text
  static Color textSecondary = const Color(0xFFC9C6BD); // --text-2
  static Color textFaint = const Color(0xFFA9A69E); // --text-3 (between text-2 and muted)
  static Color textTertiary = const Color(0xFF918F88); // --muted
  static Color textMuted = const Color(0xFF8F8D86); // --muted-2 (section labels + helper text)
  static Color textDisabled = const Color(0xFF6D6B64); // --dim

  /// A turned-off button's fill and its words ([ZestSurfaces.disabledFill]):
  /// one for every kind of button.
  static Color disabledFill = const Color(0x1FE6E3DA); // --text at 12%
  static Color disabledInk = const Color(0xFF918F88); // --muted

  // Brand orange - RUNTIME-MUTABLE so a user-chosen ACCENT retints the 1.7
  // component layer (ZestButton / ZestField / ZestTokens.brand, ...). Defaults
  // are the historical `#FF7A1A` family; [applyAccent] restores them exactly
  // for the built-in brand.
  static Color accentPrimary = const Color(0xFFFF7A1A);
  static Color accentHover = const Color(0xFFFF9547);
  static Color accentPressed = const Color(0xFFE05A00);
  static Color accentGlow = const Color(0x2EFF7A1A); // ~18% alpha
  static Color accentRing = const Color(0x73FF7A1A); // ~45% alpha - session ring

  /// Text and icons in the accent colour on the theme's surfaces (3.0 UI):
  /// the accent itself wherever it reads well enough, a deeper shade of it
  /// where it does not (the brand orange on Daylight's light greys). Fills,
  /// borders and rings keep [accentPrimary].
  static Color accentInk = const Color(0xFFFF7A1A);

  /// Text and icons painted ON a brand fill (a primary button's label, a
  /// selected segment, a switch knob): near-black, or white when the accent
  /// is dark enough that white reads better. Never the panel colour, which
  /// turns white on a light theme.
  static Color onBrand = const Color(0xFF161004);

  // Status: the one palette (3.0), from the active theme.
  static Color statusSuccess = const Color(0xFF4F9D69);
  static Color statusWarning = const Color(0xFFE6C14A);
  static Color statusError = const Color(0xFFF0736B);
  static Color statusInfo = const Color(0xFF83A8D8);

  /// The frozen default accent hue. When [applyAccent] receives exactly this
  /// value the historical constants are restored verbatim.
  static const Color _defaultAccent = Color(0xFFFF7A1A);

  /// Retint the mutable accent family from [accent].
  static void applyAccent(Color accent) {
    onBrand = onFill(accent);
    if (accent.toARGB32() == _defaultAccent.toARGB32()) {
      accentPrimary = const Color(0xFFFF7A1A);
      accentHover = const Color(0xFFFF9547);
      accentPressed = const Color(0xFFE05A00);
      accentGlow = const Color(0x2EFF7A1A);
      accentRing = const Color(0x73FF7A1A);
      return;
    }
    accentPrimary = accent;
    accentHover = _lighten(accent, 0.10);
    accentPressed = _darken(accent, 0.10);
    accentGlow = accent.withValues(alpha: 0x2E / 0xFF);
    accentRing = accent.withValues(alpha: 0x73 / 0xFF);
  }

  /// Point every surface, border and text token at the active theme's
  /// [ladder], its [chrome] (the title and status bars), status colours and
  /// [accent]. Ember with the built-in brand lands on the exact historical
  /// values.
  static void applySurfaces(
    ZestSurfaces ladder, {
    required bool isDark,
    required Color chrome,
    required Color accent,
    required Color success,
    required Color warning,
    required Color error,
    required Color info,
  }) {
    chromeBg = chrome;
    chromeDivider = ladder.raised2;
    chromeElevated = ladder.raised;
    band = Color.lerp(ladder.panel, ladder.raised, 0.4)!;
    bandLine = Color.lerp(ladder.border, ladder.borderStrong, 0.45)!;

    bgContent = ladder.sunken;
    bgSurface = ladder.cell;
    bgElevated = ladder.borderStrong;
    // A hovered row or cell: the cell step where it stands off the cards
    // (the dark themes), otherwise a quiet wash of the text over whatever the
    // row sits on. Daylight's cells are as white as its cards, so a hover
    // painted in the cell colour never showed.
    bgHover = contrast(ladder.cell, ladder.raised) >= 1.05 ? ladder.cell : ladder.text.withValues(alpha: 0.05);

    surfacePanel = ladder.panel;
    surfaceRaisedAlt = ladder.raised2;
    surfaceChip = ladder.chip;
    surfaceChipStrong = ladder.chipStrong;

    final emberBrand =
        identical(ladder, ZestSurfaces.ember) &&
        accent.toARGB32() == _defaultAccent.toARGB32();
    brandFill = emberBrand
        ? const Color(0xFF231A12)
        : Color.alphaBlend(accent.withValues(alpha: 0.09), ladder.panel);
    brandBadge = emberBrand
        ? const Color(0xFF2D1E12)
        : Color.alphaBlend(accent.withValues(alpha: 0.14), ladder.panel);
    brandIconBg = emberBrand
        ? const Color(0xFF2A1E12)
        : Color.alphaBlend(accent.withValues(alpha: 0.12), ladder.panel);
    varHighlight = isDark ? const Color(0xFFE0B48A) : const Color(0xFF9A5A12);
    // Measured against the strongest chip, a step past the hovered rows,
    // label cells and accent-tinted selections that text in the accent
    // sits on.
    accentInk = inkOn(accent, ladder.chipStrong);

    borderSubtle = ladder.line;
    borderDefault = ladder.border;
    borderStrong = ladder.borderStrong;

    textPrimary = ladder.text;
    textSecondary = ladder.text2;
    textFaint = ladder.text3;
    textTertiary = ladder.muted;
    textMuted = ladder.muted2;
    textDisabled = ladder.dim;
    disabledFill = ladder.disabledFill;
    disabledInk = ladder.disabledInk;

    statusSuccess = success;
    statusWarning = warning;
    statusError = error;
    statusInfo = info;
  }

  /// The WCAG contrast ratio of [a] and [b], from 1 to 21.
  static double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  /// [accent] as text or an icon on [surface]: unchanged when it reads at
  /// 4.5:1 or better (WCAG AA for text), otherwise the nearest shade of it
  /// that does, darker on a light surface and lighter on a dark one.
  static Color inkOn(Color accent, Color surface) => shadeThat(accent, (c) => contrast(c, surface) >= 4.5, surface);

  /// [color] when [holds] of it, otherwise the nearest shade of it (the same
  /// hue, lighter on a dark [surface] and darker on a light one) of which
  /// [holds], or the lightest or darkest there is when none does.
  static Color shadeThat(Color color, bool Function(Color shade) holds, Color surface) {
    if (holds(color)) return color;
    final darken = surface.computeLuminance() > 0.18;
    var hsl = HSLColor.fromColor(color);
    for (var i = 0; i < 100; i++) {
      final lightness = (hsl.lightness + (darken ? -0.01 : 0.01)).clamp(0.0, 1.0);
      hsl = hsl.withLightness(lightness);
      if (holds(hsl.toColor()) || lightness == 0.0 || lightness == 1.0) break;
    }
    return hsl.toColor();
  }

  /// Near-black or white, whichever contrasts more with [fill] (WCAG).
  static Color onFill(Color fill) {
    // The ink of the "On accent" token: whichever of white
    // and this near-black reads better on the fill, so a custom accent, a
    // yellow or a navy, always has a readable label (white on the default
    // orange is 2.6:1; this is 6.7:1).
    const dark = Color(0xFF161920);
    const white = Color(0xFFFFFFFF);
    double ratio(Color a, Color b) {
      final la = a.computeLuminance();
      final lb = b.computeLuminance();
      final hi = la > lb ? la : lb;
      final lo = la > lb ? lb : la;
      return (hi + 0.05) / (lo + 0.05);
    }

    return ratio(dark, fill) >= ratio(white, fill) ? dark : white;
  }

  static Color _lighten(Color c, double amount) {
    final hsl = HSLColor.fromColor(c);
    return hsl
        .withLightness((hsl.lightness + amount).clamp(0.0, 1.0))
        .toColor();
  }

  static Color _darken(Color c, double amount) {
    final hsl = HSLColor.fromColor(c);
    return hsl
        .withLightness((hsl.lightness - amount).clamp(0.0, 1.0))
        .toColor();
  }

  }
