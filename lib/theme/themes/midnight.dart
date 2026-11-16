import 'package:flutter/material.dart';
import 'package:zestssh/theme/zest_color_scheme.dart';
import 'package:zestssh/theme/zest_surfaces.dart';
import 'package:zestssh/theme/zest_theme.dart';

/// Midnight: a deep navy dark theme.
///
/// Rich dark blue surfaces with a cool blue-white text palette, and a bright
/// sky blue accent with the navy of the background written on it (white on
/// that blue could not be read). Its steps are spelled out, so that every
/// step of text can be read on every surface it is drawn on.
const midnightTheme = ZestTheme(
  id: 'midnight',
  name: 'Midnight',
  brightness: Brightness.dark,
  colorScheme: ZestColorScheme(
    id: 'midnight',
    name: 'Midnight',
    isDark: true,
    // Surfaces
    background: Color(0xFF0B1021),
    surface: Color(0xFF131A2E),
    surfaceElevated: Color(0xFF171E35),
    // Content
    onBackground: Color(0xFFDDE3F0),
    onBackgroundMuted: Color(0xFFA4AEC6),
    onBackgroundSubtle: Color(0xFF828EAC),
    onSurface: Color(0xFFDDE3F0),
    onSurfaceMuted: Color(0xFFC2CADC),
    // Brand
    primary: Color(0xFF5B9CF5),
    primaryHover: Color(0xFF82B6FF),
    onPrimary: Color(0xFF0B1021),
    // Semantic
    success: Color(0xFF4EC07A),
    warning: Color(0xFFE5A840),
    error: Color(0xFFE85B6E),
    info: Color(0xFF5B9CF5),
    // Borders
    border: Color(0xFF33405F),
    divider: Color(0xFF222C4A),
    // Interactive
    hover: Color(0x0DFFFFFF),
    selected: Color(0x265B9CF5),
    focus: Color(0xFF5B9CF5),
    surfaces: ZestSurfaces(
      panel: Color(0xFF0B1021),
      sunken: Color(0xFF0F1527),
      raised: Color(0xFF131A2E),
      raised2: Color(0xFF171E35),
      cell: Color(0xFF1A233C),
      chip: Color(0xFF1E2843),
      chipStrong: Color(0xFF222C4A),
      line: Color(0xFF1C253F),
      border: Color(0xFF222C4A),
      borderStrong: Color(0xFF33405F),
      text: Color(0xFFDDE3F0),
      text2: Color(0xFFC2CADC),
      text3: Color(0xFFA4AEC6),
      muted: Color(0xFF828EAC),
      muted2: Color(0xFF6C7B9E),
      dim: Color(0xFF4E5A76),
    ),
  ),
);
