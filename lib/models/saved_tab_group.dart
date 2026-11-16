import 'package:flutter/widgets.dart' show Axis;
import 'package:uuid/uuid.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/work_tab.dart';
import 'package:zestssh/features/sftp/sftp_pane_paths.dart';

const _uuid = Uuid();

/// The row of `local_state` that holds a profile's saved tab groups.
const String kSavedTabGroupsKey = 'desktop_saved_tab_groups';

/// A snapshot of a single [WorkTab] where every session id in the pane tree
/// has been replaced with its underlying connection id, so the layout can be
/// re-launched after the app restarts (or on demand).
///
/// Captures everything needed to rebuild the tab *exactly* as the user left it:
///  • [customName] - user-given label
///  • [colorIndex] - per-tab color override (the colored chip / group color)
///  • [paneTreeOfConnIds] - full split layout, ratios, active-tab indices,
///    and per-leaf [PaneLeaf.type] (terminal / sftp), with connection ids
///    in place of session ids so a fresh session can be spawned per leaf.
class TabSnapshot {
  /// Optional user-given tab name (mirrors [WorkTab.customName]).
  final String? customName;

  /// Optional per-tab color override (mirrors [WorkTab.colorIndex]).
  /// Index into [AppColors.connectionLabelColors]. When null, the launcher
  /// lets the tab inherit its color from the first session's connection.
  final int? colorIndex;

  /// Pane tree whose [PaneLeaf.sessionIds] are *connection ids*, not session
  /// ids. Reuses [PaneNode]/[PaneLeaf]/[PaneSplit] verbatim - the strings
  /// inside the leaves are reinterpreted as connection ids by the launcher.
  final PaneNode paneTreeOfConnIds;

  /// Where each SFTP pane pair was browsing, keyed by the leaf id in
  /// [paneTreeOfConnIds] (remember-last-folder spec, section 1 "pane
  /// state"). Device-local: it rides in the snapshot on this device and is
  /// never part of the sync blob.
  final Map<String, SftpPanePaths> panePaths;

  const TabSnapshot({
    this.customName,
    this.colorIndex,
    required this.paneTreeOfConnIds,
    this.panePaths = const {},
  });

  Map<String, dynamic> toJson() => {
        if (customName != null) 'customName': customName,
        if (colorIndex != null) 'colorIndex': colorIndex,
        'paneTree': paneTreeOfConnIds.toJson(),
        if (panePaths.isNotEmpty)
          'panePaths': {
            for (final e in panePaths.entries) e.key: e.value.toJson(),
          },
      };

  static TabSnapshot? fromJson(Map<String, dynamic> json) {
    final tree = PaneNode.fromJson(json['paneTree'] as Map<String, dynamic>?);
    if (tree == null) return null;
    final paths = <String, SftpPanePaths>{};
    final rawPaths = json['panePaths'];
    if (rawPaths is Map) {
      for (final e in rawPaths.entries) {
        final p = SftpPanePaths.fromJson(e.value);
        if (p != null) paths['${e.key}'] = p;
      }
    }
    return TabSnapshot(
      customName: json['customName'] as String?,
      colorIndex: (json['colorIndex'] as num?)?.toInt(),
      paneTreeOfConnIds: tree,
      panePaths: paths,
    );
  }
}

/// [tabs] without the hosts [connIds] (the Telnet hosts of the last run that
/// the person would not reopen): each leaves the panes it is a tab of, a pane
/// left with none leaves its tab, the split it was in becoming its other
/// side, and a tab left with no pane is not among them. [activeTabIndex]
/// follows its tab, and is null when that tab is gone.
({List<TabSnapshot> tabs, int? activeTabIndex}) tabsWithoutHosts(
  List<TabSnapshot> tabs,
  Set<String> connIds, {
  int? activeTabIndex,
}) {
  if (connIds.isEmpty) return (tabs: tabs, activeTabIndex: activeTabIndex);
  final kept = <TabSnapshot>[];
  int? active;
  for (var i = 0; i < tabs.length; i++) {
    final tab = tabs[i];
    final tree = _paneTreeWithoutHosts(tab.paneTreeOfConnIds, connIds);
    if (tree == null) continue;
    if (i == activeTabIndex) active = kept.length;
    kept.add(identical(tree, tab.paneTreeOfConnIds)
        ? tab
        : TabSnapshot(
            customName: tab.customName,
            colorIndex: tab.colorIndex,
            paneTreeOfConnIds: tree,
            panePaths: tab.panePaths,
          ));
  }
  return (tabs: kept, activeTabIndex: active);
}

