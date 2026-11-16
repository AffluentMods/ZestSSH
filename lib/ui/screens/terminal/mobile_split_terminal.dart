import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/terminal/terminal_screen.dart';
import 'package:zestssh/utils/host_address.dart';

/// Minimum shortest-side (dp) that qualifies a device as a tablet.
const _kTabletShortestSide = 600.0;

/// Minimum dimension (dp) for *both* width and height to recognise a foldable
/// in fully-open mode (e.g. Galaxy Z Fold open: ~585 x 841).
const _kFoldableMinDimension = 500.0;

/// Whether the current screen supports split terminal.
///
/// Returns true only for:
///   - Tablets (shortestSide >= 600dp), or
///   - Foldable devices in open mode (both width AND height >= 500dp).
///
/// Regular phones - even large ones like iPhone Pro Max (428dp wide) -
/// will not trigger this.
bool _canSplit(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  final isTablet = size.shortestSide >= _kTabletShortestSide;
  final isFoldableOpen =
      size.width >= _kFoldableMinDimension && size.height >= _kFoldableMinDimension;
  return isTablet || isFoldableOpen;
}

/// Whether the split should be horizontal (side-by-side) rather than
/// vertical (top/bottom).
///
/// Foldable phones in tent/tabletop mode have a portrait-like aspect ratio
/// where height >> width. In that case, side-by-side works better because
/// each pane gets the full height. For landscape-ish screens, vertical
/// stacking (top/bottom) is the default.
bool _shouldSplitHorizontally(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  // If height is >= 1.5x the width, the device is likely a foldable in
  // a tall orientation - use horizontal split so each pane gets full height.
  return size.height >= size.width * 1.5;
}

/// Provider tracking whether mobile split mode is active.
final mobileSplitActiveProvider = StateProvider<bool>((ref) => false);

/// Provider tracking which session is shown in the secondary (bottom/right) pane.
final mobileSplitSecondarySessionProvider =
    StateProvider<String?>((ref) => null);

/// Mobile split terminal - wraps two [TerminalScreen] instances in a
/// draggable split layout for tablets and foldable phones.
///
/// On regular phones (shortestSide < 600dp), this delegates directly to a single
/// [TerminalScreen]. The split is activated via the toolbar toggle button
/// returned by [buildSplitButton].
class MobileSplitTerminal extends ConsumerWidget {
  final String primarySessionId;

  const MobileSplitTerminal({super.key, required this.primarySessionId});

