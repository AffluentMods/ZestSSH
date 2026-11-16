import 'package:flutter/material.dart';
import 'package:zestssh/theme/zest_color_scheme.dart'; import 'package:zestssh/theme/zest_surfaces.dart';
import 'package:zestssh/theme/zest_theme.dart';

/// Ember, the default dark theme: the 1.6 warm-charcoal palette.
///
/// Warm off-white text (#E6E3DA) and warm charcoal surfaces (#161619 /
/// #1F1F23) with subtle #2A2A2E borders, brand orange #FF7A1A. 3.0 gives it
/// its name and one status palette (the soft green, amber, red and blue the
/// SFTP view already used), and dark text on the orange, which reads far
/// better than white on it. The id stays 'default_dark' so a saved choice
/// keeps working.
const defaultDarkTheme = ZestTheme(
  id: 'default_dark',
  name: 'Ember',
  brightness: Brightness.dark,
  colorScheme: ZestColorScheme(
    id: 'default_dark',
    name: 'Ember',
    isDark: true,
    // Surfaces - warm charcoal
    background: Color(0xFF0A0A0B),
    surface: Color(0xFF161619),
    surfaceElevated: Color(0xFF1F1F23),
    // Content - warm greys
    onBackground: Color(0xFFE6E3DA),
    onBackgroundMuted: Color(0xFFA9A69E),
    onBackgroundSubtle: Color(0xFF8D8B83),
    onSurface: Color(0xFFE6E3DA),
    onSurfaceMuted: Color(0xFFC9C6BD),
    // Brand
    primary: Color(0xFFFF7A1A),
    primaryHover: Color(0xFFFF9547),
    onPrimary: Color(0xFF161004),
    // Semantic - one palette everywhere
    success: Color(0xFF4F9D69),
    warning: Color(0xFFE6C14A),
    error: Color(0xFFF0736B),
    info: Color(0xFF83A8D8),
    // Borders - subtle warm charcoal
    border: Color(0xFF3A3A3F),
    divider: Color(0xFF2A2A2E),
    // Interactive
    hover: Color(0x0DFFFFFF),
    selected: Color(0x26FF7A1A),
    focus: Color(0xFFFF7A1A),
  surfaces: ZestSurfaces.ember,
  ),
);
