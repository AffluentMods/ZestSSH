import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/models/pane_layout.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/work_tab.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/pane_tree_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';

/// SharedPreferences key holding serialized [WorkTabsState].
const String _kPersistKey = 'desktop_work_tabs';

/// Source of truth for the desktop top-bar "tab groups" model.
///
/// Each tab owns its own [PaneNode] tree. Switching the active tab swaps the
/// tree exposed by [paneTreeProvider]; existing call sites that read or
/// mutate [paneTreeProvider] continue to work unchanged - their effects are
/// transparently scoped to the active tab.
final workTabsProvider =
    StateNotifierProvider<WorkTabsNotifier, WorkTabsState>(
  (ref) => WorkTabsNotifier(ref),
);

/// Convenience: id of the currently active tab (null when no tabs exist).
final activeWorkTabIdProvider = Provider<String?>((ref) {
  return ref.watch(workTabsProvider).activeTabId;
});

/// Convenience: the active tab object, or null.
final activeWorkTabProvider = Provider<WorkTab?>((ref) {
  return ref.watch(workTabsProvider).activeTab;
});

/// What came of arranging a tab ([WorkTabsNotifier.arrangeTab]).
enum ArrangeOutcome {
  /// The tab stands in the arrangement.
  done,

  /// The arrangement has fewer panes than the tab has terminals: nothing
  /// was changed.
  tooSmall,

  /// There was nothing to arrange.
  nothing,
}

/// Two tabs as they were before [WorkTabsNotifier.mergeTabs] combined them,
/// for [WorkTabsNotifier.undoMerge] (the Undo of "Combined into one tab").
class TabMergeUndo {
  const TabMergeUndo._({
    required this.source,
    required this.dest,
    required this.sourceIndex,
    required this.activeTabId,
    required this.focusedPane,
  });

  /// The tab that was dropped onto the other, and its place in the strip.
  final WorkTab source;
  final int sourceIndex;

  /// The tab it joined, as it was.
  final WorkTab dest;

  /// The tab in front then, and the pane that had the keyboard.
  final String? activeTabId;
  final String? focusedPane;
}

/// The SSH session of each tab last in front, by the tab's id: where a tab's
/// tmux and SFTP act while a local pane has the focus ([sshToolsSessionOf]).
final lastSshSessionOfTabProvider = Provider<Map<String, String>>((ref) => {});

/// The session a tab's tmux and SFTP act on (on a tab with local
/// and SSH panes): [focused] where it speaks SSH,
/// else the one of the tab last in front ([lastInFront]), else the tab's first
/// that does. Null where none of its sessions does: the tab offers neither,
/// and that does not change as the focus moves between its panes.
String? sshToolsSessionOf(
  WorkTab tab,
  Map<String, SessionState> sessions, {
  String? focused,
  String? lastInFront,
}) {
  final ssh = [
    for (final id in tab.terminalSessionIds)
      if (sessions[id]?.speaksSsh ?? false) id,
  ];
  if (focused != null && ssh.contains(focused)) return focused;
  if (lastInFront != null && ssh.contains(lastInFront)) return lastInFront;
  return ssh.firstOrNull;
}

class WorkTabsNotifier extends StateNotifier<WorkTabsState> {
  final Ref _ref;

  /// When true, the [paneTreeProvider] listener should NOT mirror its value
  /// back into [state]. Used to break the feedback loop when we are the ones
  /// driving the change (tab switch, tab create, persistence restore).
  bool _suppressPaneTreeSync = false;

  /// Number of upcoming session creations that should NOT auto-spawn a new
  /// tab. Used by split-pane and "add session to current tab" flows that
  /// route the new session into an existing tab's tree themselves.
  int _expectedNonTabSessions = 0;

  /// Tell the notifier that the *next* new session appearing in
  /// [activeSessionsProvider] should NOT be auto-tabbed. Call this just
  /// before invoking `startSession` for split/duplicate-into-pane flows.
  void expectSplitSession() {
    _expectedNonTabSessions++;
  }

