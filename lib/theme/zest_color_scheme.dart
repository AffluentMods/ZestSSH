import 'package:flutter/material.dart'; import 'package:zestssh/theme/zest_surfaces.dart';

/// Design-token colour scheme for ZestSSH app themes.
///
/// Each [ZestTheme] carries one of these. Unlike the terminal colour scheme
/// (which maps to ANSI colours), this defines the **app chrome** palette:
/// surfaces, text, brand accent, semantic colours, borders, and interactive
/// states.
class ZestColorScheme {
  /// Machine-readable identifier (e.g. 'default_dark', 'dracula').
  final String id;

  /// Human-readable display name (e.g. 'Default Dark', 'Dracula').
  final String name;

  /// Whether this scheme is considered a dark theme.
  final bool isDark;

  // ── Surfaces ──────────────────────────────────────────────────

  /// Root scaffold / window background.
  final Color background;

  /// Card / sheet / dialog surface.
  final Color surface;

  /// Elevated surface (e.g. floating panels, tooltips).
  final Color surfaceElevated;

  // ── Content ───────────────────────────────────────────────────

  /// Primary text on [background].
  final Color onBackground;

  /// Secondary / muted text on [background].
  final Color onBackgroundMuted;

  /// Tertiary / subtle text on [background] (hints, placeholders).
  final Color onBackgroundSubtle;

  /// Primary text on [surface].
  final Color onSurface;

  /// Muted text on [surface].
  final Color onSurfaceMuted;

  // ── Brand ─────────────────────────────────────────────────────

  /// Primary brand colour (buttons, active indicators).
  final Color primary;

  /// Hover / pressed variant of [primary].
  final Color primaryHover;

  /// Text / icon colour on top of [primary].
  final Color onPrimary;

  /// Optional user-editable SECONDARY accent (Material secondary/tertiary +
  /// [AppColors.v3AccentSecondary]). Null on built-in themes and on schemes
  /// persisted before secondary existed - see [effectiveSecondary].
  final Color? secondary;

  /// Optional hover/variant of [secondary]. See [effectiveSecondaryHover].
  final Color? secondaryHover;

  /// Optional user-editable ACCENT - the frozen 1.7 component brand
  /// (`ZestColors.accentPrimary` / `ZestTokens.brand`, historically
  /// `#FF7A1A`). Distinct from [primary]. Null on built-in / legacy schemes,
  /// in which case it resolves to the historical brand - see [effectiveAccent].
  final Color? accent;

  // ── Semantic ──────────────────────────────────────────────────

  /// Success indicator.
  final Color success;

  /// Warning indicator.
  final Color warning;

  /// Error / destructive indicator.
  final Color error;

  /// Informational indicator.
  final Color info;

  // ── Borders ───────────────────────────────────────────────────

  /// Visible border (input outlines, card strokes).
  final Color border;

  /// Subtle divider between sections.
  final Color divider;

  // ── Interactive ───────────────────────────────────────────────

  /// Hover overlay colour (typically semi-transparent).
  final Color hover;

  /// Selected-item highlight.
  final Color selected;

  /// Focus ring / border colour.
  final Color focus;

  /// The full surface and text ladder, when the theme spells it out (the
  /// built-in Ember, Graphite and Daylight). Null for every other theme,
  /// which gets one worked out from its colours ([effectiveSurfaces]).
  final ZestSurfaces? surfaces;

  const ZestColorScheme({
    required this.id,
    required this.name,
    required this.isDark,
    required this.background,
    required this.surface,
    required this.surfaceElevated,
    required this.onBackground,
    required this.onBackgroundMuted,
    required this.onBackgroundSubtle,
    required this.onSurface,
    required this.onSurfaceMuted,
    required this.primary,
    required this.primaryHover,
    required this.onPrimary,
    this.secondary,
    this.secondaryHover,
    this.accent,
    required this.success,
    required this.warning,
    required this.error,
    required this.info,
    required this.border,
    required this.divider,
    required this.hover,
    required this.selected,
    required this.focus,
  this.surfaces,
  });

  /// The ladder screens paint with: [surfaces] when given, else derived.
  ZestSurfaces get effectiveSurfaces =>
      surfaces ??
      ZestSurfaces.derive(
        isDark: isDark,
        background: background,
        surface: surface,
        surfaceElevated: surfaceElevated,
        onSurface: onSurface,
        onSurfaceMuted: onSurfaceMuted,
        onBackgroundMuted: onBackgroundMuted,
        onBackgroundSubtle: onBackgroundSubtle,
        border: border,
        divider: divider, );

