import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/features/terminal/terminal_reader.dart';
import 'package:zestssh/features/tmux/tmux_cell_metrics.dart';
import 'package:zestssh/features/tmux/tmux_control_parser.dart';
import 'package:zestssh/features/tmux/tmux_controller.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/features/tmux/tmux_messages.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/shortcut_overrides_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_search_bar.dart';
import 'package:zestssh/ui/widgets/desktop_drop_target.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/terminal_paste.dart';
import 'package:zestssh/utils/command_text.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/screens/terminal/hardware_keyboard_use.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// The self-contained tmux workspace: a window strip styled like the app's
/// session tabs, cell-exact pane placement, the session switcher and the
/// window / pane management menus, driven by a [TmuxController]. It renders
/// inside a session's own tab on desktop and full screen on mobile.
class TmuxWorkspace extends ConsumerStatefulWidget {
  final TmuxController controller;

  /// The host of the session tmux runs in: its panes show its theme.
  final String? connectionId;

  /// Detach and leave tmux mode (the tmux session keeps running).
  final VoidCallback? onDetach;

  /// Shown as an always-visible control when set (in-band mode): asks the
  /// host to leave control mode even if tmux is wedged.
  final VoidCallback? onExitRequested;

  /// Find in terminal is open: its bar, under the window strip, searches the
  /// pane in front, and another pane in front is searched in its turn.
  final bool findOpen;

  /// How often Find was asked for while open: each time, its field takes the
  /// keyboard again.
  final int findAsk;

  /// Find's bar was closed (its close button, Escape); the keyboard goes
  /// back to the pane in front.
  final VoidCallback? onFindClose;

  /// How often the keyboard was asked for (a tab picked on a computer, the
  /// key for it on a phone): each time, the pane in front takes it, and a
  /// phone's on-screen keyboard comes up for it.
  final int keyboardAsk;

  const TmuxWorkspace({
    super.key,
    required this.controller,
    this.connectionId,
    this.onDetach,
    this.onExitRequested,
    this.findOpen = false,
    this.findAsk = 0,
    this.onFindClose,
    this.keyboardAsk = 0,
  });

  @override
  ConsumerState<TmuxWorkspace> createState() => _TmuxWorkspaceState();
}

/// Window names tmux picks automatically for an idle shell. For these the
/// tab shows where the shell is instead (from the pane title the prompt
/// sets), which tells windows apart far better than "bash" four times.
const _shellNames = {
  'bash', 'zsh', 'fish', 'sh', 'dash', 'ksh', 'tcsh', 'csh', 'ash',
  '-bash', '-zsh', '-fish', 'login',
};

/// `user@host: ~/dir`, the title most default prompts set through OSC 0.
final _promptTitle = RegExp(r'^[^\s@]+@[^\s:]+:\s*(.+)$');

/// The sessions menu: every tmux session on the host (the attached one
/// ticked), new / resync / detach, and kill in its own section. The
/// workspace strip's session crumb and the session bar's tmux button both
/// show exactly this list, so there is one menu, not two drifting copies.
/// Picks are handled by [handleTmuxSessionsMenu].
List<PopupMenuEntry<String>> tmuxSessionsMenuItems(
    AppLocalizations l10n, WidgetRef ref, TmuxController c) {
  return [
    PopupMenuItem(
      enabled: false,
      height: 28,
      child: _MenuSectionLabel(l10n.tmuxSessionsMenu),
    ),
    for (final s in c.sessions)
      PopupMenuItem(
        value: s.id,
        height: 40,
        child: Row(
          children: [
            Icon(
              s.id == c.currentSessionId
                  ? LucideIcons.check
                  : LucideIcons.terminal,
              size: 15,
              color: s.id == c.currentSessionId
                  ? AppColors.v3AccentInk
                  : AppColors.v3TextTertiary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                Redactable.host(s.name).displayIn(ref),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              l10n.tmuxPickerWindows(s.windows),
              style: TextStyle(fontSize: 11, color: AppColors.v3TextTertiary),
            ),
          ],
        ),
      ),
    const PopupMenuDivider(height: 1),
    PopupMenuItem(
      value: ':new',
      height: 40,
      child: _MenuRow(LucideIcons.plus, l10n.tmuxNewSessionAction),
    ),
    PopupMenuItem(
      value: ':resync',
      height: 40,
      child: _MenuRow(LucideIcons.refreshCw, l10n.tmuxResync),
    ),
    PopupMenuItem(
      value: ':detach',
      height: 48,
      child: _MenuRow(LucideIcons.unplug, l10n.tmuxDetach,
          subtitle: l10n.tmuxDetachHelp),
    ),
    const PopupMenuDivider(height: 1),
    // Destructive, in its own section: ends this session for good (the
    // picker's trash icon does the same for sessions not attached here).
    PopupMenuItem(
      value: ':kill',
      height: 48,
      child: _MenuRow(LucideIcons.trash2, l10n.tmuxKillSession,
          subtitle: l10n.tmuxKillSessionHelp, destructive: true),
    ),
  ];
}

