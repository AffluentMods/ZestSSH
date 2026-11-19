import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/core/widgets/os_icon.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart' show ConnectionGroup;
import 'package:zestssh/features/groups/widgets/phone_group_sheets.dart';
import 'package:zestssh/features/hosts/connect_as.dart';
import 'package:zestssh/features/hosts/pending_files.dart';
import 'package:zestssh/features/hosts/phone/phone_host_page.dart';
import 'package:zestssh/features/hosts/phone/phone_host_selection.dart';
import 'package:zestssh/features/hosts/state/host_multi_select.dart';
import 'package:zestssh/features/hosts/state/kex_refused_hosts.dart';
import 'package:zestssh/features/hosts/host_attention.dart' show HostHealthChip, healthChipsFor, monitoredHostViewsProvider;
import 'package:zestssh/features/hosts/host_health_summary.dart' show hostHealthSummariesProvider;
import 'package:zestssh/features/hosts/widgets/host_card.dart'
    show
        HostHealthChipView,
        HostKeyChangedChip,
        HostOldKexChip,
        HostOpenSignal,
        HostSelectBox,
        defaultIconIdFor,
        screenCarrierKind,
        worstHealthChip;
import 'package:zestssh/providers/changed_host_keys_provider.dart' show changedHostKeysProvider, normalizeKnownHost;
import 'package:zestssh/ui/widgets/selection_bar.dart' show SelectionHiddenRow;
import 'package:zestssh/features/hosts/state/host_sort_mode.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/widgets/crate_filter_chips.dart' show crateOfHost;
import 'package:zestssh/features/orchards/spaces.dart' show kOrchardsEnabled;
import 'package:zestssh/features/orchards/sync/item_store.dart' show teamMayNotOpenWith;
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart' show crateDisplayName;
import 'package:zestssh/features/orchards/widgets/crate_session_logs_view.dart' show HostSessionsLoggedNote;
import 'package:zestssh/features/orchards/widgets/crate_offline_limit_view.dart' show HostCrateClosedNote;
import 'package:zestssh/features/orchards/widgets/crate_watched_view.dart' show HostSessionsWatchedNote;
import 'package:zestssh/features/tmux/tmux_session_counts.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/providers/pinned_hosts_provider.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/purchase/pricing_modal.dart';
import 'package:zestssh/ui/widgets/haptics.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/utils/host_address.dart';
import 'package:zestssh/features/hosts/host_card_face.dart';
import 'package:zestssh/features/hosts/host_screens.dart';
import 'package:zestssh/providers/os_detection_providers.dart';
import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:zestssh/models/enums.dart' show ConnectionProtocol;
import 'package:zestssh/features/screens/proxmox/proxmox_console_open.dart';
import 'package:zestssh/features/screens/proxmox/proxmox_guest_of.dart';
import 'package:zestssh/features/screens/xprogram/x_program_dialog.dart' show openXProgramOnPhone;
import 'package:zestssh/features/orchards/guardrails.dart' show mayChangeItem;
import 'package:zestssh/features/orchards/team_write.dart';
import 'package:zestssh/l10n/l10n_global.dart';

/// What a host row on a phone can do, beyond connecting: the sheet its more
/// button opens offers each one that is given.
class PhoneHostActions {
  const PhoneHostActions({
    required this.connect,
    required this.edit,
    this.connectAs,
    this.wake,
    this.delete,
    this.duplicate,
    this.share,
    this.moveTo,
    this.copyTo,
    this.openScreen,
  });

  final VoidCallback connect;
  final VoidCallback edit;
  final ValueChanged<String>? connectAs;
  final VoidCallback? wake;
  final VoidCallback? delete;
  final VoidCallback? duplicate;
  final VoidCallback? share;

  /// Move to... and Copy to...: Personal, or a team's vault (3.4).
  final VoidCallback? moveTo;
  final VoidCallback? copyTo;

  /// Opens one of the host's own screens (4.0, the screen hosts reached
  /// through it): a monitor on its row and Screen in its sheet while it has one.
  final ValueChanged<ConnectionWithDetails>? openScreen;
}

/// A group made from Home's + (New group): the list picks it, so its section
/// shows, empty, with Add hosts (the New group chip did that, which the +
/// took over in 4.0).
final phoneGroupPickWanted = ValueNotifier<String?>(null);

/// The phone's Hosts (4.0):
/// one row of filter chips that scrolls sideways (all, pinned,
/// each group, with their counts), then the pinned hosts and each group as a
/// section that folds, the first section's head carrying the sort (Active
/// first and Arrange are in its sheet). Each host a row with its OS tile,
/// its name with "Open" or one health chip, `user@host:port` and one more
/// button for everything else. A tap connects; a long press selects.
class PhoneHostsList extends ConsumerStatefulWidget {
  const PhoneHostsList({
    super.key,
    required this.hosts,
    required this.actionsOf,
    this.bottomPadding = 96,
  });

  /// The hosts to show (already filtered by the search and the vault).
  final List<ConnectionWithDetails> hosts;
  final PhoneHostActions Function(ConnectionWithDetails host) actionsOf;
  final double bottomPadding;

  @override
  ConsumerState<PhoneHostsList> createState() => _PhoneHostsListState();
}

/// What the chips filter by: everything, the pinned hosts, or one group
/// (its id; [_ungrouped] for the hosts in none).
const _all = '';
const _pinned = '__pinned__';
const _ungrouped = '__ungrouped__';

class _PhoneHostsListState extends ConsumerState<PhoneHostsList> {
  String _filter = _all;
  final _folded = <String>{};

