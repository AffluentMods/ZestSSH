import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/models/work_tab.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' show activeSessionsProvider, filesOnlySessionsProvider, screenSessionsProvider;
import 'package:zestssh/providers/work_tabs_provider.dart';

// Broadcast: what a person types or pastes into one terminal is typed into
// others as well.
//
// On a computer it belongs to a TAB. A tab broadcasts or it does not; while
// it does, what is typed into one of its terminals goes to the others of
// that tab, except the ones left out. Its terminals are the ones on screen
// in it: the session in front of each terminal pane. Nothing is ever typed
// into a terminal nobody can see: not one behind another in its pane, and
// not one shown in a window of its own.
//
// Who receives follows the tab: a session that leaves the tab leaves the
// broadcast (it used to keep receiving, and typing into it still reached
// every pane of the group it had left), one that joins receives, and a tab
// that is closed or comes down to one terminal stops broadcasting, for good:
// it does not start again by itself when terminals join it later. A terminal
// that is left out is a terminal like any other: nothing typed elsewhere
// reaches it, and what is typed into it goes nowhere else.
//
// On a phone there are no tabs: the person picks the sessions that type
// together ([BroadcastModeState.enabled], [BroadcastModeState.targetSessionIds]).
//
// What is broadcast is what was TYPED (keys, text, a paste), typed again
// into each receiving terminal: never what a terminal answers by itself,
// and never the mouse (ActiveSessionsNotifier wires this).

/// Who types together.
final broadcastModeProvider = StateNotifierProvider<BroadcastModeNotifier, BroadcastModeState>(
  (ref) => BroadcastModeNotifier(ref),
);

/// The sessions a tab's broadcast passes over ([terminalsOf]'s `away`):
/// those shown in a window of their own, and those that are files only
/// (an SFTP-only host), which have no shell to type into, and remote
/// screens (4.0), whose keys go to a picture.
final broadcastAwayProvider = Provider<Set<String>>((ref) {
  final detached = ref.watch(detachedSessionsProvider);
  final filesOnly = ref.watch(filesOnlySessionsProvider);
  final screens = ref.watch(screenSessionsProvider);
  return filesOnly.isEmpty && screens.isEmpty ? detached : {...detached, ...filesOnly, ...screens};
});

class BroadcastModeState {
  /// On a phone: whether the sessions of [targetSessionIds] type together.
  final bool enabled;
  final Set<String> targetSessionIds;

  /// On a computer: the tabs that broadcast, each with the sessions of it
  /// that are left out.
  final Map<String, Set<String>> tabs;

  const BroadcastModeState({
    this.enabled = false,
    this.targetSessionIds = const {},
    this.tabs = const {},
  });

  BroadcastModeState copyWith({
    bool? enabled,
    Set<String>? targetSessionIds,
    Map<String, Set<String>>? tabs,
  }) =>
      BroadcastModeState(
        enabled: enabled ?? this.enabled,
        targetSessionIds: targetSessionIds ?? this.targetSessionIds,
        tabs: tabs ?? this.tabs,
      );

  /// Whether the tab [tabId] broadcasts.
  bool broadcasts(String tabId) => tabs.containsKey(tabId);

  /// The sessions of the tab [tabId] that are left out of its broadcast.
  Set<String> leftOut(String tabId) => tabs[tabId] ?? const {};

  /// Whether anything is broadcast anywhere.
  bool get any => enabled || tabs.isNotEmpty;
}

/// The fewest terminals a broadcast is for: with one there is nobody to
/// type to.
const kBroadcastFewest = 2;

/// The terminals of [tab] that are on screen in it: the session in front of
/// each terminal pane, each once, in the tab's order. Not SFTP, not an empty
/// place to connect, not a session behind another one in its pane, and none
/// of [away] (the sessions shown in a window of their own).
List<String> terminalsOf(WorkTab tab, {Set<String> away = const {}}) {
  final seen = <String>{};
  return [
    for (final leaf in tab.paneTree.allLeaves)
      if (leaf.type != 'sftp' && !leaf.isPlaceholder)
        if (leaf.sessionId.isNotEmpty && !away.contains(leaf.sessionId) && seen.add(leaf.sessionId))
          leaf.sessionId,
  ];
}

