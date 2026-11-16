import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/multi_window_service.dart';

export 'package:zestssh/providers/broadcast_provider.dart';

// ── Desktop Tab State ────────────────────────────────────────────

/// Currently selected tab index in the desktop terminal area.
final desktopSelectedTabProvider = StateProvider<int>((ref) => 0);

/// Moves on each time a tab is picked (its pill, a key): the terminal in
/// front takes the keyboard, the tab in front already too (before,
/// one click picked the tab and a second, into the
/// terminal, was needed to type).
final terminalKeyboardAskProvider = StateProvider<int>((ref) => 0);

/// A remote screen's Files (4.0): the session whose SSH connection's
/// files to open in its tab's SFTP dock. The desktop shell opens them, by the
/// same path as a terminal's SFTP button, and puts this back to null.
final screenFilesRequestProvider = StateProvider<String?>((ref) => null);

// ── Pane Tab Drag State ─────────────────────────────────────────

/// Data carried during a pane tab drag operation.
class PaneTabDragData {
  /// The session being dragged.
  final String sessionId;
  /// The pane leaf the session was dragged FROM.
  final String sourcePaneId;
  /// Display name for the ghost card.
  final String label;

  const PaneTabDragData({
    required this.sessionId,
    required this.sourcePaneId,
    required this.label,
  });
}

/// Whether a pane tab drag is in progress - drives drop zone visibility.
final paneDragActiveProvider = StateProvider<bool>((ref) => false);

/// Drop zone position while dragging: 'paneId:left|right|top|bottom|center'
final paneDragDropZoneProvider = StateProvider<String?>((ref) => null);

/// Sidebar collapsed state (icon-only mode). Persisted, so the rail stays
/// where the user left it: the arrow at the top of the rail and the Toggle
/// sidebar shortcut (Ctrl+B by default) both flip it through
/// [DesktopSettingsUpdater.setSidebarCollapsed].
final sidebarCollapsedProvider = StateProvider<bool>((ref) {
  final prefs = ref.read(sharedPreferencesProvider);
  return prefs.getBool('desktop_sidebar_collapsed') ?? false;
});

/// Sidebar width (resizable by dragging the right edge).
final sidebarWidthProvider = StateProvider<double>((ref) {
  final prefs = ref.read(sharedPreferencesProvider);
  return prefs.getDouble('desktop_sidebar_width') ?? 280.0;
});

/// A1 - Hosts slide-out panel: whether the persistent fast-connect host panel
/// is open. When open, the primary nav collapses to an icon-only rail and the
/// panel sits beside it. Persisted so it survives restarts.
final hostPanelVisibleProvider = StateProvider<bool>((ref) {
  final prefs = ref.read(sharedPreferencesProvider);
  return prefs.getBool('desktop_host_panel_visible') ?? false;
});

/// Host panel width (drag-resizable). Clamped to [kHostPanelMinWidth,
/// kHostPanelMaxWidth] at the UI so it can't be dragged to unusability or made
/// to swallow the session area.
const double kHostPanelMinWidth = 200.0;
const double kHostPanelMaxWidth = 420.0;
final hostPanelWidthProvider = StateProvider<double>((ref) {
  final prefs = ref.read(sharedPreferencesProvider);
  final v = prefs.getDouble('desktop_host_panel_width') ?? 260.0;
  return v.clamp(kHostPanelMinWidth, kHostPanelMaxWidth);
});

/// Group ids collapsed in the host panel. Persisted as a string list.
final hostPanelCollapsedGroupsProvider = StateProvider<Set<String>>((ref) {
  final prefs = ref.read(sharedPreferencesProvider);
  return (prefs.getStringList('desktop_host_panel_collapsed_groups') ?? const [])
      .toSet();
});

// ── Docked Connection Editor (New / Edit) ────────────────────────

/// The sections of the host editor on a computer (its rail), in their order:
/// a caller can open it on one ([ConnectionEditorTarget.initialSection]).
/// The host's address, its key and its user are under [basic].
enum HostEditorSection { basic, auth, network, terminal, advanced }

/// Identifies which connection the docked right-side editor is showing.
///
/// A [connectionId] of `null` means the editor is open on a brand-NEW
/// connection. The provider below holding `null` (rather than a target) means
/// the editor is closed.
class ConnectionEditorTarget {
  const ConnectionEditorTarget({
    this.connectionId,
    this.initialProtocol,
    this.initialHost,
    this.initialPort,
    this.initialLabel,
    this.initialSection,
    this.initialVia,
  });

