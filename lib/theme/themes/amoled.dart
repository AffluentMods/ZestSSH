import 'package:flutter/material.dart';
import 'package:zestssh/theme/zest_color_scheme.dart';
import 'package:zestssh/theme/zest_surfaces.dart';
import 'package:zestssh/theme/zest_theme.dart';

/// True-black AMOLED theme.
///
/// Pure #000000 background for maximum battery savings on OLED screens.
/// Uses the ZestSSH orange accent (#FF7A1A, with dark text on it) and the
/// shared status palette on ultra-dark surfaces. Its greys are spelled out
/// step by step, so that every step of text can be read on every surface it
/// is drawn on (its muted text was too dim on its cards).
const amoledTheme = ZestTheme(
  id: 'amoled',
  name: 'AMOLED Black',
  brightness: Brightness.dark,
  colorScheme: ZestColorScheme(
    id: 'amoled',
    name: 'AMOLED Black',
    isDark: true,
    // Surfaces
    background: Color(0xFF000000),
    surface: Color(0xFF0D0D0D),
    surfaceElevated: Color(0xFF121212),
    // Content
    onBackground: Color(0xFFE0E0E0),
    onBackgroundMuted: Color(0xFFA1A1A1),
    onBackgroundSubtle: Color(0xFF838383),
    onSurface: Color(0xFFE0E0E0),
    onSurfaceMuted: Color(0xFFBDBDBD),
    // Brand
    primary: Color(0xFFFF7A1A),
    primaryHover: Color(0xFFFF9547),
    onPrimary: Color(0xFF161004),
    // Semantic
    success: Color(0xFF4F9D69),
    warning: Color(0xFFE6C14A),
    error: Color(0xFFF0736B),
    info: Color(0xFF83A8D8),
    // Borders
    border: Color(0xFF3A3A3A),
    divider: Color(0xFF262626),
    // Interactive
    hover: Color(0x0DFFFFFF),
    selected: Color(0x26FF7A1A),
    focus: Color(0xFFFF7A1A),
    surfaces: ZestSurfaces(
      panel: Color(0xFF000000),
      sunken: Color(0xFF070707),
      raised: Color(0xFF0D0D0D),
      raised2: Color(0xFF121212),
      cell: Color(0xFF161616),
      chip: Color(0xFF1A1A1A),
      chipStrong: Color(0xFF1F1F1F),
      line: Color(0xFF1C1C1C),
      border: Color(0xFF262626),
      borderStrong: Color(0xFF3A3A3A),
      text: Color(0xFFE0E0E0),
      text2: Color(0xFFBDBDBD),
      text3: Color(0xFFA1A1A1),
      muted: Color(0xFF838383),
      muted2: Color(0xFF707070),
      dim: Color(0xFF515151),
    ),
  ),
);
