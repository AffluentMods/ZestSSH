import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/theme/ui_density.dart' show mouseExtrasProvider, touchSizedAt;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/features/hosts/widgets/host_card.dart' show TmuxSessionsBadge;
import 'package:zestssh/features/notifications/widgets/notification_bell.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart' show orchardSummariesProvider;
import 'package:zestssh/features/orchards/spaces.dart' show kOrchardsEnabled;
import 'package:zestssh/features/orchards/tab_sources.dart';
import 'package:zestssh/features/sharing/share_providers.dart';
import 'package:zestssh/features/sharing/share_viewer.dart';
import 'package:zestssh/ui/screens/sharing/share_invitations.dart';
import 'package:zestssh/features/tickets/ticket_service.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/features/tmux/tmux_session_counts.dart';
import 'package:zestssh/providers/saved_tab_groups_provider.dart';
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/providers/shortcut_overrides_provider.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/drag_ghost.dart';
import 'package:zestssh/ui/widgets/middle_ellipsis_text.dart';
import 'package:zestssh/ui/widgets/update_pill.dart';
import 'package:zestssh/ui/widgets/window_bar.dart';
import 'package:zestssh/ui/widgets/title_bar_double_click.dart';
import 'package:zestssh/ui/widgets/window_drag_area.dart';
import 'package:zestssh/theme/desktop_dimensions.dart';
import 'package:zestssh/ui/screens/desktop/widgets/tree_selector.dart';
import 'package:zestssh/ui/screens/desktop/widgets/session_chrome.dart' show FilesOnlyTag, ScreenTag;
import 'package:zestssh/ui/widgets/session_status_mark.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/window_service.dart';

/// Resolved at access time. Top-level `final ... = AppColors.v3X`
/// would snapshot the charcoal default at library load and never
/// update when the user picks a different app theme.
Color get _pillBarBackground => AppColors.v3ChromeBg;

/// The title bar (3.0).
///
/// ```
/// [space v] [Hosts] | [tab] [tab] [+]   [Broadcasting to 3] [Update available] [Search Ctrl+Shift+K] [bell] [REC] [?] [_ [] x]
/// ```
///
/// SFTP, Layout and the Inspector live in the session header; creating a host
/// lives on the Hosts page; Settings lives in the rail. The broadcast chip only
/// shows while typing goes to several terminals. Height: 48px.
class PillBar extends ConsumerWidget {
  final NavSection activeNav;
  final String? activeSessionId;
  final List<MapEntry<String, SessionState>> sessions;
  final ValueChanged<NavSection> onNavChanged;
  final ValueChanged<String> onSessionSelected;
  final ValueChanged<String> onSessionClosed;
  final VoidCallback onNewSession;
  final VoidCallback onCommandPalette;
  /// Toggles the docked Help panel.
  final VoidCallback onHelp;

  /// A session tab's tmux badge was clicked: open tmux in that session.
  final ValueChanged<String>? onOpenTmux;

  /// Called when a context-menu action is selected on a session tab.
  /// The action string is one of: reconnect, duplicate, close, closeOthers,
  /// closeAll.
  final void Function(String sessionId, String action)? onTabAction;

  /// A tab was dropped on the edge of another: it should stand right before
  /// [besideTabId], or right after it. The tabs are named by their ids, never
  /// by their place in the strip: the strip shows pinned tabs first and
  /// leaves out the ones being closed, so a place in it is not a place in
  /// the list of tabs.
  final void Function(String tabId, String besideTabId, bool after)? onTabMove;

  /// A tab was dropped onto the middle of another tab: the source tab's
  /// panes should join the destination tab's.
  final void Function(String sourceTabId, String destTabId)? onTabMerge;

  /// A terminal pane (identified by its `leafId`) was dragged from the terminal
  /// area onto the middle of a tab: that pane's session should join the tab's
  /// group.
  final void Function(String leafId, String destTabId)? onLeafMoveToTab;

  /// A terminal pane was dragged out of its group: its session should become
  /// a tab of its own, right before [besideTabId] or right after it when it
  /// was dropped on that tab's edge, and at the end of the strip when it was
  /// dropped on the open space (no [besideTabId]).
  final void Function(String leafId, String? besideTabId, bool after)? onLeafPopOut;

  /// Per-tab group size: how many sessions are merged into the tab.
  /// Keyed by the same id used in [sessions] (the tab id). No longer drawn
  /// as a numeric badge (§8 - the pane count is encoded once, via the tab
  /// title's `+n`); still used for context-menu bookkeeping.
  final Map<String, int> tabGroupSizes;

  /// Per-tab identity colours, in pane order, already resolved through the
  /// host → group → neutral fallback (§3). A single entry paints a solid
  /// identity bar; two or more distinct colours paint a segmented bar. Keyed
  /// by tab id. Resolved live by the shell (watching connections + groups),
  /// so recolouring a host or its group repaints the open tab with no
  /// reconnect.
  final Map<String, List<Color>> tabIdentityColors;

  /// Set of tab ids the user has pinned. Pinned tabs render a pin
  /// glyph and (per the parent's sort order) live at the front of the
  /// pill strip. The set is treated as opaque - only contains-checks
  /// are done here.
  final Set<String> pinnedTabIds;

  /// Whether the window shows a terminal now, as the shell decides it: a tab
  /// can be open with none of its sessions on screen (each popped out, say),
  /// and then the page under it shows. Null: whenever a tab is open.
  final bool? terminalShown;

  /// The bar on a phone's or a tablet's large screen (4.0):
  /// an app bar, touch sized where the controls are, with no
  /// window's controls (and no window to drag), the page's name, and Search,
  /// the bell and Help at its right.
  final bool touch;

  /// Whether the session tabs stand in the bar: on a computer, and on a
  /// tablet held sideways. Upright they are a strip of their own under the
  /// bar ([stripOnly]), while sessions are open.
  final bool tabsInBar;

  /// Only the strip of session tabs, under the bar ([tabsInBar] false).
  final bool stripOnly;

  /// The page's name in a touch screen's app bar, for a page with no title
  /// line of its own (Hosts); null shows the Hosts pill in its place.
  final String? pageTitle;

  const PillBar({
    super.key,
    required this.activeNav,
    this.activeSessionId,
    required this.sessions,
    required this.onNavChanged,
    required this.onSessionSelected,
    required this.onSessionClosed,
    required this.onNewSession,
    required this.onCommandPalette,
    required this.onHelp,
    this.onOpenTmux,
    this.onTabAction,
    this.onTabMove,
    this.onTabMerge,
    this.onLeafMoveToTab,
    this.onLeafPopOut,
    this.tabGroupSizes = const {},
    this.tabIdentityColors = const {},
    this.pinnedTabIds = const {},
    this.terminalShown,
    this.touch = false,
    this.tabsInBar = true,
    this.stripOnly = false,
    this.pageTitle,
  });

  /// The session tabs, in the bar or in a strip of their own.
  Widget _tabStrip(WidgetRef ref, AppLocalizations l10n) => _SessionTabStrip(
        sessions: sessions,
        activeSessionId: activeSessionId,
        onSessionSelected: onSessionSelected,
        onSessionClosed: onSessionClosed,
        onTabAction: onTabAction,
        onTabMove: onTabMove,
        onTabMerge: onTabMerge,
        onLeafMoveToTab: onLeafMoveToTab,
        onLeafPopOut: onLeafPopOut,
        tabGroupSizes: tabGroupSizes,
        tabIdentityColors: tabIdentityColors,
        pinnedTabIds: pinnedTabIds,
        hasWorkspaces: ref.watch(savedTabGroupsProvider).isNotEmpty,
        sshTabIds: {
          for (final tab in ref.watch(workTabsProvider).tabs)
            if (sshToolsSessionOf(tab, ref.watch(activeSessionsProvider)) != null) tab.id,
        },
        tmuxCounts: ref.watch(tmuxSessionCountsProvider),
        onOpenTmux: onOpenTmux,
        tabSources: _tabSources(ref, l10n),
        filesOnlyIds: ref.watch(filesOnlySessionsProvider),
        screenIds: ref.watch(screenSessionsProvider),
        // Live shortcut bindings so the context menu's right-aligned
        // shortcut column follows the user's rebindings (§4/§5). Watched
        // here → the strip rebuilds on any change, and each menu open
        // reads the current binding.
        bindings: ref.watch(shortcutBindingsProvider),
      );

  /// The strip of session tabs under a touch screen's app bar (upright), with
  /// a New session button at its end.
  Widget _buildStrip(BuildContext context, WidgetRef ref, AppLocalizations l10n) {
    final touchSized = touchSizedAt(context);
    return Container(
      key: const ValueKey('session-tab-strip'),
      height: touchSized ? 56 : 44,
      padding: const EdgeInsets.only(left: 8, right: 4),
      decoration: BoxDecoration(
        color: _pillBarBackground,
        border: Border(bottom: BorderSide(color: AppColors.v3ChromeDivider, width: 1)),
      ),
      child: Row(
        children: [
          Expanded(child: _tabStrip(ref, l10n)),
          const SizedBox(width: 4),
          _PillBarIconButton(
            tooltip: l10n.desktopQuickConnect,
            icon: LucideIcons.plus,
            onTap: onNewSession,
          ),
        ],
      ),
    );
  }

