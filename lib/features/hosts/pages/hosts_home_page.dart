import 'package:zestssh/services/connection_share_service.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:zestssh/l10n/time_ago.dart' show timeAgoShort;
import 'package:zestssh/features/hosts/connect_as.dart';
import 'package:zestssh/features/hosts/delete_host.dart';
import 'package:zestssh/features/hosts/quick_target.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/features/orchards/move/item_transfer.dart' show TransferKinds, TransferMode;
import 'package:zestssh/features/orchards/move/move_copy_dialog.dart';
import 'package:zestssh/features/onboarding/widgets/get_connected_options.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/models/os_kind.dart';
import 'package:zestssh/providers/changed_host_keys_provider.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/connection_tags_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/host_card_settings_provider.dart';
import 'package:zestssh/providers/pinned_hosts_provider.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/os_detection_providers.dart';
import 'package:zestssh/providers/sftp_sessions_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/wake_host.dart';
import 'package:zestssh/ui/widgets/load_error_state.dart';
import 'package:zestssh/utils/logger.dart';
import '../../../core/theme/zest_colors.dart';
import '../../../core/theme/group_color.dart';
import '../../workspaces/models/workspace_view.dart';
import '../../workspaces/state/workspaces_provider.dart';
import '../../workspaces/widgets/workspace_dialog_common.dart';
import '../../workspaces/widgets/workspace_launch.dart';
import '../../workspaces/widgets/workspace_panel.dart';
import '../../workspaces/widgets/workspace_save_dialog.dart';
import '../../../core/widgets/status_pill.dart';
import '../../groups/models/group.dart';
import '../../groups/widgets/group_editor_panel.dart';
import '../../groups/data/default_group_icons.dart';
import '../data/folder_icon_catalog.dart';
import '../bulk/host_bulk_edit.dart' show BulkField;
import '../bulk/host_bulk_edit_panel.dart';
import '../state/host_multi_select.dart';
import '../state/kex_refused_hosts.dart';
import '../state/host_arrange_mode.dart';
import '../state/host_sort_mode.dart';
import '../widgets/host_bulk_action_bar.dart';
import '../widgets/host_card.dart';
import '../widgets/host_grid_area.dart';
import 'package:zestssh/features/tmux/tmux_session_counts.dart';
import '../state/hosts_page_prefs.dart';
import '../host_health_summary.dart';
import '../widgets/hosts_band.dart';
import '../widgets/group_tiles.dart';
import '../widgets/hosts_table.dart';
import '../widgets/hosts_filter_panel.dart';
import '../local_terminal.dart';
import '../host_card_face.dart';
import '../open_selected_hosts.dart';
import '../move_hosts.dart';
import '../widgets/host_panel_sections.dart' show sshCommandFor;
import 'dart:async' show unawaited;
import 'package:zestssh/features/monitoring/monitor_host_alerts.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart' show canAddMonitoredHostProvider;
import 'package:zestssh/providers/purchase_providers.dart' show freeMonitorLimit;
import 'package:zestssh/ui/screens/monitoring/monitor_thresholds_dialog.dart' show showMonitorThresholds;
import 'package:zestssh/ui/screens/purchase/pricing_modal.dart';
import 'package:zestssh/models/enums.dart' show ConnectionProtocol;
import '../widgets/group_filter_chips.dart';
import '../widgets/section_label.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/features/screens/proxmox/proxmox_guest_of.dart';
import 'package:zestssh/features/screens/session/screen_target.dart' show XProgramTarget;
import 'package:zestssh/features/screens/xprogram/x_program_dialog.dart' show showXProgramDialog;
import 'package:zestssh/ui/screens/connection/share_link_add.dart'
    show looksLikeShareLink, addShareLinkFromText, showPasteShareLink, addShareLinkHost;
import 'package:zestssh/features/cloud_import/cloud_plan.dart';
import 'package:zestssh/features/cloud_import/ui/import_hosts_entry.dart';
import 'package:zestssh/features/hosts/host_attention.dart';
import 'package:zestssh/features/hosts/host_screens.dart';
import 'package:zestssh/features/hosts/host_share_file.dart';
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/providers/shortcut_overrides_provider.dart';
import 'package:zestssh/features/hosts/widgets/host_panel.dart';
import 'package:zestssh/ui/screens/desktop/dialogs/get_connected_dialogs.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_empty_state.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/features/sftp/forget_last_folder.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/item_store.dart' show teamMayNotOpenWith;
import 'package:zestssh/features/orchards/widgets/crate_filter_chips.dart';
import 'package:zestssh/features/orchards/widgets/orchard_status_banner.dart';
import 'package:zestssh/features/orchards/widgets/vault_picker.dart';
import 'package:zestssh/ui/widgets/guide_help_button.dart';
import 'package:zestssh/ui/widgets/selection_bar.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:zestssh/ui/widgets/zest_pressable.dart';

// ══════════════════════════════════════════════════════════════════
// Hosts Home Page - v3 assembly
// ══════════════════════════════════════════════════════════════════

class HostsHomePage extends ConsumerStatefulWidget {
  final void Function(ConnectionWithDetails) onConnectTo;

  /// tmux was asked for on a host (its menu, its panel): connect if needed,
  /// then open the tmux session picker in that session's tab.
  final void Function(ConnectionWithDetails)? onOpenTmux;

  /// The host panel's SFTP: SFTP for this host (connecting first if needed).
  final void Function(ConnectionWithDetails)? onOpenSftp;

  /// The host panel's "Switch to session": bring that session's tab up.
  final void Function(String sessionId)? onSwitchToSession;

  /// Connects to a host signed in with one of its other accounts (3.0,
  /// accounts per host): "Connect as" in a host's menu, where it is given.
  final void Function(ConnectionWithDetails item, String account)? onConnectAs;

  /// Quick connect (the New host menu): the shell's own window.
  final VoidCallback? onQuickConnect;

  /// Opens an X program on an SSH host in a screen tab of its own (4.0, step
  /// 2): "Open an X program..." in a host's menu, where it is given.
  final void Function(ConnectionWithDetails item, XProgramTarget program)? onOpenXProgram;

  /// Opens the console of the Proxmox guest a host was imported as (4.0):
  /// "Open console" in its menu, where it is given.
  final void Function(ConnectionWithDetails item)? onOpenConsole;

  const HostsHomePage({
    super.key,
    required this.onConnectTo,
    this.onOpenTmux,
    this.onOpenSftp,
    this.onSwitchToSession,
    this.onConnectAs,
    this.onQuickConnect,
    this.onOpenXProgram,
    this.onOpenConsole,
  });

  @override
  ConsumerState<HostsHomePage> createState() => _HostsHomePageState();
}

