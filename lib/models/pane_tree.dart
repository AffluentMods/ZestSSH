import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

sealed class PaneNode {
  PaneLeaf? findLeaf(String leafId);
  List<PaneLeaf> get allLeaves;
  Map<String, dynamic> toJson();

  static PaneNode? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    switch (json['type']) {
      case 'leaf':
        final List<String> sessionIds;
        final int activeIndex;
        if (json.containsKey('sessionIds')) {
          sessionIds = (json['sessionIds'] as List).cast<String>();
          activeIndex = (json['activeIndex'] as num?)?.toInt() ?? 0;
        } else {
          sessionIds = [json['sessionId'] as String];
          activeIndex = 0;
        }
        return PaneLeaf(
          id: json['id'] as String?,
          sessionIds: sessionIds,
          activeIndex: activeIndex,
          type: json['paneType'] as String?,
        );
      case 'split':
        return PaneSplit(
          id: json['id'] as String?,
          axis: json['axis'] == 'horizontal' ? Axis.horizontal : Axis.vertical,
          ratio: (json['ratio'] as num?)?.toDouble() ?? 0.5,
          first: fromJson(json['first'] as Map<String, dynamic>)!,
          second: fromJson(json['second'] as Map<String, dynamic>)!,
        );
      default:
        return null;
    }
  }
}

class PaneLeaf extends PaneNode {
  final String id;
  final List<String> sessionIds;
  final int activeIndex;
  final String type;

  /// True when this leaf has no real sessions - rendered as a "Connect…"
  /// placeholder. Created by the layout sorter when the user picks a preset
  /// that needs more panes than there are alive terminals (e.g. four-grid
  /// with only three sessions). Click/drag on the placeholder fills it.
  bool get isPlaceholder =>
      sessionIds.isEmpty || sessionIds.every((s) => s.isEmpty);

  /// The currently active session in this pane's tab list.
  ///
  /// Throws if called on a placeholder leaf - callers should guard with
  /// [isPlaceholder] first. Use [sessionIdOrNull] for a safe lookup.
  String get sessionId =>
      sessionIds[activeIndex.clamp(0, sessionIds.length - 1)];

  /// Safe variant of [sessionId] - returns null for placeholder leaves
  /// instead of throwing.
  String? get sessionIdOrNull =>
      isPlaceholder ? null : sessionId;

  PaneLeaf({
    List<String>? sessionIds,
    String? sessionId,
    this.activeIndex = 0,
    String? id,
    String? type,
  })  : assert(
          sessionIds != null || sessionId != null,
          'Either sessionIds or sessionId must be provided',
        ),
        id = id ?? _uuid.v4(),
        sessionIds = sessionIds ?? [sessionId!],
        type = type ?? 'terminal';

  /// Convenience factory for creating a leaf with a single session.
  factory PaneLeaf.single({required String sessionId, String? id, String? type}) {
    return PaneLeaf(sessionIds: [sessionId], id: id, type: type);
  }

  /// Empty placeholder leaf - rendered as a "Connect…" card. Used by the
  /// layout sorter when a preset needs more panes than there are sessions,
  /// so the user can fill the slot by clicking or dragging.
  factory PaneLeaf.placeholder({String? id, String type = 'terminal'}) {
    return PaneLeaf(sessionIds: const [], id: id, type: type);
  }

  /// Returns a copy with a different active tab index.
  PaneLeaf withActiveIndex(int index) => PaneLeaf(
        sessionIds: sessionIds,
        activeIndex: index.clamp(0, sessionIds.length - 1),
        id: id,
        type: type,
      );

  /// Returns a copy with an additional session appended to the tab list.
  PaneLeaf withAddedSession(String sessionId) => PaneLeaf(
        sessionIds: [...sessionIds, sessionId],
        activeIndex: sessionIds.length, // focus the new tab
        id: id,
        type: type,
      );

  /// Returns a copy with the given session removed from the tab list.
  /// Adjusts [activeIndex] to stay in bounds.
  PaneLeaf withRemovedSession(String sessionId) {
    final newIds = sessionIds.where((s) => s != sessionId).toList();
    if (newIds.isEmpty) {
      // Caller should handle empty leaves (remove the pane entirely).
      return PaneLeaf(sessionIds: const [''], activeIndex: 0, id: id, type: type);
    }
    final removedIndex = sessionIds.indexOf(sessionId);
    int newActive = activeIndex;
    if (removedIndex <= activeIndex && activeIndex > 0) {
      newActive = activeIndex - 1;
    }
    return PaneLeaf(
      sessionIds: newIds,
      activeIndex: newActive.clamp(0, newIds.length - 1),
      id: id,
      type: type,
    );
  }