/// Act on a pick from [tmuxSessionsMenuItems]. [onDetach] leaves tmux mode
/// the way the caller's surface does (the desktop tab detaches through its
/// host so the normal terminal comes back); without it the controller
/// detaches on its own.
Future<void> handleTmuxSessionsMenu(
  BuildContext context,
  WidgetRef ref,
  TmuxController c,
  String value, {
  VoidCallback? onDetach,
}) async {
  switch (value) {
    case ':new':
      await newTmuxSession(context, c);
    case ':detach':
      (onDetach ?? c.detach)();
    case ':resync':
      c.resyncAll();
    case ':kill':
      await killCurrentTmuxSession(context, ref, c);
    default:
      if (value != c.currentSessionId) c.switchSession(value);
  }
}

/// Name and create a session on [c]'s host, then switch to it.
Future<void> newTmuxSession(BuildContext context, TmuxController c) async {
  final l10n = AppLocalizations.of(context)!;
  final name = await showZestInputDialog(
    context: context,
    title: l10n.tmuxPickerNewSession,
    fieldLabel: l10n.tmuxPickerNewSessionHint,
    initialValue: '',
    confirmLabel: l10n.create,
  );
  if (name == null || name.trim().isEmpty) return;
  await c.newSession(name.trim());
}

/// Kill the session this client is attached to: every window and whatever
/// runs in them ends, and tmux detaches us (%exit), which the session view
/// shows as "Session ended" with the picker one click away.
Future<void> killCurrentTmuxSession(
    BuildContext context, WidgetRef ref, TmuxController c) async {
  final l10n = AppLocalizations.of(context)!;
  final id = c.currentSessionId;
  if (id == null) return;
  final name = c.currentSessionName ?? id;
  final windows = c.windows.length;
  final ok = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.destructive,
    title: l10n.tmuxKillSessionConfirmTitle(
        Redactable.host(name).displayIn(ref)),
    body: l10n.tmuxKillSessionConfirmBody(windows),
    confirmLabel: l10n.tmuxKillSession,
  );
  if (ok != true) return;
  await c.killSession(id);
}

/// What the tab for [w] should say.
String tmuxWindowLabel(TmuxWindow w) {
  if (_shellNames.contains(w.name)) {
    final title = w.activePane?.title ?? '';
    final m = _promptTitle.firstMatch(title);
    if (m != null) {
      final place = m.group(1)!.trim();
      if (place.isNotEmpty) return place;
    }
  }
  return w.name;
}

class _TmuxWorkspaceState extends ConsumerState<TmuxWorkspace> {
  final Map<String, TerminalController> _paneCtrls = {};
  final Map<String, FocusNode> _paneFocus = {};

  /// Each pane's terminal view, with the terminal it shows, for Find's
  /// bringing a match into view ([_view]).
  final Map<String, (Terminal, GlobalKey<TerminalViewState>)> _paneViews = {};

  /// The field of Find's bar.
  final FocusNode _findFocus = FocusNode(debugLabel: 'tmux find');
  String? _focusedPane;
  (String, double, TextScaler)? _cellKey;
  Size _cell = Size.zero;

  /// Whether the on-screen keyboard may learn from what is typed into a pane
  /// (Settings). Read where the panes are built, [_paneArea].
  bool _keyboardLearns = false;

  /// When the panes draw their cursor (Settings, 4.0). Read where the panes
  /// are built, [_paneArea].
  TerminalCursorVisibility _cursorShown = TerminalCursorVisibility.always;

  /// Whether the keyboard asked for is the one without suggestions (Settings,
  /// the compact keyboard). Read where the panes are built, [_paneArea].
  bool _compactKeyboard = false;

  /// On a computer, the keys Settings binds copy and paste to (terminalKeys).
  /// Read where the panes are built, [_paneArea].
  ShortcutBindings? _bindings;
  final _copyOnRelease = CopyOnRelease();

