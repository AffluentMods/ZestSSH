import 'package:flutter/widgets.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Shared, semantic icon constants so a glyph's MEANING is fixed in one place
/// and the same concept never renders with two different glyphs across the app.
///
/// §8 fix: the status-bar "Arrange panes" control and the Workspaces feature
/// previously BOTH used the four-square grid glyph, so one glyph carried two
/// meanings. These two constants split them cleanly:
///
/// * [workspaces] keeps the four-square grid: a saved set of tabs + panes you
///   can relaunch.
/// * [arrangePanes] takes a distinct panel-layout glyph for rearranging the
///   split terminals on screen.
///
/// Consume these at every Workspaces / Arrange draw site instead of hard-coding
/// a [LucideIcons] value, so the two concepts never collide on one glyph again.
abstract final class ZestIcons {
  /// Workspaces: a saved set of tabs + panes you can relaunch. Four-square
  /// grid, matching the Workspaces surfaces in the design mockups.
  static const IconData workspaces = LucideIcons.layoutGrid;

  /// "Arrange panes": rearranging the split terminals on screen (the
  /// status-bar layout-preset control). A panel-layout glyph, deliberately
  /// DISTINCT from [workspaces] so the two actions never share a glyph.
  static const IconData arrangePanes = LucideIcons.layoutPanelLeft;
}
