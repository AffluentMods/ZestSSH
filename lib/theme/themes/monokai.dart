import 'package:flutter/material.dart';
import 'package:zestssh/theme/zest_color_scheme.dart';
import 'package:zestssh/theme/zest_surfaces.dart';
import 'package:zestssh/theme/zest_theme.dart';

/// Monokai, in the colours of the classic scheme.
///
/// Background #272822, Foreground #F8F8F2, Pink #F92672,
/// Green #A6E22E, Yellow #F4BF75, Purple #AE81FF, Blue #66D9EF.
/// https://monokai.pro/
///
/// Its one quiet colour, the comment's #75715E, cannot be read as text on its
/// surfaces. The steps of text between the foreground and it are spelled out
/// here, lighter tints of it, so that every step can be read on every surface
/// it is drawn on. What is written on the pink is dark (white on it could not
/// be read), and the pink of an error is a shade lighter.
const monokaiTheme = ZestTheme(
  id: 'monokai',
  name: 'Monokai Pro',
  brightness: Brightness.dark,
  colorScheme: ZestColorScheme(
    id: 'monokai',
    name: 'Monokai Pro',
    isDark: true,
    // Surfaces
    background: Color(0xFF272822),
    surface: Color(0xFF2D2E27),
    surfaceElevated: Color(0xFF34342D),
    // Content
    onBackground: Color(0xFFF8F8F2),
    onBackgroundMuted: Color(0xFFC8C6B9),
    onBackgroundSubtle: Color(0xFFACA998),
    onSurface: Color(0xFFF8F8F2),
    onSurfaceMuted: Color(0xFFDEDDD3),
    // Brand
    primary: Color(0xFFF92672),
    primaryHover: Color(0xFFFF4D8D),
    onPrimary: Color(0xFF161004),
    // Semantic
    success: Color(0xFFA6E22E),
    warning: Color(0xFFF4BF75),
    error: Color(0xFFFA538F),
    info: Color(0xFF66D9EF),
    // Borders
    border: Color(0xFF75715E),
    divider: Color(0xFF49483E),
    // Interactive
    hover: Color(0x0DF8F8F2),
    selected: Color(0x26F92672),
    focus: Color(0xFFF92672),
    surfaces: ZestSurfaces(
      panel: Color(0xFF272822),
      sunken: Color(0xFF1E1F1C),
      raised: Color(0xFF2D2E27),
      raised2: Color(0xFF34342D),
      cell: Color(0xFF3B3B33),
      chip: Color(0xFF424238),
      chipStrong: Color(0xFF49483E),
      line: Color(0xFF3E3E35),
      border: Color(0xFF49483E),
      borderStrong: Color(0xFF75715E),
      text: Color(0xFFF8F8F2),
      text2: Color(0xFFDEDDD3),
      text3: Color(0xFFC8C6B9),
      muted: Color(0xFFACA998),
      muted2: Color(0xFF97937E),
      dim: Color(0xFF73705D),
    ),
  ),
);
