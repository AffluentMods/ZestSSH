import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart' show Connection;
import 'package:zestssh/features/workspaces/models/workspace_view.dart';
import 'package:zestssh/models/pane_layout.dart' show tilePanes;
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/saved_tab_group.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/saved_tab_groups_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/utils/host_address.dart';

/// Ordered read model of every saved workspace, joined with the live
/// connection list so member names and identity colours stay current and a
/// deleted host surfaces as an unresolved slot.
///
/// This is the single contract other surfaces consume (drawer, Hosts page,
/// Split-tab empty state). List order is the persisted order, which also drives
/// [WorkspaceView.launchShortcutIndex] (Ctrl+1..9) - stable across renames.
final workspacesProvider = Provider<List<WorkspaceView>>((ref) {
  final groups = ref.watch(savedTabGroupsProvider);
  final byId = _connectionsById(ref);
  final out = <WorkspaceView>[];
  for (var i = 0; i < groups.length; i++) {
    out.add(_viewFromGroup(groups[i], i, byId));
  }
  return out;
});

/// A [WorkspaceView] describing the CURRENT live layout (what a save would
/// capture), or null when there is nothing capturable open. Backs the save
/// dialog's preview. Not persisted; recomputed as tabs / sessions change.
final currentLayoutPreviewProvider = Provider<WorkspaceView?>((ref) {
  final tabsState = ref.watch(workTabsProvider);
  final sessions = ref.watch(activeSessionsProvider);
  final byId = _connectionsById(ref);
  final snaps = captureTabsAsSnapshots(
    tabsState.tabs,
    (sid) => sessions[sid]?.connectionId,
  );
  if (snaps == null) return null;
  final names = <String, String>{};
  for (final snap in snaps) {
    for (final leaf in snap.paneTreeOfConnIds.allLeaves) {
      for (final cid in leaf.sessionIds) {
        final c = byId[cid];
        if (c != null) names[cid] = c.connection.label;
      }
    }
  }
  final draft = SavedTabGroup(id: '', name: '', tabs: snaps, hostNames: names);
  return _viewFromGroup(draft, -1, byId);
});

/// What the save dialog saves of what is open (before,
/// it always took every tab and pane, so other terminals had to
/// be closed first).
enum WorkspaceSaveScope { thisTab, allTabs, chosen }

/// A pane of an open tab, as the save dialog's Choose tabs lists it.
@immutable
class WorkspaceSavePane {
  const WorkspaceSavePane({
    required this.leafId,
    required this.name,
    this.host,
    this.groupId,
    this.groupName,
    this.isSftp = false,
  });

  final String leafId;

  /// The session's name, where it has no saved host.
  final String name;

  /// The saved host it is a session of; null where it has none (a local shell
  /// made for the moment), and a workspace cannot keep it.
  final ConnectionWithDetails? host;
  final String? groupId;
  final String? groupName;
  final bool isSftp;
}

/// An open tab with its panes, as the save dialog's Choose tabs lists it.
@immutable
class WorkspaceSaveTab {
  const WorkspaceSaveTab({required this.id, required this.customName, required this.panes});

  final String id;
  final String? customName;
  final List<WorkspaceSavePane> panes;

  /// The panes a workspace can keep.
  Iterable<WorkspaceSavePane> get saveable => panes.where((p) => p.host != null);
}

/// Every open tab with its panes, in the strip's order.
final openTabsForSaveProvider = Provider<List<WorkspaceSaveTab>>((ref) {
  final tabs = ref.watch(workTabsProvider).tabs;
  final sessions = ref.watch(activeSessionsProvider);
  final byId = _connectionsById(ref);
  return [
    for (final tab in tabs)
      if (!tab.pendingClose)
        WorkspaceSaveTab(
          id: tab.id,
          customName: tab.customName,
          panes: [
            for (final leaf in tab.paneTree.allLeaves)
              if (!leaf.isPlaceholder)
                () {
                  final session = sessions[leaf.sessionId];
                  // Stacked in one place, the host a workspace can keep may be
                  // behind a local shell ([capturePanesAsSnapshots] keeps it).
                  final host = byId[session?.connectionId] ??
                      leaf.sessionIds.map((s) => byId[sessions[s]?.connectionId]).nonNulls.firstOrNull;
                  return WorkspaceSavePane(
                    leafId: leaf.id,
                    name: session?.connectionLabel ?? '',
                    host: host,
                    groupId: host?.group?.id,
                    groupName: host?.group?.name,
                    isSftp: leaf.type == 'sftp',
                  );
                }(),
          ],
        ),
  ];
});

