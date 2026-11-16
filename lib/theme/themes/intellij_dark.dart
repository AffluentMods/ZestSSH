import 'package:flutter/material.dart';
import 'package:zestssh/theme/zest_color_scheme.dart';
import 'package:zestssh/theme/zest_surfaces.dart';
import 'package:zestssh/theme/zest_theme.dart';

/// IntelliJ Dark: the dark look of the JetBrains IDEs' current interface,
/// in the greys, the blue, the green, the yellow and the red of its own
/// palette: the editor's #1E1F22 behind everything, panels #2B2D30, #393B40
/// and #43454A above them, the border #4E5157, and the text #DFE1E5 with
/// #CED0D6, #B4B8BF, #9DA0A8, #868A91 and #6F737A below it. The accent is
/// the palette's blue a step under the one of the IDE's buttons (#366ACE
/// for #3574F0), so that the white text on it reads as well as text should;
/// the IDE's own blue is the focus ring and what a button turns to under
/// the pointer. A hovered row is a step between its panels (#33353A), so
/// that every step of text can be read on it.
const intellijDarkTheme = ZestTheme(
  id: 'intellij_dark',
  name: 'IntelliJ Dark',
  brightness: Brightness.dark,
  colorScheme: ZestColorScheme(
    id: 'intellij_dark',
    name: 'IntelliJ Dark',
    isDark: true,
    // Surfaces
    background: Color(0xFF1E1F22),
    surface: Color(0xFF2B2D30),
    surfaceElevated: Color(0xFF2F3135),
    // Content
    onBackground: Color(0xFFDFE1E5),
    onBackgroundMuted: Color(0xFFB4B8BF),
    onBackgroundSubtle: Color(0xFF9DA0A8),
    onSurface: Color(0xFFDFE1E5),
    onSurfaceMuted: Color(0xFFCED0D6),
    // Brand
    primary: Color(0xFF366ACE),
    primaryHover: Color(0xFF3574F0),
    onPrimary: Color(0xFFFFFFFF),
    // Semantic
    success: Color(0xFF5FAD65),
    warning: Color(0xFFF2C55C),
    error: Color(0xFFF75464),
    info: Color(0xFF548AF7),
    // Borders
    border: Color(0xFF4E5157),
    divider: Color(0xFF43454A),
    // Interactive
    hover: Color(0x0DDFE1E5),
    selected: Color(0x263574F0),
    focus: Color(0xFF3574F0),
    surfaces: ZestSurfaces(
      panel: Color(0xFF1E1F22),
      sunken: Color(0xFF18191B),
      raised: Color(0xFF2B2D30),
      raised2: Color(0xFF2F3135),
      cell: Color(0xFF33353A),
      chip: Color(0xFF393B40),
      chipStrong: Color(0xFF43454A),
      line: Color(0xFF393B40),
      border: Color(0xFF43454A),
      borderStrong: Color(0xFF4E5157),
      text: Color(0xFFDFE1E5),
      text2: Color(0xFFCED0D6),
      text3: Color(0xFFB4B8BF),
      muted: Color(0xFF9DA0A8),
      muted2: Color(0xFF868A91),
      dim: Color(0xFF6F737A),
    ),
  ),
);