class _HostsHomePageState extends ConsumerState<HostsHomePage> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  String _searchQuery = '';

  /// Only the hosts that need attention (the header's toggle, or Filter).
  bool _attentionOnly = false;

  /// Only the hosts with a session open (Filter).
  bool _openOnly = false;

  /// Only hosts of these kinds (their protocol; Filter). Empty: every kind.
  final Set<String> _kinds = {};

  /// The Groups section shows every tile (it folds to one row past six).
  bool _allGroups = false;

  /// Every workspace shown, not one row of them.
  bool _allWorkspaces = false;

  /// How the hosts are shown (a list, the compact grid, the grid), as this
  /// device last had them.
  HostsViewMode get _viewMode => HostsPagePrefs.view(ref.watch(sharedPreferencesProvider));
  set _viewMode(HostsViewMode mode) {
    unawaited(HostsPagePrefs.setView(ref.read(sharedPreferencesProvider), mode));
    setState(() {});
  }

  bool get _listView => _viewMode == HostsViewMode.list;

  /// The sections folded away on this device.
  Set<HostsSection> get _folded => HostsPagePrefs.folded(ref.watch(sharedPreferencesProvider));
  void _toggleFold(HostsSection section) {
    unawaited(HostsPagePrefs.setFolded(ref.read(sharedPreferencesProvider), section, !_folded.contains(section)));
    setState(() {});
  }

  /// The list's columns, as this device last had them.
  Set<HostsListColumn> get _listColumns => HostsPagePrefs.columns(ref.watch(sharedPreferencesProvider));
  void _setListColumns(Set<HostsListColumn> columns) {
    unawaited(HostsPagePrefs.setColumns(ref.read(sharedPreferencesProvider), columns));
    setState(() {});
  }

  /// A column's head was clicked: sort by it, or, where it is the sort
  /// already, the other way round. The toolbar's Sort says the same sort.
  void _sortByColumn(HostSortMode mode) {
    final reversed = ref.read(hostSortReversedProvider.notifier);
    if (ref.read(hostSortModeProvider) == mode) {
      reversed.state = !reversed.state;
    } else {
      _sortMode = mode;
      reversed.state = false;
    }
    setState(() {});
  }

  /// The host open in the panel (a click selects, a double click connects).
  String? _selectedHostId;

  /// The workspace open in the panel at the right (it stands where a host's
  /// panel stands: one or the other).
  String? _selectedWorkspaceId;

  /// That panel opens on its editor (the card's pencil, a right click).
  bool _workspaceEditing = false;

  /// Counts the pencil's presses: each opens the panel's editor anew, also on
  /// the workspace it just saved.
  int _workspacePick = 0;

  /// Takes the keyboard when a host is selected, so Enter connects it and
  /// Escape closes the panel.
  final _pageFocus = FocusNode(debugLabel: 'HostsPage');

  /// The hosts in the order the page shows them now (the grid puts the
  /// pinned first, the list does not): what Ctrl+A selects, what a
  /// Shift-click's range runs along, and the order the bulk bar opens them.
  List<String> _shownOrder = const [];

  /// The bulk bar, for the Delete key while hosts are selected.
  final _bulkBar = GlobalKey<HostBulkActionBarState>();

  /// The bulk editor of the selection is open at the right (Edit..., and Tags
  /// and Move to group), on
  /// [_bulkFocus] where given.
  bool _bulkEditOpen = false;
  BulkField? _bulkFocus;

  /// Opens the bulk editor of the selection, on [focus].
  void _openBulkEdit(BulkField? focus) {
    if (!ref.read(hostMultiSelectProvider).hasSelection) return;
    setState(() {
      _bulkEditOpen = true;
      _bulkFocus = focus;
      _selectedWorkspaceId = null;
    });
  }

  void _closeBulkEdit() {
    if (_bulkEditOpen) setState(() => _bulkEditOpen = false);
  }

  /// The column the page scrolls, and the host grid in it: the grid is made
  /// to reach the foot of the window ([_gridFill]), so a band can start in
  /// the empty space below the last row.
  final _scrollColumn = GlobalKey();
  final _gridBox = GlobalKey();
  double _gridFill = 0;

  /// Whether the keyboard is in a text field (the search): its own keys win.
  static bool _typing() =>
      FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;

  /// Ctrl+A (Cmd+A on a Mac) selects every host shown, and Delete (Backspace
  /// on a Mac too) deletes the selected ones, once asked; neither while the
  /// keyboard is in a text field, where they edit the text.
  KeyEventResult _onPageKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _typing()) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.keyA && hostToggleKeyHeld() && !keys.isShiftPressed && !keys.isAltPressed) {
      if (_shownOrder.isEmpty) return KeyEventResult.ignored;
      ref.read(hostSelectionPlaceProvider.notifier).state = HostSelectionPlace.page;
      ref.read(hostMultiSelectProvider.notifier).selectAll(_shownOrder);
      return KeyEventResult.handled;
    }
    final select = ref.read(hostMultiSelectProvider);
    final deleteKey = event.logicalKey == LogicalKeyboardKey.delete ||
        (defaultTargetPlatform == TargetPlatform.macOS && event.logicalKey == LogicalKeyboardKey.backspace);
    if (deleteKey && select.active && select.hasSelection) {
      _bulkBar.currentState?.deleteSelected();
      return KeyEventResult.handled;
    }
    // The host open in the panel: E edits it, Ctrl+Enter (Cmd+Enter) opens
    // it in a new tab, Delete deletes it once asked (the keys its menu says).
    final entry = _panelEntry();
    if (entry == null || select.active || keys.isAltPressed) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.keyE && !hostToggleKeyHeld() && !keys.isShiftPressed) {
      unawaited(_editHost(entry.data.id));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter && hostToggleKeyHeld()) {
      openHostInNewTab(context, ref, entry.connectionWithDetails.connection);
      return KeyEventResult.handled;
    }
    if (deleteKey && mayChangeItem(ref, 'host', entry.data.id, delete: true, watch: false)) {
      unawaited(_confirmDeleteSingle(entry));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The host open in the panel, as the page shows it; null where none is.
  ({HostCardData data, ConnectionWithDetails connectionWithDetails})? _panelEntry() {
    final id = _selectedHostId;
    if (id == null) return null;
    return _shownEntries.where((e) => e.data.id == id).firstOrNull;
  }

  /// The hosts as the page shows them now (see [_shownOrder]).
  List<({HostCardData data, ConnectionWithDetails connectionWithDetails})> _shownEntries = const [];

  /// Measures how far the host grid must reach to fill the window below it
  /// ([_gridFill]), after a frame has laid the page out.
  void _measureGridFill(double viewport, double bottomPad) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final grid = _gridBox.currentContext?.findRenderObject();
      final column = _scrollColumn.currentContext?.findRenderObject();
      if (grid is! RenderBox || column is! RenderBox || !grid.attached || !column.attached) return;
      final top = grid.localToGlobal(Offset.zero, ancestor: column).dy;
      final fill = (viewport - top - bottomPad).clamp(0.0, double.infinity);
      if ((fill - _gridFill).abs() > 0.5) setState(() => _gridFill = fill);
    });
  }
  // Group filter is shared app-wide via [selectedGroupFilterProvider] so it
  // survives opening a host and returning to the list, the same way the sort
  // mode and tag filters do. Read during build via the getter; writes go
  // through the setter into the provider.
  String? get _selectedGroupId => ref.watch(selectedGroupFilterProvider);
  set _selectedGroupId(String? id) =>
      ref.read(selectedGroupFilterProvider.notifier).state = id;
  // Sort mode is shared with the desktop host sidebar via [hostSortModeProvider]
  // so a sort picked in either place applies to both. Read during build via the
  // getter; writes go through the setter into the provider.
  HostSortMode get _sortMode => ref.watch(hostSortModeProvider);
  set _sortMode(HostSortMode m) =>
      ref.read(hostSortModeProvider.notifier).state = m;

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _pageFocus.dispose();
    super.dispose();
  }

  /// Pure IPv4 address with optional :port (e.g. `192.168.10.21` or `192.168.10.21:2222`).
  static final _ipv4Pattern = RegExp(
    r'^(\d{1,3}\.){3}\d{1,3}(:\d{1,5})?$',
  );

  /// Returns true only for inputs that should trigger a direct connect on
  /// Enter / Connect-button click: `user@host[:port]` (read as everywhere it
  /// is typed, [parseQuickTarget], an IPv6 address in brackets too), or a
  /// bare IPv4 or IPv6 address (with optional port). Freeform text like
  /// `grayog` stays in search-only mode regardless of how the user submits
  /// the field.
  bool get _isConnectableQuery {
    final q = _searchQuery.trim();
    final target = q.isEmpty ? null : parseQuickTarget(q);
    if (target == null) return false;
    return target.user != null || _ipv4Pattern.hasMatch(q) || target.host.contains(':');
  }

  /// Friendly failure state for the connections stream - no raw exception
  /// dumped into the UI: a plain message, a Retry that re-runs the query by
  /// invalidating the provider, and the details to copy (3.0:
  /// the error went to a console nobody sees).
  Widget _buildErrorState(Object error, StackTrace stackTrace) {
    AppLogger.error('Failed to load connections', error, stackTrace);
    return LoadErrorState(
      icon: LucideIcons.cloudOff,
      message: AppLocalizations.of(context)!.hostsHomeLoadError,
      where: 'Loading the hosts',
      error: error,
      stack: stackTrace,
      onRetry: () => ref.invalidate(connectionsWithDetailsProvider),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final connectionsAsync = ref.watch(connectionsWithDetailsProvider);
    final groupsAsync = ref.watch(connectionGroupsProvider);
    final sessions = ref.watch(activeSessionsProvider);
    final healthMap = ref.watch(connectionHealthProvider);
    final osCache = ref.watch(osDetectionCacheProvider);
    // Tag assignments map (connectionId → tags) drives both the tag
    // chips on each host card and the tag-filter pass below. We grab
    // it once at the top so child widgets don't re-watch the stream
    // dozens of times.
    final tagAssignments = ref.watch(allTagAssignmentsProvider).valueOrNull ??
        const <String, List<String>>{};
    final activeTagFilters = ref.watch(activeTagFiltersProvider);
    // Watched so entering/leaving arrange mode (B5) rebuilds the section
    // list - `_buildGroupSections` reads it to switch the grid to a
    // reorderable list.
    ref.watch(hostArrangeModeProvider);
    // Watched (not just read in _responsiveColumns) so changing the host-card
    // "Columns" setting rebuilds the grid immediately, instead of only taking
    // effect the next time the page happens to rebuild for another reason.
    ref.watch(hostCardSettingsProvider);

    // Esc exits multi-select mode anywhere on the page (only when in
    // selection mode - otherwise a global Esc keeps doing whatever it
    // does for the rest of the shell). Wrapped around the whole tree so
    // the binding holds even while the search field has focus, but the
    // search field's own Esc handler will fire first if it's active.
    return Listener(
      // A press on the page makes it the place of the selection: its bulk bar
      // shows, not the drawer's (the two showed one selection twice).
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => ref.read(hostSelectionPlaceProvider.notifier).state = HostSelectionPlace.page,
      child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          // The host menu first (opened with the mouse, the keyboard stays
          // on the page, not in the menu).
          if (_hostMenu.isOpen) {
            _hostMenu.close();
          } else if (_bulkEditOpen) {
            _closeBulkEdit();
          } else if (ref.read(hostArrangeModeProvider)) {
            ref.read(hostArrangeModeProvider.notifier).exit();
          } else if (ref.read(hostMultiSelectProvider).active) {
            ref.read(hostMultiSelectProvider.notifier).exit();
          } else if (_selectedHostId != null) {
            setState(() => _selectedHostId = null);
          } else if (_selectedWorkspaceId != null) {
            setState(() => _selectedWorkspaceId = null);
          }
        },
        // Enter connects the host open in the panel (the search field's own
        // Enter, connecting its top match, wins while it has focus).
        const SingleActivator(LogicalKeyboardKey.enter): () {
          final id = _selectedHostId;
          if (id == null || _searchFocusNode.hasFocus) return;
          final item = (ref.read(connectionsWithDetailsProvider).valueOrNull ??
                  const <ConnectionWithDetails>[])
              .where((c) => c.connection.id == id)
              .firstOrNull;
          if (item != null) widget.onConnectTo(item);
        },
      },
      child: Focus(
        // Never takes focus by itself (it must not steal it from the search
        // field); selecting a host focuses it on purpose, so Enter and
        // Escape reach the shortcuts above.
        focusNode: _pageFocus,
        descendantsAreFocusable: true,
        onKeyEvent: _onPageKey,
        // Not a stop of a screen reader's: as one, it gathered the page's
        // words under one node ("Connect", then the panel's host) that the
        // reader read as a single thing the size of the page.
        includeSemantics: false,
        child: connectionsAsync.when(
          // A reload (another space) keeps what is shown until its rows come: a spinner here was a flash.
          skipLoadingOnReload: true,
          loading: () => Center(child: CircularProgressIndicator(color: ZestColors.accentPrimary)),
          error: (e, st) => _buildErrorState(e, st),
          data: (allConnections) {
        // Where its person turned on the checks of whether hosts can be
        // reached (Settings; off until then, since a host sees and logs every
        // check), this page asks for its hosts to be checked and keeps the
        // list current. startPeriodicChecks self-guards against duplicate
        // timers on rebuild; updateConnections keeps the list fresh as hosts
        // are added / removed. Scheduled post-frame so we never mutate a
        // provider during build.
        final healthChecksOn = ref.watch(healthChecksEnabledProvider);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final health = ref.read(connectionHealthProvider.notifier);
          if (healthChecksOn) {
            final conns = allConnections.map((c) => c.connection).toList();
            health.updateConnections(conns);
            health.startPeriodicChecks(conns);
          } else {
            // Off: nothing is asked for (and the checks themselves refuse).
            health.stopPeriodicChecks();
          }
        });
        final groups = groupsAsync.valueOrNull ?? <ConnectionGroup>[];

        // ── Derive the header's counts ──
        // "open" = hosts with a session up or coming up. "need attention" =
        // Server Monitor's own verdict (a metric over its threshold, or a
        // watched host that cannot be reached) plus any unresolved changed
        // host key, so the Hosts page never disagrees with the monitor.
        final monitorViews = ref.watch(monitoredHostViewsProvider);
        final changedKeysForCount = ref.watch(changedHostKeysProvider);
        bool needsAttention(ConnectionWithDetails c) => hostNeedsAttention(
              monitorViews[c.connection.id],
              changedHostKey: changedKeysForCount.contains(
                  '${normalizeKnownHost(c.connection.host)}:${c.connection.port}'),
            );

        // Workspaces (§7b). The
        // header gains a workspace count alongside hosts/reachable, and a
        // Workspaces section sits above Recent.
        final workspaces = ref.watch(workspacesProvider);
        final hasSession = sessions.values.any((s) =>
            s.status == SessionStatus.connected ||
            s.status == SessionStatus.connecting);

        // ── Build HostGroup list ──
        final hostGroups = groups.map((g) {
          final connsInGroup = allConnections.where((c) => c.connection.groupId == g.id);
          final onlineInGroup = connsInGroup.where((c) {
            final h = healthMap[c.connection.id];
            return h != null && h.status == ConnectionHealth.online;
          }).length;
          return HostGroup(
            id: g.id,
            name: Redactable.group(g.name).displayIn(ref),
            // Unified resolution - a user-picked colorIndex wins; otherwise
            // the legacy name-hash color (shared with the desktop surfaces).
            color: resolveGroupColorToken(
                colorIndex: g.colorIndex, name: g.name),
            // A custom colorValue overrides the token everywhere the group
            // chip is drawn.
            colorOverride:
                g.colorValue != null ? Color(g.colorValue!) : null,
            // A user-picked folder icon wins; otherwise keep the smart
            // name-derived default (homelab → home, staging → flask, …).
            icon: g.iconCodePoint != null
                ? folderIconFor(g.iconCodePoint)
                : defaultGroupIcon(g.name),
            hostCount: connsInGroup.length,
            onlineCount: onlineInGroup,
          );
        }).toList();

        // ── Filter hosts ──
        var filteredConnections = allConnections.toList();
        if (_selectedGroupId == GroupFilterChips.ungroupedFilterId) {
          filteredConnections = filteredConnections
              .where((c) => c.connection.groupId == null)
              .toList();
        } else if (_selectedGroupId != null) {
          filteredConnections = filteredConnections.where((c) => c.connection.groupId == _selectedGroupId).toList();
        }
        // Crate filter: an Orchard on screen shows one Crate's hosts when one
        // is picked (3.0).
        final orchardOnScreen =
            kOrchardsEnabled ? ref.watch(activeOrchardProvider).valueOrNull : null;
        final crateFilter =
            orchardOnScreen == null ? null : ref.watch(selectedCrateFilterProvider);
        if (orchardOnScreen != null && crateFilter != null) {
          final hostCrates = ref.watch(hostCratesProvider).valueOrNull ?? const {};
          filteredConnections = filteredConnections
              .where((c) =>
                  crateOfHost(c.connection.id, hostCrates, orchardOnScreen) == crateFilter)
              .toList();
        }
        // Only those with a session open, and only these kinds (Filter).
        if (_openOnly) {
          filteredConnections =
              filteredConnections.where((c) => hostIsOpen(sessions, c.connection.id)).toList();
        }
        if (_kinds.isNotEmpty) {
          filteredConnections =
              filteredConnections.where((c) => _kinds.contains(_kindOf(c.connection.protocol))).toList();
        }
        // "Need attention" (the header's toggle): only those hosts.
        if (_attentionOnly) {
          filteredConnections =
              filteredConnections.where(needsAttention).toList();
        }
        // Tag filter - OR across selected tags. A host matches if any
        // of its tags appears in [activeTagFilters]. We fall back to
        // an empty list when the host has no tags so `.any` short-
        // circuits without throwing.
        if (activeTagFilters.isNotEmpty) {
          filteredConnections = filteredConnections.where((c) {
            final hostTags = tagAssignments[c.connection.id] ?? const [];
            return hostTags.any(activeTagFilters.contains);
          }).toList();
        }
        // When the input looks like a connect target (user@host or IP), don't
        // bother filtering the host list - the user is about to dispatch a
        // direct connect, not browse. For everything else (freeform text),
        // do a substring match against label and host.
        // A share link in the box is a host to add, not words to find.
        if (_searchQuery.isNotEmpty && !_isConnectableQuery && !looksLikeShareLink(_searchQuery)) {
          final q = _searchQuery.toLowerCase();
          filteredConnections = filteredConnections.where((c) {
            // Tags are also searchable - typing "prod" should surface
            // hosts tagged `prod` even if neither the label nor the
            // address contains that string.
            final hostTags = tagAssignments[c.connection.id] ?? const [];
            return c.connection.label.toLowerCase().contains(q) ||
                c.connection.host.toLowerCase().contains(q) ||
                hostTags.any((t) => t.contains(q));
          }).toList();
        }

        // ── Map to HostCardData ──
        // Pin state: read the SAME source the legacy Pinned shelf + the
        // context-menu label use (the per-device prefs set) so the card
        // badge never disagrees with them. The synced `pinned` column is
        // dual-written for a future full consolidation but isn't read here.
        final pinnedIds = ref.watch(pinnedHostsProvider);
        // Hosts with an unresolved changed-key event, keyed by the same
        // normalized `host:port` the verify flow writes (F2).
        final changedHostKeys = ref.watch(changedHostKeysProvider);
        final tmuxCounts = ref.watch(tmuxSessionCountsProvider);
        final kexRefused = ref.watch(kexRefusedHostsProvider);
        final hostRules = ItemRules.of(ref, 'host');


        final hostCards = filteredConnections.map((c) {
          final conn = c.connection;
          final identity = c.identity;
          final group = c.group;

          final user = identity?.username ?? 'root';
          // Lean subtitle: just `user@host`, in mono. The protocol suffix is
          // appended ONLY for non-SSH transports (Mosh / Telnet / Serial /
          // Local) \u2014 "SSH" is the default and never shown. Tags no longer ride
          // the subtitle (they still drive filtering / search).
          final protoSuffix = hostProtocolSuffix(conn.protocol);
          // One a team's record brought that opens no shell here says so.
          final subtitle = orchardOnScreen != null && teamMayNotOpenWith(conn.protocol)
              ? AppLocalizations.of(context)!.teamHostLocalShellRow
              // A remote screen (VNC or RDP): where it listens and the host it
              // is reached through, not a user it has none of (an RDP host said
              // "root@10.0.0.40" until it got the line too).
              : ConnectionProtocol.storedIsScreen(conn.protocol)
                  ? screenCardSubtitleOf(conn,
                      labelOf: (id) {
                        final c = allConnections.where((h) => h.connection.id == id).firstOrNull?.connection;
                        return c == null ? null : (c.label.isNotEmpty ? c.label : c.host);
                      },
                      via: AppLocalizations.of(context)!.pfPageVia)
              : protoSuffix == null
                  ? '$user@${conn.host}'
                  : '$user@${conn.host} \u00b7 $protoSuffix';

          final osKind = osCache[conn.id];
          final osId = osKind != null ? osCatalogIdFor(osKind) : null;

          // The group's OWN resolved colour (custom colorValue ?? picked
          // colorIndex ?? name-hash), resolved at render time and never copied
          // onto the host. Null when ungrouped. Feeds both the card's rail
          // inheritance and the group chip.
          final Color? groupColor = group != null
              ? resolveGroupColor(
                  colorValue: group.colorValue,
                  colorIndex: group.colorIndex,
                  name: group.name,
                )
              : null;

          final hasActiveSession = hostIsOpen(sessions, conn.id);
          // How many are open or opening: what its card says ("2 open").
          final openSessions = sessions.values
              .where((s) =>
                  s.connectionId == conn.id &&
                  (s.status == SessionStatus.connected || s.status == SessionStatus.connecting))
              .length;

          // Status is driven by SSH session state - what the user cares
          // about is "am I connected?", not "did a TCP ping reach the
          // host?". The legacy `unknown` state has been retired so every
          // unsessioned host reads as "Offline" instead of "Unknown".
          final relevantSession = sessions.values
              .where((s) => s.connectionId == conn.id)
              .toList();
          // Pick the most-meaningful session for status: prefer
          // connected/connecting over disconnected/error, so a user with
          // both a live session and a stale errored one still sees green.
          SessionStatus? primary;
          for (final s in relevantSession) {
            if (s.status == SessionStatus.connected) {
              primary = SessionStatus.connected;
              break;
            }
            if (s.status == SessionStatus.connecting) {
              primary = SessionStatus.connecting;
            } else {
              primary ??= s.status;
            }
          }
          final HostStatus status = switch (primary) {
            SessionStatus.connected => HostStatus.online,
            SessionStatus.connecting => HostStatus.connecting,
            SessionStatus.error => HostStatus.disconnected,
            SessionStatus.disconnected => HostStatus.disconnected,
            null => HostStatus.offline,
          };

          return (
            data: HostCardData(
              id: conn.id,
              name: conn.label.isNotEmpty ? conn.label : conn.host,
              subtitle: subtitle,
              osId: osId,
              // A remote screen (4.0) shows a screen where nothing else is chosen.
              iconId: conn.iconId ?? defaultIconIdFor(conn.protocol),
              customIcon: conn.customIcon,
              iconColor: conn.iconColor,
              cloud: CloudLink.decode(conn.cloudSource),
              // Colour-label channel (raw) - the card resolves the rail via
              // AppColors.resolveConnectionLabelColor: host override ??
              // inherited group colour ?? neutral grey.
              colorValue: conn.colorValue,
              colorIndex: conn.colorIndex,
              // Group channel - the resolved group colour (rail inheritance +
              // chip dot) and the group name (chip label). Both null when the
              // host is ungrouped.
              groupColor: groupColor,
              groupName: group?.name,
              // Show the group CHIP only in FLAT renders (search results or a
              // single-group filter), where the per-group section headers are
              // gone and the chip is the card's only group signal. In the
              // grouped-sections view the SectionLabel already names the group,
              // so the chip would be redundant. Uses the SAME `flatView` flag
              // that selects the flat-vs-sectioned render branch below, so the
              // two can never disagree.
              showGroupChip: false,
              status: status,
              hasActiveSession: hasActiveSession,
              openSessions: openSessions,
              // conn.sizeTier is not read: every host is one card (the
              // per-host size was taken away). The column and its sync field stay
              // as they were, so nothing migrates and older apps keep theirs.
              pinned: pinnedIds.contains(conn.id),
              note: conn.note,
              lastConnected: conn.lastConnected,
              hasChangedHostKey: changedHostKeys
                  .contains('${normalizeKnownHost(conn.host)}:${conn.port}'),
              tmuxSessions: tmuxCounts[conn.id] ?? 0,
              healthChips: healthChipsFor(monitorViews[conn.id], l10n),
              // The list's Health cell, and its order (a changed host key
              // needs attention too).
              health: hostHealthSummary(
                monitorViews[conn.id],
                l10n,
                changedHostKey: changedHostKeys.contains('${normalizeKnownHost(conn.host)}:${conn.port}'),
              ),
              tags: tagAssignments[conn.id] ?? const [],
              // Refused for an old key exchange, with the mode off (3.4).
              oldKeyExchange: kexRefused.contains(conn.id) && !conn.compatibilityMode,
              // In a team's vault this account only connects to: an edit of
              // the selection leaves it as it is.
              // (Not while the team is still being read: nothing is
              // known of it yet.)
              connectOnly: orchardOnScreen != null && !hostRules.loading && !hostRules.mayChange(conn.id),
            ),
            connectionWithDetails: c,
          );
        }).toList();

        // Apply sort BEFORE handing the cards to the grid. The sort
        // helper is stable so user-driven reorders survive future
        // refilters (e.g. typing into the search box).
        final sorted = sortHostCards(
          cards: hostCards,
          mode: _sortMode,
          sessions: sessions,
        );
        // A second click on the list's active column turns the order round.
        final sortedHostCards = ref.watch(hostSortReversedProvider) ? sorted.reversed.toList() : sorted;

        // The group tiles: each group's hosts, how many are open or need
        // attention, and the kinds of host in it.
        final groupTiles = <GroupTileData>[];
        for (final g in hostGroups) {
          final inGroup = allConnections.where((c) => c.connection.groupId == g.id).toList();
          groupTiles.add(GroupTileData(
            id: g.id,
            name: g.name,
            color: g.accentColor,
            icon: g.icon,
            hostCount: inGroup.length,
            openCount: inGroup.where((c) => hostIsOpen(sessions, c.connection.id)).length,
            kinds: _kindsOf(inGroup, osCache),
          ));
        }
        final ungroupedHosts = allConnections.where((c) => c.connection.groupId == null).toList();
        final ungroupedTile = ungroupedHosts.isEmpty
            ? null
            : GroupTileData(
                id: null,
                name: l10n.hostPanelUngrouped,
                color: ZestColors.textTertiary,
                icon: LucideIcons.layers,
                hostCount: ungroupedHosts.length,
                openCount: ungroupedHosts.where((c) => hostIsOpen(sessions, c.connection.id)).length,
              );
        final knownTags = {for (final tags in tagAssignments.values) ...tags}.toList()..sort();
        final knownKinds = {for (final c in allConnections) _kindOf(c.connection.protocol)};

        // The host open in the panel, while it still exists.
        final selectedEntry = _selectedHostId == null
            ? null
            : hostCards
                    .where((e) => e.data.id == _selectedHostId)
                    .firstOrNull ??
                // Filtered out of the grid: still described in the panel.
                () {
                  final c = allConnections
                      .where((c) => c.connection.id == _selectedHostId)
                      .firstOrNull;
                  return c == null
                      ? null
                      : (
                          data: HostCardData(
                            id: c.connection.id,
                            name: c.connection.label.isNotEmpty
                                ? c.connection.label
                                : c.connection.host,
                            subtitle: c.connection.host,
                            osId: null,
                            status: HostStatus.offline,
                            hasActiveSession: false,
                            colorValue: c.connection.colorValue,
                            colorIndex: c.connection.colorIndex,
                            // Its group's colour, as in the grid: what its
                            // label, and an icon that follows the label,
                            // are drawn in.
                            groupColor: c.group == null
                                ? null
                                : resolveGroupColor(
                                    colorValue: c.group!.colorValue,
                                    colorIndex: c.group!.colorIndex,
                                    name: c.group!.name,
                                  ),
                            iconId: c.connection.iconId,
                            customIcon: c.connection.customIcon,
                            iconColor: c.connection.iconColor,
                            cloud: CloudLink.decode(c.connection.cloudSource),
                          ),
                          connectionWithDetails: c,
                        );
                }();

        final page = _buildScrollView(
          rawGroups: groups,
          hostCards: sortedHostCards,
          workspaces: workspaces,
          hasSession: hasSession,
          totalHostCount: allConnections.length,
          filteredHostCount: filteredConnections.length,
          groupTiles: groupTiles,
          ungroupedTile: ungroupedTile,
          knownTags: knownTags,
          knownKinds: knownKinds,
        );
        // One pane at the right: while the docked editor is open it stands
        // where the panel stands, and the panel comes back (on the host it
        // showed) once the editor closes.
        if (ref.watch(connectionEditorTargetProvider) != null) return page;
        // The bulk editor of the selection, at the right; the page under a
        // veil beside it, its hosts as they are while it is open.
        final selection = ref.watch(hostMultiSelectProvider);
        if (_bulkEditOpen && selection.active && selection.hasSelection) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  children: [
                    page,
                    Positioned.fill(
                      child: AbsorbPointer(
                        key: const ValueKey('host-bulk-veil'),
                        child: ColoredBox(color: Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.6)),
                      ),
                    ),
                  ],
                ),
              ),
              HostBulkEditPanel(
                key: ValueKey('host-bulk-edit-${_bulkFocus?.name}'),
                hostIds: [
                  for (final id in _shownOrder)
                    if (selection.selected.contains(id)) id,
                  for (final id in selection.selected)
                    if (!_shownOrder.contains(id)) id,
                ],
                focus: _bulkFocus,
                onClose: _closeBulkEdit,
                onUnselect: (ids) => ref.read(hostMultiSelectProvider.notifier).removeAll(ids),
                onApplied: (outcome, skipped) {
                  sayHostBulkApplied(context, ref.read(databaseProvider), outcome, skipped: skipped);
                  ref.read(hostMultiSelectProvider.notifier).exit();
                  _closeBulkEdit();
                },
              ),
            ],
          );
        }
        final selectedWorkspace = _selectedWorkspaceId == null
            ? null
            : workspaces.where((w) => w.id == _selectedWorkspaceId).firstOrNull;
        if (selectedWorkspace != null) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: page),
              WorkspacePanel(
                // A new panel for each pick: the pencil on a card opens on its
                // editor, a click on another card on its details.
                key: ValueKey('workspace-panel-${selectedWorkspace.id}-$_workspacePick'),
                workspace: selectedWorkspace,
                startEditing: _workspaceEditing,
                onClose: () => setState(() => _selectedWorkspaceId = null),
                onOpen: () => launchWorkspaceFromSurface(context, ref, selectedWorkspace.id),
              ),
            ],
          );
        }
        if (selectedEntry == null) return page;
        final item = selectedEntry.connectionWithDetails;
        final panel = HostPanel(
              key: ValueKey('host-panel-${item.connection.id}'),
              card: selectedEntry.data,
              item: item,
              onClose: () => setState(() => _selectedHostId = null),
              onConnect: () => widget.onConnectTo(item),
              onSwitchTo: (sid) => widget.onSwitchToSession?.call(sid),
              onOpenSftp: () => widget.onOpenSftp?.call(item),
              onOpenTmux: () => widget.onOpenTmux?.call(item),
              onEdit: () => _editHost(item.connection.id),
              // Its group's chip: only that group's hosts on the page.
              onShowGroup: (groupId) => setState(() => _selectedGroupId = groupId),
              onOpenInSplit: () => openHostInSplit(context, ref, item.connection),
              onDuplicate: mayAddScreenSpace(ref)
                  ? () async {
                      try {
                        await ref
                            .read(connectionCrudProvider)
                            .duplicate(item.connection, label: l10n.homeCopyLabelSuffix(item.connection.label));
                      } catch (e) {
                        if (context.mounted) {
                          showTopSnackBar(context, l10n.hostsHomeDuplicateError, isError: true, details: '$e');
                        }
                      }
                    }
                  : null,
              onOpenMonitor: () => ref.read(activeSidebarNavProvider.notifier).state = NavSection.monitor,
              onOpenHistory: () => ref.read(activeSidebarNavProvider.notifier).state = NavSection.commandHistory,
              // Its own screens (4.0): a screen host opens as any host does.
              onOpenScreen: widget.onConnectTo,
              // Touch sized: the host's menu under a more button at its foot.
              onMore: (at) => _showHostContextMenu(at, selectedEntry),
            );
        // A tablet held upright (4.0): the panel is a sheet over the page, at
        // its right, the page under a scrim that closes it; beside the page
        // it left the hosts one narrow column.
        final screen = MediaQuery.sizeOf(context);
        if (touchSizedAt(context) && screen.height > screen.width) {
          return Stack(
            children: [
              Positioned.fill(child: page),
              Positioned.fill(
                child: GestureDetector(
                  key: const ValueKey('host-panel-scrim'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _selectedHostId = null),
                  child: ColoredBox(color: Colors.black.withValues(alpha: 0.4)),
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                bottom: 0,
                child: Material(
                  key: const ValueKey('host-panel-sheet'),
                  elevation: 12,
                  color: Colors.transparent,
                  child: panel,
                ),
              ),
            ],
          );
        }
        return Row(
          // The page keeps the whole height beside the panel: a Row centres
          // its children, and a page shorter than the window floated to the
          // middle under an empty band.
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: page),
            panel,
          ],
        );
          },
        ),
      ),
    ),
    );
  }

  Widget _buildScrollView({
    required List<ConnectionGroup> rawGroups,
    required List<({HostCardData data, ConnectionWithDetails connectionWithDetails})> hostCards,
    required List<WorkspaceView> workspaces,
    required bool hasSession,
    required int totalHostCount,
    required int filteredHostCount,
    required List<GroupTileData> groupTiles,
    required GroupTileData? ungroupedTile,
    required List<String> knownTags,
    required Set<String> knownKinds,
  }) {
    final l10n = AppLocalizations.of(context)!;
    // The Enter-to-connect target: the top of the currently-visible list.
    final topMatch = hostCards.isNotEmpty ? hostCards.first.connectionWithDetails : null;
    final filterCount = (_selectedGroupId != null ? 1 : 0) +
        ref.watch(activeTagFiltersProvider).length +
        _kinds.length +
        (_openOnly ? 1 : 0) +
        (_attentionOnly ? 1 : 0);
    final mayAdd = mayAddScreenSpace(ref);
    // The hosts as they are drawn below, in order: the grid puts the pinned
    // first, the list keeps the sort as it is.
    final folded = _folded;
    final shownCards = folded.contains(HostsSection.hosts)
        ? const <({HostCardData data, ConnectionWithDetails connectionWithDetails})>[]
        : _listView
            ? hostCards
            : _pinnedFirst(hostCards);
    // Active first: the hosts with an open session apart, the last used first.
    // Null where it is off, or none is open: the page as it always was.
    final used = ref.watch(hostUseProvider);
    final activeCards = ref.watch(activeFirstProvider(HostListPlace.hostsPage))
        ? ([for (final c in shownCards) if (c.data.hasActiveSession) c]
          ..sort((a, b) {
            DateTime at(HostCardData d) => used[d.id] ?? d.lastConnected ?? DateTime.fromMillisecondsSinceEpoch(0);
            return at(b.data).compareTo(at(a.data));
          }))
        : const <({HostCardData data, ConnectionWithDetails connectionWithDetails})>[];
    final activeFirstCards = activeCards.isEmpty
        ? null
        : (active: activeCards, rest: [for (final c in shownCards) if (!c.data.hasActiveSession) c]);
    _shownOrder = [for (final c in activeFirstCards == null ? shownCards : [...activeCards, ...activeFirstCards.rest]) c.data.id];
    _shownEntries = shownCards;
    final band = HostsBand(
      lead: [
        BandSplitButton(
          label: l10n.hostsNewHost,
          icon: LucideIcons.plus,
          menuTooltip: l10n.hostsNewMenuTip,
          onPressed: mayAdd ? () => ConnectionEditScreen.showAdaptive(context) : null,
          onMenu: _openNewMenu,
        ),
        // Only where this device has a shell of its own: not an iPhone or an
        // iPad, also in the computer's layout.
        if (localTerminalOnThisDevice)
          BandButton(
            key: const ValueKey('hosts-terminal'),
            label: l10n.hostsToolbarTerminal,
            icon: LucideIcons.terminalSquare,
            tooltip: l10n.hostsToolbarTerminalTip,
            onPressed: _openLocalTerminal,
          ),
      ],
      // With the panel or the editor open: its icon, so the views keep
      // their place at the end of the one row.
      leadCompact: localTerminalOnThisDevice
          ? BandButton(
              key: const ValueKey('hosts-terminal-compact'),
              label: l10n.hostsToolbarTerminal,
              icon: LucideIcons.terminalSquare,
              iconOnly: true,
              onPressed: _openLocalTerminal,
            )
          : null,
      field: HostsQuickField(
        controller: _searchController,
        focusNode: _searchFocusNode,
        width: double.infinity,
        onChanged: (v) {
          // A share link pasted into the empty box goes straight to the
          // question of whether to add its host ("add new host,
          // paste that link, done").
          if (_searchQuery.isEmpty && looksLikeShareLink(v)) {
            _addShareLink(v);
            return;
          }
          setState(() => _searchQuery = v);
        },
        onSubmitted: () => _submitQuick(topMatch),
        onConnect: _isConnectableQuery ||
                looksLikeShareLink(_searchQuery) ||
                (_searchQuery.trim().isNotEmpty && topMatch != null)
            ? () => _submitQuick(topMatch)
            : null,
      ),
      trailing: [
        // A team's vault on screen (Team > Vaults holds them all).
        if (kOrchardsEnabled && ref.watch(activeOrchardProvider).valueOrNull != null) const VaultPickerButton(),
        _SortButton(
          mode: _sortMode,
          onSelect: (m) => setState(() {
            _sortMode = m;
            ref.read(hostSortReversedProvider.notifier).state = false;
          }),
        ),
        Builder(
          builder: (ctx) => BandButton(
            key: const ValueKey('hosts-filter'),
            label: l10n.hostsToolbarFilter,
            icon: LucideIcons.listFilter,
            badge: filterCount,
            onPressed: () => _openFilterMenu(ctx, rawGroups, knownTags, knownKinds),
          ),
        ),
        // The Hosts page has no title line: its guide's "?" ends the band.
        const GuideHelpButton(feature: 'hosts'),
      ],
      toggles: HostsViewToggle(mode: _viewMode, onChanged: (m) => _viewMode = m),
    );

    // The host menu's anchor is a layer over the page that takes no pointer,
    // not the page's parent: a MenuAnchor counts its child as part of the
    // menu (one tap region group), so with the page as its child a click
    // anywhere on the page was inside the menu and left it open.
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: MenuAnchor(
              key: _hostMenuAnchor,
              controller: _hostMenu,
              style: _menuStyle,
              // The click that closes the menu does nothing else, as with the
              // app's other right-click menus (a route with a barrier).
              consumeOutsideTap: true,
              menuChildren: _hostMenuItems,
              child: const SizedBox.expand(),
            ),
          ),
        ),
        Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        band,
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final availableWidth = constraints.maxWidth;
              final cols = _responsiveColumns(availableWidth);
              // Content area = total width minus 24px padding on each side
              final contentWidth = availableWidth - 48;
              final itemWidth = _itemWidth(contentWidth, cols);
              // The compact grid: smaller cards, more of them in a row.
              final compact = _viewMode == HostsViewMode.compact;
              final hostItemWidth = compact ? _itemWidth(contentWidth, _compactColumns(availableWidth)) : itemWidth;
              final searching = _searchQuery.trim().isNotEmpty;
              final groupTileCount = groupTiles.length + (ungroupedTile == null ? 0 : 1) + 1;
              // Compact group cards: as many as fit at 160 or wider (six
              // across at 1280), folded to one row past that.
              // At least 220 wide, so a group's name reads whole (five in a row at
              // 1440, six past it).
              final groupCols = ((contentWidth + 8) / 228).floor().clamp(2, 8);
              final groupWidth = (contentWidth - 8 * (groupCols - 1)) / groupCols;
              final foldGroups = groupTileCount > groupCols && !_allGroups;
              // While hosts are selected the page ends with room for the bulk
              // bar and its hint, so the bar never covers the last row.
              final bottomPad = ref.watch(hostMultiSelectProvider).active ? 132.0 : 40.0;
              if (!_listView && !folded.contains(HostsSection.hosts)) _measureGridFill(constraints.maxHeight, bottomPad);

              // Stack so the bulk-action bar can float over the content while
              // the person is in multi-select mode.
              //
              // ScrollConfiguration strips mouse / unknown from the scroll
              // view's drag inputs: on desktop, click-and-drag is reserved for
              // the rubber-band recogniser and for dragging a host onto a group.
              // A mouse wheel still scrolls; a touchpad and touch drag-scroll.
              return Stack(
                children: [
                  ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context).copyWith(
                      dragDevices: const <PointerDeviceKind>{
                        PointerDeviceKind.touch,
                        PointerDeviceKind.stylus,
                        PointerDeviceKind.invertedStylus,
                        PointerDeviceKind.trackpad,
                      },
                    ),
                    child: SingleChildScrollView(
                      padding: EdgeInsets.only(bottom: bottomPad),
                      child: Column(
                        key: _scrollColumn,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // A team's state (held by a rule, stopped, keys waiting).
                          if (kOrchardsEnabled && ref.watch(activeOrchardProvider).valueOrNull != null)
                            const Padding(
                              padding: EdgeInsets.fromLTRB(24, 16, 24, 0),
                              child: OrchardStatusBanner(),
                            ),

                          // Workspaces, on the page as it opens (not while
                          // searching or filtering).
                          if (!searching && filterCount == 0) ...[
                            const SizedBox(height: 16),
                            ..._buildWorkspacesSection(workspaces, hasSession, itemWidth, cols),
                          ],

                          // Groups, as tiles (not while searching).
                          if (!searching) ...[
                            const SizedBox(height: 16),
                            SectionLabel(
                              l10n.hostsSectionGroups,
                              // No groups yet: no count (a 0 over the
                              // Ungrouped tile read as a contradiction
                              // before).
                              count: groupTiles.isEmpty ? null : groupTiles.length,
                              folded: folded.contains(HostsSection.groups),
                              onFold: () => _toggleFold(HostsSection.groups),
                              foldKey: const ValueKey('hosts-fold-groups'),
                              // The hint while a host is dragged; else, past one
                              // row, Show all.
                              trailingChild: ValueListenableBuilder<bool>(
                                valueListenable: hostDragActive,
                                builder: (context, dragging, _) => dragging
                                    ? _SectionHint(l10n.hostsGroupsDragHint)
                                    : groupTileCount > groupCols
                                        ? SectionLink(
                                            key: const ValueKey('groups-show-all'),
                                            label: _allGroups
                                                ? l10n.hostsGroupsShowFewer
                                                : l10n.hostsGroupsShowAll(groupTileCount - 1),
                                            onTap: () => setState(() => _allGroups = !_allGroups),
                                          )
                                        : const SizedBox.shrink(),
                              ),
                            ),
                            if (!folded.contains(HostsSection.groups))
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 24),
                              child: GroupTiles(
                                groups: groupTiles,
                                ungrouped: ungroupedTile,
                                columns: groupCols,
                                itemWidth: groupWidth,
                                limit: foldGroups ? groupCols : null,
                                selectedId: _selectedGroupId == GroupFilterChips.ungroupedFilterId
                                    ? GroupTiles.ungroupedId
                                    : _selectedGroupId,
                                onSelect: (id) => setState(() => _selectedGroupId =
                                    id == GroupTiles.ungroupedId ? GroupFilterChips.ungroupedFilterId : id),
                                onMenu: (id, at) => _openGroupMenu(id, at),
                                onDrop: _dropOnGroup,
                                carriedWith: _carriedWith,
                                onNewGroup: mayAdd ? () => GroupEditorPanel.showAdaptive(context) : null,
                              ),
                            ),
                          ],

                          // Hosts: one grid, or a list.
                          const SizedBox(height: 16),
                          // (No hint of the order at the end of the rule: the
                          // band's Sort says it.)
                          Row(
                            children: [
                              Expanded(
                                child: SectionLabel(
                                  l10n.hostsSectionHosts,
                                  count: filteredHostCount,
                                  folded: folded.contains(HostsSection.hosts),
                                  onFold: () => _toggleFold(HostsSection.hosts),
                                  foldKey: const ValueKey('hosts-fold-hosts'),
                                  // While selecting: the box that selects every
                                  // host shown (or none), how many are, and
                                  // Clear selection (the head of the
                                  // hosts), on the head's own line, so the
                                  // hosts stay where they are.
                                  trailingChild: ref.watch(hostMultiSelectProvider).active &&
                                          ref.watch(hostSelectionPlaceProvider) == HostSelectionPlace.page &&
                                          _shownOrder.isNotEmpty
                                      ? _SelectionHead(shown: _shownOrder)
                                      : null,
                                ),
                              ),
                              // Select: hosts to edit, open or delete together
                              // (Selecting while it is on; a
                              // click ends it). On the hosts' own line: the
                              // toolbar has no room left for it. (Active first
                              // is in the band's Sort since 4.0: a way of
                              // sorting.)
                              if (!folded.contains(HostsSection.hosts) && hostCards.isNotEmpty)
                                const Padding(
                                  padding: EdgeInsetsDirectional.only(end: 24),
                                  child: _SelectToggle(),
                                ),
                            ],
                          ),

                          if (folded.contains(HostsSection.hosts))
                            const SizedBox.shrink()
                          else if (hostCards.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 24),
                              child: _buildEmptyState(totalHostCount: totalHostCount),
                            )
                          else if (_listView)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 24),
                              child: HostsTable(
                                // Active first: the open ones lead its rows.
                                rows: activeFirstCards == null
                                    ? shownCards
                                    : [...activeFirstCards.active, ...activeFirstCards.rest],
                                columns: _listColumns,
                                onColumnsChanged: _setListColumns,
                                sortMode: _sortMode,
                                reversed: ref.watch(hostSortReversedProvider),
                                onSort: _sortByColumn,
                                selectedHostId: _selectedHostId,
                                onSelect: _showHost,
                                onSelectionGesture: _pageFocus.requestFocus,
                                onConnect: widget.onConnectTo,
                                onMenu: (position, entry) => _showHostContextMenu(position, entry),
                              ),
                            )
                          else ...[
                            // Active first: the
                            // hosts with an open session in a grid of their
                            // own, the last used first, and the rest under
                            // them. (Dragged into order they are not: that is
                            // the order of the whole list.)
                            if (activeFirstCards != null) ...[
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 24),
                                child: HostSectionHeading(active: true, count: activeFirstCards.active.length),
                              ),
                              const SizedBox(height: 6),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 24),
                                child: _buildHostGrid(activeFirstCards.active, hostItemWidth, compact: compact, fills: false),
                              ),
                              const SizedBox(height: 10),
                              if (activeFirstCards.rest.isNotEmpty) ...[
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 24),
                                  child: HostSectionHeading(active: false, count: activeFirstCards.rest.length),
                                ),
                                const SizedBox(height: 6),
                              ],
                            ],
                            Padding(
                              key: _gridBox,
                              padding: const EdgeInsets.symmetric(horizontal: 24),
                              child: _buildHostGrid(
                                activeFirstCards?.rest ?? shownCards,
                                hostItemWidth,
                                compact: compact,
                                showAddTile: true,
                                reorderable: activeFirstCards == null && _sortMode == HostSortMode.manual,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  // Floating bulk action bar - only paints in selection mode.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Offstage(
                      // (Not while the editor of the selection is open: the
                      // page is under its veil.)
                      offstage: ref.watch(hostSelectionPlaceProvider) != HostSelectionPlace.page || _bulkEditOpen,
                      child: HostBulkActionBar(
                      key: _bulkBar,
                      groups: rawGroups,
                      onCreateGroup: _createGroupAndMoveSelected,
                      shownOrder: _shownOrder,
                      onEdit: _openBulkEdit,
                    ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    ),
      ],
    );
  }

  /// Enter in the quick field, or its Connect: user@host:port connects as
  /// typed; other words connect the first host they found.
  void _submitQuick(ConnectionWithDetails? topMatch) {
    if (looksLikeShareLink(_searchQuery)) {
      _addShareLink(_searchQuery);
      return;
    }
    if (_isConnectableQuery) {
      _handleQuickConnect();
    } else if (_searchQuery.trim().isNotEmpty && topMatch != null) {
      widget.onConnectTo(topMatch);
    }
  }

  /// A share link typed or pasted into the quick field: the box empties and
  /// the link's host is shown, to be added on a yes ([addShareLinkFromText]).
  void _addShareLink(String text) {
    _searchController.clear();
    setState(() => _searchQuery = '');
    // ignore: discarded_futures
    addShareLinkFromText(context, text);
  }

  /// A terminal on this computer, in a tab of its own.
  void _openLocalTerminal() {
    final sessionId = openLocalTerminal(ref, AppLocalizations.of(context)!);
    if (sessionId == null) {
      showTopSnackBar(context, AppLocalizations.of(context)!.hostsHomeFreeTierLimit, isError: true);
      return;
    }
    ref.read(workTabsProvider.notifier).onSessionCreated(sessionId);
    ref.read(v3ActiveSessionTabProvider.notifier).state = sessionId;
  }

  /// The New host button's menu: a host, a group, quick connect, a serial
  /// line, importing, a host someone sent as a file or a share link.
  Future<void> _openNewMenu(Rect anchor) async {
    final l10n = AppLocalizations.of(context)!;
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;
    final mayAdd = mayAddScreenSpace(ref, watch: false);
    final value = await showMenu<String>(
      context: context,
      color: ZestColors.surfaceRaisedAlt,
      constraints: const BoxConstraints(minWidth: 268, maxWidth: 300),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: ZestColors.borderStrong),
      ),
      position: RelativeRect.fromLTRB(
        anchor.left,
        anchor.bottom + 6,
        overlay.size.width - anchor.left - 268,
        0,
      ),
      items: [
        if (mayAdd)
          PopupMenuItem(
            value: 'host',
            height: 38,
            child: BandMenuRow(
              icon: LucideIcons.server,
              label: l10n.hostsNewMenuHost,
              keys: ref.read(shortcutBindingProvider(ShortcutAction.newConnection)),
            ),
          ),
        if (mayAdd)
          PopupMenuItem(
            value: 'group',
            height: 38,
            child: BandMenuRow(icon: LucideIcons.folderPlus, label: l10n.hostsNewMenuGroup),
          ),
        if (widget.onQuickConnect != null)
          PopupMenuItem(
            value: 'quick',
            height: 38,
            child: BandMenuRow(
              icon: LucideIcons.zap,
              label: l10n.hostsNewMenuQuick,
              keys: ref.read(shortcutBindingProvider(ShortcutAction.quickConnect)),
            ),
          ),
        // A host on a serial line (it had a button of its own on the toolbar).
        if (mayAdd)
          PopupMenuItem(
            key: const ValueKey('hosts-new-serial'),
            value: 'serial',
            height: 48,
            child: BandMenuRow(
              icon: LucideIcons.usb,
              label: l10n.hostsToolbarSerial,
              sub: l10n.hostsToolbarSerialTip,
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          key: const ValueKey('hosts-new-import'),
          value: 'import',
          height: 48,
          child: BandMenuRow(
            icon: LucideIcons.download,
            label: l10n.hostsNewMenuImport,
            sub: l10n.hostsNewMenuImportSub,
          ),
        ),
        if (mayAdd)
          PopupMenuItem(
            value: 'shared',
            height: 38,
            child: BandMenuRow(icon: LucideIcons.fileInput, label: l10n.hostsNewMenuShared),
          ),
        // A host someone sent as a share link.
        if (mayAdd)
          PopupMenuItem(
            key: const ValueKey('hosts-new-share-link'),
            value: 'share_link',
            height: 38,
            child: BandMenuRow(icon: LucideIcons.link, label: l10n.shareLinkPasteTitle),
          ),
      ],
    );
    if (!mounted || value == null) return;
    switch (value) {
      case 'host':
        await ConnectionEditScreen.showAdaptive(context);
      case 'group':
        await GroupEditorPanel.showAdaptive(context);
      case 'quick':
        widget.onQuickConnect?.call();
      case 'serial':
        await ConnectionEditScreen.showAdaptive(context, initialProtocol: ConnectionProtocol.serial);
      case 'import':
        await openImportHosts(context);
      case 'shared':
        await importHostShareFile(context);
      case 'share_link':
        final r = await showPasteShareLink(context);
        if (r != null && r.ok && mounted) await addShareLinkHost(context, r.share!, r.uri!);
    }
  }

  /// A group tile's menu: change it (its name, icon and colour), or show only
  /// its hosts.
  Future<void> _openGroupMenu(String groupId, Offset at) async {
    final l10n = AppLocalizations.of(context)!;
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;
    final value = await showMenu<String>(
      context: context,
      color: ZestColors.surfaceRaisedAlt,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: ZestColors.borderStrong),
      ),
      position: RelativeRect.fromLTRB(at.dx, at.dy, overlay.size.width - at.dx, overlay.size.height - at.dy),
      items: [
        PopupMenuItem(
          value: 'show',
          height: 38,
          child: BandMenuRow(icon: LucideIcons.filter, label: l10n.hostsGroupShowOnly),
        ),
        PopupMenuItem(
          value: 'edit',
          height: 38,
          child: BandMenuRow(icon: LucideIcons.pencil, label: l10n.hostsGroupEdit),
        ),
      ],
    );
    if (!mounted || value == null) return;
    switch (value) {
      case 'show':
        setState(() => _selectedGroupId = groupId);
      case 'edit':
        await GroupEditorPanel.showAdaptive(context, groupId: groupId);
    }
  }

  /// Filter: by group, tag, kind of host, open now, needs attention. Stays
  /// open while choices are ticked.
  Future<void> _openFilterMenu(
    BuildContext anchorContext,
    List<ConnectionGroup> groups,
    List<String> knownTags,
    Set<String> knownKinds,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final box = anchorContext.findRenderObject();
    final overlay = Overlay.of(context).context.findRenderObject();
    if (box is! RenderBox || overlay is! RenderBox) return;
    final origin = box.localToGlobal(Offset.zero);
    await showDialog<void>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (dialogContext) => Stack(
        children: [
          Positioned(
            top: origin.dy + box.size.height + 6,
            right: overlay.size.width - origin.dx - box.size.width,
            child: Material(
              color: Colors.transparent,
              child: StatefulBuilder(
                builder: (context, setMenu) {
                  void change(VoidCallback f) {
                    setState(f);
                    setMenu(() {});
                  }

                  final tags = ref.read(activeTagFiltersProvider);
                  return HostsFilterPanel(
                    groups: [for (final g in groups) (id: g.id, name: g.name)],
                    ungroupedId: GroupFilterChips.ungroupedFilterId,
                    group: _selectedGroupId,
                    onGroup: (id) => change(() => _selectedGroupId = id),
                    tags: knownTags,
                    tagsOn: tags,
                    onTag: (tag) => change(() => ref.read(activeTagFiltersProvider.notifier).toggle(tag)),
                    kinds: [for (final k in _kindOrder) if (knownKinds.contains(k)) (id: k, name: _kindName(l10n, k))],
                    kindsOn: _kinds,
                    onKind: (k) => change(() => _kinds.contains(k) ? _kinds.remove(k) : _kinds.add(k)),
                    openOnly: _openOnly,
                    onOpenOnly: (v) => change(() => _openOnly = v),
                    attentionOnly: _attentionOnly,
                    onAttentionOnly: (v) => change(() => _attentionOnly = v),
                    onClear: () => change(() {
                      _selectedGroupId = null;
                      ref.read(activeTagFiltersProvider.notifier).clear();
                      _kinds.clear();
                      _openOnly = false;
                      _attentionOnly = false;
                    }),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The Workspaces section: its head (with Save current layout) and a card
  /// for each saved workspace, or one slim row while there is none.
  List<Widget> _buildWorkspacesSection(
    List<WorkspaceView> workspaces,
    bool hasSession,
    double itemWidth,
    int perRow,
  ) {
    final l10n = AppLocalizations.of(context)!;
    // Only once a workspace has been made (saved from the session bar).
    if (workspaces.isEmpty) return const [];
    final save = SaveLayoutButton(
      hasSession: hasSession,
      onSave: () => WorkspaceSaveDialog.show(context),
    );
    // One row; the rest behind Show all.
    final more = workspaces.length > perRow;
    final shown = more && !_allWorkspaces ? workspaces.take(perRow).toList() : workspaces;
    return [
      SectionLabel(
        l10n.workspacesSectionTitle,
        count: workspaces.length,
        folded: _folded.contains(HostsSection.workspaces),
        onFold: () => _toggleFold(HostsSection.workspaces),
        foldKey: const ValueKey('hosts-fold-workspaces'),
        trailingChild: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (more) ...[
              Flexible(
                child: SectionLink(
                  key: const ValueKey('workspaces-show-all'),
                  label: _allWorkspaces ? l10n.hostsGroupsShowFewer : l10n.hostsGroupsShowAll(workspaces.length),
                  onTap: () => setState(() => _allWorkspaces = !_allWorkspaces),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Flexible(child: save),
          ],
        ),
      ),
      if (!_folded.contains(HostsSection.workspaces))
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final w in shown)
              SizedBox(
                width: itemWidth,
                child: _WorkspaceHostCard(
                  workspace: w,
                  selected: w.id == _selectedWorkspaceId,
                  onSelect: () => _showWorkspace(w.id),
                  onLaunch: () {
                    // ignore: discarded_futures
                    launchWorkspaceFromSurface(context, ref, w.id);
                  },
                  onOverflow: () => _showWorkspace(w.id, editing: true),
                ),
              ),
          ],
        ),
      ),
    ];
  }

  /// A workspace's details in the panel at the right, in place of a host's.
  void _showWorkspace(String id, {bool editing = false}) {
    // A click on the card already shown changes nothing: it would throw away
    // what is being edited there.
    if (!editing && _selectedWorkspaceId == id) return;
    setState(() {
      _selectedHostId = null;
      _selectedWorkspaceId = id;
      _workspaceEditing = editing;
      _workspacePick++;
    });
    // As a host's: Esc closes the panel. (The editor keeps the keyboard, in its
    // name field, and Esc comes up from there.)
    if (!editing) _takeKeyboard();
  }

  /// Stable-partition so pinned hosts sort to the front of a section (B4)
  /// while preserving the active sort within each partition.
  List<({HostCardData data, ConnectionWithDetails connectionWithDetails})>
      _pinnedFirst(
    List<({HostCardData data, ConnectionWithDetails connectionWithDetails})>
        cards,
  ) {
    return [
      ...cards.where((c) => c.data.pinned),
      ...cards.where((c) => !c.data.pinned),
    ];
  }

  Widget _buildHostGrid(
    List<({HostCardData data, ConnectionWithDetails connectionWithDetails})> hostCards,
    double itemWidth, {
    bool compact = false,
    bool showAddTile = false,
    bool reorderable = false,
    bool fills = true,
  }) {
    // The grid lives inside [HostGridArea] which adds shift-drag
    // rubber-band selection on top of the per-card tap / right-click
    // behaviour. The home page just hands it the data + callbacks; all
    // selection state lives in [hostMultiSelectProvider].
    //
    // [showAddTile] appends the dashed "New Connection" tile as the last cell
    // of THIS grid's flow (right after the final host). The caller sets it on
    // the single flat grid, or on the last group section, so it shows once.
    //
    // [reorderable] turns on drag-to-reorder within this grid (manual sort
    // only). The reorder renumbers only THIS list's connections, so callers
    // pass the exact list shown here (a section's pinned-first cards).
    return HostGridArea(
      hostCards: hostCards,
      itemWidth: itemWidth,
      compact: compact,
      onConnect: widget.onConnectTo,
      // A click opens the host's panel; a double click connects.
      selectedHostId: _selectedHostId,
      onSelect: _showHost,
      onSelectionGesture: _pageFocus.requestFocus,
      // (Of two grids, the last fills what is left of the page.)
      minHeight: fills ? _gridFill : 0,
      // In an Orchard, only where a Crate lets this account add.
      onNewConnection: showAddTile && mayAddScreenSpace(ref)
          ? () => ConnectionEditScreen.showAdaptive(context)
          : null,
      onReorder: reorderable
          ? (draggedId, targetId) =>
              _reorderWithin(hostCards, draggedId, targetId)
          : null,
      onShowContextMenu: (position, entry) =>
          _showHostContextMenu(position, entry),
      onEdit: (entry) => _editHost(entry.connectionWithDetails.connection.id),
    );
  }

  /// Edits host [id] in the docked editor, which takes the panel's place;
  /// Cancel or Save brings back the panel, on that host.
  Future<void> _editHost(String id) async {
    if (!await _editorMayGive(id)) return;
    if (!mounted) return;
    setState(() {
      _selectedHostId = id;
      _selectedWorkspaceId = null;
    });
    await ConnectionEditScreen.showAdaptive(context, connectionId: id);
  }

  /// Whether the docked editor, where it is open on another host than
  /// [id], has given way: asked as its own close button asks (about unsaved
  /// changes), and closed. True where none is open.
  Future<bool> _editorMayGive(String id) async {
    final target = ref.read(connectionEditorTargetProvider);
    if (target == null || target.connectionId == id) return true;
    return ConnectionEditScreen.closeDocked();
  }

  /// A host's details in the panel; where the editor is open on another
  /// host, once it has given way ([_editorMayGive]).
  Future<void> _showHost(ConnectionWithDetails item) async {
    final id = item.connection.id;
    if (ref.read(connectionEditorTargetProvider) != null) {
      if (!await _editorMayGive(id)) return;
      if (!mounted) return;
    }
    setState(() {
      _selectedHostId = id;
      _selectedWorkspaceId = null;
    });
    _takeKeyboard();
  }

  /// The page takes the keyboard, so Enter and Esc reach its keys, unless it
  /// is on one of the page's own parts already (4.0, the accessibility pass:
  /// a card opened with Enter kept its place in the Tab order, where the page
  /// took it and the next Tab started from the top). The search field gives
  /// it up: its Enter connects its top match.
  void _takeKeyboard() {
    final now = FocusManager.instance.primaryFocus;
    final onPage = now != null && now != _pageFocus && now.ancestors.contains(_pageFocus);
    if (!onPage || _searchFocusNode.hasFocus) _pageFocus.requestFocus();
  }

  /// Move [draggedId] to where [targetId] sits within [shownCards] (the exact
  /// list the grid rendered) and persist the new manual order. Renumbers just
  /// this list's `sortOrder`, preserving each card's pinned flag and the
  /// size it has saved, so a drop reorders in place with no separate Arrange
  /// mode.
  Future<void> _reorderWithin(
    List<({HostCardData data, ConnectionWithDetails connectionWithDetails})>
        shownCards,
    String draggedId,
    String targetId,
  ) async {
    final ids = shownCards.map((c) => c.data.id).toList();
    final from = ids.indexOf(draggedId);
    final to = ids.indexOf(targetId);
    if (from < 0 || to < 0 || from == to) return;
    final moved = ids.removeAt(from);
    // Drop onto the target takes the target's slot (before it when moving
    // right, in its place when moving left).
    ids.insert(from < to ? to - 1 : to, moved);
    final byId = {for (final c in shownCards) c.data.id: c};
    final rows = [
      for (var idx = 0; idx < ids.length; idx++)
        (
          id: ids[idx],
          sortOrder: idx,
          pinned: byId[ids[idx]]!.data.pinned,
          // Written back as it was saved: no longer drawn, never changed.
          sizeTier: byId[ids[idx]]!.connectionWithDetails.connection.sizeTier,
        ),
    ];
    await ref.read(connectionsDaoProvider).applyLayout(rows);
  }

  /// The host menu open now (a MenuAnchor over the page): its items, and
  /// where it is anchored.
  final _hostMenu = MenuController();
  final _hostMenuAnchor = GlobalKey();
  List<Widget> _hostMenuItems = const [];

  /// Right-click / long-press host menu (grouped
  /// in 4.0): Connect, Open in new tab, Open in split, SFTP
  /// and Edit, then Organize and Tools, then Delete; its keys at the right of
  /// what they do, and submenus (Open in split, Organize, Move to group,
  /// Tools, Health) that stay inside the window (the
  /// MenuAnchor opens a submenu to the left where there is no room to the
  /// right, moves one up where there is none below, and lets a long one
  /// scroll). A host that is one of several selected gets the selection's
  /// menu instead: what it does, it does to all of them, and its head says
  /// how many.
  Future<void> _showHostContextMenu(
    Offset position,
    ({HostCardData data, ConnectionWithDetails connectionWithDetails}) entry,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final connId = entry.data.id;
    // The host's other accounts: each may be connected as, open or not.
    final connectAs = widget.onConnectAs == null
        ? const <({String id, String text})>[]
        : connectAsItems(l10n, ref, await hostAccountChoicesNow(ref, connId),
            defaultUsername: entry.connectionWithDetails.identity?.username);
    if (!mounted) return;
    final select = ref.read(hostMultiSelectProvider);
    final many = select.active && select.selected.length > 1 && select.selected.contains(connId);
    setState(() => _hostMenuItems = many ? _selectionMenu(l10n, select.count) : _hostMenuOf(l10n, entry, connectAs));
    final box = _hostMenuAnchor.currentContext?.findRenderObject();
    if (box is! RenderBox) return;
    // The page takes the keyboard (off the search field too), so Esc reaches
    // the page's key that closes the menu.
    _takeKeyboard();
    _hostMenu.open(position: box.globalToLocal(position));
  }

  /// One item of the host menu: its icon, its words, and its key at the
  /// right where one does it ([shortcut], or [keys] in words).
  Widget _menuItem(
    String value,
    IconData icon,
    String label,
    VoidCallback onPick, {
    MenuSerializableShortcut? shortcut,
    String? keys,
    bool danger = false,
    Key? key,
  }) {
    final color = danger ? ZestColors.statusError : ZestColors.textPrimary;
    return MenuItemButton(
      key: key ?? ValueKey('host-menu-$value'),
      leadingIcon: Icon(icon, size: 15, color: color),
      shortcut: shortcut,
      trailingIcon: keys == null
          ? null
          : Text(keys, style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11, color: ZestColors.textTertiary)),
      style: MenuItemButton.styleFrom(
        foregroundColor: color,
        // The app's own type (a style of its own here would leave the
        // theme's font behind, and the menu in the system's).
        textStyle: _menuText,
        minimumSize: const Size(232, 34),
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      onPressed: onPick,
      child: Text(label),
    );
  }

  /// A submenu of the host menu.
  Widget _submenu(String value, IconData icon, String label, List<Widget> children) => SubmenuButton(
        key: ValueKey('host-menu-$value'),
        leadingIcon: Icon(icon, size: 15, color: ZestColors.textPrimary),
        menuStyle: _menuStyle,
        style: SubmenuButton.styleFrom(
          foregroundColor: ZestColors.textPrimary,
          textStyle: _menuText,
          minimumSize: const Size(232, 34),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        menuChildren: children,
        child: Text(label),
      );

  /// A small-capitals head inside a menu.
  Widget _menuHead(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 10,
            letterSpacing: 1,
            fontWeight: FontWeight.w600,
            color: ZestColors.textTertiary,
          ),
        ),
      );

  /// The words of the host menu: the theme's body type, at 13.
  TextStyle? get _menuText => Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13);

  MenuStyle get _menuStyle => MenuStyle(
        backgroundColor: WidgetStatePropertyAll(ZestColors.surfaceRaisedAlt),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: ZestColors.borderStrong),
        )),
      );

  /// The menu of one host.
  List<Widget> _hostMenuOf(
    AppLocalizations l10n,
    ({HostCardData data, ConnectionWithDetails connectionWithDetails}) entry,
    List<({String id, String text})> connectAs,
  ) {
    final connId = entry.data.id;
    final conn = entry.connectionWithDetails.connection;
    final isActive = entry.data.hasActiveSession;
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    void pick(String value) => _runHostAction(value, entry);
    final groups = ref.read(connectionGroupsProvider).valueOrNull ?? const <ConnectionGroup>[];
    final watched = conn.monitored;
    final ssh = conn.protocol.toLowerCase() == 'ssh';
    // A host that is SFTP only: its files (as Connect opens them). tmux runs
    // over SSH: a saved local shell, or one that is SFTP only, has none.
    final sftpOnly = conn.protocol == 'sftp';
    final name = Redactable.host(entry.data.name).displayIn(ref);
    final offer = transferOffer(ref, TransferKinds.host, [connId]);
    final screens = ref.read(screensOfHostProvider(connId));
    return [
      if (isActive) ...[
        _menuItem('open', LucideIcons.arrowRight, l10n.hostsHomeMenuOpen, () => pick('open'),
            shortcut: const SingleActivator(LogicalKeyboardKey.enter)),
        _menuItem('disconnect', LucideIcons.power, l10n.hostsHomeMenuDisconnect, () => pick('disconnect'), danger: true),
      ] else
        _menuItem('connect', LucideIcons.play, l10n.commonConnect, () => pick('connect'),
            shortcut: const SingleActivator(LogicalKeyboardKey.enter)),
      for (final account in connectAs)
        _menuItem('as:${account.id}', LucideIcons.user, account.text, () => pick('as:${account.id}'),
            key: ValueKey('connect-as-${account.id}')),
      _menuItem('new_tab', LucideIcons.plusSquare, l10n.hmenuOpenNewTab, () => pick('new_tab'),
          shortcut: SingleActivator(LogicalKeyboardKey.enter, control: !mac, meta: mac)),
      _submenu('split', LucideIcons.columns, l10n.hpanelOpenInSplit, [
        _menuItem('split_beside', LucideIcons.layoutGrid, l10n.hmenuSplitBeside, () => pick('split_beside')),
        _menuItem('split_right', LucideIcons.panelRight, l10n.hmenuSplitRight, () => pick('split_right')),
        _menuItem('split_below', LucideIcons.panelBottom, l10n.hmenuSplitBelow, () => pick('split_below')),
      ]),
      if (widget.onOpenSftp != null && (ssh || sftpOnly))
        _menuItem('sftp', LucideIcons.folderOpen, 'SFTP', () => pick('sftp')),
      // Its own screens (4.0): the screen hosts reached through it.
      if (screens.length == 1)
        _menuItem('screen:${screens.single.connection.id}', LucideIcons.monitor, l10n.hostScreenOpen,
            () => pick('screen:${screens.single.connection.id}'),
            key: const ValueKey('host-menu-screen'))
      else if (screens.length > 1)
        _submenu('screen', LucideIcons.monitor, l10n.hostScreenOpen, [
          for (final s in screens)
            _menuItem('screen:${s.connection.id}', LucideIcons.monitor,
                '${hostScreenKind(s)} · ${Redactable.host(hostScreenName(s)).displayIn(ref)}',
                () => pick('screen:${s.connection.id}')),
        ]),
      const Divider(height: 9),
      _menuItem('edit', LucideIcons.pencil, l10n.edit, () => pick('edit'),
          shortcut: const SingleActivator(LogicalKeyboardKey.keyE)),
      const Divider(height: 9),
      // Where the host is kept and how it is found (4.0:
      // the menu was some 22 items in one list).
      _submenu('organize', LucideIcons.folderTree, l10n.hostMenuOrganize, [
        if (mayChangeItem(ref, 'host', connId, watch: false))
          _submenu('move', LucideIcons.folderInput, l10n.hostBulkActionMoveToGroup, [
            for (final g in groups)
              if (g.id != conn.groupId)
                _menuItem('move:${g.id}', LucideIcons.folder, Redactable.group(g.name).displayIn(ref), () => pick('move:${g.id}')),
            if (conn.groupId != null)
              _menuItem('move_none', LucideIcons.folderMinus, l10n.hmenuNoGroup, () => pick('move_none')),
            if (mayAddScreenSpace(ref, watch: false))
              _menuItem('move_new', LucideIcons.folderPlus, l10n.hostBulkActionNewGroup, () => pick('move_new')),
          ]),
        // Move to... and Copy to...: Personal, or a team's vault (3.4).
        if (offer.move) _menuItem('move_to', LucideIcons.folderInput, l10n.transferMoveTo, () => pick('move_to')),
        if (offer.copy) _menuItem('copy_to', LucideIcons.copyPlus, l10n.transferCopyTo, () => pick('copy_to')),
        if (ref.read(pinnedHostsProvider).contains(connId))
          _menuItem('unpin', LucideIcons.pinOff, l10n.hostsHomeMenuUnpin, () => pick('unpin'))
        else
          _menuItem('pin', LucideIcons.pin, l10n.hmenuPinTop, () => pick('pin')),
        // In an Orchard: a copy is a new item, and needs somewhere to go.
        if (mayAddScreenSpace(ref, watch: false))
          _menuItem('duplicate', LucideIcons.copyPlus, l10n.commonDuplicate, () => pick('duplicate')),
        // The host as a file to send to someone, as a phone's Share makes.
        if (mayExportScreenSpace(ref) && ConnectionShareService.canShare(conn.protocol))
          _menuItem('share_file', LucideIcons.fileOutput, l10n.hostShareSaveFile, () => pick('share_file')),
        _menuItem('select', LucideIcons.checkSquare, l10n.hostsHomeMenuSelect, () => pick('select'),
            keys: mac ? 'Cmd+click' : 'Ctrl+click'),
      ]),
      // What else may be done with it.
      _submenu('tools', LucideIcons.wrench, l10n.hostMenuTools, [
        if (ssh) _menuItem('copy_ssh', LucideIcons.copy, l10n.hpanelCopySsh, () => pick('copy_ssh')),
        // tmux control mode on this host: reuses the live session, else
        // connects first and attaches once the shell is up.
        if (widget.onOpenTmux != null && ssh)
          _menuItem('tmux', LucideIcons.layoutGrid, l10n.termTbTmux, () => pick('tmux')),
        // A remote screen (4.0) reached through this host: a new host, so
        // only where one may be added, as Duplicate.
        if (screenCarrierKind(conn.protocol) && mayAddScreenSpace(ref, watch: false))
          _menuItem('add_screen', LucideIcons.monitor, l10n.hostMenuAddScreen, () => pick('add_screen')),
        // An X program on this host, in a screen tab (4.0): opens a
        // session, adds nothing, so wherever the host may be connected to.
        if (screenCarrierKind(conn.protocol) && widget.onOpenXProgram != null)
          _menuItem('x_program', LucideIcons.appWindow, l10n.hostMenuOpenXProgram, () => pick('x_program')),
        // A Proxmox guest's console (4.0): for a host imported as one.
        if (widget.onOpenConsole != null && proxmoxGuestOf(conn) != null)
          _menuItem('console', LucideIcons.monitorPlay, l10n.hostMenuOpenConsole, () => pick('console')),
        if (ssh)
          watched
              ? _submenu('health', LucideIcons.activity, l10n.hostPanelHealth, [
                  _menuHead(l10n.hmenuHealthOn(name)),
                  _menuItem('mute_all', LucideIcons.bellOff, l10n.hmenuMuteAll, () => pick('mute_all')),
                  _menuItem('snooze_day', LucideIcons.clock, l10n.hmenuSnoozeDay, () => pick('snooze_day')),
                  _menuItem('snooze_recover', LucideIcons.rotateCcw, l10n.hmenuSnoozeRecovers, () => pick('snooze_recover')),
                  _menuItem('thresholds', LucideIcons.slidersHorizontal, l10n.hpanelThresholds, () => pick('thresholds')),
                  const Divider(height: 9),
                  _menuItem('unwatch', LucideIcons.eyeOff, l10n.monitorAgentlessStopHost, () => pick('unwatch')),
                ])
              : _menuItem('watch', LucideIcons.activity, l10n.hpanelWatch, () => pick('watch')),
        // Wake-on-LAN, for a host with an address to wake saved.
        if (canWake(conn)) _menuItem('wake', LucideIcons.zap, l10n.connectionCardWakeWol, () => pick('wake')),
        // Remember-last-folder spec, section 4.
        _menuItem('forget_last_folder', LucideIcons.folderX, l10n.sftpForgetLastFolder, () => pick('forget_last_folder')),
      ]),
      if (mayChangeItem(ref, 'host', connId, delete: true, watch: false)) ...[
        const Divider(height: 9),
        _menuItem('delete', LucideIcons.trash2, l10n.delete, () => pick('delete'),
            danger: true, shortcut: const SingleActivator(LogicalKeyboardKey.delete)),
      ],
    ];
  }

  /// The menu of a host that is one of [count] selected: the selection's
  /// actions, said for all of them.
  List<Widget> _selectionMenu(AppLocalizations l10n, int count) {
    final bar = _bulkBar.currentState;
    final groups = ref.read(connectionGroupsProvider).valueOrNull ?? const <ConnectionGroup>[];
    final pinned = ref.read(pinnedHostsProvider);
    final allPinned = ref.read(hostMultiSelectProvider).selected.every(pinned.contains);
    // Delete says how many go: in a team's vault, those the role may delete
    // (none: no Delete, as a single host's menu has none).
    final hostRules = ItemRules.of(ref, TransferKinds.host, watch: false);
    final deletable = ref.read(hostMultiSelectProvider).selected.where((id) => hostRules.mayChange(id, delete: true)).length;
    void run(Future<void> Function()? f) {
      if (f != null) unawaited(f());
    }

    return [
      _menuHead(l10n.hmenuSelectionHead(count)),
      _menuItem('sel_edit', LucideIcons.pencil, l10n.bulkEdit, () => _openBulkEdit(null)),
      _menuItem('sel_open_tabs', LucideIcons.copy, l10n.hostsSelOpenInTabs, () => run(() async => bar?.openSelected(OpenSelectedAs.tabs))),
      _menuItem('sel_open_panes', LucideIcons.layoutGrid, l10n.hostsSelOpenInPanes,
          () => run(() async => bar?.openSelected(OpenSelectedAs.splitPanes))),
      _menuItem('sel_save_ws', LucideIcons.layoutDashboard, l10n.hostsSelSaveWorkspace,
          () => run(() async => bar?.saveSelectedAsWorkspace())),
      const Divider(height: 9),
      _submenu('sel_move', LucideIcons.folderInput, l10n.hostBulkActionMoveToGroup, [
        for (final g in groups)
          _menuItem('sel_move:${g.id}', LucideIcons.folder, Redactable.group(g.name).displayIn(ref),
              () => run(() async => bar?.moveSelectedTo(g.id))),
        _menuItem('sel_move_none', LucideIcons.folderMinus, l10n.hmenuNoGroup, () => run(() async => bar?.moveSelectedTo(null))),
        _menuItem('sel_move_new', LucideIcons.folderPlus, l10n.hostBulkActionNewGroup, () => run(_createGroupAndMoveSelected)),
      ]),
      _menuItem('sel_tag', LucideIcons.tag, l10n.hostBulkActionAddTag, () => run(() async => bar?.tagSelected())),
      _menuItem('sel_pin', allPinned ? LucideIcons.pinOff : LucideIcons.pin,
          allPinned ? l10n.hostsHomeMenuUnpin : l10n.hostsHomeMenuPin, () => run(() async => bar?.togglePinnedSelected())),
      if (deletable > 0) ...[
        const Divider(height: 9),
        _menuItem('sel_delete', LucideIcons.trash2, l10n.hostBulkActionDeleteButton(deletable),
            () => run(() async => bar?.deleteSelected()),
            danger: true, shortcut: const SingleActivator(LogicalKeyboardKey.delete)),
      ],
    ];
  }

  /// What a pick of the host menu does.
  Future<void> _runHostAction(
    String value,
    ({HostCardData data, ConnectionWithDetails connectionWithDetails}) entry,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final connId = entry.data.id;
    if (!mounted) return;
    final conn = entry.connectionWithDetails.connection;
    if (value.startsWith('move:')) {
      await ref.read(connectionCrudProvider).update(id: connId, groupId: value.substring(5));
      return;
    }
    if (value.startsWith('as:')) {
      widget.onConnectAs?.call(entry.connectionWithDetails, value.substring(3));
      return;
    }
    if (value.startsWith('screen:')) {
      final screen = ref.read(screensOfHostProvider(connId)).where((s) => s.connection.id == value.substring(7)).firstOrNull;
      if (screen != null) widget.onConnectTo(screen);
      return;
    }
    switch (value) {
      case 'connect':
      case 'open':
        // Both routes call onConnectTo - _connectTo already reuses an
        // existing session for this connection (allowDuplicate: false)
        // and switches the active WorkTab to focus its tab.
        widget.onConnectTo(entry.connectionWithDetails);
      case 'wake':
        await wakeHost(context, ref, entry.connectionWithDetails.connection);
      case 'tmux':
        widget.onOpenTmux?.call(entry.connectionWithDetails);
      case 'disconnect':
        await _disconnectAllSessionsForHost(entry);
      case 'edit':
        await _editHost(connId);
      case 'forget_last_folder':
        await forgetLastFolder(ref, connId);
        if (mounted) {
          showTopSnackBar(
              context, AppLocalizations.of(context)!.sftpForgetLastFolderDone);
        }
      case 'add_screen':
        await addScreenForHost(context, ref, conn);
      case 'console':
        widget.onOpenConsole?.call(entry.connectionWithDetails);
      case 'x_program':
        final program = await showXProgramDialog(context, host: conn);
        if (program != null && mounted) widget.onOpenXProgram?.call(entry.connectionWithDetails, program);
      case 'duplicate':
        try {
          await ref
              .read(connectionCrudProvider)
              .duplicate(entry.connectionWithDetails.connection,
                  label: l10n.homeCopyLabelSuffix(entry.connectionWithDetails.connection.label));
        } catch (e) {
          if (mounted) {
            showTopSnackBar(context, l10n.hostsHomeDuplicateError,
                isError: true, details: '$e');
          }
        }
      case 'move_to':
        await showMoveCopyDialog(context, ref, kind: TransferKinds.host, keys: [connId], mode: TransferMode.move);
      case 'copy_to':
        await showMoveCopyDialog(context, ref, kind: TransferKinds.host, keys: [connId], mode: TransferMode.copy);
      case 'share_file':
        await shareHostAsFile(context, ref, entry.connectionWithDetails);
      case 'removeFromGroup' || 'move_none':
        await ref.read(connectionCrudProvider).update(
              id: connId,
              clearGroupId: true,
            );
      case 'move_new':
        await _createGroupAndMove({connId});
      case 'new_tab':
        openHostInNewTab(context, ref, conn);
      case 'split_beside':
        await openHostInSplit(context, ref, conn);
      case 'split_right':
        await openHostSplitting(context, ref, conn, Axis.horizontal);
      case 'split_below':
        await openHostSplitting(context, ref, conn, Axis.vertical);
      case 'sftp':
        widget.onOpenSftp?.call(entry.connectionWithDetails);
      case 'copy_ssh':
        await Clipboard.setData(ClipboardData(text: sshCommandFor(entry.connectionWithDetails)));
        if (mounted) showTopSnackBar(context, l10n.hpanelCopiedSsh, isSuccess: true);
      case 'mute_all':
        ref.read(hostAlertPrefsProvider.notifier).muteAll(connId);
      case 'snooze_day':
        ref.read(hostAlertPrefsProvider.notifier).snoozeAllFor(connId, const Duration(hours: 24));
      case 'snooze_recover':
        ref.read(hostAlertPrefsProvider.notifier).snoozeAllUntilRecovers(connId);
      case 'thresholds':
        await showMonitorThresholds(context, hostId: connId);
      case 'unwatch':
        await ref.read(connectionsDaoProvider).setMonitored(connId, false);
      case 'watch':
        // As the monitor's own list adds one: within the free plan's limit.
        if (ref.read(canAddMonitoredHostProvider)) {
          await ref.read(connectionsDaoProvider).setMonitored(connId, true);
        } else {
          showTopSnackBar(context, l10n.monitorAgentlessLimitReached(freeMonitorLimit),
              isWarning: true, actionLabel: l10n.upgrade, onAction: () => PricingModal.show(context));
        }
      case 'pin':
        // Single source of truth: the provider writes the synced
        // Connections.pinned column (B4).
        await ref.read(pinnedHostsProvider.notifier).pin(connId);
      case 'unpin':
        await ref.read(pinnedHostsProvider.notifier).unpin(connId);
      case 'select':
        ref.read(hostMultiSelectProvider.notifier).enter(connId);
      case 'delete':
        await _confirmDeleteSingle(entry);
    }
  }

  /// Fully disconnect every active session associated with [entry]'s
  /// connection. Closes any registered SFTP services first so they
  /// don't linger in the registry, then ends the SSH sessions which
  /// frees the slot count.
  Future<void> _disconnectAllSessionsForHost(
    ({HostCardData data, ConnectionWithDetails connectionWithDetails}) entry,
  ) async {
    final sftpNotifier = ref.read(sftpSessionsProvider.notifier);
    final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
    final connId = entry.data.id;
    final matching = ref
        .read(activeSessionsProvider)
        .entries
        .where((e) => e.value.connectionId == connId)
        .map((e) => e.key)
        .toList();
    for (final sid in matching) {
      final sftp = sftpNotifier.get(sid);
      if (sftp != null) {
        sftpNotifier.unregister(sid);
        // ignore: discarded_futures
        sftp.close();
      }
      // ignore: discarded_futures
      sessionsNotifier.endSession(sid);
    }
  }

  Future<void> _confirmDeleteSingle(
    ({HostCardData data, ConnectionWithDetails connectionWithDetails}) entry,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final conn = entry.connectionWithDetails.connection;
    // Painted form: masked by the host rule (or the address rule when the
    // connection has no label) in recording mode.
    final label = conn.label.isNotEmpty
        ? Redactable.host(conn.label).display
        : Redactable.address(conn.host).display;
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.hostsHomeDeleteConnectionTitle,
      body: l10n.hostsHomeDeleteConnectionBody(label),
      confirmLabel: l10n.delete,
    );
    if (confirmed != true || !mounted) return;
    // The host, then its pin; a team vault's refusal (or any failure) is
    // said, as the selection's Delete says it, and the host stays pinned.
    await deleteOneHost(context, ref, entry.data.id);
  }

  /// Create a new group, then move whichever connections are currently
  /// selected into it. Used by the bulk action bar's "New group…" item.
  Future<void> _createGroupAndMoveSelected() async {
    final state = ref.read(hostMultiSelectProvider);
    if (!state.active || state.selected.isEmpty) return;
    await _createGroupAndMove(Set<String>.from(state.selected));
  }

  /// Asks for a new group's name, makes it, and moves [selectedIds] into it.
  Future<void> _createGroupAndMove(Set<String> selectedIds) async {
    final groupId = await createGroupAndMoveHosts(context, ref, selectedIds);
    if (groupId == null || !mounted) return;
    ref.read(hostMultiSelectProvider.notifier).exit();
    setState(() => _selectedGroupId = groupId);
  }

  /// The hosts a drag of [host] carries ([hostsCarriedWith]), in the order
  /// the page shows them.
  List<ConnectionWithDetails> _carriedWith(ConnectionWithDetails host) => hostsCarriedWith(ref, host, _shownOrder);

  /// A host dropped on a group tile ([groupId] null: the Ungrouped tile):
  /// it moves there, and with it every host selected with it
  /// ([moveHostsToGroup]).
  Future<void> _dropOnGroup(String? groupId, ConnectionWithDetails item) =>
      moveHostsToGroup(context, ref, _carriedWith(item), groupId);

  Widget _buildEmptyState({required int totalHostCount}) {
    final l10n = AppLocalizations.of(context)!;
    final noHostsAtAll = totalHostCount == 0;
    final filtersActive = _searchQuery.isNotEmpty ||
        _selectedGroupId != null ||
        ref.watch(activeTagFiltersProvider).isNotEmpty;
    // An empty page must offer the primary actions directly. When the list is
    // empty only because of filters, offer to clear them instead of the
    // get-connected paths (which wouldn't explain the emptiness). Otherwise
    // surface the SAME four paths as first-run.
    if (noHostsAtAll) {
      return ZestEmptyState(
        icon: LucideIcons.server,
        iconSize: 56,
        title: l10n.hostsEmptyTitle,
        action: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          // Desktop-native: the import and scan flows are modals on the shared
          // dialog shell, and Restore opens the Account panel in place.
          child: GetConnectedOptions(
            onImport: () async {
              final outcome = await showDesktopSshConfigImport(context);
              if (outcome != null && mounted) {
                toastImportOutcome(context,
                    added: outcome.imported, failedLimit: outcome.failedLimit);
              }
            },
            onScan: () async {
              final outcome = await showDesktopLanScan(context);
              if (outcome != null && mounted) {
                toastImportOutcome(context,
                    added: outcome.added, failedLimit: outcome.failedLimit);
              }
            },
            onRestore: () => ProfileScreen.openAccount(context, ref),
            onAdd: () => ConnectionEditScreen.showAdaptive(context),
          ),
        ),
      );
    }
    return ZestEmptyState(
      icon: LucideIcons.searchX,
      title: l10n.hostsFilterEmptyTitleGeneric,
      message: l10n.hostsFilterEmptyMessage,
      actionLabel: filtersActive ? l10n.hostsClearFilters : null,
      actionIcon: LucideIcons.x,
      onAction: filtersActive ? _clearFilters : null,
    );
  }

  /// Reset every active host filter (search text, group selection, tag
  /// filters) back to the unfiltered view.
  void _clearFilters() {
    _searchController.clear();
    ref.read(activeTagFiltersProvider.notifier).clear();
    setState(() {
      _searchQuery = '';
      _selectedGroupId = null;
    });
  }

  void _handleQuickConnect() {
    final q = _searchQuery.trim();
    if (q.isEmpty) return;

    // Read as user@host:port everywhere it is typed (parseQuickTarget). A
    // bare address has no user: startSession then falls back to the default
    // username, as for `192.168.10.21`.
    // (Only what reads as an address comes here: [_isConnectableQuery].)
    final target = parseQuickTarget(q, defaultPort: ref.read(defaultPortProvider));
    if (target == null) return;
    // A host that is not saved (named as typed in the tab strip).
    final conn = quickConnectionOf(target);
    final userPart = target.user;

    // Bypass `widget.onConnectTo` because that callback's signature can't
    // carry `usernameOverride`. We have everything we need (ref, conn) so
    // dispatch the session directly. This mirrors what `_connectTo` does
    // in DesktopShell, minus the Telnet warning (quick connect is always
    // SSH) and split-mode handling (always opens as a new tab).
    final sessionId = ref
        .read(activeSessionsProvider.notifier)
        .startSession(conn, usernameOverride: userPart);
    if (sessionId == null) {
      // Free-tier session limit hit. Surface a snack so users know why
      // nothing happened - silent failure looks like a bug.
      showTopSnackBar(
        context,
        AppLocalizations.of(context)!.hostsHomeFreeTierLimit,
        isError: true,
      );
      return;
    }
    ref.read(workTabsProvider.notifier).onSessionCreated(sessionId);
    ref.read(v3ActiveSessionTabProvider.notifier).state = sessionId;

    // Clear the search field so the next quick-connect starts from a clean
    // slate rather than the just-connected target.
    _searchController.clear();
    setState(() => _searchQuery = '');
  }

  // ── Responsive layout helpers ──

  int _responsiveColumns(double width) {
    final pinned = ref.read(hostCardSettingsProvider).columns.fixedCount;
    if (pinned == null) return _autoColumns(width);
    // Honour the pin, but never let card width fall below ~200px -
    // the OS icon + "user@host" subtitle stops being readable below
    // that.  ContentWidth = width − 48 (page padding), and we need
    // 12px between cards.
    final contentWidth = width - 48;
    const minCardWidth = 180.0;
    final maxFittable =
        ((contentWidth + 12) / (minCardWidth + 12)).floor().clamp(1, 12);
    return pinned > maxFittable ? maxFittable : pinned;
  }

  int _autoColumns(double width) {
    // Touch sized (a tablet, 4.0, portrait and
    // landscape): cards about 330 wide or wider, with room for a finger's
    // more button: two across upright, and beside the host's panel held
    // sideways.
    if (touchSizedAt(context)) return ((width - 48 + 12) / (330 + 12)).floor().clamp(1, 6);
    if (width >= 1200) {
      // Keep adding columns on wide / maximized monitors so cards stay near
      // their ~300px design width instead of ballooning. The default card is
      // now shorter and wider, so a slightly larger target packs fewer, wider
      // columns on big screens.
      // contentWidth ≈ width − 48 page padding; 12px gaps between cards.
      final contentWidth = width - 48;
      const targetCardWidth = 300.0;
      return ((contentWidth + 12) / (targetCardWidth + 12))
          .floor()
          .clamp(4, 12);
    }
    // Lowered breakpoints (was 900 / 600): the leaner card fits THREE across at
    // the common docked-inspector width where the old card only fit two.
    if (width >= 760) return 3;
    if (width >= 540) return 2;
    return 1;
  }

  /// The compact grid's columns: as many cards about 220 wide as fit.
  int _compactColumns(double width) => ((width - 48 + 12) / (220 + 12)).floor().clamp(1, 12);

  /// Compute the width of each grid item given the available [contentWidth]
  /// (after subtracting horizontal padding) and the number of [cols].
  /// Accounts for 12px gaps between columns.
  double _itemWidth(double contentWidth, int cols) {
    if (cols <= 1) return contentWidth;
    final totalGaps = (cols - 1) * 12.0;
    return (contentWidth - totalGaps) / cols;
  }
}

