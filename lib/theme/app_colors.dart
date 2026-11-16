import 'package:flutter/material.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/theme/zest_color_scheme.dart'; import 'package:zestssh/theme/zest_surfaces.dart';

/// ZestSSH color constants.
///
/// Orange accent on OLED-black background. All colors are defined here
/// so changing the brand palette is a single-file change.
abstract final class AppColors {
  // Brand - RUNTIME-MUTABLE so a user-chosen PRIMARY retints the ~700 legacy
  // orange references across the app UI. Defaults are the exact historical
  // `#E8600A` family; [applyTheme] only moves them when the active scheme
  // carries a custom primary (the built-in default / light / amoled themes all
  // use `#E8600A`, so their look is byte-identical - see [applyTheme]).
  static Color orange = const Color(0xFFFF7A1A);
  static Color orangeLight = const Color(0xFFFF9547);
  static Color orangeDark = const Color(0xFFE05A00);

  /// Alias of [orange] - a getter so it tracks runtime retints.
  static Color get brandOrange => orange;

  /// [orange] as text or an icon on the theme's surfaces (3.0 UI): the same
  /// colour on dark themes, a deeper shade where the brand orange would be
  /// hard to read (Daylight). Fills keep [brandOrange].
  static Color accentInk = const Color(0xFFFF7A1A);

  /// [v3AccentPrimary] as text or an icon, in the same way.
  static Color v3AccentInk = const Color(0xFFFF7A1A);

  /// Lighter brand tint (mockup `--brand-hi`). Reserved for the single file
  /// TYPE distinction worth a colour - directory rows in the file browser -
  /// kept separate from [brandOrange], which stays for primary actions +
  /// selection. A getter so it tracks runtime retints too.
  static Color get brandHi => orangeLight;

  /// Text or icon colour to put ON a solid [fill]: near-black or white,
  /// whichever contrasts more (WCAG). Dark text on the brand orange reads at
  /// about 7:1 where white manages about 2.6:1, so every solid brand button
  /// uses this instead of a fixed colour.
  static Color onBrand(Color fill) => ZestColors.onFill(fill);

  /// Discord "blurple" - the brand colour for the Join Discord affordance.
  static const Color brandDiscord = Color(0xFF5865F2);

  // Surfaces, divider and text: RUNTIME-MUTABLE since 3.0 ([applyTheme]
  // points them at the active theme's ladder), so every screen follows every
  // theme. The defaults are Ember's (warm charcoal, the 1.6 palette).
  static Color background = const Color(0xFF0A0A0B);
  static Color surface = const Color(0xFF161619);
  static Color surfaceDark = const Color(0xFF121215);
  static Color surfaceLight = const Color(0xFF1F1F23);
  static Color surfaceContainer = const Color(0xFF1A1A1D);
  static Color surfaceContainerHigh = const Color(0xFF1F1F23);
  static Color surfaceContainerHighest = const Color(0xFF26262A);

  // Divider
  static Color divider = const Color(0xFF2A2A2E);

  // Text
  static Color onBackground = const Color(0xFFE6E3DA);
  static Color onSurface = const Color(0xFFE6E3DA);
  static Color onSurfaceVariant = const Color(0xFFA9A69E);
  static Color onSurfaceDim = const Color(0xFF8D8B83);
  static Color get textSecondary => onSurfaceVariant;

  // SFTP-view semantic palette (chrome-exact spec) - softer ok/warn/crit tuned
  // for the charcoal SFTP surfaces. Used by the Activity queue, rail stale pins,
  // and destructive-operation rows so the SFTP view stays inside one palette.
  static Color sftpOk = const Color(0xFF4F9D69);
  static Color sftpWarn = const Color(0xFFE6C14A);
  static Color sftpCrit = const Color(0xFFF0736B);

  // SFTP-view surface ladder (chrome-exact §8). --panel is the pane, rail and
  // header; --sunken (== surfaceDark) is the path bar and other inputs; rows
  // hover up to --raised (== surface). Kept here so the SFTP shell can honour
  // the exact ladder without inventing inline hex.
  static Color sftpPanel = const Color(0xFF0D0D0E); // --panel
  static Color sftpSunken = const Color(0xFF121215); // --sunken (path bar)
  static Color sftpRaised2 = const Color(0xFF1A1A1D); // --raised-2 (rail header)
  static Color sftpBorderLift = const Color(0xFF3A3A40); // --border-lift