  /// A touch screen's app bar (4.0): the space's switcher, the page's name
  /// (or the Hosts pill over a terminal), the tabs where they stand in the
  /// bar, then Search, the bell and Help. No window's controls: a tablet's
  /// app has no window of its own to move or close.
  Widget _buildTouchBar(BuildContext context, WidgetRef ref, AppLocalizations l10n) {
    final touchSized = touchSizedAt(context);
    final title = pageTitle;
    return Container(
      height: touchSized ? 60 : DesktopDimensions.pillBarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: _pillBarBackground,
        border: Border(bottom: BorderSide(color: AppColors.v3ChromeDivider, width: 1)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            const TreeSelector(),
            const SizedBox(width: 16),
            if (title != null)
              Flexible(
                flex: 0,
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    key: const ValueKey('app-bar-title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary),
                  ),
                ),
              )
            else
              _ContextPill(
                label: l10n.pillHosts,
                isActive: hostsDrawerShown(
                  panelOn: ref.watch(hostPanelVisibleProvider),
                  terminalShown: terminalShown ?? activeSessionId != null,
                  activeNav: activeNav,
                  openedOnHostsPage: ref.watch(hostsDrawerOnHostsPageProvider),
                ),
                onTap: () => ref.read(desktopSettingsUpdaterProvider).toggleHostPanel(),
              ),
            const SizedBox(width: 12),
            if (tabsInBar) Expanded(child: _tabStrip(ref, l10n)) else const Spacer(),
            const SizedBox(width: 8),
            const BroadcastingChip(),
            // Search: the command palette, its keys said where a mouse or a
            // keyboard is at hand (the hint is no use to a finger).
            _CtrlKBadge(
              onTap: onCommandPalette,
              compact: constraints.maxWidth < 700,
              touch: true,
            ),
            const SizedBox(width: 4),
            const NotificationBell(),
            const _SharedSessionsButton(),
            _HelpButton(onTap: onHelp),
          ],
        ),
      ),
    );
  }

  /// Where each tab's host comes from, by tab id, while tabs from more than
  /// one place (a team's vault, or Personal) are open: "Acme · Production
  /// · Databases" (team, vault and the host's group), or "Personal · Web
  /// servers". Empty while they all come from the same place: groups
  /// within Personal alone do not count.
  ///
  /// Settings choose when ([TabSourceMode]) and whether the vault and the
  /// group are in it; Automatic leaves out the vault of a team where this
  /// account opens only one.
  Map<String, String> _tabSources(WidgetRef ref, AppLocalizations l10n) {
    if (!kOrchardsEnabled) return const {};
    final mode = ref.watch(tabSourceModeProvider);
    if (mode == TabSourceMode.off) return const {};
    final withVault = ref.watch(tabSourceVaultProvider);
    final withGroup = ref.watch(tabSourceGroupProvider);
    final summaries = ref.watch(orchardSummariesProvider).valueOrNull ?? const [];
    final names = {for (final o in summaries) o.id: o.name};
    final vaults = {for (final o in summaries) o.id: o.crates.length};
    final out = <String, String>{};
    final places = <(String?, String?)>{};
    for (final s in sessions) {
      final connectionId = s.value.connectionId;
      if (connectionId == null) continue;
      final source = ref.watch(tabSourceProvider(connectionId)).valueOrNull;
      if (source == null) continue;
      final team = source.orchardId;
      places.add((team, source.vaultName));
      final group = withGroup ? source.groupName : null;
      final vault = withVault && !(mode == TabSourceMode.auto && (vaults[team] ?? 0) == 1) ? source.vaultName : null;
      out[s.key] = team == null
          ? [l10n.treeSelectorPersonal, ?group].join(' · ')
          : [names[team] ?? l10n.orchardUnnamed, ?vault, ?group].join(' · ');
    }
    return mode == TabSourceMode.always || places.length > 1 ? out : const {};
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    if (stripOnly) return _buildStrip(context, ref, l10n);
    if (touch) return _buildTouchBar(context, ref, l10n);
    return ValueListenableBuilder<bool>(
      valueListenable: WindowService.fullscreen,
      builder: (context, fullscreen, child) => Container(
        height: DesktopDimensions.pillBarHeight,
        decoration: BoxDecoration(
          color: _pillBarBackground,
          border: Border(
            bottom: BorderSide(color: AppColors.v3ChromeDivider, width: 1),
          ),
        ),
        // macOS keeps its native traffic-light controls at the top-left, so
        // the pill-bar content is inset past them; in native fullscreen the
        // system hides them (they slide in with the menu bar on hover), so
        // the inset goes too instead of leaving a dead gap. Windows/Linux
        // draw their own controls at the far right and need no left inset.
        padding:
            EdgeInsets.only(left: Platform.isMacOS && !fullscreen ? 78 : 8),
        child: child,
      ),
      // The pill bar IS the window title bar now (frameless). Dragging any
      // empty area moves the window; the interactive children (pills, tabs,
      // buttons) still receive their taps normally. Window controls live at
      // the far right (macOS: native traffic lights left, tree selector right).
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Under everything: a double-click on the bar's EMPTY space zooms
          // (or what a Mac is set to do), as a system title bar does; a tab,
          // a pill or a button takes its own clicks first (3.3).
          const Positioned.fill(child: TitleBarDoubleClickLayer()),
          LayoutBuilder(
        builder: (context, constraints) {
          // Collapse the search badge to an icon at narrow widths so the
          // fixed-width right cluster stops overflowing near the app's
          // minimum window width.
          final compactSearch = constraints.maxWidth < 1000;
          return WindowDragArea(
        // Drag any empty area to move the window. We deliberately do NOT use
        // window_manager's DragToMoveArea here: its built-in double-tap toggles
        // maximize/restore on ANY double-click on the bar, a tab's too, which
        // on this dense pill bar fired by accident. A double-click on empty
        // space only is the layer under this ([TitleBarDoubleClickLayer]).
        // WindowDragArea cancels the initiating pointer after handing off to
        // the native drag, so the Win32 modal move loop can't strand it "down".
        child: Row(
        children: [
          // -- Tree selector (left zone) --
          // MUST be inflexible. Wrapping it in Flexible gave it flex:1 -
          // the SAME flex factor as the Expanded session-tab strip below -
          // so RenderFlex split the free horizontal space 50/50 between the
          // two. The tab strip's Expanded only ever received HALF the slack,
          // while the tree selector claimed the other half and used just its
          // content width (~130px), discarding the rest. With
          // mainAxisAlignment.start that discarded space piled up at the far
          // right, shoving the whole right cluster (New/search/bell/settings/
          // help + window controls) inward. Invisible when restored (little
          // slack) but ~600px of dead space once maximized. The tree selector
          // is a fixed-size pill; it should size to content and let the tab
          // strip own ALL the free space.
          //
          // Windows/Linux only: on macOS the native traffic lights own the
          // top-left, so the tree selector moves to the far right (below).
          if (!Platform.isMacOS) const TreeSelector(),
          if (!Platform.isMacOS) const SizedBox(width: 8),

          // -- Context pills --
          // A1: the Hosts pill toggles the slide-out fast-connect panel
          // (reads active while it's open) rather than navigating to the grid.
          _ContextPill(
            label: l10n.pillHosts,
            // The pill opens and closes the fast-connect drawer, so it is lit
            // while the drawer is on screen, not for "am I on the Hosts page"
            // (the sidebar shows that). On the Hosts page, which hides the
            // drawer otherwise, it opens it there for itself (closed again when
            // the page is come back to); elsewhere it switches it on or off.
            isActive: hostsDrawerShown(
              panelOn: ref.watch(hostPanelVisibleProvider),
              terminalShown: terminalShown ?? activeSessionId != null,
              activeNav: activeNav,
              openedOnHostsPage: ref.watch(hostsDrawerOnHostsPageProvider),
            ),
            onTap: () => !(terminalShown ?? activeSessionId != null) && activeNav == NavSection.hosts
                ? ref.read(hostsDrawerOnHostsPageProvider.notifier).toggle()
                : ref.read(desktopSettingsUpdaterProvider).toggleHostPanel(),
          ),

          const SizedBox(width: 12),

          // -- Session tabs --
          Expanded(child: _tabStrip(ref, l10n)),

          const SizedBox(width: 8),

          // -- Right actions --
          // While typing goes to several terminals, say so up here where it
          // cannot be missed; a click stops it. Turning it on lives in the
          // session header's Layout popover (and the palette).
          const BroadcastingChip(),
          // A newer release: "Update available", orange, beside Search and
          // the bell (nothing at all otherwise, and never on a store's build).
          const UpdateAvailablePill(),
          _CtrlKBadge(onTap: onCommandPalette, compact: compactSearch),
          const SizedBox(width: 4),
          // Notification bell + unread badge. Click opens an
          // IntelliJ-style popover with the full notification
          // history. Toasts slide in under it, at the top right;
          // see [NotificationToastOverlay].
          const NotificationBell(),
          const SizedBox(width: 4),
          // Recording mode is a MODE with a persistent control (spec 7c): a
          // dim camera glyph when off, a red REC pill when on.
          const _RecordingToggle(),
          const SizedBox(width: 4),
          const _SharedSessionsButton(),
          _HelpButton(onTap: onHelp),
          const SizedBox(width: 6),
          // Windows/Linux: in-theme window controls (frameless title bar).
          if (!Platform.isMacOS) const WindowControls(),
          // macOS: the native traffic lights (top-left) own window control, so
          // the tree selector takes the top-right slot instead.
          if (Platform.isMacOS) const TreeSelector(),
          if (Platform.isMacOS) const SizedBox(width: 8),
        ],
        ),
          );
        },
          ),
        ],
      ),
    );
  }
}