/// A host's kind, as Filter names them: its protocol, with the two ways of
/// writing a local shell as one.
String _kindOf(String protocol) {
  final p = protocol.toLowerCase();
  return p == 'local' || p == 'localshell' ? 'localShell' : p;
}

/// The order kinds are offered in.
const _kindOrder = ['ssh', 'sftp', 'mosh', 'et', 'telnet', 'serial', 'localShell', 'demo'];

/// A kind's name in the person's language.
String _kindName(AppLocalizations l10n, String kind) => switch (kind) {
      'ssh' => 'SSH',
      'sftp' => l10n.connectionEditProtocolSftpShort,
      'mosh' => 'Mosh',
      'et' => 'Eternal Terminal',
      'telnet' => 'Telnet',
      'serial' => l10n.connectionEditProtocolSerialShort,
      'localShell' => l10n.protocolNameLocalShell,
      'demo' => l10n.protocolNameDemo,
      _ => kind,
    };

/// Up to four different icons among [hosts], as their cards draw them.
List<GroupKind> _kindsOf(List<ConnectionWithDetails> hosts, Map<String, OsKind> osCache) {
  final seen = <String>{};
  final out = <GroupKind>[];
  for (final c in hosts) {
    final conn = c.connection;
    final os = osCache[conn.id];
    final osId = os == null ? null : osCatalogIdFor(os);
    final key = conn.customIcon != null ? 'custom:${conn.id}' : (conn.iconId ?? osId ?? 'none');
    if (!seen.add(key)) continue;
    out.add(GroupKind(iconId: conn.iconId, customIcon: conn.customIcon, osId: osId, iconColor: conn.iconColor));
    if (out.length == 4) break;
  }
  return out;
}