  WorkTabsNotifier(this._ref) : super(const WorkTabsState()) {
    // NOTE: We deliberately do NOT restore tabs from `desktop_work_tabs` on
    // startup. The persisted tab list contains *session ids* from the last
    // process - those ids are always stale on process restart (no live
    // sessions exist yet). Loading them would create phantom "Session not
    // found" panes that linger alongside the user-confirmed restoration in
    // [DesktopShellState._checkRestoredSessions], producing duplicated /
    // four-pane bugs after a merge group is restored.
    //
    // The canonical cross-session restore path is the user-prompted snapshot
    // dialog in `_checkRestoredSessions`, which spawns fresh sessions and
    // rebuilds the WorkTabs cleanly. We only persist (write) on every change
    // for in-session crash recovery / debugging, not for cross-process
    // restoration.
    _clearPersistedTabs();

    // Mirror paneTreeProvider mutations back into the active tab so that all
    // existing call sites (splitPane, closePane, etc.) automatically persist.
    _ref.listen<PaneNode?>(paneTreeProvider, (prev, next) {
      if (_suppressPaneTreeSync) return;
      _onPaneTreeChanged(next);
    });

    // Auto-tab newly created sessions, and drop sessions that disappear.
    _ref.listen<Map<String, SessionState>>(activeSessionsProvider,
        (prev, next) {
      if (prev == null) return;
      final added = next.keys.where((k) => !prev.containsKey(k)).toList();
      for (final sid in added) {
        if (_expectedNonTabSessions > 0) {
          _expectedNonTabSessions--;
          continue; // split/add-to-pane flow will route this elsewhere
        }
        onSessionCreated(sid); // idempotent - no-op if already tabbed
      }
      final removed = prev.keys.where((k) => !next.containsKey(k)).toList();
      for (final sid in removed) {
        removeSession(sid);
      }
    });
  }

  // ── Persistence ─────────────────────────────────────────────────

  /// Drop any stale [_kPersistKey] left over from the previous process, plus
  /// the stale `desktop_pane_layout` mirror written by [paneTreePersistenceProvider].
  /// Both contain session ids that no longer resolve to live sessions on startup.
  void _clearPersistedTabs() {
    final prefs = _ref.read(sharedPreferencesProvider);
    prefs.remove(_kPersistKey);
    prefs.remove('desktop_pane_layout');
  }

  /// Wipe all in-memory tabs and clear the active tab. The pane tree provider
  /// is reset to null. Used by the desktop shell's restore flow before
  /// repopulating tabs from a snapshot, so we never end up with stale and
  /// fresh tabs side by side.
  void clearAllTabs() {
    state = const WorkTabsState();
    _setPaneTreeQuiet(null);
    _persist();
  }

  void _persist() {
    final prefs = _ref.read(sharedPreferencesProvider);
    prefs.setString(_kPersistKey, jsonEncode(state.toJson()));
  }

  // ── Pane tree sync ──────────────────────────────────────────────

  /// Set [paneTreeProvider]'s state without re-entering [_onPaneTreeChanged].
  void _setPaneTreeQuiet(PaneNode? tree) {
    _suppressPaneTreeSync = true;
    try {
      _ref.read(paneTreeProvider.notifier).setTree(tree);
    } finally {
      _suppressPaneTreeSync = false;
    }
  }

  /// Called when [paneTreeProvider] mutates externally (split, close, etc.).
  /// Reflects the new tree onto the active tab. If the tree collapses to
  /// null and we have an active tab, the tab is *not* removed - it just
  /// has a null tree (single-pane mode resumes).
  void _onPaneTreeChanged(PaneNode? tree) {
    final id = state.activeTabId;
    if (id == null) {
      // No active tab - orphaned tree. Ignore.
      return;
    }
    final idx = state.indexOf(id);
    if (idx < 0) return;

    if (tree == null) {
      // Tree was cleared. Keep the tab but note that the collapse has
      // happened - caller (e.g. closeTabInPane) is responsible for
      // closing the tab if appropriate. Leave a stub leaf based on the
      // tab's previous contents so we still have a valid model.
      // NOTE: the existing PaneTreeNotifier emits null when a split
      // collapses to a single leaf; that single-leaf state was already
      // mirrored in our model on the previous mutation, so we can simply
      // ignore null here.
      return;
    }

    final updated = state.tabs[idx].copyWith(paneTree: tree);
    final newTabs = List<WorkTab>.from(state.tabs);
    newTabs[idx] = updated;
    state = state.copyWith(tabs: newTabs);
    _persist();
  }

  // ── Tab lifecycle ───────────────────────────────────────────────