  // SFTP context-menu text ladder (pin + bookmark menus, chrome-exact §7). Item
  // text rests at --text-2 and lifts to onSurface (--text) on hover; glyphs sit
  // at onSurfaceDim (--muted); shortcut hints and the path header use --muted-2;
  // disabled rows collapse the whole row - text, glyph and shortcut - to --dim.
  static Color sftpMenuText = const Color(0xFFC9C6BD); // --text-2
  static Color sftpMenuMuted = const Color(0xFF78766F); // --muted-2
  static Color sftpMenuDim = const Color(0xFF5C5A55); // --dim (disabled)

  // Semantic: the one status palette (3.0), == Ember's and ZestColors'.
  static Color error = const Color(0xFFF0736B);
  static const Color onError = Color(0xFF1A1A1A);
  static Color success = const Color(0xFF4F9D69);
  static Color warning = const Color(0xFFE6C14A);

  // Connection status
  static Color connected = const Color(0xFF4F9D69);
  static Color disconnected = const Color(0xFFF0736B);

  // Interactive state (focus / selection highlights). Resolves to the active
  // theme's primary accent so selected chrome (e.g. the desktop terminal tab
  // highlight) follows a custom theme or preset instead of staying frozen at
  // brand orange. [v3AccentPrimary] defaults to #FF7A1A, so the out-of-the-box
  // look is byte-identical; it only moves once the user picks another theme.
  static Color get focusOrange => v3AccentPrimary;

  // Identity type indicators
  static const Color identityKey = Color(0xFF26A69A);
  static const Color identityPassword = Color(0xFFE8A030);

  // Key strength indicators
  static Color get keyStrengthStrong => success;
  static const Color keyStrengthGood = Color(0xFF66BB6A);
  static Color get keyStrengthLegacy => warning;

  // Cloud sync accent
  static const Color cloudSync = Color(0xFFF5A623);

  // Snippet category colors
  static const Color categorySystem = Color(0xFF4A9EF5);
  static const Color categoryServices = Color(0xFF8B5CF6);
  static const Color categoryDocker = Color(0xFF0EA5E9);
  static const Color categoryNetwork = Color(0xFF10B981);
  static const Color categoryFiles = Color(0xFFF59E0B);
  static const Color categorySecurity = Color(0xFFEF4444);
  static const Color categoryPackages = Color(0xFF6366F1);
  static const Color categoryGit = Color(0xFFF97316);
  static const Color categoryDatabase = Color(0xFF14B8A6);
  static const Color categoryLogs = Color(0xFF64748B);

  // SFTP file type indicators
  static const Color fileTypeCode = Color(0xFF4EC9B0);
  static const Color fileTypeConfig = Color(0xFF4A9EF5);
  static const Color fileTypeImage = Color(0xFFCE93D8);

  // What a colour INDEX saved on a host, a key or a tab means. Only read (by
  // [labelColorFor] and [explicitConnectionLabel]) and never offered: a picker
  // offers [labelPalette]. Never reordered or changed, so a saved one stays.
  static const List<Color> connectionLabelColors = [
    // The group colours' family, in the order hosts saved them by (an
    // index): Material's saturated 500s were louder than the rest of the app.
    Color(0xFFFF7A1A), // orange (default, the brand)
    Color(0xFF10B981), // green
    Color(0xFF3B82F6), // blue
    Color(0xFFEF4444), // red
    Color(0xFFA855F7), // purple
    Color(0xFFEAB308), // yellow
    Color(0xFF14B8A6), // teal
    Color(0xFFA16207), // brown
  ];

  /// Resolve a connection / identity label colour.
  ///
  /// An explicit [colorValue] (an ARGB int from `Color.toARGB32()`) always
  /// wins - it lets the user persist ANY custom colour. When null we fall back
  /// to the legacy behaviour: the palette entry at [colorIndex] (index 0 =
  /// orange default). A null [colorValue] therefore behaves exactly as before.
  static Color labelColorFor(int? colorValue, int colorIndex) =>
      colorValue != null
          ? Color(colorValue)
          : connectionLabelColors[colorIndex % connectionLabelColors.length];

