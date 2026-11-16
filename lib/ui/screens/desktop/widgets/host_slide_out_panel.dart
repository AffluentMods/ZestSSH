import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:lucide_icons/lucide_icons.dart';

import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/database/database.dart' show ConnectionGroup;
import 'package:zestssh/database/daos/connections_dao.dart'
    show ConnectionWithDetails;
import 'package:zestssh/features/groups/widgets/group_editor_panel.dart';
import 'package:zestssh/features/hosts/data/folder_icon_catalog.dart';
import 'package:zestssh/features/hosts/move_hosts.dart';
import 'package:zestssh/features/hosts/state/host_multi_select.dart';
import 'package:zestssh/features/hosts/state/host_sort_mode.dart';
import 'package:zestssh/features/hosts/host_health_summary.dart' show hostHealthSummariesProvider;
import 'package:zestssh/features/hosts/widgets/host_bulk_action_bar.dart';
import 'package:zestssh/features/hosts/widgets/host_card.dart' show HostSelectBox;
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/features/workspaces/models/workspace_view.dart';
import 'package:zestssh/features/workspaces/state/workspaces_provider.dart';
import 'package:zestssh/features/workspaces/widgets/workspace_dialog_common.dart';
import 'package:zestssh/features/workspaces/widgets/workspace_edit_dialog.dart';
import 'package:zestssh/features/workspaces/widgets/workspace_identity.dart';
import 'package:zestssh/features/workspaces/widgets/workspace_launch.dart';
import 'package:zestssh/features/workspaces/widgets/workspace_save_dialog.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/shortcut_overrides_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/wake_host.dart';
import 'package:zestssh/ui/widgets/button_box.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/database/database.dart' show Connection;
import 'package:zestssh/features/hosts/host_list_layout.dart';

/// Stable per-group colour: a user-picked accent when set, otherwise a hash
/// of the group name into the shared [GroupColor] palette. Resolved through
/// the same [resolveGroupColorToken] helper the Hosts grid and mobile home
/// page use, so a group reads the same colour everywhere.
Color _groupColorFor(ConnectionGroup g) => resolveGroupColor(
      colorValue: g.colorValue,
      colorIndex: g.colorIndex,
      name: g.name,
    );

/// A1 - the persistent, resizable **Hosts fast-connect panel**.
///
/// A scan-and-connect list that sits in the left column beside the icon-only
/// nav rail, so users can reach a second host WITHOUT leaving their sessions.
/// It is deliberately NOT a second copy of the Hosts page: no arrange mode, no
/// size tiers, no group summary cards, no inline editing. Full management lives
/// on the Hosts grid, reachable via the header's "manage" button.
class HostSlideOutPanel extends ConsumerStatefulWidget {
  /// Connect to (or, if already open, focus) the given host. Wired to the
  /// shell's `_connectTo`, which reuses an existing session rather than
  /// duplicating it, so a single call handles both connect and switch.
  final void Function(ConnectionWithDetails) onConnectTo;

  /// Open the full Hosts grid page (for arrange / edit / size tiers).
  final VoidCallback onManageHosts;

  /// Toggle the panel closed.
  final VoidCallback onClose;

  const HostSlideOutPanel({
    super.key,
    required this.onConnectTo,
    required this.onManageHosts,
    required this.onClose,
  });

  @override
  ConsumerState<HostSlideOutPanel> createState() => _HostSlideOutPanelState();
}

class _HostSlideOutPanelState extends ConsumerState<HostSlideOutPanel> {
  final _filterController = TextEditingController();
  String _query = '';

  /// The drawer's own keyboard (a click on a host gives it the keys):
  /// Ctrl+A (Cmd+A) selects every host it shows, Escape ends a selection.
  final _drawerFocus = FocusNode(debugLabel: 'HostsDrawer');

