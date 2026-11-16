import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart' show Connection;
import 'package:zestssh/features/workspaces/models/workspace_view.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/saved_tab_group.dart';
import 'package:zestssh/models/workspace.dart';
import 'package:zestssh/models/work_tab.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/features/sftp/sftp_pane_paths.dart';
import 'package:zestssh/services/local_state_store.dart';


/// Where the command palette's Save workspace kept what it saved before 3.0:
/// a store of its own, in plain preferences, holding each window's frame, a
/// pane tree of session ids that meant nothing after a restart, and its
/// hosts. The Hosts page never showed those, and the palette's Load showed
/// no other (3.0 docs check, 22 October 2026). The palette uses this list
/// now; what that store holds is brought in once ([withPaletteWorkspaces])
/// and the key removed.
const String kPaletteWorkspacesKey = 'desktop_workspaces';

/// [groups] with the palette's old workspaces in [raw] (the JSON kept under
/// [kPaletteWorkspacesKey]) added after them: each with its name (the first
/// free "name N" where one has it already), its dates, and each of its hosts
/// in a tab of its own, which is what loading it opened. One already here
/// (by its id), or with no host, is left out; what cannot be read adds none.
List<SavedTabGroup> withPaletteWorkspaces(List<SavedTabGroup> groups, String? raw) {
  if (raw == null) return groups;
  final out = [...groups];
  final List<dynamic> list;
  try {
    list = jsonDecode(raw) as List<dynamic>;
  } catch (_) {
    return groups;
  }
  bool taken(String name) => out.any((g) => g.name.trim().toLowerCase() == name.toLowerCase());
  for (final e in list) {
    final Workspace w;
    try {
      w = Workspace.fromJson(e as Map<String, dynamic>);
    } catch (_) {
      continue;
    }
    if (out.any((g) => g.id == w.id)) continue;
    final hosts = <String>{
      for (final window in w.windows) ...window.connectionIds.where((id) => id.isNotEmpty),
    };
    if (hosts.isEmpty) continue;
    final base = w.name.trim();
    var name = base;
    for (var n = 2; name.isEmpty || taken(name); n++) {
      name = '$base $n'.trim();
    }
    out.add(SavedTabGroup(
      id: w.id,
      name: name,
      tabs: [for (final id in hosts) TabSnapshot(paneTreeOfConnIds: PaneLeaf.single(sessionId: id))],
      createdAt: w.createdAt,
      lastUsedAt: w.lastUsedAt,
    ));
  }
  return out;
}

/// What a workspace keeps of a layout: its tabs, and each host's name for when
/// the host is gone.
typedef WorkspaceCapture = ({List<TabSnapshot> tabs, Map<String, String> hostNames});

/// User-saved tab-group "workspaces". Persisted in the encrypted database
/// ([LocalStateStore], schema v36): a workspace carries every SFTP pane's
/// remote and local folder and the remote user, so it does not belong in
/// plaintext preferences. A list an older build left there is imported once.
final savedTabGroupsProvider =
    StateNotifierProvider<SavedTabGroupsNotifier, List<SavedTabGroup>>(
  (ref) => SavedTabGroupsNotifier(ref),
);

/// The Telnet hosts among [connIds] (one that is gone is not among them).
Future<List<Connection>> telnetHostsAmong(ConnectionsDao dao, Iterable<String> connIds) async {
  final found = <Connection>[];
  for (final id in {...connIds}) {
    if (id.isEmpty) continue;
    final host = await dao.getById(id);
    if (host != null && host.protocol == 'telnet') found.add(host);
  }
  return found;
}

class SavedTabGroupsNotifier extends StateNotifier<List<SavedTabGroup>> {
  final Ref _ref;

  // True once the stored list has been read. Nothing is written back before
  // that: with the vault locked at start-up the database is closed, and an
  // early persist would overwrite the user's workspaces with an empty list.
  bool _restored = false;
  ProviderSubscription<bool>? _readySub;