  /// The colour shown for a connection, inheriting the identity's colour when
  /// the connection itself carries no explicit colour.
  ///
  /// Priority: a connection with an explicit colour (custom [connColorValue] or
  /// a non-default [connColorIndex]) always wins; otherwise an identity that
  /// carries a colour (its own custom value, or a non-zero index) is inherited;
  /// failing both, the connection's own (default orange) colour. With every
  /// `*ColorValue` null this reproduces the old index-only "inherit identity
  /// colour when the connection is still the 0/orange default" behaviour.
  static Color effectiveConnectionColor({
    int? connColorValue,
    required int connColorIndex,
    int? identityColorValue,
    int identityColorIndex = 0,
  }) {
    final connHasColour = connColorValue != null || connColorIndex != 0;
    if (connHasColour) return labelColorFor(connColorValue, connColorIndex);
    final identityHasColour =
        identityColorValue != null || identityColorIndex != 0;
    if (identityHasColour) {
      return labelColorFor(identityColorValue, identityColorIndex);
    }
    return labelColorFor(connColorValue, connColorIndex);
  }

  /// Neutral fallback for a connection that has neither an explicit colour
  /// label nor a group to inherit from. A desaturated grey (== [v3TextTertiary]
  /// default) so an unlabelled host reads as "no colour" rather than orange.
  static const Color neutralLabelColor = Color(0xFF8D8B83);

  /// The connection's OWN explicit colour label, or `null` when the user chose
  /// **None** - i.e. the default no-label state (`colorValue == null` AND
  /// `colorIndex == 0`). Any custom [colorValue], or a non-zero legacy
  /// [colorIndex], counts as an explicit override.
  ///
  /// This is the "override" term of [resolveConnectionLabelColor]; a null
  /// result means "inherit from the group / fall back to neutral".
  static Color? explicitConnectionLabel(int? colorValue, int colorIndex) {
    if (colorValue != null) return Color(colorValue);
    if (colorIndex != 0) {
      return connectionLabelColors[colorIndex % connectionLabelColors.length];
    }
    return null;
  }

  /// Whether a connection carries an explicit colour override (vs. inheriting
  /// from its group). True when the user picked any swatch other than **None**.
  static bool hasExplicitConnectionLabel(int? colorValue, int colorIndex) =>
      explicitConnectionLabel(colorValue, colorIndex) != null;

  /// Resolve the colour shown for a connection under the v1.6 channel model:
  ///
  ///   explicit host override  ??  inherited group colour  ??  neutral
  ///
  /// The group's colour is **never** copied onto the host record - resolve the
  /// group colour at render time (via `resolveGroupColor`) and pass it here as
  /// [inheritedGroupColor], or `null` when the host is ungrouped. Choosing
  /// **None** on the host clears its override so it re-inherits automatically.
  static Color resolveConnectionLabelColor({
    int? connColorValue,
    required int connColorIndex,
    Color? inheritedGroupColor,
  }) =>
      explicitConnectionLabel(connColorValue, connColorIndex) ??
      inheritedGroupColor ??
      neutralLabelColor;

  /// The resolved colour label, or `null` when the host has NEITHER an explicit
  /// override NOR a group to inherit from. Accent bars (host card, drawer rows)
  /// use this and simply draw NO rail when it is null - an unlabelled, ungrouped
  /// host shows the bare card, not a neutral-grey stub. (Contrast
  /// [resolveConnectionLabelColor], which substitutes [neutralLabelColor].)
  static Color? resolveConnectionLabelColorOrNull({
    int? connColorValue,
    required int connColorIndex,
    Color? inheritedGroupColor,
  }) =>
      explicitConnectionLabel(connColorValue, connColorIndex) ??
      inheritedGroupColor;

  // ── v1.5 Desktop palette (Charcoal + Black Chrome) ──────────────
  // Authoritative palette from zestssh-1.5-complete.md.
  // Chrome = pure black (pill bar, status bar).
  // Content = charcoal (sidebar, main area).
  // Surface = lighter (cards, inputs).
  // Elevated = modals, popovers, dropdowns.