/// The terminals of [tab] that type together: its terminals on screen
/// ([terminalsOf]) but the ones left out. Empty when the tab does not
/// broadcast.
List<String> broadcastReceivers(BroadcastModeState state, WorkTab tab, {Set<String> away = const {}}) {
  if (!state.broadcasts(tab.id)) return const [];
  final out = state.leftOut(tab.id);
  return [
    for (final id in terminalsOf(tab, away: away))
      if (!out.contains(id)) id,
  ];
}

/// Who gets what is typed into [sessionId], besides that session itself.
/// Nobody when it does not broadcast: its tab does not, it is left out of
/// its tab's broadcast, or it is not on screen there.
Set<String> broadcastPeers(
  BroadcastModeState state,
  WorkTabsState tabs,
  String sessionId, {
  Set<String> away = const {},
}) {
  for (final tab in tabs.tabs) {
    if (!tab.contains(sessionId)) continue;
    if (!state.broadcasts(tab.id)) break;
    final receivers = broadcastReceivers(state, tab, away: away);
    if (!receivers.contains(sessionId)) return const {};
    return {
      for (final id in receivers)
        if (id != sessionId) id,
    };
  }
  // A phone's picked sessions.
  if (state.enabled && state.targetSessionIds.contains(sessionId)) {
    return {
      for (final id in state.targetSessionIds)
        if (id != sessionId) id,
    };
  }
  return const {};
}

/// The terminals that type together in the tab in front, in its order.
/// Empty while that tab does not broadcast.
final activeTabBroadcastProvider = Provider<List<String>>((ref) {
  final state = ref.watch(broadcastModeProvider);
  final tab = ref.watch(activeWorkTabProvider);
  if (tab == null) return const [];
  return broadcastReceivers(state, tab, away: ref.watch(broadcastAwayProvider));
});

class BroadcastModeNotifier extends StateNotifier<BroadcastModeState> {
  BroadcastModeNotifier(this._ref) : super(const BroadcastModeState());

  final Ref _ref;
  bool _following = false;

  final _stoppedByItself = StreamController<String>.broadcast();

  /// The tabs whose broadcast stopped by itself: the tab is still there,
  /// with fewer than two terminals on screen (one closed or moved out, a
  /// pane maximized). The window says so, for nobody to type on believing
  /// every host gets it.
  Stream<String> get stoppedByItself => _stoppedByItself.stream;

  @override
  void dispose() {
    _stoppedByItself.close();
    super.dispose();
  }

  // ── A computer: by tab ────────────────────────────────────────

  /// The sessions shown in a window of their own, and those with no shell.
  /// (Read from where each is kept, not through [broadcastAwayProvider]: a
  /// window that just opened is told to [settle] before that is worked out
  /// again.)
  Set<String> get _away {
    final detached = _ref.read(detachedSessionsProvider);
    final sessions = _ref.read(activeSessionsProvider.notifier);
    final filesOnly = sessions.filesOnlySessionIds;
    final screens = sessions.screenSessionIds;
    return filesOnly.isEmpty && screens.isEmpty ? detached : {...detached, ...filesOnly, ...screens};
  }

  /// The tab [tabId] broadcasts from now on, to all of its terminals but
  /// [leftOut]. False, and nothing changes, when it has fewer than two
  /// terminals on screen: there is nobody to type to.
  bool startTab(String tabId, {Set<String> leftOut = const {}}) {
    if (state.broadcasts(tabId)) return true;
    WorkTab? tab;
    for (final t in _ref.read(workTabsProvider).tabs) {
      if (t.id == tabId) tab = t;
    }
    if (tab == null || tab.pendingClose) return false;
    final terminals = terminalsOf(tab, away: _away);
    if (terminals.length < kBroadcastFewest) return false;
    _follow();
    state = state.copyWith(tabs: {
      ...state.tabs,
      tabId: {
        for (final id in leftOut)
          if (terminals.contains(id)) id,
      },
    });
    return true;
  }