PaneNode? _paneTreeWithoutHosts(PaneNode node, Set<String> connIds) {
  if (node is PaneLeaf) {
    final keep = [
      for (final id in node.sessionIds)
        if (!connIds.contains(id)) id,
    ];
    if (keep.length == node.sessionIds.length) return node;
    if (keep.isEmpty) return null;
    final shown = node.sessionIds[node.activeIndex.clamp(0, node.sessionIds.length - 1)];
    final at = keep.indexOf(shown);
    return PaneLeaf(id: node.id, sessionIds: keep, activeIndex: at < 0 ? 0 : at, type: node.type);
  }
  final split = node as PaneSplit;
  final first = _paneTreeWithoutHosts(split.first, connIds);
  final second = _paneTreeWithoutHosts(split.second, connIds);
  if (first == null) return second;
  if (second == null) return first;
  if (identical(first, split.first) && identical(second, split.second)) return split;
  return split.copyWith(first: first, second: second);
}

/// A user-saved snapshot of one or more work tabs (a "group" / "workspace").
///
/// Distinct from the legacy window-positional [Workspace] model - this one
/// captures the tab-group layout from the v1.5 desktop shell.
class SavedTabGroup {
  final String id;
  final String name;
  final List<TabSnapshot> tabs;
  final DateTime createdAt;
  final DateTime? lastUsedAt;

  /// Last-known display label for every referenced connection id, captured at
  /// save / replace time. A workspace only stores *references* to hosts (never
  /// their credentials), so when a referenced host is later deleted this map is
  /// the only way to still NAME the unresolved slot: both in the member-chip
  /// list and in the "couldn't launch these" report. Missing entries fall back
  /// to the raw id. Optional + additive so older persisted blobs load untouched.
  final Map<String, String> hostNames;

  SavedTabGroup({
    String? id,
    required this.name,
    required this.tabs,
    DateTime? createdAt,
    this.lastUsedAt,
    this.hostNames = const {},
  })  : id = id ?? _uuid.v4(),
        createdAt = createdAt ?? DateTime.now();

  SavedTabGroup copyWith({
    String? name,
    List<TabSnapshot>? tabs,
    DateTime? lastUsedAt,
    Map<String, String>? hostNames,
  }) =>
      SavedTabGroup(
        id: id,
        name: name ?? this.name,
        tabs: tabs ?? this.tabs,
        createdAt: createdAt,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
        hostNames: hostNames ?? this.hostNames,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'tabs': tabs.map((t) => t.toJson()).toList(),
        'createdAt': createdAt.toIso8601String(),
        if (lastUsedAt != null) 'lastUsedAt': lastUsedAt!.toIso8601String(),
        if (hostNames.isNotEmpty) 'hostNames': hostNames,
      };

  static SavedTabGroup? fromJson(Map<String, dynamic> json) {
    final list = (json['tabs'] as List?) ?? const [];
    final tabs = <TabSnapshot>[];
    for (final raw in list) {
      final snap = TabSnapshot.fromJson(raw as Map<String, dynamic>);
      if (snap != null) tabs.add(snap);
    }
    if (tabs.isEmpty) return null;
    final rawNames = json['hostNames'];
    final hostNames = <String, String>{};
    if (rawNames is Map) {
      rawNames.forEach((k, v) {
        if (k is String && v is String) hostNames[k] = v;
      });
    }
    return SavedTabGroup(
      id: json['id'] as String?,
      name: (json['name'] as String?) ?? 'Untitled',
      tabs: tabs,
      createdAt: DateTime.tryParse((json['createdAt'] as String?) ?? '') ??
          DateTime.now(),
      lastUsedAt: json['lastUsedAt'] != null
          ? DateTime.tryParse(json['lastUsedAt'] as String)
          : null,
      hostNames: hostNames,
    );
  }
}

