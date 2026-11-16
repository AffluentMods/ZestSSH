import 'package:flutter/material.dart';

/// User-pickable group color tokens. Keep this list closed - adding a 10th
/// color requires updating the picker UI and any persistence migrations.
///
/// Storage uses the enum's `index`. Reordering breaks existing data -
/// always append new entries at the end.
enum GroupColor {
  red(Color(0xFFEF4444)),
  yellow(Color(0xFFF59E0B)),
  orange(Color(0xFFFF7A1A)),
  green(Color(0xFF10B981)),
  blue(Color(0xFF3B82F6)),
  purple(Color(0xFFA855F7)),
  pink(Color(0xFFEC4899)),
  teal(Color(0xFF14B8A6)),
  // Gray is the system Default network's color. Distinct from the saturated
  // user-pickable colors above; conveys "neutral / fallback".
  gray(Color(0xFF71717A));

  const GroupColor(this.value);
  final Color value;

  /// 18% alpha tint for use as fill behind icon containers and pills.
  Color get tint => value.withValues(alpha: 0.18);
}

/// Single source of truth for a group's accent color token.
///
/// A user-picked [colorIndex] (an index into `AppColors.v3GroupColors`,
/// whose first eight entries line up 1:1 with [GroupColor.red] … .teal)
/// always wins; otherwise fall back to the legacy deterministic name-hash
/// color so untouched groups keep looking the way they always did.
///
/// Used everywhere a group is drawn - the Hosts grid group cards, the
/// mobile Hosts home page, and the desktop fast-connect panel - so a color
/// the user picks in the folder editor shows up consistently across all of
/// them.
GroupColor resolveGroupColorToken({
  required int? colorIndex,
  required String name,
}) {
  if (colorIndex != null && colorIndex >= 0) {
    return GroupColor.values[colorIndex % GroupColor.values.length];
  }
  return GroupColor.values[name.hashCode.abs() % GroupColor.values.length];
}

/// Resolve a group's accent to a concrete [Color], honouring a custom
/// [colorValue] (an ARGB int from `Color.toARGB32()`).
///
/// A non-null [colorValue] lets the user persist ANY colour and always wins;
/// otherwise this falls back to the legacy [resolveGroupColorToken] token
/// (a picked [colorIndex], else the name-hash colour). A null [colorValue]
/// therefore behaves exactly as before. Use this at every group draw site so a
/// custom colour shows up consistently; callers that specifically need the
/// closed [GroupColor] enum keep using [resolveGroupColorToken].
Color resolveGroupColor({
  required int? colorValue,
  required int? colorIndex,
  required String name,
}) {
  if (colorValue != null) return Color(colorValue);
  return resolveGroupColorToken(colorIndex: colorIndex, name: name).value;
}

