import 'package:flutter/material.dart';
import 'package:zestssh/theme/zest_color_scheme.dart'; import 'package:zestssh/theme/zest_surfaces.dart';
import 'package:zestssh/theme/zest_theme.dart';

/// Graphite: Ember's layout in cooler blue-grey charcoal, for people who
/// prefer a neutral dark. Same brand orange and the same status palette,
/// tuned for the cooler surfaces.
const graphiteTheme = ZestTheme(
  id: 'graphite',
  name: 'Graphite',
  brightness: Brightness.dark,
  colorScheme: ZestColorScheme(
    id: 'graphite',
    name: 'Graphite',
    isDark: true,
    // Surfaces - cool charcoal
    background: Color(0xFF08090C),
    surface: Color(0xFF161920),
    surfaceElevated: Color(0xFF1D2129),
    // Content - cool greys
    onBackground: Color(0xFFE9E7E2),
    onBackgroundMuted: Color(0xFFA7ABB3),
    onBackgroundSubtle: Color(0xFF8B919C),
    onSurface: Color(0xFFE9E7E2),
    onSurfaceMuted: Color(0xFFC6C8CD),
    // Brand
    primary: Color(0xFFFF7A1A),
    primaryHover: Color(0xFFFF9547),
    onPrimary: Color(0xFF161004),
    // Semantic
    success: Color(0xFF4FAE78),
    warning: Color(0xFFE6C14A),
    error: Color(0xFFF07178),
    info: Color(0xFF7AA7E0),
    // Borders
    border: Color(0xFF363C48),
    divider: Color(0xFF272C36),
    // Interactive
    hover: Color(0x0DFFFFFF),
    selected: Color(0x26FF7A1A),
    focus: Color(0xFFFF7A1A),
  surfaces: ZestSurfaces.graphite,
  ),
);
