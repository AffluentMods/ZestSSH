import 'package:flutter/material.dart';
import 'package:zestssh/theme/zest_color_scheme.dart';
import 'package:zestssh/theme/zest_surfaces.dart';
import 'package:zestssh/theme/zest_theme.dart';

/// Catppuccin Mocha, the darkest Catppuccin flavour.
///
/// Base #1E1E2E, Surface0 #313244, Text #CDD6F4,
/// Mauve #CBA6F7 (primary), Green #A6E3A1, Red #F38BA8, etc.
/// https://catppuccin.com/palette
///
/// Its steps are spelled out from the palette: Text, Subtext1, then steps
/// that can be read on Surface0 and Surface1 where Subtext0 and the Overlays
/// cannot (Overlay2 is the section label, Overlay0 the dimmest), so that
/// every step of text can be read on every surface it is drawn on.
const catppuccinMochaTheme = ZestTheme(
  id: 'catppuccin_mocha',
  name: 'Catppuccin Mocha',
  brightness: Brightness.dark,
  colorScheme: ZestColorScheme(
    id: 'catppuccin_mocha',
    name: 'Catppuccin Mocha',
    isDark: true,
    // Surfaces
    background: Color(0xFF1E1E2E),
    surface: Color(0xFF313244),
    surfaceElevated: Color(0xFF36374A),
    // Content
    onBackground: Color(0xFFCDD6F4),
    onBackgroundMuted: Color(0xFFB0B6CC),
    onBackgroundSubtle: Color(0xFFA7ACC0),
    onSurface: Color(0xFFCDD6F4),
    onSurfaceMuted: Color(0xFFBAC2DE),
    // Brand
    primary: Color(0xFFCBA6F7),
    primaryHover: Color(0xFFDDBBFF),
    onPrimary: Color(0xFF1E1E2E),
    // Semantic
    success: Color(0xFFA6E3A1),
    warning: Color(0xFFF9E2AF),
    error: Color(0xFFF38BA8),
    info: Color(0xFF89DCEB),
    // Borders
    border: Color(0xFF6C7086),
    divider: Color(0xFF45475A),
    // Interactive
    hover: Color(0x0DCDD6F4),
    selected: Color(0x26CBA6F7),
    focus: Color(0xFFCBA6F7),
    surfaces: ZestSurfaces(
      panel: Color(0xFF1E1E2E),
      sunken: Color(0xFF181825),
      raised: Color(0xFF313244),
      raised2: Color(0xFF36374A),
      cell: Color(0xFF3B3C4F),
      chip: Color(0xFF404255),
      chipStrong: Color(0xFF45475A),
      line: Color(0xFF3D3F51),
      border: Color(0xFF45475A),
      borderStrong: Color(0xFF6C7086),
      text: Color(0xFFCDD6F4),
      text2: Color(0xFFBAC2DE),
      text3: Color(0xFFB0B6CC),
      muted: Color(0xFFA7ACC0),
      muted2: Color(0xFF9399B2),
      dim: Color(0xFF6C7086),
    ),
  ),
);