  @override
  void initState() {
    super.initState();
    phoneGroupPickWanted.addListener(_takeGroupPick);
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeGroupPick());
  }

  @override
  void dispose() {
    phoneGroupPickWanted.removeListener(_takeGroupPick);
    super.dispose();
  }

  void _takeGroupPick() {
    final id = phoneGroupPickWanted.value;
    if (id == null || !mounted) return;
    phoneGroupPickWanted.value = null;
    setState(() => _filter = id);
  }

  /// Arrange (3.1, as a computer's): each group's hosts are dragged into
  /// their order by a handle, written to their `sortOrder` as a computer's
  /// Manual sort writes it; Done leaves.
  bool _arranging = false;

  /// While arranging: each section's order as last dragged, shown until
  /// the saved order comes back from the database.
  final _arranged = <String, List<String>>{};

  /// [sections] with the hosts with an open session first, the last used
  /// first, where Active first is on and any is open; and otherwise as they
  /// are. (A host pinned stays among the pinned as well, as it does in its
  /// group.)
  List<_Section> _activeFirst(List<_Section> sections, AppLocalizations l10n, {required Set<String?> open}) {
    if (!ref.watch(activeFirstProvider(HostListPlace.phoneHosts))) return sections;
    final used = ref.watch(hostUseProvider);
    final active = {
      for (final s in sections)
        for (final h in s.hosts)
          if (open.contains(h.connection.id)) h.connection.id: h,
    }.values.toList();
    if (active.isEmpty) return sections;
    DateTime at(ConnectionWithDetails h) =>
        used[h.connection.id] ?? h.connection.lastConnected ?? DateTime.fromMillisecondsSinceEpoch(0);
    active.sort((a, b) => at(b).compareTo(at(a)));
    return [
      _Section(
        id: '__active__',
        label: l10n.hostsSectionActive,
        hosts: active,
        color: ZestTokens.statusHealthy,
        icon: LucideIcons.circleDot,
      ),
      for (final s in sections)
        if (s.id == _pinned)
          s
        else if (s.hosts.isEmpty || s.hosts.any((h) => !open.contains(h.connection.id)))
          _Section(
            id: s.id,
            label: s.label,
            hosts: [for (final h in s.hosts) if (!open.contains(h.connection.id)) h],
            color: s.color,
            icon: s.icon,
            group: s.group,
          ),
    ];
  }

  /// [hosts] in the order last dragged in section [id], where it was.
  List<ConnectionWithDetails> _inArrangedOrder(String id, List<ConnectionWithDetails> hosts) {
    final order = _arranged[id];
    if (order == null) return hosts;
    int place(ConnectionWithDetails h) {
      final i = order.indexOf(h.connection.id);
      return i < 0 ? order.length : i;
    }

    // A stable sort: a host not dragged keeps its place after the others.
    final indexed = [for (var i = 0; i < hosts.length; i++) (i, hosts[i])]
      ..sort((a, b) {
        final byPlace = place(a.$2).compareTo(place(b.$2));
        return byPlace != 0 ? byPlace : a.$1.compareTo(b.$1);
      });
    return [for (final e in indexed) e.$2];
  }

  /// A host of section [s] dragged from [oldIndex] to [newIndex]: the
  /// group's order is saved (every host of the group, those the search
  /// hides keeping their places), and the Manual sort is picked, as a
  /// computer does once its hosts are arranged.
  Future<void> _reorder(_Section s, int oldIndex, int newIndex) async {
    final shown = [for (final h in s.hosts) h.connection.id];
    if (oldIndex == newIndex || oldIndex < 0 || oldIndex >= shown.length) return;
    shown.insert(newIndex, shown.removeAt(oldIndex));
    haptic(ref, Haptic.selection);
    setState(() => _arranged[s.id] = shown);
    ref.read(hostSortModeProvider.notifier).state = HostSortMode.manual;
    ref.read(hostSortReversedProvider.notifier).state = false;

    final groupId = s.group?.id;
    final every = ref.read(connectionsWithDetailsProvider).valueOrNull ?? widget.hosts;
    final full = [for (final c in every) if (c.group?.id == groupId) c];
    final fullIds = {for (final c in full) c.connection.id};
    final shownInFull = [for (final id in shown) if (fullIds.contains(id)) id];
    final shownSet = shownInFull.toSet();
    var k = 0;
    final order = [
      for (final c in full) shownSet.contains(c.connection.id) ? shownInFull[k++] : c.connection.id,
      for (final id in shown) if (!fullIds.contains(id)) id,
    ];
    final byId = {for (final c in [...full, ...s.hosts]) c.connection.id: c.connection};
    await ref.read(connectionsDaoProvider).applyLayout([
      for (var i = 0; i < order.length; i++)
        (
          id: order[i],
          sortOrder: i,
          // Written back as they were saved.
          pinned: byId[order[i]]!.pinned,
          sizeTier: byId[order[i]]!.sizeTier,
        ),
    ]);
  }

  void _setArranging(bool on) {
    haptic(ref, Haptic.selection);
    // The hosts are arranged in their own order, which the Manual sort
    // shows (as a computer's Arrange picks it).
    if (on) {
      ref.read(hostSortModeProvider.notifier).state = HostSortMode.manual;
      ref.read(hostSortReversedProvider.notifier).state = false;
    }
    setState(() {
      _arranging = on;
      _arranged.clear();
    });
  }

  /// The sort's sheet, from the first section's head (4.0): how the hosts are
  /// ordered (the same sorts as a computer's, the one in use ticked), Active
  /// first (it was a row of its own over the list) and Arrange (it was an
  /// icon at the chips' end), where the hosts may be arranged.
  Future<void> _sortSheet({required bool canArrange}) async {
    haptic(ref, Haptic.selection);
    final picked = await showZestSheet<String>(
      context: context,
      child: ZestSheetFrame(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Builder(
            builder: (sheet) => Consumer(
              builder: (context, ref, _) {
                final l10n = AppLocalizations.of(context)!;
                final mode = ref.watch(hostSortModeProvider);
                final activeFirst = ref.watch(activeFirstProvider(HostListPlace.phoneHosts));
                return Column(
                  key: const ValueKey('phone-sort-sheet'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
                      child: Text(l10n.sftpSortHosts,
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: ZestTokens.textPrimary)),
                    ),
                    for (final m in HostSortMode.values)
                      Semantics(
                        selected: m == mode,
                        inMutuallyExclusiveGroup: true,
                        child: _SheetRow(
                          key: ValueKey('phone-sort-${m.name}'),
                          icon: m == mode ? LucideIcons.check : LucideIcons.arrowDownUp,
                          iconColor: m == mode ? ZestTokens.brandInk : null,
                          label: m.nameIn(l10n),
                          onTap: () => Navigator.of(sheet).pop('sort:${m.name}'),
                        ),
                      ),
                    Divider(height: 9, thickness: 0.6, color: ZestTokens.borderSubtle),
                    _SheetSwitchRow(
                      key: const ValueKey('phone-sort-active-first'),
                      icon: LucideIcons.circleDot,
                      label: l10n.hostsActiveFirst,
                      subtitle: l10n.hostsActiveFirstTip,
                      value: activeFirst,
                      onChanged: (on) => setActiveFirst(ref, HostListPlace.phoneHosts, on),
                    ),
                    if (canArrange)
                      _SheetRow(
                        key: const ValueKey('phone-sort-arrange'),
                        icon: LucideIcons.gripVertical,
                        label: l10n.hostsHomeArrange,
                        trailingIcon: LucideIcons.chevronRight,
                        onTap: () => Navigator.of(sheet).pop('arrange'),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    if (!mounted || picked == null) return;
    if (picked == 'arrange') {
      _setArranging(true);
    } else if (picked.startsWith('sort:')) {
      final name = picked.substring(5);
      ref.read(hostSortModeProvider.notifier).state = HostSortMode.values.firstWhere((m) => m.name == name);
      ref.read(hostSortReversedProvider.notifier).state = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hosts = widget.hosts;
    final pinnedIds = ref.watch(pinnedHostsProvider);
    final health = ref.watch(connectionHealthProvider);
    final sessions = ref.watch(activeSessionsProvider);
    final open = {
      for (final s in sessions.values)
        if (s.status == SessionStatus.connected || s.status == SessionStatus.connecting) s.connectionId,
    };

    // Whether groups may be made, changed and deleted here (3.0.1: on a
    // phone too; in a team's space, by who may add to the vault).
    final canEditGroups = mayEditGroups(ref);

    // The groups that hold a host here, in their own order.
    final groups = <String, ConnectionGroup>{};
    for (final h in hosts) {
      final g = h.group;
      if (g != null) groups[g.id] = g;
    }
    // A group with no host at all (just made, or emptied) keeps its chip, to
    // be picked, changed or filled.
    final everyHost = ref.watch(connectionsWithDetailsProvider).valueOrNull;
    if (everyHost != null) {
      final held = {for (final c in everyHost) ?c.connection.groupId};
      for (final g in ref.watch(connectionGroupsProvider).valueOrNull ?? const <ConnectionGroup>[]) {
        if (!held.contains(g.id)) groups[g.id] = g;
      }
    }
    final orderedGroups = groups.values.toList()
      ..sort((a, b) {
        final byOrder = a.sortOrder.compareTo(b.sortOrder);
        return byOrder != 0 ? byOrder : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    // Each section in the sort picked (4.0: the sorts of a computer's; the
    // hosts were in their saved order, which Manual shows).
    final sortMode = ref.watch(hostSortModeProvider);
    final summaries = sortMode == HostSortMode.health ? ref.watch(hostHealthSummariesProvider) : null;
    List<ConnectionWithDetails> sorted(List<ConnectionWithDetails> those) =>
        sortConnections(conns: those, mode: sortMode, sessions: sessions, health: summaries ?? const {});
    final pinned = sorted([for (final h in hosts) if (pinnedIds.contains(h.connection.id)) h]);
    final ungrouped = sorted([for (final h in hosts) if (h.group == null) h]);
    // What each row says beside its name, as a computer's page gives its
    // cards (4.0): how many of its sessions are open, Server Monitor's
    // warnings, and a changed host key.
    final monitorViews = ref.watch(monitoredHostViewsProvider);
    final changedKeys = ref.watch(changedHostKeysProvider);
    int openOf(String id) => sessions.values
        .where((s) =>
            s.connectionId == id && (s.status == SessionStatus.connected || s.status == SessionStatus.connecting))
        .length;
    List<HostHealthChip> chipsOf(String id) => healthChipsFor(monitorViews[id], l10n);
    bool keyChangedOf(ConnectionWithDetails h) =>
        changedKeys.contains('${normalizeKnownHost(h.connection.host)}:${h.connection.port}');
    // A filter whose group is gone shows everything (kept, not cleared: a
    // group just made is picked before the list has it).
    final filter =
        _filter == _all || _filter == _pinned || _filter == _ungrouped || groups.containsKey(_filter) ? _filter : _all;
    int inGroup(String id) => hosts.where((h) => h.group?.id == id).length;

    // The sections: pinned first, then each group, then the hosts in none.
    // A group with no host here shows only when its chip is picked.
    final sectionsShown = <_Section>[
      if (pinned.isNotEmpty && (filter == _all || filter == _pinned))
        _Section(id: _pinned, label: l10n.phoneHostsPinned, hosts: pinned, icon: LucideIcons.star, color: ZestTokens.brand),
      for (final g in orderedGroups)
        if (filter == g.id || (filter == _all && hosts.any((h) => h.group?.id == g.id)))
          _Section(
            id: g.id,
            label: g.name,
            hosts: sorted([for (final h in hosts) if (h.group?.id == g.id) h]),
            color: resolveGroupColor(colorValue: g.colorValue, colorIndex: g.colorIndex, name: g.name),
            group: g,
          ),
      if (ungrouped.isNotEmpty && (filter == _all || filter == _ungrouped))
        _Section(
          id: _ungrouped,
          // With no group at all, they are simply the hosts.
          label: groups.isEmpty ? l10n.hostsSectionHosts : l10n.zestGroupUngrouped,
          hosts: ungrouped,
          color: ZestTokens.textTertiary,
        ),
    ];
    // While arranging: each group and the hosts in none, in the order last
    // dragged; not the pinned hosts (each is in its group as well), nor a
    // group with no host.
    final sections = _arranging
        ? [
            for (final s in sectionsShown)
              if (s.id != _pinned && s.hosts.isNotEmpty)
                _Section(
                  id: s.id,
                  label: s.label,
                  hosts: _inArrangedOrder(s.id, s.hosts),
                  color: s.color,
                  icon: s.icon,
                  group: s.group,
                ),
          ]
        : _activeFirst(sectionsShown, l10n, open: open);
    // Arrange is offered where there is an order to make and it may be
    // changed (as groups may), and not while hosts are selected.
    final selection = ref.watch(hostMultiSelectProvider);
    final selecting = selection.active;
    final canArrange = canEditGroups && hosts.length > 1 && !selecting;

    // The hosts shown, in their order: what Select all shown selects (3.4).
    final shownIds = <String>{
      for (final s in sections)
        for (final h in s.hosts) h.connection.id,
    }.toList();
    if (!listEquals(ref.read(phoneShownHostIdsProvider), shownIds)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(phoneShownHostIdsProvider.notifier).state = shownIds;
      });
    }
    final hiddenSelected = selecting ? selection.selected.where((id) => !shownIds.contains(id)).length : 0;

    final chips = <Widget>[
      _FilterChip(
        key: const ValueKey('phone-filter-all'),
        label: l10n.zestHostsAll,
        count: hosts.length,
        selected: filter == _all,
        onTap: () => setState(() => _filter = _all),
      ),
      if (pinned.isNotEmpty)
        _FilterChip(
          key: const ValueKey('phone-filter-pinned'),
          label: l10n.phoneHostsPinned,
          icon: LucideIcons.star,
          selected: filter == _pinned,
          onTap: () => setState(() => _filter = filter == _pinned ? _all : _pinned),
        ),
      for (final g in orderedGroups)
        _FilterChip(
          key: ValueKey('phone-filter-${g.id}'),
          label: g.name,
          count: inGroup(g.id),
          dot: resolveGroupColor(colorValue: g.colorValue, colorIndex: g.colorIndex, name: g.name),
          selected: filter == g.id,
          onTap: () => setState(() => _filter = filter == g.id ? _all : g.id),
          // Edit group, New group, Delete group.
          onLongPress: canEditGroups ? () => _groupActions(g) : null,
        ),
      if (groups.isNotEmpty && ungrouped.isNotEmpty)
        _FilterChip(
          key: const ValueKey('phone-filter-ungrouped'),
          label: l10n.zestGroupUngrouped,
          count: ungrouped.length,
          selected: filter == _ungrouped,
          onTap: () => setState(() => _filter = filter == _ungrouped ? _all : _ungrouped),
        ),
      // (New group is in the +'s menu since 4.0: it was a chip at the far
      // right, a row of controls fewer.)
    ];

    return CustomScrollView(
      key: const ValueKey('phone-hosts-list'),
      slivers: [
        // Selected hosts the search (or the group picked) hides: said, with
        // Show, which shows every host again.
        if (hiddenSelected > 0)
          SliverToBoxAdapter(
            child: _HiddenSelectedRow(
              count: hiddenSelected,
              onShow: () {
                ref.read(connectionSearchQueryProvider.notifier).state = '';
                setState(() => _filter = _all);
              },
            ),
          ),
        // Arranging: what to do, and Done, in place of the chips.
        if (_arranging)
          SliverToBoxAdapter(
            child: Padding(
              key: const ValueKey('phone-arrange-bar'),
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 2),
              child: Row(
                children: [
                  Icon(LucideIcons.arrowUpDown, size: 16, color: ZestTokens.brandInk),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l10n.hostsHomeArrangeBanner,
                      style: TextStyle(fontSize: 12.5, height: 1.35, color: ZestTokens.textSecondary),
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('phone-arrange-done'),
                    onPressed: () => _setArranging(false),
                    child: Text(l10n.done, style: TextStyle(fontWeight: FontWeight.w600, color: ZestTokens.brandInk)),
                  ),
                ],
              ),
            ),
          )
        // One row of chips that scrolls sideways (4.0: Arrange went into the
        // sort's sheet, and Active first's row under the chips with it).
        else if (chips.length > 1)
          SliverToBoxAdapter(
            child: SizedBox(
              height: 60,
              // Each chip a thumb's 48 high (drawn 36 in it).
              child: ListView.separated(
                key: const ValueKey('phone-filter-chips'),
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                scrollDirection: Axis.horizontal,
                itemCount: chips.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) => chips[i],
              ),
            ),
          ),
        for (final (i, s) in sections.indexed) ...[
          SliverToBoxAdapter(
            child: _SectionHeader(
              key: ValueKey('phone-section-${s.id}'),
              section: s,
              folded: _folded.contains(s.id),
              onToggle: () => setState(() {
                if (!_folded.remove(s.id)) _folded.add(s.id);
              }),
              onLongPress: s.group != null && canEditGroups && !_arranging ? () => _groupActions(s.group!) : null,
              // The list's sort, on the first head (4.0).
              //
              sort: i == 0 && !_arranging && hosts.isNotEmpty
                  ? _SortButton(mode: sortMode, onTap: () => _sortSheet(canArrange: canArrange))
                  : null,
            ),
          ),
          if (_arranging && !_folded.contains(s.id))
            // The group's hosts, each dragged by its handle; a list of the
            // scroll view itself, so a drag near an edge scrolls it.
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: DecoratedSliver(
                decoration: BoxDecoration(
                  color: ZestTokens.surfaceElevated,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: ZestTokens.borderSubtle, width: 0.6),
                ),
                sliver: SliverReorderableList(
                  key: ValueKey('phone-arrange-${s.id}'),
                  itemCount: s.hosts.length,
                  onReorderItem: (from, to) => _reorder(s, from, to),
                  proxyDecorator: (child, _, _) => Material(
                    color: ZestTokens.surfaceRaised,
                    elevation: 6,
                    borderRadius: BorderRadius.circular(12),
                    child: child,
                  ),
                  itemBuilder: (context, i) {
                    final h = s.hosts[i];
                    return Column(
                      key: ValueKey('phone-arrange-${s.id}-${h.connection.id}'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (i > 0) Divider(height: 0.6, thickness: 0.6, indent: 64, color: ZestTokens.borderSubtle),
                        PhoneHostRow(
                          key: ValueKey('phone-host-${s.id}-${h.connection.id}'),
                          host: h,
                          open: open.contains(h.connection.id),
                          health: health[h.connection.id],
                          pinned: pinnedIds.contains(h.connection.id),
                          actions: widget.actionsOf(h),
                          openSessions: openOf(h.connection.id),
                          healthChips: chipsOf(h.connection.id),
                          keyChanged: keyChangedOf(h),
                          arrangeIndex: i,
                        ),
                      ],
                    );
                  },
                ),
              ),
            )
          else if (!_folded.contains(s.id))
            SliverToBoxAdapter(
              child: _SectionCard(
                children: [
                  // A group with no host yet: says so, and is filled from
                  // its Edit group.
                  if (s.hosts.isEmpty && s.group != null)
                    _EmptyGroupRow(
                      key: ValueKey('phone-group-empty-${s.id}'),
                      onAddHosts: canEditGroups ? () => showEditGroupSheet(context, s.id) : null,
                    ),
                  for (final h in s.hosts)
                    PhoneHostRow(
                      key: ValueKey('phone-host-${s.id}-${h.connection.id}'),
                      host: h,
                      open: open.contains(h.connection.id),
                      health: health[h.connection.id],
                      pinned: pinnedIds.contains(h.connection.id),
                      actions: widget.actionsOf(h),
                      openSessions: openOf(h.connection.id),
                      healthChips: chipsOf(h.connection.id),
                      keyChanged: keyChangedOf(h),
                      selecting: selecting,
                      selected: selection.isSelected(h.connection.id),
                      onToggle: () {
                        haptic(ref, Haptic.selection);
                        ref.read(hostMultiSelectProvider.notifier).toggle(h.connection.id);
                      },
                      // A long press starts selecting, with this host (3.4).
                      onStartSelecting: () {
                        haptic(ref, Haptic.medium);
                        ref.read(hostSelectionPlaceProvider.notifier).state = HostSelectionPlace.page;
                        ref.read(hostMultiSelectProvider.notifier).enter(h.connection.id);
                      },
                    ),
                ],
              ),
            ),
        ],
        SliverToBoxAdapter(child: SizedBox(height: widget.bottomPadding)),
      ],
    );
  }

  /// A long press on a group: Edit group, New group, Delete group; a group
  /// made there is picked.
  Future<void> _groupActions(ConnectionGroup group) async {
    haptic(ref, Haptic.selection);
    final made = await openGroupActions(context, group);
    if (made != null && mounted) setState(() => _filter = made);
  }
}

/// A group with no host yet, in its section: says so, with Add hosts.
class _EmptyGroupRow extends StatelessWidget {
  const _EmptyGroupRow({super.key, required this.onAddHosts});
  final VoidCallback? onAddHosts;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(l10n.phoneGroupsEmpty, style: TextStyle(fontSize: 13, color: ZestTokens.textTertiary)),
          ),
          if (onAddHosts != null)
            TextButton.icon(
              key: const ValueKey('phone-group-empty-add'),
              onPressed: onAddHosts,
              icon: Icon(LucideIcons.plus, size: 16, color: ZestTokens.brandInk),
              label: Text(l10n.phoneGroupsAddHosts, style: TextStyle(color: ZestTokens.brandInk)),
            ),
        ],
      ),
    );
  }
}

