import 'package:flutter/material.dart';

/// Spacing design tokens for ZestSSH.
///
/// Consistent spacing scale used across the entire UI. Import this
/// instead of hard-coding pixel values. The scale is deliberately
/// small-stepped at the low end (4-8-12-16) for fine control in
/// dense UIs, and jumps at the high end for section separation.
class ZestSpacing {
  const ZestSpacing._();

  // ── Base scale ────────────────────────────────────────────────

  /// 4px  -- Tight gaps (icon-to-label, inline padding).
  static const double xs = 4.0;

  /// 8px  -- Small gaps (between chips, list-item internal padding).
  static const double sm = 8.0;

  /// 12px -- Medium gaps (card internal padding, form field spacing).
  static const double md = 12.0;

  /// 16px -- Base unit (standard padding, section gaps).
  static const double base = 16.0;

  /// 24px -- Large gaps (between sections, dialog padding).
  static const double lg = 24.0;

  /// 32px -- Extra-large gaps (screen-level margins, hero spacing).
  static const double xl = 32.0;

  /// 48px -- Section dividers, splash-screen spacing.
  static const double xxl = 48.0;

  // ── Commonly used EdgeInsets ───────────────────────────────────

  /// All sides xs (4).
  static const EdgeInsets paddingXs = EdgeInsets.all(xs);

  /// All sides sm (8).
  static const EdgeInsets paddingSm = EdgeInsets.all(sm);

  /// All sides md (12).
  static const EdgeInsets paddingMd = EdgeInsets.all(md);

  /// All sides base (16).
  static const EdgeInsets paddingBase = EdgeInsets.all(base);

  /// All sides lg (24).
  static const EdgeInsets paddingLg = EdgeInsets.all(lg);

  /// Horizontal base (16), vertical sm (8) -- common list-tile padding.
  static const EdgeInsets paddingListTile = EdgeInsets.symmetric(
    horizontal: base,
    vertical: sm,
  );

  /// Horizontal base (16), vertical md (12) -- card content padding.
  static const EdgeInsets paddingCard = EdgeInsets.symmetric(
    horizontal: base,
    vertical: md,
  );

  /// Horizontal lg (24), vertical base (16) -- dialog content padding.
  static const EdgeInsets paddingDialog = EdgeInsets.symmetric(
    horizontal: lg,
    vertical: base,
  );

  /// Horizontal lg (24), vertical md (12) -- button internal padding.
  static const EdgeInsets paddingButton = EdgeInsets.symmetric(
    horizontal: lg,
    vertical: md,
  );

  // ── Border radius ─────────────────────────────────────────────

  /// Small radius (4) -- chips, badges.
  static const double radiusSm = 4.0;

  /// Default radius (8) -- buttons, inputs.
  static const double radiusMd = 8.0;

  /// Card / sheet radius (12) -- cards, dialogs.
  static const double radiusLg = 12.0;

  /// Large radius (16) -- FAB, bottom sheet.
  static const double radiusXl = 16.0;

  /// Full-round (999) -- pills, circular avatars.
  static const double radiusFull = 999.0;

  /// Pre-built BorderRadius for [radiusSm].
  static const BorderRadius borderRadiusSm =
      BorderRadius.all(Radius.circular(radiusSm));

  /// Pre-built BorderRadius for [radiusMd].
  static const BorderRadius borderRadiusMd =
      BorderRadius.all(Radius.circular(radiusMd));

  /// Pre-built BorderRadius for [radiusLg].
  static const BorderRadius borderRadiusLg =
      BorderRadius.all(Radius.circular(radiusLg));

  /// Pre-built BorderRadius for [radiusXl].
  static const BorderRadius borderRadiusXl =
      BorderRadius.all(Radius.circular(radiusXl));
}