/// A soft-deleted workspace held for the undo window, remembering the list
/// position so a restore lands it back where it was (keeping its Ctrl+1..9
/// launch shortcut).
class DeletedWorkspaceRecord {
  const DeletedWorkspaceRecord({required this.group, required this.index});
  final SavedTabGroup group;
  final int index;
}

/// Snapshot the given live work [tabs] into a list of [TabSnapshot]s, mapping
/// each pane's live session ids to their underlying connection ids via
/// [sessionToConn].
///
/// Tabs mid soft-close are skipped, as are tabs containing a pane whose session
/// cannot be mapped to a saved connection (e.g. an ad-hoc / local-shell
/// session) since those cannot be referenced by a workspace. Returns null when
/// nothing capturable remains.
List<TabSnapshot>? captureTabsAsSnapshots(
  List<WorkTab> tabs,
  String? Function(String sessionId) sessionToConn, {
  SftpPanePaths? Function(String sessionId)? panePathsFor,
}) {
  final out = <TabSnapshot>[];
  for (final tab in tabs) {
    if (tab.pendingClose) continue;
    final tree = mapPaneTreeIds(tab.paneTree, sessionToConn, keepIds: true);
    // A tab of empty places alone has no host to open again.
    if (tree == null || tree.allLeaves.every((l) => l.isPlaceholder)) continue;
    out.add(TabSnapshot(
      customName: tab.customName,
      colorIndex: tab.colorIndex,
      paneTreeOfConnIds: tree,
      panePaths: panePathsFor == null
          ? const {}
          : collectPanePaths(tab.paneTree, panePathsFor),
    ));
  }
  return out.isEmpty ? null : out;
}

/// Snapshot the given live work [tabs] pane by pane, for the save dialog's
/// choice of what to save (before, it always
/// took every tab and pane). A pane is kept when [keep] names its leaf (null:
/// every pane) and [sessionToConn] maps a session of it to a saved host: one
/// that has none (a local shell made for the moment) leaves the tab's other
/// panes as they are, its room going to the side it split with. Of a pane
/// holding both (stacked in one place), the sessions of saved hosts stay. A tab
/// left with no pane is skipped; an empty place stays only in a tab saved
/// whole. Null when nothing is left.
List<TabSnapshot>? capturePanesAsSnapshots(
  List<WorkTab> tabs,
  String? Function(String sessionId) sessionToConn, {
  Set<String>? keep,
  SftpPanePaths? Function(String sessionId)? panePathsFor,
}) {
  final out = <TabSnapshot>[];
  for (final tab in tabs) {
    if (tab.pendingClose) continue;
    final kept = <String>{
      for (final leaf in tab.paneTree.allLeaves)
        if (leaf.isPlaceholder
            ? keep == null
            : (keep == null || keep.contains(leaf.id)) && leaf.sessionIds.any((s) => sessionToConn(s) != null))
          leaf.id,
    };
    final pruned = _withoutLeavesOutside(tab.paneTree, kept);
    if (pruned == null || pruned.allLeaves.every((l) => l.isPlaceholder)) continue;
    final tree = mapPaneTreeIds(_withSessionsThatMap(pruned, sessionToConn), sessionToConn, keepIds: true);
    if (tree == null) continue;
    out.add(TabSnapshot(
      customName: tab.customName,
      colorIndex: tab.colorIndex,
      paneTreeOfConnIds: tree,
      panePaths: panePathsFor == null ? const {} : collectPanePaths(pruned, panePathsFor),
    ));
  }
  return out.isEmpty ? null : out;
}

