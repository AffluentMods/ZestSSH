import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show TextScaler;
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// User-tunable customisation knobs for the Hosts grid.
///
/// Persisted as JSON in SharedPreferences (see
/// [hostCardSettingsProvider]). Every field has a sensible default so
/// the JSON can be missing fields without crashing.

/// How tightly cards pack vertically and how big the typography is.
enum HostCardDensity {
  /// 56px tall, smaller font - fits more on screen.
  compact(56, 13, 10, 32),

  /// 64px tall - the default: a short, dense card.
  comfortable(64, 14, 11, 36),

  /// 80px tall - generous touch targets, easier to read at a glance.
  spacious(80, 15, 12, 40);

  const HostCardDensity(this.cardHeight,
      this.titleFontSize, this.subtitleFontSize, this.iconSize);

  /// Its name in the person's language (each kept an English one, which
  /// Settings showed, whatever the language).
  String nameIn(AppLocalizations l10n) => switch (this) {
        HostCardDensity.compact => l10n.hostCardDensityCompact,
        HostCardDensity.comfortable => l10n.hostCardDensityComfortable,
        HostCardDensity.spacious => l10n.hostCardDensitySpacious,
      };

  /// Card height in logical pixels.
  final double cardHeight;

  /// Title font size.
  final double titleFontSize;

  /// Subtitle / metadata font size.
  final double subtitleFontSize;

  /// OS icon size.
  final double iconSize;

  /// The room above and below a card's two lines: less on a compact card,
  /// whose second line was cut off by 5 pixels in its 56.
  double get verticalPadding => this == HostCardDensity.compact ? 8 : 12;

  /// The card's height at the text size [scaler] gives (a larger one a
  /// phone or a computer can be set to): [cardHeight] at the size the app
  /// is drawn at, and as much more as its two lines of text grow, so that
  /// the second is not cut off (it was, by 9 pixels at 1.25 times).
  double heightFor(TextScaler scaler) =>
      cardHeight +
      1.6 *
          (scaler.scale(titleFontSize) - titleFontSize + scaler.scale(subtitleFontSize) - subtitleFontSize);
}

/// Column count override.  `auto` defers to the responsive layout
/// math (1/2/3/4 cols based on viewport width); the integer values
/// pin a specific count so power-users with ultra-wide monitors can
/// say "I always want 5 columns".
enum HostCardColumns {
  auto(null),
  one(1),
  two(2),
  three(3),
  four(4),
  five(5),
  six(6);

  const HostCardColumns(this.fixedCount);
  final int? fixedCount;

  /// Its name in the person's language.
  String nameIn(AppLocalizations l10n) =>
      fixedCount == null ? l10n.hostCardColumnsAuto : l10n.hostCardColumnsCount(fixedCount!);
}

/// Accent tint applied to the left rail / status ring: the host's colour
/// (its own label's, or its group's), the app's accent on every card, or
/// none. None by default since 4.0 (the
/// stripe repeated the group's colour on every card of it).
enum HostCardAccentMode {
  group,
  uniform,
  none;

  /// Its name in the person's language, for what it draws: the uniform one
  /// is the app's accent colour, which brand colours change (it was named
  /// "Uniform orange", in English, whatever the language and the colour).
  String nameIn(AppLocalizations l10n) => switch (this) {
        HostCardAccentMode.group => l10n.hostCardAccentHostColor,
        HostCardAccentMode.uniform => l10n.hostCardAccentAppColor,
        HostCardAccentMode.none => l10n.hostCardAccentNone,
      };
}

@immutable
class HostCardSettings {
  const HostCardSettings({
    this.density = HostCardDensity.comfortable,
    this.columns = HostCardColumns.auto,
    this.accentMode = HostCardAccentMode.none,
    this.showStatusPill = true,
    this.showOsIcon = true,
    this.showSubtitle = true,
    this.showHoverEdit = true,
    this.showTags = false,
  });

  /// What the settings are written with: 2 since the 4.0 cards (no stripe
  /// and no tags by default). A blob without it was written by an older app,
  /// which wrote every field, its default stripe among them.
  static const version = 2;

