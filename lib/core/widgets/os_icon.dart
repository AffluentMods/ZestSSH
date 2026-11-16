import 'package:flutter/material.dart';
import '../data/os_catalog.dart';
import '../models/host_icon_color.dart';
import '../models/host_icon_limits.dart';
import '../models/os_descriptor.dart';
import '../theme/zest_colors.dart';

/// The host-card icon, resolving the user's override before the auto OS icon:
/// a custom uploaded image wins, then a chosen built-in catalog id, then the
/// auto-detected OS. Renders in the same tinted tile as [OsIcon] for the
/// built-in cases; a custom image fills the tile.
///
/// A built-in icon is drawn in its own colour unless the person chose
/// otherwise for this host ([iconColor], see [HostIconColor]): the colour of
/// the host's label, or a colour of their own.
class HostIcon extends StatelessWidget {
  const HostIcon({
    super.key,
    this.iconId,
    this.customIcon,
    this.osId,
    this.size = 36,
    this.cornerRadius = 8,
    this.iconColor,
    this.labelColor,
  });

  /// A user-chosen built-in catalog id, used in place of [osId] when set.
  final String? iconId;

  /// A user-uploaded base64 PNG, used in place of everything else when set.
  final String? customIcon;

  /// The auto-detected OS id, the fallback when no override is set.
  final String? osId;
  final double size;
  final double cornerRadius;

  /// What the person chose for the icon's colour, as the host stores it:
  /// null for the icon's own. Ignored for a custom image.
  final int? iconColor;

  /// The colour of the host's label (its own, else its group's), null when it
  /// has neither. Only an icon that follows the label is drawn in it.
  final Color? labelColor;

  @override
  Widget build(BuildContext context) {
    final color = HostIconColor.tint(iconColor, labelColor: labelColor);
    // One a team's record brings is decoded as soon as its card is on screen:
    // only a picture that says it is small, and decoded no larger than drawn.
    final bytes = hostIconBytes(customIcon);
    if (bytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(cornerRadius),
        child: Image.memory(
          bytes,
          width: size,
          height: size,
          cacheWidth: (size * MediaQuery.maybeDevicePixelRatioOf(context).orOne).ceil(),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          // A corrupt image falls back to the built-in icon rather than a
          // broken-image glyph.
          errorBuilder: (_, _, _) => OsIcon(
              osId: iconId ?? osId,
              size: size,
              cornerRadius: cornerRadius,
              color: color),
        ),
      );
    }
    // A chosen built-in icon, else the auto OS icon.
    return OsIcon(
        osId: iconId ?? osId,
        size: size,
        cornerRadius: cornerRadius,
        color: color);
  }

}

extension on double? {
  double get orOne => this ?? 1;
}

class OsIcon extends StatelessWidget {
  const OsIcon({
    super.key,
    required this.osId,
    this.size = 36,
    this.cornerRadius = 8,
    this.color,
  });
  final String? osId;
  final double size;
  final double cornerRadius;

  /// The colour to draw it in; null = the icon's own colour.
  final Color? color;

  /// How much of the colour the tile behind the glyph is.
  static const double tileAlpha = 0.18;

  /// What a glyph must hold against its tile to be seen (WCAG's measure for
  /// what is not text).
  static const double seenAt = 3.0;

  /// The tile behind a glyph drawn in [color], on a host's card.
  static Color tileOf(Color color) =>
      Color.alphaBlend(color.withValues(alpha: tileAlpha), ZestColors.bgSurface);

  /// [color] as an icon is drawn in it on the theme in use: itself where it
  /// holds [seenAt] against the tile it sits on, otherwise the nearest shade
  /// of it that does, the same hue (lighter on a dark theme, darker on a
  /// light one).
  ///
  /// The catalog's colours are the brands' own, and an icon is in its own
  /// colour unless the person chose otherwise, so that colour has to show: on
  /// a dark theme Debian's red and AlmaLinux's blue could not be made out,
  /// and on a light one most of the catalog is too pale. The same goes for
  /// the colour of a label and for a colour picked for the icon: a yellow
  /// on a light theme is a yellow that can be seen.
  static Color seen(Color color) => ZestColors.shadeThat(
      color, (c) => ZestColors.contrast(c, tileOf(c)) >= seenAt, ZestColors.bgSurface);

  /// [os]'s own colour as it is drawn on the theme in use.
  static Color ownColor(OsDescriptor os) => seen(os.brandColor);

  @override
  Widget build(BuildContext context) {
    final os = OsCatalog.get(osId);
    final tint = seen(color ?? os.brandColor);
    // Per-logo correction (os.glyphScale) enlarges marks that under-fill their
    // viewBox so they match the others; the tile's ~1/3 padding absorbs it.
    final glyphSize = size * (24 / 36) * os.glyphScale;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: tileAlpha),
        borderRadius: BorderRadius.circular(cornerRadius),
      ),
      alignment: Alignment.center,
      child: os.iconBuilder(glyphSize, tint),
    );
  }
}
