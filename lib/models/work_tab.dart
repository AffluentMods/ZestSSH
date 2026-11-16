import 'package:uuid/uuid.dart';
import 'package:zestssh/models/pane_tree.dart';

const _uuid = Uuid();

/// A "work tab" - a single tab in the desktop top bar that owns its own
/// pane tree. A tab containing a single session has a `PaneLeaf` tree;
/// splitting/merging within a tab grows the tree without affecting other tabs.
///
/// Multiple sessions can be merged into one tab; dragging a tab onto another
/// tab combines their pane trees.
class WorkTab {
  /// Stable id used for active-tab tracking and persistence.
  final String id;

  /// Optional user-provided label. When null, the tab label is derived from
  /// the contained sessions' connection labels.
  final String? customName;

  /// Pane tree owned by this tab. Always non-null - at minimum a single-leaf
  /// tree containing one session id.
  final PaneNode paneTree;

  /// Optional per-tab color override (index into
  /// [AppColors.connectionLabelColors]). When null, the tab inherits the
  /// color of its first session's connection.
  final int? colorIndex;

  /// True when the user has pinned this tab. Pinned tabs sort to the
  /// far left of the pill bar (before any unpinned tab), render a pin
  /// glyph in the pill, and survive "Close Others" / "Close All".
  final bool pinned;

  /// Transient: the user clicked X (or Close Others / Close All) and
  /// the tab is in its **5-second undo window**. While this is true:
  ///   * The pill bar filters the tab out (it visually disappears).
  ///   * The render dispatch ignores it as the active tab.
  ///   * The underlying SSH session(s) are still alive - nothing has
  ///     been disconnected yet, so clicking "Undo" in the snackbar
  ///     just clears this flag and the tab reappears intact.
  ///   * After the timer expires, the desktop shell calls
  ///     `endSession` for every member session and `closeTab` to
  ///     remove the tab for real.
  ///
  /// Not persisted to JSON - restarting cancels any in-flight close
  /// (the tab is restored as if Undo had been pressed).
  final bool pendingClose;

  WorkTab({
    String? id,
    this.customName,
    required this.paneTree,
    this.colorIndex,
    this.pinned = false,
    this.pendingClose = false,
  }) : id = id ?? _uuid.v4();

  /// Session ids contained in this tab (across all panes / tab lists).
  List<String> get sessionIds => [
        for (final leaf in paneTree.allLeaves) ...leaf.sessionIds,
      ];

  /// Session ids of TERMINAL panes only (excludes SFTP panes). Features that
  /// mean "the terminals in this group" - broadcast, terminal counts - use
  /// this so an SFTP pane is never mistaken for a broadcastable terminal.
  List<String> get terminalSessionIds => [
        for (final leaf in paneTree.allLeaves)
          if (leaf.type != 'sftp') ...leaf.sessionIds,
      ];

  /// Whether this tab contains [sessionId] anywhere in its tree.
  bool contains(String sessionId) => sessionIds.contains(sessionId);

  WorkTab copyWith({
    String? customName,
    bool clearCustomName = false,
    PaneNode? paneTree,
    int? colorIndex,
    bool clearColorIndex = false,
    bool? pinned,
    bool? pendingClose,
  }) {
    return WorkTab(
      id: id,
      customName: clearCustomName ? null : (customName ?? this.customName),
      paneTree: paneTree ?? this.paneTree,
      colorIndex: clearColorIndex ? null : (colorIndex ?? this.colorIndex),
      pinned: pinned ?? this.pinned,
      pendingClose: pendingClose ?? this.pendingClose,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        if (customName != null) 'customName': customName,
        'paneTree': paneTree.toJson(),
        if (colorIndex != null) 'colorIndex': colorIndex,
        if (pinned) 'pinned': true,
      };

  static WorkTab? fromJson(Map<String, dynamic> json) {
    final tree = PaneNode.fromJson(json['paneTree'] as Map<String, dynamic>?);
    if (tree == null) return null;
    return WorkTab(
      id: json['id'] as String?,
      customName: json['customName'] as String?,
      paneTree: tree,
      colorIndex: json['colorIndex'] as int?,
      pinned: (json['pinned'] as bool?) ?? false,
    );
  }
}

/// Snapshot state for the work tabs notifier.
class WorkTabsState {
  final List<WorkTab> tabs;
  final String? activeTabId;

  const WorkTabsState({this.tabs = const [], this.activeTabId});

  WorkTab? get activeTab {
    if (activeTabId == null) return null;
    for (final t in tabs) {
      if (t.id == activeTabId) return t;
    }
    return null;
  }

  /// Index of the tab with [id], or -1.
  int indexOf(String id) {
    for (var i = 0; i < tabs.length; i++) {
      if (tabs[i].id == id) return i;
    }
    return -1;
  }

  WorkTabsState copyWith({
    List<WorkTab>? tabs,
    String? activeTabId,
    bool clearActive = false,
  }) {
    return WorkTabsState(
      tabs: tabs ?? this.tabs,
      activeTabId: clearActive ? null : (activeTabId ?? this.activeTabId),
    );
  }

  Map<String, dynamic> toJson() => {
        'tabs': tabs.map((t) => t.toJson()).toList(),
        if (activeTabId != null) 'activeTabId': activeTabId,
      };

  static WorkTabsState fromJson(Map<String, dynamic> json) {
    final list = (json['tabs'] as List?) ?? const [];
    final tabs = <WorkTab>[];
    for (final raw in list) {
      final tab = WorkTab.fromJson(raw as Map<String, dynamic>);
      if (tab != null) tabs.add(tab);
    }
    return WorkTabsState(
      tabs: tabs,
      activeTabId: json['activeTabId'] as String?,
    );
  }
}
