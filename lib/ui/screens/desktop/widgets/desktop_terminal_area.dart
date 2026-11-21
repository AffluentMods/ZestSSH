import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/mosh_contact_mark.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/ui/screens/sharing/share_widgets.dart';
import 'package:zestssh/ui/screens/sharing/watch_ui.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/features/terminal/session_announcer.dart';
import 'package:zestssh/features/terminal/terminal_reader.dart';
import 'package:zestssh/features/triggers/trigger_highlight_binder.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/providers/pane_tree_provider.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/sftp_sessions_provider.dart';
import 'package:zestssh/providers/shortcut_overrides_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/ui/widgets/error_details_panel.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/services/session_ssh.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/services/ftps/ftps_pane_file_source.dart';
import 'package:zestssh/services/ftps/ftps_session.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/sftp/sftp_dual_pane_screen.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/ui/screens/tmux/tmux_session_view.dart';
import 'package:zestssh/ui/screens/tmux/tmux_start_question.dart';
import 'package:zestssh/ui/widgets/connection_lost_view.dart';
import 'package:zestssh/ui/widgets/desktop_drop_target.dart';
import 'package:zestssh/ui/widgets/terminal_paste.dart';
import 'package:zestssh/ui/screens/desktop/widgets/session_chrome.dart';
import 'package:zestssh/ui/screens/desktop/widgets/shell_questions.dart' show confirmUnencryptedConnection;
import 'package:zestssh/ui/screens/desktop/widgets/sftp_dock.dart';
import 'package:zestssh/ui/widgets/layout_preset_picker.dart';
import 'package:zestssh/ui/screens/desktop/widgets/inspector_panel.dart';
import 'package:zestssh/ui/widgets/connection_picker_dialog.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/command_text.dart';
import 'package:zestssh/utils/hidden_characters.dart';
import 'package:zestssh/ui/widgets/pane_tree_view.dart';
import 'package:zestssh/ui/widgets/terminal_tab_bar.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_search_bar.dart';
import 'package:zestssh/ui/screens/terminal/widgets/connection_error_view.dart'
    show maskConnectionLine;
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/features/sftp/sftp_pane_paths.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/features/screens/desktop/screen_pane.dart';
import 'package:zestssh/ui/screens/desktop/widgets/pane_keys_row.dart';
import 'package:zestssh/ui/screens/terminal/hardware_keyboard_use.dart' show hardwareKeyboardUseProvider;
import 'package:zestssh/utils/platform_utils.dart' show isTouchLayout;

/// The main terminal area with tab bar, split panes, and terminal views.
/// One stable key per SFTP dock leaf, so the browser survives moving sides.
final Map<String, GlobalKey> _sftpDockKeys = {};

/// One stable key per session that is files only, so its browser (where it
/// is in its folders, what it is copying) survives its tab being split,
/// joined to another or arranged.
final Map<String, GlobalKey> _filesOnlyKeys = {};

/// A session whose connection dropped that a computer shows in its place:
/// its tab stays, with why and Reconnect (3.0). Not one that was
/// ended or disconnected on purpose (it stays disconnected for a moment as
/// it goes), popped out to a window of its own ([detachedIds]) or hidden.
bool shownAsDropped(SessionState session, String sessionId, Set<String> detachedIds) =>
    session.status == SessionStatus.disconnected &&
    session.dropped &&
    session.connectionId != null &&
    !detachedIds.contains(sessionId) &&
    !session.isHidden;

class DesktopTerminalArea extends ConsumerWidget {
  /// Fills an empty pane with a host (its "Connect" card).
  final void Function(ConnectionWithDetails) onConnectTo;

  /// The session header's SFTP button: opens SFTP for a session, or closes it.
  final ValueChanged<String> onToggleSftp;

  /// The session header's Layout popover: applies a preset to the active tab.
  /// An arrangement was chosen in the Layout popover; null for the
  /// automatic one.
  final ValueChanged<LayoutPreset?> onApplyLayout;

  /// Brings a session's tab to the front: one the SFTP dock opened ("Open
  /// SFTP on its own"). Where none is given, its work tab is made the active
  /// one.
  final ValueChanged<String>? onShowSession;