class _Section {
  const _Section({
    required this.id,
    required this.label,
    required this.hosts,
    required this.color,
    this.icon,
    this.group,
  });
  final String id;
  final String label;
  final List<ConnectionWithDetails> hosts;
  final Color color;
  final IconData? icon;

  /// The group the section is (none for pinned and ungrouped).
  final ConnectionGroup? group;
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
    this.icon,
    this.dot,
    this.onLongPress,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;
  final IconData? icon;
  final Color? dot;

  /// A group's chip: what may be done to the group (a right click with a
  /// mouse on a tablet).
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final brand = ZestTokens.brand;
    final fg = selected ? ZestTokens.brandInk : ZestTokens.textSecondary;
    // "Web, 2 hosts", picked or not (it read "Web" and "2" as two lines).
    final l10n = AppLocalizations.of(context)!;
    return Semantics(
      selected: selected,
      button: true,
      label: count == null ? label : '$label, ${l10n.hostsMetaHostCount(count!)}',
      excludeSemantics: true,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          onLongPress: onLongPress,
          onSecondaryTap: onLongPress,
          // A thumb's 48 high, the chip drawn 36 high in it.
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Ink(
              decoration: ShapeDecoration(
                color: selected ? brand.withValues(alpha: 0.12) : ZestTokens.surfaceRaised,
                shape: StadiumBorder(
                    side: BorderSide(color: selected ? brand.withValues(alpha: 0.55) : ZestTokens.borderSubtle)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 13),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 13, color: selected ? ZestTokens.brandInk : ZestTokens.textTertiary),
                      const SizedBox(width: 6),
                    ],
                    if (dot != null) ...[
                      Container(width: 7, height: 7, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
                      const SizedBox(width: 7),
                    ],
                    Text(label, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: fg)),
                    if (count != null) ...[
                      const SizedBox(width: 6),
                      // A count, in the app's own type (monospace is for values).
                      Text('$count',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: selected ? ZestTokens.brandInk : ZestTokens.textTertiary)),
                    ],
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

/// The list's sort on the first section's head (4.0): the sort in use, in
/// words beside its icon, a thumb's 48 high; a tap opens its sheet.
class _SortButton extends StatelessWidget {
  const _SortButton({required this.mode, required this.onTap});