  @override
  PaneLeaf? findLeaf(String leafId) => id == leafId ? this : null;

  @override
  List<PaneLeaf> get allLeaves => [this];

  @override
  Map<String, dynamic> toJson() => {
        'type': 'leaf',
        'id': id,
        'sessionIds': sessionIds,
        'activeIndex': activeIndex,
        'paneType': type,
      };
}

/// The smallest and the largest share one side of a split takes. Eight
/// panes side by side are an eighth each, so the floor is under that; a
/// divider that is dragged stops before it (see PaneTreeView).
const double kMinPaneShare = 0.1;
const double kMaxPaneShare = 0.9;

class PaneSplit extends PaneNode {
  /// Who this split is, for as long as it stands between the same two
  /// sides: what changes inside either side, or how the two share their
  /// room, makes it no other split. The divider on screen goes by it, so a
  /// divider someone dragged keeps its place while panes come and go
  /// elsewhere, and is not taken for the divider of another tab.
  final String id;
  final PaneNode first;
  final PaneNode second;
  final Axis axis;
  final double ratio;

  PaneSplit({
    required this.first,
    required this.second,
    required this.axis,
    double ratio = 0.5,
    String? id,
  })  : ratio = ratio.clamp(kMinPaneShare, kMaxPaneShare),
        id = id ?? _uuid.v4();

  /// A split whose two sides share the room evenly ([evenPaneShare]).
  factory PaneSplit.even({
    required PaneNode first,
    required PaneNode second,
    required Axis axis,
    String? id,
  }) =>
      PaneSplit(
        first: first,
        second: second,
        axis: axis,
        id: id,
        ratio: evenPaneShare(first, second, axis) ?? 0.5,
      );

  /// The same split with other sides, or sharing its room another way.
  PaneSplit copyWith({PaneNode? first, PaneNode? second, double? ratio}) => PaneSplit(
        id: id,
        first: first ?? this.first,
        second: second ?? this.second,
        axis: axis,
        ratio: ratio ?? this.ratio,
      );

  @override
  PaneLeaf? findLeaf(String leafId) {
    return first.findLeaf(leafId) ?? second.findLeaf(leafId);
  }

  @override
  List<PaneLeaf> get allLeaves => [...first.allLeaves, ...second.allLeaves];

  @override
  Map<String, dynamic> toJson() => {
        'type': 'split',
        'id': id,
        'axis': axis == Axis.horizontal ? 'horizontal' : 'vertical',
        'ratio': ratio,
        'first': first.toJson(),
        'second': second.toJson(),
      };
}

/// How many panes stand side by side in [node] (for [Axis.horizontal]) or
/// one above the other (for [Axis.vertical]), where it is at its fullest. An
/// SFTP leaf is no pane: it shows in its dock, and takes no room among the
/// terminals.
int paneTracks(PaneNode node, Axis axis) {
  if (node is PaneLeaf) return node.type == 'sftp' ? 0 : 1;
  final split = node as PaneSplit;
  final first = paneTracks(split.first, axis);
  final second = paneTracks(split.second, axis);
  return split.axis == axis ? first + second : math.max(first, second);
}

/// How far from its even share a split may stand and still count as sharing
/// evenly: a few pixels of a wide window, less than anyone drags a divider
/// on purpose.
const double kEvenShareSlack = 0.002;

/// The share of the first side at which [first] and [second], split along
/// [axis], share the room evenly: by how many panes each holds along the
/// split (its columns for a split left and right, its rows for one above
/// and below). Three panes side by side are a third each; a pane beside two
/// stacked ones is half, the two a quarter each. Null when one side has no
/// pane along it (nothing but SFTP, which shows in its dock).
double? evenPaneShare(PaneNode first, PaneNode second, Axis axis) {
  final a = paneTracks(first, axis);
  final b = paneTracks(second, axis);
  if (a == 0 || b == 0) return null;
  return (a / (a + b)).clamp(kMinPaneShare, kMaxPaneShare);
}

/// Whether the two sides of [split] share its room evenly: nobody moved
/// its divider, and nobody chose an arrangement that shares it otherwise.
bool sharesEvenly(PaneSplit split) {
  final even = evenPaneShare(split.first, split.second, split.axis);
  return even == null || (split.ratio - even).abs() < kEvenShareSlack;
}

/// Whether every split of [node] shares its room evenly.
bool sharedEvenly(PaneNode node) =>
    node is! PaneSplit || (sharesEvenly(node) && sharedEvenly(node.first) && sharedEvenly(node.second));