/// Recording mode's persistent control (spec 7c). Off: a dim camera glyph;
/// on: a red REC pill. Either way a click opens the mode's own menu: the
/// on/off switch, the Layout / Strict level, and what the mode does. This is
/// the one home for these controls (they are no longer in Settings).
class _RecordingToggle extends ConsumerWidget {
  const _RecordingToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(recordingModeProvider);
    final l10n = AppLocalizations.of(context)!;
    final Widget child;
    if (!on) {
      child = _PillBarIconButton(
        tooltip: l10n.recModeTooltipOff,
        icon: LucideIcons.video,
        onTap: () => _showRecordingMenu(context, ref),
      );
    } else {
      // A click opens the recording menu (it said "Click to turn it off").
      child = Tooltip(
        message: l10n.docCheckRecPillTooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => _showRecordingMenu(context, ref),
            child: Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: AppColors.sftpCrit.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: AppColors.sftpCrit.withValues(alpha: 0.5),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: AppColors.sftpCrit,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    l10n.pillRec,
                    style: TextStyle(
                      color: AppColors.sftpCrit,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return child;
  }

  void _showRecordingMenu(BuildContext context, WidgetRef ref) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final offset = box.localToGlobal(Offset.zero);
    final overlayState = Navigator.of(context).overlay;
    if (overlayState == null) return;
    final overlay = overlayState.context.findRenderObject() as RenderBox?;
    if (overlay == null || !overlay.hasSize) return;
    showMenu<void>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(offset.dx, offset.dy + box.size.height + 4, 320, 0),
        Offset.zero & overlay.size,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      color: AppColors.v3Surface,
      constraints: const BoxConstraints(minWidth: 320, maxWidth: 320),
      items: [
        // One live item: its own controls stay interactive while the popup is
        // open (same pattern as the overflow tab picker).
        const PopupMenuItem<void>(
          enabled: false,
          padding: EdgeInsets.zero,
          child: _RecordingMenu(),
        ),
      ],
    );
  }
}