  final HostSortMode mode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final name = mode.nameIn(l10n);
    // A button of its own, apart from the head it sits in (which folds it).
    return Semantics(
      container: true,
      button: true,
      label: l10n.hostsHomeSortPrefix(name),
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: const ValueKey('phone-hosts-sort'),
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.arrowUpDown, size: 16, color: ZestTokens.textTertiary),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13.5, color: ZestTokens.textTertiary)),
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

/// A row of a sheet with a switch: its icon, its name and a line under it,
/// the switch at its end; a tap anywhere on it turns it.
class _SheetSwitchRow extends StatelessWidget {
  const _SheetSwitchRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      toggled: value,
      label: label,
      hint: subtitle,
      onTap: () => onChanged(!value),
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => onChanged(!value),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(
              children: [
                Icon(icon, size: 18, color: value ? ZestTokens.statusHealthy : ZestTokens.textTertiary),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(label, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary)),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(subtitle!, style: TextStyle(fontSize: 12, height: 1.35, color: ZestTokens.textTertiary)),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                ExcludeFocus(child: ZestSwitch(value: value, onChanged: onChanged)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    super.key,
    required this.section,
    required this.folded,
    required this.onToggle,
    this.onLongPress,
    this.sort,
  });

  final _Section section;
  final bool folded;
  final VoidCallback onToggle;

  /// A group's header: what may be done to the group.
  final VoidCallback? onLongPress;

  /// The list's sort, on the first head ([_SortButton]).
  final Widget? sort;