/// [tree] with each pane holding only the sessions [sessionToConn] maps, the
/// one in front still in front where it is one of them.
PaneNode _withSessionsThatMap(PaneNode tree, String? Function(String sessionId) sessionToConn) {
  if (tree is PaneLeaf) {
    if (tree.isPlaceholder) return tree;
    final mapped = tree.sessionIds.where((s) => sessionToConn(s) != null).toList();
    if (mapped.length == tree.sessionIds.length) return tree;
    return PaneLeaf(
      id: tree.id,
      sessionIds: mapped,
      activeIndex: mapped.indexOf(tree.sessionId).clamp(0, mapped.length - 1),
      type: tree.type,
    );
  }
  if (tree is PaneSplit) {
    return tree.copyWith(
      first: _withSessionsThatMap(tree.first, sessionToConn),
      second: _withSessionsThatMap(tree.second, sessionToConn),
    );
  }
  return tree;
}

/// [tab] with new ids on the leaves [renew] names, their remembered folders
/// following them.
TabSnapshot _withNewLeafIds(TabSnapshot tab, bool Function(String leafId) renew) {
  final paths = <String, SftpPanePaths>{...tab.panePaths};
  PaneNode walk(PaneNode node) {
    if (node is PaneLeaf) {
      if (!renew(node.id)) return node;
      final fresh = node.isPlaceholder
          ? PaneLeaf.placeholder(type: node.type)
          : PaneLeaf(sessionIds: node.sessionIds, activeIndex: node.activeIndex, type: node.type);
      final remembered = paths.remove(node.id);
      if (remembered != null) paths[fresh.id] = remembered;
      return fresh;
    }
    if (node is PaneSplit) return node.copyWith(first: walk(node.first), second: walk(node.second));
    return node;
  }

  final tree = walk(tab.paneTreeOfConnIds);
  return TabSnapshot(
    customName: tab.customName,
    colorIndex: tab.colorIndex,
    paneTreeOfConnIds: tree,
    panePaths: paths,
  );
}

/// [tabs] with no empty place: "Remove them" of Update's question, where a pane
/// a plan's limit left out stands as an empty place while it is open.
List<TabSnapshot> withoutEmptyPlaces(List<TabSnapshot> tabs) => [
      for (final tab in tabs)
        TabSnapshot(
          customName: tab.customName,
          colorIndex: tab.colorIndex,
          paneTreeOfConnIds: _withoutLeavesOutside(
                tab.paneTreeOfConnIds,
                {
                  for (final leaf in tab.paneTreeOfConnIds.allLeaves)
                    if (!leaf.isPlaceholder) leaf.id,
                },
              ) ??
              tab.paneTreeOfConnIds,
          panePaths: tab.panePaths,
        ),
    ];

/// [tab] as a tab of its own, with leaf ids no other tab has, for adding to a
/// workspace that may hold it already: the workspace's editor tells its panes
/// apart by their ids.
TabSnapshot withFreshLeafIds(TabSnapshot tab) => _withNewLeafIds(tab, (_) => true);

/// What became of each saved tab's panes in [open], walked in order. A host
/// counts as open as many times as [open] holds it.
List<({TabSnapshot tab, Set<String> open, List<PaneLeaf> notOpen})> _savedTabsNow(
  List<TabSnapshot> saved,
  List<TabSnapshot> open,
) {
  final spare = <String, int>{};
  for (final tab in open) {
    for (final leaf in tab.paneTreeOfConnIds.allLeaves) {
      if (leaf.isPlaceholder) continue;
      for (final id in leaf.sessionIds) {
        spare[id] = (spare[id] ?? 0) + 1;
      }
    }
  }
  final out = <({TabSnapshot tab, Set<String> open, List<PaneLeaf> notOpen})>[];
  for (final tab in saved) {
    final held = <String>{};
    final notOpen = <PaneLeaf>[];
    for (final leaf in tab.paneTreeOfConnIds.allLeaves) {
      if (leaf.isPlaceholder) continue;
      final gone = <String>[];
      for (final id in leaf.sessionIds) {
        final left = spare[id] ?? 0;
        if (left > 0) {
          spare[id] = left - 1;
          held.add(id);
        } else {
          gone.add(id);
        }
      }
      if (gone.isEmpty) continue;
      // All of it: the pane itself, with its id and remembered folders.
      notOpen.add(gone.length == leaf.sessionIds.length ? leaf : PaneLeaf(sessionIds: gone, type: leaf.type));
    }
    out.add((tab: tab, open: held, notOpen: notOpen));
  }
  return out;
}

