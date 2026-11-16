import 'dart:io';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/os_kind.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/desktop_dimensions.dart';
import 'package:zestssh/ui/desktop/tab_drag_controller.dart';
import 'package:zestssh/ui/widgets/kbd.dart';
import 'package:zestssh/ui/widgets/os_icon.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';

/// Enhanced desktop terminal tab bar.
///
/// Features:
/// - Status dots (green=connected, yellow=connecting, red=disconnected)
/// - Right-click context menu (Duplicate, Close, Close Others)
/// - Middle-click to close
/// - Recording indicator (red dot)
/// - Broadcast indicator (orange border)
/// - Activity indicator for background tabs
/// - Pin tabs
/// - Drag to reorder
class TerminalTabBar extends StatefulWidget {
  final List<TerminalTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onTabSelected;
  final ValueChanged<int> onTabClosed;
  final VoidCallback onNewTab;
  final void Function(int index, String action)? onTabAction;
  final bool broadcastMode;

  /// Compact mode - reduced height for when 3+ panes are stacked.
  final bool compact;

  /// Called when a tab is dragged out of the window or the user selects
  /// "Detach to New Window" from the context menu.
  final void Function(int index, Offset globalPosition)? onTabDetach;

  /// Called when tabs are reordered by drag. Receives the old and new index.
  final void Function(int oldIndex, int newIndex)? onTabReorder;

  const TerminalTabBar({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onTabSelected,
    required this.onTabClosed,
    required this.onNewTab,
    this.onTabAction,
    this.broadcastMode = false,
    this.compact = false,
    this.onTabDetach,
    this.onTabReorder,
  });

  @override
  State<TerminalTabBar> createState() => _TerminalTabBarState();
}

class _TerminalTabBarState extends State<TerminalTabBar> {
  /// Key for the scrollable tab row, used by [TabDragController] on Windows
  /// to compute the tab bar's screen-space rectangle for detach detection.
  final GlobalKey _tabBarRowKey = GlobalKey();

  /// Windows-only drag controller that uses raw pointer events via [Listener]
  /// to detect vertical drags beyond the tab bar for instant tear-off.
  /// On other platforms, [LongPressDraggable] is used instead.
  TabDragController? _dragController;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows && widget.onTabDetach != null) {
      _initDragController();
    }
  }

  @override
  void didUpdateWidget(TerminalTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (Platform.isWindows) {
      if (widget.onTabDetach != null && _dragController == null) {
        _initDragController();
      } else if (widget.onTabDetach == null && _dragController != null) {
        _dragController!.dispose();
        _dragController = null;
      }
    }
  }

  void _initDragController() {
    _dragController = TabDragController(
      onDetach: (tabIndex, screenPosition) {
        widget.onTabDetach?.call(tabIndex, screenPosition);
      },
      onDragEnd: () {
        if (mounted) setState(() {});
      },
    );
    _dragController!.setTabBarKey(_tabBarRowKey);
  }

  @override
  void dispose() {
    _dragController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final barHeight = widget.compact
        ? DesktopDimensions.tabBarCompactHeight
        : DesktopDimensions.tabBarHeight;
    return Container(
      height: barHeight,
      decoration: BoxDecoration(
        color: AppColors.surfaceDark,
        border: Border(
          bottom: BorderSide(
            color: widget.broadcastMode
                ? AppColors.brandOrange.withValues(alpha: 0.6)
                : AppColors.divider,
            width: widget.broadcastMode ? 2 : 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          // Broadcast indicator
          if (widget.broadcastMode)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Tooltip(
                message: l10n.terminalTabBarBroadcastTooltip,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.radioTower,
                        size: 14, color: AppColors.accentInk),
                    const SizedBox(width: 4),
                    Text(
                      l10n.terminalTabBarBroadcast,
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: AppColors.accentInk,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Scrollable tabs with overflow indicator
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final hasOverflow =
                    widget.tabs.length * DesktopDimensions.tabMinWidth >
                        constraints.maxWidth;

                // Use ListView + LongPressDraggable/DragTarget so that
                // the same drag gesture works for both tab reorder AND
                // snap-zone drops in the terminal area.
                Widget tabListView = ListView.builder(
                  key: _tabBarRowKey,
                  scrollDirection: Axis.horizontal,
                  itemCount: widget.tabs.length,
                  itemBuilder: (context, index) {
                    final tab = widget.tabs[index];
                    final isSelected = index == widget.selectedIndex;

                    return _DraggableTab(
                      key: ValueKey(tab.id),
                      index: index,
                      tab: tab,
                      isSelected: isSelected,
                      onTap: () => widget.onTabSelected(index),
                      onClose: () => widget.onTabClosed(index),
                      onMiddleClick: () => widget.onTabClosed(index),
                      onAction: widget.onTabAction != null
                          ? (action) =>
                              widget.onTabAction!(index, action)
                          : null,
                      broadcastMode: widget.broadcastMode,
                      onDetach: widget.onTabDetach != null
                          ? (globalPos) =>
                              widget.onTabDetach!(index, globalPos)
                          : null,
                      onReorderWith: widget.onTabReorder != null
                          ? (fromIndex) {
                              if (fromIndex != index) {
                                widget.onTabReorder!(fromIndex, index);
                              }
                            }
                          : null,
                    );
                  },
                );

                return Row(
                  children: [
                    Expanded(child: tabListView),
                    if (hasOverflow)
                      _TabOverflowButton(
                        tabs: widget.tabs,
                        selectedIndex: widget.selectedIndex,
                        onTabSelected: widget.onTabSelected,
                      ),
                  ],
                );
              },
            ),
          ),

          // New tab button
          _NewTabButton(onTap: widget.onNewTab),
        ],
      ),
    );
  }
}