  /// This scheme as the app paints it: every colour that is read (text,
  /// and the status colours, which say things in words as well as in dots)
  /// readable on every ground it is drawn on, WCAG AA (the 4.0 accessibility
  /// pass). Body, secondary and muted text and the status
  /// colours at 4.5:1 on the background, the surface, the elevated surface
  /// and each step of the ladder that holds words; placeholders at 3:1. Each
  /// colour that did not read is replaced by the nearest shade of it that
  /// does; a scheme where all of them read (Ember, Graphite, Daylight) comes
  /// back as it is. The colours a scheme was authored with stay in it, for
  /// the theme designer to show and save.
  ZestColorScheme get readable {
    final ladder = effectiveSurfaces;
    final page = [background, surface, surfaceElevated];
    final steps = ladder.readable(also: page);
    final grounds = [...page, ...ladder.textGrounds];
    Color ink(Color c) => readableShade(c, grounds);
    // Body and secondary text are also the words of chips.
    Color body(Color c) => readableShade(c, [...grounds, ladder.chip, ladder.chipStrong]);
    final shades = (
      body(onBackground),
      ink(onBackgroundMuted),
      ink(onBackgroundSubtle),
      body(onSurface),
      body(onSurfaceMuted),
      ink(success),
      ink(warning),
      ink(error),
      ink(info),
    );
    if (identical(steps, ladder) &&
        shades ==
            (onBackground, onBackgroundMuted, onBackgroundSubtle, onSurface, onSurfaceMuted, success, warning, error, info)) {
      return this;
    }
    return copyWith(
      onBackground: shades.$1,
      onBackgroundMuted: shades.$2,
      onBackgroundSubtle: shades.$3,
      onSurface: shades.$4,
      onSurfaceMuted: shades.$5,
      success: shades.$6,
      warning: shades.$7,
      error: shades.$8,
      info: shades.$9,
      // The ladder it was worked out from (a derived one, from the colours
      // as authored, then made readable), or the one spelled out.
      surfaces: steps,
    );
  }

  // ── Effective brand resolution ────────────────────────────────
  //
  // [secondary] and [accent] are nullable so built-in const themes and
  // schemes persisted before these fields existed keep compiling / loading
  // untouched. These getters supply the historical fallbacks so the DEFAULT
  // look is byte-identical: absent a custom secondary, Material's
  // secondary/tertiary stay a shade of the primary (the pre-existing
  // behaviour); absent a custom accent, the 1.7 component brand stays the
  // frozen `#FF7A1A`.

  /// The default frozen 1.7 brand accent (`ZestColors.accentPrimary`).
  static const Color kDefaultAccent = Color(0xFFFF7A1A);

  /// Resolved secondary accent. Falls back to [primaryHover] (== the built-in
  /// themes' historical Material secondary/tertiary) so nothing shifts until
  /// the user picks a custom secondary.
  Color get effectiveSecondary => secondary ?? primaryHover;

  /// Resolved secondary hover.
  Color get effectiveSecondaryHover => secondaryHover ?? effectiveSecondary;

  /// Resolved 1.7 component accent (drives ZestButton / ZestField /
  /// ZestTokens.brand). Falls back to the theme's own [primary] so that
  /// changing the theme colour also recolours the component brand: a blue
  /// theme gets blue buttons instead of leaving them the old orange. Default
  /// Dark's primary is exactly the frozen brand (`#FF7A1A`), so it is unchanged;
  /// Default Light / AMOLED (primary `#E8600A`) now paint their component brand
  /// in their OWN primary instead of `#FF7A1A`, unifying the two orange shades
  /// they used to mix.
  Color get effectiveAccent => accent ?? primary;

  // ── JSON serialisation ────────────────────────────────────────
  //
  // Custom app themes (created via the Theme Designer) round-trip
  // through SharedPreferences as JSON. Built-in themes never touch
  // these helpers - they're defined as Dart consts in
  // lib/theme/themes/*.dart.

