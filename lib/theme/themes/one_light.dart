import 'package:flutter/material.dart';
import 'package:zestssh/theme/zest_color_scheme.dart';
import 'package:zestssh/theme/zest_surfaces.dart';
import 'package:zestssh/theme/zest_theme.dart';

/// One Light: the interface colours of Atom's One Light, worked out from the
/// formulas of its one-light-ui package for the editor background the theme
/// is known by (#FAFAFA): the app background #EAEAEB, panes #FAFAFA, the
/// grey of its borders and selected rows #DBDBDC, the text #232324 and
/// #383A42. The accent is the blue its formulas give for accent text
/// (#304EE2), which carries white. The status colours are its syntax
/// colours where those can be read on white (gold #986801, red #CA1243),
/// and a darker green and blue of the same hues where they cannot (its
/// green #50A14F and blue #4078F2 are too light for small text). The steps
/// in between (a card on the pane, the muted text) are placed so that a
/// card stands out from the pane and every step of text can be read on
/// every surface it is drawn on.
const oneLightTheme = ZestTheme(
  id: 'one_light',
  name: 'One Light',
  brightness: Brightness.light,
  colorScheme: ZestColorScheme(
    id: 'one_light',
    name: 'One Light',
    isDark: false,
    // Surfaces
    background: Color(0xFFEAEAEB),
    surface: Color(0xFFFAFAFA),
    surfaceElevated: Color(0xFFF2F2F3),
    // Content
    onBackground: Color(0xFF232324),
    onBackgroundMuted: Color(0xFF5C5F6B),
    onBackgroundSubtle: Color(0xFF696C77),
    onSurface: Color(0xFF232324),
    onSurfaceMuted: Color(0xFF383A42),
    // Brand
    primary: Color(0xFF304EE2),
    primaryHover: Color(0xFF2440C4),
    onPrimary: Color(0xFFFFFFFF),
    // Semantic
    success: Color(0xFF2F7F33),
    warning: Color(0xFF986801),
    error: Color(0xFFCA1243),
    info: Color(0xFF3466D8),
    // Borders
    border: Color(0xFFBBBBBE),
    divider: Color(0xFFCFCFD1),
    // Interactive
    hover: Color(0x0A232324),
    selected: Color(0x1F304EE2),
    focus: Color(0xFF304EE2),
    surfaces: ZestSurfaces(
      panel: Color(0xFFEAEAEB),
      sunken: Color(0xFFE2E2E3),
      raised: Color(0xFFFAFAFA),
      raised2: Color(0xFFF2F2F3),
      cell: Color(0xFFDCDCDD),
      chip: Color(0xFFDBDBDC),
      chipStrong: Color(0xFFD4D4D6),
      line: Color(0xFFDBDBDC),
      border: Color(0xFFCFCFD1),
      borderStrong: Color(0xFFBBBBBE),
      text: Color(0xFF232324),
      text2: Color(0xFF383A42),
      text3: Color(0xFF4F525E),
      muted: Color(0xFF5C5F6B),
      muted2: Color(0xFF696C77),
      dim: Color(0xFF98999F),
    ),
  ),
);