/// Wraps a tab widget and adds tear-off drag support.
///
/// Uses [LongPressDraggable] so that short clicks select the tab and
/// short drags reorder (handled by [ReorderableDragStartListener] above),
/// while a long-press-drag initiates a tear-off. When the long-press
/// drag ends outside any [DragTarget], [onDetach] fires to open a new window.
class _DraggableTab extends StatelessWidget {
  final int index;
  final TerminalTab tab;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final VoidCallback onMiddleClick;
  final void Function(String action)? onAction;
  final bool broadcastMode;
  final void Function(Offset globalPosition)? onDetach;
  final void Function(int fromIndex)? onReorderWith;

  const _DraggableTab({
    super.key,
    required this.index,
    required this.tab,
    required this.isSelected,
    required this.onTap,
    required this.onClose,
    required this.onMiddleClick,
    this.onAction,
    this.broadcastMode = false,
    this.onDetach,
    this.onReorderWith,
  });

  @override
  Widget build(BuildContext context) {
    final tabWidget = _TabWidget(
      tab: tab,
      isSelected: isSelected,
      index: index,
      onTap: onTap,
      onClose: onClose,
      onMiddleClick: onMiddleClick,
      onAction: onAction,
      broadcastMode: broadcastMode,
      onDetach: onDetach,
    );

    // DragTarget accepts drops from OTHER tabs for reorder
    Widget child = tabWidget;
    if (onReorderWith != null) {
      child = DragTarget<TabDragData>(
        onWillAcceptWithDetails: (details) =>
            details.data.tabId != tab.id,
        onAcceptWithDetails: (details) =>
            onReorderWith!(details.data.index),
        builder: (context, candidateData, rejectedData) {
          if (candidateData.isNotEmpty) {
            return Container(
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: AppColors.brandOrange.withValues(alpha: 0.8),
                    width: 2,
                  ),
                ),
              ),
              child: tabWidget,
            );
          }
          return tabWidget;
        },
      );
    }

    // LongPressDraggable lets this tab be dragged for reorder or snap-zone split
    return LongPressDraggable<TabDragData>(
      data: TabDragData(index: index, tabId: tab.id, sessionId: tab.id),
      delay: const Duration(milliseconds: 150),
      feedback: Material(
        color: Colors.transparent,
        elevation: 8,
        child: Opacity(
          opacity: 0.85,
          child: Container(
            constraints: const BoxConstraints(minWidth: DesktopDimensions.tabMinWidth, maxWidth: DesktopDimensions.tabMaxWidth),
            height: DesktopDimensions.tabBarHeight,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: AppColors.brandOrange.withValues(alpha: 0.6),
                width: 1.5,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.externalLink,
                    size: 12, color: AppColors.accentInk),
                const SizedBox(width: 6),
                Flexible(
                  child: RedactedText(
                    Redactable.host(tab.label),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: DesktopDimensions.tabFontSize,
                      color: AppColors.onSurface,
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
      childWhenDragging: Opacity(
        opacity: 0.3,
        child: tabWidget,
      ),
      onDragEnd: (details) {
        if (!details.wasAccepted) {
          onDetach?.call(details.offset);
        }
      },
      child: child,
    );
  }
}

/// Data carried during a tab drag operation (reorder, split, or tear-off).
///
/// Public so that [PaneTreeView] can use it as a [DragTarget] type
/// for drag-to-split drop zones.
class TabDragData {
  final int index;
  final String tabId;

  /// The session ID of the dragged tab (for creating splits).
  final String? sessionId;

  const TabDragData({
    required this.index,
    required this.tabId,
    this.sessionId,
  });
}

class _TabWidget extends StatefulWidget {
  final TerminalTab tab;
  final bool isSelected;
  final int index;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final VoidCallback onMiddleClick;
  final void Function(String action)? onAction;
  final bool broadcastMode;
  final void Function(Offset globalPosition)? onDetach;

  const _TabWidget({
    required this.tab,
    required this.isSelected,
    required this.index,
    required this.onTap,
    required this.onClose,
    required this.onMiddleClick,
    this.onAction,
    this.broadcastMode = false,
    this.onDetach,
  });

  @override
  State<_TabWidget> createState() => _TabWidgetState();
}

class _TabWidgetState extends State<_TabWidget> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tab = widget.tab;

    // Status dot color
    Color statusColor;
    switch (tab.status) {
      case TabStatus.connected:
        statusColor = AppColors.success;
      case TabStatus.connecting:
        statusColor = AppColors.warning;
      case TabStatus.disconnected:
        statusColor = AppColors.error;
    }

    final String statusLabel;
    switch (tab.status) {
      case TabStatus.connected:
        statusLabel = l10n.terminalTabBarStatusConnected;
      case TabStatus.connecting:
        statusLabel = l10n.terminalTabBarStatusConnecting;
      case TabStatus.disconnected:
        statusLabel = l10n.terminalTabBarStatusDisconnected;
    }

    // The label is a host name. It is masked HERE (the widget that paints
    // it) so every producer of a [TerminalTab] is covered; a label a caller
    // already masked comes through unchanged (the name rule is idempotent).
    return Semantics(
      label: l10n.terminalTabBarSemanticLabel(
          Redactable.host(tab.label).display, statusLabel),
      selected: widget.isSelected,
      child: MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Listener(
        // Middle-click to close
        onPointerDown: (event) {
          if (event.buttons == kMiddleMouseButton) {
            widget.onMiddleClick();
          }
        },
        child: GestureDetector(
          onTap: widget.onTap,
          onSecondaryTapDown: (details) {
            _showContextMenu(context, details.globalPosition);
          },
          child: Container(
            constraints: const BoxConstraints(
              minWidth: DesktopDimensions.tabMinWidth,
              maxWidth: DesktopDimensions.tabMaxWidth,
            ),
            decoration: BoxDecoration(
              color: widget.isSelected
                  ? AppColors.focusOrange.withValues(alpha: 0.15)
                  : (_isHovered
                      ? AppColors.surfaceDark.withValues(alpha: 0.8)
                      : Colors.transparent),
              border: Border(
                left: BorderSide(
                  color: widget.isSelected
                      ? (tab.connectionColor ?? AppColors.focusOrange)
                      : (tab.connectionColor != null
                          ? tab.connectionColor!.withValues(alpha: 0.4)
                          : Colors.transparent),
                  width: 3,
                ),
                right: BorderSide(
                  color: AppColors.divider,
                  width: 0.5,
                ),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                // Pinned indicator
                if (tab.isPinned) ...[
                  Icon(LucideIcons.pin,
                      size: 10, color: AppColors.textSecondary),
                  const SizedBox(width: 4),
                ],

                // Recording indicator
                if (tab.isRecording) ...[
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: AppColors.error,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                ],

                // Connection color dot with status ring
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: tab.connectionColor ?? statusColor,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: statusColor,
                      width: 1.5,
                    ),
                    boxShadow: tab.status == TabStatus.connected
                        ? [
                            BoxShadow(
                              color: statusColor.withValues(alpha: 0.4),
                              blurRadius: 3,
                            ),
                          ]
                        : null,
                  ),
                ),
                const SizedBox(width: 8),

                // OS icon (replaces generic encryption icon when available)
                if (tab.osKind != null && tab.osKind != OsKind.unknown) ...[
                  Tooltip(
                    message: OsIconWidget.labelForOs(tab.osKind!),
                    child: OsIconWidget(kind: tab.osKind!, size: 12),
                  ),
                  const SizedBox(width: 4),
                ] else
                // Encryption indicator
                if (tab.isEncrypted) ...[
                  Tooltip(
                    message: l10n.terminalTabBarEncryptedTooltip,
                    child: Icon(
                      LucideIcons.lock,
                      size: 11,
                      color: widget.isSelected
                          ? AppColors.success
                          : AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 4),
                ],

                // Label
                Expanded(
                  child: RedactedText(
                    Redactable.host(tab.label),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: DesktopDimensions.tabFontSize,
                      color: widget.isSelected
                          ? AppColors.onSurface
                          : AppColors.textSecondary,
                      fontWeight:
                          widget.isSelected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),

                // Activity indicator for background tabs
                if (!widget.isSelected && tab.hasActivity) ...[
                  Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: AppColors.brandOrange,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                ],

                // Close button - always visible.
                // Ctrl+Click disconnects fully; plain click hides.
                const Spacer(),
                Tooltip(
                  message: l10n.terminalTabBarCloseTabTooltip,
                  child: GestureDetector(
                    onTap: () {
                      // Check if Ctrl is held - if so, force-disconnect
                      if (HardwareKeyboard.instance.logicalKeysPressed
                          .contains(LogicalKeyboardKey.controlLeft) ||
                          HardwareKeyboard.instance.logicalKeysPressed
                          .contains(LogicalKeyboardKey.controlRight)) {
                        widget.onAction?.call('force_close');
                      } else {
                        widget.onClose();
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        LucideIcons.x,
                        size: 14,
                        color: _isHovered
                            ? AppColors.onSurface
                            : AppColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
    );
  }

  void _showContextMenu(BuildContext context, Offset position) {
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
          value: 'duplicate',
          child: _ContextMenuItem(
            icon: LucideIcons.copy,
            label: l10n.terminalTabBarDuplicateSession,
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'toggle_recording',
          child: _ContextMenuItem(
            icon: widget.tab.isRecording ? LucideIcons.square : LucideIcons.circle,
            label: widget.tab.isRecording
                ? l10n.terminalTabBarStopRecording
                : l10n.terminalTabBarStartRecording,
            iconColor: widget.tab.isRecording ? AppColors.error : null,
          ),
        ),
        if (widget.tab.isRecording)
          PopupMenuItem(
            value: 'view_recording',
            child: _ContextMenuItem(
              icon: LucideIcons.rotateCcw,
              label: l10n.terminalTabBarViewRecording,
            ),
          ),
        PopupMenuItem(
          value: widget.tab.isPinned ? 'unpin' : 'pin',
          child: _ContextMenuItem(
            icon: widget.tab.isPinned ? LucideIcons.pin : LucideIcons.pin,
            label: widget.tab.isPinned
                ? l10n.terminalTabBarUnpinTab
                : l10n.terminalTabBarPinTab,
          ),
        ),
        PopupMenuItem(
          value: 'toggle_sftp',
          child: _ContextMenuItem(
            icon: LucideIcons.folderOpen,
            label: l10n.terminalTabBarToggleSftpPanel,
            shortcut: 'Ctrl+Shift+S',
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'copy_session',
          child: _ContextMenuItem(
            icon: LucideIcons.copy,
            label: l10n.terminalTabBarCopySessionOutput,
          ),
        ),
        PopupMenuItem(
          // Live transcript export - writes the running buffer to a
          // file even if the user never hit "Start Recording".
          // Recording-mode export still goes via 'view_recording'
          // when a recording is active.
          value: 'save_transcript',
          child: _ContextMenuItem(
            icon: LucideIcons.save,
            label: l10n.terminalTabBarSaveTranscript,
          ),
        ),
        PopupMenuItem(
          value: 'clear',
          child: _ContextMenuItem(
            icon: LucideIcons.listX,
            label: l10n.terminalTabBarClearTerminal,
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'close',
          child: _ContextMenuItem(
            icon: LucideIcons.x,
            label: l10n.close,
            shortcut: 'Ctrl+Shift+W',
          ),
        ),
        PopupMenuItem(
          value: 'close_others',
          child: _ContextMenuItem(
            icon: LucideIcons.minimize2,
            label: l10n.terminalTabBarCloseOthers,
          ),
        ),
        PopupMenuItem(
          value: 'close_all',
          child: _ContextMenuItem(
            icon: LucideIcons.x,
            label: l10n.terminalTabBarCloseAll,
          ),
        ),
      ],
    ).then((value) {
      if (value == 'close') {
        widget.onClose();
      } else if (value != null && widget.onAction != null) {
        widget.onAction!(value);
      }
    });
  }
}

class _ContextMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? shortcut;
  final Color? iconColor;

  const _ContextMenuItem({
    required this.icon,
    required this.label,
    this.shortcut,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: iconColor ?? AppColors.textSecondary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
        if (shortcut != null)
          Kbd(shortcut!),
      ],
    );
  }
}

/// Overflow chevron shown when tabs exceed available width.
/// Clicking it reveals a dropdown of all tabs.
class _TabOverflowButton extends StatefulWidget {
  final List<TerminalTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onTabSelected;

  const _TabOverflowButton({
    required this.tabs,
    required this.selectedIndex,
    required this.onTabSelected,
  });

  @override
  State<_TabOverflowButton> createState() => _TabOverflowButtonState();
}

class _TabOverflowButtonState extends State<_TabOverflowButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: PopupMenuButton<int>(
        tooltip: l10n.terminalTabBarTabsOpen(widget.tabs.length),
        constraints: const BoxConstraints(minWidth: 180, maxWidth: 300),
        color: AppColors.surface,
        itemBuilder: (context) {
          return List.generate(widget.tabs.length, (index) {
            final tab = widget.tabs[index];
            final isSelected = index == widget.selectedIndex;

            Color statusColor;
            switch (tab.status) {
              case TabStatus.connected:
                statusColor = AppColors.success;
              case TabStatus.connecting:
                statusColor = AppColors.warning;
              case TabStatus.disconnected:
                statusColor = AppColors.error;
            }

            return PopupMenuItem<int>(
              value: index,
              child: Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: RedactedText(
                      Redactable.host(tab.label),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: isSelected
                            ? FontWeight.w600
                            : FontWeight.normal,
                        color: isSelected
                            ? AppColors.accentInk
                            : AppColors.onSurface,
                      ),
                    ),
                  ),
                  if (isSelected)
                    Icon(
                      LucideIcons.check,
                      size: 14,
                      color: AppColors.accentInk,
                    ),
                ],
              ),
            );
          });
        },
        onSelected: (index) => widget.onTabSelected(index),
        padding: EdgeInsets.zero,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          decoration: BoxDecoration(
            color: _isHovered
                ? AppColors.surfaceLight.withValues(alpha: 0.3)
                : Colors.transparent,
            border: Border(
              left: BorderSide(color: AppColors.divider, width: 0.5),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                LucideIcons.moreHorizontal,
                size: 16,
                color: _isHovered
                    ? AppColors.accentInk
                    : AppColors.textSecondary,
              ),
              const SizedBox(width: 2),
              Text(
                '${widget.tabs.length}',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: _isHovered
                      ? AppColors.accentInk
                      : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NewTabButton extends StatefulWidget {
  final VoidCallback onTap;

  const _NewTabButton({required this.onTap});

  @override
  State<_NewTabButton> createState() => _NewTabButtonState();
}

class _NewTabButtonState extends State<_NewTabButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _isHovered
                ? AppColors.surfaceLight.withValues(alpha: 0.3)
                : Colors.transparent,
            border: Border(
              left: BorderSide(color: AppColors.divider, width: 0.5),
            ),
          ),
          child: Tooltip(
            message: l10n.terminalTabBarNewConnectionTooltip,
            child: Icon(
              LucideIcons.plus,
              size: 20,
              color: _isHovered
                  ? AppColors.onSurface
                  : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Tab status for visual indicators.
enum TabStatus { connected, connecting, disconnected }

/// Enhanced terminal tab data.
class TerminalTab {
  final String id;
  final String label;
  final TabStatus status;
  final bool isRecording;
  final bool isPinned;
  final bool hasActivity;
  final bool isEncrypted;
  final String? connectionId;
  final Color? connectionColor;

  /// Detected remote OS for this connection (may be null if not detected yet).
  final OsKind? osKind;

  const TerminalTab({
    required this.id,
    required this.label,
    this.status = TabStatus.disconnected,
    this.isRecording = false,
    this.isPinned = false,
    this.hasActivity = false,
    this.isEncrypted = false,
    this.connectionId,
    this.connectionColor,
    this.osKind,
  });

  // Backward compatibility
  bool get isConnected => status == TabStatus.connected;
}