/// The panes of a workspace's [saved] tabs that [open] (what Update would put
/// in their place) does not hold, in the workspace's order.
List<PaneLeaf> panesNotOpen(List<TabSnapshot> saved, List<TabSnapshot> open) => [
      for (final tab in _savedTabsNow(saved, open)) ...tab.notOpen,
    ];

/// [open] with the panes of [saved] it does not hold put back ("Keep them" of
/// Update's question): a saved tab with nothing open stands as it was saved, in
/// its place; panes of a tab that is open go into its empty places, which is
/// where a plan's limit left them, else beside what it holds. Open tabs that
/// are no saved tab's come after. Every leaf keeps an id of its own.
List<TabSnapshot> withPanesNotOpen(List<TabSnapshot> saved, List<TabSnapshot> open) {
  final out = <TabSnapshot>[];
  final placed = <int, int>{}; // an open tab's index, to its place in [out]
  for (final was in _savedTabsNow(saved, open)) {
    bool holdsIt(TabSnapshot t) => t.paneTreeOfConnIds.allLeaves.any((l) => l.sessionIds.any(was.open.contains));
    // The tab it became: one not taken yet where two hold the same host.
    var at = -1;
    for (var i = 0; i < open.length && at < 0; i++) {
      if (!placed.containsKey(i) && holdsIt(open[i])) at = i;
    }
    if (at < 0) at = open.indexWhere(holdsIt);
    if (at < 0) {
      if (was.notOpen.isNotEmpty) out.add(was.tab);
      continue;
    }
    final place = placed.putIfAbsent(at, () {
      out.add(open[at]);
      return out.length - 1;
    });
    if (was.notOpen.isNotEmpty) out[place] = _withPanesAdded(out[place], was.notOpen, was.tab.panePaths);
  }
  for (var i = 0; i < open.length; i++) {
    if (!placed.containsKey(i)) out.add(open[i]);
  }
  // A leaf that came back beside one with its id (a tab saved, then added
  // again) would be drawn once.
  final seen = <String>{};
  return [
    for (final tab in out) _withNewLeafIds(tab, (id) => !seen.add(id)),
  ];
}

/// [tab] with [panes] in its empty places, and what is left of them beside
/// what it holds, keeping each one's remembered folders from [paths].
TabSnapshot _withPanesAdded(TabSnapshot tab, List<PaneLeaf> panes, Map<String, SftpPanePaths> paths) {
  final rest = [...panes];
  PaneNode fill(PaneNode node) {
    if (node is PaneLeaf) return node.isPlaceholder && rest.isNotEmpty ? rest.removeAt(0) : node;
    if (node is PaneSplit) {
      final first = fill(node.first);
      return node.copyWith(first: first, second: fill(node.second));
    }
    return node;
  }

  var tree = fill(tab.paneTreeOfConnIds);
  if (rest.isNotEmpty) {
    final before = tree.allLeaves.length;
    tree = PaneSplit(
      first: tree,
      second: linearSplitOf(rest),
      axis: Axis.horizontal,
      ratio: before / (before + rest.length),
    );
  }
  return TabSnapshot(
    customName: tab.customName,
    colorIndex: tab.colorIndex,
    paneTreeOfConnIds: tree,
    panePaths: {
      ...tab.panePaths,
      for (final pane in panes)
        if (paths[pane.id] != null) pane.id: paths[pane.id]!,
    },
  );
}

