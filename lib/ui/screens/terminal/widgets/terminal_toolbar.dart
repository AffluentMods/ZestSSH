
import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:zestssh/utils/foreground_ticker.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/models/os_kind.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/models/redactable.dart';

/// Toolbar at the top of the terminal screen.
///
/// Displays session status, optional duration timer, action buttons,
/// and disconnect control.
class TerminalToolbar extends StatefulWidget {
  final String sessionId;
  final SessionStatus status;
  final VoidCallback onDisconnect;
  final VoidCallback onBack;
  final VoidCallback? onSftp;
  final VoidCallback? onPortForward;
  final VoidCallback? onTmux;
  final VoidCallback? onSnippets;
  final VoidCallback? onSettings;
  final VoidCallback? onSearch;
  final VoidCallback? onReconnect;
  final VoidCallback? onBroadcastConfig;

  /// Optional split-view button widget (shown on desktop/tablets).
  final Widget? splitButton;

  /// Callback for split terminal toggle (used in mobile overflow menu).
  final VoidCallback? onSplit;

  /// The split view's own controls for this pane (its lower or right pane on
  /// a tablet: the session in it, swap, close the split), at the bar's end
  /// before Disconnect, so the pane has one header.
  final Widget? paneControls;

  /// Dynamic terminal title from SSH server (e.g. "user@host:~").
  final String? terminalTitle;

  /// Connection label (e.g. "db-primary").
  final String? connectionLabel;

  /// Server host/IP (e.g. "192.168.10.21"). Shown on mobile toolbar.
  final String? host;

  /// Whether session transcript recording is active.
  final bool isRecording;

  /// Whether auto-reconnect is in progress.
  final bool isReconnecting;

  /// Whether broadcast mode is active.
  final bool isBroadcasting;

  /// Number of sessions being broadcast to.
  final int broadcastTargetCount;

  /// When the session was established - used for duration timer.
  final DateTime? connectedAt;

  /// Whether the terminal is actively receiving data (for pulse animation).
  final bool isReceivingData;

  /// Callback to show session info dialog.
  final VoidCallback? onSessionInfo;

  /// Callback to open the connection editor for the active session.
  /// Used by the "Save connection..." menu item to let the user
  /// promote a quick-connect session into a fully configured saved
  /// connection without leaving the terminal.
  final VoidCallback? onEditConnection;

  /// Detected OS of the remote host.
  final OsKind? detectedOs;

  /// Connection port.
  final int? port;

  /// Connection username.
  final String? username;

  const TerminalToolbar({
    super.key,
    required this.sessionId,
    required this.status,
    required this.onDisconnect,
    required this.onBack,
    this.onSftp,
    this.onPortForward,
    this.onTmux,
    this.onSnippets,
    this.onSettings,
    this.onSearch,
    this.onReconnect,
    this.onBroadcastConfig,
    this.splitButton,
    this.onSplit,
    this.paneControls,
    this.terminalTitle,
    this.connectionLabel,
    this.host,
    this.isRecording = false,
    this.isReconnecting = false,
    this.isBroadcasting = false,
    this.broadcastTargetCount = 0,
    this.connectedAt,
    this.isReceivingData = false,
    this.onSessionInfo,
    this.onEditConnection,
    this.detectedOs,
    this.port,
    this.username,
  });

  @override
  State<TerminalToolbar> createState() => _TerminalToolbarState();
}

