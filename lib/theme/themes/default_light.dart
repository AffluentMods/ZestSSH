import 'package:flutter/material.dart';
import 'package:zestssh/theme/zest_color_scheme.dart'; import 'package:zestssh/theme/zest_surfaces.dart';
import 'package:zestssh/theme/zest_theme.dart';

/// Daylight, the light theme: cool light greys, white cards, the brand
/// orange with dark text on it, and status colours dark enough to read on
/// white. The id stays 'default_light' so a saved choice keeps working.
const defaultLightTheme = ZestTheme(
  id: 'default_light',
  name: 'Daylight',
  brightness: Brightness.light,
  colorScheme: ZestColorScheme(
    id: 'default_light',
    name: 'Daylight',
    isDark: false,
    // Surfaces
    background: Color(0xFFF5F6F8),
    surface: Color(0xFFFFFFFF),
    surfaceElevated: Color(0xFFFFFFFF),
    // Content
    onBackground: Color(0xFF15171C),
    onBackgroundMuted: Color(0xFF5F6573),
    // At 4.5:1 or more on every surface of the theme, its chips included
    // (it was 4.3 on the page and 3.8 on a chip: 4.0, the accessibility
    // pass).
    onBackgroundSubtle: Color(0xFF626876),
    onSurface: Color(0xFF15171C),
    onSurfaceMuted: Color(0xFF343944),
    // Brand
    primary: Color(0xFFFF7A1A),
    primaryHover: Color(0xFFE05A00),
    onPrimary: Color(0xFF161004),
    // Semantic
    // A green that reads as words on the page (#2C8651 was 4.2:1).
    success: Color(0xFF287A4A),
    // Amber that reads on white (it was olive).
    warning: Color(0xFF8A5A00),
    error: Color(0xFFC4403A),
    info: Color(0xFF2F63B0),
    // Borders
    border: Color(0xFFC1C6CF),
    divider: Color(0xFFD8DBE1),
    // Interactive
    // A quiet but visible wash on the white cards (at 4% it was all but
    // white).
    hover: Color(0x0F15171C),
    selected: Color(0x1FFF7A1A),
    focus: Color(0xFFFF7A1A),
  surfaces: ZestSurfaces.daylight,
  ),
);
