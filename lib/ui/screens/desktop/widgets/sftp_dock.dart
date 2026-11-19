import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart' show TerminalResizeHold;
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart' show freeSessionLimit, isProProvider;
import 'package:zestssh/providers/sftp_pins_provider.dart' show sftpTimeFormatProvider;
import 'package:zestssh/providers/terminal_folder_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ftps/ftps_session.dart' show FtpsShellService;
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/terminal/widgets/connection_error_view.dart' show connectionFailureReport;
import 'package:zestssh/ui/widgets/connection_lost_view.dart' show dropKind, mayOfferSftpOnlyHost;
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/terminal_folder_help.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// Where the SFTP dock sits in a session tab.
enum SftpDockSide { bottom, right }

/// This device's SFTP dock: its side and sizes. Device-local on purpose (a
/// laptop and a big desktop want different sizes), so it lives in
/// SharedPreferences and is never synced.
class SftpDockPrefs {
  const SftpDockPrefs({
    this.side = SftpDockSide.bottom,
    this.height = defaultHeight,
    this.width = defaultWidth,
    this.twoPanes = true,
    this.followTerminal = false,
  });

  static const double defaultHeight = 328;
  static const double defaultWidth = 640;
  static const double minHeight = 200;
  static const double minWidth = 420;

  final SftpDockSide side;
  final double height;
  final double width;

  /// Two panes side by side, with the rail of places (this computer, or
  /// another host, beside the session's): the default, as a file transfer
  /// usually has two sides; off, the session's host alone.
  final bool twoPanes;

  /// Whether the dock opens each folder its terminal goes to (4.0, "Follow
  /// the terminal"): this computer's choice, as the dock's other ones.
  final bool followTerminal;

  SftpDockPrefs copyWith({SftpDockSide? side, double? height, double? width, bool? twoPanes, bool? followTerminal}) =>
      SftpDockPrefs(
        side: side ?? this.side,
        height: height ?? this.height,
        width: width ?? this.width,
        twoPanes: twoPanes ?? this.twoPanes,
        followTerminal: followTerminal ?? this.followTerminal,
      );
}

class SftpDockPrefsNotifier extends StateNotifier<SftpDockPrefs> {
  SftpDockPrefsNotifier(this._prefs) : super(_read(_prefs));

  final SharedPreferences _prefs;

  static const _kSide = 'sftp_dock_side';
  static const _kHeight = 'sftp_dock_height';
  static const _kWidth = 'sftp_dock_width';
  static const _kTwoPanes = 'sftp_dock_two_panes';
  static const _kFollowTerminal = 'sftp_dock_follow_terminal';

  static SftpDockPrefs _read(SharedPreferences p) => SftpDockPrefs(
        side: p.getString(_kSide) == 'right'
            ? SftpDockSide.right
            : SftpDockSide.bottom,
        height: (p.getDouble(_kHeight) ?? SftpDockPrefs.defaultHeight)
            .clamp(SftpDockPrefs.minHeight, 2000)
            .toDouble(),
        width: (p.getDouble(_kWidth) ?? SftpDockPrefs.defaultWidth)
            .clamp(SftpDockPrefs.minWidth, 3000)
            .toDouble(),
        twoPanes: p.getBool(_kTwoPanes) ?? true,
        followTerminal: p.getBool(_kFollowTerminal) ?? false,
      );

  void setSide(SftpDockSide side) {
    state = state.copyWith(side: side);
    _prefs.setString(_kSide, side.name);
  }

  void setTwoPanes(bool on) {
    state = state.copyWith(twoPanes: on);
    _prefs.setBool(_kTwoPanes, on);
  }

  void setFollowTerminal(bool on) {
    state = state.copyWith(followTerminal: on);
    _prefs.setBool(_kFollowTerminal, on);
  }

  /// Live while dragging; [persist] once the drag ends. [max] is the most the
  /// window gives the dock now: a size past it is never kept (the edge then
  /// stopped following the pointer until the extra was dragged back).
  void setHeight(double h, {double max = double.infinity}) =>
      state = state.copyWith(height: _within(h, SftpDockPrefs.minHeight, max));

