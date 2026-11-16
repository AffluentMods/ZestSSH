import 'package:flutter/material.dart';

/// The picker sections of the host-card icon catalog. Order is display order.
enum HostIconCategory {
  /// OS and platform marks (Ubuntu, Proxmox, Docker, ...).
  os,
  hardware,
  network,

  /// Cloud, virtualisation and orchestration.
  cloud,
  services,
  security,
  places,

  /// Labels with no infrastructure meaning (star, flame, production, ...).
  tags,
}

class OsDescriptor {
  const OsDescriptor({
    required this.id,
    required this.displayName,
    required this.brandColor,
    required this.iconBuilder,
    required this.category,
    this.keywords = const [],
    this.glyphScale = 1.0,
  });
  final String id;
  final String displayName;

  /// The colour used when the host itself has no colour label: the brand
  /// colour for an OS mark, a category colour for a generic icon.
  final Color brandColor;
  final Widget Function(double size, Color color) iconBuilder;
  final HostIconCategory category;

  /// Extra search terms beyond the id and the name (`k8s`, `docker`, `pi`).
  final List<String> keywords;

  /// Per-logo visual-size correction. A few marks (Debian's swirl, Fedora's
  /// disc) leave a lot of empty margin inside their 24x24 viewBox, so at the
  /// shared glyph size they read smaller than logos that fill the box. This
  /// multiplies the glyph size for just those, filling more of the tile. The
  /// tile leaves ~1/3 slack around the glyph, so keep this at or below ~1.4 so
  /// the mark never overflows its tile.
  final double glyphScale;
}