  SavedTabGroupsNotifier(this._ref) : super(const []) {
    _restoreWhenReady();
  }

  void _restoreWhenReady() {
    if (_ref.read(dbReadyProvider)) {
      unawaited(_restore());
      return;
    }
    _readySub = _ref.listen<bool>(dbReadyProvider, (_, ready) {
      if (ready && !_restored) unawaited(_restore());
    });
  }

  Future<void> _restore() async {
    try {
      final store = _ref.read(localStateStoreProvider);
      final prefs = _ref.read(sharedPreferencesProvider);
      final raw = await store.importFromPrefs(
        kSavedTabGroupsKey,
        () => prefs.getString(kSavedTabGroupsKey),
        () => prefs.remove(kSavedTabGroupsKey),
      );
      _restored = true;
      _readySub?.close();
      _readySub = null;
      if (!mounted) return;
      final restored = <SavedTabGroup>[];
      if (raw != null) {
        final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
        for (final m in list) {
          final g = SavedTabGroup.fromJson(m);
          if (g != null) restored.add(g);
        }
      }
      // The command palette's own workspaces, from before it saved here:
      // brought in once, kept in this (encrypted) store, then taken out of
      // the plain preferences they were in.
      final withPalette = withPaletteWorkspaces(restored, prefs.getString(kPaletteWorkspacesKey));
      if (withPalette.length != restored.length) {
        await store.write(kSavedTabGroupsKey, jsonEncode(withPalette.map((g) => g.toJson()).toList()));
      }
      if (prefs.containsKey(kPaletteWorkspacesKey)) await prefs.remove(kPaletteWorkspacesKey);
      if (!mounted) return;
      state = withPalette;
    } catch (_) {
      // Database closed or corrupt data: keep what is in memory and try again
      // on the next ready signal; never persist over the stored list.
    }
  }

  void _persist() {
    if (!_restored) return;
    final store = _ref.read(localStateStoreProvider);
    unawaited(store
        .write(kSavedTabGroupsKey, jsonEncode(state.map((g) => g.toJson()).toList()))
        .catchError((Object _) {}));
  }

  @override
  void dispose() {
    _readySub?.close();
    super.dispose();
  }

  /// Save the tab with [tabId] as a new workspace. Returns the saved id.
  /// Returns null if the tab is empty or any session can't be mapped to a
  /// connection (e.g. ad-hoc session with no DB record).
  String? saveTab(String tabId, String name) {
    final tabs = _ref.read(workTabsProvider).tabs;
    final tab = tabs.firstWhere(
      (t) => t.id == tabId,
      orElse: () => WorkTab(paneTree: tabs.isEmpty
          ? throw StateError('no tabs')
          : tabs.first.paneTree),
    );
    if (tab.id != tabId) return null;
    return _saveTabs([tab], name);
  }

  /// Save *all* current work tabs as a single workspace.
  String? saveAll(String name) {
    final tabs = _ref.read(workTabsProvider).tabs;
    if (tabs.isEmpty) return null;
    return _saveTabs(tabs, name);
  }

  String? _saveTabs(List<WorkTab> sourceTabs, String name) {
    final sessions = _ref.read(activeSessionsProvider);
    final panePaths = _ref.read(sftpPanePathsProvider);
    final snapshots = <TabSnapshot>[];
    for (final tab in sourceTabs) {
      final snapTree = mapPaneTreeIds(tab.paneTree, (sessionId) {
        final s = sessions[sessionId];
        if (s == null) return null;
        return s.connectionId;
      }, keepIds: true);
      if (snapTree == null) return null;
      snapshots.add(TabSnapshot(
        customName: tab.customName,
        colorIndex: tab.colorIndex,
        paneTreeOfConnIds: snapTree,
        // Each SFTP pane's folder rides along (remember-last-folder spec).
        panePaths: collectPanePaths(tab.paneTree, (sid) => panePaths[sid]),
      ));
    }
    if (snapshots.isEmpty) return null;
    final group = SavedTabGroup(name: name, tabs: snapshots);
    state = [...state, group];
    _persist();
    return group.id;
  }