  /// Create a new tab containing a single session and make it active.
  String createTab(String sessionId) {
    final tab = WorkTab(paneTree: PaneLeaf.single(sessionId: sessionId));
    state = state.copyWith(
      tabs: [...state.tabs, tab],
      activeTabId: tab.id,
    );
    _setPaneTreeQuiet(tab.paneTree);
    _syncActiveSessionIndex(tab);
    _persist();
    return tab.id;
  }

  /// Switch the active tab. The tree exposed by [paneTreeProvider] is swapped
  /// to the target tab's tree atomically.
  void setActiveTab(String tabId) {
    final tab = state.tabs.firstWhere(
      (t) => t.id == tabId,
      orElse: () => state.activeTab ?? WorkTab(paneTree: PaneLeaf.single(sessionId: '')),
    );
    if (tab.id != tabId) return; // not found
    state = state.copyWith(activeTabId: tabId);
    _setPaneTreeQuiet(tab.paneTree);
    // CRITICAL: clear focusedPaneProvider so a stale leafId from the
    // previous tab's tree can't slip into a subsequent splitPane() or
    // openSftpForSession() call. Without this reset, splitting after
    // a tab switch silently no-ops (target leaf isn't in the current
    // tree) and the orphan session shows up in the count but never
    // gets rendered.
    _ref.read(focusedPaneProvider.notifier).state = null;
    _syncActiveSessionIndex(tab);
    _persist();
  }

  /// Clear the active tab selection without removing any tabs. Used when the
  /// user clicks a sidebar nav item (Hosts, Snippets, Keys, etc.) - the
  /// terminal area should give way to the sidebar page, while preserving the
  /// tab strip and pane trees so clicking a tab brings the terminal back.
  void clearActiveTab() {
    if (state.activeTabId == null) return;
    state = state.copyWith(clearActive: true);
    // Mirror to the legacy single-session pointer so the terminal-area
    // IndexedStack also resets - otherwise the next tab click starts from
    // a stale index.
    _ref.read(v3ActiveSessionTabProvider.notifier).state = null;
    _persist();
  }

  /// Mirror the tab's first session into the legacy single-pane providers
  /// so [IndexedStack]-based rendering picks the correct visible session.
  void _syncActiveSessionIndex(WorkTab tab) {
    final firstSid = tab.sessionIds.isNotEmpty ? tab.sessionIds.first : null;
    if (firstSid == null) return;
    _ref.read(v3ActiveSessionTabProvider.notifier).state = firstSid;
    final sessions = _ref.read(activeSessionsProvider);
    final keys = sessions.keys
        .where((k) {
          final s = sessions[k];
          return s != null && !s.isHidden;
        })
        .toList();
    final idx = keys.indexOf(firstSid);
    if (idx >= 0) {
      _ref.read(desktopSelectedTabProvider.notifier).state = idx;
    }
  }

  /// Close a tab. If it was the active tab, the next/previous tab becomes
  /// active. Returns the list of session ids that were in the closed tab so
  /// the caller can end them via [activeSessionsProvider.notifier.endSession].
  List<String> closeTab(String tabId) {
    final idx = state.indexOf(tabId);
    if (idx < 0) return const [];

    final removed = state.tabs[idx];
    final removedSessionIds = removed.sessionIds;

    final newTabs = List<WorkTab>.from(state.tabs)..removeAt(idx);
    String? newActiveId = state.activeTabId;
    if (state.activeTabId == tabId) {
      // Pick the next tab to the right, or the last one.
      if (newTabs.isEmpty) {
        newActiveId = null;
      } else {
        newActiveId = newTabs[idx.clamp(0, newTabs.length - 1)].id;
      }
    }

    state = WorkTabsState(tabs: newTabs, activeTabId: newActiveId);
    final newActive = state.activeTab;
    _setPaneTreeQuiet(newActive?.paneTree);
    _persist();

    return removedSessionIds;
  }

  /// Remove a session from whichever tab contains it. If the session was the
  /// last one in its tab, the entire tab is closed.
  void removeSession(String sessionId) {
    final idx = state.tabs.indexWhere((t) => t.contains(sessionId));
    if (idx < 0) return;

    final tab = state.tabs[idx];
    final left = removeSessionFromPanes(tab.paneTree, sessionId);
    if (left == null) {
      // Last session - close the tab.
      closeTab(tab.id);
      return;
    }
    // The ones that stay share the room it had.
    final newTree = settledAfterRemoval(tab.paneTree, left);

    final newTabs = List<WorkTab>.from(state.tabs);
    newTabs[idx] = tab.copyWith(paneTree: newTree);
    state = state.copyWith(tabs: newTabs);
    if (tab.id == state.activeTabId) {
      _setPaneTreeQuiet(newTree);
    }
    _persist();
  }

