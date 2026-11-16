import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/models/pane_layout.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/providers/core_providers.dart';

final paneTreeProvider = StateNotifierProvider<PaneTreeNotifier, PaneNode?>(
  (ref) => PaneTreeNotifier(ref),
);

final focusedPaneProvider = StateProvider<String?>((ref) => null);

class PaneTreeNotifier extends StateNotifier<PaneNode?> {
  final Ref _ref;

  PaneTreeNotifier(this._ref) : super(null);

  void initSinglePane(String sessionId) {
    state = PaneLeaf.single(sessionId: sessionId);
  }

  /// Split the leaf identified by [leafId] along [axis] and place a new
  /// terminal leaf for [secondSessionId] on the trailing side.
  ///
  /// Returns `true` if the split was applied, `false` if [leafId] could
  /// not be found in the current tree (typically because focus state
  /// is stale from a previous tab's tree). Callers should treat `false`
  /// as a failure and undo any side effects (e.g. end an orphan
  /// session that was started in anticipation of this split).
  bool splitPane(String leafId, Axis axis, String secondSessionId) {
    if (state == null) return false;
    final target = state!.findLeaf(leafId);
    if (target == null) return false;

    final newLeaf = PaneLeaf.single(sessionId: secondSessionId);
    final split = PaneSplit(
      first: target,
      second: newLeaf,
      axis: axis,
    );

    // The room is shared again after the split, so that panes side by
    // side are as wide as each other (2 → 50/50, 3 → 33/33/33, ...). Left
    // alone, the binary tree compounds its halves into 50/25/25. A divider
    // someone moved stays where it was put.
    state = rebalancePaneTree(replacePaneLeaf(state!, leafId, split), since: state);
    return true;
  }

  /// Same contract as [splitPane] but inserts an SFTP-typed leaf
  /// instead of a terminal leaf. Returns `true` on success.
  bool splitPaneWithSftp(String leafId, Axis axis, String sessionId) {
    if (state == null) return false;
    final target = state!.findLeaf(leafId);
    if (target == null) return false;

    final newLeaf = PaneLeaf.single(sessionId: sessionId, type: 'sftp');
    final split = PaneSplit(
      first: target,
      second: newLeaf,
      axis: axis,
    );

    // (SFTP shows in its dock: no pane gets wider or narrower for it.)
    state = rebalancePaneTree(replacePaneLeaf(state!, leafId, split), since: state);
    return true;
  }

  /// What is left once panes were taken out of [before]. A tree that came
  /// down to a single leaf is cleared, so single-tab mode uses IndexedStack
  /// (which responds to desktopSelectedTabProvider). Otherwise the ones
  /// that stay share the freed room: a tab that stood in its grid stands in
  /// the grid for what is left, any other keeps its arrangement.
  PaneNode? _left(PaneNode before, PaneNode? after) =>
      after == null || after is PaneLeaf ? null : settledAfterRemoval(before, after);

  void closePane(String leafId) {
    final before = state;
    if (before == null) return;
    state = _left(before, removePaneLeaf(before, leafId));
  }

  /// Remove a session from the tree. If it was the last session in a leaf,
  /// the leaf itself is removed, and the room is shared again.
  void removeLeafBySessionId(String sessionId) {
    final before = state;
    if (before == null) return;
    final after = removeSessionFromPanes(before, sessionId);
    // (A session that only left a pane's tabs takes no pane with it.)
    state = after != null && after.allLeaves.length == before.allLeaves.length ? after : _left(before, after);
  }

  /// Set the active tab index within a specific pane leaf.
  void setActiveTab(String leafId, int index) {
    if (state == null) return;
    final leaf = state!.findLeaf(leafId);
    if (leaf == null) return;
    state = replacePaneLeaf(state!, leafId, leaf.withActiveIndex(index));
  }

