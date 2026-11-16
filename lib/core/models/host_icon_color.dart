import 'dart:ui';

/// What colours a host's icon (3.0).
///
/// By default an icon is drawn in its own colour: a logo's brand colour, a
/// category's colour. The person may have it take the colour of the host's
/// label instead (its own, else its group's: the colour its card shows), or
/// give it a colour of their choosing. An uploaded picture is never tinted.
///
/// The choice is one number, `connections.icon_color`:
///
///  * null: the icon's own colour;
///  * [followsLabel] (0): the colour of the host's label;
///  * anything else: the custom colour, as ARGB. A custom colour is always
///    opaque, so it is never 0.
///
/// Every number has a meaning, so a value that came from another device or
/// from a teammate can be drawn as it is.
abstract final class HostIconColor {
  /// Stored for an icon that takes the colour of the host's label.
  static const int followsLabel = 0;

  /// What to store for the custom colour [color].
  static int custom(Color color) => 0xFF000000 | (color.toARGB32() & 0x00FFFFFF);

  /// Whether [stored] is a colour of the person's choosing.
  static bool isCustom(int? stored) => stored != null && stored != followsLabel;

  /// The custom colour [stored] holds, or null when it holds none.
  static Color? customColor(int? stored) => isCustom(stored) ? Color(custom(Color(stored!))) : null;

  /// The colour to draw the icon in, or null for the icon's own.
  ///
  /// [labelColor] is the colour of the host's label (its own, else its
  /// group's), null when the host has neither: an icon that follows it then
  /// keeps its own colour until the host has one.
  static Color? tint(int? stored, {required Color? labelColor}) {
    if (stored == null) return null;
    if (stored == followsLabel) return labelColor;
    return customColor(stored);
  }

  /// [value] as it may be kept when it comes from outside the app (a sync
  /// payload): the choice it is, or null (the icon's own colour) when it is
  /// no number a colour can be. Nothing the app itself wrote is changed.
  static int? fromOutside(Object? value) {
    if (value is! int) return null;
    if (value < 0 || value > 0xFFFFFFFF) return null;
    return value;
  }
}