/// The body of the recording-mode popover.
class _RecordingMenu extends ConsumerWidget {
  const _RecordingMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final on = ref.watch(recordingModeProvider);
    final level = ref.watch(recordingRedactLevelProvider);
    final updater = ref.read(settingsUpdaterProvider);
    final shortcut = ref
        .watch(shortcutBindingsProvider)
        .bindingFor(ShortcutAction.toggleRecordingMode)
        ?.displayLabel;
    return DefaultTextStyle.merge(
      style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(LucideIcons.video, size: 15,
                    color: on ? AppColors.sftpCrit : AppColors.v3TextSecondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.settingsInlineRecordingMode,
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600),
                  ),
                ),
                if (shortcut != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      shortcut,
                      style: TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 10,
                        color: AppColors.v3TextDisabled,
                      ),
                    ),
                  ),
                SizedBox(
                  height: 24,
                  child: FittedBox(
                    child: ZestSwitch(value: on, onChanged: (v) => updater.setRecordingMode(v)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              l10n.securityRecordingHelp,
              style: TextStyle(
                  fontSize: 11.5, height: 1.45, color: AppColors.v3TextSecondary),
            ),
            const SizedBox(height: 10),
            RadioGroup<RedactLevel>(
              groupValue: level,
              onChanged: (value) {
                if (value != null) updater.setRecordingRedactLevel(value);
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _LevelRow(
                    key: const ValueKey('rec-level-layout'),
                    value: RedactLevel.layout,
                    label: l10n.recModeLevelLayout,
                    desc: l10n.recModeLevelLayoutDesc,
                    selected: level == RedactLevel.layout,
                    onTap: () => updater.setRecordingRedactLevel(RedactLevel.layout),
                  ),
                  const SizedBox(height: 4),
                  _LevelRow(
                    key: const ValueKey('rec-level-strict'),
                    value: RedactLevel.strict,
                    label: l10n.recModeLevelStrict,
                    desc: l10n.recModeLevelStrictDesc,
                    selected: level == RedactLevel.strict,
                    onTap: () => updater.setRecordingRedactLevel(RedactLevel.strict),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              l10n.securityRecordingNote,
              style: TextStyle(
                  fontSize: 11, height: 1.45, color: AppColors.v3TextTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

/// One level of what recording mode masks. One is picked, so the dot radio
/// the dialogs have, in the RadioGroup around the two (it
/// was a check in a circle, which is for where several can
/// be picked).
class _LevelRow extends StatefulWidget {
  final RedactLevel value;
  final String label;
  final String desc;
  final bool selected;
  final VoidCallback onTap;
  const _LevelRow({
    super.key,
    required this.value,
    required this.label,
    required this.desc,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_LevelRow> createState() => _LevelRowState();
}

class _LevelRowState extends State<_LevelRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.v3AccentPrimary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: widget.selected
                ? accent.withValues(alpha: 0.08)
                : _hovering
                    ? AppColors.v3Hover
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.selected
                  ? accent.withValues(alpha: 0.35)
                  : AppColors.v3BorderSubtle,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: Radio<RedactLevel>(value: widget.value),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.label,
                        style: const TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      widget.desc,
                      style: TextStyle(
                          fontSize: 11, height: 1.4, color: AppColors.v3TextSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ======================================================================
// Brand button - terminal icon in orange, opens command palette
// ======================================================================

class _BrandButton extends ConsumerStatefulWidget {
  final VoidCallback onTap;
  const _BrandButton({required this.onTap});

  @override
  ConsumerState<_BrandButton> createState() => _BrandButtonState();
}

class _BrandButtonState extends ConsumerState<_BrandButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    // Live command-palette binding so the tooltip follows the user's
    // rebinding; null (cleared) drops the parenthetical hint entirely (§4c).
    final accel =
        ref.watch(shortcutBindingProvider(ShortcutAction.commandPalette));
    final l10n = AppLocalizations.of(context)!;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Tooltip(
          message: accel == null
              ? l10n.pillCommandPalette
              : l10n.pillCommandPaletteWithShortcut(accel),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hovering
                  ? AppColors.v3AccentPrimary.withValues(alpha: 0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              LucideIcons.terminal,
              size: 22,
              color: AppColors.v3AccentInk,
            ),
          ),
        ),
      ),
    );
  }
}

// ======================================================================
// Context pill - 32px height rounded pill button
// ======================================================================

class _ContextPill extends StatefulWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _ContextPill({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<_ContextPill> createState() => _ContextPillState();
}

class _ContextPillState extends State<_ContextPill> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: widget.isActive
                ? AppColors.v3AccentPrimary.withValues(alpha: 0.20)
                : _hovering
                    ? AppColors.v3TextPrimary.withValues(alpha: 0.06)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            border: widget.isActive
                ? Border.all(
                    color: AppColors.v3AccentPrimary.withValues(alpha: 0.40),
                    width: 1,
                  )
                : null,
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: widget.isActive ? FontWeight.w600 : FontWeight.w400,
              color: widget.isActive
                  ? AppColors.v3AccentInk
                  : _hovering
                      ? AppColors.v3TextPrimary
                      : AppColors.v3TextSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

// ======================================================================
// Session tab strip - overflow-aware row with drag-reorder + chevron
// ======================================================================

/// Estimated width of a single session tab pill.
const double _kTabEstimatedWidth = 160.0;

/// Width of the overflow chevron button.
const double _kChevronWidth = 32.0;

/// Height of a tab in the strip.
const double _kTabHeight = 36.0;

/// Width of the copy of a tab that follows the pointer while it is dragged.
const double _kTabGhostWidth = _kTabEstimatedWidth;

/// The gap after each tab, which is part of the tab's own box.
const double _kTabGap = 2.0;

/// Corner radius of a tab.
const double _kTabRadius = 6.0;

/// A tab being dragged along the strip, by its id. (A terminal dragged up
/// out of a split is its pane's id, a plain String: `SlimPaneHeader`.)
class _DraggedTab {
  const _DraggedTab(this.tabId);

  final String tabId;
}

/// Where what is dragged over a tab lands when it is let go there. The edges
/// of a tab put it beside that tab, the middle puts it into the tab's group:
/// the same for a tab and for a terminal dragged out of a split.
enum _Landing {
  /// A tab of its own, right before this one.
  before,

  /// A tab of its own, right after this one.
  after,

  /// Into this tab's group.
  join,
}

/// The bar that says where what is dragged will land: beside this tab, on
/// the side it will stand at. It is in the gap between two tabs, the same
/// place whether that is "after this one" or "before the next", and taller
/// than the tabs. It is drawn by the zone at that edge of the tab (or by the
/// last tab, for the strip's open space), at the zone's outer edge.
/// (The bar there was before was two pixels at the tab's left whichever
/// side the tab would land on, and under the tab's body: it was never seen.)
class _LandingBar extends StatelessWidget {
  const _LandingBar({super.key, required this.after});

  /// After the tab; otherwise before it.
  final bool after;

  static const double _width = 3;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 2,
      bottom: 2,
      left: after ? null : -_width,
      right: after ? 0 : null,
      child: IgnorePointer(
        child: Container(
          width: _width,
          decoration: BoxDecoration(
            color: AppColors.v3AccentPrimary,
            borderRadius: BorderRadius.circular(_width / 2),
          ),
        ),
      ),
    );
  }
}

/// The look of a tab that what is dragged will join: the whole tab tinted
/// and outlined. Never together with [_LandingBar]: a drop does the one or
/// the other. It is drawn by the tab's middle zone, the half of the tab
/// between its two edges, [zoneWidth] wide: the tab reaches half of that
/// further on each side, less the gap after it.
class _JoinMark extends StatelessWidget {
  const _JoinMark({super.key, required this.zoneWidth});

  final double zoneWidth;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      bottom: 0,
      left: -zoneWidth / 2,
      right: -zoneWidth / 2 + _kTabGap,
      child: Center(
        child: Container(
          height: _kTabHeight,
          decoration: BoxDecoration(
            color: AppColors.v3AccentPrimary.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(_kTabRadius),
            border: Border.all(color: AppColors.v3AccentPrimary, width: 1.5),
          ),
        ),
      ),
    );
  }
}

class _SessionTabStrip extends StatefulWidget {
  final List<MapEntry<String, SessionState>> sessions;

  /// Where each tab's host comes from ("Acme · Production", "Personal"),
  /// by tab id; empty while every open tab comes from the same place.
  final Map<String, String> tabSources;
  final String? activeSessionId;
  final ValueChanged<String> onSessionSelected;
  final ValueChanged<String> onSessionClosed;
  final void Function(String sessionId, String action)? onTabAction;
  final void Function(String tabId, String besideTabId, bool after)? onTabMove;
  final void Function(String sourceTabId, String destTabId)? onTabMerge;
  final void Function(String leafId, String destTabId)? onLeafMoveToTab;
  final void Function(String leafId, String? besideTabId, bool after)? onLeafPopOut;
  final Map<String, int> tabGroupSizes;
  final Map<String, List<Color>> tabIdentityColors;
  final Set<String> pinnedTabIds;
  final ShortcutBindings bindings;

  /// Whether any workspace is saved: a tab can then be added to one.
  final bool hasWorkspaces;

  /// The tabs with a session that speaks SSH, for SFTP in their menus.
  final Set<String> sshTabIds;

  /// tmux sessions per connection id (badge on the tab).
  final Map<String, int> tmuxCounts;
  final ValueChanged<String>? onOpenTmux;

  /// The sessions that are files only: their tabs say SFTP.
  final Set<String> filesOnlyIds;

  /// The sessions that are remote screens (4.0): their tabs say VNC.
  final Set<String> screenIds;

  const _SessionTabStrip({
    required this.sessions,
    this.activeSessionId,
    required this.onSessionSelected,
    required this.onSessionClosed,
    this.onTabAction,
    this.onTabMove,
    this.onTabMerge,
    this.onLeafMoveToTab,
    this.onLeafPopOut,
    this.tabGroupSizes = const {},
    this.tabIdentityColors = const {},
    this.pinnedTabIds = const {},
    required this.bindings,
    this.hasWorkspaces = false,
    this.sshTabIds = const {},
    this.tmuxCounts = const {},
    this.onOpenTmux,
    this.tabSources = const {},
    this.filesOnlyIds = const {},
    this.screenIds = const {},
  });

  @override
  State<_SessionTabStrip> createState() => _SessionTabStripState();
}

class _SessionTabStripState extends State<_SessionTabStrip> {
  @override
  Widget build(BuildContext context) {
    if (widget.sessions.isEmpty) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;
        final totalNeeded =
            widget.sessions.length * _kTabEstimatedWidth;

        // Determine how many tabs fit.
        final bool hasOverflow =
            totalNeeded > available && widget.sessions.length > 1;
        final int visibleCount = hasOverflow
            ? ((available - _kChevronWidth) / _kTabEstimatedWidth)
                .floor()
                .clamp(1, widget.sessions.length - 1)
            : widget.sessions.length;

        final visibleSessions = widget.sessions.sublist(0, visibleCount);
        final hiddenSessions = hasOverflow
            ? widget.sessions.sublist(visibleCount)
            : <MapEntry<String, SessionState>>[];

        // If the active session is hidden, swap it into the visible set.
        if (hasOverflow && widget.activeSessionId != null) {
          final hiddenActiveIdx = hiddenSessions
              .indexWhere((e) => e.key == widget.activeSessionId);
          if (hiddenActiveIdx >= 0) {
            final activeEntry = hiddenSessions.removeAt(hiddenActiveIdx);
            final evicted = visibleSessions.removeLast();
            visibleSessions.add(activeEntry);
            hiddenSessions.insert(0, evicted);
          }
        }

        // [landsAtEnd]: a terminal dragged out of a split is held over the
        // strip's open space, and will become the last tab.
        Widget strip({required bool landsAtEnd}) => Row(
              children: [
                // -- Visible tabs with drag support --
                Expanded(
                  child: Row(
                    children: List.generate(visibleSessions.length, (i) {
                      return Flexible(
                        child: _buildDraggableTab(
                          visibleSessions[i],
                          landsAfter:
                              landsAtEnd && i == visibleSessions.length - 1,
                        ),
                      );
                    }),
                  ),
                ),

                // -- Overflow chevron --
                if (hasOverflow)
                  _OverflowChevron(
                    hiddenSessions: hiddenSessions,
                    activeSessionId: widget.activeSessionId,
                    onSessionSelected: widget.onSessionSelected,
                  ),
              ],
            );

        if (widget.onLeafPopOut == null) return strip(landsAtEnd: false);
        // Open header space (anywhere on the strip a tab isn't) takes a
        // terminal dragged out of its split: let go there, it becomes a tab
        // of its own at the end, which the bar after the last tab says. It
        // sits UNDER the tabs' own zones, so what is held over a tab is that
        // tab's to answer; only what misses every tab reaches here.
        return DragTarget<String>(
          onAcceptWithDetails: (details) =>
              widget.onLeafPopOut!(details.data, null, true),
          builder: (context, candidate, rejected) =>
              strip(landsAtEnd: candidate.isNotEmpty),
        );
      },
    );
  }

  /// What letting [dragged] go on the [zone] of the tab [tabId] does: [zone]
  /// itself, or null for nothing. [dragged] is a tab or a terminal: a zone
  /// takes nothing else. A tab is not put beside itself or into itself, a
  /// terminal not into the group it is in, and nothing is put beside a
  /// pinned tab but another pinned tab: the strip keeps pinned tabs first,
  /// so it would not stay where it was dropped.
  _Landing? _landingOn(Object? dragged, String tabId, _Landing zone) {
    final pinned = widget.pinnedTabIds.contains(tabId);
    if (dragged is _DraggedTab) {
      if (dragged.tabId == tabId) return null;
      if (zone == _Landing.join) return widget.onTabMerge == null ? null : zone;
      if (widget.onTabMove == null) return null;
      return widget.pinnedTabIds.contains(dragged.tabId) == pinned ? zone : null;
    }
    // A terminal of the tab in front, dragged up out of its split.
    if (zone == _Landing.join) {
      if (widget.onLeafMoveToTab == null) return null;
      return tabId == widget.activeSessionId ? null : zone;
    }
    if (widget.onLeafPopOut == null) return null;
    return pinned ? null : zone;
  }

  /// One of the parts of a tab that take what is dragged over it, with the
  /// mark of what letting go there does. The mark is drawn from what the
  /// zone itself holds at the moment, so it cannot outlast the drag.
  Widget _zone(String tabId, _Landing zone, {required int flex}) {
    return Expanded(
      flex: flex,
      child: DragTarget<Object>(
        // A tab or a terminal is taken also where letting go does nothing,
        // so that it does not fall through to the open space under the tabs
        // and act there. Anything else dragged over the strip is not ours.
        onWillAcceptWithDetails: (details) =>
            details.data is _DraggedTab || details.data is String,
        onAcceptWithDetails: (details) {
          final dragged = details.data;
          final landing = _landingOn(dragged, tabId, zone);
          if (landing == null) return;
          final after = landing == _Landing.after;
          if (dragged is _DraggedTab) {
            if (landing == _Landing.join) {
              widget.onTabMerge?.call(dragged.tabId, tabId);
            } else {
              widget.onTabMove?.call(dragged.tabId, tabId, after);
            }
          } else if (dragged is String) {
            if (landing == _Landing.join) {
              widget.onLeafMoveToTab?.call(dragged, tabId);
            } else {
              widget.onLeafPopOut?.call(dragged, tabId, after);
            }
          }
        },
        builder: (context, candidate, rejected) {
          final landing = candidate.isEmpty
              ? null
              : _landingOn(candidate.first, tabId, zone);
          // IgnorePointer lets plain taps fall through to the tab's own
          // GestureDetector below. A drag still finds the zone: a Draggable
          // looks its targets up by where the pointer is, not through the
          // gesture arena. Without it the tab would be "dead" to clicks.
          return IgnorePointer(
            child: LayoutBuilder(
              builder: (context, box) => Stack(
                // The marks reach past the zone: the bar into the gap before
                // the tab, the tint over the whole tab.
                clipBehavior: Clip.none,
                fit: StackFit.expand,
                children: [
                  if (landing == _Landing.before)
                    const _LandingBar(
                      key: ValueKey('tab-lands-before'),
                      after: false,
                    ),
                  if (landing == _Landing.after)
                    const _LandingBar(
                      key: ValueKey('tab-lands-after'),
                      after: true,
                    ),
                  if (landing == _Landing.join)
                    _JoinMark(
                      key: const ValueKey('tab-joins'),
                      zoneWidth: box.maxWidth,
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// [landsAfter]: what is dragged will become a tab right after this one,
  /// the last (it is held over the strip's open space).
  Widget _buildDraggableTab(
    MapEntry<String, SessionState> entry, {
    required bool landsAfter,
  }) {
    final tabId = entry.key;
    final groupSize = widget.tabGroupSizes[tabId] ?? 1;
    final isPinned = widget.pinnedTabIds.contains(tabId);
    final tab = _SessionTab(
      key: ValueKey(tabId),
      sessionId: tabId,
      state: entry.value,
      isActive: tabId == widget.activeSessionId,
      identityColors: widget.tabIdentityColors[tabId] ?? const [],
      onTap: () => widget.onSessionSelected(tabId),
      onClose: () => widget.onSessionClosed(tabId),
      onMiddleClick: () => widget.onSessionClosed(tabId),
      // Pass the tab's own on-screen rect so the menu can open BELOW the tab
      // bar, clear of the clicked tab (§5), instead of under the cursor.
      onContextMenu: (tabRect) => _showTabContextMenu(
          context, tabRect, tabId, groupSize, isPinned),
      isPinned: isPinned,
      source: widget.tabSources[tabId],
      tmuxSessions: entry.value.connectionId == null
          ? 0
          : (widget.tmuxCounts[entry.value.connectionId!] ?? 0),
      onTmuxTap: widget.onOpenTmux == null
          ? null
          : () => widget.onOpenTmux!(tabId),
      filesOnly: widget.filesOnlyIds.contains(tabId),
      screen: widget.screenIds.contains(tabId),
    );

    // The strip's whole height, not only the tab's own: a tab is found from
    // the window's top edge down to the strip's bottom.
    return SizedBox(
      height: double.infinity,
      child: Stack(
        // The bar stands in the gap beside the tab and is taller than it.
        clipBehavior: Clip.none,
        alignment: Alignment.centerLeft,
        children: [
          Draggable<_DraggedTab>(
            data: _DraggedTab(tabId),
            // A see-through copy of the tab follows the pointer, hanging
            // under it: the tab it is held over, and the mark of where it
            // will land, are not covered.
            dragAnchorStrategy: hangingDragAnchor(reach: _kTabGhostWidth - 24),
            feedback: Material(
              color: Colors.transparent,
              child: Opacity(
                opacity: kDragGhostOpacity,
                child: SizedBox(
                  width: _kTabGhostWidth,
                  child: tab,
                ),
              ),
            ),
            childWhenDragging: Opacity(
              opacity: 0.30,
              child: tab,
            ),
            child: tab,
          ),
          // The tab's edges put what is dragged beside it, its middle half
          // into its group; with nothing to join, each half is an edge. By
          // the tab's real width (it was a fixed 40 pixels each side).
          Positioned.fill(
            child: Row(
              children: [
                _zone(tabId, _Landing.before, flex: 1),
                if (widget.onTabMerge != null || widget.onLeafMoveToTab != null)
                  _zone(tabId, _Landing.join, flex: 2),
                _zone(tabId, _Landing.after, flex: 1),
              ],
            ),
          ),
          if (landsAfter)
            const _LandingBar(key: ValueKey('tab-lands-after'), after: true),
        ],
      ),
    );
  }

  // ── Context menu ──────────────────────────────────────────────

  void _showTabContextMenu(
    BuildContext context,
    Rect tabRect,
    String tabId,
    int groupSize,
    bool isPinned,
  ) {
    final l10n = AppLocalizations.of(context)!;
    // Target of the click - named in a dim, non-interactive header row so the
    // user can confirm they right-clicked the intended tab (§5).
    final target =
        widget.sessions.where((e) => e.key == tabId).firstOrNull?.value;
    final targetName = (target?.connectionLabel.isNotEmpty ?? false)
        ? Redactable.host(target!.connectionLabel).display
        : tabId;
    final user = target?.username;
    final host = target?.host;
    final port = target?.port;
    String? targetAddress;
    if (host != null && host.isNotEmpty) {
      final up = (user != null && user.isNotEmpty) ? '$user@$host' : host;
      targetAddress = Redactable.freeText(
              (port != null && port != 22) ? '$up:$port' : up)
          .display;
    }

    // Live counts for Close others / Close all. Pinned tabs survive both, so
    // they don't count toward what would actually close; a zero count
    // disables the row rather than offering a no-op.
    final othersCount = widget.sessions
        .where((e) => e.key != tabId && !widget.pinnedTabIds.contains(e.key))
        .length;
    final allCount = widget.sessions
        .where((e) => !widget.pinnedTabIds.contains(e.key))
        .length;

    // "Merge same-color tabs" is a no-op unless another open tab shares this
    // tab's colour. Keep the row (§3) but disable it, with a tooltip, when
    // there's nothing to merge - instead of silently doing nothing.
    final thisColor = target?.colorIndex;
    final hasMergeCandidates = thisColor != null &&
        thisColor >= 0 &&
        widget.sessions.any(
            (e) => e.key != tabId && e.value.colorIndex == thisColor);

    String? shortcutFor(ShortcutAction action) =>
        widget.bindings.bindingFor(action)?.displayLabel;

    // Anchor the menu BELOW the tab, flush to its left edge, so it never
    // covers the tab that was clicked (§5). showMenu clamps to the screen, so
    // a menu near the bottom flips upward on its own; this bar lives at the
    // top of the window, so in practice it always opens downward.
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromLTRB(
      tabRect.left,
      tabRect.bottom + 4,
      overlay.size.width - tabRect.right,
      0,
    );

    showMenu<String>(
      context: context,
      position: position,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      color: AppColors.v3Surface,
      constraints: const BoxConstraints(minWidth: 248, maxWidth: 320),
      items: [
        // Target header - dim, non-interactive.
        PopupMenuItem<String>(
          enabled: false,
          height: 42,
          child: _TabMenuHeader(name: targetName, address: targetAddress),
        ),
        const PopupMenuDivider(height: 1),

        _tabMenuItem(
          value: isPinned ? 'unpin' : 'pin',
          icon: isPinned ? LucideIcons.pinOff : LucideIcons.pin,
          label: isPinned ? l10n.pillUnpin : l10n.pillPin,
        ),
        _tabMenuItem(
          value: 'rename',
          icon: LucideIcons.pencil,
          label: l10n.pillRenameTab,
        ),
        const PopupMenuDivider(height: 1),

        _tabMenuItem(
          value: 'reconnect',
          icon: LucideIcons.refreshCw,
          label: l10n.pillReconnect,
        ),
        _tabMenuItem(
          value: 'duplicate',
          icon: LucideIcons.copy,
          label: l10n.pillDuplicateSession,
        ),
        _tabMenuItem(
          value: 'splitRight',
          icon: LucideIcons.columns,
          label: l10n.pillSplitRight,
          shortcut: shortcutFor(ShortcutAction.splitRight),
        ),
        _tabMenuItem(
          value: 'splitDown',
          icon: LucideIcons.rows,
          label: l10n.pillSplitDown,
          shortcut: shortcutFor(ShortcutAction.splitDown),
        ),
        const PopupMenuDivider(height: 1),

        _tabMenuItem(
          value: 'saveWorkspace',
          icon: LucideIcons.save,
          label: l10n.pillSaveLayoutAsWorkspace,
        ),
        if (widget.hasWorkspaces)
          _tabMenuItem(
            value: 'addToWorkspace',
            icon: LucideIcons.layoutGrid,
            label: l10n.pillAddTabToWorkspace,
          ),
        _tabMenuItem(
          value: 'mergeGroup',
          icon: LucideIcons.combine,
          label: l10n.pillMergeSameColorTabs,
          enabled: hasMergeCandidates,
          disabledTooltip: l10n.pillMergeDisabledTooltip,
        ),
        _tabMenuItem(
          value: 'detach',
          icon: LucideIcons.externalLink,
          label: l10n.pillDetachToNewWindow,
          // Multi-window detach isn't implemented - surface the row (§5) but
          // disabled, so it doesn't advertise a dead action.
          enabled: false,
          disabledTooltip: l10n.pillDetachDisabledTooltip,
        ),
        // SFTP runs over SSH: a tab of local shells has none to open.
        if (widget.sshTabIds.contains(tabId))
          _tabMenuItem(
            value: 'openSftp',
            icon: LucideIcons.folderOpen,
            label: l10n.pillOpenInSftp,
            shortcut: shortcutFor(ShortcutAction.toggleSftpPanel),
          ),
        const PopupMenuDivider(height: 1),

        // One outline × glyph for the whole close family - distinguished by
        // label + count only (no circled-×, no trash can). Close all is
        // NORMAL text, not red: closing sessions destroys nothing; the count
        // in parentheses carries the weight (§5).
        _tabMenuItem(
          value: 'close',
          icon: LucideIcons.x,
          label: l10n.close,
          shortcut: shortcutFor(ShortcutAction.closeTab),
        ),
        // Close others / Close all only mean something with company: a lone
        // tab already has Close, so they are not shown for it.
        if (othersCount > 0) ...[
          _tabMenuItem(
            value: 'closeOthers',
            icon: LucideIcons.x,
            label: l10n.pillCloseOthers(othersCount),
          ),
          _tabMenuItem(
            value: 'closeAll',
            icon: LucideIcons.x,
            label: l10n.pillCloseAll(allCount),
          ),
        ],
      ],
    ).then((action) {
      if (action != null) {
        if (action == 'close') {
          widget.onSessionClosed(tabId);
        } else {
          widget.onTabAction?.call(tabId, action);
        }
      }
    });
  }

  /// One dense (~30px) context-menu row: a single outline-family icon, a 13px
  /// label, an optional right-aligned mono dim shortcut, and enabled/disabled
  /// styling. Disabled rows can carry a tooltip explaining why.
  PopupMenuItem<String> _tabMenuItem({
    required String value,
    required IconData icon,
    required String label,
    String? shortcut,
    bool enabled = true,
    String? disabledTooltip,
  }) {
    Widget row = _TabMenuRow(
      icon: icon,
      label: label,
      shortcut: shortcut,
      enabled: enabled,
    );
    if (!enabled && disabledTooltip != null) {
      row = Tooltip(message: disabledTooltip, child: row);
    }
    return PopupMenuItem<String>(
      value: value,
      enabled: enabled,
      height: 30,
      child: row,
    );
  }
}

// ======================================================================
// Tab context-menu building blocks (§5)
// ======================================================================

/// Dim, non-interactive first row naming the right-clicked tab: host name in
/// the UI font over `user@address` in mono. Removes any ambiguity about which
/// tab the menu is acting on.
class _TabMenuHeader extends StatelessWidget {
  final String name;
  final String? address;

  const _TabMenuHeader({required this.name, this.address});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.v3TextSecondary,
          ),
        ),
        if (address != null && address!.isNotEmpty) ...[
          const SizedBox(height: 1),
          Text(
            address!,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'JetBrainsMono',
              color: AppColors.v3TextTertiary,
            ),
          ),
        ],
      ],
    );
  }
}

/// One dense context-menu row. Single outline-family icon (one stroke, one
/// size, no fills), 13px label, and an optional right-aligned mono dim
/// shortcut column. Items without a binding simply show an empty column.
class _TabMenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? shortcut;
  final bool enabled;

  const _TabMenuRow({
    required this.icon,
    required this.label,
    this.shortcut,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final labelColor =
        enabled ? AppColors.v3TextPrimary : AppColors.v3TextDisabled;
    final iconColor =
        enabled ? AppColors.v3TextSecondary : AppColors.v3TextDisabled;
    return Row(
      children: [
        Icon(icon, size: 15, color: iconColor),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: TextStyle(fontSize: 13, color: labelColor),
          ),
        ),
        if (shortcut != null && shortcut!.isNotEmpty) ...[
          const SizedBox(width: 12),
          Text(
            shortcut!,
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'JetBrainsMono',
              color: AppColors.v3TextTertiary,
            ),
          ),
        ],
      ],
    );
  }
}