  /// Builds a split view toggle button for the terminal toolbar.
  ///
  /// Returns null if the device cannot support split (too narrow),
  /// or if there are fewer than 2 active sessions.
  static Widget? buildSplitButton(BuildContext context, WidgetRef ref) {
    if (!_canSplit(context)) return null;

    final l10n = AppLocalizations.of(context)!;

    final sessions = ref.watch(activeSessionsProvider);
    final connectedCount = sessions.values
        .where((s) =>
            s.status == SessionStatus.connected ||
            s.status == SessionStatus.connecting)
        .length;

    // Need at least 1 session to show the button (the second pane
    // will show a "connect another" prompt if only 1 is active).
    if (connectedCount < 1) return null;

    final isActive = ref.watch(mobileSplitActiveProvider);

    return Semantics(
      label: isActive
          ? l10n.mobileSplitTerminalExitSplitViewSemantics
          : l10n.mobileSplitTerminalSplitViewSemantics,
      button: true,
      // Its name and whether split view is on, once (4.0 accessibility pass:
      // its tooltip was read after its name), and 48 square to a finger.
      toggled: isActive,
      excludeSemantics: true,
      onTap: () => ref.read(mobileSplitActiveProvider.notifier).state = !isActive,
      child: IconButton(
        icon: Icon(
          isActive ? LucideIcons.maximize2 : LucideIcons.rows,
          size: 20,
          color: isActive ? AppColors.accentInk : null,
        ),
        onPressed: () {
          ref.read(mobileSplitActiveProvider.notifier).state = !isActive;
        },
        tooltip: isActive
            ? l10n.mobileSplitTerminalExitSplit
            : l10n.mobileSplitTerminalSplitView,
        visualDensity: VisualDensity.standard,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isSplitActive = ref.watch(mobileSplitActiveProvider);

    // If split is off or screen is too small, show single terminal.
    if (!isSplitActive || !_canSplit(context)) {
      return TerminalScreen(sessionId: primarySessionId);
    }

    return _MobileSplitLayout(primarySessionId: primarySessionId);
  }
}

/// The actual split layout with draggable divider.
class _MobileSplitLayout extends ConsumerStatefulWidget {
  final String primarySessionId;

  const _MobileSplitLayout({required this.primarySessionId});

  @override
  ConsumerState<_MobileSplitLayout> createState() =>
      _MobileSplitLayoutState();
}

class _MobileSplitLayoutState extends ConsumerState<_MobileSplitLayout> {
  /// Split ratio: 0.0 = all primary, 1.0 = all secondary.
  /// Default 0.5 = 50/50 split.
  double _splitRatio = 0.5;

  /// Clamp split ratio so neither pane gets too small.
  static const _minRatio = 0.2;
  static const _maxRatio = 0.8;

  @override
  Widget build(BuildContext context) {
    final isHorizontal = _shouldSplitHorizontally(context);
    final secondarySessionId = ref.watch(mobileSplitSecondarySessionProvider);

    // Get the list of other connected sessions for the picker.
    final sessions = ref.watch(activeSessionsProvider);
    final otherSessions = sessions.entries
        .where((e) =>
            e.key != widget.primarySessionId &&
            (e.value.status == SessionStatus.connected ||
                e.value.status == SessionStatus.connecting))
        .toList();

    void selectSession(String id) => ref.read(mobileSplitSecondarySessionProvider.notifier).state = id;
    void swap() {
      // Real swap: promote the secondary session to primary and demote the
      // current primary into the secondary slot, then pushReplacement so the
      // router rebuilds MobileSplitTerminal with the new primarySessionId.
      // Split mode stays active, so the two panes visibly exchange.
      final currentSecondary = ref.read(mobileSplitSecondarySessionProvider);
      if (currentSecondary == null) return;
      ref.read(mobileSplitSecondarySessionProvider.notifier).state = widget.primarySessionId;
      context.pushReplacement('/terminal/$currentSecondary');
    }

    void close() {
      ref.read(mobileSplitActiveProvider.notifier).state = false;
      ref.read(mobileSplitSecondarySessionProvider.notifier).state = null;
    }

    // Build the secondary pane content. A session's terminal has one header:
    // its own toolbar, with the split's controls (the session in this pane,
    // swap, close) at its end; it had the split's strip over it as well.
    Widget secondaryPane;
    final secondaryIsTerminal = secondarySessionId != null &&
        sessions.containsKey(secondarySessionId) &&
        sessions[secondarySessionId]!.status == SessionStatus.connected;
    if (secondaryIsTerminal) {
      secondaryPane = TerminalScreen(
        sessionId: secondarySessionId,
        paneControls: _PaneControls(
          currentSessionId: secondarySessionId,
          others: otherSessions,
          onSessionSelected: selectSession,
          onSwap: swap,
          onClose: close,
        ),
      );
    } else if (otherSessions.isEmpty) {
      secondaryPane = _EmptySecondaryPane(
        onClose: () {
          ref.read(mobileSplitActiveProvider.notifier).state = false;
        },
      );
    } else {
      // Auto-select the first available session if none is chosen.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(mobileSplitSecondarySessionProvider.notifier).state =
              otherSessions.first.key;
        }
      });
      secondaryPane = Center(
        child: CircularProgressIndicator(color: AppColors.brandOrange),
      );
    }

    // Build the primary pane.
    final primaryPane = TerminalScreen(sessionId: widget.primarySessionId);

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalSize = isHorizontal
            ? constraints.maxWidth
            : constraints.maxHeight;
        final primarySize = totalSize * _splitRatio;