  /// Rename a saved group.
  void rename(String savedId, String name) {
    final idx = state.indexWhere((g) => g.id == savedId);
    if (idx < 0) return;
    final updated = state[idx].copyWith(name: name);
    final next = List<SavedTabGroup>.from(state);
    next[idx] = updated;
    state = next;
    _persist();
  }

  /// Delete a saved group.
  void delete(String savedId) {
    final next = state.where((g) => g.id != savedId).toList();
    if (next.length == state.length) return;
    state = next;
    _persist();
  }

  // ── Workspaces v1.6 surface ─────────────────────────────────────

  /// The saved workspace with [id], or null.
  SavedTabGroup? byId(String id) {
    for (final g in state) {
      if (g.id == id) return g;
    }
    return null;
  }

  /// The saved workspace whose name matches [name] case-insensitively after
  /// trimming surrounding whitespace, or null. [excludingId] skips a specific
  /// workspace so the edit dialog can rename without colliding with itself.
  ///
  /// This is the guard behind the "two workspaces both named Main" bug: the
  /// save dialog disables Save whenever this returns non-null.
  SavedTabGroup? workspaceByName(String name, {String? excludingId}) {
    final norm = name.trim().toLowerCase();
    if (norm.isEmpty) return null;
    for (final g in state) {
      if (g.id == excludingId) continue;
      if (g.name.trim().toLowerCase() == norm) return g;
    }
    return null;
  }

  /// First free `"<base> N"` (N starting at 2) not already taken by another
  /// workspace: the "Save as ..." collision resolution.
  String nextAvailableName(String base) {
    final trimmed = base.trim();
    var n = 2;
    while (workspaceByName('$trimmed $n') != null) {
      n++;
    }
    return '$trimmed $n';
  }

  /// Capture the current live layout (all open, non-closing work tabs whose
  /// panes reference saved connections) as snapshots plus a label map for the
  /// referenced hosts. Null when nothing is capturable.
  ({List<TabSnapshot> tabs, Map<String, String> hostNames})? captureCurrent() {
    final tabsState = _ref.read(workTabsProvider);
    final sessions = _ref.read(activeSessionsProvider);
    final panePaths = _ref.read(sftpPanePathsProvider);
    final snaps = captureTabsAsSnapshots(
      tabsState.tabs,
      (sid) => sessions[sid]?.connectionId,
      // Each SFTP pane's folders ride along (remember-last-folder spec), and
      // a launch opens the pane there again (3.0 docs check: the save of the
      // Hosts page's workspaces had stopped keeping them).
      panePathsFor: (sid) => panePaths[sid],
    );
    if (snaps == null) return null;
    final byId = _connectionsById();
    final names = <String, String>{};
    for (final snap in snaps) {
      for (final leaf in snap.paneTreeOfConnIds.allLeaves) {
        for (final cid in leaf.sessionIds) {
          final c = byId[cid];
          if (c != null) names[cid] = c.connection.label;
        }
      }
    }
    return (tabs: snaps, hostNames: names);
  }

  Map<String, ConnectionWithDetails> _connectionsById() {
    final conns =
        _ref.read(connectionsWithDetailsProvider).valueOrNull ?? const [];
    return {for (final c in conns) c.connection.id: c};
  }