// ======================================================================
// Overflow chevron - shows hidden tabs in a dropdown with search
// ======================================================================

class _OverflowChevron extends StatefulWidget {
  final List<MapEntry<String, SessionState>> hiddenSessions;
  final String? activeSessionId;
  final ValueChanged<String> onSessionSelected;

  const _OverflowChevron({
    required this.hiddenSessions,
    this.activeSessionId,
    required this.onSessionSelected,
  });

  @override
  State<_OverflowChevron> createState() => _OverflowChevronState();
}

class _OverflowChevronState extends State<_OverflowChevron> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: () => _showOverflowDropdown(context),
        child: Tooltip(
          message: l10n.pillMoreTabs(widget.hiddenSessions.length),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: _kChevronWidth,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hovering
                  ? AppColors.v3TextPrimary.withValues(alpha: 0.08)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    '${widget.hiddenSessions.length}',
                    overflow: TextOverflow.clip,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: AppColors.v3TextSecondary,
                    ),
                  ),
                ),
                Icon(
                  LucideIcons.chevronRight,
                  size: 14,
                  color: AppColors.v3TextSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showOverflowDropdown(BuildContext context) {
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final Offset offset = box.localToGlobal(Offset.zero);
    final overlayState = Navigator.of(context).overlay;
    if (overlayState == null) return;
    final RenderBox? overlay =
        overlayState.context.findRenderObject() as RenderBox?;
    if (overlay == null || !overlay.hasSize) return;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(offset.dx, offset.dy + box.size.height, 260, 0),
        Offset.zero & overlay.size,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      color: AppColors.v3Surface,
      constraints: const BoxConstraints(maxHeight: 480, minWidth: 240),
      items: [
        // Single live-filtering picker: typing narrows the list in place
        // (the old showMenu baked the entries in statically, so the
        // "Filter tabs…" field only did anything on Enter).
        PopupMenuItem<String>(
          enabled: false,
          padding: EdgeInsets.zero,
          child: _OverflowTabPicker(
            sessions: widget.hiddenSessions,
            activeSessionId: widget.activeSessionId,
            onSessionSelected: (sessionId) =>
                Navigator.pop(context, sessionId),
          ),
        ),
      ],
    ).then((sessionId) {
      if (sessionId != null) {
        widget.onSessionSelected(sessionId);
      }
    });
  }
}