        final children = <Widget>[
          // Primary pane. Stacked, the screen's foot is the lower pane's,
          // and the screen's top (the status bar's room) is the upper one's
          // alone: the lower pane's header had an empty band over it.
          SizedBox(
            width: isHorizontal ? primarySize : null,
            height: isHorizontal ? null : primarySize,
            child: isHorizontal
                ? primaryPane
                : MediaQuery.removePadding(context: context, removeBottom: true, child: primaryPane),
          ),

          // Draggable divider
          _SplitDivider(
            isHorizontal: isHorizontal,
            onDrag: (delta) {
              setState(() {
                final change = isHorizontal
                    ? delta.dx / totalSize
                    : delta.dy / totalSize;
                _splitRatio = (_splitRatio + change).clamp(_minRatio, _maxRatio);
              });
            },
            onDoubleTap: () {
              // Reset to 50/50 on double-tap.
              setState(() => _splitRatio = 0.5);
            },
          ),

          // Secondary pane: a terminal with the split's controls in its own
          // toolbar; otherwise (no other session yet) the split's strip over
          // what it shows.
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeTop: !isHorizontal,
              child: secondaryIsTerminal
                  ? secondaryPane
                  : Column(
                      children: [
                        _SessionPickerBar(
                          currentSessionId: secondarySessionId,
                          primarySessionId: widget.primarySessionId,
                          sessions: sessions,
                          onSessionSelected: selectSession,
                          onSwap: swap,
                          onClose: close,
                        ),
                        Expanded(child: secondaryPane),
                      ],
                    ),
            ),
          ),
        ];

        // The route gives this layout no Scaffold of its own (each pane's
        // TerminalScreen has one): without a Material here the lower pane's
        // header draws its text in Flutter's no-Material error style (a
        // yellow double underline) and its session picker has no ink.
        return Material(
          color: AppColors.background,
          child: isHorizontal ? Row(children: children) : Column(children: children),
        );
      },
    );
  }
}

/// Draggable divider between the two terminal panes.
class _SplitDivider extends StatelessWidget {
  final bool isHorizontal;
  final ValueChanged<Offset> onDrag;
  final VoidCallback onDoubleTap;