  /// The section the editor opens on (its first where null).
  final HostEditorSection? initialSection;

  /// The connection being edited, or `null` for a new connection.
  final String? connectionId;

  /// Protocol to pre-select when opening a NEW connection (null id). Ignored
  /// when editing an existing connection. Lets the Hosts SERIAL button open the
  /// docked editor already switched to serial-over-SSH.
  final ConnectionProtocol? initialProtocol;

  /// A new remote screen's SSH host ([ConnectionEditScreen.initialVia]).
  final String? initialVia;

  /// Pre-fill for a NEW connection promoted from a live session ("Save
  /// connection"), so the docked editor opens carrying the session's host /
  /// port / label instead of a blank form. Ignored when editing an existing id.
  final String? initialHost;
  final int? initialPort;
  final String? initialLabel;
}

/// The connection open in the docked right-side editor, or `null` when the
/// editor is closed. Setting a target opens the dock (which sits as a layout
/// sibling in the desktop shell and shrinks the content); setting `null`
/// closes it. Session-only - deliberately not persisted (an in-progress edit
/// shouldn't reopen on restart).
final connectionEditorTargetProvider =
    StateProvider<ConnectionEditorTarget?>((ref) => null);

/// Bounds for the docked editor width. Kept wide enough that the two-column
/// Basic pane never crowds, and capped so it can't swallow the session area.
const double kConnectionEditorMinWidth = 460.0;
const double kConnectionEditorMaxWidth = 980.0;

/// In-memory (session) width of the docked connection editor - resizable via
/// the panel's left-edge drag handle. Not persisted (matches the session-only
/// nature of the editor target).
final connectionEditorWidthProvider = StateProvider<double>((ref) => 700.0);

/// Which sidebar section is selected.
final sidebarSectionProvider = StateProvider<SidebarSection>((ref) {
  return SidebarSection.sessions;
});

enum SidebarSection {
  sessions,
  connections,
  identities,
  snippets,
  portForwards,
  settings,
}

// ── Split Pane State (legacy - use paneTreeProvider instead) ─────

@Deprecated('Use paneTreeProvider from pane_tree_provider.dart instead')
// ignore: deprecated_member_use_from_same_package
/// Legacy split pane configuration. Kept for migration only.
final splitPaneProvider =
    StateNotifierProvider<SplitPaneNotifier, SplitPaneState>(
  (ref) => SplitPaneNotifier(),
);

enum SplitDirection { none, horizontal, vertical }

class SplitPaneState {
  final SplitDirection direction;
  final double ratio;
  final String? secondarySessionId;

  /// When non-null, the secondary pane shows an inline SFTP browser
  /// for this session ID instead of a second terminal.
  final String? sftpSessionId;

  const SplitPaneState({
    this.direction = SplitDirection.none,
    this.ratio = 0.5,
    this.secondarySessionId,
    this.sftpSessionId,
  });

  bool get isActive =>
      direction != SplitDirection.none || sftpSessionId != null;

  /// Whether the SFTP pane is showing.
  bool get isSftpActive => sftpSessionId != null;

  SplitPaneState copyWith({
    SplitDirection? direction,
    double? ratio,
    String? secondarySessionId,
    String? sftpSessionId,
    bool clearSftp = false,
    bool clearSecondary = false,
  }) =>
      SplitPaneState(
        direction: direction ?? this.direction,
        ratio: ratio ?? this.ratio,
        secondarySessionId: clearSecondary
            ? null
            : (secondarySessionId ?? this.secondarySessionId),
        sftpSessionId:
            clearSftp ? null : (sftpSessionId ?? this.sftpSessionId),
      );
}

class SplitPaneNotifier extends StateNotifier<SplitPaneState> {
  SplitPaneNotifier() : super(const SplitPaneState());

  void splitRight(String secondarySessionId) {
    state = SplitPaneState(
      direction: SplitDirection.horizontal,
      ratio: 0.5,
      secondarySessionId: secondarySessionId,
    );
  }

  void splitDown(String secondarySessionId) {
    state = SplitPaneState(
      direction: SplitDirection.vertical,
      ratio: 0.5,
      secondarySessionId: secondarySessionId,
    );
  }

  void updateRatio(double ratio) {
    state = state.copyWith(ratio: ratio.clamp(0.15, 0.85));
  }

  void closeSplit() {
    state = const SplitPaneState();
  }