  /// Merge the source tab into the destination tab ([withTreeAdded]): two
  /// tabs that stand in their grid become one grid, any other source stands
  /// at the right of the destination with its own arrangement, and the room
  /// is shared evenly either way. (It used to be halved at every merge: the
  /// fifth tab joined took half the width, the first two a sixteenth each.)
  /// The source tab is removed; the destination remains active if it was.
  /// Returns what [undoMerge] needs to put both back (null when nothing was
  /// merged).
  TabMergeUndo? mergeTabs(String sourceTabId, String destTabId) {
    if (sourceTabId == destTabId) return null;
    final srcIdx = state.indexOf(sourceTabId);
    final dstIdx = state.indexOf(destTabId);
    if (srcIdx < 0 || dstIdx < 0) return null;

    final src = state.tabs[srcIdx];
    final dst = state.tabs[dstIdx];
    final undo = TabMergeUndo._(
      source: src,
      dest: dst,
      sourceIndex: srcIdx,
      activeTabId: state.activeTabId,
      focusedPane: _ref.read(focusedPaneProvider),
    );

    final mergedTree = withTreeAdded(dst.paneTree, src.paneTree);
    final mergedDst = dst.copyWith(paneTree: mergedTree);

    final newTabs = <WorkTab>[];
    for (var i = 0; i < state.tabs.length; i++) {
      if (i == srcIdx) continue;
      if (i == dstIdx) {
        newTabs.add(mergedDst);
      } else {
        newTabs.add(state.tabs[i]);
      }
    }

    final wasActive = state.activeTabId == sourceTabId ||
        state.activeTabId == destTabId;
    state = WorkTabsState(
      tabs: newTabs,
      activeTabId: wasActive ? destTabId : state.activeTabId,
    );
    if (state.activeTabId == destTabId) {
      _setPaneTreeQuiet(mergedTree);
    }
    _persist();
    return undo;
  }

  /// Puts back the two tabs [mergeTabs] combined ([undo]), as they were:
  /// their panes and arrangement, their places in the strip, the tab that
  /// was in front and its focused pane. The sessions are not touched. Only
  /// while the combined tab still holds just those terminals (one closed or
  /// added since, and there are no two tabs to go back to): false then, and
  /// nothing changes.
  bool undoMerge(TabMergeUndo undo) {
    final idx = state.indexOf(undo.dest.id);
    if (idx < 0 || state.indexOf(undo.source.id) >= 0) return false;
    final now = state.tabs[idx].sessionIds.toSet();
    final then = {...undo.dest.sessionIds, ...undo.source.sessionIds};
    if (now.length != then.length || !now.containsAll(then)) return false;

    final tabs = List<WorkTab>.from(state.tabs);
    // (The combined tab keeps a name, colour or pin given it meanwhile.)
    final merged = tabs[idx];
    tabs[idx] = merged.copyWith(paneTree: undo.dest.paneTree);
    tabs.insert(undo.sourceIndex.clamp(0, tabs.length), undo.source);

    final wasOneOfThem = undo.activeTabId == undo.source.id || undo.activeTabId == undo.dest.id;
    final active = wasOneOfThem ? undo.activeTabId : state.activeTabId;
    state = WorkTabsState(tabs: tabs, activeTabId: active);
    final front = state.activeTab;
    if (front != null && (front.id == undo.source.id || front.id == undo.dest.id)) {
      _setPaneTreeQuiet(front.paneTree);
      // The pane that had the keyboard, where it is in the tab now in front.
      final focus = undo.focusedPane;
      _ref.read(focusedPaneProvider.notifier).state =
          wasOneOfThem && focus != null && front.paneTree.findLeaf(focus) != null ? focus : null;
    }
    _persist();
    return true;
  }