  /// Cycle to the next tab in the currently focused pane.
  void nextTabInPane() {
    final tree = state;
    if (tree == null) return;
    final focusedId = _ref.read(focusedPaneProvider);
    if (focusedId == null) return;
    final leaf = tree.findLeaf(focusedId);
    if (leaf == null || leaf.sessionIds.length < 2) return;
    final next = (leaf.activeIndex + 1) % leaf.sessionIds.length;
    state = replacePaneLeaf(tree, focusedId, leaf.withActiveIndex(next));
  }

  /// Cycle to the previous tab in the currently focused pane.
  void prevTabInPane() {
    final tree = state;
    if (tree == null) return;
    final focusedId = _ref.read(focusedPaneProvider);
    if (focusedId == null) return;
    final leaf = tree.findLeaf(focusedId);
    if (leaf == null || leaf.sessionIds.length < 2) return;
    final prev =
        (leaf.activeIndex - 1 + leaf.sessionIds.length) % leaf.sessionIds.length;
    state = replacePaneLeaf(tree, focusedId, leaf.withActiveIndex(prev));
  }

  /// Add a session tab to an existing pane leaf.
  void addSessionToPane(String leafId, String sessionId) {
    if (state == null) return;
    final leaf = state!.findLeaf(leafId);
    if (leaf == null) return;
    state = replacePaneLeaf(state!, leafId, leaf.withAddedSession(sessionId));
  }

  /// Keeps where the divider of the split [splitId] was dragged to: the
  /// share of its first side.
  void setSplitRatio(String splitId, double ratio) {
    final tree = state;
    if (tree == null) return;
    state = withSplitRatio(tree, splitId, ratio);
  }

  /// Replace a placeholder leaf (sessionIds empty) with a real leaf carrying
  /// [sessionId]. The replacement preserves the original leaf id and pane
  /// [PaneLeaf.type] so SFTP placeholders stay as SFTP panes.
  ///
  /// No-op if the leaf isn't found or isn't actually a placeholder - guards
  /// against races where the user clicks the placeholder twice or the layout
  /// has already been re-sorted.
  void fillPlaceholderLeaf(String leafId, String sessionId) {
    if (state == null) return;
    final leaf = state!.findLeaf(leafId);
    if (leaf == null || !leaf.isPlaceholder) return;
    final replacement = PaneLeaf(
      id: leaf.id,
      sessionIds: [sessionId],
      type: leaf.type,
    );
    state = replacePaneLeaf(state!, leafId, replacement);
  }

  /// Re-target an SFTP leaf to a different SSH session. Used by the SFTP
  /// pane header's connection picker (Stage 3) so the user can flip a
  /// remote pane from `log-store` to `db-primary` without closing it.
  ///
  /// Preserves the leaf id and `type='sftp'` so widget identity is stable
  /// (Flutter still tears down the old `_SftpLeafPane` state because the
  /// constructor sessionId changes - but the surrounding pane geometry,
  /// split ratios, etc. all stay put).
  void retargetSftpLeaf(String leafId, String newSessionId) {
    if (state == null) return;
    final leaf = state!.findLeaf(leafId);
    if (leaf == null) return;
    final replacement = PaneLeaf(
      id: leaf.id,
      sessionIds: [newSessionId],
      type: leaf.type,
    );
    state = replacePaneLeaf(state!, leafId, replacement);
  }

  /// Close a specific session tab within a pane. If it was the last tab,
  /// the entire pane is removed from the tree.
  void closeTabInPane(String leafId, String sessionId) {
    if (state == null) return;
    final leaf = state!.findLeaf(leafId);
    if (leaf == null) return;
    if (leaf.sessionIds.length <= 1) {
      // Last tab - remove the whole pane, and share its room.
      final before = state!;
      state = _left(before, removePaneLeaf(before, leafId));
    } else {
      state = replacePaneLeaf(
          state!, leafId, leaf.withRemovedSession(sessionId));
    }
  }