  void toggleDirection() {
    if (state.direction == SplitDirection.horizontal) {
      state = state.copyWith(direction: SplitDirection.vertical);
    } else if (state.direction == SplitDirection.vertical) {
      state = state.copyWith(direction: SplitDirection.horizontal);
    }
  }

  /// Open an inline SFTP pane beside the terminal for [sessionId].
  void openSftp(String sessionId) {
    state = SplitPaneState(
      direction: state.direction == SplitDirection.none
          ? SplitDirection.horizontal
          : state.direction,
      ratio: state.ratio,
      sftpSessionId: sessionId,
      secondarySessionId: null,
    );
  }

  /// Close the SFTP pane and return to full terminal.
  void closeSftp() {
    state = const SplitPaneState();
  }
}

// ── Broadcast ────────────────────────────────────────────────────
// Who types together lives in broadcast_provider.dart (by tab on a computer,
// by the sessions picked on a phone); it is handed on from here because this
// is where it used to be.

// ── Session Recording ────────────────────────────────────────────

/// Tracks which sessions are being recorded.
final sessionRecordingProvider =
    StateNotifierProvider<SessionRecordingNotifier, Map<String, SessionRecording>>(
  (ref) => SessionRecordingNotifier(),
);

class SessionRecording {
  final String sessionId;
  final DateTime startedAt;
  final List<RecordingEntry> entries;
  final bool isRecording;

  SessionRecording({
    required this.sessionId,
    required this.startedAt,
    List<RecordingEntry>? entries,
    this.isRecording = true,
  }) : entries = entries ?? [];
}

class RecordingEntry {
  final Duration timestamp;
  final String data;

  const RecordingEntry({required this.timestamp, required this.data});
}

class SessionRecordingNotifier
    extends StateNotifier<Map<String, SessionRecording>> {
  SessionRecordingNotifier() : super({});

  void startRecording(String sessionId) {
    state = {
      ...state,
      sessionId: SessionRecording(
        sessionId: sessionId,
        startedAt: DateTime.now(),
      ),
    };
  }

  void stopRecording(String sessionId) {
    final recording = state[sessionId];
    if (recording == null) return;
    final updated = Map<String, SessionRecording>.from(state);
    updated.remove(sessionId);
    state = updated;
  }

  void addEntry(String sessionId, String data) {
    final recording = state[sessionId];
    if (recording == null || !recording.isRecording) return;
    final elapsed = DateTime.now().difference(recording.startedAt);
    // Append in place (O(1) amortized) instead of spreading the entire list
    recording.entries.add(RecordingEntry(timestamp: elapsed, data: data));
    // Trigger state update with a new map reference
    state = Map.from(state);
  }

  bool isRecording(String sessionId) =>
      state[sessionId]?.isRecording ?? false;

  /// Export recording as plain text transcript.
  ///
  /// WARNING: The transcript contains raw terminal I/O and may include
  /// passwords typed at sudo/su prompts or other interactive password
  /// fields. The export header warns the recipient.
  String exportAsText(String sessionId) {
    final recording = state[sessionId];
    if (recording == null) return '';
    final buffer = StringBuffer();
    buffer.writeln('ZestSSH Session Transcript');
    buffer.writeln('Session: $sessionId');
    buffer.writeln('Started: ${recording.startedAt.toIso8601String()}');
    buffer.writeln();
    buffer.writeln('SECURITY WARNING: This transcript contains raw terminal');
    buffer.writeln('output and may include passwords or secrets typed during');
    buffer.writeln('the session. Handle with care and do not share publicly.');
    buffer.writeln('=' * 60);
    for (final entry in recording.entries) {
      buffer.write(entry.data);
    }
    return buffer.toString();
  }
}

// ── Desktop Settings ─────────────────────────────────────────────

// NOTE: `desktopCopyOnSelectProvider` / `desktop_copy_on_select` was removed
// (S1). It was an orphaned duplicate of the wired terminal `copyOnSelect`
// setting (settings_service `copy_on_select`, consumed at
// desktop_terminal_area.dart) and drove nothing. Any previously persisted
// `desktop_copy_on_select` value is now inert.

/// Desktop-specific settings persisted via SharedPreferences.
final desktopRightClickPasteProvider = StateProvider<bool>((ref) {
  final prefs = ref.read(sharedPreferencesProvider);
  return prefs.getBool('desktop_right_click_paste') ?? true;
});

