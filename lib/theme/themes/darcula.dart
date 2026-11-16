import 'package:flutter/material.dart';
import 'package:zestssh/theme/zest_color_scheme.dart';
import 'package:zestssh/theme/zest_surfaces.dart';
import 'package:zestssh/theme/zest_theme.dart';

/// Darcula: the JetBrains IDEs' classic dark look, in the colours of its
/// own theme and editor scheme: the editor's #2B2B2B behind everything, the
/// gutter's #313335 for cards and the tool windows' #3C3F41 for chips; the
/// separator #515151 and the border #646464; the label text #BBBBBB with
/// the editor's #A9B7C6 and the grey #787878 of its hints. The accent is
/// its link blue (#589DF6); the status colours are its error red (#FF6B68)
/// and the yellow of its function names (#FFC66D), with a green that can
/// be read on its greys. The IDE's own text is dim on its lighter greys,
/// so the first step of text is lighter than its label (#DEDEDE), and the
/// steps in between (a hovered row, the muted text) are placed so that
/// every step of text can be read on every surface it is drawn on.
const darculaTheme = ZestTheme(
  id: 'darcula',
  name: 'Darcula',
  brightness: Brightness.dark,
  colorScheme: ZestColorScheme(
    id: 'darcula',
    name: 'Darcula',
    isDark: true,
    // Surfaces
    background: Color(0xFF2B2B2B),
    surface: Color(0xFF313335),
    surfaceElevated: Color(0xFF353739),
    // Content
    onBackground: Color(0xFFDEDEDE),
    onBackgroundMuted: Color(0xFFA9B7C6),
    onBackgroundSubtle: Color(0xFFA4A7AA),
    onSurface: Color(0xFFDEDEDE),
    onSurfaceMuted: Color(0xFFBBBBBB),
    // Brand
    primary: Color(0xFF589DF6),
    primaryHover: Color(0xFF7AB1F8),
    onPrimary: Color(0xFF15191F),
    // Semantic
    success: Color(0xFF73BD79),
    warning: Color(0xFFFFC66D),
    error: Color(0xFFFF6B68),
    info: Color(0xFF589DF6),
    // Borders
    border: Color(0xFF646464),
    divider: Color(0xFF515151),
    // Interactive
    hover: Color(0x0DDEDEDE),
    selected: Color(0x26589DF6),
    focus: Color(0xFF589DF6),
    surfaces: ZestSurfaces(
      panel: Color(0xFF2B2B2B),
      sunken: Color(0xFF252525),
      raised: Color(0xFF313335),
      raised2: Color(0xFF353739),
      cell: Color(0xFF393C3E),
      chip: Color(0xFF3C3F41),
      chipStrong: Color(0xFF414446),
      line: Color(0xFF3C3F41),
      border: Color(0xFF515151),
      borderStrong: Color(0xFF646464),
      text: Color(0xFFDEDEDE),
      text2: Color(0xFFBBBBBB),
      text3: Color(0xFFA9B7C6),
      muted: Color(0xFFA4A7AA),
      muted2: Color(0xFF909396),
      dim: Color(0xFF787878),
    ),
  ),
);