  final HostCardDensity density;
  final HostCardColumns columns;
  final HostCardAccentMode accentMode;

  /// Whether the card says it is open ("Open", "2 open") on its right.
  final bool showStatusPill;

  /// OS icon on the left.  Hiding it gives more horizontal room for
  /// long hostnames.
  final bool showOsIcon;

  /// "user@host:port · SSH" subtitle line under the name.
  final bool showSubtitle;

  /// Hover-revealed pencil affordance.  Some users prefer to
  /// right-click for everything and find the pencil distracting.
  final bool showHoverEdit;

  /// The host's tags on its card, after its name. Off by default since 4.0:
  /// the list view and the host's panel show them.
  final bool showTags;

  HostCardSettings copyWith({
    HostCardDensity? density,
    HostCardColumns? columns,
    HostCardAccentMode? accentMode,
    bool? showStatusPill,
    bool? showOsIcon,
    bool? showSubtitle,
    bool? showHoverEdit,
    bool? showTags,
  }) {
    return HostCardSettings(
      density: density ?? this.density,
      columns: columns ?? this.columns,
      accentMode: accentMode ?? this.accentMode,
      showStatusPill: showStatusPill ?? this.showStatusPill,
      showOsIcon: showOsIcon ?? this.showOsIcon,
      showSubtitle: showSubtitle ?? this.showSubtitle,
      showHoverEdit: showHoverEdit ?? this.showHoverEdit,
      showTags: showTags ?? this.showTags,
    );
  }

  Map<String, dynamic> toJson() => {
        'v': version,
        'density': density.name,
        'columns': columns.name,
        'accentMode': accentMode.name,
        'showStatusPill': showStatusPill,
        'showOsIcon': showOsIcon,
        'showSubtitle': showSubtitle,
        'showHoverEdit': showHoverEdit,
        'showTags': showTags,
      };

  static HostCardSettings fromJson(Map<String, dynamic> json) {
    final accent = _enumByName(
      HostCardAccentMode.values,
      json['accentMode'] as String?,
    );
    return HostCardSettings(
      density: _enumByName(
            HostCardDensity.values,
            json['density'] as String?,
          ) ??
          HostCardDensity.comfortable,
      columns: _enumByName(
            HostCardColumns.values,
            json['columns'] as String?,
          ) ??
          HostCardColumns.auto,
      // An older app wrote its default stripe (the host's colour) with
      // whatever else was changed (a density, the columns): that is the
      // default it had, not a choice, and takes the new default. A stripe
      // in the app's colour, or none, was a choice and stays.
      accentMode: accent == null || (accent == HostCardAccentMode.group && json['v'] == null)
          ? HostCardAccentMode.none
          : accent,
      showStatusPill: json['showStatusPill'] as bool? ?? true,
      showOsIcon: json['showOsIcon'] as bool? ?? true,
      showSubtitle: json['showSubtitle'] as bool? ?? true,
      showHoverEdit: json['showHoverEdit'] as bool? ?? true,
      showTags: json['showTags'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is HostCardSettings &&
        other.density == density &&
        other.columns == columns &&
        other.accentMode == accentMode &&
        other.showStatusPill == showStatusPill &&
        other.showOsIcon == showOsIcon &&
        other.showSubtitle == showSubtitle &&
        other.showHoverEdit == showHoverEdit &&
        other.showTags == showTags;
  }

  @override
  int get hashCode => Object.hash(
        density,
        columns,
        accentMode,
        showStatusPill,
        showOsIcon,
        showSubtitle,
        showHoverEdit,
        showTags,
      );
}

/// Generic name-tolerant enum lookup. Used for forward-compat: a
/// future build might add new HostCardDensity values; loading prefs
/// from an older build with a now-removed name should fall back to
/// the default rather than crash.
T? _enumByName<T extends Enum>(List<T> values, String? name) {
  if (name == null) return null;
  for (final v in values) {
    if (v.name == name) return v;
  }
  return null;
}