/// Live-filtering tab picker inside the overflow dropdown.
///
/// Owns both the query and the filtered list so typing narrows the list
/// in place. Enter selects the top hit; each row is tappable.
class _OverflowTabPicker extends StatefulWidget {
  final List<MapEntry<String, SessionState>> sessions;
  final String? activeSessionId;
  final ValueChanged<String> onSessionSelected;

  const _OverflowTabPicker({
    required this.sessions,
    this.activeSessionId,
    required this.onSessionSelected,
  });

  @override
  State<_OverflowTabPicker> createState() => _OverflowTabPickerState();
}

class _OverflowTabPickerState extends State<_OverflowTabPicker> {
  String _query = '';

  String _labelFor(MapEntry<String, SessionState> e) =>
      e.value.connectionLabel.isNotEmpty ? e.value.connectionLabel : e.key;

  List<MapEntry<String, SessionState>> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.sessions;
    return widget.sessions
        .where((e) => _labelFor(e).toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final filtered = _filtered;
    return SizedBox(
      width: 260,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: SizedBox(
              height: 30,
              child: TextField(
                autofocus: true,
                style: TextStyle(fontSize: 12, color: AppColors.v3TextPrimary),
                onChanged: (v) => setState(() => _query = v),
                onSubmitted: (_) {
                  // Enter selects the top hit.
                  if (filtered.isNotEmpty) {
                    widget.onSessionSelected(filtered.first.key);
                  }
                },
                decoration: InputDecoration(
                  hintText: l10n.pillFilterTabsHint,
                  hintStyle: TextStyle(
                    fontSize: 12,
                    color: AppColors.v3TextSecondary.withValues(alpha: 0.6),
                  ),
                  prefixIcon: Icon(LucideIcons.search,
                      size: 14, color: AppColors.v3TextSecondary),
                  prefixIconConstraints:
                      const BoxConstraints(minWidth: 28, minHeight: 0),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  filled: true,
                  fillColor: AppColors.v3Surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: AppColors.v3BorderSubtle),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: AppColors.v3BorderSubtle),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: AppColors.v3AccentPrimary),
                  ),
                ),
              ),
            ),
          ),
          Divider(height: 1, color: AppColors.v3BorderSubtle),
          if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                l10n.pillNoTabsMatch,
                style:
                    TextStyle(fontSize: 12, color: AppColors.v3TextSecondary),
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: filtered.length,
                itemBuilder: (context, i) {
                  final entry = filtered[i];
                  final label = _labelFor(entry);
                  final isConnected =
                      entry.value.status == SessionStatus.connected;
                  final isActive = entry.key == widget.activeSessionId;
                  return InkWell(
                    onTap: () => widget.onSessionSelected(entry.key),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 9),
                      child: Row(
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: isConnected
                                  ? AppColors.success
                                  : AppColors.v3Error,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: RedactedText(
                              Redactable.host(label),
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: isActive
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: isActive
                                    ? AppColors.v3AccentInk
                                    : AppColors.v3TextPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

// ======================================================================
// Session tab - individual tab with color bar, status dot, label, close
// ======================================================================

class _SessionTab extends StatefulWidget {
  final String sessionId;
  final SessionState state;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final VoidCallback onMiddleClick;
  final void Function(Rect tabRect)? onContextMenu;

  /// Resolved identity colours for this tab's panes, in pane order (§3). One
  /// colour → a solid identity bar; two or more distinct colours → a segmented
  /// bar (one stacked band per distinct colour). Empty → a neutral bar.
  final List<Color> identityColors;

  /// True when the user has pinned this tab. Renders a pin glyph in
  /// place of the close X (pinned tabs aren't closable from the pill;
  /// the user has to unpin first or use Close All / Close Others).
  final bool isPinned;

  /// tmux sessions known on this tab's host; a badge that opens tmux.
  final int tmuxSessions;
  final VoidCallback? onTmuxTap;

  /// Where its host comes from, under its name ("Acme · Production",
  /// "Personal"), while tabs from more than one place are open; null
  /// otherwise (the name alone, in the middle).
  final String? source;

  /// The tab's session is files only (an SFTP-only host): it says SFTP.
  final bool filesOnly;

  /// The tab's session is a remote screen (4.0): it says VNC.
  final bool screen;

  const _SessionTab({
    super.key,
    required this.sessionId,
    required this.state,
    required this.isActive,
    required this.onTap,
    required this.onClose,
    required this.onMiddleClick,
    this.onContextMenu,
    this.identityColors = const [],
    this.isPinned = false,
    this.tmuxSessions = 0,
    this.onTmuxTap,
    this.source,
    this.filesOnly = false,
    this.screen = false,
  });

  @override
  State<_SessionTab> createState() => _SessionTabState();
}

class _SessionTabState extends State<_SessionTab> {
  bool _hovering = false;

  /// The keyboard's focus is on the tab, and shown (not after a click).
  bool _focused = false;

  /// Report the tab's on-screen rect so the context menu can open below it.
  Rect? _tabRect() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final topLeft = box.localToGlobal(Offset.zero);
    return topLeft & box.size;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final touch = touchSizedAt(context);

    final label = widget.state.connectionLabel.isNotEmpty
        ? widget.state.connectionLabel
        : widget.sessionId;
    final status = sessionStatusWord(l10n, widget.state.status);
    void openMenu() {
      final rect = _tabRect();
      if (rect != null) widget.onContextMenu?.call(rect);
    }

    // To a screen reader the tab is one control: its name, where it comes
    // from, its state in words (the dot's colour said it to the eye only)
    // and whether it is pinned, selected while in front, its menu as an
    // action (4.0 accessibility pass: it was its name alone, with no state
    // and no button). To a keyboard it is a stop of Tab: Enter or Space
    // brings it to the front, the menu key or Shift+F10 opens its menu, and
    // the accent rings it while it has the focus.
    return Semantics(
      container: true,
      button: true,
      selected: widget.isActive,
      label: [
        Redactable.host(label).display,
        if (widget.source != null) Redactable.group(widget.source!).display,
        status,
        if (widget.isPinned) l10n.a11yTabPinned,
      ].join(', '),
      onTap: widget.onTap,
      onLongPress: widget.onContextMenu == null ? null : openMenu,
      customSemanticsActions: widget.onContextMenu == null
          ? null
          : {CustomSemanticsAction(label: l10n.a11yTabMenu): openMenu},
      child: FocusableActionDetector(
      onShowFocusHighlight: (on) => setState(() => _focused = on),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.contextMenu): _TabMenuIntent(),
        SingleActivator(LogicalKeyboardKey.f10, shift: true): _TabMenuIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onTap();
          return null;
        }),
        _TabMenuIntent: CallbackAction<_TabMenuIntent>(onInvoke: (_) {
          openMenu();
          return null;
        }),
      },
      child: MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Listener(
        // Middle-click to close
        onPointerDown: (event) {
          if (event.buttons == kMiddleMouseButton) {
            widget.onMiddleClick();
          }
        },
        child: GestureDetector(
          // Said by the tab's own node above, with its tap and its menu.
          excludeFromSemantics: true,
          onTap: widget.onTap,
          onSecondaryTapUp: (_) {
            final rect = _tabRect();
            if (rect != null) widget.onContextMenu?.call(rect);
          },
          // The right click's menu under a long press too (4.0): a finger
          // has no right button.
          onLongPress: () {
            final rect = _tabRect();
            if (rect != null) widget.onContextMenu?.call(rect);
          },
          child: Container(
            constraints: const BoxConstraints(
              minWidth: 120,
              maxWidth: 220,
            ),
            // A finger's 44 where the controls are touch sized (4.0).
            height: touch ? 44 : _kTabHeight,
            margin: const EdgeInsets.only(right: _kTabGap),
            child: Stack(
              children: [
                // Tab body. Clip so the identity bar's outer edge follows the
                // pill's corner radius (§3).
                ClipRRect(
                  borderRadius: BorderRadius.circular(_kTabRadius),
                  child: Container(
                  decoration: BoxDecoration(
                    // Active vs inactive is carried by the BACKGROUND + label,
                    // never the identity bar (§3): active lifts one surface
                    // step, inactive stays recessed.
                    color: widget.isActive
                        ? AppColors.v3Elevated
                        : _hovering
                            ? AppColors.v3Hover
                            : AppColors.v3Surface,
                    borderRadius: BorderRadius.circular(_kTabRadius),
                    border: Border.all(
                      color: _focused
                          ? ZestTokens.brand
                          : widget.isActive
                              ? AppColors.v3AccentPrimary.withValues(alpha: 0.45)
                              : AppColors.v3BorderSubtle,
                      width: _focused ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      // Identity bar (§3): the host's colour → its group's
                      // colour → neutral. Full tab height, ~4px, segmented
                      // when a split holds hosts of different colours. Full
                      // saturation on the active tab, ~60% opacity when
                      // inactive - so the colour stays readable but never
                      // encodes active/inactive itself.
                      _IdentityBar(
                        colors: widget.identityColors,
                        active: widget.isActive,
                      ),
                      const SizedBox(width: 8),

                      // Status dot - the ONE place status lives on the tab
                      // (dot + background tint, never a bar; §2).
                      // Its shape says it too, not its colour alone (4.0
                      // accessibility pass): a dot while connected, a ring
                      // while connecting, a cross once it is not.
                      SessionStatusMark(status: widget.state.status, size: 6),
                      const SizedBox(width: 6),

                      // Connection name, and under it where it comes from
                      // while tabs from more than one place are
                      // open.
                      Expanded(
                        // Said by the tab's own node, once.
                        child: ExcludeSemantics(
                          child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            RedactedText(
                              Redactable.host(label),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: 12,
                                height: widget.source == null ? null : 1.2,
                                fontWeight: widget.isActive
                                    ? FontWeight.w500
                                    : FontWeight.w400,
                                color: widget.isActive
                                    ? AppColors.v3TextPrimary
                                    : AppColors.v3TextSecondary,
                              ),
                            ),
                            // Cut in the middle where it does not fit, so
                            // both the team and the vault (or group) read.
                            if (widget.source != null)
                              MiddleEllipsisText(
                                Redactable.group(widget.source!),
                                key: ValueKey('tab-source-${widget.sessionId}'),
                                style: TextStyle(
                                  fontSize: 10,
                                  height: 1.2,
                                  color: AppColors.v3TextTertiary,
                                ),
                              ),
                          ],
                        ),
                        ),
                      ),

                      // Files only: SFTP, where a terminal's tab says
                      // nothing more.
                      if (widget.filesOnly) ...[
                        const SizedBox(width: 4),
                        FilesOnlyTag(
                            key: ValueKey('tab-files-only-${widget.sessionId}'),
                            sessionId: widget.sessionId,
                            compact: true),
                      ],
                      // A remote screen: VNC, with a monitor.
                      if (widget.screen) ...[
                        const SizedBox(width: 4),
                        ScreenTag(
                            key: ValueKey('tab-screen-${widget.sessionId}'), sessionId: widget.sessionId, compact: true),
                      ],

                      // Typing goes to every terminal of this tab: said on
                      // the tab itself, also while another tab is in front.
                      _TabBroadcastMark(tabId: widget.sessionId),

                      if (widget.tmuxSessions > 0) ...[
                        const SizedBox(width: 4),
                        TmuxSessionsBadge(
                          count: widget.tmuxSessions,
                          compact: true,
                          onTap: widget.onTmuxTap,
                        ),
                      ],

                      // Pin glyph (always visible) takes the place of
                      // the close X for pinned tabs. Pinned tabs aren't
                      // closable from the pill bar - the user has to
                      // unpin first via the right-click menu, which
                      // matches the convention every browser uses.
                      if (widget.isPinned)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Icon(
                            LucideIcons.pin,
                            size: 12,
                            color: AppColors.v3AccentInk,
                          ),
                        )
                      // Close button - always shown on the ACTIVE tab (so its
                      // close affordance is discoverable) and on hover for the
                      // rest. Pinned tabs show the pin glyph instead (above).
                      else if (_hovering || widget.isActive || _focused)
                        Tooltip(message: AppLocalizations.of(context)!.shortcutNameCloseTab, excludeFromSemantics: true, child: Semantics(
                          // Which tab it closes, to a screen reader ("Close
                          // web-01"; it heard "Close tab" on each).
                          container: true,
                          button: true,
                          label: l10n.desktopTerminalAreaCloseNamedTab(Redactable.host(label).display),
                          excludeSemantics: true,
                          onTap: widget.onClose,
                          child: GestureDetector(
                          onTap: widget.onClose,
                          // The whole height of the tab and 40 wide to a
                          // finger.
                          behavior: HitTestBehavior.opaque,
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: touch ? 13 : 6),
                            child: Icon(
                              LucideIcons.x,
                              size: 14,
                              color: AppColors.v3TextSecondary,
                            ),
                          ),
                        )))
                      else
                        const SizedBox(width: 26),
                    ],
                  ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
      ),
    );
  }
}

