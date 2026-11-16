import 'package:flutter/material.dart';

/// The WCAG contrast of [a] and [b], from 1 to 21.
double contrastOf(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// [ink] as words or a sign on every one of [grounds]: [ink] itself where it
/// reads at [min]:1 or better on each, else the nearest shade of it (the same
/// hue, lighter on dark grounds and darker on light ones) that does, or the
/// lightest or darkest there is where none does.
Color readableShade(Color ink, List<Color> grounds, {double min = 4.5}) {
  if (grounds.isEmpty) return ink;
  bool reads(Color c) => grounds.every((g) => contrastOf(c, g) >= min);
  if (reads(ink)) return ink;
  final lightGrounds = grounds.fold(0.0, (sum, g) => sum + g.computeLuminance()) / grounds.length > 0.18;
  var hsl = HSLColor.fromColor(ink);
  for (var i = 0; i < 100; i++) {
    final lightness = (hsl.lightness + (lightGrounds ? -0.01 : 0.01)).clamp(0.0, 1.0);
    hsl = hsl.withLightness(lightness);
    if (reads(hsl.toColor()) || lightness == 0.0 || lightness == 1.0) break;
  }
  return hsl.toColor();
}

/// The surface and text ladder every screen paints with (3.0).
///
/// A [ZestColorScheme] names only a few colours (background, surface,
/// elevated, text, border). Screens need the steps in between: the pane
/// behind a list, the sunken well of a field, a card, a chip, a hairline, the
/// dimmest label. Built-in themes spell these out; any other theme (presets,
/// the ones people make in the theme designer) gets them worked out from its
/// scheme by [ZestSurfaces.derive], so every screen follows every theme.
@immutable
class ZestSurfaces {
  const ZestSurfaces({
    required this.panel,
    required this.sunken,
    required this.raised,
    required this.raised2,
    required this.cell,
    required this.chip,
    required this.chipStrong,
    required this.line,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.text2,
    required this.text3,
    required this.muted,
    required this.muted2,
    required this.dim,
  });

  /// The pane behind lists and pages.
  final Color panel;

  /// Field wells and path bars: a step below the pane's cards.
  final Color sunken;

  /// Cards and rows.
  final Color raised;

  /// Menus, pills, a header strip.
  final Color raised2;

  /// A label cell, a hovered row, the highest ordinary surface.
  final Color cell;

  /// Chips.
  final Color chip;

  /// Count badges; a stronger chip.
  final Color chipStrong;

  /// The softest hairline.
  final Color line;

  /// Card and field borders.
  final Color border;

  /// Pane dividers, a heavier rule.
  final Color borderStrong;

  /// Body text.
  final Color text;

  /// Secondary text.
  final Color text2;

  /// Between secondary and muted.
  final Color text3;

  /// Muted text and glyphs.
  final Color muted;

  /// Section labels and helper text.
  final Color muted2;

  /// Placeholders and disabled.
  final Color dim;

  /// The one fill of a turned-off button, whatever kind (the theme's filled
  /// button, ZestButton, a dialog's or a sheet's main button): the text at
  /// a low strength, so it stands off the page, a card, a dialog and a sheet
  /// alike. A step of the ladder (the chip) was a sheet's own colour on the
  /// dark themes, and a dialog's main button had a fill of its own that
  /// nearly vanished there (found in a design audit).
  Color get disabledFill => text.withValues(alpha: 0.12);

  /// The words and icon of a turned-off button, on [disabledFill].
  Color get disabledInk => muted;

  /// Ember, the default: the exact values the app has shipped since 1.7.
  static const ember = ZestSurfaces(
    panel: Color(0xFF0D0D0E),
    sunken: Color(0xFF121215),
    raised: Color(0xFF161619),
    raised2: Color(0xFF1A1A1D),
    cell: Color(0xFF1F1F23),
    chip: Color(0xFF232327),
    chipStrong: Color(0xFF26262A),
    line: Color(0xFF26262A),
    border: Color(0xFF2A2A2E),
    borderStrong: Color(0xFF3A3A3F),
    text: Color(0xFFE6E3DA),
    text2: Color(0xFFC9C6BD),
    text3: Color(0xFFA9A69E),
    // The muted words at 4.5:1 on a chip as well (#8D8B83 and #8A8881 were
    // 4.4 and 4.25:1 on the strong chip: the 4.0 accessibility pass).
    muted: Color(0xFF918F88),
    muted2: Color(0xFF8F8D86),
    // Placeholders at 3:1 on its cells (#68665F was 2.9:1, the 4.0
    // accessibility pass).
    dim: Color(0xFF6D6B64),
  );

  /// Graphite: the same ladder in cool blue-grey.
  static const graphite = ZestSurfaces(
    panel: Color(0xFF0F1115),
    // Wells between the pane and its cards, as Ember's are (darker than
    // the page, every nested box read as a hole).
    sunken: Color(0xFF12151B),
    raised: Color(0xFF161920),
    raised2: Color(0xFF1B1F27),
    cell: Color(0xFF1D2129),
    chip: Color(0xFF222731),
    chipStrong: Color(0xFF262B35),
    line: Color(0xFF232833),
    border: Color(0xFF272C36),
    borderStrong: Color(0xFF363C48),
    text: Color(0xFFE9E7E2),
    text2: Color(0xFFC6C8CD),
    text3: Color(0xFFA7ABB3),
    // At 4.5:1 on a chip as well (#8B919C and #878D98 were 4.48 and
    // 4.25:1 on the strong chip).
    muted: Color(0xFF8E949E),
    muted2: Color(0xFF8C929D),
    dim: Color(0xFF666C77),
  );

  /// Daylight: light greys, white cards, dark text.
  static const daylight = ZestSurfaces(
    panel: Color(0xFFF5F6F8),
    // Wells (fields, code) a breath below the cards; cards white on the
    // grey page, as a light theme lifts (they were darker than the page).
    sunken: Color(0xFFF0F2F5),
    raised: Color(0xFFFFFFFF),
    raised2: Color(0xFFF7F8FA),
    cell: Color(0xFFFFFFFF),
    chip: Color(0xFFE5E7EC),
    chipStrong: Color(0xFFDDE0E6),
    line: Color(0xFFE1E4E9),
    border: Color(0xFFD8DBE1),
    borderStrong: Color(0xFFC1C6CF),
    text: Color(0xFF15171C),
    text2: Color(0xFF343944),
    text3: Color(0xFF4A505C),
    // At 4.5:1 on a chip as well (#5F6573 and #656B78 were 4.42 and
    // 4.04:1 on the strong chip).
    muted: Color(0xFF5A5F6C),
    muted2: Color(0xFF5C616D),
    dim: Color(0xFF858B96),
  );

  /// The grounds text is drawn on: the pane, a field's well, a card, a menu
  /// and a cell. (A chip's fill holds only body text, [text] and [text2].)
  List<Color> get textGrounds => [panel, sunken, raised, raised2, cell];

  /// This ladder with every text step readable on every ground it is drawn on
  /// ([textGrounds], and [also]: a scheme's own background, surface and
  /// elevated surface), WCAG AA (the 4.4 accessibility
  /// pass): body and secondary text, the muted words of labels and helper
  /// lines at 4.5:1, placeholders and what is turned off ([dim]) at 3:1, the
  /// nearest shade of each that does where it did not. The same ladder where
  /// every step already read (Ember, Graphite and Daylight spell theirs out
  /// so that they do), so what tells a ladder by identity keeps telling it.
  ZestSurfaces readable({List<Color> also = const []}) {
    final grounds = [...textGrounds, ...also];
    final onChips = [...grounds, chip, chipStrong];
    final t = readableShade(text, onChips);
    final t2 = readableShade(text2, onChips);
    final t3 = readableShade(text3, grounds);
    // The muted words are a chip's too (a tag's, a count's, a filter's).
    final m = readableShade(muted, onChips);
    final m2 = readableShade(muted2, onChips);
    final d = readableShade(dim, grounds, min: 3);
    if (t == text && t2 == text2 && t3 == text3 && m == muted && m2 == muted2 && d == dim) return this;
    return ZestSurfaces(
      panel: panel,
      sunken: sunken,
      raised: raised,
      raised2: raised2,
      cell: cell,
      chip: chip,
      chipStrong: chipStrong,
      line: line,
      border: border,
      borderStrong: borderStrong,
      text: t,
      text2: t2,
      text3: t3,
      muted: m,
      muted2: m2,
      dim: d,
    );
  }

  /// The ladder for a scheme that does not spell one out: steps between
  /// its background, surface and elevated surface, and text shades between
  /// its subtle text and the background.
  static ZestSurfaces derive({
    required bool isDark,
    required Color background,
    required Color surface,
    required Color surfaceElevated,
    required Color onSurface,
    required Color onSurfaceMuted,
    required Color onBackgroundMuted,
    required Color onBackgroundSubtle,
    required Color border,
    required Color divider,
  }) {
    Color mix(Color a, Color b, double t) => Color.lerp(a, b, t)!;
    Color shift(Color c, double amount) {
      final hsl = HSLColor.fromColor(c);
      final l = (hsl.lightness + (isDark ? amount : -amount)).clamp(0.0, 1.0);
      return hsl.withLightness(l).toColor();
    }

    return ZestSurfaces(
      panel: mix(background, surface, 0.25),
      sunken: isDark ? mix(background, surface, 0.55) : shift(background, 0.03),
      raised: surface,
      raised2: mix(surface, surfaceElevated, 0.45),
      cell: surfaceElevated,
      chip: shift(surfaceElevated, 0.02),
      chipStrong: shift(surfaceElevated, 0.035),
      line: mix(divider, surfaceElevated, 0.5),
      border: divider,
      borderStrong: border,
      text: onSurface,
      text2: onSurfaceMuted,
      text3: onBackgroundMuted,
      muted: onBackgroundSubtle,
      muted2: mix(onBackgroundSubtle, background, 0.18),
      dim: mix(onBackgroundSubtle, background, 0.42),
    );
  }
}