  static String _hex(Color c) =>
      c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase();
  static Color _fromHex(String hex) => Color(int.parse(hex, radix: 16));

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'isDark': isDark,
        'background': _hex(background),
        'surface': _hex(surface),
        'surfaceElevated': _hex(surfaceElevated),
        'onBackground': _hex(onBackground),
        'onBackgroundMuted': _hex(onBackgroundMuted),
        'onBackgroundSubtle': _hex(onBackgroundSubtle),
        'onSurface': _hex(onSurface),
        'onSurfaceMuted': _hex(onSurfaceMuted),
        'primary': _hex(primary),
        'primaryHover': _hex(primaryHover),
        'onPrimary': _hex(onPrimary),
        if (secondary != null) 'secondary': _hex(secondary!),
        if (secondaryHover != null) 'secondaryHover': _hex(secondaryHover!),
        if (accent != null) 'accent': _hex(accent!),
        'success': _hex(success),
        'warning': _hex(warning),
        'error': _hex(error),
        'info': _hex(info),
        'border': _hex(border),
        'divider': _hex(divider),
        'hover': _hex(hover),
        'selected': _hex(selected),
        'focus': _hex(focus),
      };

  /// Parse a previously serialised scheme. Returns `null` if any
  /// required field is missing or malformed.
  static ZestColorScheme? fromJson(Map<String, dynamic> json) {
    try {
      return ZestColorScheme(
        id: json['id'] as String,
        name: json['name'] as String,
        isDark: json['isDark'] as bool? ?? true,
        background: _fromHex(json['background'] as String),
        surface: _fromHex(json['surface'] as String),
        surfaceElevated: _fromHex(json['surfaceElevated'] as String),
        onBackground: _fromHex(json['onBackground'] as String),
        onBackgroundMuted: _fromHex(json['onBackgroundMuted'] as String),
        onBackgroundSubtle: _fromHex(json['onBackgroundSubtle'] as String),
        onSurface: _fromHex(json['onSurface'] as String),
        onSurfaceMuted: _fromHex(json['onSurfaceMuted'] as String),
        primary: _fromHex(json['primary'] as String),
        primaryHover: _fromHex(json['primaryHover'] as String),
        onPrimary: _fromHex(json['onPrimary'] as String),
        // Optional - absent on schemes persisted before these fields existed.
        // A missing value stays null so the effective* getters supply the
        // historical fallback (old schemes load byte-identical).
        secondary: json['secondary'] != null
            ? _fromHex(json['secondary'] as String)
            : null,
        secondaryHover: json['secondaryHover'] != null
            ? _fromHex(json['secondaryHover'] as String)
            : null,
        accent:
            json['accent'] != null ? _fromHex(json['accent'] as String) : null,
        success: _fromHex(json['success'] as String),
        warning: _fromHex(json['warning'] as String),
        error: _fromHex(json['error'] as String),
        info: _fromHex(json['info'] as String),
        border: _fromHex(json['border'] as String),
        divider: _fromHex(json['divider'] as String),
        hover: _fromHex(json['hover'] as String),
        selected: _fromHex(json['selected'] as String),
        focus: _fromHex(json['focus'] as String),
      );
    } catch (_) {
      return null;
    }
  }

  /// Creates a copy with the given fields replaced.
  ZestColorScheme copyWith({
    String? id,
    String? name,
    bool? isDark,
    Color? background,
    Color? surface,
    Color? surfaceElevated,
    Color? onBackground,
    Color? onBackgroundMuted,
    Color? onBackgroundSubtle,
    Color? onSurface,
    Color? onSurfaceMuted,
    Color? primary,
    Color? primaryHover,
    Color? onPrimary,
    Color? secondary,
    Color? secondaryHover,
    Color? accent,
    Color? success,
    Color? warning,
    Color? error,
    Color? info,
    Color? border,
    Color? divider,
    Color? hover,
    Color? selected,
    Color? focus,
  ZestSurfaces? surfaces,
  }) {
    return ZestColorScheme(
      id: id ?? this.id,
      name: name ?? this.name,
      isDark: isDark ?? this.isDark,
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surfaceElevated: surfaceElevated ?? this.surfaceElevated,
      onBackground: onBackground ?? this.onBackground,
      onBackgroundMuted: onBackgroundMuted ?? this.onBackgroundMuted,
      onBackgroundSubtle: onBackgroundSubtle ?? this.onBackgroundSubtle,
      onSurface: onSurface ?? this.onSurface,
      onSurfaceMuted: onSurfaceMuted ?? this.onSurfaceMuted,
      primary: primary ?? this.primary,
      primaryHover: primaryHover ?? this.primaryHover,
      onPrimary: onPrimary ?? this.onPrimary,
      secondary: secondary ?? this.secondary,
      secondaryHover: secondaryHover ?? this.secondaryHover,
      accent: accent ?? this.accent,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      error: error ?? this.error,
      info: info ?? this.info,
      border: border ?? this.border,
      divider: divider ?? this.divider,
      hover: hover ?? this.hover,
      selected: selected ?? this.selected,
      focus: focus ?? this.focus,
    // A copy with other colours must not keep a ladder spelled out for the
      // original (the theme designer copies a built-in, then edits it), so the
      // ladder is dropped and worked out again unless it is passed.
      surfaces: surfaces,
    );
  }
}
