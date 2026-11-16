import 'package:flutter/material.dart';
import 'package:zestssh/theme/zest_color_scheme.dart';
import 'package:zestssh/theme/zest_surfaces.dart';
import 'package:zestssh/theme/zest_theme.dart';

/// Tokyo Night.
///
/// Background #1A1B26, Foreground #C0CAF5, Blue #7AA2F7 (primary),
/// Red #F7768E, Green #9ECE6A, Purple #BB9AF7, etc.
/// https://github.com/enkia/tokyo-night-vscode-theme
///
/// Its comment colour (#565F89) cannot be read as text on its surfaces. The
/// steps of text between the foreground and it are spelled out here, so that
/// every step can be read on every surface it is drawn on.
const tokyoNightTheme = ZestTheme(
  id: 'tokyo_night',
  name: 'Tokyo Night',
  brightness: Brightness.dark,
  colorScheme: ZestColorScheme(
    id: 'tokyo_night',
    name: 'Tokyo Night',
    isDark: true,
    // Surfaces
    background: Color(0xFF1A1B26),
    surface: Color(0xFF24283B),
    surfaceElevated: Color(0xFF282C42),
    // Content
    onBackground: Color(0xFFC0CAF5),
    onBackgroundMuted: Color(0xFF9DA4C3),
    onBackgroundSubtle: Color(0xFF979DBA),
    onSurface: Color(0xFFC0CAF5),
    onSurfaceMuted: Color(0xFFABB3D6),
    // Brand
    primary: Color(0xFF7AA2F7),
    primaryHover: Color(0xFF89B4FF),
    onPrimary: Color(0xFF1A1B26),
    // Semantic
    success: Color(0xFF9ECE6A),
    warning: Color(0xFFE0AF68),
    error: Color(0xFFF7768E),
    info: Color(0xFF7DCFFF),
    // Borders
    border: Color(0xFF545C7E),
    divider: Color(0xFF343A55),
    // Interactive
    hover: Color(0x0DC0CAF5),
    selected: Color(0x267AA2F7),
    focus: Color(0xFF7AA2F7),
    surfaces: ZestSurfaces(
      panel: Color(0xFF1A1B26),
      sunken: Color(0xFF16161E),
      raised: Color(0xFF24283B),
      raised2: Color(0xFF282C42),
      cell: Color(0xFF2C3148),
      chip: Color(0xFF30364E),
      chipStrong: Color(0xFF343A55),
      line: Color(0xFF2E334B),
      border: Color(0xFF343A55),
      borderStrong: Color(0xFF545C7E),
      text: Color(0xFFC0CAF5),
      text2: Color(0xFFABB3D6),
      text3: Color(0xFF9DA4C3),
      muted: Color(0xFF979DBA),
      muted2: Color(0xFF8187AB),
      dim: Color(0xFF5D658D),
    ),
  ),
);