  /// Move [sessionId] out of the group it is in and into [destTabId] as a new
  /// side-by-side pane, reflowing BOTH trees so the panes stay even. If the
  /// session was the last one in its source tab, that tab is dropped. A no-op
  /// if the session is already in the destination, or either tab is missing.
  ///
  /// The destination may be a NON-active tab, so its tree is edited directly in
  /// the tab list (never through [paneTreeProvider], which only mirrors the
  /// active tab). Powers dragging a terminal onto another group's header pill.
  void moveSessionToTab(String sessionId, String destTabId) {
    final srcIdx = state.tabs.indexWhere((t) => t.contains(sessionId));
    final dstIdx = state.indexOf(destTabId);
    if (srcIdx < 0 || dstIdx < 0) return;
    if (state.tabs[srcIdx].id == destTabId) return;

    final src = state.tabs[srcIdx];
    final dst = state.tabs[dstIdx];

    final prunedSrc = removeSessionFromPanes(src.paneTree, sessionId);
    final newDstTree = withPaneAdded(dst.paneTree, PaneLeaf.single(sessionId: sessionId));

    final newTabs = <WorkTab>[];
    for (var i = 0; i < state.tabs.length; i++) {
      if (i == dstIdx) {
        newTabs.add(dst.copyWith(paneTree: newDstTree));
      } else if (i == srcIdx) {
        // prunedSrc == null means the source tab emptied - drop it.
        if (prunedSrc != null) {
          newTabs.add(src.copyWith(paneTree: settledAfterRemoval(src.paneTree, prunedSrc)));
        }
      } else {
        newTabs.add(state.tabs[i]);
      }
    }

    // Stay on the current view unless it was the (now-gone) source tab, in
    // which case follow the session to its new home.
    var activeId = state.activeTabId;
    if (prunedSrc == null && activeId == src.id) {
      activeId = destTabId;
    }
    if (activeId != null && !newTabs.any((t) => t.id == activeId)) {
      activeId = newTabs.isEmpty ? null : newTabs.first.id;
    }
    final followed = activeId != state.activeTabId;
    state = WorkTabsState(tabs: newTabs, activeTabId: activeId);
    _setPaneTreeQuiet(state.activeTab?.paneTree);
    // When the view followed the session to another tab, the tab in front
    // changed: the same as in [splitSessionToNewTab].
    final front = state.activeTab;
    if (followed && front != null) {
      _ref.read(focusedPaneProvider.notifier).state = null;
      _syncActiveSessionIndex(front);
    }
    _persist();
  }

  /// Pop [sessionId] out of its group into its own new tab, reflowing the
  /// group it left, and make the new tab active. The new tab stands right
  /// before the tab [besideTabId], or right [after] it, when one is named
  /// (the terminal was dropped on that tab's edge), and at the end otherwise
  /// (it was dropped on the header's open space). A session that is alone in
  /// its tab already has nothing to leave: its tab is what moves beside the
  /// named one, and nothing happens when none is named. A no-op for a
  /// session that is not tabbed at all.
  void splitSessionToNewTab(String sessionId, {String? besideTabId, bool after = true}) {
    final srcIdx = state.tabs.indexWhere((t) => t.contains(sessionId));
    if (srcIdx < 0) return;
    final src = state.tabs[srcIdx];
    if (src.sessionIds.length <= 1) {
      if (besideTabId != null) moveTabBeside(src.id, besideTabId, after: after);
      return;
    }

    // src has >= 2 sessions, so pruning one always leaves a non-null tree.
    final prunedSrc = removeSessionFromPanes(src.paneTree, sessionId)!;
    final newTab = WorkTab(paneTree: PaneLeaf.single(sessionId: sessionId));

    final newTabs = <WorkTab>[];
    for (var i = 0; i < state.tabs.length; i++) {
      newTabs.add(i == srcIdx
          ? src.copyWith(paneTree: settledAfterRemoval(src.paneTree, prunedSrc))
          : state.tabs[i]);
    }
    // (A tab named that is not there: the end, as when none is named.)
    final beside = besideTabId == null ? -1 : newTabs.indexWhere((t) => t.id == besideTabId);
    if (beside < 0) {
      newTabs.add(newTab);
    } else {
      newTabs.insert(after ? beside + 1 : beside, newTab);
    }

    state = WorkTabsState(tabs: newTabs, activeTabId: newTab.id);
    _setPaneTreeQuiet(newTab.paneTree);
    // The tab in front changed, as in [setActiveTab]: what was focused is a
    // pane of the group that was left, and the single-pane selection still
    // names a session of that group. (Left as they were, the new tab was
    // highlighted while a session of the old group was shown full size, and
    // the status bar, search, paste and the command palette acted on it.)
    _ref.read(focusedPaneProvider.notifier).state = null;
    _syncActiveSessionIndex(newTab);
    _persist();
  }