  TmuxController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChanged);
    // The active pane usually exists before this widget does (the host
    // attaches first): hand it the keyboard once the first frame is up.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusActivePane();
    });
  }

  @override
  void didUpdateWidget(covariant TmuxWorkspace old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
    }
    if (widget.keyboardAsk != old.keyboardAsk && !widget.findOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final id = c.activeWindow?.activePaneId;
        if (id == null) return;
        _paneFocus[id]?.requestFocus();
        // A phone's on-screen keyboard (nothing on a computer).
        _paneViews[id]?.$2.currentState?.requestKeyboard();
      });
    }
    if (widget.findOpen && old.findOpen && widget.findAsk != old.findAsk) {
      _findFocus.requestFocus();
    } else if (old.findOpen && !widget.findOpen) {
      // Closed: the keyboard back to the pane in front.
      final id = c.activeWindow?.activePaneId;
      if (id != null) _paneFocus[id]?.requestFocus();
    }
  }

  @override
  void dispose() {
    c.removeListener(_onChanged);
    for (final ctrl in _paneCtrls.values) {
      ctrl.dispose();
    }
    for (final f in _paneFocus.values) {
      f.dispose();
    }
    _findFocus.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    _pruneStale();
    _focusActivePane();
  }

  void _pruneStale() {
    final live = <String>{
      for (final w in c.windows) ...w.panes.keys,
    };
    for (final id in _paneCtrls.keys.where((k) => !live.contains(k)).toList()) {
      _paneCtrls.remove(id)?.dispose();
      _paneFocus.remove(id)?.dispose();
    }
    _paneViews.removeWhere((id, _) => !live.contains(id));
  }

  /// Keyboard focus follows tmux's active pane of the active window, once
  /// per change (never reactively every build, which fights the user).
  void _focusActivePane() {
    final id = c.activeWindow?.activePaneId;
    if (id == null || id == _focusedPane) return;
    _focusedPane = id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final node = _paneFocus[id];
      if (node != null && !node.hasFocus) node.requestFocus();
    });
  }

  TerminalController _ctrl(String paneId) =>
      _paneCtrls.putIfAbsent(paneId, TerminalController.new);

  FocusNode _focus(String paneId) =>
      _paneFocus.putIfAbsent(paneId, () => FocusNode(debugLabel: 'tmux $paneId'));

  /// A pane's view key: its own while the pane keeps its terminal, a new one
  /// (a new view) for a new terminal, as the pane's id and terminal keyed it.
  GlobalKey<TerminalViewState> _view(String paneId, Terminal terminal) {
    final had = _paneViews[paneId];
    if (had != null && identical(had.$1, terminal)) return had.$2;
    final key = GlobalKey<TerminalViewState>(debugLabel: 'tmux view $paneId');
    _paneViews[paneId] = (terminal, key);
    return key;
  }

  TerminalCursorType _cursorType(TerminalCursorShape shape) {
    switch (shape) {
      case TerminalCursorShape.block:
        return TerminalCursorType.block;
      case TerminalCursorShape.underline:
        return TerminalCursorType.underline;
      case TerminalCursorShape.verticalBar:
        return TerminalCursorType.verticalBar;
    }
  }

  // ── Actions ──

  Future<void> _renameWindow(TmuxWindow w) async {
    final l10n = AppLocalizations.of(context)!;
    final name = await showZestInputDialog(
      context: context,
      title: l10n.tmuxRenameWindow,
      fieldLabel: l10n.tmuxRenameWindowHint,
      initialValue: w.name,
      confirmLabel: l10n.save,
    );
    if (name == null || name.trim().isEmpty) return;
    await c.renameWindow(w.id, name.trim());
  }

  Future<void> _closeWindow(TmuxWindow w) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      // (A host sets the name: masked while recording, as on the pill.)
      title: l10n.tmuxCloseWindowConfirmTitle(Redactable.host(tmuxWindowLabel(w)).displayIn(ref)),
      body: l10n.tmuxCloseWindowConfirmBody,
      confirmLabel: l10n.tmuxCloseWindow,
    );
    if (ok != true) return;
    await c.closeWindow(w.id);
  }

  Future<void> _closePane(TmuxWindow w, String paneId) async {
    final l10n = AppLocalizations.of(context)!;
    if (w.panes.length == 1) return _closeWindow(w);
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.tmuxClosePaneConfirmTitle,
      body: l10n.tmuxClosePaneConfirmBody,
      confirmLabel: l10n.tmuxClosePane,
    );
    if (ok != true) return;
    await c.closePane(paneId);
  }

  Future<void> _showTabMenu(TmuxWindow w, Offset at) async {
    final l10n = AppLocalizations.of(context)!;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        at & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      color: AppColors.v3Surface,
      items: [
        PopupMenuItem(
          enabled: false,
          height: 26,
          child: _MenuSectionLabel(l10n.tmuxMenuWindow(tmuxWindowLabel(w))),
        ),
        PopupMenuItem(
          value: 'rename',
          height: 38,
          child: _MenuRow(LucideIcons.pencil, l10n.tmuxRenameWindow),
        ),
        PopupMenuItem(
          value: 'close',
          height: 38,
          child: _MenuRow(
            LucideIcons.trash2,
            l10n.tmuxCloseWindow,
            destructive: true,
            trailing: l10n.tmuxPaneCount(w.panes.length),
          ),
        ),
      ],
    );
    if (!mounted) return;
    switch (v) {
      case 'rename':
        _renameWindow(w);
      case 'close':
        _closeWindow(w);
    }
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final active = c.activeWindow;
    final finding = widget.findOpen ? active?.panes[active.activePaneId] : null;
    return Column(
      children: [
        _strip(l10n),
        if (finding != null)
          TerminalSearchBar(
            terminal: finding.terminal,
            controller: _ctrl(finding.id),
            theme: ref.watch(hostTerminalThemeProvider(widget.connectionId)),
            focusNode: _findFocus,
            onShowLine: (line) => _paneViews[finding.id]?.$2.currentState?.scrollToLine(line),
            onClose: () => widget.onFindClose?.call(),
          ),
        Expanded(child: active == null ? _status(l10n) : _paneArea()),
      ],
    );
  }

  Widget _status(AppLocalizations l10n) {
    final String text;
    switch (c.phase) {
      case TmuxPhase.waiting:
      case TmuxPhase.connecting:
        text = l10n.tmuxConnecting;
      case TmuxPhase.syncing:
        text = l10n.tmuxSyncing;
      case TmuxPhase.ready:
        text = l10n.tmuxNoSessionsYet;
      case TmuxPhase.exited:
        // Why, in the app's language where it is known (tmux's own words
        // were shown as they were).
        final why = c.exitReason == null ? null : tmuxSaid(l10n, c.exitReason!);
        text = why == null ? l10n.tmuxUiSessionEnded : '${l10n.tmuxUiSessionEnded} $why';
    }
    final busy = c.phase != TmuxPhase.exited && c.phase != TmuxPhase.ready;
    return ColoredBox(
      color: ref.watch(hostTerminalThemeProvider(widget.connectionId)).background,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(LucideIcons.layoutGrid, size: 32, color: AppColors.v3TextTertiary),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.v3TextSecondary, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  // ── Window strip ──

  Widget _strip(AppLocalizations l10n) {
    final desktop = isDesktopPlatform;
    final windows = c.windows;
    final active = c.activeWindow;
    return Container(
      height: desktop ? 38 : 46,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppColors.v3Surface,
        border: Border(bottom: BorderSide(color: AppColors.v3BorderSubtle)),
      ),
      child: Row(
        children: [
          // The session is a breadcrumb: it orients, it never competes with
          // the one accent owner in this strip (the active window).
          _sessionCrumb(l10n),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              '/',
              style: TextStyle(fontSize: 12, color: AppColors.v3TextDisabled),
            ),
          ),
          Expanded(
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                dragDevices: {PointerDeviceKind.touch, PointerDeviceKind.mouse},
                scrollbars: false,
              ),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(vertical: 6),
                itemCount: windows.length + (c.exited ? 0 : 1),
                separatorBuilder: (_, _) => const SizedBox(width: 2),
                itemBuilder: (context, i) {
                  if (i == windows.length) {
                    return _StripIconButton(
                      icon: LucideIcons.plus,
                      tooltip: l10n.tmuxNewWindow,
                      onTap: () => c.newWindow(),
                    );
                  }
                  final w = windows[i];
                  return _WindowPill(
                    window: w,
                    label: Redactable.host(tmuxWindowLabel(w)).displayIn(ref),
                    // The pane's title is the host's text too (often user@host: folder).
                    tooltip: w.activePane?.title == null ? '' : Redactable.host(w.activePane!.title).displayIn(ref),
                    isActive: w.id == c.activeWindowId,
                    l10n: l10n,
                    onTap: () => c.selectWindow(w.id),
                    onClose: () => _closeWindow(w),
                    onContextMenu: (at) => _showTabMenu(w, at),
                  );
                },
              ),
            ),
          ),
          if (active != null && !c.exited) _paneMenuButton(l10n, active),
          if (widget.onExitRequested != null)
            _StripTextButton(
              icon: LucideIcons.logOut,
              label: l10n.tmuxExitControl,
              onTap: widget.onExitRequested!,
            )
          else if (widget.onDetach != null)
            _StripTextButton(
              icon: LucideIcons.unplug,
              label: l10n.tmuxDetach,
              tooltip: l10n.tmuxDetachHelp,
              onTap: widget.onDetach!,
            ),
        ],
      ),
    );
  }

  Widget _sessionCrumb(AppLocalizations l10n) {
    final name = c.currentSessionName;
    final label = name == null ? 'tmux' : Redactable.host(name).displayIn(ref);
    return PopupMenuButton<String>(
      tooltip: l10n.tmuxSessionsMenu,
      enabled: !c.exited,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      color: AppColors.v3Surface,
      onSelected: (v) => handleTmuxSessionsMenu(context, ref, c, v,
          onDetach: widget.onDetach),
      itemBuilder: (context) => tmuxSessionsMenuItems(l10n, ref, c),
      child: _HoverPad(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.layoutGrid, size: 12,
                color: AppColors.v3TextTertiary.withValues(alpha: 0.8)),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: AppColors.v3TextTertiary),
              ),
            ),
            const SizedBox(width: 3),
            Icon(LucideIcons.chevronDown, size: 12, color: AppColors.v3TextTertiary),
          ],
        ),
      ),
    );
  }

  /// The pane / window menu, opened from the strip's kebab and from a
  /// right-click on a pane divider. Two labelled scopes; both destructive
  /// entries in the error colour; Close window states its blast radius.
  List<PopupMenuEntry<String>> _paneMenuItems(
      AppLocalizations l10n, TmuxWindow w) {
    return [
      PopupMenuItem(
        enabled: false,
        height: 26,
        child: _MenuSectionLabel(l10n.tmuxMenuPane),
      ),
      PopupMenuItem(
        value: 'split-right',
        height: 38,
        child: _MenuRow(LucideIcons.panelRight, l10n.tmuxSplitPaneRight),
      ),
      PopupMenuItem(
        value: 'split-down',
        height: 38,
        child: _MenuRow(LucideIcons.panelBottom, l10n.tmuxSplitPaneDown),
      ),
      PopupMenuItem(
        value: 'zoom',
        height: 38,
        child: _MenuRow(
          w.zoomed ? LucideIcons.minimize2 : LucideIcons.maximize2,
          w.zoomed ? l10n.tmuxUnzoomPane : l10n.tmuxZoomPane,
        ),
      ),
      PopupMenuItem(
        value: 'close-pane',
        height: 38,
        child: _MenuRow(LucideIcons.x, l10n.tmuxClosePane, destructive: true),
      ),
      const PopupMenuDivider(height: 1),
      PopupMenuItem(
        enabled: false,
        height: 26,
        child: _MenuSectionLabel(l10n.tmuxMenuWindow(tmuxWindowLabel(w))),
      ),
      PopupMenuItem(
        value: 'rename',
        height: 38,
        child: _MenuRow(LucideIcons.pencil, l10n.tmuxRenameWindow),
      ),
      PopupMenuItem(
        value: 'close-window',
        height: 38,
        child: _MenuRow(
          LucideIcons.trash2,
          l10n.tmuxCloseWindow,
          destructive: true,
          trailing: l10n.tmuxPaneCount(w.panes.length),
        ),
      ),
    ];
  }

  void _onPaneMenu(TmuxWindow w, String v) {
    final paneId = w.activePaneId;
    switch (v) {
      case 'split-right':
        if (paneId != null) c.splitPane(paneId, horizontal: true);
      case 'split-down':
        if (paneId != null) c.splitPane(paneId, horizontal: false);
      case 'zoom':
        if (paneId != null) c.toggleZoom(paneId);
      case 'close-pane':
        if (paneId != null) _closePane(w, paneId);
      case 'rename':
        _renameWindow(w);
      case 'close-window':
        _closeWindow(w);
    }
  }

  Widget _paneMenuButton(AppLocalizations l10n, TmuxWindow w) {
    return PopupMenuButton<String>(
      tooltip: l10n.tmuxWindowActions,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      color: AppColors.v3Surface,
      onSelected: (v) => _onPaneMenu(w, v),
      itemBuilder: (context) => _paneMenuItems(l10n, w),
      child: const _StripIconButton(icon: LucideIcons.moreVertical),
    );
  }

  Future<void> _showPaneMenuAt(TmuxWindow w, Offset at) async {
    final l10n = AppLocalizations.of(context)!;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        at & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      color: AppColors.v3Surface,
      items: _paneMenuItems(l10n, w),
    );
    if (!mounted || v == null) return;
    _onPaneMenu(w, v);
  }

  // ── Panes ──

  Widget _paneArea() {
    final theme = ref.watch(hostTerminalThemeProvider(widget.connectionId));
    final style = ref.watch(terminalStyleProvider);
    final cursorType = _cursorType(ref.watch(cursorStyleProvider));
    final cursorBlink = ref.watch(cursorBlinkProvider);
    _cursorShown = ref.watch(cursorVisibilityProvider);
    _keyboardLearns = !ref.watch(keyboardIncognitoProvider);
    _compactKeyboard = ref.watch(compactKeyboardProvider);
    _bindings = isDesktopPlatform ? ref.watch(shortcutBindingsProvider) : null;
    final scaler = MediaQuery.textScalerOf(context);
    final key = (style.fontFamily, style.fontSize, scaler);
    if (_cellKey != key) {
      _cellKey = key;
      _cell = measureTerminalCell(style, scaler);
    }
    final cell = _cell;
    // Same breathing room as the main terminal pane.
    final inset = ref.watch(terminalMarginProvider);
    return ColoredBox(
      color: theme.background,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cols = ((constraints.maxWidth - inset * 2) / cell.width).floor();
          final rows = ((constraints.maxHeight - inset * 2) / cell.height).floor();
          // Tell tmux the client's size in cells; deduped in the controller.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) c.setClientSize(cols, rows);
          });
          // Every window stays mounted (offstage when not current), so a tab
          // switch is a visibility flip rather than a rebuild of the pane
          // views: instant, and scroll positions survive.
          return Padding(
            padding: EdgeInsets.all(inset),
            child: ClipRect(
              child: Stack(
                children: [
                  for (final w in c.windows)
                    Offstage(
                      key: ValueKey('tmux-window-${w.id}'),
                      offstage: w.id != c.activeWindowId,
                      child: _windowPanes(
                          w, cell, theme, style, scaler, cursorType, cursorBlink),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _windowPanes(
    TmuxWindow win,
    Size cell,
    TerminalTheme theme,
    TerminalStyle style,
    TextScaler scaler,
    TerminalCursorType cursorType,
    bool cursorBlink,
  ) {
    final layout = win.renderLayout;
    final children = <Widget>[];
    if (layout == null) {
      final pane = win.activePane;
      if (pane != null) {
        children.add(Positioned.fill(
          child: _pane(win, pane, theme, style, scaler, cursorType, cursorBlink),
        ));
      }
    } else {
      _collect(layout, win, cell, theme, style, scaler, cursorType, cursorBlink,
          children);
    }
    return Stack(children: children);
  }

  /// Panes are placed at their tmux cell coordinates scaled by the measured
  /// cell size, so the mirror is pixel-exact; the one-cell gaps tmux leaves
  /// between panes get a hairline divider.
  void _collect(
    TmuxLayoutNode node,
    TmuxWindow win,
    Size cell,
    TerminalTheme theme,
    TerminalStyle style,
    TextScaler scaler,
    TerminalCursorType cursorType,
    bool cursorBlink,
    List<Widget> out,
  ) {
    if (node is TmuxPaneNode) {
      final pane = win.panes[node.paneId];
      if (pane == null) return;
      out.add(Positioned(
        left: node.x * cell.width,
        top: node.y * cell.height,
        width: node.width * cell.width,
        height: node.height * cell.height,
        child: _pane(win, pane, theme, style, scaler, cursorType, cursorBlink),
      ));
      return;
    }
    final split = node as TmuxSplitNode;
    for (var i = 0; i < split.children.length; i++) {
      final child = split.children[i];
      _collect(child, win, cell, theme, style, scaler, cursorType, cursorBlink, out);
      if (i < split.children.length - 1) {
        // The gap cell after this child, spanning the split's extent.
        // The whole gap cell is the hit target (a right-click opens the
        // pane / window menu); the hairline sits in its middle.
        if (split.horizontal) {
          final gapX = (child.x + child.width) * cell.width;
          out.add(Positioned(
            left: gapX,
            top: split.y * cell.height,
            width: cell.width,
            height: split.height * cell.height,
            child: _Divider(
              vertical: true,
              onContextMenu: (at) => _showPaneMenuAt(win, at),
            ),
          ));
        } else {
          final gapY = (child.y + child.height) * cell.height;
          out.add(Positioned(
            left: split.x * cell.width,
            top: gapY,
            width: split.width * cell.width,
            height: cell.height,
            child: _Divider(
              vertical: false,
              onContextMenu: (at) => _showPaneMenuAt(win, at),
            ),
          ));
        }
      }
    }
  }

  Widget _pane(
    TmuxWindow win,
    TmuxPane pane,
    TerminalTheme theme,
    TerminalStyle style,
    TextScaler scaler,
    TerminalCursorType cursorType,
    bool cursorBlink,
  ) {
    final isActive = win.activePaneId == pane.id;
    final multi = win.panes.length > 1 && !win.zoomed;
    final terminal = pane.terminal;
    final ctrl = _ctrl(pane.id);
    Widget view = TerminalView(
      terminal,
      key: _view(pane.id, terminal),
      controller: ctrl,
      focusNode: _focus(pane.id),
      theme: theme,
      textStyle: style,
      textScaler: scaler,
      padding: EdgeInsets.zero,
      // The pane's size is tmux's business (the layout), never the
      // widget's: the terminal is resized from the layout tree.
      autoResize: false,
      autofocus: false,
      cursorType: cursorType,
      cursorBlink: cursorBlink,
      // As the session's own terminal: a program's hide request obeyed, and
      // the person's choice of when the cursor is drawn (4.0).
      alwaysShowCursor: false,
      hideCursor: _cursorShown == TerminalCursorVisibility.never,
      hideCursorWhileOutput: _cursorShown == TerminalCursorVisibility.notDuringOutput,
      // A computer's keys alone; on a phone and a tablet the on-screen
      // keyboard too, as the session's own terminal has it there (a test
      // draws a phone's: isTouchLayout).
      hardwareKeyboardOnly: !isTouchLayout,
      // As the phone's own terminal: a deletion with the on-screen keyboard
      // seen as one wherever the field is empty (Android), and a tap that
      // brings no keyboard up while a hardware one is typed on.
      deleteDetection: true,
      keyboardOnTap: ref.watch(hardwareKeyboardUseProvider).keyboardOnTap,
      onKeyboardInput: () => ref.read(hardwareKeyboardUseProvider.notifier).softText(),
      personalizedLearning: _keyboardLearns,
      // The keyboard without suggestions where its person chose it, else the
      // widget's own, as it was.
      keyboardType: _compactKeyboard ? TextInputType.visiblePassword : TextInputType.emailAddress,
      // Option (Alt) as Meta, as Settings has it.
      altIsMeta: ref.watch(optionAsMetaProvider),
      enableUrlDetection: true,
      // A terminal's own keys, as every terminal has them (terminalKeys).
      shortcuts: terminalKeys(
        paste: () => pasteClipboardIntoTerminal(context, ref, terminal),
        bindings: _bindings,
        selected: () => ctrl.selection != null,
      ),
      // What the keyboard commits from its clipboard is a paste too.
      onKeyboardPaste: (text) => pasteTextIntoTerminal(context, ref, terminal, text),
      onSecondaryTapUp: (details, offset) {
        // Right-click paste, gated by the setting, at the release of the
        // button (same as the main terminal, and for its reason).
        if (!ref.read(desktopRightClickPasteProvider)) return;
        pasteClipboardIntoTerminal(context, ref, terminal);
      },
      onTertiaryTapUp: (details, offset) {
        // X11-style middle-click paste, gated by its own setting, at the
        // release too.
        if (!ref.read(desktopMiddleClickPasteProvider)) return;
        pasteClipboardIntoTerminal(context, ref, terminal);
      },
    );
    // Named by the pane and its terminal, as the view was before it had a key
    // of its own (Find's).
    view = KeyedSubtree(key: ValueKey('tmux-pane-${pane.id}-${terminal.hashCode}'), child: view);
    // To a screen reader, as a session's own terminal (4.0 accessibility):
    // one node named for its window, its new lines read out (the pane in
    // front only), and Read the screen.
    view = TerminalReadAloud(
      terminal: terminal,
      name: tmuxWindowLabel(win),
      speaks: isActive,
      onActivate: () {
        _focus(pane.id).requestFocus();
        if (isTouchLayout) _view(pane.id, terminal).currentState?.requestKeyboard();
      },
      child: view,
    );
    if (isDesktopPlatform) {
      view = DesktopDropTarget(
        onFilesDropped: (paths) {
          // Never into a pane the Support Hub lies over.
          if (ref.read(supportHubOpenProvider)) return;
          typeDroppedPaths(context, terminal, paths);
        },
        onTextDropped: (text) {
          final sanitized = CommandText.withoutControlCharacters(text);
          if (sanitized.isNotEmpty) terminal.textInput(sanitized);
        },
        child: view,
      );
    }
    return Listener(
      // onPointerDown (not a GestureDetector) so it doesn't compete with the
      // TerminalView's own tap handling for focus/selection.
      onPointerDown: (e) {
        _copyOnRelease.down(e);
        c.selectPane(win.id, pane.id);
        _focusedPane = pane.id;
        _focus(pane.id).requestFocus();
      },
      // PuTTY-style copy on highlight, a mouse's alone: never on a
      // right-click release, which is the paste gesture, nor as a finger
      // lifts (it took a phone's selection away as it was made).
      onPointerUp: (e) {
        if (!_copyOnRelease.up(e)) return;
        copySelectionIfEnabled(ref, terminal, ctrl);
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(
            color: multi && isActive
                ? AppColors.v3AccentPrimary.withValues(alpha: 0.7)
                : Colors.transparent,
            width: 1,
          ),
        ),
        child: view,
      ),
    );
  }
}

// ── Strip widgets ─────────────────────────────────────────────────────────

/// One window tab. Only the ACTIVE tab carries the accent (a brand wash and
/// a hairline brand border); the rest are the same component at rest, so a
/// sibling reads as a sibling, never as disabled. The dot after the label is
/// the window's state: dim when idle, accent on activity, warning on a bell.
class _WindowPill extends StatefulWidget {
  final TmuxWindow window;
  final String label;
  final String tooltip;
  final bool isActive;
  final AppLocalizations l10n;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final void Function(Offset at) onContextMenu;

  const _WindowPill({
    required this.window,
    required this.label,
    required this.tooltip,
    required this.isActive,
    required this.l10n,
    required this.onTap,
    required this.onClose,
    required this.onContextMenu,
  });

  @override
  State<_WindowPill> createState() => _WindowPillState();
}

class _WindowPillState extends State<_WindowPill> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final w = widget.window;
    final active = widget.isActive;
    final l10n = widget.l10n;
    final accent = AppColors.v3AccentPrimary;
    final Color dot;
    final String dotTip;
    if (w.hasBell) {
      dot = AppColors.v3Warning;
      dotTip = l10n.tmuxBellBadge;
    } else if (w.hasActivity) {
      dot = accent;
      dotTip = l10n.tmuxActivityBadge;
    } else {
      dot = active ? AppColors.v3AccentSecondary : AppColors.v3TextDisabled;
      dotTip = '';
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Listener(
        onPointerDown: (e) {
          if (e.buttons == kMiddleMouseButton) widget.onClose();
        },
        // No onDoubleTap here: a double-tap recognizer makes every single
        // tap wait out the double-tap window, which reads as a laggy tab.
        child: GestureDetector(
          onTap: widget.onTap,
          onSecondaryTapUp: (d) => widget.onContextMenu(d.globalPosition),
          onLongPressStart: (d) => widget.onContextMenu(d.globalPosition),
          child: Tooltip(
            message: widget.tooltip,
            waitDuration: const Duration(milliseconds: 600),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              constraints: const BoxConstraints(maxWidth: 220),
              decoration: BoxDecoration(
                color: active
                    ? accent.withValues(alpha: 0.07)
                    : _hovering
                        ? AppColors.v3Hover
                        : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: active
                      ? accent.withValues(alpha: 0.30)
                      : Colors.transparent,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${w.index}',
                    style: TextStyle(
                      fontSize: 10,
                      fontFamily: 'JetBrainsMono',
                      color: active
                          ? AppColors.v3AccentSecondary
                          : AppColors.v3TextDisabled,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      widget.label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: active ? FontWeight.w500 : FontWeight.w400,
                        color: active
                            ? AppColors.v3TextPrimary
                            : AppColors.v3TextSecondary,
                      ),
                    ),
                  ),
                  if (w.zoomed) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: l10n.tmuxZoomedBadge,
                      child: Icon(LucideIcons.maximize2,
                          size: 10, color: AppColors.v3TextTertiary),
                    ),
                  ],
                  const SizedBox(width: 7),
                  Tooltip(
                    message: dotTip,
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                    ),
                  ),
                  const SizedBox(width: 4),
                  // A close of its own, as a browser's tab has: on the active
                  // tab, and on another while the pointer is over it (only
                  // menus and a middle-click closed a window before).
                  // Its room is kept, so a tab does not grow
                  // under the pointer.
                  IgnorePointer(
                    ignoring: !(active || _hovering),
                    child: Opacity(
                      opacity: active || _hovering ? 1 : 0,
                      child: Tooltip(
                        message: l10n.tmuxCloseWindow,
                        child: GestureDetector(
                          key: ValueKey('tmux-window-close-${w.id}'),
                          behavior: HitTestBehavior.opaque,
                          onTap: widget.onClose,
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: Icon(LucideIcons.x, size: 11, color: AppColors.v3TextTertiary),
                          ),
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
}

/// Transparent hover surface for the breadcrumb.
class _HoverPad extends StatefulWidget {
  final Widget child;
  const _HoverPad({required this.child});

  @override
  State<_HoverPad> createState() => _HoverPadState();
}

class _HoverPadState extends State<_HoverPad> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: _hovering ? AppColors.v3Hover : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: widget.child,
      ),
    );
  }
}

class _StripIconButton extends StatefulWidget {
  final IconData icon;
  final String? tooltip;
  final VoidCallback? onTap;
  const _StripIconButton({required this.icon, this.tooltip, this.onTap});

  @override
  State<_StripIconButton> createState() => _StripIconButtonState();
}

class _StripIconButtonState extends State<_StripIconButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    Widget child = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          width: 28,
          height: 26,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: _hovering ? AppColors.v3Hover : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(
            widget.icon,
            size: 15,
            color: _hovering ? AppColors.v3TextPrimary : AppColors.v3TextTertiary,
          ),
        ),
      ),
    );
    if (widget.tooltip != null) {
      child = Tooltip(message: widget.tooltip!, child: child);
    }
    return child;
  }
}