  // The section header every page has (ZestSectionHeader: the brand's tick,
  // capitals, a hairline), with the hosts' count and the fold chevron
  // at its end; the line folds the section, 44 high (a box
  // with the section's first letter, no rule, a 24 high fold control).
  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      expanded: !folded,
      child: InkWell(
        onTap: onToggle,
        onLongPress: onLongPress,
        onSecondaryTap: onLongPress,
        child: ConstrainedBox(
          // A finger's 48 (it was 44: 4.0, the accessibility pass).
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            // (The sort is a thumb's 48 high: the head takes less room above it.)
            padding: EdgeInsets.fromLTRB(16, sort == null ? 16 : 2, 16, 0),
            child: ZestSectionHeader(
              label: section.label,
              count: section.hosts.length,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (sort != null) Flexible(child: sort!),
                  AnimatedRotation(
                    turns: folded ? -0.25 : 0,
                    duration: const Duration(milliseconds: 160),
                    child: Icon(LucideIcons.chevronDown, size: 16, color: ZestTokens.textTertiary),
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

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ZestTokens.borderSubtle, width: 0.6),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 0.6, thickness: 0.6, indent: 64, color: ZestTokens.borderSubtle),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// One host on a phone, as a computer's card has it (4.0):
/// its OS tile, its name with "Open" or "2 open" while it
/// has sessions and one health chip only where a limit is crossed, how it is
/// reached, and one more button for everything else the row offers (its
/// details, edit and the rest: the host's sheet). A tap connects, a long
/// press selects. It ended in two buttons (details, and an arrow that
/// connected), so the row itself was not the plain thing to tap.
class PhoneHostRow extends ConsumerWidget {
  const PhoneHostRow({
    super.key,
    required this.host,
    required this.open,
    required this.health,
    required this.pinned,
    required this.actions,
    this.openSessions = 0,
    this.healthChips = const [],
    this.keyChanged = false,
    this.arrangeIndex,
    this.selecting = false,
    this.selected = false,
    this.onToggle,
    this.onStartSelecting,
  });

  final ConnectionWithDetails host;
  final bool open;
  final HealthCheckResult? health;
  final bool pinned;
  final PhoneHostActions actions;

  /// How many of its sessions are open or opening ("2 open"); one where it
  /// is [open] and none is said.
  final int openSessions;

  /// Server Monitor's warnings for it, worst first ([healthChipsFor]): the
  /// row shows the worst. Given by the list, as a computer's page gives its
  /// cards theirs.
  final List<HostHealthChip> healthChips;

  /// It presented a changed host key nobody has resolved: in the chip's
  /// place, which it outranks.
  final bool keyChanged;

  /// Hosts are being selected (3.4): the row has its box before its tile, a
  /// tap or a long press puts it in or takes it out ([onToggle]), and its
  /// buttons give way.
  final bool selecting;
  final bool selected;
  final VoidCallback? onToggle;

  /// A long press starts selecting, with this host; null: it opens the
  /// host's sheet, as before.
  final VoidCallback? onStartSelecting;

  /// While the list is arranged (3.1): the row's place in its group's
  /// reorderable list. The row then has a handle to drag it by in place of
  /// its buttons, and a tap or a long press does nothing.
  final int? arrangeIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final conn = host.connection;
    final shownLabel = Redactable.host(conn.label).displayIn(ref);
    final brand = ZestTokens.brand;
    final protocol = conn.protocol;
    final vault = _vaultNameOf(ref, l10n, conn.id);
    final arranging = arrangeIndex != null;
    final oldKex = ref.watch(kexRefusedHostsProvider).contains(conn.id) && !conn.compatibilityMode;
    void sheet() => showPhoneHostSheet(context, ref, host, actions, pinned: pinned);
    // How many of its sessions are open or opening.
    final openCount = !open ? 0 : (openSessions > 0 ? openSessions : 1);
    // One chip at most, as a computer's card: a changed host key, else
    // Server Monitor's worst reading over its limit, else (where checks of
    // whether hosts answer are on) that it does not answer.
    final Widget? chip = keyChanged
        ? HostKeyChangedChip(key: ValueKey('phone-host-key-changed-${conn.id}'))
        : healthChips.isNotEmpty
            ? HostHealthChipView(key: ValueKey('phone-host-health-${conn.id}'), chip: worstHealthChip(healthChips))
            : !open && health?.status == ConnectionHealth.offline
                ? HostHealthChipView(
                    key: ValueKey('phone-host-unreachable-${conn.id}'),
                    chip: HostHealthChip(
                        label: l10n.hostsHealthUnreachable, critical: true, tooltip: l10n.hostsHealthUnreachable),
                  )
                : null;
    // The row as one sentence for a screen reader: its name, how it is
    // reached, whether it is open, what needs attention (it read its name
    // twice, then its address, and said nothing of its state).
    final address = teamMayNotOpenWith(protocol) && ref.read(databaseProvider).isOrchard
        ? l10n.teamHostLocalShellRow
        : _addressOf(ref, host);
    final spoken = [
      shownLabel,
      address,
      if (vault != null || protocol != 'ssh') [?vault, if (protocol != 'ssh') _protocolName(protocol)].join(', '),
      if (openCount > 0) openCount > 1 ? l10n.hostOpenSessionsCount(openCount) : l10n.phoneHostsOpen,
      if (keyChanged) l10n.hostKeyChangedTitle,
      if (!keyChanged)
        for (final c in healthChips) c.tooltip,
      if (!keyChanged && healthChips.isEmpty && !open && health?.status == ConnectionHealth.offline)
        l10n.hostsHealthUnreachable,
      if (oldKex) l10n.bulkOldKeyExchange,
      if (pinned) l10n.phoneHostsPinned,
    ].join(', ');
    return Semantics(
      button: !arranging,
      checked: selecting ? selected : null,
      label: spoken,
      // What a tap on the row does, now that no button beside it says so.
      onTapHint: arranging || selecting ? null : l10n.phoneHostsConnectTo(shownLabel),
      child: InkWell(
        onTap: arranging ? null : (selecting ? onToggle : actions.connect),
        onLongPress: arranging ? null : (selecting ? onToggle : (onStartSelecting ?? sheet)),
        // A mouse on a tablet: a right click is what a long press was, the
        // host's sheet.
        onSecondaryTap: arranging || selecting ? null : sheet,
        child: Stack(
          children: [
            if (selecting && selected)
              Positioned.fill(child: ColoredBox(color: brand.withValues(alpha: 0.08))),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 9, 4, 9),
              child: Row(
                children: [
                  if (selecting) ...[
                    HostSelectBox(key: ValueKey('phone-host-box-${conn.id}'), checked: selected, size: 20),
                    const SizedBox(width: 14),
                  ],
                  ExcludeSemantics(child: PhoneHostTile(host: host, size: 38)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ExcludeSemantics(child: Row(
                          children: [
                            Flexible(
                              child: RedactedText(
                                Redactable.host(conn.label),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                              ),
                            ),
                            // Open, in words with its dot, and one chip at
                            // most, as a computer's card (4.0).
                            if (openCount > 0) ...[
                              const SizedBox(width: 8),
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 110),
                                child: HostOpenSignal(
                                    key: ValueKey('phone-host-open-${conn.id}'), count: openCount, fontSize: 12.5),
                              ),
                            ],
                            if (chip != null) ...[
                              const SizedBox(width: 8),
                              ConstrainedBox(constraints: const BoxConstraints(maxWidth: 140), child: chip),
                            ],
                            // Its vault and how it connects: plain text.
                            if (vault != null || protocol != 'ssh') ...[
                              const SizedBox(width: 7),
                              Flexible(
                                child: Text(
                                  [?vault, if (protocol != 'ssh') _protocolName(protocol)].join(' · '),
                                  key: ValueKey('phone-host-meta-${conn.id}'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 11.5, color: ZestTokens.textTertiary),
                                ),
                              ),
                            ],
                          ],
                        )),
                        const SizedBox(height: 3),
                        // How it is reached, then what its team's vault says
                        // of it before connecting, as a host's card on a
                        // computer has them: its sessions logged or
                        // watched, its vault closed on this device by
                        // its offline limit. Small marks, the address cut
                        // first.
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                // One a team's record brought that opens no
                                // shell here says so.
                                address,
                                semanticsLabel: '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5, color: ZestTokens.textTertiary),
                              ),
                            ),
                            // Refused for an old key exchange (3.4).
                            if (oldKex) ...[
                              const SizedBox(width: 8),
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 150),
                                child: ExcludeSemantics(child: HostOldKexChip(key: ValueKey('phone-host-old-kex-${conn.id}'))),
                              ),
                            ],
                            // Each says nothing outside a team's space, as on a
                            // computer's host card.
                            const SizedBox(width: 6),
                            HostSessionsLoggedNote(connectionId: conn.id, compact: true),
                            HostSessionsWatchedNote(connectionId: conn.id, compact: true),
                            HostCrateClosedNote(connectionId: conn.id, compact: true),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (arranging)
                    ReorderableDragStartListener(
                      key: ValueKey('phone-host-drag-${conn.id}'),
                      index: arrangeIndex!,
                      child: Semantics(
                        label: l10n.phoneHostsDragToMove(shownLabel),
                        excludeSemantics: true,
                        child: Tooltip(
                          message: l10n.phoneHostsDragToMove(shownLabel),
                          child: SizedBox(
                            width: 48,
                            height: 48,
                            child: Icon(LucideIcons.gripVertical, size: 20, color: ZestTokens.textTertiary),
                          ),
                        ),
                      ),
                    )
                  // Everything else the row offers (its details, edit and the
                  // rest), in the host's sheet. (Not while hosts are selected:
                  // a tap selects.)
                  else if (selecting)
                    const SizedBox(width: 12)
                  else ...[
                    // Its own screen, one press away (4.0).
                    if (actions.openScreen != null)
                      HostScreenButton(hostId: conn.id, onOpen: actions.openScreen!, size: 48, iconSize: 20, phone: true),
                    Semantics(
                      container: true,
                      button: true,
                      label: l10n.phoneHostMoreActions(shownLabel),
                      onTap: sheet,
                      excludeSemantics: true,
                      child: Tooltip(
                        message: l10n.phoneHostMoreActions(shownLabel),
                        child: Material(
                          key: ValueKey('phone-host-more-${conn.id}'),
                          type: MaterialType.transparency,
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: sheet,
                            child: SizedBox(
                              width: 48,
                              height: 48,
                              child: Icon(LucideIcons.moreVertical, size: 20, color: ZestTokens.textTertiary),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The name of the vault a host is in, while a team is on screen and has
/// more than one; null otherwise.
String? _vaultNameOf(WidgetRef ref, AppLocalizations l10n, String hostId) {
  if (!kOrchardsEnabled) return null;
  final orchard = ref.watch(activeOrchardProvider).valueOrNull;
  if (orchard == null || orchard.crates.length < 2) return null;
  // A vault picked already says itself: its hosts need no tag.
  if (ref.watch(selectedCrateFilterProvider) != null) return null;
  final hostCrates = ref.watch(hostCratesProvider).valueOrNull ?? const <String, String>{};
  final crateId = crateOfHost(hostId, hostCrates, orchard);
  final crate = orchard.crates.where((c) => c.id == crateId).firstOrNull;
  return crate == null ? null : crateDisplayName(crate, l10n);
}

/// `user@host:port`, each part masked in recording mode. A remote screen:
/// where it listens and the SSH host it is reached through, as a computer's
/// card says it ("localhost:5900 via web-01"); its kind is said beside it.
String _addressOf(WidgetRef ref, ConnectionWithDetails host) {
  final c = host.connection;
  if (ConnectionProtocol.storedIsScreen(c.protocol)) {
    final all = ref.read(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
    final line = screenCardSubtitleOf(c,
        labelOf: (id) {
          final carrier = all.where((h) => h.connection.id == id).firstOrNull?.connection;
          return carrier == null ? null : (carrier.label.isNotEmpty ? carrier.label : carrier.host);
        },
        via: gl10n.pfPageVia,
        withKind: false);
    return Redactable.freeText(line).displayIn(ref);
  }
  final user = host.identity?.username;
  final address = Redactable.address(hostWithPort(c.host, c.port)).displayIn(ref);
  return user == null ? address : '${Redactable.username(user).displayIn(ref)}@$address';
}

String _protocolName(String protocol) => switch (protocol) {
      'sftp' => 'SFTP',
      'telnet' => 'Telnet',
      'mosh' => 'Mosh',
      'et' => 'ET',
      'serial' => gl10n.connectionEditProtocolSerialShort,
      'localShell' => gl10n.iconNameShell,
      'demo' => gl10n.protocolNameDemo,
      _ => protocol.toUpperCase(),
    };

/// A host's tile, the one a computer's card draws (4.0,
/// one row model): its own icon or picture where it has one, else
/// the icon of the system seen on it, else the terminal of a system not yet
/// seen, on its colour's tile. (It drew the first letter of the name for a
/// system not yet seen, where a computer drew an icon.)
class PhoneHostTile extends ConsumerWidget {
  const PhoneHostTile({super.key, required this.host, this.size = 38});

  final ConnectionWithDetails host;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = host.connection;
    final seen = ref.watch(detectedOsProvider(conn.id));
    final osId = seen == null ? null : osCatalogIdFor(seen);
    final group = host.group;
    // Its colour label (its own, else its group's), for an icon that follows
    // it, as on a computer.
    final label = AppColors.resolveConnectionLabelColorOrNull(
      connColorValue: conn.colorValue,
      connColorIndex: conn.colorIndex,
      inheritedGroupColor: group == null
          ? null
          : resolveGroupColor(colorValue: group.colorValue, colorIndex: group.colorIndex, name: group.name),
    );
    return HostIcon(
      // A remote screen (4.0) shows a screen where nothing else is chosen.
      iconId: conn.iconId ?? defaultIconIdFor(conn.protocol),
      customIcon: conn.customIcon,
      osId: osId,
      size: size,
      cornerRadius: size * 0.24,
      iconColor: conn.iconColor,
      labelColor: label,
    );
  }
}

// ── The host's sheet ──────────────────────────────────────────────────────

/// The host's sheet (its row's more button, a right click, or More while it
/// is selected): its name and address, the four things done most (connect,
/// its files, connect as another of its accounts, wake it), then its details
/// and everything else that may be done to it.
Future<void> showPhoneHostSheet(
  BuildContext context,
  WidgetRef ref,
  ConnectionWithDetails host,
  PhoneHostActions actions, {
  required bool pinned,
}) async {
  haptic(ref, Haptic.selection);
  final choices = actions.connectAs == null
      ? const <HostAccountChoice>[]
      : await hostAccountChoicesNow(ref, host.connection.id);
  if (!context.mounted) return;
  await showZestSheet<void>(
    context: context,
    child: _HostSheet(host: host, actions: actions, pinned: pinned, accounts: choices, opener: context),
  );
}

class _HostSheet extends ConsumerWidget {
  const _HostSheet({
    required this.host,
    required this.actions,
    required this.pinned,
    required this.accounts,
    required this.opener,
  });

  final ConnectionWithDetails host;
  final PhoneHostActions actions;
  final bool pinned;
  final List<HostAccountChoice> accounts;

  /// The page the sheet was opened from: what is asked after the sheet has
  /// closed (Delete's question) is asked there, the sheet's own context
  /// being gone by then.
  final BuildContext opener;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final conn = host.connection;
    final group = host.group;
    final connectAs = connectAsItems(l10n, ref, accounts, defaultUsername: host.identity?.username);
    final canWake = actions.wake != null && conn.wolMacAddress != null;
    final sshLike = conn.protocol == 'ssh' || conn.protocol == 'mosh' || conn.protocol == 'et';
    final screens = ref.watch(screensOfHostProvider(conn.id));

    void close() => Navigator.of(context).pop();
    void run(VoidCallback f) {
      close();
      f();
    }

    final quick = <Widget>[
      _QuickAction(
        key: const ValueKey('phone-sheet-connect'),
        icon: LucideIcons.arrowRight,
        label: l10n.commonConnect,
        primary: true,
        onTap: () => run(actions.connect),
      ),
      // (A host that is SFTP only opens to its files by Connect too.)
      if (sshLike || conn.protocol == 'sftp')
        _QuickAction(
          key: const ValueKey('phone-sheet-files'),
          icon: LucideIcons.folderOpen,
          label: l10n.phoneHostsFiles,
          onTap: () => run(() => _openFiles(ref, context, conn.id, actions.connect)),
        ),
      if (connectAs.isNotEmpty)
        _QuickAction(
          key: const ValueKey('phone-sheet-connect-as'),
          icon: LucideIcons.userCheck,
          label: l10n.phoneHostsConnectAs,
          onTap: () => _pickAccount(context, connectAs),
        ),
      // Its own screen (4.0): one, or a list of them.
      if (actions.openScreen != null && screens.isNotEmpty)
        _QuickAction(
          key: const ValueKey('phone-sheet-screen'),
          icon: LucideIcons.monitor,
          label: l10n.phoneHostsScreen,
          onTap: () => run(() => unawaited(pickHostScreen(opener, ref, screens, actions.openScreen!))),
        ),
      if (canWake)
        _QuickAction(
          key: const ValueKey('phone-sheet-wake'),
          icon: LucideIcons.zap,
          label: l10n.phoneHostsWake,
          onTap: () => run(actions.wake!),
        ),
    ];

    final address = hostWithPort(conn.host, conn.port);
    return ZestSheetFrame(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // The host.
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 6, 2, 14),
                child: Row(
                  children: [
                    PhoneHostTile(host: host, size: 42),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          RedactedText(
                            Redactable.host(conn.label),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                          ),
                          const SizedBox(height: 3),
                          Text(_addressOf(ref, host),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, color: ZestTokens.textTertiary)),
                        ],
                      ),
                    ),
                    // Its group: plain text with the group's dot (it was a
                    // chip; chips are for what needs someone).
                    if (group != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: resolveGroupColor(
                              colorValue: group.colorValue, colorIndex: group.colorIndex, name: group.name),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 120),
                        child: Text(group.name,
                            key: const ValueKey('phone-sheet-group-name'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12.5, color: ZestTokens.textSecondary)),
                      ),
                    ],
                  ],
                ),
              ),
              // What is done most.
              Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  border: Border.symmetric(horizontal: BorderSide(color: ZestTokens.borderSubtle, width: 0.6)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [for (final q in quick) Expanded(child: q)],
                ),
              ),
              const SizedBox(height: 4),
              // The host's page (3.1): what a computer's host panel shows
              // (its health, its sessions, its forwards, its tags and its
              // note). It was the info button at the row's end (4.0).
              _SheetRow(
                key: const ValueKey('phone-sheet-details'),
                icon: LucideIcons.info,
                label: l10n.phoneSheetDetails,
                trailingIcon: LucideIcons.chevronRight,
                onTap: () => run(() => openPhoneHostPage(opener, host, actions)),
              ),
              _SheetRow(
                key: const ValueKey('phone-sheet-edit'),
                icon: LucideIcons.pencil,
                label: l10n.phoneHostsEditHost,
                trailingIcon: LucideIcons.chevronRight,
                onTap: () => run(actions.edit),
              ),
              // Where the host is kept (4.0: grouped as a computer's menu groups
              // them; it was one list of every row).
              const _SheetSection('organize'),
              // Only where the role may change the host (in a team's vault;
              // as a computer's menu offers it): the move was refused by
              // the team's database, with nothing said
              // before.
              if (mayChangeItem(ref, 'host', conn.id))
                _SheetRow(
                  key: const ValueKey('phone-sheet-group'),
                  icon: LucideIcons.folderInput,
                  label: l10n.phoneHostsMoveToGroup,
                  value: group?.name ?? l10n.zestGroupUngrouped,
                  onTap: () => _moveToGroup(context, ref, host, opener: opener),
                ),
              if (actions.moveTo != null)
                _SheetRow(
                  key: const ValueKey('phone-sheet-move-to'),
                  icon: LucideIcons.folderInput,
                  label: l10n.transferMoveTo,
                  trailingIcon: LucideIcons.chevronRight,
                  onTap: () => run(actions.moveTo!),
                ),
              if (actions.copyTo != null)
                _SheetRow(
                  key: const ValueKey('phone-sheet-copy-to'),
                  icon: LucideIcons.copyPlus,
                  label: l10n.transferCopyTo,
                  trailingIcon: LucideIcons.chevronRight,
                  onTap: () => run(actions.copyTo!),
                ),
              _SheetRow(
                key: const ValueKey('phone-sheet-pin'),
                icon: LucideIcons.star,
                label: pinned ? l10n.hostsHomeMenuUnpin : l10n.hostsHomeMenuPin,
                trailingIcon: pinned ? LucideIcons.star : LucideIcons.star,
                onTap: () => run(() => unawaited(ref.read(pinnedHostsProvider.notifier).toggle(conn.id))),
              ),
              if (actions.duplicate != null)
                _SheetRow(
                  key: const ValueKey('phone-sheet-duplicate'),
                  icon: LucideIcons.copyPlus,
                  label: l10n.commonDuplicate,
                  onTap: () => run(actions.duplicate!),
                ),
              if (actions.share != null)
                _SheetRow(
                  key: const ValueKey('phone-sheet-share'),
                  icon: LucideIcons.share2,
                  label: l10n.connectionCardShare,
                  onTap: () => run(actions.share!),
                ),
              // What else may be done with it.
              const _SheetSection('tools'),
              _SheetRow(
                key: const ValueKey('phone-sheet-copy'),
                icon: LucideIcons.copy,
                label: l10n.phoneHostsCopyAddress,
                value: Redactable.address(address).displayIn(ref),
                monoValue: true,
                onTap: () => run(() {
                  Clipboard.setData(ClipboardData(text: address));
                  showTopSnackBar(context, l10n.phoneHostsAddressCopied, isSuccess: true);
                }),
              ),
              if (conn.protocol != 'telnet' && sshLike)
                _SheetRow(
                  key: const ValueKey('phone-sheet-tmux'),
                  icon: LucideIcons.layoutGrid,
                  label: l10n.termTbTmux,
                  onTap: () => run(() => _openTmux(ref, context, conn.id, actions.connect)),
                ),
              if (conn.protocol == 'ssh') _MonitorRow(connectionId: conn.id, monitored: conn.monitored),
              // A remote screen (4.0) reached through this host.
              if (screenCarrierKind(conn.protocol) && actions.duplicate != null)
                _SheetRow(
                  key: const ValueKey('phone-sheet-add-screen'),
                  icon: LucideIcons.monitor,
                  label: l10n.hostMenuAddScreen,
                  // VNC or RDP asked first, over the page the sheet was opened from.
                  onTap: () => run(() => unawaited(addScreenForHost(opener, ref, conn))),
                ),
              // An X program on this host, in a screen of its own (4.0):
              // asked over the page that opened the sheet, which is gone by then.
              if (screenCarrierKind(conn.protocol))
                _SheetRow(
                  key: const ValueKey('phone-sheet-x-program'),
                  icon: LucideIcons.appWindow,
                  label: l10n.hostMenuOpenXProgram,
                  onTap: () => run(() => unawaited(openXProgramOnPhone(opener, conn))),
                ),
              // A Proxmox guest's console (4.0): for a host imported as one.
              if (proxmoxGuestOf(conn) != null)
                _SheetRow(
                  key: const ValueKey('phone-sheet-console'),
                  icon: LucideIcons.monitorPlay,
                  label: l10n.hostMenuOpenConsole,
                  onTap: () => run(() => unawaited(openConsoleOnPhone(opener, conn))),
                ),
              const SizedBox(height: 8),
              if (actions.delete != null)
                _SheetRow(
                  key: const ValueKey('phone-sheet-delete'),
                  icon: LucideIcons.trash2,
                  label: l10n.delete,
                  destructive: true,
                  onTap: () async {
                    close();
                    // Asked on the page: the sheet's context went with it.
                    if (!opener.mounted) return;
                    final confirmed = await ZestConfirmDialog.show(
                      opener,
                      tone: ZestDialogTone.destructive,
                      title: l10n.connectionCardDeleteConnectionTitle,
                      body: l10n.connectionCardDeleteConfirm(Redactable.host(conn.label).display),
                      confirmLabel: l10n.delete,
                    );
                    if (confirmed == true) actions.delete!();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Which of the host's other accounts to connect as.
  Future<void> _pickAccount(BuildContext context, List<({String id, String text})> items) async {
    final picked = await showZestSheet<String>(
      context: context,
      child: ZestSheetFrame(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final a in items)
                Builder(
                  builder: (sheet) => _SheetRow(
                    key: ValueKey('connect-as-${a.id}'),
                    icon: LucideIcons.user,
                    label: a.text,
                    onTap: () => Navigator.of(sheet).pop(a.id),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !context.mounted) return;
    Navigator.of(context).pop();
    actions.connectAs?.call(picked);
  }
}

/// A host's files: its live session's, or the session connecting opens.
void _openFiles(WidgetRef ref, BuildContext context, String connectionId, VoidCallback connect) {
  final live = _liveSessionOf(ref, connectionId);
  ref.read(sftpPendingConnectionProvider.notifier).state = connectionId;
  if (live != null) {
    context.push('/terminal/$live');
    return;
  }
  connect();
}

/// tmux on a host: begun in its live session, or once connecting has one.
void _openTmux(WidgetRef ref, BuildContext context, String connectionId, VoidCallback connect) {
  final live = _liveSessionOf(ref, connectionId);
  if (live != null) {
    final tmux = ref.read(tmuxHostProvider(live));
    if (!tmux.active) tmux.begin();
    context.push('/terminal/$live');
    return;
  }
  ref.read(tmuxPendingConnectionProvider.notifier).state = connectionId;
  connect();
}

String? _liveSessionOf(WidgetRef ref, String connectionId) => ref
    .read(activeSessionsProvider)
    .entries
    .where((e) => e.value.connectionId == connectionId && e.value.status == SessionStatus.connected)
    .map((e) => e.key)
    .firstOrNull;

/// Which group the host goes in: each group, none, or a new one (3.0.1:
/// New group, where groups may be made here). [opener] is the page the
/// host's sheet was opened from: New group opens there, the host's sheet
/// being closed by then.
Future<void> _moveToGroup(
  BuildContext context,
  WidgetRef ref,
  ConnectionWithDetails host, {
  required BuildContext opener,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final groups = [...(ref.read(connectionGroupsProvider).valueOrNull ?? const <ConnectionGroup>[])]
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  final canMake = mayEditGroups(ref, watch: false);
  const none = '';
  const made = '\u0000new';
  final picked = await showZestSheet<String>(
    context: context,
    child: ZestSheetFrame(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Builder(
          builder: (sheet) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // What the sheet is, and for which host.
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.phoneHostsMoveToGroup,
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: ZestTokens.textPrimary)),
                    const SizedBox(height: 2),
                    RedactedText(
                      Redactable.host(host.connection.label),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: ZestTokens.textTertiary),
                    ),
                  ],
                ),
              ),
              for (final g in groups)
                _SheetRow(
                  key: ValueKey('phone-group-${g.id}'),
                  icon: LucideIcons.folder,
                  iconColor: resolveGroupColor(colorValue: g.colorValue, colorIndex: g.colorIndex, name: g.name),
                  label: g.name,
                  trailingIcon: host.group?.id == g.id ? LucideIcons.check : null,
                  onTap: () => Navigator.of(sheet).pop(g.id),
                ),
              _SheetRow(
                key: const ValueKey('phone-group-none'),
                icon: LucideIcons.folderMinus,
                label: l10n.zestGroupUngrouped,
                trailingIcon: host.group == null ? LucideIcons.check : null,
                onTap: () => Navigator.of(sheet).pop(none),
              ),
              if (canMake) ...[
                Divider(height: 9, thickness: 0.6, color: ZestTokens.borderSubtle),
                _SheetRow(
                  key: const ValueKey('phone-group-new'),
                  icon: LucideIcons.folderPlus,
                  iconColor: ZestTokens.brandInk,
                  label: l10n.phoneGroupsNewGroupMore,
                  onTap: () => Navigator.of(sheet).pop(made),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  Navigator.of(context).pop();
  if (picked == made) {
    await _moveToNewGroup(opener, host);
    return;
  }
  if (picked == (host.group?.id ?? none)) return;
  final crud = ref.read(connectionCrudProvider);
  await runTeamWrite(
      opener.mounted ? opener : context,
      () => crud.update(
            id: host.connection.id,
            groupId: picked == none ? null : picked,
            clearGroupId: picked == none,
          ),
      where: 'Move to a group');
}

/// New group from a host's Move to a group: the group is made, the host
/// moved into it, and the move said with Undo (which puts the host back;
/// the group stays).
Future<void> _moveToNewGroup(BuildContext opener, ConnectionWithDetails host) async {
  if (!opener.mounted) return;
  // The host's row goes once the host moves (it is drawn in its new
  // group's section): what is said after is said on the navigator's page.
  final page = Navigator.of(opener).context;
  final crud = ProviderScope.containerOf(opener, listen: false).read(connectionCrudProvider);
  final group = await showNewGroupSheet(opener, forHost: host.connection.label);
  if (group == null || !page.mounted) return;
  final before = host.connection.groupId;
  if (!await runTeamWrite(page, () => crud.update(id: host.connection.id, groupId: group.id),
      where: 'Move to a new group')) {
    return;
  }
  if (!page.mounted) return;
  final l10n = AppLocalizations.of(page)!;
  showTopSnackBar(
    page,
    l10n.phoneGroupsMovedHost(Redactable.host(host.connection.label).display, Redactable.group(group.name).display),
    isSuccess: true,
    actionLabel: l10n.hostsSelUndo,
    onAction: () => crud.update(id: host.connection.id, groupId: before, clearGroupId: before == null),
  );
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({super.key, required this.icon, required this.label, required this.onTap, this.primary = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final brand = ZestTokens.brand;
    // A button to a screen reader (an InkWell alone said nothing of it).
    return Semantics(
      button: true,
      child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: primary ? brand : ZestTokens.surfaceRaised,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: primary ? brand : ZestTokens.borderSubtle, width: 0.6),
                boxShadow: primary
                    ? [BoxShadow(color: brand.withValues(alpha: 0.3), blurRadius: 14, offset: const Offset(0, 4))]
                    : null,
              ),
              child: Icon(icon, size: 20, color: primary ? ZestTokens.onBrand : ZestTokens.textSecondary),
            ),
            const SizedBox(height: 7),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: ZestTokens.textSecondary)),
          ],
        ),
      ),
    ),
    );
  }
}

