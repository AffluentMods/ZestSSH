import 'package:flutter/material.dart';
import 'package:zestssh/theme/zest_color_scheme.dart';
import 'package:zestssh/theme/zest_surfaces.dart';
import 'package:zestssh/theme/zest_theme.dart';

/// Nord, in the colours of its palette.
///
/// Polar Night (#2E3440 .. #4C566A), Snow Storm (#D8DEE9 .. #ECEFF4),
/// Frost (#8FBCBB, #88C0D0, #81A1C1, #5E81AC),
/// Aurora (red/orange/yellow/green/purple).
/// https://www.nordtheme.com/docs/colors-and-palettes
///
/// Between the Snow Storm whites and the Polar Night greys the palette has
/// nothing for quiet text: nord3 on a card is all but invisible. The steps of
/// text below nord4 are spelled out here, lighter tints of nord3, so that
/// every step can be read on every surface it is drawn on. Its red and its
/// blue for information are lighter than nord11 and nord9 for the same reason.
const nordTheme = ZestTheme(
  id: 'nord',
  name: 'Nord',
  brightness: Brightness.dark,
  colorScheme: ZestColorScheme(
    id: 'nord',
    name: 'Nord',
    isDark: true,
    // Surfaces
    background: Color(0xFF2E3440),
    surface: Color(0xFF3B4252),
    surfaceElevated: Color(0xFF3F4758),
    // Content
    onBackground: Color(0xFFECEFF4),
    onBackgroundMuted: Color(0xFFC4CBD6),
    onBackgroundSubtle: Color(0xFFBAC1CE),
    onSurface: Color(0xFFECEFF4),
    onSurfaceMuted: Color(0xFFD8DEE9),
    // Brand
    primary: Color(0xFF88C0D0),
    primaryHover: Color(0xFF8FBCBB),
    onPrimary: Color(0xFF2E3440),
    // Semantic
    success: Color(0xFFA3BE8C),
    warning: Color(0xFFEBCB8B),
    error: Color(0xFFD5989D),
    info: Color(0xFF8EABC7),
    // Borders
    border: Color(0xFF616E88),
    divider: Color(0xFF4C566A),
    // Interactive
    hover: Color(0x0DECEFF4),
    selected: Color(0x2688C0D0),
    focus: Color(0xFF88C0D0),
    surfaces: ZestSurfaces(
      panel: Color(0xFF2E3440),
      sunken: Color(0xFF272C36),
      raised: Color(0xFF3B4252),
      raised2: Color(0xFF3F4758),
      cell: Color(0xFF444C5E),
      chip: Color(0xFF485164),
      chipStrong: Color(0xFF4C566A),
      line: Color(0xFF454E60),
      border: Color(0xFF4C566A),
      borderStrong: Color(0xFF616E88),
      text: Color(0xFFECEFF4),
      text2: Color(0xFFD8DEE9),
      text3: Color(0xFFC4CBD6),
      muted: Color(0xFFBAC1CE),
      muted2: Color(0xFFA1AABB),
      dim: Color(0xFF76839C),
    ),
  ),
);
