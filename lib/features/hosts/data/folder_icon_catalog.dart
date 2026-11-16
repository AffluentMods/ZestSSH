import 'package:flutter/widgets.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Curated icon set + static codePoint → const [IconData] lookup for
/// connection groups (folders).
///
/// Why this exists - the SAME reason as `network_icon_catalog.dart`:
/// Flutter's release-mode icon tree-shaker only keeps `IconData`
/// instances that were declared as `const`. Rebuilding an
/// `IconData(row.iconCodePoint, …)` at runtime from a database row trips
/// the tree-shaker and fails the build:
///
///     This application cannot tree shake icons fonts. It has
///     non-constant instances of IconData at …
///
/// So instead of reconstructing the IconData from the stored codePoint we
/// look the codePoint up in this pre-built list of *const* IconData
/// values. Anything in [folderIconChoices] is preserved by the tree-shaker;
/// anything else falls back to [defaultFolderIcon] (also const).
///
/// Extending the set: just add another entry below. Existing stored groups
/// stay compatible because the persistence key is the icon's codePoint -
/// keep those stable and only ever append.
const IconData defaultFolderIcon = LucideIcons.folder;

/// Allowed folder icons, ordered for the editor's picker grid. First entry
/// is the default folder glyph. Curated for grouping servers / hosts.
const List<IconData> folderIconChoices = <IconData>[
  LucideIcons.folder,
  LucideIcons.server,
  LucideIcons.database,
  LucideIcons.cloud,
  LucideIcons.shield,
  LucideIcons.home,
  LucideIcons.briefcase,
  LucideIcons.globe,
  LucideIcons.cpu,
  LucideIcons.hardDrive,
  LucideIcons.network,
  LucideIcons.box,
  LucideIcons.boxes,
  LucideIcons.layers,
  LucideIcons.flaskConical,
  LucideIcons.gamepad2,
  LucideIcons.terminal,
  LucideIcons.monitor,
  LucideIcons.container,
  LucideIcons.rocket,
  LucideIcons.users,
  LucideIcons.code2,
  LucideIcons.building,
  LucideIcons.lock,
];

/// Resolve a stored folder-icon codePoint back into a const [IconData].
///
/// Returns [defaultFolderIcon] when [codePoint] is null (no explicit pick)
/// or isn't in the known catalog - keeps the row renderable when older /
/// newer builds disagree on the catalog contents (forward + backward
/// compatible), and keeps the tree-shaker happy.
IconData folderIconFor(int? codePoint) {
  if (codePoint == null) return defaultFolderIcon;
  for (final icon in folderIconChoices) {
    if (icon.codePoint == codePoint) return icon;
  }
  return defaultFolderIcon;
}
