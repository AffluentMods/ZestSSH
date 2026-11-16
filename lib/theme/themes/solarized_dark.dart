import 'package:flutter/material.dart';
import 'package:zestssh/theme/zest_color_scheme.dart';
import 'package:zestssh/theme/zest_surfaces.dart';
import 'package:zestssh/theme/zest_theme.dart';

/// Solarized Dark, on Ethan Schoonover's palette.
///
/// Base03 #002B36 (background), Base02 #073642 (cards),
/// Blue #268BD2 (primary), Yellow #B58900, Red #DC322F, etc.
/// https://ethanschoonover.com/solarized/
///
/// The content tones of the palette (base01 to base1) are low in contrast by
/// design: as the text of an interface they could not be read on its cards.
/// The steps of text are spelled out here in the same hue, lighter, so that
/// every step can be read on every surface it is drawn on; base01 is the
/// dimmest of them. Its red and its blue for information are lighter for the
/// same reason, and what is written on the blue is dark. The terminal theme
/// of this name keeps the palette as it is.
const solarizedDarkTheme = ZestTheme(
  id: 'solarized_dark',
  name: 'Solarized Dark',
  brightness: Brightness.dark,
  colorScheme: ZestColorScheme(
    id: 'solarized_dark',
    name: 'Solarized Dark',
    isDark: true,
    // Surfaces
    background: Color(0xFF002B36),
    surface: Color(0xFF073642),
    surfaceElevated: Color(0xFF093B48),
    // Content
    onBackground: Color(0xFFC6CDCD),
    onBackgroundMuted: Color(0xFFA2B4B8),
    onBackgroundSubtle: Color(0xFF98ACB2),
    onSurface: Color(0xFFC6CDCD),
    onSurfaceMuted: Color(0xFFABB9BD),
    // Brand
    primary: Color(0xFF268BD2),
    primaryHover: Color(0xFF2AA198),
    onPrimary: Color(0xFF001B22),
    // Semantic
    success: Color(0xFF859900),
    warning: Color(0xFFB58900),
    error: Color(0xFFE66C69),
    info: Color(0xFF3998DB),
    // Borders
    border: Color(0xFF586E75),
    divider: Color(0xFF1B5262),
    // Interactive
    hover: Color(0x0D839496),
    selected: Color(0x26268BD2),
    focus: Color(0xFF268BD2),
    surfaces: ZestSurfaces(
      panel: Color(0xFF002B36),
      sunken: Color(0xFF00222B),
      raised: Color(0xFF073642),
      raised2: Color(0xFF093B48),
      cell: Color(0xFF0A404E),
      chip: Color(0xFF0C4554),
      chipStrong: Color(0xFF0E4A5A),
      line: Color(0xFF134755),
      border: Color(0xFF1B5262),
      borderStrong: Color(0xFF586E75),
      text: Color(0xFFC6CDCD),
      text2: Color(0xFFABB9BD),
      text3: Color(0xFFA2B4B8),
      muted: Color(0xFF98ACB2),
      muted2: Color(0xFF7E979E),
      dim: Color(0xFF5C737A),
    ),
  ),
);