  /// Puts [sessionIds] together in one tab, in the order given, in the grid
  /// a tab nobody arranged stands in, and shows it: the tab of the first one
  /// when it is alone in it, else a new one. Each of the others comes out of
  /// the tab it was in, alone (a tab left empty goes; a group it leaves
  /// keeps the rest). For "Broadcast to hosts": hosts that are open already
  /// are gathered, not opened twice. Returns the tab; null when none of
  /// [sessionIds] is in a tab.
  String? gatherInTab(List<String> sessionIds) {
    // (One named twice is moved to where it already is the second time:
    // nothing.)
    final ids = <String>[
      for (final id in sessionIds)
        if (tabContaining(id) != null) id,
    ];
    if (ids.isEmpty) return null;
    splitSessionToNewTab(ids.first);
    final dest = tabContaining(ids.first)!.id;
    for (final id in ids.skip(1)) {
      moveSessionToTab(id, dest);
    }
    arrangeTab(dest, null);
    setActiveTab(dest);
    return dest;
  }

  /// Replace the pane tree of [tabId] wholesale. Used by the workspace
  /// launcher to materialise a saved tab snapshot into the live tab.
  void replaceTabTree(String tabId, PaneNode tree) {
    final idx = state.indexOf(tabId);
    if (idx < 0) return;
    final newTabs = List<WorkTab>.from(state.tabs);
    newTabs[idx] = newTabs[idx].copyWith(paneTree: tree);
    state = state.copyWith(tabs: newTabs);
    if (tabId == state.activeTabId) {
      _setPaneTreeQuiet(tree);
    }
    _persist();
  }

  /// The terminal panes of the tab [tabId] that an arrangement works with,
  /// in their order: each with the sessions [shown] says are still shown in
  /// it (one that ended, or went to a window of its own, is not; left out,
  /// every session is). Places to connect that stand empty are not among
  /// them, and SFTP is no pane.
  List<PaneLeaf> arrangeablePanes(String tabId, {bool Function(String sessionId)? shown}) {
    final idx = state.indexOf(tabId);
    if (idx < 0) return const [];
    final out = <PaneLeaf>[];
    for (final leaf in withoutSftp(state.tabs[idx].paneTree)?.allLeaves ?? const <PaneLeaf>[]) {
      if (leaf.isPlaceholder) continue;
      final here = [
        for (final sid in leaf.sessionIds)
          if (shown == null || shown(sid)) sid,
      ];
      if (here.isEmpty) continue;
      out.add(here.length == leaf.sessionIds.length
          ? leaf
          : PaneLeaf(
              id: leaf.id,
              sessionIds: here,
              activeIndex: leaf.activeIndex.clamp(0, here.length - 1),
              type: leaf.type,
            ));
    }
    return out;
  }

  /// Arranges the terminals of the tab [tabId] as [preset]; with no preset,
  /// in the grid a tab nobody arranged stands in ([tilePanes]), which the
  /// tab then keeps to as terminals join and leave it.
  ///
  /// Every pane stays the pane it was (its sessions, its tabs), in the order
  /// they stood in. SFTP is kept at the side of the tree: it shows in its
  /// dock. An arrangement with panes to spare shows those as places to
  /// connect. One with fewer panes than the tab has terminals is not made
  /// ([ArrangeOutcome.tooSmall]): it would have to move terminals out of
  /// sight.
  ArrangeOutcome arrangeTab(String tabId, LayoutPreset? preset, {bool Function(String sessionId)? shown}) {
    final idx = state.indexOf(tabId);
    if (idx < 0) return ArrangeOutcome.nothing;
    final tree = state.tabs[idx].paneTree;
    final leaves = arrangeablePanes(tabId, shown: shown);
    final sftp = sftpLeavesOf(tree);
    final PaneNode terminals;
    if (preset == null) {
      if (leaves.isEmpty) return ArrangeOutcome.nothing;
      terminals = tilePanes(leaves);
    } else {
      // (A tab with nothing but SFTP has nothing to make one pane of.)
      if (leaves.isEmpty && (sftp.isEmpty || preset.panes == 1)) return ArrangeOutcome.nothing;
      final made = treeOfPreset(preset, leaves);
      if (made == null) return ArrangeOutcome.tooSmall;
      terminals = made;
    }
    replaceTabTree(tabId, withSftpAside(terminals, sftp)!);
    return ArrangeOutcome.done;
  }

