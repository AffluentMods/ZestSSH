import 'package:flutter/material.dart';
import 'package:zestssh/theme/zest_color_scheme.dart';
import 'package:zestssh/theme/zest_surfaces.dart';
import 'package:zestssh/theme/zest_theme.dart';

/// Gruvbox Dark, on the original morhetz palette.
///
/// bg #282828, bg1 #3C3836, bg2 #504945, fg #EBDBB2, Orange #FE8019 (primary),
/// Red #FB4934, Green #B8BB26, Yellow #FABD2F, Blue #83A598.
/// https://github.com/morhetz/gruvbox
///
/// Its steps are spelled out from the palette: fg, fg2, then steps that can
/// be read on bg1 and bg2 where fg3, fg4 and the grey cannot (bg4 is the
/// dimmest), so that every step of text can be read on every surface it is
/// drawn on. Its red is a shade lighter for the same reason.
const gruvboxDarkTheme = ZestTheme(
  id: 'gruvbox_dark',
  name: 'Gruvbox Dark',
  brightness: Brightness.dark,
  colorScheme: ZestColorScheme(
    id: 'gruvbox_dark',
    name: 'Gruvbox Dark',
    isDark: true,
    // Surfaces
    background: Color(0xFF282828),
    surface: Color(0xFF3C3836),
    surfaceElevated: Color(0xFF413C3A),
    // Content
    onBackground: Color(0xFFEBDBB2),
    onBackgroundMuted: Color(0xFFC4B8A2),
    onBackgroundSubtle: Color(0xFFBBB09F),
    onSurface: Color(0xFFEBDBB2),
    onSurfaceMuted: Color(0xFFD5C4A1),
    // Brand
    primary: Color(0xFFFE8019),
    primaryHover: Color(0xFFFF9838),
    onPrimary: Color(0xFF282828),
    // Semantic
    success: Color(0xFFB8BB26),
    warning: Color(0xFFFABD2F),
    error: Color(0xFFFC6C5A),
    info: Color(0xFF83A598),
    // Borders
    border: Color(0xFF7C6F64),
    divider: Color(0xFF504945),
    // Interactive
    hover: Color(0x0DEBDBB2),
    selected: Color(0x26FE8019),
    focus: Color(0xFFFE8019),
    surfaces: ZestSurfaces(
      panel: Color(0xFF282828),
      sunken: Color(0xFF1D2021),
      raised: Color(0xFF3C3836),
      raised2: Color(0xFF413C3A),
      cell: Color(0xFF46403D),
      chip: Color(0xFF4B4541),
      chipStrong: Color(0xFF504945),
      line: Color(0xFF48423F),
      border: Color(0xFF504945),
      borderStrong: Color(0xFF7C6F64),
      text: Color(0xFFEBDBB2),
      text2: Color(0xFFD5C4A1),
      text3: Color(0xFFC4B8A2),
      muted: Color(0xFFBBB09F),
      muted2: Color(0xFFA89983),
      dim: Color(0xFF7C6F64),
    ),
  ),
);