class _StripTextButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final String? tooltip;
  final VoidCallback onTap;
  const _StripTextButton({
    required this.icon,
    required this.label,
    this.tooltip,
    required this.onTap,
  });

  @override
  State<_StripTextButton> createState() => _StripTextButtonState();
}

class _StripTextButtonState extends State<_StripTextButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    Widget child = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          height: 26,
          margin: const EdgeInsets.only(left: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: _hovering ? AppColors.v3Hover : AppColors.v3Elevated,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.v3BorderSubtle),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 12, color: AppColors.v3TextSecondary),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 12,
                  color: _hovering
                      ? AppColors.v3TextPrimary
                      : AppColors.v3TextSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (widget.tooltip != null) {
      child = Tooltip(message: widget.tooltip!, child: child);
    }
    return child;
  }
}

/// Mono, uppercase scope label inside a menu ("PANE", "WINDOW "BASH"").
class _MenuSectionLabel extends StatelessWidget {
  final String text;
  const _MenuSectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontFamily: 'JetBrainsMono',
        fontSize: 10,
        letterSpacing: 0.8,
        color: AppColors.v3TextTertiary,
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;

  /// Destructive entries render in the error colour so they never read as
  /// routine list items.
  final bool destructive;

  /// Blast radius or shortcut hint, mono and dim, right-aligned.
  final String? trailing;

