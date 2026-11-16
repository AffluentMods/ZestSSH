import 'package:flutter/widgets.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Static lookup from icon codePoint → const [IconData].
///
/// Why this exists: Flutter's release-mode icon tree-shaker only
/// keeps `IconData` instances that were declared as `const`.
/// Constructing an `IconData(row.iconCodePoint, …)` at runtime from
/// a database row trips the tree-shaker and fails the build:
///
///     This application cannot tree shake icons fonts. It has
///     non-constant instances of IconData at … network_repository.dart
///
/// So instead of rebuilding the IconData from raw fields each time
/// we read a Network row, we look up the codePoint in a pre-built
/// map of *const* IconData values.  Anything in this map gets
/// preserved by the tree-shaker; anything else falls back to
/// [defaultNetworkIcon] (also const).
///
/// Extending the set: just add another entry below.  Existing
/// stored networks remain compatible because the storage key is
/// the icon's codePoint - keep that stable.
const IconData defaultNetworkIcon = LucideIcons.globe;

/// Allowed network icons, ordered for the editor's picker grid.
/// First entry is the default for new networks.
const List<IconData> networkIconChoices = <IconData>[
  LucideIcons.home,
  LucideIcons.briefcase,
  LucideIcons.building,
  LucideIcons.coffee,
  LucideIcons.wifi,
  LucideIcons.signal,
  LucideIcons.cloud,
  LucideIcons.globe,
  LucideIcons.shield,
  LucideIcons.lock,
  LucideIcons.airplay,
  LucideIcons.network,
];

/// Resolve a stored icon codePoint back into a const [IconData].
///
/// Returns [defaultNetworkIcon] if the codePoint isn't in the
/// known catalog - keeps the row renderable when older / newer
/// builds disagree on the catalog contents (forward + backward
/// compatible).
IconData iconForCodePoint(int codePoint) {
  for (final icon in networkIconChoices) {
    if (icon.codePoint == codePoint) return icon;
  }
  return defaultNetworkIcon;
}