final desktopMiddleClickPasteProvider = StateProvider<bool>((ref) {
  final prefs = ref.read(sharedPreferencesProvider);
  return prefs.getBool('desktop_middle_click_paste') ?? true;
});


final desktopConfirmCloseWithSessionsProvider = StateProvider<bool>((ref) {
  final prefs = ref.read(sharedPreferencesProvider);
  return prefs.getBool('desktop_confirm_close_sessions') ?? true;
});

/// Recently closed tabs (for Ctrl+Shift+T reopening).
final recentlyClosedTabsProvider =
    StateNotifierProvider<RecentlyClosedTabsNotifier, List<String>>(
  (ref) => RecentlyClosedTabsNotifier(),
);

class RecentlyClosedTabsNotifier extends StateNotifier<List<String>> {
  RecentlyClosedTabsNotifier() : super([]);

  void add(String connectionId) {
    state = [connectionId, ...state.take(9)];
  }

  String? pop() {
    if (state.isEmpty) return null;
    final id = state.first;
    state = state.sublist(1);
    return id;
  }
}

// ── Pinned / Favorite Connections ────────────────────────────────

final pinnedConnectionIdsProvider = StateProvider<Set<String>>((ref) {
  final prefs = ref.read(sharedPreferencesProvider);
  final list = prefs.getStringList('desktop_pinned_connections') ?? [];
  return list.toSet();
});

// ── Search across all entities ───────────────────────────────────

final desktopSearchQueryProvider = StateProvider<String>((ref) => '');

// ── Host Key Auto-Accept Notification ───────────────────────

/// Notification shown when a new host key is auto-accepted (TOFU mode off).
/// The UI watches this and shows a brief SnackBar so the user is aware.
class HostKeyAutoAcceptEvent {
  final String host;
  final int port;
  final String keyType;
  final String fingerprint;

  const HostKeyAutoAcceptEvent({
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprint,
  });
}

final hostKeyAutoAcceptProvider =
    StateProvider<HostKeyAutoAcceptEvent?>((ref) => null);

/// Fired the first time this device confirms a host key that was ADOPTED from
/// cloud sync (recorded on another device). The UI shows a one-time,
/// non-blocking notice naming the recording device + date, so a synced
/// fingerprint is trusted informed, never silently.
class HostKeyProvenanceEvent {
  final String host;
  final int port;
  final String device;
  final DateTime recordedAt;

  /// An FTPS server's TLS certificate (3.4) rather than an SSH host key.
  final bool certificate;

  const HostKeyProvenanceEvent({
    required this.host,
    required this.port,
    required this.device,
    required this.recordedAt,
    this.certificate = false,
  });
}

final hostKeyProvenanceProvider =
    StateProvider<HostKeyProvenanceEvent?>((ref) => null);

// ── Desktop Layout Mode ─────────────────────────────────────────

// ── V3 Layout Navigation ───────────────────────────────────────

/// Navigation sections in the v1.5 sidebar.
///
/// Six primary items + Settings below divider. `networks` is the v1.6
/// addition, slotted between `keys` and `portForwarding` per the spec
/// (semantically: identity → environment → network plumbing).
enum NavSection {
  hosts,
  keys,
  networks,
  portForwarding,
  snippets,
  automation,
  monitor,
  settings,
  // Appended last on purpose: the v3 content IndexedStack is keyed by
  // NavSection.values order, so new values go at the end (with appended
  // children) rather than shifting the existing indices. Triggers and Command
  // history are separate rail items under the "Utilities" group.
  triggers,
  commandHistory,
  // The Orchard on screen (3.0): shown in the rail only while one is open.
  team,
}

/// Which sidebar item is active in the v3 narrow sidebar.
/// Whether the Hosts fast-connect drawer is on screen: over a terminal or
/// another page, while it is switched on (the pill-bar Hosts chip); on the
/// Hosts page, which shows every host itself, only where its pill opened it
/// there ([openedOnHostsPage], [hostsDrawerOnHostsPageProvider]). The shell,
/// the sidebar and the pill all ask this one question, so the rail can never
/// stay icon-only for a drawer that is not there, nor the pill light up for one.
bool hostsDrawerShown({
  required bool panelOn,
  required bool terminalShown,
  required NavSection activeNav,
  bool openedOnHostsPage = false,
}) =>
    terminalShown || activeNav != NavSection.hosts ? panelOn : openedOnHostsPage;

