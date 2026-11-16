import 'package:flutter/material.dart';
import 'package:zestssh/theme/zest_color_scheme.dart';
import 'package:zestssh/theme/zest_surfaces.dart';
import 'package:zestssh/theme/zest_theme.dart';

/// Dracula, in the colours of its palette.
///
/// Background #282A36, Current Line #44475A, Foreground #F8F8F2,
/// Purple #BD93F9, Pink #FF79C6, Green #50FA7B, etc.
/// https://draculatheme.com/contribute
///
/// The palette has one quiet colour, its Comment (#6272A4), which cannot be
/// read as text on its surfaces. The steps of text between the Foreground and
/// the Comment are spelled out here, lighter tints of the Comment, so that
/// every step can be read on every surface it is drawn on; the Comment itself
/// is the dimmest of them. Its red is a shade lighter for the same reason.
const draculaTheme = ZestTheme(
  id: 'dracula',
  name: 'Dracula',
  brightness: Brightness.dark,
  colorScheme: ZestColorScheme(
    id: 'dracula',
    name: 'Dracula',
    isDark: true,
    // Surfaces
    background: Color(0xFF282A36),
    surface: Color(0xFF343746),
    surfaceElevated: Color(0xFF383B4B),
    // Content
    onBackground: Color(0xFFF8F8F2),
    onBackgroundMuted: Color(0xFFBFC6D7),
    onBackgroundSubtle: Color(0xFFA5AFCB),
    onSurface: Color(0xFFF8F8F2),
    onSurfaceMuted: Color(0xFFD9DDE3),
    // Brand
    primary: Color(0xFFBD93F9),
    primaryHover: Color(0xFFD6ACFF),
    onPrimary: Color(0xFF282A36),
    // Semantic
    success: Color(0xFF50FA7B),
    warning: Color(0xFFF1FA8C),
    error: Color(0xFFFF6565),
    info: Color(0xFF8BE9FD),
    // Borders
    border: Color(0xFF6272A4),
    divider: Color(0xFF4D5066),
    // Interactive
    hover: Color(0x0DF8F8F2),
    selected: Color(0x26BD93F9),
    focus: Color(0xFFBD93F9),
    surfaces: ZestSurfaces(
      panel: Color(0xFF282A36),
      sunken: Color(0xFF21222C),
      raised: Color(0xFF343746),
      raised2: Color(0xFF383B4B),
      cell: Color(0xFF3C3F50),
      chip: Color(0xFF404355),
      chipStrong: Color(0xFF44475A),
      line: Color(0xFF434659),
      border: Color(0xFF4D5066),
      borderStrong: Color(0xFF6272A4),
      text: Color(0xFFF8F8F2),
      text2: Color(0xFFD9DDE3),
      text3: Color(0xFFBFC6D7),
      muted: Color(0xFFA5AFCB),
      muted2: Color(0xFF8D99BD),
      dim: Color(0xFF6474A5),
    ),
  ),
);
