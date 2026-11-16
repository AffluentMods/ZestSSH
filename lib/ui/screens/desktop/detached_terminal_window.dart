import 'dart:convert';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/providers/os_detection_providers.dart';
import 'package:zestssh/providers/pane_tree_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/multi_window_service.dart';
import 'package:zestssh/services/session_transcript_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/terminal/terminal_screen.dart';
import 'package:zestssh/ui/widgets/pane_tree_view.dart';
import 'package:zestssh/ui/widgets/terminal_tab_bar.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';

/// A standalone terminal window for a detached session.
///
/// Launched by [MultiWindowService.detachSession] in a secondary
/// `desktop_multi_window` window.  Works as a mini version of the
/// main desktop shell with:
/// - A tab bar (even for a single tab)
/// - Split pane support via [PaneTreeView]
/// - Keyboard shortcuts for pane navigation
/// - Right-click context menu with split/layout options
///
/// Does NOT include a sidebar.
class DetachedTerminalWindow extends ConsumerStatefulWidget {
  final String sessionId;
  final String connectionLabel;
  final int windowId;

  /// Optional serialized pane tree from the window payload.
  final Map<String, dynamic>? paneTreeJson;

  const DetachedTerminalWindow({
    super.key,
    required this.sessionId,
    required this.connectionLabel,
    required this.windowId,
    this.paneTreeJson,
  });

  @override
  ConsumerState<DetachedTerminalWindow> createState() =>
      _DetachedTerminalWindowState();
}