/// A session tab's menu, from the keyboard: the menu key or Shift+F10.
class _TabMenuIntent extends Intent {
  const _TabMenuIntent();
}

/// The mark on a tab that broadcasts: what is typed into one of its
/// terminals goes to the others. Nothing on a tab that does not.
class _TabBroadcastMark extends ConsumerWidget {
  const _TabBroadcastMark({required this.tabId});

  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(broadcastModeProvider.select((s) => s.broadcasts(tabId)));
    if (!on) return const SizedBox.shrink();
    return Tooltip(
      message: AppLocalizations.of(context)!.broadcastButtonOn,
      child: Padding(
        key: ValueKey('tab-broadcasting-$tabId'),
        padding: const EdgeInsets.only(left: 4),
        child: Icon(LucideIcons.radio, size: 12, color: AppColors.v3AccentInk),
      ),
    );
  }
}

// ======================================================================
// Identity bar - solid or segmented left rule carrying host/group colour
// ======================================================================

/// The tab's left identity rule (§3). Full tab height, ~4px, with the pill's
/// corner radius on its outer (left) edge (the parent [ClipRRect] handles the
/// rounding). A single colour paints a solid bar; two or more distinct colours
/// paint a segmented bar - one stacked band per distinct colour, in pane
/// order - matching the segmented treatment on workspace rows/cards. The bar
/// renders at full saturation on the active tab and ~60% opacity when
/// inactive, so the colour stays readable without the bar ever encoding
/// active/inactive itself.
class _IdentityBar extends StatelessWidget {
  final List<Color> colors;
  final bool active;