  const _SplitDivider({
    required this.isHorizontal,
    required this.onDrag,
    required this.onDoubleTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanUpdate: (details) => onDrag(details.delta),
      onDoubleTap: onDoubleTap,
      child: MouseRegion(
        cursor: isHorizontal
            ? SystemMouseCursors.resizeColumn
            : SystemMouseCursors.resizeRow,
        child: Container(
          // Expand the transparent hit area to ~32px so the divider is
          // comfortably draggable by touch; the visible grip stays 4px.
          width: isHorizontal ? 32 : double.infinity,
          height: isHorizontal ? double.infinity : 32,
          color: Colors.transparent,
          child: Center(
            child: Container(
              width: isHorizontal ? 4 : 32,
              height: isHorizontal ? 32 : 4,
              decoration: BoxDecoration(
                color: AppColors.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The split view's controls for its second pane, at the end of that pane's
/// own toolbar: which session it shows (where there is more than one other
/// to pick from), swap the panes, close the split.
class _PaneControls extends StatelessWidget {
  const _PaneControls({
    required this.currentSessionId,
    required this.others,
    required this.onSessionSelected,
    required this.onSwap,
    required this.onClose,
  });

  final String currentSessionId;
  final List<MapEntry<String, SessionState>> others;
  final ValueChanged<String> onSessionSelected;
  final VoidCallback onSwap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      key: const ValueKey('split-pane-controls'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 1,
          height: 18,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          color: AppColors.divider,
        ),
        if (others.length > 1)
          PopupMenuButton<String>(
            key: const ValueKey('split-pane-pick'),
            tooltip: l10n.mobileSplitTerminalSelectSession,
            initialValue: currentSessionId,
            onSelected: onSessionSelected,
            icon: const Icon(LucideIcons.chevronsUpDown, size: 18),
            itemBuilder: (context) => [
              for (final entry in others)
                PopupMenuItem<String>(
                  value: entry.key,
                  child: Text(
                    _paneSessionLabel(entry.value, entry.key),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: entry.key == currentSessionId ? FontWeight.w600 : null,
                    ),
                  ),
                ),
            ],
          ),
        IconButton(
          key: const ValueKey('split-pane-swap'),
          icon: const Icon(LucideIcons.arrowUpDown, size: 18),
          onPressed: onSwap,
          tooltip: l10n.mobileSplitTerminalSwapPanes,
          visualDensity: VisualDensity.standard,
        ),
        IconButton(
          key: const ValueKey('split-pane-close'),
          icon: const Icon(LucideIcons.x, size: 18),
          onPressed: onClose,
          tooltip: l10n.mobileSplitTerminalCloseSplit,
          visualDensity: VisualDensity.standard,
        ),
      ],
    );
  }
}

/// A session's name for the split's pickers, in its recording-mode display
/// form (the label through the name rule, a bare host:port through the
/// address rule).
String _paneSessionLabel(SessionState state, String sessionId) {
  if (state.connectionLabel.isNotEmpty) {
    return Redactable.host(state.connectionLabel).display;
  }
  if (state.host != null) {
    return Redactable.address(hostWithPort(state.host ?? '', state.port ?? 22)).display;
  }
  return sessionId.split('_').first;
}

/// Session picker bar shown above the secondary pane while it shows no
/// session's terminal (none picked yet).
class _SessionPickerBar extends StatelessWidget {
  final String? currentSessionId;
  final String primarySessionId;
  final Map<String, SessionState> sessions;
  final ValueChanged<String> onSessionSelected;
  final VoidCallback onSwap;
  final VoidCallback onClose;

  const _SessionPickerBar({
    required this.currentSessionId,
    required this.primarySessionId,
    required this.sessions,
    required this.onSessionSelected,
    required this.onSwap,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Build list of sessions available for the secondary pane
    // (exclude the primary session).
    final availableSessions = sessions.entries
        .where((e) =>
            e.key != primarySessionId &&
            (e.value.status == SessionStatus.connected ||
                e.value.status == SessionStatus.connecting))
        .toList();

    final currentLabel = currentSessionId != null &&
            sessions.containsKey(currentSessionId)
        ? _sessionLabel(sessions[currentSessionId]!, currentSessionId!)
        : l10n.mobileSplitTerminalSelectSession;

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceDark,
        border: Border(
          top: BorderSide(
            color: AppColors.divider,
            width: 1,
          ),
          bottom: BorderSide(
            color: AppColors.divider,
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(width: 4),
          // Pane label
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: AppColors.brandOrange,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),

          // Session dropdown
          if (availableSessions.length > 1)
            Expanded(
              child: PopupMenuButton<String>(
                initialValue: currentSessionId,
                onSelected: onSessionSelected,
                offset: const Offset(0, 32),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        currentLabel,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      LucideIcons.chevronDown,
                      size: 16,
                      color: AppColors.onSurfaceVariant,
                    ),
                  ],
                ),
                itemBuilder: (context) => availableSessions.map((entry) {
                  final label = _sessionLabel(entry.value, entry.key);
                  return PopupMenuItem<String>(
                    value: entry.key,
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: entry.key == currentSessionId
                            ? FontWeight.w600
                            : null,
                      ),
                    ),
                  );
                }).toList(),
              ),
            )
          else
            Expanded(
              child: Text(
                currentLabel,
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),

          // Swap button
          if (currentSessionId != null)
            IconButton(
              icon: const Icon(LucideIcons.arrowUpDown, size: 16),
              onPressed: onSwap,
              tooltip: l10n.mobileSplitTerminalSwapPanes,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                minWidth: 28,
                minHeight: 28,
              ),
            ),

          // Close split button
          IconButton(
            icon: const Icon(LucideIcons.x, size: 16),
            onPressed: onClose,
            tooltip: l10n.mobileSplitTerminalCloseSplit,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(
              minWidth: 28,
              minHeight: 28,
            ),
          ),
        ],
      ),
    );
  }

  /// The session's name for the picker, in its recording-mode display form
  /// (the label through the name rule, a bare host:port through the address
  /// rule). The bar is rebuilt whenever the sessions change.
  String _sessionLabel(SessionState state, String sessionId) {
    if (state.connectionLabel.isNotEmpty) {
      return Redactable.host(state.connectionLabel).display;
    }
    if (state.host != null) {
      return Redactable.address(hostWithPort(state.host ?? '', state.port ?? 22)).display;
    }
    return sessionId.split('_').first;
  }
}

/// Shown in the secondary pane when no other sessions are available.
class _EmptySecondaryPane extends StatelessWidget {
  final VoidCallback onClose;

  const _EmptySecondaryPane({required this.onClose});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      color: AppColors.background,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                LucideIcons.terminal,
                size: 48,
                color: AppColors.textSecondary.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 16),
              Text(
                l10n.mobileSplitTerminalNoOtherSessions,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: AppColors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.mobileSplitTerminalNoOtherSessionsDescription,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: onClose,
                icon: const Icon(LucideIcons.maximize2, size: 18),
                label: Text(l10n.mobileSplitTerminalExitSplit),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.onSurfaceVariant,
                  side: BorderSide(
                    color: AppColors.divider.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
