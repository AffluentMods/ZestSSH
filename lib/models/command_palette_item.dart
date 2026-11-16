import 'package:flutter/widgets.dart';

enum CommandCategory {
  /// Recently-used sessions + connections, surfaced at the top of the
  /// palette when the query is empty (A9). Not a real "kind" of item -
  /// items are re-tagged into this bucket by recency.
  recent,
  activeSession,
  connection,
  snippet,
  action,
}

class CommandPaletteItem {
  final String id;

  /// Mutable so recency promotion (A9) can re-tag an item into
  /// [CommandCategory.recent] for the empty-query view.
  CommandCategory category;
  final String title;

  /// What the action does, in a line under its name (the palette's second
  /// line, 4.0). Mutable so recency promotion can swap in an
  /// action-oriented subtitle ("Connect · 4m ago", "Switch to session").
  String? subtitle;
  final IconData icon;
  final VoidCallback onSelect;

  /// Optional accelerator label (e.g. "Ctrl+Shift+N"), rendered as a
  /// keycap on the tile. Sourced live from the user's current bindings
  /// so it never drifts from what actually fires.
  final String? shortcut;

  /// Optional family of a [CommandCategory.action] item, e.g. "Layout &
  /// panes", "Window", "Sessions": how the desktop shell keeps its actions
  /// together. The palette lists every action under Actions (4.0: Hosts,
  /// Actions, Snippets), in the order given.
  final String? group;

  double score;

  CommandPaletteItem({
    required this.id,
    required this.category,
    required this.title,
    this.subtitle,
    required this.icon,
    required this.onSelect,
    this.shortcut,
    this.group,
    this.score = 0.0,
  });
}