  /// The hosts in the order the drawer shows them (its groups, then the
  /// hosts in none): what Shift-click's range runs along and Ctrl+A selects.
  List<String> _order = const [];

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.keyA && hostToggleKeyHeld() && !keys.isShiftPressed && !keys.isAltPressed) {
      if (_order.isEmpty) return KeyEventResult.ignored;
      ref.read(hostSelectionPlaceProvider.notifier).state = HostSelectionPlace.drawer;
      ref.read(hostMultiSelectProvider.notifier).selectAll(_order);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape && ref.read(hostMultiSelectProvider).active) {
      ref.read(hostMultiSelectProvider.notifier).exit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// A click on host [h]: a selection click where it is one (Ctrl or Cmd,
  /// Shift, or any click in selection mode, as on the Hosts page), else it
  /// connects, as it always did.
  void _clickHost(ConnectionWithDetails h) {
    _drawerFocus.requestFocus();
    if (hostSelectionClick(ref, h.connection.id, _order)) return;
    widget.onConnectTo(h);
  }

  /// Hosts dropped on group [groupId] (null: the hosts in none): [h] and
  /// every host selected with it move there.
  Future<void> _dropInto(String? groupId, ConnectionWithDetails h) =>
      moveHostsToGroup(context, ref, hostsCarriedWith(ref, h, _order), groupId);

  /// Reserved collapse-store key for the Workspaces section, so its
  /// collapsed state persists alongside the host-group collapse state.
  static const _kWorkspacesCollapseKey = '__workspaces__';

  @override
  void dispose() {
    _filterController.dispose();
    _drawerFocus.dispose();
    super.dispose();
  }

  bool _hasActiveSession(String connectionId, Map<String, SessionState> s) => hostIsOpen(s, connectionId);

  bool _matches(ConnectionWithDetails c) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return c.connection.label.toLowerCase().contains(q) ||
        c.connection.host.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final width = ref.watch(hostPanelWidthProvider);
    final connectionsAsync = ref.watch(connectionsWithDetailsProvider);
    final List<ConnectionGroup> groups =
        ref.watch(connectionGroupsProvider).valueOrNull ?? const [];
    final sessions = ref.watch(activeSessionsProvider);
    final collapsed = ref.watch(hostPanelCollapsedGroupsProvider);
    // Workspaces rank ABOVE hosts in the drawer - a workspace opens several
    // hosts, so it outranks a single host row (§7a). Provided by the parallel
    // workspaces agent's `workspacesProvider`.
    final workspaces = ref.watch(workspacesProvider);
    // "Save current layout" is only meaningful with a live split to capture.
    final hasSession = sessions.values.any((s) =>
        s.status == SessionStatus.connected ||
        s.status == SessionStatus.connecting);

    final selecting = ref.watch(hostMultiSelectProvider).active &&
        ref.watch(hostSelectionPlaceProvider) == HostSelectionPlace.drawer;
    return Row(
      children: [
        SizedBox(
          width: width,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => ref.read(hostSelectionPlaceProvider.notifier).state = HostSelectionPlace.drawer,
            child: Focus(
            focusNode: _drawerFocus,
            onKeyEvent: _onKey,
            child: Container(
            decoration: BoxDecoration(
              color: AppColors.v3Background,
              border: Border(
                right: BorderSide(color: AppColors.v3BorderSubtle, width: 1),
              ),
            ),
            child: Column(
              children: [
                _buildHeader(l10n),
                _buildFilter(l10n),
                const Padding(
                  padding: EdgeInsets.fromLTRB(14, 0, 10, 4),
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: ActiveFirstToggle(place: HostListPlace.hostsPanel),
                  ),
                ),
                Expanded(
                  child: connectionsAsync.when(
                    // A reload (another space) keeps what is shown until its rows come: a spinner here was a flash.
                    skipLoadingOnReload: true,
                    loading: () => const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                    error: (_, _) => const SizedBox.shrink(),
                    data: (all) => _buildList(
                        l10n, all, groups, sessions, collapsed, workspaces,
                        hasSession),
                  ),
                ),
                // While hosts are selected, the foot is what can be done to
                // them (the Hosts page's bulk bar, in its narrow form).
                if (selecting)
                  HostBulkActionBar(groups: groups, shownOrder: _order, compact: true)
                // Footer becomes "Save current layout" (§7a). When nothing is
                // saved yet the CTA lives inline in the empty Workspaces block
                // instead, so the footer would double it up - hide it then.
                else if (workspaces.isNotEmpty)
                  _buildSaveLayoutFooter(l10n, hasSession: hasSession),
              ],
            ),
          ),
          ),
          ),
        ),
        _ResizeHandle(
          onDrag: (dx) {
            final next = (ref.read(hostPanelWidthProvider) + dx)
                .clamp(kHostPanelMinWidth, kHostPanelMaxWidth);
            ref.read(hostPanelWidthProvider.notifier).state = next;
          },
          onDragEnd: () => ref
              .read(desktopSettingsUpdaterProvider)
              .setHostPanelWidth(ref.read(hostPanelWidthProvider)),
        ),
      ],
    );
  }

  Widget _buildHeader(AppLocalizations l10n) {
    // Read the live, platform-correct binding; null (cleared) hides the
    // hint chip below rather than showing a stale default.
    final accel =
        ref.watch(shortcutBindingProvider(ShortcutAction.toggleHostPanel));
    return Container(
      height: 40,
      padding: const EdgeInsets.only(left: 14, right: 4),
      child: Row(
        children: [
          Text(
            l10n.hostPanelTitle,
            style: TextStyle(
              color: AppColors.v3TextPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          if (accel != null)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.v3Hover,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                accel,
                style: TextStyle(
                  color: AppColors.v3TextTertiary,
                  fontSize: 10,
                  fontFamily: 'JetBrainsMono',
                ),
              ),
            ),
          const Spacer(),
          // Sort control - writes the shared [hostSortModeProvider], so picking
          // a sort here also re-sorts the Hosts page (and vice versa), and the
          // ungrouped hosts finally have an order.
          PopupMenuButton<HostSortMode>(
            tooltip: AppLocalizations.of(context)!.sftpSortHosts,
            padding: EdgeInsets.zero,
            iconSize: 15,
            splashRadius: 16,
            color: AppColors.v3Surface,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
            icon: Icon(LucideIcons.arrowDownUp,
                size: 15, color: AppColors.v3TextSecondary),
            onSelected: (m) =>
                ref.read(hostSortModeProvider.notifier).state = m,
            itemBuilder: (context) {
              final current = ref.read(hostSortModeProvider);
              return [
                for (final m in HostSortMode.values)
                  PopupMenuItem<HostSortMode>(
                    value: m,
                    height: 38,
                    child: Row(
                      children: [
                        Icon(
                          m == current
                              ? LucideIcons.check
                              : LucideIcons.arrowDownUp,
                          size: 14,
                          color: m == current
                              ? AppColors.v3AccentInk
                              : AppColors.v3TextTertiary,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          m.nameIn(l10n),
                          style: TextStyle(
                            color: AppColors.v3TextPrimary,
                            fontSize: 13,
                            fontWeight: m == current
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  ),
              ];
            },
          ),
          _HeaderIconButton(
            icon: LucideIcons.layoutGrid,
            tooltip: l10n.hostPanelManageTooltip,
            onTap: widget.onManageHosts,
            // The header row sits directly above the filter field; nudge
            // this tooltip further below its trigger so it clears the
            // input instead of covering it.
            verticalOffset: 40,
          ),
          _HeaderIconButton(
            icon: LucideIcons.x,
            tooltip: l10n.hostPanelCloseTooltip,
            onTap: widget.onClose,
          ),
        ],
      ),
    );
  }

  Widget _buildFilter(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
      child: TextField(
        controller: _filterController,
        onChanged: (v) => setState(() => _query = v.trim()),
        style: TextStyle(color: AppColors.v3TextPrimary, fontSize: 12),
        cursorColor: AppColors.v3AccentPrimary,
        decoration: InputDecoration(
          isDense: true,
          hintText: l10n.hostPanelFilterHint,
          hintStyle: TextStyle(color: AppColors.v3TextTertiary, fontSize: 12),
          prefixIcon: Icon(LucideIcons.search,
              size: 14, color: AppColors.v3TextTertiary),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 32, minHeight: 32),
          filled: true,
          fillColor: AppColors.v3Surface,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
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
    );
  }

  /// "Save current layout" footer (§7a). Replaces the old "+ New Connection"
  /// button - that action already lives in the title bar, so two primary
  /// buttons no longer appear on screen at once. Disabled (flat neutral) when
  /// there's no live session to capture.
  Widget _buildSaveLayoutFooter(
    AppLocalizations l10n, {
    required bool hasSession,
  }) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.v3BorderSubtle, width: 1),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
      child: ButtonBox(
        width: double.infinity,
        height: 36,
        child: FilledButton.icon(
          onPressed: hasSession
              ? () => WorkspaceSaveDialog.show(context)
              : null,
          icon: const Icon(LucideIcons.save, size: 15),
          label: Text(l10n.workspaceSaveCurrentLayout),
          style: FilledButton.styleFrom(
            minimumSize: const Size(64, 36),
            backgroundColor: AppColors.v3AccentPrimary,
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildList(
    AppLocalizations l10n,
    List<ConnectionWithDetails> all,
    List<ConnectionGroup> groups,
    Map<String, SessionState> sessions,
    Set<String> collapsed,
    List<WorkspaceView> workspaces,
    bool hasSession,
  ) {
    // Workspaces section sits ABOVE the first host group (§7a).
    final sections = <Widget>[
      ..._buildWorkspacesSection(l10n, workspaces, collapsed, hasSession),
    ];

    if (all.isEmpty) {
      sections.add(_inlineHostMessage(l10n.hostPanelEmpty));
      return ListView(
        padding: const EdgeInsets.only(bottom: 8),
        children: sections,
      );
    }
    final filtered = all.where(_matches).toList();
    if (filtered.isEmpty) {
      sections.add(_inlineHostMessage(l10n.hostPanelNoMatches));
      return ListView(
        padding: const EdgeInsets.only(bottom: 8),
        children: sections,
      );
    }

    final select = ref.watch(hostMultiSelectProvider);
    final order = <String>[];
    // Bucket by groupId (null = ungrouped).
    final byGroup = <String?, List<ConnectionWithDetails>>{};
    for (final c in filtered) {
      byGroup.putIfAbsent(c.connection.groupId, () => []).add(c);
    }

    void addSection(String groupId, String name,
        List<ConnectionWithDetails> hosts, Color? groupColor,
        {ConnectionGroup? group, String keyPrefix = ''}) {
      if (hosts.isEmpty) return;
      final open = hosts
          .where((h) => _hasActiveSession(h.connection.id, sessions))
          .length;
      final isCollapsed = collapsed.contains(groupId);
      // A host dropped on the header (or on a host of the section) moves
      // into its group; on Ungrouped's, out of its group.
      final into = group?.id;
      sections.add(_DropInto(
        key: ValueKey('drawer-group-$keyPrefix$groupId'),
        groupId: into,
        order: order,
        onDrop: (h) => _dropInto(into, h),
        builder: (over) => _GroupHeader(
          name: name,
          color: groupColor,
          // Named groups render their picked folder icon; the synthetic
          // "Ungrouped" section (group == null) stays icon-free.
          icon: group != null ? folderIconFor(group.iconCodePoint) : null,
          countLabel: l10n.hostPanelOpenCount(open, hosts.length),
          collapsed: isCollapsed,
          dropOver: over,
          onTap: () => ref
              .read(desktopSettingsUpdaterProvider)
              .setHostPanelGroupCollapsed(groupId, !isCollapsed),
          // Right-click any host-section header (a real group or the synthetic
          // Ungrouped bucket) for the sort options; real groups also get Edit.
          onContextMenu: (pos) => _showHeaderMenu(l10n, pos, group),
        ),
      ));
      if (!isCollapsed) {
        for (final h in hosts) {
          order.add(h.connection.id);
          final row = _HostRow(
            entry: h,
            groupColor: groupColor,
            hasSession: _hasActiveSession(h.connection.id, sessions),
            connecting: sessions.values.any((s) =>
                s.connectionId == h.connection.id &&
                s.status == SessionStatus.connecting),
            selecting: select.active,
            selected: select.isSelected(h.connection.id),
            onTap: () => _clickHost(h),
            onContextMenu: (pos) => _showMenu(l10n, pos, h),
          );
          final carried = ref.read(hostMultiSelectProvider.notifier).dragSetFor(h.connection.id);
          sections.add(_DropInto(
            key: ValueKey('drawer-row-${h.connection.id}'),
            groupId: into,
            order: order,
            onDrop: (d) => _dropInto(into, d),
            builder: (over) => Draggable<ConnectionWithDetails>(
              key: ValueKey('drawer-drag-${h.connection.id}'),
              data: h,
              // Under a finger (a tablet, 4.0) a drag up or down scrolls the
              // drawer; a host is dragged sideways.
              affinity: touchSizedAt(context) ? Axis.horizontal : null,
              dragAnchorStrategy: pointerDragAnchorStrategy,
              feedback: _DragChip(
                host: carried.length > 1 ? null : h.connection,
                label: carried.length > 1
                    ? l10n.hostsSelDragCount(carried.length)
                    : Redactable.host(h.connection.label).displayIn(ref),
              ),
              childWhenDragging: Opacity(opacity: 0.4, child: row),
              child: row,
            ),
          ));
        }
      }
    }

    // Named groups first (in their stored order), ungrouped last. The group
    // colour matches the Hosts grid's rail colour (a stable hash of the group
    // name into the shared GroupColor palette) so the panel reads the same.
    // Each section is ordered by the shared [hostSortModeProvider], so the sort
    // chosen on the Hosts page (or the header control below) applies here too -
    // and the ungrouped bucket is no longer left unsorted.
    final sortMode = ref.watch(hostSortModeProvider);
    // Each host's health, for the Health sort (as the Hosts page orders by it).
    final health = sortMode == HostSortMode.health ? ref.watch(hostHealthSummariesProvider) : null;
    final used = ref.watch(hostUseProvider);

    // The groups with those of [keep] in them. Among the active ones the last
    // used first ([byUse]).
    void addGroups(bool Function(ConnectionWithDetails h) keep, {String keyPrefix = '', bool byUse = false}) {
      List<ConnectionWithDetails> ofGroup(String? id) {
        final hosts = [
          for (final h in sortConnections(
            conns: byGroup[id] ?? const [],
            mode: sortMode,
            sessions: sessions,
            health: health ?? const {},
          ))
            if (keep(h)) h,
        ];
        if (byUse) {
          DateTime at(ConnectionWithDetails h) =>
              used[h.connection.id] ?? h.connection.lastConnected ?? DateTime.fromMillisecondsSinceEpoch(0);
          hosts.sort((a, b) => at(b).compareTo(at(a)));
        }
        return hosts;
      }

      for (final g in groups) {
        // The header paints the group name; colour and collapse state keep
        // using the raw name / id.
        addSection(g.id, Redactable.group(g.name).displayIn(ref), ofGroup(g.id),
            _groupColorFor(g),
            group: g, keyPrefix: keyPrefix);
      }
      addSection('__ungrouped__', l10n.hostPanelUngrouped, ofGroup(null), null, keyPrefix: keyPrefix);
    }

    // Active first: the hosts with an open session
    // stand first; with it off, or none open, the list as it always was.
    bool isOpen(ConnectionWithDetails h) => _hasActiveSession(h.connection.id, sessions);
    final openCount = filtered.where(isOpen).length;
    if (ref.watch(activeFirstProvider(HostListPlace.hostsPanel)) && openCount > 0) {
      sections.add(Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: HostSectionHeading(active: true, count: openCount),
      ));
      addGroups(isOpen, keyPrefix: 'active-', byUse: true);
      if (openCount < filtered.length) {
        sections.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: HostSectionHeading(active: false, count: filtered.length - openCount),
        ));
        addGroups((h) => !isOpen(h));
      }
    } else {
      addGroups((_) => true);
    }
    _order = order;

    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: sections,
    );
  }

  /// Host empty / no-match line, laid out to live INSIDE the combined
  /// ListView (a plain padded row - not [_emptyMessage]'s Center, which needs
  /// bounded height and would throw under the scroll view).
  Widget _inlineHostMessage(String message) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 8),
      child: Text(
        message,
        style: TextStyle(color: AppColors.v3TextTertiary, fontSize: 12),
      ),
    );
  }

  /// The collapsible **Workspaces** section that heads the drawer list (§7a).
  /// Collapse state persists via the same per-group store host groups use,
  /// keyed by a reserved id.
  List<Widget> _buildWorkspacesSection(
    AppLocalizations l10n,
    List<WorkspaceView> workspaces,
    Set<String> collapsed,
    bool hasSession,
  ) {
    final out = <Widget>[];

    // Filter matches workspace names AND member host names (§7a).
    final q = _query.toLowerCase();
    final filtered = q.isEmpty
        ? workspaces
        : workspaces
            .where((w) =>
                w.name.toLowerCase().contains(q) ||
                w.memberHosts.any((m) => m.name.toLowerCase().contains(q)))
            .toList();

    // While actively filtering, a section with no matches just adds noise.
    if (_query.isNotEmpty && filtered.isEmpty) return out;

    final isCollapsed = collapsed.contains(_kWorkspacesCollapseKey);
    out.add(_GroupHeader(
      name: l10n.workspacesSectionTitle,
      color: null,
      icon: null,
      // Count in mono (§7a) - total saved, not the filtered subset.
      countLabel: '${workspaces.length}',
      collapsed: isCollapsed,
      onTap: () => ref
          .read(desktopSettingsUpdaterProvider)
          .setHostPanelGroupCollapsed(
              _kWorkspacesCollapseKey, !isCollapsed),
      onContextMenu: null,
    ));
    if (isCollapsed) return out;

    if (workspaces.isEmpty) {
      // Inline dashed block carrying the disabled CTA + one-line reason.
      out.add(_WorkspaceDrawerEmpty(
        hasSession: hasSession,
        onSave: () => WorkspaceSaveDialog.show(context),
      ));
      return out;
    }

    for (final w in filtered) {
      out.add(_WorkspaceDrawerRow(
        workspace: w,
        onLaunch: () {
          // ignore: discarded_futures
          launchWorkspaceFromSurface(context, ref, w.id);
        },
        onOverflow: () =>
            WorkspaceEditDialog.show(context, workspaceId: w.id),
      ));
    }
    return out;
  }

  Future<void> _showMenu(
      AppLocalizations l10n, Offset pos, ConnectionWithDetails entry) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final hasSession =
        _hasActiveSession(entry.connection.id, ref.read(activeSessionsProvider));
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        pos & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      color: AppColors.v3Elevated,
      items: [
        PopupMenuItem(
          value: 'connect',
          child: Text(
              hasSession ? l10n.hostMenuSwitchToSession : l10n.hostMenuConnect),
        ),
        // Wake-on-LAN, for a host with an address to wake saved.
        if (canWake(entry.connection))
          PopupMenuItem(value: 'wake', child: Text(l10n.connectionCardWakeWol)),
        PopupMenuItem(value: 'edit', child: Text(l10n.hostMenuEdit)),
      ],
    );
    if (!mounted) return;
    switch (selected) {
      case 'connect':
        widget.onConnectTo(entry);
      case 'wake':
        await wakeHost(context, ref, entry.connection);
      case 'edit':
        ConnectionEditScreen.showAdaptive(context,
            connectionId: entry.connection.id);
    }
  }

  /// Right-click menu on a group header: a single "Edit" that opens the
  /// unified group editor (§6), which owns rename / recolour / reorder /
  /// delete - so there is no longer a separate delete action here.
  /// Right-click menu for a host-section header. A real group gets Edit; every
  /// header, including the synthetic Ungrouped bucket (group == null), also gets
  /// the full set of sort options, writing the shared [hostSortModeProvider] so
  /// the choice applies everywhere hosts are listed.
  Future<void> _showHeaderMenu(
      AppLocalizations l10n, Offset pos, ConnectionGroup? group) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final current = ref.read(hostSortModeProvider);
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        pos & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      color: AppColors.v3Elevated,
      items: [
        if (group != null) ...[
          PopupMenuItem(value: 'edit', child: Text(l10n.zestGroupEdit)),
          const PopupMenuDivider(),
        ],
        for (final m in HostSortMode.values)
          PopupMenuItem<String>(
            value: 'sort:${m.name}',
            height: 38,
            child: Row(
              children: [
                Icon(
                  m == current ? LucideIcons.check : LucideIcons.arrowDownUp,
                  size: 14,
                  color: m == current
                      ? AppColors.v3AccentInk
                      : AppColors.v3TextTertiary,
                ),
                const SizedBox(width: 10),
                Text(
                  m.nameIn(l10n),
                  style: TextStyle(
                    color: AppColors.v3TextPrimary,
                    fontSize: 13,
                    fontWeight:
                        m == current ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    if (!mounted || selected == null) return;
    if (selected == 'edit') {
      if (group != null) {
        await GroupEditorPanel.showAdaptive(context, groupId: group.id);
      }
    } else if (selected.startsWith('sort:')) {
      final name = selected.substring(5);
      ref.read(hostSortModeProvider.notifier).state =
          HostSortMode.values.firstWhere((m) => m.name == name);
    }
  }
}

class _GroupHeader extends StatelessWidget {
  final String name;

  /// The group's colour (null = ungrouped). Tints the section title so the
  /// group is identifiable at a glance.
  final Color? color;

  /// The group's folder icon (null = ungrouped / no icon shown).
  final IconData? icon;
  final String countLabel;
  final bool collapsed;
  final VoidCallback onTap;

  /// Hosts are held over it, to be dropped into its group: it lights up.
  final bool dropOver;

  /// Right-click (or equivalent) on the header. Null for the synthetic
  /// "Ungrouped" section, which has no folder to edit.
  final void Function(Offset globalPos)? onContextMenu;

  const _GroupHeader({
    required this.name,
    required this.color,
    required this.icon,
    required this.countLabel,
    required this.collapsed,
    required this.onTap,
    required this.onContextMenu,
    this.dropOver = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onSecondaryTapDown: onContextMenu == null
          ? null
          : (d) => onContextMenu!(d.globalPosition),
      // The right click's menu under a long press too where the controls are
      // touch sized (a tablet, 4.0): a finger has no right button.
      onLongPress: onContextMenu == null || !touchSizedAt(context)
          ? null
          : () {
              final box = context.findRenderObject() as RenderBox?;
              if (box != null) onContextMenu!(box.localToGlobal(box.size.center(Offset.zero)));
            },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        decoration: BoxDecoration(
          color: dropOver ? AppColors.v3AccentPrimary.withValues(alpha: 0.12) : Colors.transparent,
          border: Border(
            left: BorderSide(color: dropOver ? AppColors.v3AccentPrimary : Colors.transparent, width: 2),
          ),
        ),
        child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 12, 4),
        child: Row(
          children: [
            Icon(
              collapsed ? LucideIcons.chevronRight : LucideIcons.chevronDown,
              size: 13,
              color: color?.withValues(alpha: 0.85) ?? AppColors.v3TextTertiary,
            ),
            if (icon != null) ...[
              const SizedBox(width: 4),
              Icon(
                icon,
                size: 13,
                color: color?.withValues(alpha: 0.85) ??
                    AppColors.v3TextTertiary,
              ),
            ],
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                name.toUpperCase(),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color ?? AppColors.v3TextSecondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            Text(
              countLabel,
              style: TextStyle(
                color: AppColors.v3TextTertiary,
                fontSize: 10,
                fontFamily: 'JetBrainsMono',
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

/// A place in the drawer a host can be dropped on, to go into [groupId]
/// (null: out of its group): it takes the hosts a drag carries where any of
/// them is not in that group yet, and tells [builder] while they are over it.
class _DropInto extends ConsumerWidget {
  const _DropInto({
    super.key,
    required this.groupId,
    required this.order,
    required this.onDrop,
    required this.builder,
  });

  final String? groupId;
  final List<String> order;
  final ValueChanged<ConnectionWithDetails> onDrop;
  final Widget Function(bool over) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DragTarget<ConnectionWithDetails>(
      onWillAcceptWithDetails: (d) => hostsCarriedWith(ref, d.data, order).any((c) => c.connection.groupId != groupId),
      onAcceptWithDetails: (d) => onDrop(d.data),
      builder: (context, candidates, _) => builder(candidates.isNotEmpty),
    );
  }
}

/// What rides under the pointer while hosts are dragged out of the drawer:
/// the host's name, or how many.
class _DragChip extends StatelessWidget {
  const _DragChip({required this.label, this.host});
  final String label;

  /// The one host it carries, whose icon it shows; null where it is many.
  final Connection? host;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.v3Elevated,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: AppColors.v3AccentPrimary.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (host != null)
              HostGlyph(host: host!, size: 16)
            else
              Icon(LucideIcons.layers, size: 13, color: AppColors.v3AccentInk),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 12, color: AppColors.v3TextPrimary)),
          ],
        ),
      ),
    );
  }
}

class _HostRow extends StatefulWidget {
  final ConnectionWithDetails entry;

  /// The host's group colour (null = ungrouped). Painted as a "calling-card"
  /// gradient wash behind the row for at-a-glance grouping.
  final Color? groupColor;
  final bool hasSession;
  final bool connecting;
  final VoidCallback onTap;
  final void Function(Offset globalPos) onContextMenu;

  /// Selection mode: a box in the icon's place, ticked where [selected].
  final bool selecting;
  final bool selected;

  const _HostRow({
    required this.entry,
    required this.groupColor,
    required this.hasSession,
    required this.connecting,
    required this.onTap,
    required this.onContextMenu,
    this.selecting = false,
    this.selected = false,
  });

  @override
  State<_HostRow> createState() => _HostRowState();
}

class _HostRowState extends State<_HostRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.entry.connection;

    // Status → colour, shared by the name text and the status dot:
    //   connecting → yellow, connected → green, offline → white.
    final active = widget.hasSession && !widget.connecting;
    final Color statusColor = widget.connecting
        ? AppColors.v3Warning
        : active
            ? AppColors.v3Success
            : AppColors.v3TextPrimary;
    // A live host reads brighter; the offline dot is a dimmed white so a long
    // list of resting hosts doesn't shout.
    final dotColor = (widget.hasSession || widget.connecting)
        ? statusColor
        : statusColor.withValues(alpha: 0.5);

    // "Calling-card" wash: the group colour bleeds in from the left and fades
    // to transparent, so grouping reads at a glance without a solid block.
    final gc = widget.groupColor;
    final BoxDecoration decoration = widget.selected
        ? BoxDecoration(color: AppColors.v3AccentPrimary.withValues(alpha: _hover ? 0.16 : 0.11))
        : gc == null
        ? BoxDecoration(
            color: _hover ? AppColors.v3Hover : Colors.transparent)
        : BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                gc.withValues(alpha: _hover ? 0.34 : 0.24),
                gc.withValues(alpha: _hover ? 0.07 : 0.03),
                Colors.transparent,
              ],
              stops: const [0.0, 0.5, 1.0],
            ),
          );

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onSecondaryTapDown: (d) => widget.onContextMenu(d.globalPosition),
        // The right click's menu under a long press too where the controls are
        // touch sized (a tablet, 4.0): a finger has no right button.
        onLongPressStart: touchSizedAt(context) ? (d) => widget.onContextMenu(d.globalPosition) : null,
        child: Container(
          height: 30,
          padding: const EdgeInsets.only(left: 14, right: 10),
          decoration: decoration,
          // The one row of a host, by name alone in a panel this narrow. (Its
          // dot says more than an open session's, and stands at its end.)
          child: HostRow(
            host: c,
            group: widget.entry.group,
            showAddress: false,
            iconSize: 16,
            leading: widget.selecting ? HostSelectBox(checked: widget.selected, size: 14) : null,
            nameStyle: TextStyle(
              color: statusColor,
              fontSize: 12,
              fontWeight: (widget.hasSession || widget.connecting)
                  ? FontWeight.w600
                  : FontWeight.w400,
            ),
            padding: EdgeInsets.zero,
            margin: EdgeInsets.zero,
            hovers: false,
            trailing: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
            ),
          ),
        ),
      ),
    );
  }
}