class _TerminalToolbarState extends State<TerminalToolbar>
    with SingleTickerProviderStateMixin {
  // ── Pulse animation for status dot ──
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    _pulseAnimation = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant TerminalToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isReceivingData != widget.isReceivingData) {
      _syncPulse();
    }
  }

  /// Start or stop the pulse animation based on data reception state.
  void _syncPulse() {
    if (widget.isReceivingData &&
        widget.status == SessionStatus.connected) {
      if (!_pulseController.isAnimating) {
        _pulseController.repeat(reverse: true);
      }
    } else {
      _pulseController.stop();
      _pulseController.value = 1.0; // Solid when idle
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final showDuration = widget.connectedAt != null &&
        widget.status == SessionStatus.connected;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Container(
      // 48 high where a finger taps it: its buttons are 48 by 48 there (4.0
      // accessibility pass; they were 40 in a bar 44 high, 36 on its side).
      height: isTouchLayout ? 48 : (isLandscape ? 36 : 44),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceDark,
        border: Border(
          bottom: BorderSide(
            color: widget.isBroadcasting
                ? AppColors.brandOrange.withValues(alpha: 0.6)
                : Colors.white.withValues(alpha: 0.06),
            width: widget.isBroadcasting ? 2 : 1,
          ),
        ),
      ),
      child: Row(
        children: [
          // Back button
          Semantics(
            label: l10n.termTbGoBackSemantic,
            button: true,
            // One name for a screen reader: the button's tooltip under it
            // said it a second time.
            excludeSemantics: true,
            onTap: widget.onBack,
            child: IconButton(
              icon: const Icon(LucideIcons.arrowLeft, size: 20),
              onPressed: widget.onBack,
              tooltip: l10n.back,
              visualDensity: _barDensity,
            ),
          ),

          // Status indicator (pulses when receiving data)
          Semantics(
            label: l10n.termTbStatusSemantic(_displayText),
            child: AnimatedBuilder(
              animation: _pulseAnimation,
              builder: (context, child) {
                return Opacity(
                  opacity: widget.isReceivingData &&
                          widget.status == SessionStatus.connected
                      ? _pulseAnimation.value
                      : 1.0,
                  child: child,
                );
              },
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _statusColor,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),

          // Recording indicator
          if (widget.isRecording) ...[
            const SizedBox(width: 6),
            Semantics(
              label: l10n.termTbRecordingSemantic,
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: AppColors.error,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
          const SizedBox(width: 8),

          // Session info - show SSH title on desktop / wide screens only.
          // On narrow phones the status dot alone is sufficient.
          Expanded(
            child: Semantics(
              label: l10n.termTbSessionSemantic(_displayText),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return Row(
                    children: [
                      // Duration timer (left side). Self-contained widget so
                      // its 1s tick rebuilds only the chip, not the whole
                      // toolbar (all the action buttons) every second.
                      // (Where the bar's buttons, 48 to a finger, leave the
                      // name too little room, the timer gives way: its time
                      // is in the session's details too.)
                      if (showDuration && constraints.maxWidth >= 170) ...[
                        _ConnectionDurationChip(
                            connectedAt: widget.connectedAt!),
                        const SizedBox(width: 8),
                      ],
                      // IP / connection info
                      // (Out of a screen reader's way: "Session: web-01"
                      // above says it, and said it twice.)
                      Flexible(
                        child: ExcludeSemantics(
                          child: Text(
                            _displayText,
                            style: const TextStyle(fontSize: 14),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),

          // Action buttons (only when connected)
          if (widget.status == SessionStatus.connected) ...[
            // On desktop, show all action buttons directly in the toolbar.
            // On mobile, collapse them into a single overflow popup menu
            // to prevent row overflow on narrow screens.
            // (isTouchLayout is !isDesktopPlatform in the app; a test draws
            // a phone's bar with it, as a phone has it.)
            if (!isTouchLayout) ...[
              // Split-view button (tablets/desktop only)
              if (widget.splitButton != null) widget.splitButton!,

              // Broadcast button
              if (widget.onBroadcastConfig != null)
                IconButton(
                  icon: Icon(
                    LucideIcons.radioTower,
                    size: 20,
                    color: widget.isBroadcasting
                        ? AppColors.accentInk
                        : null,
                  ),
                  onPressed: widget.onBroadcastConfig,
                  tooltip: widget.isBroadcasting
                      ? l10n.termTbBroadcastingTooltip(
                          widget.broadcastTargetCount)
                      : l10n.termTbBroadcastMode,
                  visualDensity: _barDensity,
                ),

              // Search button
              if (widget.onSearch != null)
                Semantics(
                  label: l10n.termTbFindSemantic,
                  button: true,
                  // One name for a screen reader: the button's tooltip under it
                  // said it a second time.
                  excludeSemantics: true,
                  onTap: widget.onSearch,
                  child: IconButton(
                    icon: const Icon(LucideIcons.search, size: 20),
                    onPressed: widget.onSearch,
                    tooltip: l10n.termTbFind,
                    visualDensity: _barDensity,
                  ),
                ),

              // SFTP button
              if (widget.onSftp != null)
                Semantics(
                  label: l10n.termTbSftpSemantic,
                  button: true,
                  // One name for a screen reader: the button's tooltip under it
                  // said it a second time.
                  excludeSemantics: true,
                  onTap: widget.onSftp,
                  child: IconButton(
                    icon: const Icon(LucideIcons.folderOpen, size: 20),
                    onPressed: widget.onSftp,
                    tooltip: l10n.termTbSftp,
                    visualDensity: _barDensity,
                  ),
                ),

              // Port forward button
              if (widget.onPortForward != null)
                Semantics(
                  label: l10n.termTbPortForwardSemantic,
                  button: true,
                  // One name for a screen reader: the button's tooltip under it
                  // said it a second time.
                  excludeSemantics: true,
                  onTap: widget.onPortForward,
                  child: IconButton(
                    icon: const Icon(LucideIcons.arrowLeftRight, size: 20),
                    onPressed: widget.onPortForward,
                    tooltip: l10n.termTbPortForward,
                    visualDensity: _barDensity,
                  ),
                ),

              // Snippets button
              if (widget.onSnippets != null)
                Semantics(
                  label: l10n.termTbSnippetsSemantic,
                  button: true,
                  // One name for a screen reader: the button's tooltip under it
                  // said it a second time.
                  excludeSemantics: true,
                  onTap: widget.onSnippets,
                  child: IconButton(
                    icon: const Icon(LucideIcons.code, size: 20),
                    onPressed: widget.onSnippets,
                    tooltip: l10n.termTbSnippets,
                    visualDensity: _barDensity,
                  ),
                ),

              // Settings gear
              if (widget.onSettings != null)
                Semantics(
                  label: l10n.termTbSettingsSemantic,
                  button: true,
                  // One name for a screen reader: the button's tooltip under it
                  // said it a second time.
                  excludeSemantics: true,
                  onTap: widget.onSettings,
                  child: IconButton(
                    icon: const Icon(LucideIcons.settings, size: 20),
                    onPressed: widget.onSettings,
                    tooltip: l10n.termTbSettings,
                    visualDensity: _barDensity,
                  ),
                ),
            ] else ...[
              // ── Mobile: settings icon stays visible ──
              if (widget.onSettings != null)
                Semantics(
                  label: l10n.termTbSettingsSemantic,
                  button: true,
                  // One name for a screen reader: the button's tooltip under it
                  // said it a second time.
                  excludeSemantics: true,
                  onTap: widget.onSettings,
                  child: IconButton(
                    icon: const Icon(LucideIcons.settings, size: 20),
                    onPressed: widget.onSettings,
                    tooltip: l10n.termTbSettings,
                    visualDensity: _barDensity,
                  ),
                ),

              // ── Mobile: overflow popup menu ──
              _buildMobileOverflowMenu(),
            ],
          ],

          if (widget.paneControls != null) widget.paneControls!,

          // Reconnect button (shown when disconnected and not auto-reconnecting)
          if (widget.status == SessionStatus.disconnected &&
              !widget.isReconnecting &&
              widget.onReconnect != null)
            Semantics(
              label: l10n.termTbReconnectSemantic,
              button: true,
              // One name for a screen reader: the button's tooltip under it
              // said it a second time.
              excludeSemantics: true,
              onTap: widget.onReconnect,
              child: IconButton(
                icon: const Icon(LucideIcons.refreshCw, size: 20),
                onPressed: widget.onReconnect,
                tooltip: l10n.termTbReconnect,
                color: AppColors.accentInk,
                visualDensity: _barDensity,
              ),
            ),

          // Disconnect button
          if (widget.status == SessionStatus.connected ||
              widget.status == SessionStatus.connecting)
            Semantics(
              label: l10n.termTbDisconnectSemantic,
              button: true,
              // One name for a screen reader: the button's tooltip under it
              // said it a second time.
              excludeSemantics: true,
              onTap: widget.onDisconnect,
              child: IconButton(
                icon: const Icon(LucideIcons.power, size: 20),
                onPressed: widget.onDisconnect,
                tooltip: l10n.termTbDisconnect,
                color: AppColors.error,
                visualDensity: _barDensity,
              ),
            ),
        ],
      ),
    );
  }

  /// Build the overflow popup menu for mobile, collapsing action icons
  /// that would otherwise cause toolbar overflow on narrow screens.
  Widget _buildMobileOverflowMenu() {
    final l10n = AppLocalizations.of(context)!;
    final items = <PopupMenuEntry<String>>[];

    // Split-view - only show if splitButton was provided (device supports it)
    if (widget.onSplit != null && widget.splitButton != null) {
      items.add(PopupMenuItem<String>(
        value: 'split',
        child: Row(
          children: [
            const Icon(LucideIcons.columns, size: 20),
            const SizedBox(width: 12),
            Text(l10n.termTbSplitTerminal),
          ],
        ),
      ));
    }

    // Broadcast
    if (widget.onBroadcastConfig != null) {
      items.add(PopupMenuItem<String>(
        value: 'broadcast',
        child: Row(
          children: [
            Icon(
              LucideIcons.radioTower,
              size: 20,
              color: widget.isBroadcasting ? AppColors.accentInk : null,
            ),
            const SizedBox(width: 12),
            Text(widget.isBroadcasting
                ? l10n.termTbBroadcastCount(widget.broadcastTargetCount)
                : l10n.termTbBroadcastMode),
          ],
        ),
      ));
    }

    // Search
    if (widget.onSearch != null) {
      items.add(PopupMenuItem<String>(
        value: 'search',
        child: Row(
          children: [
            const Icon(LucideIcons.search, size: 20),
            const SizedBox(width: 12),
            Text(l10n.termTbFind),
          ],
        ),
      ));
    }

    // SFTP
    if (widget.onSftp != null) {
      items.add(PopupMenuItem<String>(
        value: 'sftp',
        child: Row(
          children: [
            const Icon(LucideIcons.folderOpen, size: 20),
            const SizedBox(width: 12),
            Text(l10n.termTbSftp),
          ],
        ),
      ));
    }

    // Port Forward
    if (widget.onPortForward != null) {
      items.add(PopupMenuItem<String>(
        value: 'portForward',
        child: Row(
          children: [
            const Icon(LucideIcons.arrowLeftRight, size: 20),
            const SizedBox(width: 12),
            Text(l10n.termTbPortForward),
          ],
        ),
      ));
    }

    // tmux (native control mode inside this tab)
    if (widget.onTmux != null) {
      items.add(PopupMenuItem<String>(
        value: 'tmux',
        child: Row(
          children: [
            const Icon(LucideIcons.layoutGrid, size: 20),
            const SizedBox(width: 12),
            Text(l10n.termTbTmux),
          ],
        ),
      ));
    }

    // Snippets
    if (widget.onSnippets != null) {
      items.add(PopupMenuItem<String>(
        value: 'snippets',
        child: Row(
          children: [
            const Icon(LucideIcons.code, size: 20),
            const SizedBox(width: 12),
            Text(l10n.termTbSnippets),
          ],
        ),
      ));
    }

    // Save / Edit connection - promote a quick-connect session
    // (auto-saved with a raw "user@host:port" label) into a fully
    // configured saved connection with a proper label, identity,
    // port forwards, tags, etc. Or simply edit an existing saved
    // connection without leaving the session.
    if (widget.onEditConnection != null) {
      items.add(PopupMenuItem<String>(
        value: 'editConnection',
        child: Row(
          children: [
            const Icon(LucideIcons.bookmarkPlus, size: 20),
            const SizedBox(width: 12),
            Text(l10n.termTbSaveConnection),
          ],
        ),
      ));
    }

    // Session Info
    if (widget.onSessionInfo != null) {
      items.add(const PopupMenuDivider());
      items.add(PopupMenuItem<String>(
        value: 'sessionInfo',
        child: Row(
          children: [
            const Icon(LucideIcons.info, size: 20),
            const SizedBox(width: 12),
            Text(l10n.termTbSessionInfo),
          ],
        ),
      ));
    }

    if (items.isEmpty) return const SizedBox.shrink();

    return PopupMenuButton<String>(
      icon: const Icon(LucideIcons.moreVertical, size: 20),
      tooltip: l10n.termTbMoreActions,
      padding: EdgeInsets.zero,
      onSelected: (value) {
        switch (value) {
          case 'split':
            widget.onSplit?.call();
          case 'broadcast':
            widget.onBroadcastConfig?.call();
          case 'search':
            widget.onSearch?.call();
          case 'sftp':
            widget.onSftp?.call();
          case 'portForward':
            widget.onPortForward?.call();
          case 'tmux':
            widget.onTmux?.call();
          case 'snippets':
            widget.onSnippets?.call();
          case 'sessionInfo':
            widget.onSessionInfo?.call();
          case 'editConnection':
            widget.onEditConnection?.call();
        }
      },
      itemBuilder: (context) => items,
    );
  }

  Color get _statusColor {
    if (widget.isReconnecting) return AppColors.warning;
    switch (widget.status) {
      case SessionStatus.connected:
        return AppColors.success;
      case SessionStatus.connecting:
        return AppColors.warning;
      case SessionStatus.error:
        return AppColors.error;
      case SessionStatus.disconnected:
        return AppColors.textSecondary;
    }
  }

  /// Display text: use the SSH terminal title when connected, else status.
  String get _displayText {
    if (widget.status == SessionStatus.connected) {
      if (!isTouchLayout) {
        // Desktop: show terminal title (user@host:~) or label
        if (widget.terminalTitle != null && widget.terminalTitle!.isNotEmpty) {
          return Redactable.freeText(widget.terminalTitle!).display;
        }
        if (widget.connectionLabel != null &&
            widget.connectionLabel!.isNotEmpty) {
          return Redactable.host(widget.connectionLabel!).display;
        }
      } else {
        // A phone and a tablet: the host by its name, as its session tab
        // under this bar names it (MobileSessionTabs): its label, else its
        // address. (It said the address while the tabs said the name: found
        // on a Pixel 3a, 5 November 2026.)
        if (widget.connectionLabel != null &&
            widget.connectionLabel!.isNotEmpty) {
          return Redactable.host(widget.connectionLabel!).display;
        }
        if (widget.host != null && widget.host!.isNotEmpty) {
          return Redactable.address(widget.host!).display;
        }
      }
    }
    return _statusText;
  }

  String get _statusText {
    final l10n = AppLocalizations.of(context)!;
    if (widget.isReconnecting) return l10n.termTbStatusReconnecting;
    switch (widget.status) {
      case SessionStatus.connected:
        return l10n.termTbStatusConnected;
      case SessionStatus.connecting:
        return l10n.termTbStatusConnecting;
      case SessionStatus.error:
        return l10n.termTbStatusError;
      case SessionStatus.disconnected:
        return l10n.termTbStatusDisconnected;
    }
  }
}

/// Connected-duration chip that owns its own 1-second ticker so only this
/// small Text rebuilds each second - the parent toolbar (and its buttons)
/// no longer setState()s on every tick.
class _ConnectionDurationChip extends StatefulWidget {
  const _ConnectionDurationChip({required this.connectedAt});

  final DateTime connectedAt;

  @override
  State<_ConnectionDurationChip> createState() =>
      _ConnectionDurationChipState();
}

class _ConnectionDurationChipState extends State<_ConnectionDurationChip> {
  /// Once a second while the app is in front, not while it is in the
  /// background, where it ticked on for as long as the session was open;
  /// back in front it shows the right time at once.
  late final ForegroundTicker _timer;

  @override
  void initState() {
    super.initState();
    _timer = ForegroundTicker(const Duration(seconds: 1), () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer.dispose();
    super.dispose();
  }

  String get _durationText {
    final elapsed = DateTime.now().difference(widget.connectedAt);
    final h = elapsed.inHours;
    final m = elapsed.inMinutes.remainder(60);
    final s = elapsed.inSeconds.remainder(60);
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// What the timer counts, in words: "Connected for 12m 7s". The bar shows
  /// the bare figures; a tooltip (a tap or a long press on a phone) and a
  /// screen reader say what they are (a
  /// time beside the host's name said nothing of what it was).
  String _words(AppLocalizations l10n) => l10n.termTbConnectedFor(durationWords(
      l10n, DateTime.now().difference(widget.connectedAt),
      seconds: true));

  @override
  Widget build(BuildContext context) {
    final words = _words(AppLocalizations.of(context)!);
    // A phone and a tablet: plain text in the app's own type, its figures
    // of one width (a timer is not a value to copy, and not a chip; 3.0
    // quick wins), after a stopwatch that says it is a time counting.
    if (isTouchLayout) {
      // The words for a screen reader stand over the tooltip, which would
      // otherwise speak in their place.
      return Semantics(
        label: words,
        excludeSemantics: true,
        child: Tooltip(
          key: const ValueKey('terminal-bar-duration-tip'),
          message: words,
          triggerMode: TooltipTriggerMode.tap,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.timer, size: 14, color: AppColors.textSecondary),
              const SizedBox(width: 3),
              Text(
                _durationText,
                key: const ValueKey('terminal-bar-duration'),
                style: TextStyle(
                  fontSize: 13,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Semantics(
      label: words,
      excludeSemantics: true,
      child: Tooltip(
        message: words,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            color: AppColors.success.withValues(alpha: 0.12),
          ),
          child: Text(
            _durationText,
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'JetBrainsMono',
              color: AppColors.success,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// The bar's buttons: 48 by 48 where a finger taps them, a mouse's 40 on a
/// computer.
VisualDensity get _barDensity => isTouchLayout ? VisualDensity.standard : VisualDensity.compact;