  // ── v3 chrome tokens ─────────────────────────────────────────
  //
  // These USED to be `static const` so widgets could embed them in
  // const constructors. The downside: the entire desktop UI was
  // visually locked to charcoal-and-orange regardless of which
  // "App Theme" the user picked - Default Dark, Dracula, Nord,
  // whatever, you'd only see the Material widgets shift (cards,
  // buttons) while the pill bar / sidebar / dialogs / 95% of the
  // chrome stayed identical.
  //
  // Now they're `static` mutable fields (no longer const), and
  // [applyTheme] rewires them from a [ZestColorScheme]. App.dart
  // calls `applyTheme` before each MaterialApp build and bumps a
  // rebuild key so existing widgets re-read the new values.
  //
  // The defaults below match Default Dark (the shipped default theme) so the
  // first paint, before any theme is resolved, looks identical to the applied
  // default. Borders are kept DISTINCT from the surfaces so no card / popover
  // stroke is ever authored equal to its fill (which renders it invisible).

  /// Behind a phone's status and navigation bars where a screen keeps its
  /// own bars clear of them (the file editor): black in every theme.
  static const Color systemBarsBlack = Color(0xFF000000);

  /// Around a remote screen's picture (4.0) where it does not fill its view:
  /// black in every theme, as the edge of a monitor.
  static const Color screenLetterbox = Color(0xFF000000);

  /// Words on [screenLetterbox] (waiting for the picture): a light grey.
  static const Color screenLetterboxInk = Color(0xFFA9A69E);

  /// The pointer drawn over a remote screen's picture in Mouse pointer mode
  /// until the server sends its own: a white arrow with a black edge, seen on
  /// any desktop.
  static const Color screenPointerFill = Color(0xFFFFFFFF);
  static const Color screenPointerEdge = Color(0xFF000000);

  // Chrome (pill bar + status bar)
  static Color v3ChromeBg = const Color(0xFF000000);
  static Color v3ChromeDivider = const Color(0xFF0A0A0B);
  static Color v3ChromeElevated = const Color(0xFF0A0A0A);

  // Content (sidebar + main area)
  static Color v3Background = const Color(0xFF0A0A0B);
  static Color v3Surface = const Color(0xFF161619);
  static Color v3Elevated = const Color(0xFF1F1F23);
  static Color v3Hover = const Color(0xFF24242A);

  // Borders - distinct from the surfaces above (never equal to a fill).
  static Color v3BorderSubtle = const Color(0xFF2A2A2E);
  static Color v3BorderDefault = const Color(0xFF3A3A3F);
  static Color v3BorderStrong = const Color(0xFF525252);

  // Text - warm off-white to match Default Dark.
  static Color v3TextPrimary = const Color(0xFFE6E3DA);
  static Color v3TextSecondary = const Color(0xFFC9C6BD);
  static Color v3TextTertiary = const Color(0xFF8D8B83);
  static Color v3TextDisabled = const Color(0xFF525252);

  // Brand accent
  static Color v3AccentPrimary = const Color(0xFFFF7A1A);
  static Color v3AccentHover = const Color(0xFFFF9547);
  static Color v3AccentPressed = const Color(0xFFE05A00);

  // Secondary accent - feeds Material secondary/tertiary. Default `#FF8A3D`
  // equals the historical Material secondary (AppColors.orangeLight / the
  // built-in themes' primaryHover) so nothing changes until the user picks a
  // custom secondary. Re-derived in [applyTheme] from `cs.effectiveSecondary`.
  static Color v3AccentSecondary = const Color(0xFFFF9547);

  // Status (Ember's until applyTheme runs)
  static Color v3Success = const Color(0xFF4F9D69);
  static Color v3Warning = const Color(0xFFE6C14A);
  static Color v3Error = const Color(0xFFF0736B);
  static Color v3Info = const Color(0xFF83A8D8);

  // Group colors (user-pickable per group)
  /// The one list of colours a picker offers for a host, a group or a tag:
  /// eight, defined here alone. A colour already saved stays as it is, on this
  /// list or not: the picker shows it first, picked, and nothing rewrites it
  /// (test/theme/label_palette_test.dart holds every picker to this list).
  ///
  /// Groups and snippet categories save an index into it, so its order never
  /// changes, and `GroupColor` lines up with it 1:1.
  static const List<Color> labelPalette = [
    Color(0xFFEF4444), // red (Production)
    Color(0xFFF59E0B), // yellow (Staging)
    Color(0xFFFF7A1A), // orange (Homelab / brand)
    Color(0xFF10B981), // green (Personal)
    Color(0xFF3B82F6), // blue (Development)
    Color(0xFFA855F7), // purple (Testing)
    Color(0xFFEC4899), // pink
    Color(0xFF14B8A6), // teal
  ];