  void setWidth(double w, {double max = double.infinity}) =>
      state = state.copyWith(width: _within(w, SftpDockPrefs.minWidth, max));

  static double _within(double v, double min, double max) =>
      v.clamp(min, max < min ? min : max).toDouble();

  void persist() {
    _prefs.setDouble(_kHeight, state.height);
    _prefs.setDouble(_kWidth, state.width);
  }
}

final sftpDockPrefsProvider =
    StateNotifierProvider<SftpDockPrefsNotifier, SftpDockPrefs>(
  (ref) => SftpDockPrefsNotifier(ref.read(sharedPreferencesProvider)),
);

/// The SFTP leaf of a tab, if any: the one the dock shows. A tab keeps at
/// most one (opening SFTP for another session in the tab replaces it).
PaneLeaf? sftpLeafOf(PaneNode? tree) =>
    tree?.allLeaves.where((l) => l.type == 'sftp').firstOrNull;

/// The dock around the SFTP browser: its header (the host, the terminal's
/// folder and following it, move to the other side, close) and the grip that
/// resizes it.
class SftpDockFrame extends ConsumerWidget {
  const SftpDockFrame({
    super.key,
    this.sessionId,
    required this.sessionState,
    required this.side,
    required this.canMoveRight,
    required this.onClose,
    required this.child,
    this.maxSize = double.infinity,
  });

  /// The session whose terminal the dock is beside: its folder is offered
  /// (4.0). Null shows no folder buttons.
  final String? sessionId;

  final SessionState? sessionState;

  /// The most room the dock has along its grip right now.
  final double maxSize;

  /// The side the dock is drawn on right now (bottom when the right side
  /// has no room, whatever the person chose).
  final SftpDockSide side;

  /// False while the right side has no room: the button then says so.
  final bool canMoveRight;
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final prefs = ref.watch(sftpDockPrefsProvider);
    final notifier = ref.read(sftpDockPrefsProvider.notifier);
    final bottom = side == SftpDockSide.bottom;
    final s = sessionState;
    final id = sessionId;
    // An FTPS host's session has no terminal to follow.
    final hasTerminal = id != null && s?.session?.shell is! FtpsShellService;

    final header = Container(
      height: 36,
      padding: const EdgeInsets.only(left: 12, right: 6),
      decoration: BoxDecoration(
        color: ZestColors.surfacePanel,
        border: Border(bottom: BorderSide(color: ZestColors.borderDefault)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Text(
                  'SFTP',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: ZestColors.textPrimary,
                  ),
                ),
                if (s != null) ...[
                  const SizedBox(width: 10),
                  Flexible(child: _HostPill(sessionState: s)),
                ],
              ],
            ),
          ),
          if (hasTerminal) ...[
            SftpDockTerminalFolder(sessionId: id, compact: !bottom),
            const SizedBox(width: 2),
          ],
          _DockButton(
            key: const ValueKey('sftp-dock-move'),
            icon: bottom ? LucideIcons.panelRight : LucideIcons.panelBottom,
            label: bottom ? l10n.sftpDockMoveRight : l10n.sftpDockMoveBottom,
            tooltip: bottom && !canMoveRight ? l10n.sftpDockNoRoomRight : null,
            // Moves away from the side it is drawn on. The right side is
            // offered only when the window has room for it.
            onTap: bottom
                ? (canMoveRight
                    ? () => notifier.setSide(SftpDockSide.right)
                    : null)
                : () => notifier.setSide(SftpDockSide.bottom),
          ),
          const SizedBox(width: 2),
          _DockButton(
            key: const ValueKey('sftp-dock-close'),
            icon: LucideIcons.x,
            tooltip: l10n.sftpDockClose,
            onTap: onClose,
          ),
        ],
      ),
    );

    final body = Column(
      children: [
        header,
        Expanded(child: child),
      ],
    );

    // The grip: a thin bar along the edge that meets the terminals.
    // The edge stays where the pointer is, counted from where the drag began
    // (a sum of steps drifted away from it at either limit), and the
    // terminals keep their rows and columns until it ends: each new size lays
    // out every line of their scrollback again, too much for every step.
    final shown = (bottom ? prefs.height : prefs.width)
        .clamp(0.0, maxSize)
        .toDouble();
    final grip = MouseRegion(
      cursor: bottom
          ? SystemMouseCursors.resizeRow
          : SystemMouseCursors.resizeColumn,
      child: _DockGrip(
        key: const ValueKey('sftp-dock-grip'),
        bottom: bottom,
        size: shown,
        onSize: (s) => bottom
            ? notifier.setHeight(s, max: maxSize)
            : notifier.setWidth(s, max: maxSize),
        onEnd: notifier.persist,
        // A 1px hairline in a 6px hit area, as the dividers between panes
        // (it was a 5px grey band).
        child: SizedBox(
          width: bottom ? double.infinity : 6,
          height: bottom ? 6 : double.infinity,
          child: Center(
            child: Container(
              width: bottom ? double.infinity : 1,
              height: bottom ? 1 : double.infinity,
              color: ZestColors.borderDefault,
            ),
          ),
        ),
      ),
    );

    return bottom
        ? Column(children: [grip, Expanded(child: body)])
        : Row(children: [grip, Expanded(child: body)]);
  }
}