final activeSidebarNavProvider =
    StateProvider<NavSection>((ref) => NavSection.hosts);

/// Whether the Hosts drawer was opened on the Hosts page itself, by its pill:
/// the page hid it whatever the pill said, so the pill lit up and nothing
/// opened. It closes again when the Hosts page is
/// come back to.
final hostsDrawerOnHostsPageProvider =
    NotifierProvider<HostsDrawerOnHostsPage, bool>(HostsDrawerOnHostsPage.new);

class HostsDrawerOnHostsPage extends Notifier<bool> {
  @override
  bool build() {
    ref.listen(activeSidebarNavProvider, (previous, next) {
      if (next == NavSection.hosts && previous != NavSection.hosts) state = false;
    });
    return false;
  }

  void toggle() => state = !state;
}

/// Whether the session info slide-out panel is visible.
final sessionSlidePanelVisibleProvider = StateProvider<bool>((ref) => false);

/// Which session tab is active in the v3 pill bar.
/// When non-null, the main content shows the terminal for this session
/// instead of the sidebar-selected section.
final v3ActiveSessionTabProvider = StateProvider<String?>((ref) => null);

/// A computer's Find in terminal: the session whose pane shows its bar, or
/// null where none does, and how often it was asked for there ([ask]: asked
/// for again where it is open, its field takes the keyboard back).
final terminalFindProvider =
    StateProvider<({String sessionId, int ask})?>((ref) => null);

// ── Focused Pane ─────────────────────────────────────────────────

@Deprecated('Use focusedPaneProvider from pane_tree_provider.dart instead')
/// Which pane currently has focus (primary=0, secondary=1).
/// Prefer the string-based focusedPaneProvider for the new pane tree.
final focusedPaneIndexProvider = StateProvider<int>((ref) => 0);

// ── Window State ─────────────────────────────────────────────────

/// Whether the window is currently in fullscreen mode.
final desktopFullscreenProvider = StateProvider<bool>((ref) => false);

/// Whether always-on-top is enabled.
final desktopAlwaysOnTopProvider = StateProvider<bool>((ref) => false);

/// Whether to minimize to system tray instead of closing.
final desktopMinimizeToTrayProvider = StateProvider<bool>((ref) {
  final prefs = ref.read(sharedPreferencesProvider);
  return prefs.getBool('desktop_minimize_to_tray') ?? false;
});

/// Whether to restore previous sessions on app launch.
final desktopRestoreSessionsProvider = StateProvider<bool>((ref) {
  final prefs = ref.read(sharedPreferencesProvider);
  return prefs.getBool('desktop_restore_sessions') ?? true;
});

// ── Desktop Settings Updater ─────────────────────────────────────

/// Handles writing desktop settings to both provider state and SharedPreferences.
///
/// Desktop settings StateProviders read initial values from SharedPreferences
/// but don't write back on their own. Use this updater to persist changes.
class DesktopSettingsUpdater {
  final Ref _ref;
  DesktopSettingsUpdater(this._ref);

  void setRightClickPaste(bool value) {
    _ref.read(desktopRightClickPasteProvider.notifier).state = value;
    _ref.read(sharedPreferencesProvider).setBool('desktop_right_click_paste', value);
  }

  void setMiddleClickPaste(bool value) {
    _ref.read(desktopMiddleClickPasteProvider.notifier).state = value;
    _ref.read(sharedPreferencesProvider).setBool('desktop_middle_click_paste', value);
  }

  void setConfirmCloseWithSessions(bool value) {
    _ref.read(desktopConfirmCloseWithSessionsProvider.notifier).state = value;
    _ref.read(sharedPreferencesProvider).setBool('desktop_confirm_close_sessions', value);
  }

  void setPinnedConnectionIds(Set<String> ids) {
    _ref.read(pinnedConnectionIdsProvider.notifier).state = ids;
    _ref.read(sharedPreferencesProvider).setStringList('desktop_pinned_connections', ids.toList());
  }

  void setMinimizeToTray(bool value) {
    _ref.read(desktopMinimizeToTrayProvider.notifier).state = value;
    _ref.read(sharedPreferencesProvider).setBool('desktop_minimize_to_tray', value);
  }

  void setRestoreSessions(bool value) {
    _ref.read(desktopRestoreSessionsProvider.notifier).state = value;
    _ref.read(sharedPreferencesProvider).setBool('desktop_restore_sessions', value);
  }

