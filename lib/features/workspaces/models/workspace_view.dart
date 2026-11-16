import 'package:flutter/material.dart';

/// A host referenced by a workspace pane, resolved against the live connection
/// list.
///
/// A workspace stores only *references* to hosts (never credentials or keys),
/// so a member can outlive the connection it points at. [resolved] is false
/// when the underlying connection has been deleted since the workspace was
/// saved - the slot is kept and named from the workspace's stored label map,
/// and launching reports it rather than failing silently.
@immutable
class WorkspaceMemberHost {
  const WorkspaceMemberHost({
    required this.id,
    required this.name,
    required this.colorValue,
    required this.colorIndex,
    required this.resolvedColor,
    required this.userAtAddress,
    required this.resolved,
  });

  /// The referenced connection id.
  final String id;

  /// The connection's current label, or its last-known label when the
  /// connection has been deleted.
  final String name;

  /// The connection's custom colour override (ARGB int), or null.
  final int? colorValue;

  /// The connection's palette colour index.
  final int colorIndex;

  /// The identity colour to draw for this host, resolved through the v1.6
  /// channel model (explicit host override, else inherited group colour, else
  /// neutral). Never encodes status.
  final Color resolvedColor;

  /// `user@host` (with `:port` when non-default) in monospace-ready form.
  /// Empty when the host is unresolved (deleted) and no address is known.
  final String userAtAddress;

  /// False when the referenced connection no longer exists.
  final bool resolved;
}

/// One tab's pane colours, in pane order - enough to draw the small layout
/// thumbnail without re-resolving anything.
@immutable
class WorkspaceTabPreview {
  const WorkspaceTabPreview({required this.paneColors});

  /// One entry per pane in this tab, in left-to-right pane order.
  final List<Color> paneColors;
}

/// Read model for a single workspace, exposed (ordered) by `workspacesProvider`.
///
/// This is a projection over the persisted `SavedTabGroup` joined with the live
/// connection list; it is rebuilt whenever either changes so host names and
/// colours stay current.
@immutable
class WorkspaceView {
  const WorkspaceView({
    required this.id,
    required this.name,
    required this.tabCount,
    required this.paneCount,
    required this.memberHosts,
    required this.lastOpened,
    required this.launchShortcutIndex,
    required this.panePreview,
  });

  final String id;
  final String name;
  final int tabCount;
  final int paneCount;

  /// One entry per pane, across every tab in tab-then-pane order. Length equals
  /// [paneCount].
  final List<WorkspaceMemberHost> memberHosts;

  /// When the workspace was last launched, or null if never opened.
  final DateTime? lastOpened;

  /// Zero-based position among the first nine workspaces, or null from the
  /// tenth onward. No key launches a workspace (Ctrl+1..9 switch tabs), so
  /// nothing shows it as one.
  ///
  /// Derived from the persisted list order - NOT the name - so it stays stable
  /// when a workspace is renamed and only moves when the list itself is
  /// reordered.
  final int? launchShortcutIndex;

  /// Per-tab pane colours for the layout thumbnail. Length equals [tabCount].
  final List<WorkspaceTabPreview> panePreview;

  /// True when at least one referenced host has been deleted.
  bool get hasUnresolvedHosts => memberHosts.any((h) => !h.resolved);
}

/// Outcome of launching a workspace. A launch opens every pane it can and
/// never fails silently: [unresolvedHostNames] names the panes whose host was
/// deleted so the caller can surface them.
@immutable
class WorkspaceLaunchResult {
  const WorkspaceLaunchResult({
    required this.workspaceFound,
    required this.launchedTabCount,
    required this.unresolvedHostNames,
  });

  /// False when no workspace with the requested id exists.
  final bool workspaceFound;

  /// How many tabs were materialised.
  final int launchedTabCount;

  /// Display names of the referenced hosts that could not be resolved
  /// (their connection was deleted). Empty on a fully-resolved launch.
  final List<String> unresolvedHostNames;

  bool get fullyResolved => unresolvedHostNames.isEmpty;
}