/// What the save dialog shows of [captured] before it is saved.
WorkspaceView workspaceViewOfCapture(WidgetRef ref, WorkspaceCapture captured) {
  final all = ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
  final draft = SavedTabGroup(id: '', name: '', tabs: captured.tabs, hostNames: captured.hostNames);
  return _viewFromGroup(draft, -1, {for (final c in all) c.connection.id: c});
}

/// What Update would do to the workspace it came from (found in review:
/// it put what happened to be open in the workspace's place, so
/// a workspace of which a plan's limit opened one tab of three lost the other
/// two).
@immutable
class WorkspaceUpdatePlan {
  const WorkspaceUpdatePlan({required this.open, required this.keeping, required this.removing, required this.notOpen});

  /// What is open now, which Update saves where nothing else is asked.
  final WorkspaceCapture open;

  /// That with the panes not open put back ("Keep them").
  final WorkspaceCapture keeping;

  /// That with no empty place left of them ("Remove them").
  final WorkspaceCapture removing;

  /// The hosts of the saved panes that are not open.
  final List<WorkspaceMemberHost> notOpen;
}

/// The plan of Update for the workspace [id], from the tabs still open that
/// came from it. Null where none of them holds a pane a workspace can keep:
/// there is nothing to update it with (hosts of another space, say).
WorkspaceUpdatePlan? workspaceUpdatePlan(WidgetRef ref, String id) {
  final notifier = ref.read(savedTabGroupsProvider.notifier);
  final group = notifier.byId(id);
  final open = group == null ? null : notifier.captureTabs(notifier.tabsOpenedFrom(id));
  if (group == null || open == null) return null;
  final all = ref.read(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
  final byId = {for (final c in all) c.connection.id: c};
  return WorkspaceUpdatePlan(
    open: open,
    keeping: (
      tabs: withPanesNotOpen(group.tabs, open.tabs),
      hostNames: {...group.hostNames, ...open.hostNames},
    ),
    removing: (tabs: withoutEmptyPlaces(open.tabs), hostNames: open.hostNames),
    notOpen: [
      for (final pane in panesNotOpen(group.tabs, open.tabs))
        for (final host in pane.sessionIds) _memberFor(host, group, byId),
    ],
  );
}

/// The most panes a tab of a workspace made from picked hosts holds: the
/// same cap as a split made in a session.
const int kWorkspaceHostsPerTab = 8;

/// A workspace of the hosts [connIds] (in that order), as "Save as workspace"
/// on the Hosts page makes it: their panes side by side in the grid a tab
/// nobody arranged stands in, [kWorkspaceHostsPerTab] to a tab (more go on to
/// a next tab), with each host's name kept for when it is gone. Null when
/// none of them is a saved host.
WorkspaceCapture? workspaceOfHosts(
  List<ConnectionWithDetails> all,
  List<String> connIds,
) {
  final byId = {for (final c in all) c.connection.id: c};
  final ids = [for (final id in connIds) if (byId.containsKey(id)) id];
  if (ids.isEmpty) return null;
  final tabs = <TabSnapshot>[
    for (var i = 0; i < ids.length; i += kWorkspaceHostsPerTab)
      TabSnapshot(
        paneTreeOfConnIds: tilePanes([
          for (final id in ids.skip(i).take(kWorkspaceHostsPerTab)) PaneLeaf.single(sessionId: id),
        ]),
      ),
  ];
  return (tabs: tabs, hostNames: {for (final id in ids) id: byId[id]!.connection.label});
}

/// What the save dialog shows of a workspace of [connIds] before it is
/// saved ([workspaceOfHosts]), or null when there is nothing to save.
WorkspaceView? workspaceViewOfHosts(WidgetRef ref, List<String> connIds) {
  final all = ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
  final made = workspaceOfHosts(all, connIds);
  if (made == null) return null;
  final draft = SavedTabGroup(id: '', name: '', tabs: made.tabs, hostNames: made.hostNames);
  return _viewFromGroup(draft, -1, {for (final c in all) c.connection.id: c});
}

/// Saves a workspace of [connIds] named [name] ([workspaceOfHosts]) at the
/// end of the list, so the launch shortcuts of the others stay. Returns its
/// id, or null when there was nothing to save.
String? saveHostsAsWorkspace(WidgetRef ref, String name, List<String> connIds) {
  final all = ref.read(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
  final made = workspaceOfHosts(all, connIds);
  if (made == null) return null;
  final group = SavedTabGroup(name: name.trim(), tabs: made.tabs, hostNames: made.hostNames);
  // The list's own way to put a whole workspace in at a place (its Undo of a
  // delete), at the end: it has no other that takes one made elsewhere.
  ref.read(savedTabGroupsProvider.notifier).restoreDeleted(
        DeletedWorkspaceRecord(group: group, index: ref.read(savedTabGroupsProvider).length),
      );
  return group.id;
}

/// Puts the panes of a workspace of [connIds] into the saved workspace [id]
/// (the save dialog's Replace), keeping its name, place and shortcut.
bool replaceWorkspaceWithHosts(WidgetRef ref, String id, List<String> connIds) {
  final all = ref.read(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
  final made = workspaceOfHosts(all, connIds);
  final notifier = ref.read(savedTabGroupsProvider.notifier);
  if (made == null || notifier.byId(id) == null) return false;
  notifier.updateWorkspace(id, tabs: made.tabs, hostNames: made.hostNames);
  return true;
}

/// Launch the workspace [id]: opens every pane it can and returns which member
/// hosts could not be resolved (their connection was deleted). Never fails
/// silently - callers surface [WorkspaceLaunchResult.unresolvedHostNames].
///
/// [askPlaintext] is the Telnet question, asked once where a pane's host is
/// Telnet; without it those panes stay empty.
Future<WorkspaceLaunchResult> launchWorkspace(
  WidgetRef ref,
  String id, {
  Future<bool> Function(List<Connection> telnet)? askPlaintext,
}) {
  // Remember which workspace was launched last so the card / editor can show
  // it as "open now" while its sessions are live (see openWorkspaceIdProvider).
  ref.read(lastLaunchedWorkspaceIdProvider.notifier).state = id;
  return ref.read(savedTabGroupsProvider.notifier).launchResolving(id, askPlaintext: askPlaintext);
}

/// The id of the workspace launched most recently this session, or null. Set
/// by [launchWorkspace]; not persisted (a fresh process has nothing open).
final lastLaunchedWorkspaceIdProvider = StateProvider<String?>((ref) => null);

/// The workspace that is "open now": the most recently launched one, for as
/// long as at least one of its member hosts still has a live session. Null once
/// every one of its sessions is closed, or when nothing was launched. This is
/// what earns a card its brand "open now" treatment; every other card stays
/// neutral (the red / colour-label decoration is gone, see the Workspaces
/// rework).
final openWorkspaceIdProvider = Provider<String?>((ref) {
  final id = ref.watch(lastLaunchedWorkspaceIdProvider);
  if (id == null) return null;
  final ws = ref.watch(workspacesProvider).where((w) => w.id == id).firstOrNull;
  if (ws == null) return null;
  final sessions = ref.watch(activeSessionsProvider);
  final liveConnIds = <String>{
    for (final s in sessions.values)
      if (s.status == SessionStatus.connected ||
          s.status == SessionStatus.connecting)
        if (s.connectionId != null) s.connectionId!,
  };
  return ws.memberHosts.any((m) => liveConnIds.contains(m.id)) ? id : null;
});

// ── Projection helpers ────────────────────────────────────────────

Map<String, ConnectionWithDetails> _connectionsById(Ref ref) {
  final conns =
      ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const [];
  return {for (final c in conns) c.connection.id: c};
}

WorkspaceView _viewFromGroup(
  SavedTabGroup g,
  int index,
  Map<String, ConnectionWithDetails> byId,
) {
  final members = <WorkspaceMemberHost>[];
  final preview = <WorkspaceTabPreview>[];
  var paneCount = 0;

  for (final tab in g.tabs) {
    final colors = <Color>[];
    for (final leaf in tab.paneTreeOfConnIds.allLeaves) {
      paneCount++;
      final member = _memberFor(_representativeConnId(leaf), g, byId);
      members.add(member);
      colors.add(member.resolvedColor);
    }
    preview.add(WorkspaceTabPreview(paneColors: colors));
  }

  return WorkspaceView(
    id: g.id,
    name: g.name,
    tabCount: g.tabs.length,
    paneCount: paneCount,
    memberHosts: members,
    lastOpened: g.lastUsedAt,
    launchShortcutIndex: (index >= 0 && index < 9) ? index : null,
    panePreview: preview,
  );
}

/// The connection id representing a pane (its active tab within the leaf).
String? _representativeConnId(PaneLeaf leaf) {
  if (leaf.sessionIds.isEmpty) return null;
  final i = leaf.activeIndex.clamp(0, leaf.sessionIds.length - 1);
  final id = leaf.sessionIds[i];
  return id.isEmpty ? null : id;
}

WorkspaceMemberHost _memberFor(
  String? connId,
  SavedTabGroup g,
  Map<String, ConnectionWithDetails> byId,
) {
  if (connId == null) {
    return const WorkspaceMemberHost(
      id: '',
      name: '',
      colorValue: null,
      colorIndex: 0,
      resolvedColor: AppColors.neutralLabelColor,
      userAtAddress: '',
      resolved: false,
    );
  }

  final cwd = byId[connId];
  if (cwd == null) {
    // Referenced host deleted since the workspace was saved. Keep the slot,
    // name it from the stored label map (empty when unknown - the UI labels it),
    // and render neutral (never a status colour).
    return WorkspaceMemberHost(
      id: connId,
      name: g.hostNames[connId] ?? '',
      colorValue: null,
      colorIndex: 0,
      resolvedColor: AppColors.neutralLabelColor,
      userAtAddress: '',
      resolved: false,
    );
  }

  return workspaceMemberForConnection(cwd);
}

/// The display member for a LIVE connection: the same name / colour-label /
/// `user@host` resolution the read model uses. Also used by the workspace
/// editor when the user adds a host to a saved workspace, so the new pane row
/// renders exactly like the existing ones.
WorkspaceMemberHost workspaceMemberForConnection(ConnectionWithDetails cwd) {
  final conn = cwd.connection;
  final group = cwd.group;
  final inheritedGroupColor = group != null
      ? resolveGroupColor(
          colorValue: group.colorValue,
          colorIndex: group.colorIndex,
          name: group.name,
        )
      : null;
  final resolved = AppColors.resolveConnectionLabelColor(
    connColorValue: conn.colorValue,
    connColorIndex: conn.colorIndex,
    inheritedGroupColor: inheritedGroupColor,
  );

  final user = cwd.identity?.username;
  final address = conn.port == 22 ? conn.host : hostWithPort(conn.host, conn.port);
  final userAt =
      (user != null && user.isNotEmpty) ? '$user@$address' : address;

  return WorkspaceMemberHost(
    id: conn.id,
    name: conn.label,
    colorValue: conn.colorValue,
    colorIndex: conn.colorIndex,
    resolvedColor: resolved,
    userAtAddress: userAt,
    resolved: true,
  );
}