/// The dock's grip: a drag sets the size from where it began, and holds the
/// terminals' rows and columns until it ends (however it ends).
class _DockGrip extends StatefulWidget {
  const _DockGrip({
    super.key,
    required this.bottom,
    required this.size,
    required this.onSize,
    required this.onEnd,
    required this.child,
  });

  final bool bottom;
  final double size;
  final ValueChanged<double> onSize;
  final VoidCallback onEnd;
  final Widget child;

  @override
  State<_DockGrip> createState() => _DockGripState();
}

class _DockGripState extends State<_DockGrip> {
  double? _fromPos;
  double _fromSize = 0;

  double _along(Offset p) => widget.bottom ? p.dy : p.dx;

  void _start(DragStartDetails d) {
    if (_fromPos == null) TerminalResizeHold.hold();
    _fromPos = _along(d.globalPosition);
    _fromSize = widget.size;
  }

  void _update(DragUpdateDetails d) {
    final from = _fromPos;
    if (from == null) return;
    // The dock grows as the grip moves away from it (up, or left).
    widget.onSize(_fromSize + from - _along(d.globalPosition));
  }

  void _end() {
    if (_fromPos == null) return;
    _fromPos = null;
    TerminalResizeHold.release();
    widget.onEnd();
  }

  @override
  void dispose() {
    if (_fromPos != null) TerminalResizeHold.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onVerticalDragStart: widget.bottom ? _start : null,
        onVerticalDragUpdate: widget.bottom ? _update : null,
        onVerticalDragEnd: widget.bottom ? (_) => _end() : null,
        onVerticalDragCancel: widget.bottom ? _end : null,
        onHorizontalDragStart: widget.bottom ? null : _start,
        onHorizontalDragUpdate: widget.bottom ? null : _update,
        onHorizontalDragEnd: widget.bottom ? null : (_) => _end(),
        onHorizontalDragCancel: widget.bottom ? null : _end,
        child: widget.child,
      );
}

/// The dock's "Go to the terminal's folder" and "Follow the terminal" (4.0):
/// the folder the session's terminal said it is in
/// (OSC 7 or OSC 1337;CurrentDir=, [terminalFolderProvider]) opened in the
/// dock's files, once or each time it changes. Where the terminal has said
/// none, either explains how to make the shell say it. The dock's files open
/// it ([terminalFolderRequestProvider]): they know which pane shows the
/// host, and say so where the host has no such folder.
class SftpDockTerminalFolder extends ConsumerStatefulWidget {
  const SftpDockTerminalFolder({super.key, required this.sessionId, this.compact = false});

  final String sessionId;

  /// Follow shows its icon alone (the dock on the right has less room).
  final bool compact;

  @override
  ConsumerState<SftpDockTerminalFolder> createState() => _SftpDockTerminalFolderState();
}

