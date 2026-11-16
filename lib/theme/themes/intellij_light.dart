import 'package:flutter/material.dart';
import 'package:zestssh/theme/zest_color_scheme.dart';
import 'package:zestssh/theme/zest_surfaces.dart';
import 'package:zestssh/theme/zest_theme.dart';

/// IntelliJ Light: the light look of the JetBrains IDEs' current interface,
/// in the greys, the blue, the green, the yellow and the red of its own
/// palette: panels #F7F8FA with white cards, #EBECF0 and #DFE1E5 above
/// them, the border #C9CCD6, and black text with #27282E, #494B57, #5A5D6B
/// and #6C707E below it. The accent is the palette's blue a step under the
/// one of the IDE's buttons (#3369D6 for #3574F0), so that the white text
/// on it reads as well as text should; the IDE's own blue is the focus
/// ring. The dimmest text is a shade under the IDE's (#9EA3B3 for #A8ADBD),
/// which could not be made out on its greys.
const intellijLightTheme = ZestTheme(
  id: 'intellij_light',
  name: 'IntelliJ Light',
  brightness: Brightness.light,
  colorScheme: ZestColorScheme(
    id: 'intellij_light',
    name: 'IntelliJ Light',
    isDark: false,
    // Surfaces
    background: Color(0xFFF7F8FA),
    surface: Color(0xFFFFFFFF),
    surfaceElevated: Color(0xFFF7F8FA),
    // Content
    onBackground: Color(0xFF000000),
    onBackgroundMuted: Color(0xFF5A5D6B),
    onBackgroundSubtle: Color(0xFF6C707E),
    onSurface: Color(0xFF000000),
    onSurfaceMuted: Color(0xFF27282E),
    // Brand
    primary: Color(0xFF3369D6),
    primaryHover: Color(0xFF315FBD),
    onPrimary: Color(0xFFFFFFFF),
    // Semantic
    success: Color(0xFF1F8039),
    warning: Color(0xFFA46704),
    error: Color(0xFFCC3645),
    info: Color(0xFF315FBD),
    // Borders
    border: Color(0xFFC9CCD6),
    divider: Color(0xFFDFE1E5),
    // Interactive
    hover: Color(0x0A000000),
    selected: Color(0x1F3574F0),
    focus: Color(0xFF3574F0),
    surfaces: ZestSurfaces(
      panel: Color(0xFFF7F8FA),
      sunken: Color(0xFFEBECF0),
      raised: Color(0xFFFFFFFF),
      raised2: Color(0xFFF7F8FA),
      cell: Color(0xFFEBECF0),
      chip: Color(0xFFEBECF0),
      chipStrong: Color(0xFFDFE1E5),
      line: Color(0xFFEBECF0),
      border: Color(0xFFDFE1E5),
      borderStrong: Color(0xFFC9CCD6),
      text: Color(0xFF000000),
      text2: Color(0xFF27282E),
      text3: Color(0xFF494B57),
      muted: Color(0xFF5A5D6B),
      muted2: Color(0xFF6C707E),
      dim: Color(0xFF9EA3B3),
    ),
  ),
);
