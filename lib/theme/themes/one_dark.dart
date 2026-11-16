import 'package:flutter/material.dart';
import 'package:zestssh/theme/zest_color_scheme.dart';
import 'package:zestssh/theme/zest_surfaces.dart';
import 'package:zestssh/theme/zest_theme.dart';

/// One Dark: the interface colours of Atom's One Dark, worked out from the
/// formulas of its one-dark-ui package for the editor background the theme
/// is known by (#282C34): the app background #21252B, panes #282C34, its
/// highlighted row #31363F and its buttons #353B45, the text #9DA5B4 and its
/// highlight #D7DAE0, the accent #568AF2 with the dark text Atom puts on it.
/// The status colours and the greys of the text are its syntax colours
/// (green #98C379, gold #E5C07B, red #E06C75, blue #61AFEF; #ABB2BF,
/// #828997). The steps in between (a hovered row, the muted text) are
/// placed so that every step of text can be read on every surface it is
/// drawn on.
const oneDarkTheme = ZestTheme(
  id: 'one_dark',
  name: 'One Dark',
  brightness: Brightness.dark,
  colorScheme: ZestColorScheme(
    id: 'one_dark',
    name: 'One Dark',
    isDark: true,
    // Surfaces
    background: Color(0xFF21252B),
    surface: Color(0xFF282C34),
    surfaceElevated: Color(0xFF2B3038),
    // Content
    onBackground: Color(0xFFD7DAE0),
    onBackgroundMuted: Color(0xFF9DA5B4),
    onBackgroundSubtle: Color(0xFF959EAD),
    onSurface: Color(0xFFD7DAE0),
    onSurfaceMuted: Color(0xFFABB2BF),
    // Brand: Atom's accent, with the dark text it carries
    primary: Color(0xFF568AF2),
    primaryHover: Color(0xFF759EF2),
    onPrimary: Color(0xFF001133),
    // Semantic
    success: Color(0xFF98C379),
    warning: Color(0xFFE5C07B),
    error: Color(0xFFE06C75),
    info: Color(0xFF61AFEF),
    // Borders
    border: Color(0xFF4B5263),
    divider: Color(0xFF3A3F4B),
    // Interactive
    hover: Color(0x0DD7DAE0),
    selected: Color(0x26568AF2),
    focus: Color(0xFF568AF2),
    surfaces: ZestSurfaces(
      panel: Color(0xFF21252B),
      sunken: Color(0xFF1B1D23),
      raised: Color(0xFF282C34),
      raised2: Color(0xFF2B3038),
      cell: Color(0xFF2E333C),
      chip: Color(0xFF31363F),
      chipStrong: Color(0xFF353B45),
      line: Color(0xFF353B45),
      border: Color(0xFF3A3F4B),
      borderStrong: Color(0xFF4B5263),
      text: Color(0xFFD7DAE0),
      text2: Color(0xFFABB2BF),
      text3: Color(0xFF9DA5B4),
      muted: Color(0xFF959EAD),
      muted2: Color(0xFF828997),
      dim: Color(0xFF636A78),
    ),
  ),
);