/// Thin drag handle on the panel's right edge. Reports horizontal deltas; the
/// caller clamps + persists.
class _ResizeHandle extends StatelessWidget {
  final void Function(double dx) onDrag;
  final VoidCallback onDragEnd;

  const _ResizeHandle({required this.onDrag, required this.onDragEnd});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
        onHorizontalDragEnd: (_) => onDragEnd(),
        child: const SizedBox(width: 6, height: double.infinity),
      ),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  /// The header sits directly above the filter field, so [verticalOffset]
  /// can be bumped to push the tooltip clear of the input (kept below its
  /// trigger) instead of covering it.
  final double? verticalOffset;

  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.verticalOffset,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      preferBelow: true,
      verticalOffset: verticalOffset,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 15, color: AppColors.v3TextSecondary),
        ),
      ),
    );
  }
}

/// A single workspace row in the drawer's Workspaces section (§7a).
///
/// At rest it shows only content - name, `n tabs · n panes` in mono under it,
/// member colour chips, and the segmented identity bar on the left edge. On hover the
/// row lifts one surface step and reveals the launch shortcut pill, a launch
/// glyph, and an overflow menu. Tapping the row (or the launch glyph) launches;
/// the overflow opens the edit dialog directly (§7d - no standalone modal, no
/// always-visible trash).
class _WorkspaceDrawerRow extends StatefulWidget {
  final WorkspaceView workspace;
  final VoidCallback onLaunch;
  final VoidCallback onOverflow;