  void setSidebarCollapsed(bool value) {
    _ref.read(sidebarCollapsedProvider.notifier).state = value;
    _ref.read(sharedPreferencesProvider).setBool('desktop_sidebar_collapsed', value);
  }

  void toggleSidebarCollapsed() =>
      setSidebarCollapsed(!_ref.read(sidebarCollapsedProvider));

  void setHostPanelVisible(bool value) {
    _ref.read(hostPanelVisibleProvider.notifier).state = value;
    _ref.read(sharedPreferencesProvider).setBool('desktop_host_panel_visible', value);
  }

  void toggleHostPanel() =>
      setHostPanelVisible(!_ref.read(hostPanelVisibleProvider));

  void setHostPanelWidth(double value) {
    final clamped = value.clamp(kHostPanelMinWidth, kHostPanelMaxWidth);
    _ref.read(hostPanelWidthProvider.notifier).state = clamped;
    _ref.read(sharedPreferencesProvider).setDouble('desktop_host_panel_width', clamped);
  }

  void setHostPanelGroupCollapsed(String groupId, bool collapsed) {
    final next = {..._ref.read(hostPanelCollapsedGroupsProvider)};
    if (collapsed) {
      next.add(groupId);
    } else {
      next.remove(groupId);
    }
    _ref.read(hostPanelCollapsedGroupsProvider.notifier).state = next;
    _ref
        .read(sharedPreferencesProvider)
        .setStringList('desktop_host_panel_collapsed_groups', next.toList());
  }
}

final desktopSettingsUpdaterProvider = Provider<DesktopSettingsUpdater>((ref) {
  return DesktopSettingsUpdater(ref);
});

// ── Multi-Window / Tab Tear-off ──────────────────────────────────

/// Provides the singleton [MultiWindowService] for tab tear-off.
final multiWindowServiceProvider = Provider<MultiWindowService>((ref) {
  return MultiWindowService.instance;
});

/// Tracks which session IDs are currently detached to secondary windows.
///
/// This is a reactive wrapper around [MultiWindowService.detachedSessionIds]
/// that updates when sessions are detached or reattached.
final detachedSessionsProvider =
    StateNotifierProvider<DetachedSessionsNotifier, Set<String>>(
  (ref) => DetachedSessionsNotifier(ref),
);

class DetachedSessionsNotifier extends StateNotifier<Set<String>> {
  DetachedSessionsNotifier(Ref ref) : super({}) {
    // Listen for reattach events from the multi-window service
    MultiWindowService.instance.addReattachListener(_onReattach);
  }

  /// Mark a session as detached (called when creating a secondary window).
  void detach(String sessionId) {
    state = {...state, sessionId};
  }

  /// Mark a session as reattached (called when secondary window closes).
  void reattach(String sessionId) {
    final updated = Set<String>.from(state);
    updated.remove(sessionId);
    state = updated;
  }

  void _onReattach(String sessionId) {
    reattach(sessionId);
  }

  @override
  void dispose() {
    MultiWindowService.instance.removeReattachListener(_onReattach);
    super.dispose();
  }
}

// ── Legacy → Pane Tree Migration ─────────────────────────────────

/// Migrates an old [SplitPaneState] to the new [PaneNode] tree.
///
/// Call this once on startup when transitioning from the legacy split
/// system. Pass the primary session ID and the old split state.
/// Returns a [PaneNode] tree equivalent to the old layout.
// ignore: deprecated_member_use_from_same_package
PaneNode migrateSplitPaneToTree({
  required String primarySessionId,
  // ignore: deprecated_member_use_from_same_package
  required SplitPaneState oldState,
}) {
  final primaryLeaf = PaneLeaf.single(sessionId: primarySessionId);

  if (!oldState.isActive) return primaryLeaf;

  // Determine the secondary leaf.
  final PaneLeaf secondaryLeaf;
  if (oldState.sftpSessionId != null) {
    secondaryLeaf =
        PaneLeaf.single(sessionId: oldState.sftpSessionId!, type: 'sftp');
  } else if (oldState.secondarySessionId != null) {
    secondaryLeaf = PaneLeaf.single(sessionId: oldState.secondarySessionId!);
  } else {
    return primaryLeaf;
  }

  final axis = oldState.direction == SplitDirection.vertical
      ? Axis.vertical
      : Axis.horizontal;

  return PaneSplit(
    first: primaryLeaf,
    second: secondaryLeaf,
    axis: axis,
    ratio: oldState.ratio,
  );
}