/// A section of the host's sheet, as a computer's menu has it: Organize or
/// Tools, a heading to a screen reader.
class _SheetSection extends StatelessWidget {
  const _SheetSection(this.which);

  /// 'organize' or 'tools'.
  final String which;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      key: ValueKey('phone-sheet-section-$which'),
      padding: const EdgeInsets.fromLTRB(2, 14, 2, 2),
      child: ZestSectionHeader(label: which == 'organize' ? l10n.hostMenuOrganize : l10n.hostMenuTools),
    );
  }
}

class _SheetRow extends StatelessWidget {
  const _SheetRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.value,
    this.trailingIcon,
    this.destructive = false,
    this.iconColor,
    this.subtitle,
    this.monoValue = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final String? value;

  /// [value] is a value to copy (an address): monospace. Otherwise (a
  /// group's name) the app's own type.
  final bool monoValue;
  final IconData? trailingIcon;
  final bool destructive;
  final Color? iconColor;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final fg = destructive ? ZestTokens.statusCritical : ZestTokens.textPrimary;
    // A button to a screen reader (an InkWell alone said nothing of it).
    return Semantics(
      button: true,
      child: InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 50),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Row(
            children: [
              Icon(icon, size: 18, color: destructive ? fg : (iconColor ?? ZestTokens.textTertiary)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: fg)),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(subtitle!, style: TextStyle(fontSize: 12, height: 1.35, color: ZestTokens.textTertiary)),
                    ],
                  ],
                ),
              ),
              if (value != null) ...[
                const SizedBox(width: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(value!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontFamily: monoValue ? 'JetBrainsMono' : null,
                          fontSize: monoValue ? 11.5 : 12.5,
                          color: ZestTokens.textTertiary)),
                ),
              ],
              if (trailingIcon != null) ...[
                const SizedBox(width: 8),
                Icon(trailingIcon, size: 16, color: ZestTokens.textTertiary),
              ],
            ],
          ),
        ),
      ),
    ),
    );
  }
}