  /// Moves the tab [tabId] to stand right before the tab [besideTabId], or
  /// right [after] it. Nothing when either is not a tab, or they are the
  /// same one.
  ///
  /// The tabs are named, not counted. A place in the strip is not a place in
  /// this list: the strip shows pinned tabs first and leaves out the tabs
  /// being closed and the ones with nothing to show ([tabsInStripOrder]).
  /// (A drag along the strip was passed on as two places in the strip and
  /// applied to this list, so with a pinned tab that was not first, or a tab
  /// just closed, another tab than the one dragged was moved.)
  void moveTabBeside(String tabId, String besideTabId, {required bool after}) {
    if (tabId == besideTabId) return;
    final from = state.indexOf(tabId);
    if (from < 0 || state.indexOf(besideTabId) < 0) return;
    final tabs = List<WorkTab>.from(state.tabs);
    final tab = tabs.removeAt(from);
    final beside = tabs.indexWhere((t) => t.id == besideTabId);
    tabs.insert(after ? beside + 1 : beside, tab);
    state = state.copyWith(tabs: tabs);
    _persist();
  }

  /// Set a custom display name for a tab.
  void renameTab(String tabId, String? name) {
    final idx = state.indexOf(tabId);
    if (idx < 0) return;
    final newTabs = List<WorkTab>.from(state.tabs);
    final cleaned = (name == null || name.trim().isEmpty) ? null : name.trim();
    newTabs[idx] = newTabs[idx].copyWith(
      customName: cleaned,
      clearCustomName: cleaned == null,
    );
    state = state.copyWith(tabs: newTabs);
    _persist();
  }

  /// Set or clear a per-tab color override. Pass null to revert to the
  /// connection's color.
  void setTabColor(String tabId, int? colorIndex) {
    final idx = state.indexOf(tabId);
    if (idx < 0) return;
    final newTabs = List<WorkTab>.from(state.tabs);
    newTabs[idx] = newTabs[idx].copyWith(
      colorIndex: colorIndex,
      clearColorIndex: colorIndex == null,
    );
    state = state.copyWith(tabs: newTabs);
    _persist();
  }

  /// Toggle the pinned state of a tab. Doesn't reorder the tabs array
  /// (display order is the caller's job - the pill bar sorts pinned
  /// tabs to the front when it builds entries) so reorder + pin
  /// interactions stay independent.
  void togglePin(String tabId) {
    final idx = state.indexOf(tabId);
    if (idx < 0) return;
    final newTabs = List<WorkTab>.from(state.tabs);
    newTabs[idx] = newTabs[idx].copyWith(pinned: !newTabs[idx].pinned);
    state = state.copyWith(tabs: newTabs);
    _persist();
  }

  /// Soft-close a tab: it disappears from the pill strip immediately
  /// (the strip filters out `pendingClose == true`) but its sessions
  /// stay alive. The desktop shell pairs this with a 5-second "Undo"
  /// snackbar - the actual cleanup runs on snackbar dismissal via
  /// [closeTab] + `endSession`.
  ///
  /// If the closing tab was the active one, advances `activeTabId` to
  /// the next visible tab (or null when none remain) so the render
  /// dispatch can swap to the home view immediately.
  void markPendingClose(String tabId) {
    final idx = state.indexOf(tabId);
    if (idx < 0) return;
    final newTabs = List<WorkTab>.from(state.tabs);
    newTabs[idx] = newTabs[idx].copyWith(pendingClose: true);

    String? newActive = state.activeTabId;
    if (state.activeTabId == tabId) {
      // Find a fallback active tab. Prefer the next visible
      // (non-pending) tab, then any pinned visible tab, then null.
      WorkTab? fallback;
      for (var i = idx + 1; i < newTabs.length; i++) {
        if (!newTabs[i].pendingClose) {
          fallback = newTabs[i];
          break;
        }
      }
      if (fallback == null) {
        for (var i = idx - 1; i >= 0; i--) {
          if (!newTabs[i].pendingClose) {
            fallback = newTabs[i];
            break;
          }
        }
      }
      newActive = fallback?.id;
    }

    state = WorkTabsState(tabs: newTabs, activeTabId: newActive);
    if (newActive == null) {
      _setPaneTreeQuiet(null);
      _ref.read(v3ActiveSessionTabProvider.notifier).state = null;
    } else if (newActive != tabId) {
      final fallbackTab =
          newTabs.firstWhere((t) => t.id == newActive);
      _setPaneTreeQuiet(fallbackTab.paneTree);
      _syncActiveSessionIndex(fallbackTab);
    }
    _persist();
  }

