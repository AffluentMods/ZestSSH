import 'package:flutter/material.dart';
import 'package:zestssh/core/theme/zest_colors.dart';

/// ZestSSH 1.7 semantic design tokens.
///
/// This is a NAMING layer, not a new palette. Every colour role is a getter
/// onto the runtime [ZestColors] (3.0), so it follows the active theme. Per the 1.7 foundations rule
/// "existing system wins", every colour role here resolves to an existing
/// [ZestColors] constant (the charcoal/black chrome palette, whose brand
/// accent is already `#FF7A1A`). No new hues are introduced; the only genuinely
/// new values live in [ZestSizing].
///
/// New 1.7 components (`ZestButton`, `ZestField`, `ZestSectionHeader`, the
/// master/detail shell, ...) reference [ZestTokens] so the semantic role is
/// legible at the call site and a future palette change is a single-file edit.
///
/// NOTE on the two oranges: the app also carries a legacy `AppColors.orange`
/// (`#E8600A`, ~691 refs). 1.7 standardises on `#FF7A1A` (== [ZestColors]
/// .accentPrimary == [brand] here). Migrating the legacy references is a
/// separate, staged visual sweep - do NOT blind-flip `AppColors.orange`.
abstract final class ZestTokens {
  // ── Brand ──────────────────────────────────────────────────────────
  // Now runtime getters onto the mutable [ZestColors] accent so a user-chosen
  // ACCENT flows through every ZestTokens.brand* reference. Defaults are the
  // historical `#FF7A1A` family: `brand` == `#FF7A1A`, `brandSubtle` ==
  // `0x1FFF7A1A` (~12%), `brandBorder` == `0x66FF7A1A` (~40%) - byte-identical
  // when the accent is the built-in brand.
  /// The one brand accent. `#FF7A1A` by default.
  static Color get brand => ZestColors.accentPrimary;

  /// [brand] as text or an icon on the theme's surfaces (see
  /// [ZestColors.accentInk]).
  static Color get brandInk => ZestColors.accentInk;

  /// ~12% brand fill - toggle-on / selected-row / active-segment states.
  static Color get brandSubtle =>
      ZestColors.accentPrimary.withValues(alpha: 0x1F / 0xFF);

  /// ~40% brand - selected-card borders, focus rings.
  static Color get brandBorder =>
      ZestColors.accentPrimary.withValues(alpha: 0x66 / 0xFF);

  /// Text and icons on a brand fill: dark on the orange in every theme.
  static Color get onBrand => ZestColors.onBrand;

  /// Brand-tinted fill (`.brand-fill`) - a brand-highlighted field / row.
  static Color get brandFill => ZestColors.brandFill; // 0xFF231A12

  /// Brand-tinted badge (`.brand-badge`).
  static Color get brandBadge => ZestColors.brandBadge; // 0xFF2D1E12

  /// Brand-tinted icon chip background (`.brand-icon-bg`).
  static Color get brandIconBg => ZestColors.brandIconBg; // 0xFF2A1E12

  /// `${var}` highlight tone in command / snippet previews.
  static Color get varHighlight => ZestColors.varHighlight; // 0xFFE0B48A

  // ── Surfaces ───────────────────────────────────────────────────────
  /// Pane / page background (the mockup `--panel` #0D0D0E). One rung DARKER
  /// than the sunken input interior, so field wells and cards read as carved
  /// against it - matching the Hosts editor (`surfacePanel`). It was
  /// mistakenly aliased to `bgContent` (#121215, the same as [surfaceSunken]),
  /// which flattened every shared-scaffold screen and cut text contrast.
  static Color get surfaceBase => ZestColors.surfacePanel; // 0xFF0D0D0E --panel

  /// Cards, list rows - raised above [surfaceBase]. Also the raised label cell
  /// of a [ZestField] (== the Hosts mockup `.cell`).
  static Color get surfaceRaised => ZestColors.bgSurface; // 0xFF1F1F23

  /// A hovered row, list item or quiet button: a visible step off the card or
  /// pane under it in every theme. Use this, not [surfaceRaised], for hover:
  /// on Daylight the raised cell is as white as the cards.
  static Color get surfaceHover => ZestColors.bgHover;

  /// Input field interiors. Warm near-black (#121215) so a field reads via its
  /// border + raised label cell rather than a harsh pure-black fill.
  static Color get surfaceSunken => ZestColors.bgContent; // 0xFF121215