  const _MenuRow(this.icon, this.label,
      {this.subtitle, this.destructive = false, this.trailing});

  @override
  Widget build(BuildContext context) {
    final color = destructive ? AppColors.v3Error : AppColors.v3TextPrimary;
    final iconColor = destructive ? AppColors.v3Error : AppColors.v3TextSecondary;
    return Row(
      children: [
        Icon(icon, size: 14, color: iconColor),
        const SizedBox(width: 10),
        Expanded(
          child: subtitle == null
              ? Text(label, style: TextStyle(fontSize: 13, color: color))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label, style: TextStyle(fontSize: 13, color: color)),
                    Text(subtitle!,
                        style: TextStyle(
                            fontSize: 11, color: AppColors.v3TextTertiary)),
                  ],
                ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 12),
          Text(
            trailing!,
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 10,
              color: AppColors.v3TextDisabled,
            ),
          ),
        ],
      ],
    );
  }
}

/// The one-cell gap tmux leaves between panes: a hairline in the middle,
/// and a right-click target for the pane / window menu.
class _Divider extends StatelessWidget {
  final bool vertical;
  final void Function(Offset at) onContextMenu;
  const _Divider({required this.vertical, required this.onContextMenu});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (d) => onContextMenu(d.globalPosition),
      onLongPressStart: (d) => onContextMenu(d.globalPosition),
      child: Center(
        child: Container(
          width: vertical ? 1 : double.infinity,
          height: vertical ? double.infinity : 1,
          color: AppColors.v3BorderSubtle,
        ),
      ),
    );
  }
}