  /// The tab [tabId] stops broadcasting.
  void stopTab(String tabId) {
    if (!state.broadcasts(tabId)) return;
    state = state.copyWith(tabs: {
      for (final e in state.tabs.entries)
        if (e.key != tabId) e.key: e.value,
    });
  }

  /// Whether the session [sessionId] takes part in the broadcast of the tab
  /// [tabId]. Nothing changes while the tab does not broadcast.
  void setReceiving(String tabId, String sessionId, bool receives) {
    if (!state.broadcasts(tabId)) return;
    final out = {...state.leftOut(tabId)};
    if (receives ? !out.remove(sessionId) : !out.add(sessionId)) return;
    state = state.copyWith(tabs: {...state.tabs, tabId: out});
  }

  /// Every terminal of the tab [tabId] takes part in its broadcast again.
  void receiveAll(String tabId) {
    if (state.leftOut(tabId).isEmpty) return;
    state = state.copyWith(tabs: {...state.tabs, tabId: const {}});
  }

  /// Who receives follows the tabs and the windows, from the first tab that
  /// broadcasts on. (A phone has neither, and never asks for them.)
  void _follow() {
    if (_following) return;
    _following = true;
    _ref.listen<WorkTabsState>(workTabsProvider, (_, _) => settle());
    _ref.listen<Set<String>>(detachedSessionsProvider, (_, _) => settle());
  }

  /// Follows the tabs as they stand: a tab that is gone, is being closed or
  /// has fewer than two terminals on screen stops broadcasting, and a
  /// session that left its tab is forgotten there.
  void settle() {
    if (state.tabs.isEmpty) return;
    final byId = {for (final t in _ref.read(workTabsProvider).tabs) t.id: t};
    final away = _away;
    final next = <String, Set<String>>{};
    final stopped = <String>[];
    var changed = false;
    for (final e in state.tabs.entries) {
      final tab = byId[e.key];
      if (tab == null || tab.pendingClose || terminalsOf(tab, away: away).length < kBroadcastFewest) {
        changed = true;
        // (A tab that is closed, or being closed, says nothing.)
        if (tab != null && !tab.pendingClose) stopped.add(e.key);
        continue;
      }
      // (One that went behind another in its pane is still left out when it
      // comes to the front again.)
      final here = tab.terminalSessionIds;
      final out = {
        for (final id in e.value)
          if (here.contains(id)) id,
      };
      if (out.length != e.value.length) changed = true;
      next[e.key] = out;
    }
    if (changed) state = state.copyWith(tabs: next);
    if (stopped.isEmpty) return;
    // Said once what is happening now has happened: sessions that end
    // together leave their tab one by one, and a tab on its way out passes
    // through one terminal left. Only a tab still there says it.
    scheduleMicrotask(() {
      if (_stoppedByItself.isClosed) return;
      final now = {for (final t in _ref.read(workTabsProvider).tabs) t.id: t};
      for (final id in stopped) {
        final tab = now[id];
        if (tab != null && !tab.pendingClose) _stoppedByItself.add(id);
      }
    });
  }

  // ── A phone: the sessions that were picked ────────────────────

  void toggle() {
    state = state.copyWith(enabled: !state.enabled);
  }

  void enable(Set<String> sessionIds) {
    state = state.copyWith(enabled: true, targetSessionIds: sessionIds);
  }

  /// Nothing is broadcast anywhere any more.
  void disable() {
    state = const BroadcastModeState();
  }

  void addTarget(String sessionId) {
    state = state.copyWith(
      targetSessionIds: {...state.targetSessionIds, sessionId},
    );
  }

  void removeTarget(String sessionId) {
    final updated = Set<String>.from(state.targetSessionIds);
    updated.remove(sessionId);
    state = state.copyWith(targetSessionIds: updated);
  }

  void toggleTarget(String sessionId) {
    if (state.targetSessionIds.contains(sessionId)) {
      removeTarget(sessionId);
    } else {
      addTarget(sessionId);
    }
  }
}