class _DetachedTerminalWindowState
    extends ConsumerState<DetachedTerminalWindow> {
  final _focusNode = FocusNode();

  /// Local pane tree for this detached window (independent of main window).
  PaneNode? _localPaneTree;

  /// Saved tree for maximize/restore toggle.
  PaneNode? _savedTree;

  /// Session IDs managed by this detached window (for tab bar).
  /// Starts with the initial sessionId; grows when sessions are accepted.
  final List<String> _localSessionIds = [];

  /// Currently selected tab index within this window.
  int _selectedTab = 0;

  @override
  void initState() {
    super.initState();
    _localSessionIds.add(widget.sessionId);

    // Restore pane tree from payload if provided
    if (widget.paneTreeJson != null) {
      _localPaneTree = PaneNode.fromJson(widget.paneTreeJson!);
    }

    // Listen for incoming session transfers
    MultiWindowService.instance.addAcceptSessionListener(_onAcceptSession);
  }

  @override
  void dispose() {
    MultiWindowService.instance
        .removeAcceptSessionListener(_onAcceptSession);
    _focusNode.dispose();

    // Notify the main window that all sessions should be reattached
    for (final sessionId in _localSessionIds) {
      try {
        DesktopMultiWindow.invokeMethod(
          0, // main window ID
          'requestReattach',
          jsonEncode({'sessionId': sessionId}),
        );
      } catch (e) {
        AppLogger.warning('Failed to notify main window of close: $e');
      }
    }
    super.dispose();
  }

  void _onAcceptSession(String sessionId) {
    if (!mounted) return;
    setState(() {
      if (!_localSessionIds.contains(sessionId)) {
        _localSessionIds.add(sessionId);
        _selectedTab = _localSessionIds.length - 1;
      }
    });
  }

  // ── Pane operations ───────────────────────────────────────────

  void _splitPane(Axis axis) {
    final sessions = ref.read(activeSessionsProvider);
    // Find another active session to put in the second pane
    final available = _localSessionIds
        .where((id) => sessions[id]?.status == SessionStatus.connected ||
            sessions[id]?.status == SessionStatus.connecting)
        .toList();
    if (available.length < 2) return;

    final primaryId = available[_selectedTab.clamp(0, available.length - 1)];
    final secondIndex =
        (_selectedTab + 1).clamp(0, available.length - 1);
    final secondId = available[secondIndex];

    setState(() {
      if (_localPaneTree == null) {
        _localPaneTree = PaneSplit(
          first: PaneLeaf.single(sessionId: primaryId),
          second: PaneLeaf.single(sessionId: secondId),
          axis: axis,
        );
      } else {
        final focusedId = ref.read(focusedPaneProvider);
        final target = focusedId == null ? null : _localPaneTree!.findLeaf(focusedId);
        if (target != null) {
          // The room is shared again, as in the main window: panes side by
          // side are as wide as each other, and a divider someone moved
          // stays where it was put.
          _localPaneTree = rebalancePaneTree(
            replacePaneLeaf(
              _localPaneTree!,
              target.id,
              PaneSplit(first: target, second: PaneLeaf.single(sessionId: secondId), axis: axis),
            ),
            since: _localPaneTree,
          );
        }
      }
    });
  }

  void _closeFocusedPane() {
    final focusedId = ref.read(focusedPaneProvider);
    if (focusedId == null || _localPaneTree == null) return;
    setState(() {
      final left = removePaneLeaf(_localPaneTree!, focusedId);
      _localPaneTree = left == null ? null : rebalancePaneTree(left, since: _localPaneTree);
    });
  }

  void _toggleMaximizePane() {
    final focused = ref.read(focusedPaneProvider);
    if (focused == null) return;

    setState(() {
      if (_savedTree != null) {
        _localPaneTree = _savedTree;
        _savedTree = null;
      } else if (_localPaneTree is PaneSplit) {
        final leaf = _localPaneTree!.findLeaf(focused);
        if (leaf != null) {
          _savedTree = _localPaneTree;
          _localPaneTree =
              PaneLeaf(id: leaf.id, sessionIds: List.of(leaf.sessionIds), activeIndex: leaf.activeIndex, type: leaf.type);
        }
      }
    });
  }

  void _resetLayout() {
    setState(() {
      _localPaneTree = null;
      _savedTree = null;
    });
  }

  void _applyLayoutPreset(int preset) {
    final sessions = ref.read(activeSessionsProvider);
    final available = _localSessionIds
        .where((id) => sessions[id]?.status == SessionStatus.connected ||
            sessions[id]?.status == SessionStatus.connecting)
        .toList();
    if (available.isEmpty) return;

    String sid(int i) => available[i % available.length];

    PaneNode? tree;
    switch (preset) {
      case 1: // Side-by-side
        if (available.length < 2) return;
        tree = PaneSplit(
          first: PaneLeaf.single(sessionId: sid(0)),
          second: PaneLeaf.single(sessionId: sid(1)),
          axis: Axis.horizontal,
        );
      case 2: // Stacked
        if (available.length < 2) return;
        tree = PaneSplit(
          first: PaneLeaf.single(sessionId: sid(0)),
          second: PaneLeaf.single(sessionId: sid(1)),
          axis: Axis.vertical,
        );
      case 4: // 2x2 Grid
        if (available.length < 4) return;
        tree = PaneSplit(
          first: PaneSplit(
            first: PaneLeaf.single(sessionId: sid(0)),
            second: PaneLeaf.single(sessionId: sid(1)),
            axis: Axis.horizontal,
          ),
          second: PaneSplit(
            first: PaneLeaf.single(sessionId: sid(2)),
            second: PaneLeaf.single(sessionId: sid(3)),
            axis: Axis.horizontal,
          ),
          axis: Axis.vertical,
        );
      case 5: // Reset
        tree = null;
    }
    setState(() {
      _localPaneTree = tree;
    });
  }

  // ── Keyboard shortcuts ────────────────────────────────────────

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    final isCtrl = HardwareKeyboard.instance.isControlPressed;
    final isShift = HardwareKeyboard.instance.isShiftPressed;
    final isAlt = HardwareKeyboard.instance.isAltPressed;

    // Ctrl+Shift+D -> Split right
    if (isCtrl && isShift &&
        event.logicalKey == LogicalKeyboardKey.keyD) {
      _splitPane(Axis.horizontal);
      return;
    }

    // Ctrl+Shift+E -> Split down
    if (isCtrl && isShift &&
        event.logicalKey == LogicalKeyboardKey.keyE) {
      _splitPane(Axis.vertical);
      return;
    }

    // Ctrl+\ -> Close split
    if (isCtrl && event.logicalKey == LogicalKeyboardKey.backslash) {
      _closeFocusedPane();
      return;
    }

    // Alt+Arrow keys -> Navigate between panes
    if (isAlt && !isCtrl && !isShift) {
      final direction = switch (event.logicalKey) {
        LogicalKeyboardKey.arrowLeft => AxisDirection.left,
        LogicalKeyboardKey.arrowRight => AxisDirection.right,
        LogicalKeyboardKey.arrowUp => AxisDirection.up,
        LogicalKeyboardKey.arrowDown => AxisDirection.down,
        _ => null,
      };
      if (direction != null) {
        ref.read(paneTreeProvider.notifier).moveFocus(direction);
        return;
      }
    }

    // Ctrl+Shift+M -> Toggle maximize focused pane
    if (isCtrl && isShift &&
        event.logicalKey == LogicalKeyboardKey.keyM) {
      _toggleMaximizePane();
      return;
    }

    // Ctrl+Tab -> Next tab
    if (isCtrl && !isShift &&
        event.logicalKey == LogicalKeyboardKey.tab) {
      _cycleTab(1);
      return;
    }

    // Ctrl+Shift+Tab -> Previous tab
    if (isCtrl && isShift &&
        event.logicalKey == LogicalKeyboardKey.tab) {
      _cycleTab(-1);
      return;
    }

    // Ctrl+Alt+1 -> Side-by-side
    if (isCtrl && isAlt &&
        event.logicalKey == LogicalKeyboardKey.digit1) {
      _applyLayoutPreset(1);
      return;
    }

    // Ctrl+Alt+2 -> Stacked
    if (isCtrl && isAlt &&
        event.logicalKey == LogicalKeyboardKey.digit2) {
      _applyLayoutPreset(2);
      return;
    }

    // Ctrl+Alt+4 -> 2x2 Grid
    if (isCtrl && isAlt &&
        event.logicalKey == LogicalKeyboardKey.digit4) {
      _applyLayoutPreset(4);
      return;
    }

    // Ctrl+Alt+5 -> Reset layout
    if (isCtrl && isAlt &&
        event.logicalKey == LogicalKeyboardKey.digit5) {
      _resetLayout();
      return;
    }

    // Ctrl+Shift+W -> Close current tab. Not bare Ctrl+W: that is a live
    // terminal input (readline delete-word, nano search) and must reach the
    // pty, matching the main window's close-tab default.
    if (isCtrl && isShift &&
        event.logicalKey == LogicalKeyboardKey.keyW) {
      _closeTab(_selectedTab);
      return;
    }
  }

  void _cycleTab(int direction) {
    if (_localSessionIds.length <= 1) return;
    setState(() {
      _selectedTab =
          (_selectedTab + direction) % _localSessionIds.length;
    });
  }

  void _closeTab(int index) {
    if (index < 0 || index >= _localSessionIds.length) return;
    final sessionId = _localSessionIds[index];

    // Notify main window to reattach
    try {
      DesktopMultiWindow.invokeMethod(
        0,
        'requestReattach',
        jsonEncode({'sessionId': sessionId}),
      );
    } catch (e) {
      AppLogger.warning('Failed to request reattach for $sessionId: $e');
    }

    setState(() {
      _localSessionIds.removeAt(index);
      if (_localSessionIds.isEmpty) {
        // Close the window entirely
        WindowController.fromWindowId(widget.windowId).close();
        return;
      }
      if (_selectedTab >= _localSessionIds.length) {
        _selectedTab = _localSessionIds.length - 1;
      }
    });
  }

  void _handleTabAction(int index, String action) {
    switch (action) {
      case 'split_right':
        _splitPane(Axis.horizontal);
      case 'split_down':
        _splitPane(Axis.vertical);
      case 'layout_side_by_side':
        _applyLayoutPreset(1);
      case 'layout_stacked':
        _applyLayoutPreset(2);
      case 'layout_grid':
        _applyLayoutPreset(4);
      case 'layout_reset':
        _resetLayout();
      case 'close':
        _closeTab(index);
      case 'close_others':
        final keep = _localSessionIds[index];
        for (var i = _localSessionIds.length - 1; i >= 0; i--) {
          if (i != index) _closeTab(i);
        }
        setState(() {
          _selectedTab = _localSessionIds.indexOf(keep).clamp(0,
              _localSessionIds.length - 1);
        });
      case 'close_all':
        for (var i = _localSessionIds.length - 1; i >= 0; i--) {
          _closeTab(i);
        }
    }
  }

  // ── Build ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final sessions = ref.watch(activeSessionsProvider);
    final osCache = ref.watch(osDetectionCacheProvider);

    // Build tab list from local session IDs
    final activeTabs = <MapEntry<String, SessionState>>[];
    for (final id in _localSessionIds) {
      final s = sessions[id];
      if (s != null &&
          (s.status == SessionStatus.connected ||
              s.status == SessionStatus.connecting)) {
        activeTabs.add(MapEntry(id, s));
      }
    }

    // If no sessions remain, show disconnected state
    if (activeTabs.isEmpty) {
      return _buildDisconnectedState();
    }

    final clampedTab = _selectedTab.clamp(0, activeTabs.length - 1);
    final currentSessionId = activeTabs[clampedTab].key;

    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: AppColors.v3Background,
        body: Column(
          children: [
            // Tab bar
            TerminalTabBar(
              tabs: activeTabs.map((e) {
                final isRecording =
                    SessionTranscriptService.isRecording(e.key);
                final cIdx = e.value.colorIndex;
                final detachedConnId = e.value.connectionId;
                return TerminalTab(
                  id: e.key,
                  label: Redactable.host(e.value.connectionLabel).displayIn(ref),
                  status: _mapStatus(e.value.status),
                  isRecording: isRecording,
                  isEncrypted: true,
                  connectionId: detachedConnId,
                  connectionColor:
                      AppColors.labelColorFor(e.value.colorValue, cIdx),
                  osKind: detachedConnId != null ? osCache[detachedConnId] : null,
                );
              }).toList(),
              selectedIndex: clampedTab,
              onTabSelected: (index) {
                setState(() => _selectedTab = index);
              },
              onTabClosed: _closeTab,
              onNewTab: () {
                // No-op in detached window - cannot open new connections
              },
              onTabAction: _handleTabAction,
            ),

            // Terminal content
            Expanded(
              child: _localPaneTree != null
                  ? PaneTreeView(
                      node: _localPaneTree!,
                      onRatioChanged: (split, ratio) => setState(() {
                        final tree = _localPaneTree;
                        if (tree != null) _localPaneTree = withSplitRatio(tree, split.id, ratio);
                      }),
                      leafBuilder: (leaf, isFocused) {
                        final entry = activeTabs
                            .where((e) => e.key == leaf.sessionId)
                            .firstOrNull;
                        if (entry == null) {
                          return Center(
                            child: Text(
                              l10n.detachedTerminalWindowSessionNotFound,
                              style: TextStyle(
                                  color: AppColors.v3TextSecondary),
                            ),
                          );
                        }
                        Widget child = RepaintBoundary(
                          child: TerminalScreen(
                              sessionId: entry.key),
                        );
                        // Keep the focus border as a STABLE wrapper (always
                        // present, only its colour toggles). Wrapping/
                        // unwrapping `child` on focus change shifts it in the
                        // element tree and drops in-flight taps - the same
                        // two-click bug fixed in pane_tree_view.dart. A
                        // transparent border when unfocused keeps the element
                        // (and its gesture recognizers) stable with no layout
                        // jump.
                        child = Container(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: isFocused
                                  ? AppColors.brandOrange
                                      .withValues(alpha: 0.5)
                                  : Colors.transparent,
                              width: 1,
                            ),
                          ),
                          child: child,
                        );
                        return child;
                      },
                    )
                  : GestureDetector(
                      onSecondaryTapDown: (details) {
                        _showPaneContextMenu(
                            context, details.globalPosition);
                      },
                      child: TerminalScreen(
                          sessionId: currentSessionId),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDisconnectedState() {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AppColors.v3Background,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.unlink,
                size: 48, color: AppColors.v3TextSecondary),
            const SizedBox(height: 16),
            Text(
              l10n.detachedTerminalWindowSessionDisconnected,
              style: TextStyle(
                color: AppColors.v3TextSecondary,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () =>
                  WindowController.fromWindowId(widget.windowId).close(),
              child: Text(l10n.detachedTerminalWindowCloseWindow),
            ),
          ],
        ),
      ),
    );
  }

  void _showPaneContextMenu(BuildContext context, Offset position) {
    final l10n = AppLocalizations.of(context)!;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        PopupMenuItem(
          value: 'split_right',
          child: Row(
            children: [
              Icon(LucideIcons.columns,
                  size: 16, color: AppColors.v3TextSecondary),
              const SizedBox(width: 10),
              Text(l10n.detachedTerminalWindowSplitRight,
                  style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'split_down',
          child: Row(
            children: [
              Icon(LucideIcons.rows,
                  size: 16, color: AppColors.v3TextSecondary),
              const SizedBox(width: 10),
              Text(l10n.detachedTerminalWindowSplitDown,
                  style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'layout_side_by_side',
          child: Row(
            children: [
              Icon(LucideIcons.columns,
                  size: 16, color: AppColors.v3TextSecondary),
              const SizedBox(width: 10),
              Text(l10n.detachedTerminalWindowSideBySide,
                  style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'layout_stacked',
          child: Row(
            children: [
              Icon(LucideIcons.rows,
                  size: 16, color: AppColors.v3TextSecondary),
              const SizedBox(width: 10),
              Text(l10n.detachedTerminalWindowStacked,
                  style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'layout_grid',
          child: Row(
            children: [
              Icon(LucideIcons.layoutGrid,
                  size: 16, color: AppColors.v3TextSecondary),
              const SizedBox(width: 10),
              Text(l10n.detachedTerminalWindowGrid2x2,
                  style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'layout_reset',
          child: Row(
            children: [
              Icon(LucideIcons.square,
                  size: 16, color: AppColors.v3TextSecondary),
              const SizedBox(width: 10),
              Text(l10n.detachedTerminalWindowResetLayout,
                  style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == null) return;
      switch (value) {
        case 'split_right':
          _splitPane(Axis.horizontal);
        case 'split_down':
          _splitPane(Axis.vertical);
        case 'layout_side_by_side':
          _applyLayoutPreset(1);
        case 'layout_stacked':
          _applyLayoutPreset(2);
        case 'layout_grid':
          _applyLayoutPreset(4);
        case 'layout_reset':
          _resetLayout();
      }
    });
  }

  TabStatus _mapStatus(SessionStatus status) {
    return switch (status) {
      SessionStatus.connected => TabStatus.connected,
      SessionStatus.connecting => TabStatus.connecting,
      _ => TabStatus.disconnected,
    };
  }
}