class _SftpDockTerminalFolderState extends ConsumerState<SftpDockTerminalFolder> {
  void _ask(String path, {bool following = false}) {
    ref.read(terminalFolderRequestProvider(widget.sessionId).notifier).state =
        TerminalFolderRequest(path, following: following);
  }

  void _goOnce() {
    final folder = ref.read(terminalFolderProvider(widget.sessionId));
    if (folder == null) {
      showTerminalFolderHelp(context, ref);
      return;
    }
    _ask(folder);
  }

  void _toggleFollow() {
    final prefs = ref.read(sftpDockPrefsProvider.notifier);
    final on = !ref.read(sftpDockPrefsProvider).followTerminal;
    prefs.setFollowTerminal(on);
    if (!on) return;
    // Turned on: where the terminal is now, or how to make it say so.
    final folder = ref.read(terminalFolderProvider(widget.sessionId));
    if (folder == null) {
      showTerminalFolderHelp(context, ref);
    } else {
      _ask(folder, following: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final folder = ref.watch(terminalFolderProvider(widget.sessionId));
    final following = ref.watch(sftpDockPrefsProvider.select((p) => p.followTerminal));
    // Each new folder the terminal says, while following.
    ref.listen<String?>(terminalFolderProvider(widget.sessionId), (before, now) {
      if (now != null && now != before && ref.read(sftpDockPrefsProvider).followTerminal) {
        _ask(now, following: true);
      }
    });
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _DockButton(
          key: const ValueKey('sftp-dock-terminal-folder'),
          icon: LucideIcons.folderSymlink,
          tooltip: folder == null ? l10n.sftpTerminalFolderNoneTip : l10n.sftpTerminalFolderGoTip(Redactable.path(folder).displayIn(ref)),
          semanticLabel: l10n.sftpTerminalFolderGo,
          onTap: _goOnce,
        ),
        const SizedBox(width: 2),
        _DockButton(
          key: const ValueKey('sftp-dock-follow-terminal'),
          icon: following ? LucideIcons.locateFixed : LucideIcons.locate,
          label: widget.compact ? null : l10n.sftpTerminalFolderFollow,
          tooltip: l10n.sftpTerminalFolderFollowTip,
          semanticLabel: l10n.sftpTerminalFolderFollow,
          selected: following,
          onTap: _toggleFollow,
        ),
      ],
    );
  }
}

class _DockButton extends StatefulWidget {
  const _DockButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.label,
    this.tooltip,
    this.semanticLabel,
    this.selected,
  });

  final IconData icon;
  final String? label;
  final String? tooltip;

  /// What a screen reader says for a button with no [label].
  final String? semanticLabel;

  /// A button that is on or off (Follow): non-null makes it a toggle, shown
  /// in the brand's ink while on.
  final bool? selected;

  /// Null shows the button dimmed and not clickable.
  final VoidCallback? onTap;

  @override
  State<_DockButton> createState() => _DockButtonState();
}

class _DockButtonState extends State<_DockButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final on = widget.selected ?? false;
    final fg = !enabled
        ? ZestColors.textDisabled
        : on
            ? ZestColors.accentPrimary
            : _hover
                ? ZestColors.textPrimary
                : ZestColors.textSecondary;
    Widget b = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 26,
          padding: EdgeInsets.symmetric(horizontal: widget.label == null ? 5 : 9),
          decoration: BoxDecoration(
            color: (_hover && enabled) || on
                ? ZestColors.surfaceRaisedAlt
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 14, color: fg),
              if (widget.label != null) ...[
                const SizedBox(width: 6),
                Text(widget.label!, style: TextStyle(fontSize: 12, color: fg)),
              ],
            ],
          ),
        ),
      ),
    );
    if (widget.selected != null || widget.semanticLabel != null) {
      b = Semantics(
        button: true,
        toggled: widget.selected,
        label: widget.label == null ? widget.semanticLabel : null,
        child: b,
      );
    }
    if (widget.tooltip != null) b = Tooltip(message: widget.tooltip!, child: b);
    return b;
  }
}