  /// [labelPalette], by the name a saved group's or category's index reads it.
  static const List<Color> v3GroupColors = labelPalette;

  // ── Runtime theming ─────────────────────────────────────────
  //
  // Re-derive every v3* chrome token from a [ZestColorScheme].
  // Called from app.dart whenever the active [ZestTheme] changes.
  // The mapping below is the same recipe the built-in themes use
  // internally - chrome darker than background, surfaces a notch
  // lighter, accent comes from the scheme's `primary`, etc.
  //
  // We do NOT recolor the v3GroupColors palette - those are
  // host-group labels and the user's expectation is that they
  // stay consistent across themes (red = prod no matter what).
  /// The row-hover fill: the scheme's hover overlay composited onto the
  /// surface it is painted over (one step up the surface ladder). If the
  /// result would sit too close to the text colour to read a label against,
  /// fall back to a plain step above the surface. Never a text token.
  static Color _visibleHover(ZestColorScheme cs) {
    final blended = Color.alphaBlend(cs.hover, cs.surface);
    if (contrastRatio(cs.onSurface, blended) >= 4.5) return blended;
    return cs.isDark
        ? _lighten(cs.surface, 0.06)
        : _darken(cs.surface, 0.06);
  }

  /// WCAG contrast ratio between two opaque colours (1 to 21).
  static double contrastRatio(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  static void applyTheme(ZestColorScheme authored) {
    // What is read is painted readable (WCAG AA, the 4.0 accessibility pass):
    // the same scheme where every colour already read.
    final cs = authored.readable;
    // Chrome - pure black for dark themes, slightly darker than
    // surface for light themes. Charcoal default = #000 chrome,
    // #18181B bg, so chrome is darker by ~10%.
    final isDark = cs.isDark;
    v3ChromeBg = isDark
        ? _darken(cs.background, 0.6)
        : _darken(cs.background, 0.08);
    v3ChromeDivider = isDark
        ? cs.background
        : _darken(cs.background, 0.04);
    v3ChromeElevated = isDark
        ? _lighten(v3ChromeBg, 0.04)
        : cs.surface;

    // Content surfaces
    v3Background = cs.background;
    v3Surface = cs.surface;
    v3Elevated = cs.surfaceElevated;
    // A scheme authors `hover` as a translucent overlay, often the TEXT colour
    // at low alpha. Stripping the alpha used to turn that overlay into the
    // opaque text colour, so every hovered row lit up at the label's own value
    // and the label vanished. Composite the overlay onto the pane instead,
    // and refuse a result that a label could not be read against.
    v3Hover = _visibleHover(cs);

    // Borders - guarded so a border can never be authored equal (or too close)
    // to the surface it sits on, which renders it invisible. Card strokes use
    // the subtle border on `surface`; popover / dialog strokes use the default
    // border on `surfaceElevated`. Built-in themes author distinct borders so
    // this never fires for them - it's a safety net for custom / imported
    // schemes (the designer also blocks saving a colliding theme).
    v3BorderSubtle = _visibleBorder(cs.divider, cs.surface, isDark);
    v3BorderDefault = _visibleBorder(cs.border, cs.surfaceElevated, isDark);
    v3BorderStrong = isDark
        ? _lighten(v3BorderDefault, 0.10)
        : _darken(v3BorderDefault, 0.10);

    // Text
    v3TextPrimary = cs.onSurface;
    v3TextSecondary = cs.onSurfaceMuted;
    v3TextTertiary = cs.onBackgroundSubtle;
    v3TextDisabled = cs.onBackgroundSubtle.withValues(alpha: 0.5);

    // Accent
    v3AccentPrimary = cs.primary;
    v3AccentHover = cs.primaryHover;
    v3AccentPressed = _darken(cs.primary, 0.08);

    // ── Legacy orange family ─────────────────────────────────────
    //
    // Retint the legacy orange (AppColors.orange / Light / Dark) to the theme's
    // own primary so a re-tinted theme recolours these elements too, matching
    // the v3 accent above and effectiveAccent. This used to be gated to only
    // `custom_` themes to avoid a two-hue clash (orange elements would recolour
    // while the component brand stayed #FF7A1A); now that effectiveAccent also
    // follows the primary that clash is gone, so every theme follows its own
    // primary. Fires whenever the primary differs from the default brand
    // #FF7A1A: Default Dark (primary #FF7A1A) stays frozen and unchanged, while
    // Default Light / AMOLED (primary #E8600A) and the presets paint in theirs.
    final retintLegacyOrange = cs.primary.toARGB32() != 0xFFFF7A1A;
    if (retintLegacyOrange) {
      orange = cs.primary;
      orangeLight = _lighten(cs.primary, 0.12);
      orangeDark = _darken(cs.primary, 0.15);
    } else {
      orange = const Color(0xFFFF7A1A);
      orangeLight = const Color(0xFFFF9547);
      orangeDark = const Color(0xFFE05A00);
    }

    // Secondary accent (Material secondary/tertiary). Defaults to
    // `cs.primaryHover` via effectiveSecondary, matching the historical
    // Material secondary until the user picks a custom secondary.
    v3AccentSecondary = cs.effectiveSecondary;

    // The frozen 1.7 component brand (#FF7A1A) - a SEPARATE user-editable
    // accent. ZestColors.applyAccent restores the exact historical constants
    // when the accent is the default, so ZestButton/ZestField/ZestTokens.brand
    // stay byte-identical until a custom accent is chosen.
    ZestColors.applyAccent(cs.effectiveAccent);

    // Status
    v3Success = cs.success;
    v3Warning = cs.warning;
    v3Error = cs.error;
    v3Info = cs.info;
  // ── The surface ladder (3.0) ────────────────────────────────────
    //
    // The const-era tokens every older screen reads follow the theme too,
    // from the scheme's ladder (spelled out by Ember, Graphite and Daylight,
    // worked out for the rest). Ember lands on its exact historical values.
    final l = cs.effectiveSurfaces;
    accentInk = ZestColors.inkOn(orange, l.chipStrong);
    v3AccentInk = ZestColors.inkOn(v3AccentPrimary, l.chipStrong);
    background = cs.background;
    surface = l.raised;
    surfaceDark = l.sunken;
    surfaceLight = l.cell;
    surfaceContainer = l.raised2;
    surfaceContainerHigh = l.cell;
    surfaceContainerHighest = l.chipStrong;
    divider = l.border;
    onBackground = l.text;
    onSurface = l.text;
    onSurfaceVariant = l.text3;
    onSurfaceDim = l.muted;
    sftpPanel = l.panel;
    sftpSunken = l.sunken;
    sftpRaised2 = l.raised2;
    sftpBorderLift = identical(l, ZestSurfaces.ember)
        ? const Color(0xFF3A3A40)
        : l.borderStrong;
    sftpMenuText = l.text2;
    sftpMenuMuted = l.muted2;
    sftpMenuDim = l.dim;
    sftpOk = cs.success;
    sftpWarn = cs.warning;
    sftpCrit = cs.error;
    error = cs.error;
    success = cs.success;
    warning = cs.warning;
    connected = cs.success;
    disconnected = cs.error;
    ZestColors.applySurfaces(
      l,
      isDark: isDark,
      chrome: v3ChromeBg,
      accent: cs.effectiveAccent,
      success: cs.success,
      warning: cs.warning,
      error: cs.error,
      info: cs.info,
    );
  }

  /// Darken a color by mixing it with black. Amount 0..1.
  static Color _darken(Color c, double amount) {
    final hsl = HSLColor.fromColor(c);
    final l = (hsl.lightness - amount).clamp(0.0, 1.0);
    return hsl.withLightness(l).toColor();
  }

  /// Lighten a color by mixing it with white. Amount 0..1.
  static Color _lighten(Color c, double amount) {
    final hsl = HSLColor.fromColor(c);
    final l = (hsl.lightness + amount).clamp(0.0, 1.0);
    return hsl.withLightness(l).toColor();
  }

  /// Ensure a border stays visible against the [surface] it sits on: if its
  /// luminance is within a small delta of (or identical to) the surface, nudge
  /// it away - lighter on dark themes, darker on light. A safety net for
  /// custom / imported schemes that collide a border with its fill.
  static Color _visibleBorder(Color border, Color surface, bool isDark) {
    final delta =
        (border.computeLuminance() - surface.computeLuminance()).abs();
    if (delta >= 0.035) return border;
    return isDark ? _lighten(surface, 0.09) : _darken(surface, 0.09);
  }
}