  const _IdentityBar({required this.colors, required this.active});

  @override
  Widget build(BuildContext context) {
    // Distinct colours in first-appearance (pane) order.
    final distinct = <Color>[];
    for (final c in colors) {
      if (!distinct.contains(c)) distinct.add(c);
    }
    if (distinct.isEmpty) distinct.add(AppColors.neutralLabelColor);

    final opacity = active ? 1.0 : 0.6;

    return Opacity(
      opacity: opacity,
      child: SizedBox(
        width: 4,
        height: double.infinity,
        child: Column(
          // The bar's whole width. (Centred, which a column is unless told
          // otherwise, a band with nothing in it is as wide as nothing: no
          // tab ever showed its colour.)
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final c in distinct)
              Expanded(child: ColoredBox(color: c)),
          ],
        ),
      ),
    );
  }
}

// ======================================================================
// Small icon button used in the pill bar
// ======================================================================

/// Shown only while the tab in front broadcasts: how many terminals get your
/// typing. A click stops it. Turning it on lives in the session header's
/// Layout popover and the command palette.
class BroadcastingChip extends ConsumerWidget {
  const BroadcastingChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final tabId = ref.watch(activeWorkTabIdProvider);
    final broadcasts = ref.watch(broadcastModeProvider.select((s) => tabId != null && s.broadcasts(tabId)));
    if (tabId == null || !broadcasts) return const SizedBox.shrink();
    final count = ref.watch(activeTabBroadcastProvider).length;
    final accent = AppColors.v3AccentPrimary;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Tooltip(
        message: l10n.pillBroadcastingStopTooltip(count),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            key: const ValueKey('pill-broadcasting'),
            onTap: () => ref.read(broadcastModeProvider.notifier).stopTab(tabId),
            child: Container(
              height: 26,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: accent.withValues(alpha: 0.5)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.radio, size: 13, color: AppColors.v3AccentInk),
                  const SizedBox(width: 6),
                  Text(
                    l10n.pillBroadcastingTo(count),
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.v3AccentInk,
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

/// The `?` button, with a dot while an answer from support has not been
/// read (the answer itself is under Help, My tickets).
/// Sessions shared with this account (3.0): there only while an invitation
/// waits or a view is open. A click lists them.
class _SharedSessionsButton extends ConsumerWidget {
  const _SharedSessionsButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!kOrchardsEnabled) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final invitations = ref.watch(shareInvitationsProvider);
    return ValueListenableBuilder<Map<String, ShareViewerController>>(
      valueListenable: ShareViews.active,
      builder: (context, views, _) {
        final shares = {...views.keys, for (final s in invitations) s.shareId};
        if (shares.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Stack(
            key: const ValueKey('pill-shared-sessions'),
            clipBehavior: Clip.none,
            children: [
              _PillBarIconButton(
                tooltip: '${l10n.shareInvitesTitle}: ${l10n.shareInvitesPill(shares.length)}',
                icon: LucideIcons.users,
                onTap: () => showShareInvitations(context),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: IgnorePointer(
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: AppColors.brandOrange,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.v3Background, width: 1),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HelpButton extends ConsumerWidget {
  const _HelpButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final unread = ref.watch(ticketUnreadCountProvider) > 0;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        _PillBarIconButton(
          tooltip: unread
              ? '${l10n.helpTitle}: ${l10n.ticketReplyFromSupport}'
              : l10n.helpTitle,
          icon: LucideIcons.helpCircle,
          // Lit while the Support Hub is over the shell: pressing it goes back.
          active: ref.watch(supportHubOpenProvider),
          onTap: onTap,
        ),
        if (unread)
          Positioned(
            top: 4,
            right: 4,
            child: IgnorePointer(
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: AppColors.brandOrange,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.v3Background, width: 1),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _PillBarIconButton extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  /// What it opens is open.
  final bool active;

  const _PillBarIconButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.active = false,
  });

  @override
  State<_PillBarIconButton> createState() => _PillBarIconButtonState();
}

class _PillBarIconButtonState extends State<_PillBarIconButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final touch = touchSizedAt(context);
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            // A finger's 48 where the controls are touch sized (4.0).
            width: touch ? 48 : 28,
            height: touch ? 48 : 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.active
                  ? AppColors.brandOrange.withValues(alpha: 0.14)
                  : _hovering
                      ? AppColors.v3TextPrimary.withValues(alpha: 0.08)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              widget.icon,
              size: touch ? 20 : 16,
              color: widget.active
                  ? AppColors.accentInk
                  : _hovering
                      ? AppColors.v3TextPrimary
                      : AppColors.v3TextSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

// ======================================================================
// Ctrl+K badge button
// ======================================================================

class _CtrlKBadge extends ConsumerStatefulWidget {
  final VoidCallback onTap;
  final bool compact;

  /// In a touch screen's app bar (4.0): the keys are said only once a mouse
  /// or a trackpad was used (a keyboard's hand is not far then), and the
  /// badge is touch sized where the controls are.
  final bool touch;
  const _CtrlKBadge({required this.onTap, this.compact = false, this.touch = false});

  @override
  ConsumerState<_CtrlKBadge> createState() => _CtrlKBadgeState();
}

class _CtrlKBadgeState extends ConsumerState<_CtrlKBadge> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    // Live binding for the command palette so the keycap + tooltip follow
    // the user's rebinding. Null when the binding has been cleared - in
    // that case we show nothing rather than a stale default (§4c).
    final bound =
        ref.watch(shortcutBindingProvider(ShortcutAction.commandPalette));
    final accel = widget.touch && !ref.watch(mouseExtrasProvider) ? null : bound;
    final touchSized = touchSizedAt(context);
    final l10n = AppLocalizations.of(context)!;
    return Tooltip(
      message: bound == null
          ? l10n.pillCommandPalette
          : l10n.pillCommandPaletteWithShortcut(bound),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: touchSized ? 48 : 32,
            padding: EdgeInsets.symmetric(horizontal: touchSized ? 16 : 12),
            decoration: BoxDecoration(
              color: _hovering
                  ? AppColors.v3AccentPrimary.withValues(alpha: 0.15)
                  : AppColors.v3Surface.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _hovering
                    ? AppColors.v3AccentPrimary.withValues(alpha: 0.5)
                    : AppColors.v3BorderSubtle,
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.search,
                  size: 16,
                  color: _hovering
                      ? AppColors.v3AccentInk
                      : AppColors.v3TextSecondary,
                ),
                // At narrow widths drop the "Search" label + keycap and
                // keep just the icon so the bar doesn't overflow.
                if (!widget.compact) ...[
                const SizedBox(width: 8),
                Text(
                  l10n.commonSearch,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: _hovering
                        ? AppColors.v3TextPrimary
                        : AppColors.v3TextSecondary,
                  ),
                ),
                // Keycap only when the command palette actually has a
                // binding; a cleared binding shows no stale chord (§4c).
                if (accel != null) ...[
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.v3Background,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: AppColors.v3BorderSubtle,
                        width: 0.5,
                      ),
                    ),
                    child: Text(
                      accel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.v3TextSecondary,
                        fontFamily: 'JetBrainsMono',
                      ),
                    ),
                  ),
                ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
