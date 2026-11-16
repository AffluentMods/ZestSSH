import 'package:zestssh/models/pane_tree.dart';

/// The arrangement each tab had before one of its panes was maximised (the
/// computer's Maximize pane, and Restore pane layout), kept by tab id.
///
/// It was one arrangement for the whole window: a pane maximised in one tab
/// and Restore pressed in another put the first tab's arrangement, with its
/// terminals, into the tab in front, and the menu offered Restore in every
/// tab.
class MaximizedPanes {
  final _saved = <String, PaneNode>{};

  /// Whether the tab [tabId] has a pane maximised.
  bool isMaximized(String? tabId) => tabId != null && _saved.containsKey(tabId);

  /// What the tab [tabId] shows after Maximize pane or Restore, with [tree]
  /// its arrangement on screen and [focused] the pane in front: its own
  /// arrangement from before, where one of its panes is maximised; else the
  /// pane [focused] alone, where the tab has panes side by side. Null where
  /// nothing changes.
  PaneNode? toggle(String tabId, PaneNode? tree, String focused) {
    final saved = _saved.remove(tabId);
    if (saved != null) return saved;
    if (tree is! PaneSplit) return null;
    final leaf = tree.findLeaf(focused);
    if (leaf == null) return null;
    _saved[tabId] = tree;
    return PaneLeaf(id: leaf.id, sessionIds: List.of(leaf.sessionIds), activeIndex: leaf.activeIndex, type: leaf.type);
  }

  /// Forgets the arrangement kept for [tabId]: the tab was arranged anew.
  void forget(String? tabId) => _saved.remove(tabId);

  /// Forgets the arrangements of tabs that are no longer open.
  void keepOnly(Iterable<String> openTabIds) {
    final open = openTabIds.toSet();
    _saved.removeWhere((id, _) => !open.contains(id));
  }
}