/// A quiet word at the end of a section's rule.
class _SectionHint extends StatelessWidget {
  const _SectionHint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: ZestColors.textTertiary, fontSize: 12));
}


/// The band's Sort: the active mode's label and a chevron; a click opens a
/// menu with every [HostSortMode] and, under them, Active first (4.0:
/// it was a switch of its own beside Select, though
/// it is a way of sorting; the same preference underneath).
class _SortButton extends ConsumerStatefulWidget {
  const _SortButton({required this.mode, required this.onSelect});

  final HostSortMode mode;
  final ValueChanged<HostSortMode> onSelect;

  @override
  ConsumerState<_SortButton> createState() => _SortButtonState();
}

/// The menu's Active first, apart from the sorts.
const _kActiveFirstChoice = 'active-first';

class _SortButtonState extends ConsumerState<_SortButton> {

  Future<void> _show() async {
    final l10n = AppLocalizations.of(context)!;
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;
    final box = context.findRenderObject();
    if (box is! RenderBox) return;
    final origin = box.localToGlobal(Offset.zero);
    final size = box.size;
    final activeFirst = ref.read(activeFirstProvider(HostListPlace.hostsPage));
    final picked = await showMenu<Object>(
      context: context,
      color: ZestColors.bgElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      position: RelativeRect.fromLTRB(
        origin.dx,
        origin.dy + size.height + 4,
        overlay.size.width - origin.dx - size.width,
        0,
      ),
      items: [
        for (final m in HostSortMode.values)
          PopupMenuItem<Object>(
            value: m,
            child: Row(
              children: [
                Icon(
                  m == widget.mode
                      ? LucideIcons.check
                      : LucideIcons.arrowDownUp,
                  size: 14,
                  color: m == widget.mode
                      ? ZestColors.accentInk
                      : ZestColors.textTertiary,
                ),
                const SizedBox(width: 10),
                Text(
                  m.nameIn(l10n),
                  style: TextStyle(
                    color: ZestColors.textPrimary,
                    fontSize: 13,
                    fontWeight: m == widget.mode
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        const PopupMenuDivider(height: 9),
        // On or off, said by its switch and to a screen reader.
        PopupMenuItem<Object>(
          key: const ValueKey('hosts-sort-active-first'),
          value: _kActiveFirstChoice,
          child: Semantics(
            toggled: activeFirst,
            child: Row(
              children: [
                Icon(LucideIcons.circleDot, size: 14, color: activeFirst ? ZestColors.statusSuccess : ZestColors.textTertiary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.hostsActiveFirst,
                    style: TextStyle(color: ZestColors.textPrimary, fontSize: 13),
                  ),
                ),
                const SizedBox(width: 12),
                // A picture of the switch: the item itself is pressed.
                ExcludeFocus(
                  child: ExcludeSemantics(
                    child: IgnorePointer(child: ZestSwitch(value: activeFirst, onChanged: (_) {})),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
    if (!mounted) return;
    if (picked is HostSortMode) widget.onSelect(picked);
    if (picked == _kActiveFirstChoice) setActiveFirst(ref, HostListPlace.hostsPage, !activeFirst);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The band's quiet button (3.0): the sort in words, its menu below.
    return BandButton(
      key: const ValueKey('hosts-sort'),
      label: l10n.hostsHomeSortPrefix(widget.mode.nameIn(l10n)),
      icon: LucideIcons.arrowUpDown,
      trailingIcon: LucideIcons.chevronDown,
      ghost: true,
      onPressed: _show,
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Workspaces section (§7b) - launch cards + empty CTA
// ══════════════════════════════════════════════════════════════════

/// A workspace launch card on the Hosts page (§7b). Segmented identity bar +
/// pane-layout thumbnail + name + a mono metadata line (including `last
/// opened`) + member colour chips. Hover reveals an open and an edit (pencil)
/// glyph. A click opens its panel at the right (it connected everything at
/// once before); a double-click or the open
/// glyph opens the workspace; right-clicking or the pencil opens the panel on
/// its editor.
/// A workspace card. Neutral by default: the icon, the background and what
/// used to be a colour-label stripe all stay neutral, so red appears in exactly
/// one place, the host dot, where it means the host was UNREACHABLE at the
/// last health probe, and a one-line caption spells that out. The single
/// workspace that is open right now gets the brand treatment instead: a top
/// rind, a brand icon and an "open now" tag. Host colour labels are no longer
/// painted on the card (a dot means connection status and nothing else).
class _WorkspaceHostCard extends ConsumerStatefulWidget {
  final WorkspaceView workspace;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onLaunch;
  final VoidCallback onOverflow;

  const _WorkspaceHostCard({
    required this.workspace,
    required this.selected,
    required this.onSelect,
    required this.onLaunch,
    required this.onOverflow,
  });

  @override
  ConsumerState<_WorkspaceHostCard> createState() => _WorkspaceHostCardState();
}

class _WorkspaceHostCardState extends ConsumerState<_WorkspaceHostCard> {
  bool _hover = false;

  /// The keyboard is on the card: its tools show, as under a pointer.
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final w = widget.workspace;
    final healthMap = ref.watch(connectionHealthProvider);
    final isOpen = ref.watch(openWorkspaceIdProvider) == w.id;
    final statuses = [for (final m in w.memberHosts) healthMap[m.id]?.status];
    final unreachable =
        statuses.where((s) => s == ConnectionHealth.offline).length;
    final accent = ZestColors.accentPrimary;
    // Short enough never to be cut: its panes and when it was last opened.
    final meta = '${l10n.workspacePaneCountLabel(w.paneCount)} · '
        '${w.lastOpened == null ? l10n.workspaceNeverOpened : timeAgoShort(l10n, w.lastOpened!)}';
    // Up to three of its hosts by name, then how many more.
    const shownMembers = 3;
    final members = w.memberHosts;

    // The Blueprint's workspace card: an icon tile (the brand's where it is
    // open now), its name, a mono line of tabs, panes and when it was last
    // opened, and its hosts as small mono chips.
    // Reached with Tab (Enter opens its panel), said as a button and whether
    // it is the one in the panel, Open and Edit for a screen reader, its
    // menu under Shift+F10 and the menu key, its tools shown under the
    // keyboard as under the pointer (4.0, the accessibility pass: they were
    // only under a hovering pointer).
    return ZestPressable(
        key: ValueKey('workspace-card-${w.id}'),
        // At the press, as a host's card opens its panel: the double-click
        // that opens the workspace makes a single click wait otherwise.
        onTapDown: widget.onSelect,
        onDoubleTap: widget.onLaunch,
        onSecondaryTapUp: (_) => widget.onOverflow(),
        onHover: (h) => setState(() => _hover = h),
        onFocusChange: (f) => setState(() => _focus = f),
        // The right click's menu (and what the hover's tools do) under a long
        // press too where the controls are touch sized (a tablet, 4.0).
        onLongPress: touchSizedAt(context) ? widget.onOverflow : null,
        onContextMenu: widget.onOverflow,
        semanticActions: {
          CustomSemanticsAction(label: l10n.workspacePanelOpen): widget.onLaunch,
          CustomSemanticsAction(label: l10n.edit): widget.onOverflow,
        },
        selected: widget.selected,
        minSize: 0,
        borderRadius: 12,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _hover ? ZestColors.surfaceRaisedAlt : ZestColors.chromeElevated,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: widget.selected
                  ? ZestColors.accentPrimary
                  : isOpen
                      ? Color.lerp(ZestColors.borderDefault, accent, 0.3)!
                      : (_hover ? ZestColors.borderStrong : ZestColors.borderDefault),
            ),
          ),
          child: Stack(
            children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: isOpen ? accent.withValues(alpha: 0.10) : ZestColors.bgSurface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(LucideIcons.layoutGrid, size: 16, color: isOpen ? ZestColors.accentInk : ZestColors.textTertiary),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: RedactedText(
                            Redactable.workspace(w.name),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: ZestColors.textPrimary, fontSize: 13.5, fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (isOpen) ...[
                          const SizedBox(width: 6),
                          _OpenNowTag(label: l10n.workspaceOpenNow),
                        ],
                        // Room for the hover tools at the corner.
                        if (_hover) const SizedBox(width: 64),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: ZestColors.textTertiary, fontSize: 11, fontFamily: 'JetBrainsMono'),
                    ),
                    if (members.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      // One line of chips: what does not fit is cut, not wrapped.
                      SizedBox(
                        height: 20,
                        child: ClipRect(
                          child: Wrap(
                            spacing: 4,
                            runSpacing: 20,
                            children: [
                              for (var i = 0; i < members.length && i < shownMembers; i++)
                                _MemberChip(
                                  label: workspaceMemberLabel(l10n, members[i]),
                                  unreachable: statuses[i] == ConnectionHealth.offline,
                                ),
                              if (members.length > shownMembers)
                                _MemberChip(
                                  label: Redactable.freeText('+${members.length - shownMembers}'),
                                  unreachable: false,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    // Red gets a label: say what the red names mean.
                    if (unreachable > 0) ...[
                      const SizedBox(height: 5),
                      Text(
                        l10n.workspaceUnreachableCaption(unreachable),
                        style: TextStyle(color: ZestColors.statusError, fontSize: 10.5),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
              if (_hover || _focus)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _CardGlyph(
                        key: ValueKey('workspace-card-open-${w.id}'),
                        icon: LucideIcons.play,
                        tooltip: l10n.workspacePanelOpen,
                        onTap: widget.onLaunch,
                      ),
                      const SizedBox(width: 4),
                      _CardGlyph(
                        key: ValueKey('workspace-card-edit-${w.id}'),
                        icon: LucideIcons.pencil,
                        tooltip: l10n.edit,
                        onTap: widget.onOverflow,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
    );
  }
}

/// One of a workspace's hosts on its card: its name in a small mono chip, in
/// red where it could not be reached at the last check.
class _MemberChip extends ConsumerWidget {
  const _MemberChip({required this.label, required this.unreachable});
  final Redactable label;
  final bool unreachable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = unreachable ? ZestColors.statusError : ZestColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: unreachable ? c.withValues(alpha: 0.13) : ZestColors.surfaceChip,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label.displayIn(ref),
        maxLines: 1,
        style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 10.5, color: c, height: 1.1),
      ),
    );
  }
}

/// The small "open now" pill on the one workspace card that is live: the same
/// brand wash / brand line accent language the rest of the app already uses,
/// not a new stripe style.
class _OpenNowTag extends StatelessWidget {
  final String label;
  const _OpenNowTag({required this.label});

  @override
  Widget build(BuildContext context) {
    final accent = ZestColors.accentPrimary;
    return Container(
      padding: const EdgeInsets.fromLTRB(7, 2, 7, 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withValues(alpha: 0.30), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: ZestColors.accentInk,
              fontSize: 9.5,
              fontFamily: 'JetBrainsMono',
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small hover-revealed overflow glyph on a workspace card.
class _CardGlyph extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _CardGlyph({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Named, reached with Tab, a mouse's 32 square around its icon (it was
    // 19).
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: ZestPressable(
        onTap: onTap,
        semanticLabel: tooltip,
        excludeChildSemantics: true,
        borderRadius: 6,
        child: Icon(icon, size: 15, color: ZestColors.textSecondary),
      ),
    );
  }
}

/// The compact "Save current layout" action in the Workspaces section header.
/// Disabled (dim, no border) when there's no live session to capture.
class SaveLayoutButton extends StatelessWidget {
  final bool hasSession;
  final VoidCallback onSave;
  const SaveLayoutButton({super.key, required this.hasSession, required this.onSave});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final enabled = hasSession;
    return Tooltip(
      message: enabled
          ? l10n.workspaceSaveCurrentLayout
          : l10n.workspaceSaveNoSessionReason,
      // Reached with Tab, said as a button (turned off without a session),
      // a mouse's 32 high around it.
      child: ZestPressable(
          onTap: enabled ? onSave : null,
          semanticLabel: l10n.workspaceSaveCurrentLayout,
          borderRadius: 7,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: ZestColors.bgSurface.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color: enabled
                    ? ZestColors.borderSubtle
                    : ZestColors.borderSubtle.withValues(alpha: 0.5),
                width: 0.6,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.save,
                  size: 12,
                  color: enabled
                      ? ZestColors.textSecondary
                      : ZestColors.textDisabled,
                ),
                // The words whole or not at all: cut, they read "Save cur…"
                // before. The tooltip says them.
                Flexible(
                  child: LayoutBuilder(builder: (context, box) {
                    final style = TextStyle(
                      color: enabled
                          ? ZestColors.textPrimary
                          : ZestColors.textDisabled,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    );
                    final words = TextPainter(
                      text: TextSpan(
                        text: l10n.workspaceSaveCurrentLayout,
                        style: DefaultTextStyle.of(context).style.merge(style),
                      ),
                      textDirection: Directionality.of(context),
                      textScaler: MediaQuery.textScalerOf(context),
                      maxLines: 1,
                    )..layout();
                    final fits = words.width + 6 <= box.maxWidth;
                    words.dispose();
                    if (!fits) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsetsDirectional.only(start: 6),
                      child: Text(
                        l10n.workspaceSaveCurrentLayout,
                        maxLines: 1,
                        softWrap: false,
                        style: style,
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
      ),
    );
  }
}


/// At the end of the hosts' head while they are selected:
/// a box that selects every host shown, or none
/// (a dash where some are), how many of them are selected, and Clear
/// selection. As tall as the head's line, so nothing under it moves.
class _SelectionHead extends ConsumerWidget {
  const _SelectionHead({required this.shown});

  /// The hosts shown, in their order.
  final List<String> shown;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final notifier = ref.read(hostMultiSelectProvider.notifier);
    return SelectionHead(
      keyPrefix: 'host-selection',
      shown: shown,
      selected: ref.watch(hostMultiSelectProvider).selected,
      tooltip: l10n.bulkSelectShownTip,
      onSelectShown: () => notifier.addAll(shown),
      onUnselectShown: () => notifier.removeAll(shown),
      onClear: notifier.clearSelection,
    );
  }
}

/// Select (Selecting while hosts are selected on the page): starts and ends
/// selecting, on the hosts' own line.
class _SelectToggle extends ConsumerWidget {
  const _SelectToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final selecting =
        ref.watch(hostMultiSelectProvider).active && ref.watch(hostSelectionPlaceProvider) == HostSelectionPlace.page;
    return SelectToggleButton(
      buttonKey: const ValueKey('hosts-select'),
      selecting: selecting,
      tooltip: l10n.bulkSelectButtonTip,
      onTap: () {
        final select = ref.read(hostMultiSelectProvider.notifier);
        ref.read(hostSelectionPlaceProvider.notifier).state = HostSelectionPlace.page;
        selecting ? select.exit() : select.enter();
      },
    );
  }
}