/// Whether the connection the SFTP dock shares with [s]'s terminal is down:
/// dropped, given up on, or being connected again by itself. (A session
/// connecting for the first time is waited for, as before.)
bool sftpDockConnectionDown(SessionState s) =>
    s.status == SessionStatus.disconnected ||
    s.status == SessionStatus.error ||
    (s.status == SessionStatus.connecting && s.isReconnecting);

/// What a session's connection is, in words: Connected, Connecting,
/// Reconnecting with which try, Disconnected or Error, as the session's own
/// status chip says it.
String sftpDockStateWord(AppLocalizations l10n, SessionState s) => switch (s.status) {
      SessionStatus.connected => l10n.sessionInfoStatusConnected,
      SessionStatus.connecting => s.isReconnecting
          ? l10n.sessionHeaderReconnecting(s.reconnectAttempt, s.maxRetries)
          : l10n.sessionInfoStatusConnecting,
      SessionStatus.disconnected => l10n.sessionInfoStatusDisconnected,
      SessionStatus.error => l10n.sessionInfoStatusError,
    };

/// The dock's host, with the state of its connection: a dot of its colour,
/// and the state in words to a screen reader and on hover, as the session's
/// status chip has them (the dot alone said it, in green or amber).
class _HostPill extends StatelessWidget {
  const _HostPill({required this.sessionState});