/// The pane state of every SFTP leaf in a LIVE tree, keyed by leaf id, for a
/// snapshot built with `keepIds: true` (so the keys still match after the
/// session ids are swapped for connection ids).
Map<String, SftpPanePaths> collectPanePaths(
  PaneNode liveTree,
  SftpPanePaths? Function(String sessionId) panePathsFor,
) {
  final out = <String, SftpPanePaths>{};
  for (final leaf in liveTree.allLeaves) {
    if (leaf.type != 'sftp' || leaf.isPlaceholder) continue;
    final paths = panePathsFor(leaf.sessionId);
    if (paths != null && !paths.isEmpty) out[leaf.id] = paths;
  }
  return out;
}

/// Every pane (leaf) of a workspace, flattened in tab-then-pane order. Each
/// leaf's `sessionIds` hold *connection ids*. Matches the order of
/// `WorkspaceView.memberHosts` 1:1.
List<PaneLeaf> flattenWorkspaceLeaves(SavedTabGroup group) {
  final out = <PaneLeaf>[];
  for (final tab in group.tabs) {
    out.addAll(tab.paneTreeOfConnIds.allLeaves);
  }
  return out;
}

/// Rebuild a workspace's tabs from a (possibly reordered / trimmed / extended)
/// flat pane list: the edit dialog's model for "reorder panes by drag",
/// "remove a pane" and "add a host".
///
/// Each tab keeps its layout (3.0 docs check, 22 October 2026: Save turned
/// every tab into one row of even columns, a grid included, even when only
/// the name was changed). A tab keeps as many panes as it had, less those
/// removed from it; its panes are dealt out in the new order, each into the
/// place of one of the tab's own in its tree, so the splits, their
/// directions and their shares stay. A removed pane's place goes, and the
/// split it stood in gives its room to the other side. A tab left with no
/// pane disappears. Panes added (or more than the tabs hold) join the last
/// tab, side by side with what it had. Each tab's name and colour stay, and
/// every pane keeps its remembered SFTP folders, which follow it by its id.
List<TabSnapshot> rebuildWorkspaceTabs({
  required SavedTabGroup original,
  required List<PaneLeaf> orderedLeaves,
}) {
  final keptIds = {for (final l in orderedLeaves) l.id};
  final allPaths = <String, SftpPanePaths>{
    for (final tab in original.tabs) ...tab.panePaths,
  };

  // Each tab's tree with its removed panes taken out, in the tabs' order.
  final pruned = <(TabSnapshot, PaneNode)>[];
  for (final tab in original.tabs) {
    final tree = _withoutLeavesOutside(tab.paneTreeOfConnIds, keptIds);
    if (tree != null) pruned.add((tab, tree));
  }

  final out = <TabSnapshot>[];
  var cursor = 0;
  for (var i = 0; i < pruned.length; i++) {
    final (tab, tree) = pruned[i];
    final places = tree.allLeaves.length;
    final take = (orderedLeaves.length - cursor).clamp(0, places);
    if (take <= 0) break;
    final slice = orderedLeaves.sublist(cursor, cursor + take);
    cursor += take;
    // Fewer panes left than places (they moved to an earlier tab): the
    // places past them go, as a removed pane's do.
    var rebuilt = take < places
        ? _withoutLeavesOutside(tree, {for (final l in tree.allLeaves.take(take)) l.id})!
        : tree;
    rebuilt = _dealLeaves(rebuilt, slice.iterator);
    // The last tab takes what is left: panes added, or more than the tabs hold.
    if (i == pruned.length - 1 && cursor < orderedLeaves.length) {
      final extra = orderedLeaves.sublist(cursor);
      cursor = orderedLeaves.length;
      final before = rebuilt.allLeaves.length;
      rebuilt = PaneSplit(
        first: rebuilt,
        second: linearSplitOf(extra),
        axis: Axis.horizontal,
        ratio: before / (before + extra.length),
      );
    }
    out.add(_snapshotOf(rebuilt, tab.customName, tab.colorIndex, allPaths));
  }
  if (cursor < orderedLeaves.length) {
    out.add(_snapshotOf(linearSplitOf(orderedLeaves.sublist(cursor)), null, null, allPaths));
  }
  return out;
}