  /// Reorder a tab within the same pane leaf - move from [oldIndex] to [newIndex].
  void reorderTabInPane(String leafId, int oldIndex, int newIndex) {
    if (state == null) return;
    final leaf = state!.findLeaf(leafId);
    if (leaf == null) return;
    final ids = List<String>.from(leaf.sessionIds);
    if (oldIndex < 0 || oldIndex >= ids.length) return;
    if (newIndex < 0 || newIndex >= ids.length) return;
    final item = ids.removeAt(oldIndex);
    ids.insert(newIndex, item);
    // Adjust active index to follow the moved tab
    int active = leaf.activeIndex;
    if (active == oldIndex) {
      active = newIndex;
    } else if (oldIndex < active && newIndex >= active) {
      active--;
    } else if (oldIndex > active && newIndex <= active) {
      active++;
    }
    state = replacePaneLeaf(
      state!,
      leafId,
      PaneLeaf(
        id: leaf.id,
        sessionIds: ids,
        activeIndex: active.clamp(0, ids.length - 1),
        type: leaf.type,
      ),
    );
  }

  /// Split a pane and place the new session on a specific side.
  /// [insertBefore] = true means new pane goes first (left/top). The room
  /// is shared again, as after every split ([splitPane]).
  void splitPaneDirectional(
      String leafId, Axis axis, String newSessionId, bool insertBefore) {
    if (state == null) return;
    final target = state!.findLeaf(leafId);
    if (target == null) return;

    final newLeaf = PaneLeaf.single(sessionId: newSessionId);
    final split = PaneSplit(
      first: insertBefore ? newLeaf : target,
      second: insertBefore ? target : newLeaf,
      axis: axis,
    );

    state = rebalancePaneTree(replacePaneLeaf(state!, leafId, split), since: state);
  }

  void setTree(PaneNode? newTree) {
    state = newTree;
  }

  /// Swap the sessions occupying two pane leaves. Used when a SessionInfoBar
  /// is dragged onto another pane to reorder panes within a split layout.
  /// If either leaf cannot be found, this is a no-op.
  void swapPaneSessions(String leafIdA, String leafIdB) {
    if (state == null || leafIdA == leafIdB) return;
    final leafA = state!.findLeaf(leafIdA);
    final leafB = state!.findLeaf(leafIdB);
    if (leafA == null || leafB == null) return;

    // Create swapped leaves preserving original leaf IDs and types.
    final swappedA = PaneLeaf(
      id: leafA.id,
      sessionIds: List<String>.from(leafB.sessionIds),
      activeIndex: leafB.activeIndex,
      type: leafB.type,
    );
    final swappedB = PaneLeaf(
      id: leafB.id,
      sessionIds: List<String>.from(leafA.sessionIds),
      activeIndex: leafA.activeIndex,
      type: leafA.type,
    );

    var newTree = replacePaneLeaf(state!, leafIdA, swappedA);
    newTree = replacePaneLeaf(newTree, leafIdB, swappedB);
    state = newTree;
  }

  void moveFocus(AxisDirection direction) {
    final tree = state;
    if (tree == null) return;
    final leaves = tree.allLeaves;
    if (leaves.length < 2) return;

    final focusedId = _ref.read(focusedPaneProvider);
    final currentIndex = leaves.indexWhere((l) => l.id == focusedId);
    if (currentIndex < 0) {
      _ref.read(focusedPaneProvider.notifier).state = leaves.first.id;
      return;
    }

    int nextIndex;
    switch (direction) {
      case AxisDirection.right:
      case AxisDirection.down:
        nextIndex = (currentIndex + 1) % leaves.length;
      case AxisDirection.left:
      case AxisDirection.up:
        nextIndex = (currentIndex - 1 + leaves.length) % leaves.length;
    }
    _ref.read(focusedPaneProvider.notifier).state = leaves[nextIndex].id;
  }
}

final paneTreePersistenceProvider = Provider<void>((ref) {
  ref.listen<PaneNode?>(paneTreeProvider, (prev, next) {
    final prefs = ref.read(sharedPreferencesProvider);
    if (next != null) {
      prefs.setString('desktop_pane_layout', jsonEncode(next.toJson()));
    } else {
      prefs.remove('desktop_pane_layout');
    }
  });
});