  final SessionState sessionState;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final s = sessionState;
    final dot = switch (s.status) {
      SessionStatus.connected => ZestColors.statusSuccess,
      SessionStatus.connecting => ZestColors.statusWarning,
      SessionStatus.disconnected || SessionStatus.error => ZestColors.statusError,
    };
    final word = sftpDockStateWord(l10n, s);
    return Consumer(builder: (context, ref, _) {
      final name = Redactable.host(s.connectionLabel).displayIn(ref);
      return Semantics(
        label: l10n.sftpDockHostState(name, word),
        excludeSemantics: true,
        child: Tooltip(
          message: word,
          child: Container(
            key: const ValueKey('sftp-dock-host'),
            height: 22,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: ZestColors.chromeElevated,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: ZestColors.borderDefault),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: RedactedText(
                    Redactable.host(s.connectionLabel),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: ZestColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }
}

/// What the SFTP dock shows while the connection it shares with its
/// session's terminal is down (4.0): that the
/// host is disconnected, and why there are no files (the dock has no
/// connection of its own: it shares the tab's, which dropped, and when);
/// Reconnect, the one main button; the host's files on a connection of their
/// own, in a tab of their own; and the report of the drop to copy. It showed
/// "SFTP requires an active SSH connection" beside an icon, as for a session
/// with no SSH at all, with nothing to do; or what it had listed, of a host
/// nothing could be asked of any more.
class SftpDockDisconnected extends ConsumerStatefulWidget {
  const SftpDockDisconnected({
    super.key,
    required this.sessionId,
    required this.sessionState,
    this.onOpenSession,
  });

  final String sessionId;
  final SessionState sessionState;

  /// Brings a session's tab to the front: the one "Open SFTP on its own"
  /// opened.
  final ValueChanged<String>? onOpenSession;

  @override
  ConsumerState<SftpDockDisconnected> createState() => _SftpDockDisconnectedState();
}

class _SftpDockDisconnectedState extends ConsumerState<SftpDockDisconnected> {
  bool _opening = false;

  /// The host's files in a session of their own, on a connection of its own;
  /// its tab brought to the front. Where none could be opened, why.
  Future<void> _openOnItsOwn(String name) async {
    final l10n = AppLocalizations.of(context)!;
    final sessions = ref.read(activeSessionsProvider.notifier);
    setState(() => _opening = true);
    final id = await sessions.openFilesLike(widget.sessionId);
    if (!mounted) return;
    setState(() => _opening = false);
    if (id != null) return widget.onOpenSession?.call(id);
    final full = !ref.read(isProProvider) && sessions.occupiedSessionSlots >= freeSessionLimit;
    showTopSnackBar(
      context,
      full ? l10n.desktopShellFreeTierLimit(freeSessionLimit) : l10n.sftpDockHostGone(name),
      isError: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final s = widget.sessionState;
    final sessions = ref.read(activeSessionsProvider.notifier);
    final name = Redactable.host(s.connectionLabel.isNotEmpty ? s.connectionLabel : (s.host ?? '')).displayIn(ref);
    final format = ref.watch(sftpTimeFormatProvider);
    final at = sessions.droppedAt(widget.sessionId);
    final now = DateTime.now();
    final when = at == null
        ? null
        : at.year == now.year && at.month == now.month && at.day == now.day
            ? format.time(at)
            : format.dateTime(at);
    // A try of connecting again is under way: Reconnect waits for it.
    final trying = s.status == SessionStatus.connecting;
    final touch = Theme.of(context).materialTapTargetSize == MaterialTapTargetSize.padded;
    final report = connectionFailureReport(
      title: l10n.connectionLostTitle,
      error: s.errorMessage ?? s.dropCause ?? '',
      kind: dropKind(s.dropCause),
      log: s.connectionLog,
      where: 'The SFTP panel beside a session whose connection dropped',
    );
    final quiet = TextStyle(fontSize: 13, color: ZestColors.textTertiary, height: 1.45);
    return Container(
      // The surface of the dock's files, so the dock keeps its colour.
      color: AppColors.sftpPanel,
      alignment: Alignment.center,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.link2Off, size: 28, color: ZestColors.statusError),
              const SizedBox(height: 14),
              Text(
                l10n.sftpDockDisconnectedTitle(name),
                key: const ValueKey('sftp-dock-disconnected-title'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: ZestColors.textPrimary, height: 1.3),
              ),
              const SizedBox(height: 6),
              Text(
                when == null ? l10n.sftpDockSharesDropped : l10n.sftpDockSharesDroppedAt(when),
                key: const ValueKey('sftp-dock-disconnected-why'),
                textAlign: TextAlign.center,
                style: quiet.copyWith(fontSize: 13.5, color: ZestColors.textFaint),
              ),
              if (s.isReconnecting) ...[
                const SizedBox(height: 6),
                Text(sftpDockStateWord(l10n, s), textAlign: TextAlign.center, style: quiet),
              ] else if (s.reconnectAttempt > 0) ...[
                const SizedBox(height: 6),
                Text(l10n.terminalAutoReconnectFailed(s.reconnectAttempt), textAlign: TextAlign.center, style: quiet),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const ValueKey('sftp-dock-reconnect'),
                onPressed: trying ? null : () => sessions.reconnectNow(widget.sessionId),
                icon: trying
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: ZestColors.textTertiary),
                      )
                    : const Icon(LucideIcons.refreshCw, size: 16),
                label: Text(l10n.terminalReconnect),
                style: FilledButton.styleFrom(
                  backgroundColor: ZestColors.accentPrimary,
                  foregroundColor: AppColors.onBrand(ZestColors.accentPrimary),
                  minimumSize: Size(0, touch ? 48 : 40),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  textStyle:
                      Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 4,
                runSpacing: 4,
                children: [
                  // A host that is saved: a Quick connect's is not kept, and
                  // nothing could be opened of it again.
                  if (mayOfferSftpOnlyHost(s)) ...[
                    Tooltip(
                      message: l10n.sftpDockOpenOnItsOwnTip,
                      child: TextButton(
                        key: const ValueKey('sftp-dock-open-own'),
                        onPressed: _opening ? null : () => _openOnItsOwn(name),
                        style: TextButton.styleFrom(
                          foregroundColor: ZestColors.textSecondary,
                          minimumSize: Size(0, touch ? 48 : 32),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        child: Text(l10n.sftpDockOpenOnItsOwn, style: const TextStyle(fontSize: 13)),
                      ),
                    ),
                    ExcludeSemantics(
                      child: Container(
                        width: 3,
                        height: 3,
                        decoration: BoxDecoration(color: ZestColors.textDisabled, shape: BoxShape.circle),
                      ),
                    ),
                  ],
                  CopyDetailsButton(
                    key: const ValueKey('sftp-dock-copy-details'),
                    detail: report,
                    color: ZestColors.textSecondary,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