  const DesktopTerminalArea({
    super.key,
    required this.onConnectTo,
    required this.onToggleSftp,
    required this.onApplyLayout,
    this.onShowSession,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final sessions = ref.watch(activeSessionsProvider);
    final detachedIds = ref.watch(detachedSessionsProvider);
    // Filter out sessions that are detached or hidden
    final activeSessions = sessions.entries
        .where((e) =>
            (e.value.status == SessionStatus.connected ||
                e.value.status == SessionStatus.connecting) &&
            !detachedIds.contains(e.key) &&
            !e.value.isHidden)
        .toList();
    // What is shown in the tabs and panes: those, then the sessions whose
    // connection dropped, each in its own place with why and Reconnect (3.0,
    // before, a dropped session's tab showed another session's terminal,
    // or a pane said "Session not found"). They come after the others, so
    // the place of every live session is what it was.
    final shownSessions = [
      ...activeSessions,
      ...sessions.entries.where((e) => shownAsDropped(e.value, e.key, detachedIds)),
    ];

    // The shell shows this area only where it has a session to show (its
    // hosts and their search, where none is open, were never reached).
    if (shownSessions.isEmpty) return const SizedBox.shrink();

    final selectedTab = ref.watch(desktopSelectedTabProvider);
    final clampedTab = selectedTab.clamp(0, shownSessions.length - 1);
    final fullTree = ref.watch(paneTreeProvider);
    // SFTP is a dock (3.0), never a pane: the terminals lay out without its
    // leaf. The leaf stays in the tab's tree, so saved workspaces, restored
    // tabs and remembered folders keep working as they did.
    final sftpLeaf = sftpLeafOf(fullTree);
    final paneTree = withoutSftp(fullTree);
    final isSplitLayout = paneTree != null && paneTree is PaneSplit;
    // A tab whose only other leaf was SFTP shows that leaf's session.
    var singleIndex = clampedTab;
    if (paneTree is PaneLeaf && !paneTree.isPlaceholder) {
      final i = shownSessions.indexWhere((e) => e.key == paneTree.sessionId);
      if (i >= 0) singleIndex = i;
    }
    // Where a tab is split, the pane the keyboard goes to: the one in focus,
    // else (a tab just picked) its first that holds a terminal.
    final focusedLeafId = ref.watch(focusedPaneProvider);
    final keyboardLeafId = !isSplitLayout
        ? null
        : focusedLeafId != null && paneTree.findLeaf(focusedLeafId) != null
            ? focusedLeafId
            : paneTree.allLeaves
                .where((l) => !l.isPlaceholder && l.type != 'sftp' && l.sessionIds.isNotEmpty)
                .firstOrNull
                ?.id;

    // ── Content: split panes or single terminal ─────────────────
    Widget content;

    if (isSplitLayout) {
      // Split layout - pane tree with snap-zone drop targets per pane.
      // No per-pane headers; the tab bar above handles navigation.
      content = PaneTreeView(
        node: paneTree,
        // Where a divider was dragged to is kept with the tab.
        onRatioChanged: (split, ratio) =>
            ref.read(paneTreeProvider.notifier).setSplitRatio(split.id, ratio),
        leafBuilder: (leaf, isFocused) {
          Widget child;
          // Empty placeholder leaf - rendered as a "Connect…" card. The
          // sort layout flow inserts these when the picked preset needs
          // more panes than there are alive sessions; clicking the card
          // opens a connection picker that fills the slot.
          if (leaf.isPlaceholder) {
            return _PlaceholderPane(
              leafId: leaf.id,
              onConnectTo: onConnectTo,
            );
          }
          if (leaf.type == 'sftp') {
            // Never reached: the terminals are laid out without the SFTP leaf,
            // which shows in the SFTP dock (see _withSftpDock).
            return const SizedBox.shrink();
          } else {
            final tabEntries = <MapEntry<String, SessionState>>[];
            for (final sid in leaf.sessionIds) {
              final e = shownSessions.where((e) => e.key == sid).firstOrNull;
              if (e != null) tabEntries.add(e);
            }
            if (tabEntries.isEmpty) {
              return Center(
                child: Text(
                  l10n.desktopTerminalAreaSessionNotFound,
                  style: TextStyle(color: AppColors.v3TextSecondary),
                ),
              );
            }
            final activeIdx = leaf.activeIndex.clamp(0, tabEntries.length - 1);

            final isDragging = ref.watch(paneDragActiveProvider);
            final activeDropZone = ref.watch(paneDragDropZoneProvider);

            child = DragTarget<TabDragData>(
              onWillAcceptWithDetails: (details) {
                // Don't accept if this pane already shows that session
                final sid = details.data.sessionId;
                if (sid != null && leaf.sessionIds.contains(sid)) return false;
                return activeSessions.length >= 2;
              },
              onAcceptWithDetails: (details) {
                final zone = ref.read(paneDragDropZoneProvider);
                ref.read(paneDragActiveProvider.notifier).state = false;
                ref.read(paneDragDropZoneProvider.notifier).state = null;

                final sessionId = details.data.sessionId;
                if (sessionId == null) return;

                final notifier = ref.read(paneTreeProvider.notifier);

                // Remove session from its current pane first to prevent duplicates
                notifier.removeLeafBySessionId(sessionId);

                // Re-read tree - the target leaf may have changed after removal
                final updatedTree = ref.read(paneTreeProvider);
                if (updatedTree == null) {
                  // Tree collapsed to single/null - re-init and split
                  final baseId = activeSessions
                      .where((e) => e.key != sessionId)
                      .firstOrNull?.key;
                  if (baseId == null) return;
                  notifier.initSinglePane(baseId);
                  final t = ref.read(paneTreeProvider);
                  if (t == null) return;
                  final lid = t.allLeaves.first.id;
                  notifier.splitPaneDirectional(
                      lid, Axis.horizontal, sessionId, false);
                  return;
                }

                // Find the target leaf again (it may have a new ID after tree rebuild)
                final targetLeaf = updatedTree.findLeaf(leaf.id);
                final targetId = targetLeaf?.id ?? updatedTree.allLeaves.first.id;

                final zoneName = zone?.split(':').last ?? 'center';
                switch (zoneName) {
                  case 'left':
                    notifier.splitPaneDirectional(
                        targetId, Axis.horizontal, sessionId, true);
                  case 'right':
                    notifier.splitPaneDirectional(
                        targetId, Axis.horizontal, sessionId, false);
                  case 'top':
                    notifier.splitPaneDirectional(
                        targetId, Axis.vertical, sessionId, true);
                  case 'bottom':
                    notifier.splitPaneDirectional(
                        targetId, Axis.vertical, sessionId, false);
                  default:
                    notifier.addSessionToPane(targetId, sessionId);
                }
                ref.read(focusedPaneProvider.notifier).state = targetId;
              },
              onMove: (details) {
                final renderBox = context.findRenderObject() as RenderBox?;
                if (renderBox == null) return;
                final local = renderBox.globalToLocal(details.offset);
                final size = renderBox.size;
                final relX = local.dx / size.width;
                final relY = local.dy / size.height;

                String zone;
                if (relX < 0.22) {
                  zone = 'left';
                } else if (relX > 0.78) {
                  zone = 'right';
                } else if (relY < 0.22) {
                  zone = 'top';
                } else if (relY > 0.78) {
                  zone = 'bottom';
                } else {
                  zone = 'center';
                }
                final zoneKey = '${leaf.id}:$zone';
                if (ref.read(paneDragDropZoneProvider) != zoneKey) {
                  ref.read(paneDragDropZoneProvider.notifier).state = zoneKey;
                }
                if (!ref.read(paneDragActiveProvider)) {
                  ref.read(paneDragActiveProvider.notifier).state = true;
                }
              },
              onLeave: (_) {
                final current = ref.read(paneDragDropZoneProvider);
                if (current != null && current.startsWith('${leaf.id}:')) {
                  ref.read(paneDragDropZoneProvider.notifier).state = null;
                }
              },
              builder: (dragCtx, candidateData, rejectedData) {
                final isDropTarget = candidateData.isNotEmpty;
                String? currentZone;
                if (activeDropZone != null && activeDropZone.startsWith('${leaf.id}:')) {
                  currentZone = activeDropZone.split(':').last;
                }

                final paneHeader = SlimPaneHeader(
                  leafId: leaf.id,
                  sessions: tabEntries,
                  activeIndex: activeIdx,
                  isFocused: isFocused,
                );

                // Wrap header in a DragTarget so tabs can be dropped
                // directly onto another pane's header bar to move them.
                final headerWidget = DragTarget<TabDragData>(
                  onWillAcceptWithDetails: (details) {
                    final sid = details.data.sessionId;
                    // Accept if the tab is NOT already in this pane
                    return sid != null && !leaf.sessionIds.contains(sid);
                  },
                  onAcceptWithDetails: (details) {
                    final sessionId = details.data.sessionId;
                    if (sessionId == null) return;
                    final notifier = ref.read(paneTreeProvider.notifier);

                    // Remove from source pane
                    notifier.removeLeafBySessionId(sessionId);

                    // Re-read tree - target leaf may have changed
                    final updatedTree = ref.read(paneTreeProvider);
                    if (updatedTree == null) return;
                    final targetLeaf = updatedTree.findLeaf(leaf.id);
                    final targetId = targetLeaf?.id ?? updatedTree.allLeaves.first.id;

                    // Add as a tab in target pane
                    notifier.addSessionToPane(targetId, sessionId);
                    final newLeaf = ref.read(paneTreeProvider)?.findLeaf(targetId);
                    if (newLeaf != null) {
                      notifier.setActiveTab(targetId, newLeaf.sessionIds.length - 1);
                    }
                    ref.read(focusedPaneProvider.notifier).state = targetId;
                    ref.read(paneDragActiveProvider.notifier).state = false;
                    ref.read(paneDragDropZoneProvider.notifier).state = null;
                  },
                  builder: (ctx, candidateData, rejectedData) {
                    final isHeaderDropTarget = candidateData.isNotEmpty;
                    if (isHeaderDropTarget) {
                      return Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: AppColors.v3AccentPrimary.withValues(alpha: 0.6),
                            width: 1.5,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: paneHeader,
                      );
                    }
                    return paneHeader;
                  },
                );

                return Column(
                  children: [
                    headerWidget,
                    // Terminal content with snap zones.
                    //
                    // No pane-selection Listener here: it used to set
                    // focusedPaneProvider synchronously on pointer-down,
                    // which rebuilt the pane mid-gesture and broke
                    // drag-to-select inside split layouts. The inner
                    // _TerminalPane already owns focus + pane selection
                    // (it defers the provider write to a post-frame so it
                    // doesn't interrupt the terminal's pan recognizer), and
                    // every child of this IndexedStack is a _TerminalPane,
                    // so the outer Listener was redundant anyway.
                    Expanded(
                      child: SizedBox.expand(
                        child: Stack(
                          children: [
                            IndexedStack(
                              index: activeIdx,
                              children: [
                                for (final (i, e) in tabEntries.indexed)
                                  RepaintBoundary(
                                    child: _TerminalPane(
                                      key: ValueKey('pane_tab_${leaf.id}_${e.key}'),
                                      sessionId: e.key,
                                      sessionState: e.value,
                                      allSessions: activeSessions,
                                      leafId: leaf.id,
                                      front: leaf.id == keyboardLeafId && i == activeIdx,
                                      visible: i == activeIdx,
                                    ),
                                  ),
                              ],
                            ),
                            // Snap zone overlay
                            if (isDropTarget && currentZone != null && currentZone != 'center')
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: _SnapZoneOverlay(zone: currentZone),
                                ),
                              ),
                            if (isDragging && !isDropTarget)
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: Container(
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: AppColors.v3AccentPrimary.withValues(alpha: 0.15),
                                        width: 1,
                                      ),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            );
          }
          // Focused-pane indicator (§8): a brightened header (see
          // SessionInfoBar.isFocused) PLUS an accent hairline along the pane's
          // TOP edge. The old 3px LEFT accent bar was removed - a left rail
          // reads as an identity rule (§2 invariant: a coloured bar/edge always
          // means identity, never status/focus). The top edge is where focus
          // belongs, and accent is correct here because it encodes focus.
          //
          // Painted as a NON-LAYOUT overlay: `child` sits at a fixed
          // Positioned.fill, so its elements (and their gesture recognizers)
          // survive focus changes untouched - toggling a wrapper Container on
          // focus used to re-create the subtree and eat the first click on an
          // unfocused pane's controls. The hairline is IgnorePointer, so it
          // never intercepts clicks and never shifts layout.
          return Stack(
            children: [
              Positioned.fill(child: child),
              if (isFocused)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: 2,
                  child: IgnorePointer(
                    child: ColoredBox(color: AppColors.v3AccentPrimary),
                  ),
                ),
            ],
          );
        },
      );
    } else {
      // Single layout - snap-zone DragTarget over IndexedStack.
      content = DragTarget<TabDragData>(
        onWillAcceptWithDetails: (details) {
          return activeSessions.length >= 2;
        },
        onAcceptWithDetails: (details) {
          final zone = ref.read(paneDragDropZoneProvider);
          ref.read(paneDragActiveProvider.notifier).state = false;
          ref.read(paneDragDropZoneProvider.notifier).state = null;

          final sessionId = details.data.sessionId;
          if (sessionId == null) return;

          // Put ALL other sessions into the base pane, not just one
          final otherSessionIds = activeSessions
              .where((e) => e.key != sessionId)
              .map((e) => e.key)
              .toList();
          if (otherSessionIds.isEmpty) return;

          final notifier = ref.read(paneTreeProvider.notifier);
          // Initialize with all remaining sessions as tabs in one pane
          notifier.setTree(PaneLeaf(sessionIds: otherSessionIds));
          final tree = ref.read(paneTreeProvider);
          if (tree == null) return;
          final leafId = tree.allLeaves.first.id;

          final zoneName = zone?.split(':').last ?? 'right';
          switch (zoneName) {
            case 'left':
              notifier.splitPaneDirectional(
                  leafId, Axis.horizontal, sessionId, true);
            case 'right':
              notifier.splitPaneDirectional(
                  leafId, Axis.horizontal, sessionId, false);
            case 'top':
              notifier.splitPaneDirectional(
                  leafId, Axis.vertical, sessionId, true);
            case 'bottom':
              notifier.splitPaneDirectional(
                  leafId, Axis.vertical, sessionId, false);
            case 'top_left':
              notifier.splitPaneDirectional(
                  leafId, Axis.horizontal, sessionId, true);
            case 'top_right':
              notifier.splitPaneDirectional(
                  leafId, Axis.horizontal, sessionId, false);
            case 'bottom_left':
              notifier.splitPaneDirectional(
                  leafId, Axis.vertical, sessionId, false);
            case 'bottom_right':
              notifier.splitPaneDirectional(
                  leafId, Axis.vertical, sessionId, false);
            default:
              notifier.splitPane(leafId, Axis.horizontal, sessionId);
          }
        },
        onMove: (details) {
          final renderBox = context.findRenderObject() as RenderBox?;
          if (renderBox == null) return;
          final local = renderBox.globalToLocal(details.offset);
          final size = renderBox.size;
          final relX = local.dx / size.width;
          final relY = local.dy / size.height;

          String zone;
          if (relX < 0.20 && relY < 0.20) {
            zone = 'top_left';
          } else if (relX > 0.80 && relY < 0.20) {
            zone = 'top_right';
          } else if (relX < 0.20 && relY > 0.80) {
            zone = 'bottom_left';
          } else if (relX > 0.80 && relY > 0.80) {
            zone = 'bottom_right';
          } else if (relX < 0.22) {
            zone = 'left';
          } else if (relX > 0.78) {
            zone = 'right';
          } else if (relY < 0.22) {
            zone = 'top';
          } else if (relY > 0.78) {
            zone = 'bottom';
          } else {
            zone = 'center';
          }

          final zoneKey = 'single:$zone';
          if (ref.read(paneDragDropZoneProvider) != zoneKey) {
            ref.read(paneDragDropZoneProvider.notifier).state = zoneKey;
          }
          if (!ref.read(paneDragActiveProvider)) {
            ref.read(paneDragActiveProvider.notifier).state = true;
          }
        },
        onLeave: (_) {
          ref.read(paneDragDropZoneProvider.notifier).state = null;
          ref.read(paneDragActiveProvider.notifier).state = false;
        },
        builder: (dragCtx, candidateData, rejectedData) {
          final isDropTarget = candidateData.isNotEmpty;
          String? currentZone;
          final dropZone = ref.watch(paneDragDropZoneProvider);
          if (dropZone != null && dropZone.startsWith('single:')) {
            currentZone = dropZone.split(':').last;
          }

          return Stack(
            children: [
              IndexedStack(
                index: singleIndex,
                children: [
                  for (final (i, e) in shownSessions.indexed)
                    RepaintBoundary(
                      child: _TerminalPane(
                        key: ValueKey('terminal_pane_${e.key}'),
                        sessionId: e.key,
                        sessionState: e.value,
                        allSessions: activeSessions,
                        front: i == singleIndex,
                        visible: i == singleIndex,
                      ),
                    ),
                ],
              ),
              if (isDropTarget && currentZone != null && currentZone != 'center')
                Positioned.fill(
                  child: IgnorePointer(
                    child: _SnapZoneOverlay(zone: currentZone),
                  ),
                ),
              if (isDropTarget && (currentZone == null || currentZone == 'center'))
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: AppColors.v3AccentPrimary.withValues(alpha: 0.3),
                          width: 2,
                        ),
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      );
    }

    // ── One header over the tab (3.0), naming the session that has focus.
    // Session tabs live in the pill bar; a split pane adds its own slim header.
    // A tab whose session dropped is named by it, not by another session.
    final focused = _focusedSessionEntry(ref, shownSessions, paneTree);
    final Widget body = Column(
      children: [
        if (focused != null)
          SessionHeaderBar(
            sessionId: focused.key,
            sessionState: focused.value,
            onToggleSftp: onToggleSftp,
            onApplyLayout: onApplyLayout,
          ),
        // Session sharing (3.0): while someone else has the keyboard of a
        // session here, or asks for it, a line says so with the way back.
        for (final e in activeSessions) SessionShareStrip(sessionId: e.key),
        // A watched session nobody is watching (3.0): typing is
        // held, and it says when it closes.
        for (final e in activeSessions) WatchHeldBanner(sessionId: e.key),
        // Output that asks for tmux control mode with nobody having asked for
        // tmux: whether to start it.
        for (final e in activeSessions) TmuxStartQuestion(sessionId: e.key),
        Expanded(
          child: sftpLeaf == null
              ? content
              : _withSftpDock(ref, content, sftpLeaf, activeSessions, sessions),
        ),
      ],
    );

    // ── Session Details panel - ONE instance, docked at the right of the
    // whole terminal area, describing whichever pane/session has focus.
    // (Previously each pane rendered its own copy, so a split showed two
    // ~⅓-width panels; this is the F4 de-duplication.)
    // (A remote screen has none of its tools: no snippets, history or look.)
    if (focused == null ||
        !ref.watch(sessionSlidePanelVisibleProvider) ||
        ref.read(activeSessionsProvider.notifier).isScreen(focused.key)) {
      return body;
    }
    return Row(
      children: [
        Expanded(child: body),
        InspectorPanel(
          key: const ValueKey('inspector_panel'),
          sessionId: focused.key,
          sessionState: focused.value,
          onClose: () => ref
              .read(sessionSlidePanelVisibleProvider.notifier)
              .state = false,
        ),
      ],
    );
  }

  /// Brings [sessionId]'s tab to the front: as the shell does where it gave
  /// its way ([onShowSession]), else by making its work tab the active one.
  void _showSession(WidgetRef ref, String sessionId) {
    final show = onShowSession;
    if (show != null) return show(sessionId);
    final tabs = ref.read(workTabsProvider.notifier);
    final tab = tabs.tabContaining(sessionId);
    if (tab != null) tabs.setActiveTab(tab.id);
    ref.read(v3ActiveSessionTabProvider.notifier).state = sessionId;
  }

  /// [terminals] with the SFTP dock beside or below them. The browser keeps
  /// its state (and its transfers) when the dock moves sides or resizes: its
  /// key is global and stable per leaf.
  Widget _withSftpDock(
    WidgetRef ref,
    Widget terminals,
    PaneLeaf sftpLeaf,
    List<MapEntry<String, SessionState>> activeSessions,
    Map<String, SessionState> sessions,
  ) {
    // The side only: a drag of the grip resizes the dock's own box below,
    // not this whole area at every step.
    final chosenSide = ref.watch(sftpDockPrefsProvider.select((p) => p.side));
    _sftpDockKeys.removeWhere((id, _) => id != sftpLeaf.id);
    final key = _sftpDockKeys.putIfAbsent(sftpLeaf.id, GlobalKey.new);
    // The session as it is, its connection dropped too: the dock says so
    // (4.0). It looked for it among the sessions
    // that are connected, so a drop left it without its host's name.
    final session = sessions[sftpLeaf.sessionId];
    return LayoutBuilder(builder: (context, c) {
      // The terminals keep at least this much room; a right dock that would
      // squeeze them shows at the bottom, and the choice is kept.
      const minTerminal = 480.0;
      final canRight = c.maxWidth >= SftpDockPrefs.minWidth + minTerminal;
      final side = chosenSide == SftpDockSide.right && canRight
          ? SftpDockSide.right
          : SftpDockSide.bottom;
      final maxH = c.maxHeight - 140;
      final maxW = c.maxWidth - minTerminal;
      final dock = SftpDockFrame(
        sessionId: sftpLeaf.sessionId,
        sessionState: session,
        side: side,
        canMoveRight: canRight,
        maxSize: side == SftpDockSide.bottom
            ? (maxH < SftpDockPrefs.minHeight ? SftpDockPrefs.minHeight : maxH)
            : maxW,
        onClose: () =>
            ref.read(paneTreeProvider.notifier).closePane(sftpLeaf.id),
        child: _SftpLeafPane(
          key: key,
          sessionId: sftpLeaf.sessionId,
          leafId: sftpLeaf.id,
          activeSessions: activeSessions,
          docked: true,
          sessionState: session,
          onShowSession: (id) => _showSession(ref, id),
        ),
      );
      if (side == SftpDockSide.bottom) {
        return Column(children: [
          Expanded(child: terminals),
          Consumer(builder: (context, ref, child) {
            final h = ref
                .watch(sftpDockPrefsProvider.select((p) => p.height))
                .clamp(SftpDockPrefs.minHeight,
                    maxH < SftpDockPrefs.minHeight ? SftpDockPrefs.minHeight : maxH)
                .toDouble();
            return SizedBox(height: h, child: child);
          }, child: dock),
        ]);
      }
      return Row(children: [
        Expanded(child: terminals),
        Consumer(builder: (context, ref, child) {
          final w = ref
              .watch(sftpDockPrefsProvider.select((p) => p.width))
              .clamp(SftpDockPrefs.minWidth, maxW)
              .toDouble();
          return SizedBox(width: w, child: child);
        }, child: dock),
      ]);
    });
  }

  /// The session whose pane currently has focus - the one the Session Details
  /// panel should describe. Handles all three layouts:
  ///   • split      → focusedPaneProvider → that leaf's active tab
  ///   • single-pane tree → the sole leaf's active tab
  ///   • no tree (single-tab mode) → v3 active-session pointer, else the
  ///     selected tab index
  /// Falls back to the first active session if focus state is stale.
  MapEntry<String, SessionState>? _focusedSessionEntry(
    WidgetRef ref,
    List<MapEntry<String, SessionState>> activeSessions,
    PaneNode? paneTree,
  ) {
    if (activeSessions.isEmpty) return null;

    String? focusedSessionId;
    if (paneTree != null) {
      final focusedLeafId = ref.watch(focusedPaneProvider);
      final leaf = (focusedLeafId != null
              ? paneTree.findLeaf(focusedLeafId)
              : null) ??
          paneTree.allLeaves.firstOrNull;
      if (leaf != null && leaf.sessionIds.isNotEmpty) {
        final idx = leaf.activeIndex.clamp(0, leaf.sessionIds.length - 1);
        focusedSessionId = leaf.sessionIds[idx];
      }
    } else {
      final v3Active = ref.watch(v3ActiveSessionTabProvider);
      if (v3Active != null && activeSessions.any((e) => e.key == v3Active)) {
        focusedSessionId = v3Active;
      } else {
        final sel = ref
            .watch(desktopSelectedTabProvider)
            .clamp(0, activeSessions.length - 1);
        focusedSessionId = activeSessions[sel].key;
      }
    }

    final match =
        activeSessions.where((e) => e.key == focusedSessionId).firstOrNull;
    return match ?? activeSessions.first;
  }
}

// ══════════════════════════════════════════════════════════════════
// Placeholder Pane - empty leaf with "Connect…" button (Stage 2)
// ══════════════════════════════════════════════════════════════════

/// Card rendered for [PaneLeaf]s with no real session - created when the
/// layout sorter is asked for more panes than there are alive terminals.
///
/// Click → opens a connection picker → starts a session and fills the slot.
/// Drag a connection onto the card → fills the slot directly. (Drag is wired
/// defensively now; will light up once host cards become draggable.)
class _PlaceholderPane extends ConsumerStatefulWidget {
  final String leafId;
  final void Function(ConnectionWithDetails) onConnectTo;

  const _PlaceholderPane({
    required this.leafId,
    required this.onConnectTo,
  });

  @override
  ConsumerState<_PlaceholderPane> createState() => _PlaceholderPaneState();
}

class _PlaceholderPaneState extends ConsumerState<_PlaceholderPane> {
  bool _hovering = false;
  bool _dropping = false;

  Future<void> _pickAndFill() async {
    final l10n = AppLocalizations.of(context)!;
    final result = await ConnectionPickerDialog.show(
      context,
      title: l10n.desktopTerminalAreaConnectToTitle,
    );
    if (!mounted) return;
    final picked = result.connection;
    if (picked == null) return;
    await _fillWithConnection(picked);
  }

  /// Start a session for [item] and slot it into this placeholder leaf.
  ///
  /// Uses [WorkTabsNotifier.expectSplitSession] so the new session does NOT
  /// trigger an auto-tab - we want it to land here, not in a fresh tab.
  ///
  /// A Telnet host is asked about first, as every other way of opening one
  /// asks (picked here or dropped here, it opened with no question, as
  /// a security audit found).
  Future<void> _fillWithConnection(ConnectionWithDetails item) async {
    if (item.connection.protocol == 'telnet') {
      final ok = await confirmUnencryptedConnection(context);
      if (!ok || !mounted) return;
    }
    ref.read(workTabsProvider.notifier).expectSplitSession();
    final sid = ref
        .read(activeSessionsProvider.notifier)
        .startSession(item.connection);
    if (sid == null) {
      showTopSnackBar(
        context,
        AppLocalizations.of(context)!
            .desktopTerminalAreaFreeTierLimit(freeSessionLimit),
        isError: true,
      );
      return;
    }
    ref
        .read(paneTreeProvider.notifier)
        .fillPlaceholderLeaf(widget.leafId, sid);
    ref.read(focusedPaneProvider.notifier).state = widget.leafId;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final accent = AppColors.v3AccentPrimary;
    final highlight = _dropping || _hovering;

    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        color: highlight
            ? accent.withValues(alpha: 0.06)
            : AppColors.v3Surface,
        border: Border.all(
          color: highlight
              ? accent.withValues(alpha: 0.45)
              : AppColors.v3BorderSubtle,
          width: _dropping ? 2 : 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(LucideIcons.plus, size: 28, color: AppColors.v3AccentInk),
            ),
            const SizedBox(height: 14),
            Text(
              l10n.desktopTerminalAreaEmptyPane,
              style: TextStyle(
                color: AppColors.v3TextPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.desktopTerminalAreaEmptyPaneHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.v3TextTertiary,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ElevatedButton.icon(
                  onPressed: _pickAndFill,
                  icon: const Icon(LucideIcons.link, size: 16),
                  label: Text(l10n.desktopTerminalAreaConnectEllipsis),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: AppColors.onBrand(accent),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                const SizedBox(width: 8),
                // Secondary escape hatch - a pane split by accident otherwise
                // has no obvious way out. Labelled "Remove pane" (not
                // "Cancel"): there is no in-progress action to cancel.
                TextButton.icon(
                  onPressed: () => ref
                      .read(paneTreeProvider.notifier)
                      .closePane(widget.leafId),
                  icon: const Icon(LucideIcons.x, size: 15),
                  label: Text(l10n.removePane),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.v3TextSecondary,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.all(8),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: _pickAndFill,
          // Accepts drops from host cards in the Hosts grid (both _HostCard
          // and _HostListTile are wrapped in Draggable<ConnectionWithDetails>).
          child: DragTarget<ConnectionWithDetails>(
            onWillAcceptWithDetails: (details) {
              setState(() => _dropping = true);
              return true;
            },
            onLeave: (_) => setState(() => _dropping = false),
            onAcceptWithDetails: (details) {
              setState(() => _dropping = false);
              _fillWithConnection(details.data);
            },
            builder: (_, _, _) => card,
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Snap Zone Overlay - Windows-style zone preview for single-mode
// ══════════════════════════════════════════════════════════════════

class _SnapZoneOverlay extends StatelessWidget {
  final String zone;

  const _SnapZoneOverlay({required this.zone});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final l10n = AppLocalizations.of(context)!;
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final color = AppColors.v3AccentPrimary;

        double left = 0, top = 0;
        double zoneW = w, zoneH = h;
        IconData icon = LucideIcons.columns;
        String label = '';

        switch (zone) {
          case 'left':
            zoneW = w * 0.5;
            icon = LucideIcons.columns;
            label = l10n.desktopTerminalAreaSplitLeft;
          case 'right':
            left = w * 0.5;
            zoneW = w * 0.5;
            icon = LucideIcons.columns;
            label = l10n.desktopTerminalAreaSplitRight;
          case 'top':
            zoneH = h * 0.5;
            icon = LucideIcons.rows;
            label = l10n.desktopTerminalAreaSplitTop;
          case 'bottom':
            top = h * 0.5;
            zoneH = h * 0.5;
            icon = LucideIcons.rows;
            label = l10n.desktopTerminalAreaSplitBottom;
          case 'top_left':
            zoneW = w * 0.5;
            zoneH = h * 0.5;
            icon = LucideIcons.layoutGrid;
            label = l10n.desktopTerminalAreaTopLeft;
          case 'top_right':
            left = w * 0.5;
            zoneW = w * 0.5;
            zoneH = h * 0.5;
            icon = LucideIcons.layoutGrid;
            label = l10n.desktopTerminalAreaTopRight;
          case 'bottom_left':
            top = h * 0.5;
            zoneW = w * 0.5;
            zoneH = h * 0.5;
            icon = LucideIcons.layoutGrid;
            label = l10n.desktopTerminalAreaBottomLeft;
          case 'bottom_right':
            left = w * 0.5;
            top = h * 0.5;
            zoneW = w * 0.5;
            zoneH = h * 0.5;
            icon = LucideIcons.layoutGrid;
            label = l10n.desktopTerminalAreaBottomRight;
        }

        return Stack(
          children: [
            // Dim the whole area
            Positioned.fill(
              child: Container(
                color: Colors.black.withValues(alpha: 0.2),
              ),
            ),
            // Highlight the snap zone
            Positioned(
              left: left,
              top: top,
              width: zoneW,
              height: zoneH,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOut,
                margin: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  border: Border.all(
                    color: color.withValues(alpha: 0.7),
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 32, color: color.withValues(alpha: 0.8)),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.v3AccentInk,
                            fontWeight: FontWeight.w600,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// SFTP Leaf Pane - rendered inside PaneTreeView for 'sftp' leaves
// ══════════════════════════════════════════════════════════════════

class _SftpLeafPane extends ConsumerStatefulWidget {
  final String sessionId;
  final String leafId;
  final List<MapEntry<String, SessionState>> activeSessions;

  /// The SFTP dock beside a terminal (4.0): the host's files in one pane (or
  /// two, as the dock was set), and while the session's connection is down,
  /// that it is, with Reconnect ([SftpDockDisconnected]). False for a session
  /// that is files only, whose own place says when its connection drops.
  final bool docked;

  /// The session as it is now, its connection dropped too (the dock's).
  final SessionState? sessionState;

  /// Brings a session's tab to the front (one "Open SFTP on its own" opened).
  final ValueChanged<String>? onShowSession;

  const _SftpLeafPane({
    super.key,
    required this.sessionId,
    required this.leafId,
    required this.activeSessions,
    this.docked = false,
    this.sessionState,
    this.onShowSession,
  });

  @override
  ConsumerState<_SftpLeafPane> createState() => _SftpLeafPaneState();
}

class _SftpLeafPaneState extends ConsumerState<_SftpLeafPane> {
  SftpService? _sftpService;

  /// An FTPS host's files (3.4), in place of [_sftpService]: on the
  /// session's own FTPS connection, with one more for transfers.
  FtpsPaneFileSource? _ftps;
  String? _sftpError;

  /// The report of why SFTP could not start, to copy (null when there is
  /// nothing more to it than [_sftpError]).
  String? _sftpReport;
  bool _sftpLoading = true;
  bool _initInFlight = false;
  bool _waitingForSsh = false;

  /// Captured in [initState] so [dispose] can unregister the service
  /// without touching `ref` - by the time `dispose` runs, the
  /// [ConsumerStatefulElement] is already deactivated and reading
  /// `ref` throws "Cannot use 'ref' after the widget was disposed".
  late final SftpSessionsNotifier _sessionsNotifier;

  @override
  void initState() {
    super.initState();
    _sessionsNotifier = ref.read(sftpSessionsProvider.notifier);
    // After the first frame: a failure is reported with localized text, which
    // cannot be read while initState is still running.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _initSftp();
    });
  }

  @override
  void dispose() {
    // Pull the service out of state then unregister + close. We don't await
    // - close() is best-effort and dispose() is sync. Uses the captured
    // [_sessionsNotifier] rather than ref.read() because dispose runs
    // after the consumer element has been deactivated.
    final existing = _sftpService;
    _sftpService = null;
    if (existing != null) {
      _sessionsNotifier.unregisterLater(widget.sessionId, existing);
      existing.close();
    }
    // Its transfer connection; the browsing one is the session's.
    _ftps?.close();
    _ftps = null;
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _SftpLeafPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) {
      _initSftp();
      return;
    }
    // Auto-retry once the underlying SSH session becomes ready. This handles
    // the workspace-restore case: when a session is restored from disk the
    // SFTP leaf mounts immediately, but the SSH session is still in the
    // `connecting` state with `session == null` for the first second or two.
    // Without this, the user would have to manually click "Retry" the moment
    // their server finishes connecting.
    if (_sftpService == null && _ftps == null && !_initInFlight && _isSessionReady()) {
      _initSftp();
    }
  }

  /// True when the SSH session for this leaf has finished connecting and
  /// has a live [SshService] we can drive an SFTP channel from.
  bool _isSessionReady() {
    for (final entry in widget.activeSessions) {
      if (entry.key == widget.sessionId) {
        final s = entry.value;
        final shell = s.session?.shell;
        return s.status == SessionStatus.connected &&
            (shell is SshService || (shell is FtpsShellService && shell.client != null));
      }
    }
    return false;
  }

  Future<void> _initSftp() async {
    // Guard against re-entrancy: didUpdateWidget can fire repeatedly while a
    // previous _initSftp is still awaiting `sftp.open()`.
    if (_initInFlight) return;
    _initInFlight = true;

    // If we already had a service registered for this session id, drop it
    // before opening a new one. Happens during retarget (the leaf re-mounts
    // pointing at a different session that may or may not reuse this id).
    final previous = _sftpService;
    if (previous != null) {
      ref.read(sftpSessionsProvider.notifier).unregister(widget.sessionId);
      // Don't await - close races with the new open(). Worst case we leak
      // a half-closed channel for a few seconds.
      previous.close();
    }

    if (mounted) {
      setState(() {
        _sftpLoading = true;
        _sftpError = null;
        _sftpReport = null;
        _sftpService = null;
        _waitingForSsh = false;
      });
    }

    try {
      MapEntry<String, SessionState>? targetSession;
      for (final entry in widget.activeSessions) {
        if (entry.key == widget.sessionId) {
          targetSession = entry;
          break;
        }
      }

      // Session still connecting? Hold the loading state - didUpdateWidget
      // will re-fire `_initSftp` once status flips to `connected`.
      if (targetSession != null &&
          targetSession.value.status == SessionStatus.connecting) {
        if (mounted) {
          setState(() {
            _waitingForSsh = true;
          });
        }
        return;
      }

      // An FTPS host's session (3.4): its files on its own connection, where
      // the host's Crate allows files (its SFTP switch), as for SFTP below.
      final ftpsShell = targetSession?.value.session?.shell;
      if (ftpsShell is FtpsShellService && ftpsShell.client != null) {
        if (!await ref
            .read(activeSessionsProvider.notifier)
            .hostAllows(targetSession!.value.connectionId, CrateSwitches.sftp)) {
          if (mounted) {
            setState(() {
              _sftpLoading = false;
              _sftpError = AppLocalizations.of(context)!.orchardFtpsNotAllowed;
            });
          }
          return;
        }
        await _ftps?.close();
        if (mounted) {
          setState(() {
            _ftps = FtpsPaneFileSource(
                client: ftpsShell.client!, sourceId: widget.sessionId, reconnect: ftpsShell.reconnect);
            _sftpLoading = false;
          });
        }
        return;
      }

      if (targetSession == null ||
          targetSession.value.session == null ||
          sshServiceOfShell(targetSession.value.session!.shell) == null) {
        if (mounted) {
          setState(() {
            _sftpLoading = false;
            _sftpError = AppLocalizations.of(context)!.desktopSftpRequiresActive;
          });
        }
        return;
      }

      // The host's Crate must allow SFTP.
      if (!await ref
          .read(activeSessionsProvider.notifier)
          .hostAllows(targetSession.value.connectionId, CrateSwitches.sftp)) {
        if (mounted) {
          setState(() {
            _sftpLoading = false;
            _sftpError = AppLocalizations.of(context)!.orchardSftpNotAllowed;
          });
        }
        return;
      }

      // A screen's SSH connection too (4.0: Files).
      final sshService = sshServiceOfShell(targetSession.value.session!.shell)!;
      final sftp = SftpService(sshService.client);
      await sftp.open();
      if (mounted) {
        // Publish into the global registry so other panes (and the source
        // dropdown) can find this service by session id. Done here rather
        // than in build() so register/unregister are paired with the
        // service's actual lifetime, not its rendering.
        ref
            .read(sftpSessionsProvider.notifier)
            .register(widget.sessionId, sftp);
        setState(() {
          _sftpService = sftp;
          _sftpLoading = false;
        });
      } else {
        // Widget was unmounted mid-open - close the orphaned service.
        await sftp.close();
      }
    } catch (e, stack) {
      if (mounted) {
        // Why, in the app's language, with its report (it said "Failed to
        // initialize SFTP:" and the raw error).
        final said = sftpStartFailure(e);
        setState(() {
          _sftpLoading = false;
          _sftpError = said;
          _sftpReport = ErrorReport.build(what: said, where: 'Opening SFTP', error: e, stack: stack);
        });
      }
    } finally {
      _initInFlight = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    // Restored pane state (remember-last-folder spec), seeded by the launcher
    // before this leaf mounted. A remote folder stored for a different host
    // than this session's is dropped; the local folder is host-independent.
    final restoredRaw = ref.read(sftpPanePathsProvider)[widget.sessionId];
    final sessionConnId = widget.activeSessions
        .where((e) => e.key == widget.sessionId)
        .firstOrNull
        ?.value
        .connectionId;
    final restoredPaths = restoredRaw == null
        ? null
        : (restoredRaw.connectionId == null ||
                restoredRaw.connectionId == sessionConnId
            ? restoredRaw
            : restoredRaw.copyWith(clearRemote: true));

    // Connection label passed to the dual-pane screen as its title. It is the
    // BARE host name (e.g. "Windows"), never "SFTP: Windows" - the source
    // already sits in the SFTP view, so the prefix is noise that eats the room
    // the host name needs in the rail header.
    String sftpLabel = widget.sessionState?.connectionLabel ?? l10n.desktopSftpLabel;
    for (final entry in widget.activeSessions) {
      if (entry.key == widget.sessionId) {
        sftpLabel = entry.value.connectionLabel;
        break;
      }
    }

    // The dock's files: one pane, or two as the dock was set (4.0).
    final twoPanes = ref.watch(sftpDockPrefsProvider.select((p) => p.twoPanes));
    final ValueChanged<bool>? onTwoPanes = widget.docked ? ref.read(sftpDockPrefsProvider.notifier).setTwoPanes : null;
    final Widget? browser = _sftpLoading || _sftpError != null
        ? null
        : _ftps != null
            ? SftpDualPaneScreen(
                ftps: _ftps,
                connectionLabel: sftpLabel,
                initialSessionId: widget.sessionId,
                initialLocalPath: restoredPaths?.localPath,
                embedded: true,
                docked: widget.docked,
                twoPanes: twoPanes,
                onTwoPanes: onTwoPanes,
              )
            : _sftpService != null
                ? SftpDualPaneScreen(
                    sftp: _sftpService!,
                    connectionLabel: sftpLabel,
                    initialSessionId: widget.sessionId,
                    initialRemotePath: restoredPaths?.remotePath,
                    initialLocalPath: restoredPaths?.localPath,
                    embedded: true,
                    docked: widget.docked,
                    twoPanes: twoPanes,
                    onTwoPanes: onTwoPanes,
                  )
                : null;

    // The dock of a session whose connection is down says so, with Reconnect
    // (4.0). It went on showing what it had
    // listed, of a host nothing could be asked of, or, opened again, that
    // SFTP needs an active SSH connection, as a session with none says. The
    // browser stays under it as it was (its folders, its transfers), for
    // when the connection is back.
    final s = widget.sessionState;
    if (widget.docked) {
      final down = s != null && sftpDockConnectionDown(s);
      final off = down
          ? SftpDockDisconnected(
              key: const ValueKey('sftp-dock-disconnected'),
              sessionId: widget.sessionId,
              sessionState: s,
              onOpenSession: widget.onShowSession,
            )
          : null;
      if (browser != null) {
        return IndexedStack(
          index: off == null ? 0 : 1,
          sizing: StackFit.expand,
          // (Under it, the browser takes no keys.)
          children: [ExcludeFocus(excluding: off != null, child: browser), off ?? const SizedBox.shrink()],
        );
      }
      if (off != null) return off;
    } else if (browser != null) {
      return browser;
    }

    // The old per-leaf title bar (folder icon + host pill + close button) was
    // a third copy of the host label the pane's own source picker already
    // shows, so it's gone and the content fills the whole leaf.
    // The leaf is still closed the same way it's opened - the SFTP toggle in
    // the top bar / terminal-tab menu, both of which call
    // paneTreeProvider.closePane(leafId).
    return _sftpLoading
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(
                  color: AppColors.v3AccentPrimary,
                  strokeWidth: 2,
                ),
                // While waiting for the SSH session to finish connecting
                // (e.g. during workspace restore), surface that status so the
                // pane doesn't look stuck.
                if (_waitingForSsh) ...[
                  const SizedBox(height: 12),
                  Text(
                    l10n.desktopTerminalAreaWaitingForSsh,
                    style: TextStyle(
                      color: AppColors.v3TextSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          )
        : _sftpError != null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Red, with Retry and its report, only where opening
                    // failed. Where SFTP cannot be had here (a session that
                    // is no SSH, a Crate that does not allow it) it is said
                    // calmly, and trying again would not change it.
                    Icon(
                      _sftpReport != null ? LucideIcons.alertCircle : LucideIcons.info,
                      color: _sftpReport != null ? AppColors.v3Error : AppColors.v3TextTertiary,
                      size: 28,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _sftpError!,
                      key: const ValueKey('sftp-dock-message'),
                      style: TextStyle(
                        color: AppColors.v3TextSecondary,
                        fontSize: 13,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    if (_sftpReport != null) ...[
                      const SizedBox(height: 12),
                      ZestButton(
                        label: l10n.retry,
                        icon: LucideIcons.refreshCw,
                        variant: ZestButtonVariant.secondary,
                        size: ZestButtonSize.medium,
                        onPressed: _initSftp,
                      ),
                    ],
                    if (_sftpReport != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 520),
                          child: ErrorDetailsPanel(report: _sftpReport!),
                        ),
                      ),
                  ],
                ),
              )
            : const SizedBox.shrink();
  }
}

// ══════════════════════════════════════════════════════════════════
// Terminal Pane (single terminal view)
// ══════════════════════════════════════════════════════════════════

class _TerminalPane extends ConsumerStatefulWidget {
  final String sessionId;
  final SessionState sessionState;

  final List<MapEntry<String, SessionState>> allSessions;
  /// The leaf ID in the pane tree, if rendered inside one.
  final String? leafId;

  /// The terminal in front, which the keyboard goes to: the session shown
  /// in a tab of one, or the one of its pane in focus where a tab is split.
  /// The others are kept behind it (an IndexedStack), out of the keyboard's
  /// reach.
  final bool front;

  /// On screen: the session its tab (or its pane of a split) shows, with or
  /// without the keyboard. A remote screen kept behind another is paused.
  final bool visible;

  const _TerminalPane({
    super.key,
    required this.sessionId,
    required this.sessionState,
    required this.allSessions,
    this.leafId,
    this.front = false,
    this.visible = true,
  });

  @override
  ConsumerState<_TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends ConsumerState<_TerminalPane> {
  /// Owned controller so we can observe selection state for highlight-to-copy.
  final TerminalController _termController = TerminalController();

  /// External FocusNode passed to TerminalView. Owning it here lets us call
  /// `.requestFocus()` directly from `Listener.onPointerDown` - guaranteeing
  /// the terminal grabs focus on the first click, regardless of:
  ///  • whether xterm's TerminalGestureDetector wins the gesture arena, and
  ///  • any parent rebuilds the click might trigger (e.g. focusedPaneProvider
  ///    state change → _TerminalPane rebuild → Container border toggle).
  ///
  /// Without an external node, we relied on xterm's internal _onTapDown to
  /// call requestFocus, which raced with the rebuild cycle - causing the
  /// "click flashes ready-to-type then unfocuses" regression.
  final FocusNode _termFocusNode = FocusNode(debugLabel: 'TerminalPane');

  /// The terminal's view, for Find's bringing a match into view.
  final _viewKey = GlobalKey<TerminalViewState>();

  /// The field of the pane's Find bar: it takes the keyboard again when Find
  /// is asked for where it is open.
  final FocusNode _findFocus = FocusNode(debugLabel: 'TerminalFind');

  /// How often tmux's workspace, where it shows in place of the terminal,
  /// was asked to take the keyboard ([_takeKeyboard]).
  int _tmuxKeyboardAsk = 0;

  @override
  void initState() {
    super.initState();
    // One-shot initial focus, replacing the removed reactive
    // `autofocus: isFocused`: the pane in front when it mounts (a freshly
    // opened or restored session, a tab picked whose panes are new) takes
    // the keyboard once after layout. Only that one: the panes kept behind
    // it in an IndexedStack do not fight for it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeKeyboard());
  }

  @override
  void didUpdateWidget(covariant _TerminalPane old) {
    super.didUpdateWidget(old);
    // Brought to the front (its tab picked): the keyboard comes with it.
    // The one that had it went behind, where it cannot keep it, and a click
    // into the terminal was needed before typing. Or its host has connected, and
    // there is a terminal now to take it.
    if (widget.front && (!old.front || (old.sessionState.session == null && widget.sessionState.session != null))) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _takeKeyboard());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // What lay over the page when its host connected has gone.
    final inFront = ModalRoute.of(context)?.isCurrent ?? true;
    if (_keyboardOwed && inFront) {
      _keyboardOwed = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _takeKeyboard());
    }
  }

  /// The host connected with something open over the page: the keyboard comes
  /// when that has gone.
  bool _keyboardOwed = false;

  /// The keyboard to this terminal while it is the one in front: where tmux
  /// shows in its place, to tmux's pane in front. Not while something is
  /// open over the page (a dialog keeps it), nor away from Find's bar open
  /// here. Nor before its host has connected: a node with nothing to attach to
  /// remembers the request and takes the keyboard the moment it can, past every
  /// check here, from a dialog opened meanwhile (a key typed in Quick connect
  /// reached the host, 30 October 2026).
  bool _tmuxWasLive = false;
  bool _tmuxWasActive = false;

  void _takeKeyboard() {
    if (!mounted || !widget.front || widget.sessionState.session == null) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) {
      _keyboardOwed = true;
      return;
    }
    // (A session that is files only has no terminal to type into. A remote
    // screen's pane takes the keyboard to its picture itself.)
    if (ref.read(activeSessionsProvider.notifier).isFilesOnly(widget.sessionId)) return;
    if (ref.read(activeSessionsProvider.notifier).isScreen(widget.sessionId)) return;
    if (ref.read(terminalFindProvider)?.sessionId == widget.sessionId) return;
    if (ref.read(tmuxHostProvider(widget.sessionId)).active) {
      setState(() => _tmuxKeyboardAsk++);
      return;
    }
    _termFocusNode.requestFocus();
  }

  @override
  void dispose() {
    _termFocusNode.dispose();
    _findFocus.dispose();
    _termController.dispose();
    super.dispose();
  }

  /// Find's bar closed here (its close button, Escape).
  void _closeFind() {
    final find = ref.read(terminalFindProvider.notifier);
    if (find.state?.sessionId == widget.sessionId) find.state = null;
  }

  /// PuTTY-style: when the user finishes a drag-select, copy the selected
  /// text to the clipboard and clear the highlight. Called from a Listener's
  /// onPointerUp so it doesn't interfere with the TerminalView's gesture
  /// arena (which is what was breaking single-click focus). A mouse's
  /// selection only, never at a right click's release ([CopyOnRelease]).
  final _copyOnRelease = CopyOnRelease();

  /// Maps the stored cursor-shape setting to xterm's cursor type. Kept
  /// identical to terminal_screen.dart so the two rendering paths stay
  /// in sync.
  TerminalCursorType _mapCursorType(TerminalCursorShape shape) {
    switch (shape) {
      case TerminalCursorShape.block:
        return TerminalCursorType.block;
      case TerminalCursorShape.underline:
        return TerminalCursorType.underline;
      case TerminalCursorShape.verticalBar:
        return TerminalCursorType.verticalBar;
    }
  }

  void _maybeCopySelection(PointerUpEvent event, Terminal terminal) {
    // Never copy on a right-click release: that is the paste gesture (it
    // runs right after this, on the same release), and copying here would
    // let the paste read back the text we just selected. Nor on a touch's.
    if (!_copyOnRelease.up(event)) return;
    // Copy-on-select is a setting - respect it instead of always copying
    // (this is the provider the settings UI writes to).
    copySelectionIfEnabled(ref, terminal, _termController);
  }

  @override
  Widget build(BuildContext context) {
    final sessionState = widget.sessionState;
    final sessionId = widget.sessionId;
    final leafId = widget.leafId;
    // Connected, and dropped, said to a screen reader: the pane in front.
    listenSessionChanges(ref, context, sessionId, speaks: () => widget.front && widget.visible);

    if (sessionState.session == null) {
      // A session whose connection dropped: why, the tries of connecting
      // again, Reconnect and the details, in its own place.
      if (sessionState.status == SessionStatus.disconnected) {
        return ConnectionLostView(sessionId: sessionId, sessionState: sessionState);
      }
      return _ConnectingView(sessionState: sessionState, sessionId: sessionId);
    }

    // A remote screen (4.0): its picture and its toolbar fill the pane, with
    // no terminal. It takes the keyboard itself, and is paused while it is
    // not on screen.
    if (ref.read(activeSessionsProvider.notifier).isScreen(sessionId)) {
      return ScreenPane(
        key: ValueKey('screen-pane-$sessionId'),
        sessionId: sessionId,
        sessionState: sessionState,
        leafId: leafId,
        front: widget.front,
        visible: widget.visible,
      );
    }

    // A session that is files only (an SFTP-only host): its files fill the
    // pane, and there is no terminal. Its browser keeps one key while the
    // session is there, so it survives its tab being split or joined.
    if (ref.read(activeSessionsProvider.notifier).isFilesOnly(sessionId)) {
      _filesOnlyKeys.removeWhere((id, _) => !widget.allSessions.any((e) => e.key == id));
      return _SftpLeafPane(
        key: _filesOnlyKeys.putIfAbsent(sessionId, GlobalKey.new),
        sessionId: sessionId,
        leafId: 'files-$sessionId',
        activeSessions: widget.allSessions,
      );
    }

    final terminal = sessionState.session!.terminal;
    // A phone's or a tablet's large screen (4.0): the on-screen keyboard and
    // the row of keys.
    final onTouch = isTouchLayout;
    // The host's own theme where it has one, else the app's.
    final theme = ref.watch(hostTerminalThemeProvider(sessionState.connectionId));
    final style = ref.watch(terminalStyleProvider);
    // Respect the user's cursor-shape and terminal-margin settings - the
    // desktop pane previously hardcoded block cursor and 4px padding,
    // ignoring both (they were only honoured on mobile).
    final cursorType = _mapCursorType(ref.watch(cursorStyleProvider));
    final cursorBlink = ref.watch(cursorBlinkProvider);
    final cursorShown = ref.watch(cursorVisibilityProvider);
    final terminalMargin = ref.watch(terminalMarginProvider);
    // tmux mode: the tab keeps its chrome (info bar, borders) and swaps the
    // terminal for the tmux workspace. Its panes own keyboard focus then, so
    // the main terminal's focus node must not steal it back.
    final tmuxHost = ref.watch(tmuxHostProvider(sessionId));
    final tmuxActive = tmuxHost.active;
    // tmux's panes just came up in this pane's place: the terminal that had
    // the keyboard is gone, so the workspace is asked to take it, a frame
    // after it is built (a tablet in the computer layout also opens its
    // keyboard's connection with it, without which a keyboard's letters
    // went nowhere).
    final tmuxLive = tmuxHost.live;
    if (tmuxLive && !_tmuxWasLive && widget.front) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _tmuxKeyboardAsk++);
      });
    }
    _tmuxWasLive = tmuxLive;
    // And back: tmux's panes went (detached, closed, ended) and the terminal
    // is on the screen again in their place. It takes the keyboard, which
    // went with the panes: nothing typed arrived until a tap (seen on a
    // tablet with a keyboard, 21 November 2026).
    if (!tmuxActive && _tmuxWasActive && widget.front) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _takeKeyboard();
      });
    }
    _tmuxWasActive = tmuxActive;
    // Find in terminal (the shell's shortcut, menu or palette), opened for
    // this session: its bar above the terminal, or above tmux's panes for
    // the one in front.
    final find = ref.watch(terminalFindProvider);
    // Copy and paste by the keys Settings binds them to (terminalKeys).
    final keys = ref.watch(shortcutBindingsProvider);
    final findHere = find?.sessionId == sessionId;
    // A tab picked (its pill, a key): the terminal in front takes the
    // keyboard, the tab in front already too.
    ref.listen(terminalKeyboardAskProvider, (_, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _takeKeyboard());
    });
    ref.listen(terminalFindProvider, (was, now) {
      if (tmuxActive) return; // tmux's workspace has the keyboard there
      final closedHere = was?.sessionId == sessionId && now == null;
      // Under a dialog the keyboard is the dialog's: it comes when that has gone.
      if (!(ModalRoute.of(context)?.isCurrent ?? true)) {
        if (closedHere) _keyboardOwed = true;
        return;
      }
      if (was?.sessionId == sessionId && now?.sessionId == sessionId && was!.ask != now!.ask) {
        _findFocus.requestFocus();
      } else if (closedHere) {
        // Closed here: the keyboard back to the terminal.
        _termFocusNode.requestFocus();
      }
    });

    final pane = Listener(
      onPointerDown: (_) {
        // Grab keyboard focus SYNCHRONOUSLY. Focusing the node doesn't
        // rebuild this pane (the focus border tracks focusedPaneProvider,
        // not the FocusNode), so it can't interrupt an in-flight gesture -
        // typing works on the very first click.
        if (!tmuxActive) _termFocusNode.requestFocus();

        // DEFER the provider writes to the next frame. Done synchronously
        // here they rebuild the pane mid-pointer-down (focus border +
        // active-session pointer), which used to (a) eat the first click's
        // focus → forcing a second click to type, and (b) interrupt
        // drag-to-select in split layouts (the rebuild reset xterm's pan
        // recognizer). One frame later the gesture has already been
        // claimed by the terminal, so neither happens. The ~16ms border
        // delay is imperceptible.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (leafId != null &&
              ref.read(focusedPaneProvider) != leafId) {
            ref.read(focusedPaneProvider.notifier).state = leafId;
          }
          // Keep the v3 active-session pointer in sync with which pane the
          // user last clicked into. Without this, opening SFTP from inside
          // a group tab always targets the group's first session instead
          // of the focused pane.
          if (ref.read(v3ActiveSessionTabProvider) != sessionId) {
            ref.read(v3ActiveSessionTabProvider.notifier).state = sessionId;
          }
          // Re-assert focus AFTER the focusedPaneProvider rebuild settles.
          // In split mode the rebuild flips the previously-focused pane's
          // state and could momentarily reclaim focus; requesting again
          // here (this callback only runs for the pane the user actually
          // clicked, which is always the visible one) makes the click
          // stick instead of flickering focused-then-unfocused. Safe: this
          // pane already grabbed focus synchronously above; this just
          // confirms it.
          if (!tmuxActive) _termFocusNode.requestFocus();
        });
      },
      // No box around the pane: the one in front and the ones a broadcast
      // types into are said by the rail along their header (SlimPaneHeader).
      child: Column(
          children: [
            // Terminal view with drag & drop. The Session Details panel is
            // NO LONGER docked per-pane here - a single instance lives at the
            // terminal-area level and follows the focused pane (see
            // DesktopTerminalArea.build). That removes the duplicate ~⅓-width
            // panel each split pane used to render.
            Expanded(
              // A built-in Mosh session's "last contact" while its host is
              // quiet (4.0), over the terminal's top right corner.
              child: Stack(
                fit: StackFit.expand,
                children: [
              tmuxActive
                  ? TmuxSessionView(
                      host: tmuxHost,
                      onLeave: tmuxHost.stop,
                      findOpen: findHere,
                      findAsk: findHere ? find!.ask : 0,
                      onFindClose: _closeFind,
                      keyboardAsk: _tmuxKeyboardAsk,
                    )
                  : DesktopDropTarget(
                      onFilesDropped: (paths) {
                        // (Only what is on show hears of it, _droppedHere: a
                        // pane of a split without the keyboard is on show.)
                        if (ref.read(supportHubOpenProvider)) return;
                        typeDroppedPaths(context, terminal, paths);
                      },
                      onTextDropped: (text) {
                        // Security: strip control characters (escape
                        // sequences, BEL, etc.) from dropped text to
                        // prevent terminal injection attacks. This
                        // mirrors the mobile voice-input sanitization.
                        final sanitized = CommandText.withoutControlCharacters(text);
                        if (sanitized.isNotEmpty) {
                          terminal.textInput(sanitized);
                        }
                      },
                      // PuTTY-style: copy on highlight. Listener.onPointerUp
                      // doesn't compete in the gesture arena, so the
                      // TerminalView's own tap handling (focus, selection)
                      // still works correctly.
                      child: Listener(
                        onPointerDown: _copyOnRelease.down,
                        onPointerUp: (e) => _maybeCopySelection(e, terminal),
                        // To a screen reader: one node with the session's
                        // name, its new lines read out (the pane in front
                        // only), and Read the screen (4.0 accessibility).
                        child: TerminalReadAloud(
                          terminal: terminal,
                          name: sessionState.connectionLabel,
                          speaks: widget.front && widget.visible,
                          onActivate: () {
                            _termFocusNode.requestFocus();
                            if (onTouch) _viewKey.currentState?.requestKeyboard();
                          },
                          child: TriggerHighlightBinder(
                          terminal: terminal,
                          controller: _termController,
                          connectionId: sessionState.connectionId,
                          child: TerminalView(
                          terminal,
                          key: _viewKey,
                          controller: _termController,
                          focusNode: _termFocusNode,
                          theme: theme,
                          textStyle: style,
                          padding: EdgeInsets.all(terminalMargin),
                          // NEVER reactively autofocus on `isFocused`.
                          // `isFocused` tracks focusedPaneProvider, which we
                          // update one frame after a click - so for that
                          // frame the PREVIOUSLY-focused pane still had
                          // autofocus:true and would reclaim the keyboard,
                          // causing the "focused for half a second then
                          // unfocused, can type one letter" bug in split
                          // mode. Focus is now driven explicitly:
                          // requestFocus on click (onPointerDown) and a
                          // one-shot initial grab in initState.
                          autofocus: false,
                          cursorType: cursorType,
                          cursorBlink: cursorBlink,
                          // A program that hides the cursor (ESC [ ? 25 l,
                          // as full-screen programs do while they draw) is
                          // obeyed: it was drawn whatever it asked.
                          alwaysShowCursor: false,
                          hideCursor: cursorShown == TerminalCursorVisibility.never,
                          hideCursorWhileOutput: cursorShown == TerminalCursorVisibility.notDuringOutput,
                          // On a phone's or a tablet's large screen (4.0) a
                          // tap brings up the on-screen keyboard, as the
                          // phone's terminal: a computer's takes only its
                          // keyboard's keys.
                          hardwareKeyboardOnly: !onTouch,
                          deleteDetection: onTouch,
                          keyboardType: onTouch && ref.watch(compactKeyboardProvider)
                              ? TextInputType.visiblePassword
                              : TextInputType.text,
                          personalizedLearning: !(onTouch && ref.watch(keyboardIncognitoProvider)),
                          // While a hardware keyboard is typed on, a tap
                          // gives the terminal its input and no on-screen
                          // keyboard.
                          keyboardOnTap: !onTouch || ref.watch(hardwareKeyboardUseProvider).keyboardOnTap,
                          onKeyboardInput: onTouch ? () => ref.read(hardwareKeyboardUseProvider.notifier).softText() : null,
                          // What the on-screen keyboard commits from its
                          // clipboard is a paste, with the questions every
                          // other paste has (lines that would run, a
                          // command that looks dangerous).
                          onKeyboardPaste: (text) => pasteTextIntoTerminal(context, ref, terminal, text),
                          // Option as Meta on a Mac where Settings turns it
                          // on (off until then); Alt is Meta elsewhere.
                          altIsMeta: ref.watch(optionAsMetaProvider),
                          enableUrlDetection: true,
                          // A terminal's own keys (terminalKeys): the
                          // plain Ctrl chords reach the shell as bytes
                          // (Ctrl+A home, Ctrl+E end, Ctrl+K, Ctrl+U,
                          // Ctrl+W, Ctrl+R...), copy, paste and select all
                          // are Ctrl+Shift (Cmd too on a Mac), and a paste
                          // by them is asked about where it looks
                          // dangerous.
                          shortcuts: terminalKeys(
                            paste: () => pasteClipboardIntoTerminal(context, ref, terminal),
                            bindings: keys,
                            selected: () => _termController.selection != null,
                          ),
                          onUrlTap: (url) => _openTerminalUrl(context, url),
                          // At the RELEASE of the button, which is a
                          // click, never at the press: a remote desktop
                          // sends what was copied on the other computer
                          // when its window is clicked into, with the
                          // click, so at the press the clipboard still held
                          // the one before (in 2.2.1 it pasted
                          // an older copy). A press that is dragged away
                          // pastes nothing.
                          onSecondaryTapUp: (details, offset) {
                            // Right-click paste is gated by the setting.
                            if (!ref.read(desktopRightClickPasteProvider)) {
                              return;
                            }
                            // Right-click on desktop = paste clipboard
                            // contents directly. Each \n in the clipboard
                            // executes its line as Enter; the last line
                            // is left at the prompt without an auto-Enter
                            // so the user can edit / confirm before
                            // running it.
                            //
                            // Mobile long-press still surfaces the full
                            // context menu (handled in
                            // terminal_screen.dart).
                            _quickPasteFromClipboard(context, terminal);
                          },
                          // X11-style middle-click paste, gated by its own
                          // setting; at the release too, and once (it used
                          // to paste at the press, and a second time as a
                          // right click).
                          onTertiaryTapUp: (details, offset) {
                            if (!ref.read(desktopMiddleClickPasteProvider)) {
                              return;
                            }
                            _quickPasteFromClipboard(context, terminal);
                          },
                        ),
                        ),
                        ),
                      ),
                    ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: IgnorePointer(child: MoshContactMark(shell: sessionState.session?.shell)),
                  ),
                ],
              ),
            ),
            // The row of keys a touch keyboard lacks (Esc, Ctrl, Tab, the
            // arrows), under the terminal in front, as the phone's terminal
            // has it, where Settings shows it.
            if (onTouch && widget.front && !tmuxActive)
              PaneKeysRow(
                sessionId: sessionId,
                sessionState: sessionState,
                terminal: terminal,
                onShowKeyboard: () {
                  ref.read(hardwareKeyboardUseProvider.notifier).wantSoftKeyboard();
                  _viewKey.currentState?.requestKeyboard();
                },
              ),
          ],
        ),
    );
    if (!findHere || tmuxActive) return pane;
    // Above the pane, out of its pointer listener: a click into the field
    // must not hand the keyboard to the terminal.
    return Column(
      children: [
        TerminalSearchBar(
          terminal: terminal,
          controller: _termController,
          theme: theme,
          focusNode: _findFocus,
          onShowLine: (line) => _viewKey.currentState?.scrollToLine(line),
          onClose: _closeFind,
        ),
        Expanded(child: pane),
      ],
    );
  }

  /// Allowed URL schemes that may be opened from terminal output.
  /// Blocks javascript:, data:, file:, blob:, vbscript:, and any other
  /// scheme that could execute code or access local resources.
  static const _allowedUrlSchemes = {'http', 'https', 'ssh', 'sftp', 'ftp'};

  Future<void> _openTerminalUrl(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    // Security: only allow safe URL schemes from terminal output.
    // A malicious remote server could emit javascript:, data:, or file: URIs
    // to exploit the local system when clicked.
    if (!_allowedUrlSchemes.contains(uri.scheme.toLowerCase())) {
      return;
    }

    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.neutral,
      title: l10n.desktopTerminalAreaOpenUrlTitle,
      // (Shown as it is: a direction override in it drew it as another address.)
      body: l10n.desktopTerminalAreaUrlDetectedBody(withHiddenCharactersShown(url)),
      confirmLabel: l10n.desktopTerminalAreaOpen,
    );

    if (confirmed == true) {
      launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Right-click "quick paste" - PuTTY-style.
  ///
  /// Reads the clipboard and hands it to xterm's `paste()` which uses
  /// bracketed-paste mode whenever the remote shell supports it (bash,
  /// zsh, fish all enable it by default for interactive sessions).
  /// In bracketed-paste mode the shell sees the entire blob as one
  /// piece of input - multi-line text shows at the prompt with `>`
  /// continuation lines, and a SINGLE Enter from the user sends the
  /// whole thing.  Nothing auto-executes.
  ///
  /// We deliberately skip the multi-line confirm dialog that the
  /// menu's `_pasteToTerminal` shows - right-click is opt-in already
  /// so doubling up is friction.  The dangerous-command guard still
  /// runs and respects the user's setting.
  Future<void> _quickPasteFromClipboard(
    BuildContext context,
    Terminal terminal,
  ) =>
      pasteClipboardIntoTerminal(context, ref, terminal);

  // NOTE: the old `_showTerminalContextMenu` was removed in favour
  // of right-click → quick paste (see [_quickPasteFromClipboard]).
  // Every action it used to expose now lives in the tab right-click
  // menu (Copy Session Output / Save Transcript / Toggle Recording
  // / Clear / View Recording) which is the more discoverable home
  // for session-level commands.
}

class _ConnectingView extends ConsumerWidget {
  final SessionState sessionState;
  final String sessionId;

  const _ConnectingView({required this.sessionState, required this.sessionId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      color: AppColors.v3Background,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.v3AccentPrimary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              AppLocalizations.of(context)!.desktopConnectingTo(
                  Redactable.host(sessionState.connectionLabel)
                      .displayIn(ref)),
              style: TextStyle(
                fontSize: 14,
                color: AppColors.v3TextSecondary,
              ),
            ),
            // A session to a watched Crate's host waits here for someone
            // to watch it (3.0).
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: WatchWaitingPanel(sessionId: sessionId),
            ),
            const SizedBox(height: 12),
            // Connection log. Recording mode: a line names the host, the
            // user or both (`Preparing connection to 10.50.0.5:22`,
            // `Authenticating as demo`), so each goes through the
            // connection-line mask.
            ...sessionState.connectionLog.reversed.take(5).toList().reversed.map(
                  (log) => Text(
                    maskConnectionLine(log,
                        host: sessionState.host,
                        username: sessionState.username),
                    style: TextStyle(
                      fontSize: 10,
                      fontFamily: 'JetBrainsMono',
                      color: AppColors.v3TextSecondary,
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

/// The empty pane of a split, for its tests.
@visibleForTesting
Widget emptyPaneForTesting(String leafId) => _PlaceholderPane(leafId: leafId, onConnectTo: (_) {});