TabSnapshot _snapshotOf(PaneNode tree, String? name, int? color, Map<String, SftpPanePaths> paths) => TabSnapshot(
      customName: name,
      colorIndex: color,
      paneTreeOfConnIds: tree,
      panePaths: {
        for (final leaf in tree.allLeaves)
          if (paths[leaf.id] != null) leaf.id: paths[leaf.id]!,
      },
    );

/// [tree] with only the leaves whose ids are in [keep]: a split one side of
/// which is gone is its other side. Null when no leaf is left.
PaneNode? _withoutLeavesOutside(PaneNode tree, Set<String> keep) {
  if (tree is PaneLeaf) return keep.contains(tree.id) ? tree : null;
  if (tree is PaneSplit) {
    final first = _withoutLeavesOutside(tree.first, keep);
    final second = _withoutLeavesOutside(tree.second, keep);
    if (first == null) return second;
    if (second == null) return first;
    return tree.copyWith(first: first, second: second);
  }
  return null;
}

/// [tree] with each of its leaves, in order, replaced by the next of [next]
/// (as many as it has leaves): the same splits around other panes.
PaneNode _dealLeaves(PaneNode tree, Iterator<PaneLeaf> next) {
  if (tree is PaneLeaf) return next.moveNext() ? next.current : tree;
  if (tree is PaneSplit) {
    final first = _dealLeaves(tree.first, next);
    final second = _dealLeaves(tree.second, next);
    return tree.copyWith(first: first, second: second);
  }
  return tree;
}

/// Build a right-leaning chain of horizontal splits over [leaves] with roughly
/// even ratios. A single leaf is returned as-is.
PaneNode linearSplitOf(List<PaneLeaf> leaves) {
  if (leaves.isEmpty) {
    return PaneLeaf.placeholder();
  }
  if (leaves.length == 1) return leaves.first;
  PaneNode node = leaves.last;
  for (var i = leaves.length - 2; i >= 0; i--) {
    final remaining = leaves.length - i; // leaves from i..end inclusive
    node = PaneSplit(
      first: leaves[i],
      second: node,
      axis: Axis.horizontal,
      ratio: 1 / remaining,
    );
  }
  return node;
}

/// Walk [tree] and return a copy where every session id in every leaf is
/// replaced via [mapSessionId]. Returns null if any session cannot be mapped
/// (e.g. session has no associated connection record).
PaneNode? mapPaneTreeIds(
  PaneNode tree,
  String? Function(String sessionOrConnId) mapId, {
  bool keepIds = false,
}) {
  if (tree is PaneLeaf) {
    // An empty place ("Connect…", a layout's pane nobody filled) stays an
    // empty place: it holds no session to map, and keeps the layout (it
    // threw: an active index clamped between 0 and -1).
    if (tree.isPlaceholder) {
      return PaneLeaf.placeholder(id: keepIds ? tree.id : null, type: tree.type);
    }
    final mapped = <String>[];
    for (final s in tree.sessionIds) {
      final m = mapId(s);
      if (m == null) return null;
      mapped.add(m);
    }
    return PaneLeaf(
      // A snapshot keeps its leaf ids so per-leaf pane state can be keyed by
      // them (remember-last-folder); a fresh launch regenerates them.
      id: keepIds ? tree.id : null,
      sessionIds: mapped,
      activeIndex: tree.activeIndex.clamp(0, mapped.length - 1),
      type: tree.type,
    );
  }
  if (tree is PaneSplit) {
    final left = mapPaneTreeIds(tree.first, mapId, keepIds: keepIds);
    final right = mapPaneTreeIds(tree.second, mapId, keepIds: keepIds);
    if (left == null || right == null) return null;
    return PaneSplit(
      first: left,
      second: right,
      axis: tree.axis,
      ratio: tree.ratio,
    );
  }
  return null;
}