  /// Cancel a soft-close: clears `pendingClose` on the given tab so it
  /// reappears in the pill strip with all its sessions intact. Called
  /// when the user clicks Undo in the close snackbar.
  void cancelPendingClose(String tabId) {
    final idx = state.indexOf(tabId);
    if (idx < 0) return;
    if (!state.tabs[idx].pendingClose) return;
    final newTabs = List<WorkTab>.from(state.tabs);
    newTabs[idx] = newTabs[idx].copyWith(pendingClose: false);
    state = state.copyWith(tabs: newTabs);
    _persist();
  }

  /// Find which tab currently contains [sessionId], or null.
  WorkTab? tabContaining(String sessionId) {
    for (final t in state.tabs) {
      if (t.contains(sessionId)) return t;
    }
    return null;
  }

  /// Idempotent: if [sessionId] is not in any tab, create a new tab for it.
  /// If it is already in a tab, return that tab's id AND make that tab
  /// active so the V3 render dispatch swaps to the terminal area -
  /// without this, clicking a host card to reuse an existing connection
  /// silently leaves the user on whatever sidebar page they were on.
  ///
  /// When the existing tab is mid soft-close (`pendingClose: true`,
  /// e.g. the user closed it within the last 5 seconds and the Undo
  /// snackbar is still ticking), we ALSO un-mark it.  Without this,
  /// re-opening the same connection during the undo window would
  /// briefly show the tab and then have it killed when the timer
  /// finally fires - exactly the "I closed proxmox, then re-opened
  /// it, and it shut down by itself" bug.
  String onSessionCreated(String sessionId) {
    final existing = tabContaining(sessionId);
    if (existing != null) {
      if (existing.pendingClose) {
        cancelPendingClose(existing.id);
      }
      if (state.activeTabId != existing.id) {
        setActiveTab(existing.id);
      }
      return existing.id;
    }
    return createTab(sessionId);
  }

  /// Drop a list of stale session ids out of every tab. Tabs left empty are
  /// removed entirely. Used at startup to reconcile persisted layout against
  /// actually-running sessions.
  void purgeStaleSessions(Set<String> validSessionIds) {
    var changed = false;
    final newTabs = <WorkTab>[];
    for (final tab in state.tabs) {
      var tree = tab.paneTree;
      for (final sid in tab.sessionIds) {
        if (!validSessionIds.contains(sid)) {
          final pruned = removeSessionFromPanes(tree, sid);
          tree = pruned ?? tree;
          changed = true;
          if (pruned == null) break;
        }
      }
      // Skip empty tabs
      if (tab.sessionIds.every((s) => !validSessionIds.contains(s))) {
        changed = true;
        continue;
      }
      // The ones that stay share the room of the ones that went.
      newTabs.add(tab.copyWith(
          paneTree: identical(tree, tab.paneTree) ? tree : settledAfterRemoval(tab.paneTree, tree)));
    }
    if (!changed) return;

    String? activeId = state.activeTabId;
    if (activeId != null && !newTabs.any((t) => t.id == activeId)) {
      activeId = newTabs.isEmpty ? null : newTabs.first.id;
    }
    state = WorkTabsState(tabs: newTabs, activeTabId: activeId);
    final active = state.activeTab;
    _setPaneTreeQuiet(active?.paneTree);
    _persist();
  }
}

/// The tabs as the tab strip shows them, in its order: pinned tabs first,
/// then the others, each in the order it stands in; none that is being
/// closed (it waits out its moment to be taken back), and none with nothing
/// to show (every session of it ended or hidden). The keyboard's tab keys
/// go by this order, so the second tab is the second pill.
List<WorkTab> tabsInStripOrder(List<WorkTab> tabs, Map<String, SessionState> sessions) {
  bool shows(WorkTab t) {
    // (A tab is named by its terminals; SFTP's session is one of them.)
    final members = t.terminalSessionIds.isNotEmpty ? t.terminalSessionIds : t.sessionIds;
    return members.any((sid) {
      final s = sessions[sid];
      return s != null && !s.isHidden;
    });
  }

  return [
    for (final t in tabs)
      if (t.pinned && !t.pendingClose && shows(t)) t,
    for (final t in tabs)
      if (!t.pinned && !t.pendingClose && shows(t)) t,
  ];
}
