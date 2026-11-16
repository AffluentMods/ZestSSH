import 'package:flutter/material.dart';

/// Typography design tokens for ZestSSH.
///
/// All text sizes, weights, and line-heights are defined here so that
/// changing the type scale is a single-file change. The terminal uses
/// its own font settings via [TerminalStyle]; these tokens govern the
/// **app chrome** (navigation, cards, sheets, settings, etc.).
class ZestTypography {
  const ZestTypography._();

  // ── Font families ─────────────────────────────────────────────

  /// Default UI font stack.
  static const String fontFamily = '.SF Pro Text';

  /// Monospace font for code snippets, IPs, fingerprints.
  static const String monoFontFamily = 'JetBrainsMono';

  /// Fallback list appended to [fontFamily].
  static const List<String> fontFamilyFallback = [
    'Roboto',
    'Helvetica Neue',
    'Arial',
    'sans-serif',
  ];

  // ── Size tokens ───────────────────────────────────────────────

  /// Tiny labels, badges, captions.
  static const double sizeXs = 10.0;

  /// Secondary labels, helper text.
  static const double sizeSm = 12.0;

  /// Body text (default).
  static const double sizeBase = 14.0;

  /// Emphasized body, list-tile titles.
  static const double sizeMd = 16.0;

  /// Section headers, dialog titles.
  static const double sizeLg = 18.0;

  /// Screen titles, large headings.
  static const double sizeXl = 20.0;

  /// Hero headings, onboarding titles.
  static const double sizeXxl = 24.0;

  /// Display / splash text.
  static const double sizeDisplay = 32.0;

  // ── Weight tokens ─────────────────────────────────────────────

  static const FontWeight weightRegular = FontWeight.w400;
  static const FontWeight weightMedium = FontWeight.w500;
  static const FontWeight weightSemiBold = FontWeight.w600;
  static const FontWeight weightBold = FontWeight.w700;

  // ── Line-height multipliers ───────────────────────────────────

  /// Tight (headings, single-line labels).
  static const double lineHeightTight = 1.2;

  /// Normal (body text).
  static const double lineHeightNormal = 1.5;

  /// Relaxed (long-form reading).
  static const double lineHeightRelaxed = 1.75;

  // ── Letter spacing ────────────────────────────────────────────

  /// Slightly tighter for headings.
  static const double letterSpacingTight = -0.3;

  /// Default body text.
  static const double letterSpacingNormal = 0.0;

  /// Wider for all-caps labels / overlines.
  static const double letterSpacingWide = 0.5;

  // ── Pre-built TextStyles ──────────────────────────────────────

  /// Tiny caption text.
  static const TextStyle caption = TextStyle(
    fontSize: sizeXs,
    fontWeight: weightRegular,
    height: lineHeightNormal,
    letterSpacing: letterSpacingNormal,
  );

  /// Small helper / secondary text.
  static const TextStyle labelSmall = TextStyle(
    fontSize: sizeSm,
    fontWeight: weightRegular,
    height: lineHeightNormal,
    letterSpacing: letterSpacingNormal,
  );

  /// Default body text.
  static const TextStyle body = TextStyle(
    fontSize: sizeBase,
    fontWeight: weightRegular,
    height: lineHeightNormal,
    letterSpacing: letterSpacingNormal,
  );

  /// Emphasized body text.
  static const TextStyle bodyMedium = TextStyle(
    fontSize: sizeBase,
    fontWeight: weightMedium,
    height: lineHeightNormal,
    letterSpacing: letterSpacingNormal,
  );

  /// List-tile title, form labels.
  static const TextStyle subtitle = TextStyle(
    fontSize: sizeMd,
    fontWeight: weightMedium,
    height: lineHeightTight,
    letterSpacing: letterSpacingNormal,
  );

  /// Section header.
  static const TextStyle heading = TextStyle(
    fontSize: sizeLg,
    fontWeight: weightSemiBold,
    height: lineHeightTight,
    letterSpacing: letterSpacingTight,
  );

  /// Screen title.
  static const TextStyle title = TextStyle(
    fontSize: sizeXl,
    fontWeight: weightBold,
    height: lineHeightTight,
    letterSpacing: letterSpacingTight,
  );

  /// Large hero heading.
  static const TextStyle headline = TextStyle(
    fontSize: sizeXxl,
    fontWeight: weightBold,
    height: lineHeightTight,
    letterSpacing: letterSpacingTight,
  );

  /// Display / splash heading.
  static const TextStyle display = TextStyle(
    fontSize: sizeDisplay,
    fontWeight: weightBold,
    height: lineHeightTight,
    letterSpacing: letterSpacingTight,
  );

  /// Monospace text for code / IPs / fingerprints.
  static const TextStyle mono = TextStyle(
    fontFamily: monoFontFamily,
    fontSize: sizeBase,
    fontWeight: weightRegular,
    height: lineHeightNormal,
    letterSpacing: letterSpacingNormal,
  );

  /// Small monospace text for inline code.
  static const TextStyle monoSmall = TextStyle(
    fontFamily: monoFontFamily,
    fontSize: sizeSm,
    fontWeight: weightRegular,
    height: lineHeightNormal,
    letterSpacing: letterSpacingNormal,
  );
}