/// Watching the host in the background (agentless, SSH hosts): on, off, or
/// the free tier's limit reached, which offers the upgrade.
class _MonitorRow extends ConsumerWidget {
  const _MonitorRow({required this.connectionId, required this.monitored});
  final String connectionId;
  final bool monitored;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final canAdd = ref.watch(canAddMonitoredHostProvider);
    void done() => Navigator.of(context).pop();
    if (monitored) {
      return _SheetRow(
        key: const ValueKey('phone-sheet-monitor'),
        icon: LucideIcons.radar,
        iconColor: ZestTokens.brandInk,
        label: l10n.monitorAgentlessStopHost,
        onTap: () {
          done();
          ref.read(connectionsDaoProvider).setMonitored(connectionId, false);
        },
      );
    }
    if (canAdd) {
      return _SheetRow(
        key: const ValueKey('phone-sheet-monitor'),
        icon: LucideIcons.radar,
        label: l10n.monitorAgentlessToggleHost,
        onTap: () {
          done();
          ref.read(connectionsDaoProvider).setMonitored(connectionId, true);
        },
      );
    }
    return _SheetRow(
      key: const ValueKey('phone-sheet-monitor'),
      icon: LucideIcons.lock,
      label: l10n.monitorAgentlessToggleHost,
      subtitle: l10n.monitorAgentlessLimitReached(freeMonitorLimit),
      onTap: () {
        done();
        PricingModal.show(context);
      },
    );
  }
}

/// "1 selected host is hidden by search", with Show.
///
class _HiddenSelectedRow extends StatelessWidget {
  const _HiddenSelectedRow({required this.count, required this.onShow});

  final int count;
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) => SelectionHiddenRow(
        key: const ValueKey('phone-selection-hidden'),
        text: AppLocalizations.of(context)!.bulkHiddenBySearch(count),
        onShow: onShow,
      );
}