/// [node] with its room shared again after panes came or went.
///
/// A split shares evenly: the two sides take room by how many panes each
/// holds along it ([evenPaneShare]). A binary tree left alone compounds its
/// halves (a half, a quarter, an eighth...), and counting panes without
/// looking at which way they stand gives a pane beside a stack a third of
/// the width.
///
/// [since] is the tree as it stood before the change. A split that was in
/// it and did not share evenly keeps its share: a divider someone moved
/// stays where it was put, and so do the shares of an arrangement that is
/// not even by design, while panes come and go elsewhere. Without [since]
/// every split shares evenly.
///
/// A split with nothing but SFTP on one side keeps its share: that side is
/// not shown among the panes. Pure: returns a new tree, each split still
/// the split it was. Shared by the pane-tree provider and the WorkTabs
/// group edits.
PaneNode rebalancePaneTree(PaneNode node, {PaneNode? since}) {
  final kept = <String>{};
  void look(PaneNode? at) {
    if (at is! PaneSplit) return;
    if (!sharesEvenly(at)) kept.add(at.id);
    look(at.first);
    look(at.second);
  }

  look(since);

  PaneNode share(PaneNode at) {
    if (at is! PaneSplit) return at;
    final first = share(at.first);
    final second = share(at.second);
    final even = kept.contains(at.id) ? null : evenPaneShare(first, second, at.axis);
    return at.copyWith(first: first, second: second, ratio: even ?? at.ratio);
  }

  return share(node);
}

/// The SFTP leaves of [tree], in its order.
List<PaneLeaf> sftpLeavesOf(PaneNode? tree) => [
      for (final leaf in tree?.allLeaves ?? const <PaneLeaf>[])
        if (leaf.type == 'sftp') leaf,
    ];

/// [tree] without its SFTP leaves, for laying out the terminals: SFTP shows
/// in the dock, never as a pane. A split left with one side becomes that
/// side. Null when nothing but SFTP was there.
PaneNode? withoutSftp(PaneNode? tree) {
  if (tree == null) return null;
  if (tree is PaneLeaf) return tree.type == 'sftp' ? null : tree;
  final split = tree as PaneSplit;
  final first = withoutSftp(split.first);
  final second = withoutSftp(split.second);
  if (first == null) return second;
  if (second == null) return first;
  if (identical(first, split.first) && identical(second, split.second)) {
    return split;
  }
  return split.copyWith(first: first, second: second);
}

/// [node] with the leaf [leafId] replaced by [replacement]; every split is
/// still the split it was.
PaneNode replacePaneLeaf(PaneNode node, String leafId, PaneNode replacement) {
  if (node is PaneLeaf) return node.id == leafId ? replacement : node;
  final split = node as PaneSplit;
  return split.copyWith(
    first: replacePaneLeaf(split.first, leafId, replacement),
    second: replacePaneLeaf(split.second, leafId, replacement),
  );
}

/// [node] without the leaf [leafId]: a split left with one side becomes
/// that side. Null when nothing is left.
PaneNode? removePaneLeaf(PaneNode node, String leafId) {
  if (node is PaneLeaf) return node.id == leafId ? null : node;
  final split = node as PaneSplit;
  final first = removePaneLeaf(split.first, leafId);
  final second = removePaneLeaf(split.second, leafId);
  if (first == null) return second;
  if (second == null) return first;
  return split.copyWith(first: first, second: second);
}

/// [node] without the session [sessionId]: it leaves the pane it is a tab
/// of, and a pane left with no session leaves the tree, its split becoming
/// the other side. Null when nothing is left.
PaneNode? removeSessionFromPanes(PaneNode node, String sessionId) {
  if (node is PaneLeaf) {
    if (!node.sessionIds.contains(sessionId)) return node;
    if (node.sessionIds.length <= 1) return null;
    return node.withRemovedSession(sessionId);
  }
  final split = node as PaneSplit;
  final first = removeSessionFromPanes(split.first, sessionId);
  final second = removeSessionFromPanes(split.second, sessionId);
  if (first == null) return second;
  if (second == null) return first;
  return split.copyWith(first: first, second: second);
}

/// [node] with the split [splitId] sharing its room by [ratio] (the share
/// of its first side): where a divider was dragged to.
PaneNode withSplitRatio(PaneNode node, String splitId, double ratio) {
  if (node is! PaneSplit) return node;
  if (node.id == splitId) return node.copyWith(ratio: ratio);
  return node.copyWith(
    first: withSplitRatio(node.first, splitId, ratio),
    second: withSplitRatio(node.second, splitId, ratio),
  );
}