  /// Deepest panel / chrome fill (`.panel`) - also the text colour painted ON a
  /// brand fill (a brand pill's label). Sticky-footer background.
  static Color get surfacePanel => ZestColors.surfacePanel; // 0xFF0D0D0E

  /// A slightly-raised menu / pill surface (`.raised2`) - dropdown menus, pills.
  static Color get surfaceRaisedAlt => ZestColors.surfaceRaisedAlt; // 0xFF1A1A1D

  /// Elevated chrome (`.raised`) - cards floating above the panel.
  static Color get surfaceElevated => ZestColors.chromeElevated; // 0xFF161619

  /// A page's header band, a step above the panel, and its rule.
  static Color get band => ZestColors.band;
  static Color get bandLine => ZestColors.bandLine;

  /// Chip fill (`.chip`).
  static Color get surfaceChip => ZestColors.surfaceChip; // 0xFF232327

  /// Stronger chip fill / count-badge fill (`.chip2`).
  static Color get surfaceChipStrong => ZestColors.surfaceChipStrong; // 0xFF26262A

  // ── Borders ────────────────────────────────────────────────────────
  /// 1px hairlines around cards / fields.
  static Color get border => ZestColors.borderDefault; // 0xFF2A2A2E

  /// The softest hairline (`.line`) - section-header rules, subtle dividers.
  static Color get borderSubtle => ZestColors.borderSubtle; // 0xFF26262A

  /// Heavier rules: pane dividers, sticky-footer top rule.
  static Color get borderStrong => ZestColors.borderStrong; // 0xFF3A3A3F

  // ── Text ───────────────────────────────────────────────────────────
  static Color get textPrimary => ZestColors.textPrimary; // 0xFFE6E3DA
  static Color get textSecondary => ZestColors.textSecondary; // 0xFFC9C6BD

  /// Between [textSecondary] and [textTertiary] (`.text-3`).
  static Color get textFaint => ZestColors.textFaint; // 0xFFA9A69E

  static Color get textTertiary => ZestColors.textTertiary; // 0xFF918F88

  /// Section-header labels and field helper text (`.muted-2`). Dimmer than
  /// [textTertiary].
  static Color get textMuted => ZestColors.textMuted; // 0xFF8F8D86

  /// Placeholder text. Renders DIMMER than [textPrimary] so a true placeholder
  /// is visibly distinct from a prefilled default value (see [ZestTokens] doc
  /// and the placeholder/value rule enforced in ZestField).
  static Color get textPlaceholder => ZestColors.textDisabled; // 0xFF5C5A55

  /// A turned-off button's fill, whatever kind of button, and its words:
  /// the theme's one ([ZestColors.disabledFill]).
  static Color get disabledFill => ZestColors.disabledFill;
  static Color get disabledInk => ZestColors.disabledInk;

  // ── Status (one meaning per role - see ZestStatus) ────────────────
  static Color get statusCritical => ZestColors.statusError; // 0xFFEF4444
  static Color get statusWarning => ZestColors.statusWarning; // 0xFFF59E0B
  static Color get statusHealthy => ZestColors.statusSuccess; // 0xFF10B981
  static Color get statusNeutral => ZestColors.textTertiary; // grey, no-signal
  static Color get statusPending => ZestColors.statusInfo; // 0xFF3B82F6, in-progress
}

/// Sizing tokens. The button and field sizing here is the one genuinely NEW
/// value set in 1.7 §1.2 - a deliberate change because buttons and commit
/// affordances were too small to read as primary. Everything else is extracted
/// from what the desktop shell already uses.
abstract final class ZestSizing {
  // Buttons
  /// Pane footers: Save, Cancel, primary CTAs.
  static const double buttonLarge = 40;

  /// Toolbars, inline actions.
  static const double buttonMedium = 32;

  /// Minimum icon-button hit target; 36 preferred where space allows.
  static const double iconButton = 32;

  static const double buttonLargePaddingX = 20;
  static const double buttonMediumPaddingX = 12;
  static const double buttonGap = 8;

  // Fields
  static const double fieldHeight = 44;
  static const double fieldRadius = 8;

  // Panes
  static const double listPaneMinWidth = 320;
  static const double detailPaneMinWidth = 520;

  /// List side, when the split first opens.
  static const double defaultSplitRatio = 0.38;

  /// Below this total width the master/detail collapses to a single column.
  static const double singleColumnBreakpoint = 1000;

  /// Below this the detail pane's own inner two-column layout stacks.
  static const double detailInnerSplitBreakpoint = 1280;
}
