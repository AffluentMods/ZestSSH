import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/theme/zest_color_scheme.dart';
import 'package:zestssh/theme/zest_spacing.dart';
import 'package:zestssh/theme/ui_density.dart' show ZestDensity;
import 'package:zestssh/utils/platform_utils.dart' show isTouchLayout;

/// Root theme class for ZestSSH.
///
/// Combines a [ZestColorScheme] with metadata and provides a
/// [toThemeData] converter that produces a full Flutter [ThemeData]
/// matching the current colour tokens. This lets us define themes
/// as simple colour palettes and get a complete Material 3 theme
/// for free.
///
/// Built-in themes live in `lib/theme/themes/` as static constants.
/// The active theme is selected via [appThemeProvider] in
/// `lib/providers/theme_providers.dart`.
class ZestTheme {
  /// Machine-readable identifier (matches [ZestColorScheme.id]).
  final String id;

  /// Human-readable display name.
  final String name;

  /// The colour palette for this theme.
  final ZestColorScheme colorScheme;

  /// Whether this is a dark or light theme.
  final Brightness brightness;

  const ZestTheme({
    required this.id,
    required this.name,
    required this.colorScheme,
    required this.brightness,
  });

  /// Converts this theme to a full Flutter [ThemeData].
  ///
  /// The generated ThemeData replicates the component-level styling
  /// from the original [AppTheme.dark()] but parameterised by the
  /// colour tokens in [colorScheme].
  ///
  /// [compact] is the controls' size (4.0, the density: Settings' Auto,
  /// Comfortable or Compact, [touchSizedProvider]): a computer's tighter
  /// sizes, or a finger's. Null: the running platform's.
  ThemeData toThemeData({Color? accentOverride, bool? compact}) {
    // As the app paints it: every colour that is read, readable (WCAG AA).
    final cs = colorScheme.readable;
    final accent = accentOverride ?? cs.primary;
    final accentHover = accentOverride != null
        ? HSLColor.fromColor(accentOverride)
            .withLightness(
              (HSLColor.fromColor(accentOverride).lightness + 0.1)
                  .clamp(0.0, 1.0),
            )
            .toColor()
        : cs.primaryHover;

    // The accent as a label (a text button's, an outlined one's): the nearest
    // shade of it that reads on the theme's surfaces, as AppColors.accentInk
    // is (the brand orange is 2.3:1 on Daylight's). Fills keep the accent.
    final accentText = ZestColors.inkOn(accent, cs.effectiveSurfaces.chipStrong);

    // Text and icons on an accent fill (the "On accent" token): derived from
    // the accent, never authored, so any accent keeps a readable label.
    final onAccent = ZestColors.onFill(accent);

    // The same for the secondary accent and the error fill: each label is
    // the readable ink on its own fill, never the primary's (a custom
    // secondary, or a light theme's red, had a label picked for the orange).
    final onSecondary = ZestColors.onFill(cs.effectiveSecondary);
    final onError = ZestColors.onFill(cs.error);

    // A disabled filled button: the theme's one turned-off fill with muted
    // text, so it reads as there but off on whatever it sits on (on Daylight
    // it was white on a white card, on the dark themes the colour of the
    // sheet or dialog under it).
    final ladder = cs.effectiveSurfaces;
    final disabledFill = ladder.disabledFill;
    final disabledInk = ladder.disabledInk;

    final materialColorScheme = ColorScheme(
      brightness: brightness,
      primary: accent,
      onPrimary: onAccent,
      primaryContainer: accentHover,
      onPrimaryContainer: onAccent,
      // Secondary/tertiary now follow the scheme's user-editable secondary
      // accent. effectiveSecondary falls back to primaryHover (== the previous
      // `accentHover` value for built-in themes), so this is unchanged until a
      // custom secondary is set.
      secondary: cs.effectiveSecondary,
      onSecondary: onSecondary,
      secondaryContainer: cs.surfaceElevated,
      onSecondaryContainer: cs.onSurface,
      tertiary: cs.effectiveSecondary,
      onTertiary: onSecondary,
      error: cs.error,
      onError: onError,
      surface: cs.surface,
      onSurface: cs.onSurface,
      onSurfaceVariant: cs.onSurfaceMuted,
      // Guarded so a border is never invisible against its fill (safety net for
      // custom / imported schemes; built-ins author distinct borders).
      outline: _visibleBorder(
          cs.border, cs.surfaceElevated, brightness == Brightness.dark),
      outlineVariant:
          _visibleBorder(cs.divider, cs.surface, brightness == Brightness.dark),
      surfaceContainerLowest: cs.background,
      surfaceContainerLow: cs.surface,
      surfaceContainer: cs.surface,
      surfaceContainerHigh: cs.surfaceElevated,
      surfaceContainerHighest: cs.surfaceElevated,
    );

    const borderRadius = ZestSpacing.radiusLg;

    // Desktop chrome differs from mobile: no drag handles on sheets,
    // tighter dialog radius. Detected at theme-build time (no context
    // needed) via the running platform.
    final isDesktop = defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
    // The controls' size: a computer's by default there, a finger's on a
    // phone and a tablet, unless the density says otherwise.
    final small = compact ?? isDesktop;

    // Inputs sit recessed (sunken) a step below the card surface, so a field
    // never reads identical to the card it sits on.
    final isDark = brightness == Brightness.dark;
    final surfaceHsl = HSLColor.fromColor(cs.surface);
    final sunkenFill = surfaceHsl
        .withLightness(
          (surfaceHsl.lightness + (isDark ? -0.025 : -0.03)).clamp(0.0, 1.0),
        )
        .toColor();

    // A border a step further from the surfaces than [cs.border]: hovered
    // secondaries, unchecked boxes.
    final strongBorder = Color.lerp(cs.border, cs.onSurface, isDark ? 0.18 : 0.22)!;

    // An input's outline (the "Input border" token): the
    // border moved toward the text until it stands 3:1 off the field's fill
    // (WCAG's line for the edge of a control); cards keep the quieter border.
    final inputBorder = _toContrast(cs.border, sunkenFill, cs.onSurface, 3);

    return ThemeData(
      useMaterial3: true,
      colorScheme: materialColorScheme,
      brightness: brightness,
      // Geist on every theme, not only on untouched Ember (3.0).
      fontFamily: 'GeistSans',
      scaffoldBackgroundColor: cs.background,
      visualDensity: small ? VisualDensity.compact : VisualDensity.standard,
      // A finger's targets are 48 square however small a control draws.
      materialTapTargetSize: small ? MaterialTapTargetSize.shrinkWrap : MaterialTapTargetSize.padded,
      // The shell's own parts (its bars, rail, tabs and cards) follow the
      // density where it is given; else the device's kind: a test drawn as
      // Android on a computer keeps a computer's shell.
      extensions: [ZestDensity(touch: compact == null ? isTouchLayout : !compact)],

      // AppBar
      // A page's bar: its title close to the back arrow, set as a title (it
      // was a light 22 at 72 pixels in, with nothing under it), and a
      // hairline along its foot.
      appBarTheme: AppBarTheme(
        backgroundColor: cs.background,
        foregroundColor: cs.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        leadingWidth: 48,
        titleSpacing: 12,
        titleTextStyle: TextStyle(
          fontFamily: 'GeistSans',
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
          color: cs.onSurface,
        ),
        iconTheme: IconThemeData(color: cs.onSurface, size: 20),
        actionsIconTheme: IconThemeData(color: cs.onSurfaceMuted, size: 20),
        shape: Border(bottom: BorderSide(color: cs.divider, width: 0.6)),
      ),

      // Cards
      cardTheme: CardThemeData(
        color: cs.surface,
        elevation: 0,
        shadowColor: Colors.black.withValues(alpha: 0.3),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        clipBehavior: Clip.antiAlias,
      ),

      // Buttons: one height and one radius whatever kind (3.0: pills,
      // 48-pixel bars and 32-pixel rects sat side by side). The accent fills
      // the primary; a secondary is outlined in the theme's own ink, and a
      // text button is a quiet ghost, so a screen has one orange thing.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: onAccent,
          disabledBackgroundColor: disabledFill,
          disabledForegroundColor: disabledInk,
          minimumSize: Size(0, small ? 34 : 44),
          // The sizes are the app's own: the theme's compact density on a
          // computer took 8 off every button (34 drew 26).
          visualDensity: VisualDensity.standard,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 13.5, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ZestSpacing.radiusMd)),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: onAccent,
          disabledBackgroundColor: disabledFill,
          disabledForegroundColor: disabledInk,
          elevation: 0,
          minimumSize: Size(0, small ? 34 : 44),
          // The sizes are the app's own: the theme's compact density on a
          // computer took 8 off every button (34 drew 26).
          visualDensity: VisualDensity.standard,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 13.5, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ZestSpacing.radiusMd)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.disabled) ? cs.onBackgroundSubtle : cs.onSurface),
          side: WidgetStateProperty.resolveWith((states) => BorderSide(
              color: states.contains(WidgetState.hovered) || states.contains(WidgetState.focused)
                  ? _visibleBorder(strongBorder, cs.surfaceElevated, isDark)
                  : _visibleBorder(cs.border, cs.surfaceElevated, isDark))),
          overlayColor: WidgetStatePropertyAll(cs.onSurface.withValues(alpha: 0.06)),
          minimumSize: WidgetStatePropertyAll(Size(0, small ? 34 : 44)),
          visualDensity: VisualDensity.standard,
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14)),
          textStyle: const WidgetStatePropertyAll(
              TextStyle(fontFamily: 'GeistSans', fontSize: 13.5, fontWeight: FontWeight.w500)),
          shape: const WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(ZestSpacing.radiusMd)))),
        ),
      ),
      // A text button is a quiet action in the theme's own ink, the accent
      // only under the pointer (3.0: Cancel, Change, Trash were all orange,
      // and a screen had a dozen orange things).
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) return cs.onBackgroundSubtle;
            if (states.contains(WidgetState.hovered) || states.contains(WidgetState.focused)) return accentText;
            return cs.onSurface;
          }),
          overlayColor: WidgetStatePropertyAll(cs.onSurface.withValues(alpha: 0.06)),
          // A mouse's least target, 32 (4.0 accessibility pass: 30 was 2
          // short of it); a finger's 48 comes from the padded tap target.
          minimumSize: WidgetStatePropertyAll(Size(0, small ? 32 : 40)),
          visualDensity: VisualDensity.standard,
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
          textStyle: const WidgetStatePropertyAll(
              TextStyle(fontFamily: 'GeistSans', fontSize: 13.5, fontWeight: FontWeight.w500)),
          shape: const WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(ZestSpacing.radiusMd)))),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          shape: const WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(ZestSpacing.radiusMd)))),
          overlayColor: WidgetStatePropertyAll(cs.onSurface.withValues(alpha: 0.07)),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: const WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(ZestSpacing.radiusMd)))),
          side: WidgetStatePropertyAll(BorderSide(color: _visibleBorder(cs.border, cs.surfaceElevated, isDark))),
          backgroundColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected) ? accent.withValues(alpha: 0.14) : Colors.transparent),
          foregroundColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected) ? accentText : cs.onSurface),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontFamily: 'GeistSans', fontSize: 13)),
          minimumSize: WidgetStatePropertyAll(Size(0, small ? 34 : 44)),
          visualDensity: VisualDensity.standard,
        ),
      ),

      // FAB
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: accent,
        foregroundColor: onAccent,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZestSpacing.radiusXl),
        ),
      ),

      // Input fields: recessed, with a hairline that says where they are
      // and a thin ring of the accent while typed in.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: sunkenFill,
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ZestSpacing.radiusMd),
          borderSide: BorderSide(color: inputBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ZestSpacing.radiusMd),
          borderSide: BorderSide(color: inputBorder),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ZestSpacing.radiusMd),
          borderSide: BorderSide(color: cs.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ZestSpacing.radiusMd),
          borderSide: BorderSide(color: accent, width: 1.2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ZestSpacing.radiusMd),
          borderSide: BorderSide(color: cs.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ZestSpacing.radiusMd),
          borderSide: BorderSide(color: cs.error, width: 1.2),
        ),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: small ? 10 : 13),
        hintStyle: TextStyle(color: cs.onBackgroundSubtle),
        // A field's label rests inside it while it is empty and rises onto
        // its edge once it holds a value or the keyboard, so a filled field
        // still says what it is (with `never` the label was a placeholder
        // that vanished at the first character). Muted at rest, the accent's
        // readable ink while typed in, red on an error.
        labelStyle: TextStyle(color: cs.onSurfaceMuted),
        floatingLabelStyle: WidgetStateTextStyle.resolveWith((states) => TextStyle(
              color: states.contains(WidgetState.error)
                  ? cs.error
                  : states.contains(WidgetState.focused)
                      ? accentText
                      : cs.onSurfaceMuted,
            )),
      ),

      // Dialogs - safety net for any dialog not yet migrated to
      // ZestConfirmDialog/ZestDialogShell. Tighter radius, a 1px
      // hairline border, a restrained shadow, no M3 surface tint, and
      // GeistSans text so stock AlertDialogs stop reading as generic
      // mobile Material.
      dialogTheme: DialogThemeData(
        backgroundColor: cs.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        elevation: 16,
        shadowColor: Colors.black.withValues(alpha: 0.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: cs.border),
        ),
        titleTextStyle: TextStyle(
          fontFamily: 'GeistSans',
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: cs.onSurface,
          letterSpacing: -0.2,
        ),
        contentTextStyle: TextStyle(
          fontFamily: 'GeistSans',
          fontSize: 13.5,
          height: 1.5,
          color: cs.onSurface.withValues(alpha: 0.85),
        ),
      ),

      // Bottom sheets - drag handle only makes sense as a touch
      // affordance, so it is suppressed on desktop where sheets read as
      // a mobile-port tell. No M3 surface tint.
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(isDesktop ? 14 : 20),
          ),
          side: isDesktop ? BorderSide(color: cs.border) : BorderSide.none,
        ),
        dragHandleColor: cs.onBackgroundSubtle,
        dragHandleSize: const Size(36, 4),
        showDragHandle: !isDesktop,
      ),

      // Drawer
      drawerTheme: DrawerThemeData(
        backgroundColor: cs.surface,
      ),

      // List tiles
      listTileTheme: ListTileThemeData(
        iconColor: cs.onSurfaceMuted,
        textColor: cs.onSurface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      ),

      // Switch: a white thumb on the accent when on; a muted thumb in a
      // hairline track when off; no glyph, no halo (the stock one drew an
      // orange thumb on a brown track).
      switchTheme: SwitchThemeData(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        thumbIcon: const WidgetStatePropertyAll(null),
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return cs.onBackgroundSubtle.withValues(alpha: 0.5);
          if (states.contains(WidgetState.selected)) return Colors.white;
          return cs.onSurfaceMuted;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return states.contains(WidgetState.disabled) ? accent.withValues(alpha: 0.35) : accent;
          }
          return sunkenFill;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? Colors.transparent : _visibleBorder(cs.border, sunkenFill, isDark)),
        trackOutlineWidth: const WidgetStatePropertyAll(1),
        overlayColor: WidgetStatePropertyAll(accent.withValues(alpha: 0.08)),
      ),

      // Checkbox and radio: one size, one look.
      checkboxTheme: CheckboxThemeData(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        side: WidgetStateBorderSide.resolveWith((states) => states.contains(WidgetState.selected)
            ? BorderSide(color: accent, width: 1.4)
            : BorderSide(color: _visibleBorder(strongBorder, cs.surfaceElevated, isDark), width: 1.4)),
        fillColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? accent : Colors.transparent),
        checkColor: WidgetStatePropertyAll(onAccent),
        overlayColor: WidgetStatePropertyAll(accent.withValues(alpha: 0.08)),
      ),
      radioTheme: RadioThemeData(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        fillColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected)
            ? accent
            : _visibleBorder(strongBorder, cs.surfaceElevated, isDark)),
        overlayColor: WidgetStatePropertyAll(accent.withValues(alpha: 0.08)),
      ),

      // Chips
      // (The label names the app's font itself: a chip does not take it
      // from the text theme, and would be drawn in the system's font.)
      chipTheme: ChipThemeData(
        backgroundColor: cs.surface,
        selectedColor: accent.withValues(alpha: 0.3),
        labelStyle: TextStyle(fontFamily: 'GeistSans', color: cs.onSurface),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZestSpacing.radiusMd),
        ),
      ),

      // Snackbar
      snackBarTheme: SnackBarThemeData(
        backgroundColor: cs.surfaceElevated,
        contentTextStyle: TextStyle(color: cs.onSurface),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZestSpacing.radiusMd),
        ),
        behavior: SnackBarBehavior.floating,
      ),

      // Divider
      dividerTheme: DividerThemeData(
        color: cs.divider,
        thickness: 1,
      ),

      // Progress indicator
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: accent,
      ),

      // PopupMenu / context menus - hairline border, no surface tint,
      // restrained shadow, GeistSans labels. Matches the dialog chrome
      // so right-click menus stop looking like stock Material.
      popupMenuTheme: PopupMenuThemeData(
        color: cs.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        // Under what opened it, never over it.
        position: PopupMenuPosition.under,
        menuPadding: const EdgeInsets.symmetric(vertical: 4),
        elevation: 12,
        shadowColor: Colors.black.withValues(alpha: 0.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: cs.border),
        ),
        labelTextStyle: WidgetStateProperty.all(
          TextStyle(
            fontFamily: 'GeistSans',
            fontSize: 13,
            color: cs.onSurface,
          ),
        ),
      ),

      // Dropdown
      dropdownMenuTheme: DropdownMenuThemeData(
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: sunkenFill,
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(ZestSpacing.radiusMd),
            borderSide: BorderSide(color: _visibleBorder(cs.border, sunkenFill, isDark)),
          ),
        ),
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(cs.surfaceElevated),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: cs.border),
          )),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(cs.surfaceElevated),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 4)),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: cs.border),
          )),
        ),
      ),

      // Navigation bar
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: accent.withValues(alpha: 0.15),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: accent, size: 24);
          }
          return IconThemeData(color: cs.onSurfaceMuted, size: 24);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return TextStyle(
              color: accent,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            );
          }
          return TextStyle(
            color: cs.onSurfaceMuted,
            fontSize: 12,
          );
        }),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        height: 64,
      ),

      // Tab bar
      tabBarTheme: TabBarThemeData(
        labelColor: accent,
        unselectedLabelColor: cs.onSurfaceMuted,
        indicatorColor: accent,
      ),

      // Tooltip
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: cs.surfaceElevated,
          borderRadius: BorderRadius.circular(ZestSpacing.radiusMd),
        ),
        textStyle: TextStyle(fontFamily: 'GeistSans', color: cs.onSurface, fontSize: 12),
      ),

      // Icon
      iconTheme: IconThemeData(color: cs.onSurfaceMuted),
    );
  }

  /// Creates a copy with the given fields replaced.
  ZestTheme copyWith({
    String? id,
    String? name,
    ZestColorScheme? colorScheme,
    Brightness? brightness,
  }) {
    return ZestTheme(
      id: id ?? this.id,
      name: name ?? this.name,
      colorScheme: colorScheme ?? this.colorScheme,
      brightness: brightness ?? this.brightness,
    );
  }
}

/// Ensure a border stays visible against the [surface] it sits on: if its
/// luminance is within a small delta of the surface, nudge it away (lighter on
/// dark themes, darker on light). Safety net for custom / imported schemes that
/// authored a border equal to its fill.
Color _visibleBorder(Color border, Color surface, bool isDark) {
  final delta = (border.computeLuminance() - surface.computeLuminance()).abs();
  if (delta >= 0.035) return border;
  final hsl = HSLColor.fromColor(surface);
  final l = (hsl.lightness + (isDark ? 0.09 : -0.09)).clamp(0.0, 1.0);
  return hsl.withLightness(l).toColor();
}

/// [c] moved toward [toward] in small steps until it stands [target]:1 off
/// [bg] (as it is, where it already does).
Color _toContrast(Color c, Color bg, Color toward, double target) {
  double ratio(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    return ((la > lb ? la : lb) + 0.05) / ((la > lb ? lb : la) + 0.05);
  }

  for (var i = 0; i <= 20; i++) {
    final step = Color.lerp(c, toward, i / 20)!;
    if (ratio(step, bg) >= target) return step;
  }
  return toward;
}