  /// [tabs] as a workspace would keep them, pane by pane: with [keep] only the
  /// panes it names ([capturePanesAsSnapshots]), and only panes of saved hosts.
  /// Null when none is left. What the save dialog saves, for each of its
  /// choices (This tab, All tabs, Choose tabs).
  WorkspaceCapture? captureTabs(List<WorkTab> tabs, {Set<String>? keep}) {
    final sessions = _ref.read(activeSessionsProvider);
    final panePaths = _ref.read(sftpPanePathsProvider);
    final hosts = _ref.read(connectionsWithDetailsProvider).valueOrNull;
    final byId = _connectionsById();
    final snaps = capturePanesAsSnapshots(
      tabs,
      (sid) {
        final id = sessions[sid]?.connectionId;
        // Before the hosts are read (a moment at the start) a session's
        // connection is taken as saved, as a capture of everything takes it.
        return id != null && (hosts == null || byId.containsKey(id)) ? id : null;
      },
      keep: keep,
      panePathsFor: (sid) => panePaths[sid],
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
    return (tabs: snaps, hostNames: names);
  }

  /// Save [captured] as a NEW workspace named [name], at the end of the list
  /// so existing launch shortcuts don't reshuffle. Returns the new id.
  String saveCaptured(String name, WorkspaceCapture captured) {
    final group = SavedTabGroup(
      name: name.trim(),
      tabs: captured.tabs,
      hostNames: captured.hostNames,
    );
    state = [...state, group];
    _persist();
    return group.id;
  }

  /// Put [captured] into the workspace [id], keeping its id, place, launch
  /// shortcut and `lastUsedAt`. False when [id] is unknown.
  bool replaceWithCaptured(String id, WorkspaceCapture captured) {
    if (byId(id) == null) return false;
    updateWorkspace(id, tabs: captured.tabs, hostNames: captured.hostNames);
    return true;
  }

  /// The tabs [launchResolving] opened from each workspace this run of the
  /// app. Not persisted: a fresh process opened none.
  final Map<String, Set<String>> _openedTabs = {};

  /// The tabs still open that were opened from the workspace [id]: what its
  /// Update puts back into it.
  List<WorkTab> tabsOpenedFrom(String id) {
    final opened = _openedTabs[id];
    if (opened == null) return const [];
    return [
      for (final tab in _ref.read(workTabsProvider).tabs)
        if (opened.contains(tab.id) && !tab.pendingClose) tab,
    ];
  }

  /// Add the open tab [tabId] to the workspace [id], after its tabs ("Add this
  /// tab to a workspace" in a tab's right-click menu). False when there is no
  /// such workspace or tab, or the tab has no pane of a saved host.
  bool addTabToWorkspace(String id, String tabId) {
    final group = byId(id);
    if (group == null) return false;
    final tabs = _ref.read(workTabsProvider).tabs.where((t) => t.id == tabId).toList();
    final captured = tabs.isEmpty ? null : captureTabs(tabs);
    if (captured == null) return false;
    updateWorkspace(
      id,
      // New leaf ids: the workspace may be this tab's already (saved from it),
      // and its editor tells its panes apart by their ids.
      tabs: [...group.tabs, ...captured.tabs.map(withFreshLeafIds)],
      hostNames: {...group.hostNames, ...captured.hostNames},
    );
    return true;
  }

  /// Save the current live layout as a NEW workspace named [name]. Appended to
  /// the end of the list so existing launch shortcuts don't reshuffle. Returns
  /// the new id, or null when there is nothing capturable to save.
  String? saveCurrentLayout(String name) {
    final captured = captureCurrent();
    if (captured == null) return null;
    final group = SavedTabGroup(
      name: name.trim(),
      tabs: captured.tabs,
      hostNames: captured.hostNames,
    );
    state = [...state, group];
    _persist();
    return group.id;
  }

  /// Swap the panes of the existing workspace [id] to the current live layout,
  /// keeping its id, list position, launch shortcut and `lastUsedAt`. Backs
  /// both the save dialog's `Replace "<name>"` resolution and the edit dialog's
  /// `Replace with current layout`. Returns false when [id] is unknown or there
  /// is nothing capturable.
  bool replaceWithCurrentLayout(String id) {
    final idx = state.indexWhere((g) => g.id == id);
    if (idx < 0) return false;
    final captured = captureCurrent();
    if (captured == null) return false;
    final next = List<SavedTabGroup>.from(state);
    next[idx] = state[idx].copyWith(
      tabs: captured.tabs,
      hostNames: captured.hostNames,
    );
    state = next;
    _persist();
    return true;
  }

  /// Apply edits from the edit dialog in place, preserving id / position /
  /// launch shortcut. Any of [name], [tabs], [hostNames] may be supplied.
  void updateWorkspace(
    String id, {
    String? name,
    List<TabSnapshot>? tabs,
    Map<String, String>? hostNames,
  }) {
    final idx = state.indexWhere((g) => g.id == id);
    if (idx < 0) return;
    final next = List<SavedTabGroup>.from(state);
    next[idx] = state[idx].copyWith(
      name: name?.trim(),
      tabs: tabs,
      hostNames: hostNames,
    );
    state = next;
    _persist();
  }

  /// Remove the workspace [id] immediately, returning a record (with its former
  /// list index) so the caller can offer an undo. Destructive actions on
  /// workspaces are always soft: this does NOT touch any host or connection.
  DeletedWorkspaceRecord? softDelete(String id) {
    final idx = state.indexWhere((g) => g.id == id);
    if (idx < 0) return null;
    final removed = state[idx];
    state = [...state]..removeAt(idx);
    _persist();
    return DeletedWorkspaceRecord(group: removed, index: idx);
  }

  /// Re-insert a soft-deleted workspace at its original position (Undo).
  void restoreDeleted(DeletedWorkspaceRecord record) {
    // Guard against a double-undo or an id that came back some other way.
    if (state.any((g) => g.id == record.group.id)) return;
    final next = List<SavedTabGroup>.from(state);
    next.insert(record.index.clamp(0, next.length), record.group);
    state = next;
    _persist();
  }

  /// Launch a workspace, opening every pane it CAN and reporting the panes it
  /// could not (their referenced host was deleted) rather than failing
  /// silently. Deleted-host slots are kept as placeholder ("Connect…") panes so
  /// the tab layout is preserved.
  ///
  /// A Telnet host among its panes is asked about before anything opens,
  /// once for the lot ([askPlaintext], true for "connect anyway"). With no
  /// answer (nobody to ask) or a no, its panes stay empty places too and the
  /// others open: a caller that forgets the question opens no Telnet host.
  /// (A workspace opened its Telnet hosts with no question: found in a
  /// security audit.)
  Future<WorkspaceLaunchResult> launchResolving(
    String id, {
    Future<bool> Function(List<Connection> telnet)? askPlaintext,
  }) async {
    final idx = state.indexWhere((g) => g.id == id);
    if (idx < 0) {
      return const WorkspaceLaunchResult(
        workspaceFound: false,
        launchedTabCount: 0,
        unresolvedHostNames: [],
      );
    }
    final group = state[idx];

    final dao = _ref.read(connectionsDaoProvider);
    final sessionsNotifier = _ref.read(activeSessionsProvider.notifier);
    final workTabsNotifier = _ref.read(workTabsProvider.notifier);

    final telnet = await telnetHostsAmong(dao, [
      for (final snap in group.tabs)
        for (final leaf in snap.paneTreeOfConnIds.allLeaves) ...leaf.sessionIds,
    ]);
    final plaintext = telnet.isEmpty || (askPlaintext != null && await askPlaintext(telnet));
    final leftOut = plaintext ? const <String>{} : {for (final c in telnet) c.id};

    var launched = 0;
    final unresolved = <String>[]; // display names, in encounter order
    final opened = <String>{};

    for (final snap in group.tabs) {
      // The pane's leaves; their session ids are connection ids here.
      final leaves = snap.paneTreeOfConnIds.allLeaves;
      final hosts = <String, Connection?>{};
      final missing = <String>{};
      // The first session opened on each host in this tab.
      final firstOn = <String, String>{};

      // A session on [cid], or null (its host was deleted, or it could not
      // start: recorded once per tab).
      Future<String?> open(String cid) async {
        // A Telnet host the person would not open: an empty place, and not
        // among those named as gone.
        if (leftOut.contains(cid)) return null;
        final conn = hosts.containsKey(cid) ? hosts[cid] : (hosts[cid] = await dao.getById(cid));
        String? sid;
        if (conn != null) {
          workTabsNotifier.expectSplitSession();
          sid = sessionsNotifier.startSession(conn, allowDuplicate: true);
        }
        if (sid == null) {
          if (missing.add(cid)) unresolved.add(group.hostNames[cid] ?? cid);
          return null;
        }
        firstOn.putIfAbsent(cid, () => sid!);
        return sid;
      }

      // Each terminal pane opens its own session, as it had its own when the
      // tab was saved: two panes on one host (a shell beside htop) are two
      // shells, not one shown twice. An SFTP pane works in the session of
      // the first terminal on its host, as the SFTP dock does, or in one of
      // its own when the tab has none.
      final liveOf = Map<PaneLeaf, List<String>>.identity();
      for (final sftp in [false, true]) {
        for (final leaf in leaves) {
          if ((leaf.type == 'sftp') != sftp) continue;
          liveOf[leaf] = [
            for (final cid in leaf.sessionIds) ?((sftp ? firstOn[cid] : null) ?? await open(cid)),
          ];
        }
      }

      // Nothing in this tab resolved; skip creating an all-placeholder tab.
      if (firstOn.isEmpty) continue;

      // Seed each SFTP pane's remembered folders before its leaf mounts, so
      // the pane opens where it was (remember-last-folder spec, section 1).
      final panePathsNotifier = _ref.read(sftpPanePathsProvider.notifier);
      for (final leaf in leaves) {
        if (leaf.type != 'sftp' || leaf.isPlaceholder) continue;
        final paths = snap.panePaths[leaf.id];
        final sid = liveOf[leaf]?.firstOrNull;
        if (paths != null && sid != null) panePathsNotifier.seed(sid, paths);
      }

      final liveTree = _buildLiveTree(snap.paneTreeOfConnIds, liveOf);

      final firstSid = [for (final leaf in leaves) ...?liveOf[leaf]].first;
      final tabId = workTabsNotifier.createTab(firstSid);
      workTabsNotifier.replaceTabTree(tabId, liveTree);
      if (snap.customName != null) {
        workTabsNotifier.renameTab(tabId, snap.customName);
      }
      if (snap.colorIndex != null) {
        workTabsNotifier.setTabColor(tabId, snap.colorIndex);
      }
      opened.add(tabId);
      launched++;
    }
    _openedTabs[id] = opened;

    // Record the open even on a partial launch. The list is looked at again:
    // a question may have stood open meanwhile.
    final at = state.indexWhere((g) => g.id == id);
    if (at >= 0) {
      final next = List<SavedTabGroup>.from(state);
      next[at] = state[at].copyWith(lastUsedAt: DateTime.now());
      state = next;
      _persist();
    }

    return WorkspaceLaunchResult(
      workspaceFound: true,
      launchedTabCount: launched,
      unresolvedHostNames: unresolved,
    );
  }

  /// Rebuild [snap] (whose leaf ids are connection ids) into a live pane tree,
  /// each leaf holding the sessions [liveOf] opened for it, substituting a
  /// placeholder leaf wherever none could be so the slot is kept rather than
  /// collapsing the layout.
  PaneNode _buildLiveTree(PaneNode snap, Map<PaneLeaf, List<String>> liveOf) {
    if (snap is PaneLeaf) {
      final live = liveOf[snap] ?? const <String>[];
      if (live.isEmpty) {
        return PaneLeaf.placeholder(type: snap.type);
      }
      return PaneLeaf(
        sessionIds: live,
        activeIndex: snap.activeIndex.clamp(0, live.length - 1),
        type: snap.type,
      );
    }
    if (snap is PaneSplit) {
      return PaneSplit(
        first: _buildLiveTree(snap.first, liveOf),
        second: _buildLiveTree(snap.second, liveOf),
        axis: snap.axis,
        ratio: snap.ratio,
      );
    }
    return PaneLeaf.placeholder();
  }
}