  const _WorkspaceDrawerRow({
    required this.workspace,
    required this.onLaunch,
    required this.onOverflow,
  });

  @override
  State<_WorkspaceDrawerRow> createState() => _WorkspaceDrawerRowState();
}

class _WorkspaceDrawerRowState extends State<_WorkspaceDrawerRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final w = widget.workspace;
    final memberColors = [for (final m in w.memberHosts) m.resolvedColor];

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 3),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onLaunch,
          onSecondaryTap: widget.onOverflow,
          // The right click's menu under a long press too where the controls are
          // touch sized (a tablet, 4.0): a finger has no right button.
          onLongPress: touchSizedAt(context) ? widget.onOverflow : null,
          child: Container(
            decoration: BoxDecoration(
              color: _hover ? AppColors.v3Elevated : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: _hover
                  ? Border.all(color: AppColors.v3BorderSubtle, width: 1)
                  : null,
            ),
            child: Stack(
              children: [
                // Segmented identity bar pinned to the left edge (§3 / §7a).
                Positioned(
                  left: 0,
                  top: 8,
                  bottom: 8,
                  width: 3,
                  child: WorkspaceSegmentedBar(memberColors: memberColors),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 9, 9),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // The name has the line to itself, its counts under it
                      // (beside it they cut it to "Databa…": found in a design
                      // audit).
                      Row(
                        children: [
                          Expanded(
                            child: RedactedText(
                              Redactable.workspace(w.name),
                              key: const ValueKey('workspace-drawer-name'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.v3TextPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (_hover) ...[
                            _RowGlyph(
                              icon: LucideIcons.play,
                              onTap: widget.onLaunch,
                              tooltip: AppLocalizations.of(context)!.workspaceLaunch,
                            ),
                            _RowGlyph(
                              icon: LucideIcons.moreVertical,
                              onTap: widget.onOverflow,
                              tooltip: AppLocalizations.of(context)!.phoneTabMore,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        workspaceCountLabel(l10n, w.tabCount, w.paneCount),
                        key: const ValueKey('workspace-drawer-counts'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.v3TextTertiary,
                          fontSize: 10.5,
                          fontFamily: 'JetBrainsMono',
                        ),
                      ),
                      const SizedBox(height: 7),
                      WorkspaceMemberChips(
                        members: [
                          for (final m in w.memberHosts)
                            (
                              name: workspaceMemberName(l10n, m),
                              color: m.resolvedColor,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Small hover-revealed glyph button used on a workspace drawer row.
class _RowGlyph extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  const _RowGlyph({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
          child: Icon(icon, size: 14, color: AppColors.v3TextSecondary),
        ),
      ),
    );
  }
}

/// Inline dashed empty block for the drawer's Workspaces section (§7a).
/// Carries the disabled "Save current layout" CTA plus a one-line reason.
class _WorkspaceDrawerEmpty extends StatelessWidget {
  final bool hasSession;
  final VoidCallback onSave;

  const _WorkspaceDrawerEmpty({required this.hasSession, required this.onSave});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
      child: WorkspaceDashedBox(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ButtonBox(
              height: 30,
              child: FilledButton.icon(
                onPressed: hasSession ? onSave : null,
                icon: const Icon(LucideIcons.save, size: 14),
                label: Text(
                  l10n.workspaceSaveCurrentLayout,
                  style: const TextStyle(fontSize: 12),
                ),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(64, 30),
                  backgroundColor: AppColors.v3AccentPrimary,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(7),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              hasSession
                  ? l10n.workspaceDrawerEmptyReady
                  : l10n.workspaceDrawerEmptyReason,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.v3TextTertiary,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
