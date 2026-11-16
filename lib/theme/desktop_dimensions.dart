import 'package:flutter/material.dart';

/// Centralized desktop design tokens for ZestSSH.
///
/// All desktop-specific magic numbers live here to ensure consistency
/// across the entire desktop UI. Import this file instead of hardcoding
/// values in individual widgets.
class DesktopDimensions {
  DesktopDimensions._();

  // ── Status Bar ────────────────────────────────────────────────
  static const double statusBarHeight = 28.0;
  static const double statusBarFontSize = 12.0;
  static const double statusBarIconSize = 13.0;

  // ── Pill Bar (v1.5-complete) ────────────────────────────────────
  static const double pillBarHeight = 48.0;

  // ── Tab Bar ───────────────────────────────────────────────────
  static const double tabBarHeight = 36.0;
  static const double tabBarCompactHeight = 32.0;
  static const double tabMinWidth = 120.0;
  static const double tabMaxWidth = 220.0;
  static const double tabFontSize = 13.0;
  static const double tabCompactFontSize = 11.0;

  // ── Sidebar ───────────────────────────────────────────────────
  static const double sidebarMinWidth = 200.0;
  static const double sidebarMaxWidth = 400.0;
  static const double sidebarDefaultWidth = 280.0;
  static const double sidebarCollapsedWidth = 52.0;
  static const double sidebarResizeHandleWidth = 4.0;

  // ── Pane Splitting ────────────────────────────────────────────
  static const double minPaneWidth = 200.0;
  static const double minPaneHeight = 150.0;
  static const double dividerVisualWidth = 1.0;
  static const double dividerHitAreaWidth = 8.0;

  // ── Buttons ───────────────────────────────────────────────────
  static const double buttonVerticalPadding = 16.0;
  static const double buttonHorizontalPadding = 20.0;
  static const double buttonHeightDesktop = 36.0;
  static const double iconButtonSizeDesktop = 32.0;

  // ── Text Fields ──────────────────────────────────────────────
  static const double textFieldHeightDesktop = 36.0;

  // ── Sidebar ─── (item-level tokens) ──────────────────────────
  static const double sidebarNavItemHeight = 38.0;
  static const double sidebarItemPaddingVertical = 8.0;
  static const double sidebarSearchFieldHeight = 34.0;

  // ── Dialog Sizing ─────────────────────────────────────────────
  //
  // These got a uniform bump in v1.5: the previous 400-600px range
  // looked like a tiny phone-sized popup floating in the middle of a
  // 1920px desktop window.  New range targets ~50-65% of typical
  // desktop widths so dialogs feel like first-class app surfaces.
  static const double dialogMinWidth = 560.0;
  static const double dialogMaxWidth = 880.0;
  static const double dialogDesktopBreakpoint = 700.0;
  static const double connectionEditMaxWidth = 1100.0;
  static const double connectionEditMinWidth = 720.0;
  static const double identityEditMaxWidth = 880.0;
  static const double identityEditMinWidth = 620.0;
  static const double settingsMaxWidth = 1100.0;
  static const double quickConnectMaxWidth = 720.0;

  // ── Color Picker ──────────────────────────────────────────────
  static const double colorPickerCircleSize = 38.0;

  // ── Icon Sizes (standardized) ─────────────────────────────────
  static const double iconSmall = 14.0;
  static const double iconMedium = 16.0;
  static const double iconLarge = 20.0;
  static const double iconXLarge = 24.0;

  // ── v1.5 Host Grid Tokens ──────────────────────────────────────
  static const double searchBarHeight = 44.0;
  static const double subActionBarHeight = 36.0;
  static const double hostCardHeight = 80.0;
  static const double hostCardMinWidth = 280.0;
  static const double hostCardMaxWidth = 340.0;
  static const double groupCardHeight = 80.0;
  static const double groupCardMinWidth = 280.0;

  // ── v1.5 Session Info Bar ─────────────────────────────────────
  static const double sessionInfoBarHeight = 36.0;

  // ── Minimum split ratio ───────────────────────────────────────
  static const double minSplitRatio = 0.15;
  static const double maxSplitRatio = 0.85;
}

/// Desktop-specific theme tokens that adapt to light/dark mode.
class DesktopThemeTokens {
  DesktopThemeTokens._();

  /// Subtle hover background color for interactive elements.
  static Color hoverColor(Brightness brightness) =>
      brightness == Brightness.dark
          ? Colors.white.withValues(alpha: 0.05)
          : Colors.black.withValues(alpha: 0.04);

  /// Divider color for split pane separators.
  static Color dividerColor(Brightness brightness) =>
      brightness == Brightness.dark
          ? Colors.white.withValues(alpha: 0.1)
          : Colors.black.withValues(alpha: 0.1);

  /// Focus border color (uses brand orange from theme).
  static Color focusBorderColor(BuildContext context) =>
      Theme.of(context).colorScheme.primary;
}
