import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart' show Connection;
import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:zestssh/features/monitoring/monitor_host_views.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/ui/widgets/zest_list_search_field.dart';

/// The hosts, by group, with a search, to tick the ones something is for:
/// "Broadcast to hosts", "Run on hosts" (3.0) and what picks hosts for a
/// workflow's run. [picked] holds the ids ticked; [onChanged] hands on the new
/// set. A host's row is the one row of a host ([HostRow]: its icon, name,
/// user@address, the dot of an open session), a group's heading ticks its
/// hosts and says how many of them are ([place]'s Active first sets the ones
/// open apart). With [quickPicks], chips tick the hosts the Server monitor
/// singles out, and those open. Its rows, group boxes and search are keyed
/// `[keyPrefix]-host-` with the host's id, `[keyPrefix]-group-` with the
/// group's id (or `none`; `[keyPrefix]-active-group-` among the active ones)
/// and `[keyPrefix]-hosts-search`.
///
/// Where it is given a height to fill (a dialog whose body does not scroll),
/// the search and the chips stay and the hosts scroll under them; where it is
/// given none (a page that scrolls) it is as tall as its hosts.
///
/// Every list of it is of hosts something runs on (what is typed, a
/// command, a key put in place): a host that is SFTP only runs nothing, so
/// it is shown dimmed with why ([unavailable]: by default [noTerminalReason]),
/// and cannot be ticked, by itself or with its group.
class HostChecklist extends ConsumerStatefulWidget {
  const HostChecklist({
    super.key,
    required this.picked,
    required this.onChanged,
    this.keyPrefix = 'hosts',
    this.autofocus = true,
    this.place = HostListPlace.installKey,
    this.quickPicks = false,
    this.minListHeight = 220,
    this.unavailable = noTerminalReason,
  });

  final Set<String> picked;
  final ValueChanged<Set<String>> onChanged;
  final String keyPrefix;
  final bool autofocus;

  /// Which list this is: its own Active first.
  final HostListPlace place;

  /// The chips that tick what the Server monitor found, and what is open.
  final bool quickPicks;

  /// The least height of the hosts' list where it scrolls: a list that grew
  /// and shrank as the search narrowed it had the dialog jump around it.
  final double minListHeight;

  /// Why a host cannot be ticked here; null where it can.
  final String? Function(Connection host, AppLocalizations l10n) unavailable;

  @override
  ConsumerState<HostChecklist> createState() => _HostChecklistState();
}

class _HostChecklistState extends ConsumerState<HostChecklist> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _matches(ConnectionWithDetails c, String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    final conn = c.connection;
    return conn.label.toLowerCase().contains(q) ||
        conn.host.toLowerCase().contains(q) ||
        (c.identity?.username.toLowerCase().contains(q) ?? false) ||
        (c.group?.name.toLowerCase().contains(q) ?? false);
  }

  void _set(Set<String> Function(Set<String> now) change) => widget.onChanged(change({...widget.picked}));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final prefix = widget.keyPrefix;
    final all = ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
    final groups = ref.watch(connectionGroupsProvider).valueOrNull ?? const [];
    final open = ref.watch(openHostIdsProvider);
    final query = _search.text.trim();
    final shown = [for (final c in all) if (_matches(c, query)) c];
    final layout = layOutHosts(
      shown,
      groups: groups,
      activeFirst: ref.watch(activeFirstProvider(widget.place)),
      open: open,
      lastUsed: ref.watch(hostUseProvider),
    );

    Widget hostRow(ConnectionWithDetails c) {
      final conn = c.connection;
      final noTerminal = widget.unavailable(conn, l10n);
      final on = noTerminal == null && widget.picked.contains(conn.id);
      return HostRow(
        key: ValueKey('$prefix-host-${conn.id}'),
        host: conn,
        user: c.identity?.username,
        group: c.group,
        open: open.contains(conn.id),
        openLabel: l10n.broadcastToHostsIsOpen,
        showOpenLabel: true,
        unavailableReason: noTerminal,
        unavailableKey: ValueKey('$prefix-host-${conn.id}-no-terminal'),
        selected: on,
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        margin: const EdgeInsets.only(bottom: 1),
        leading: Checkbox(
          value: on,
          onChanged: noTerminal != null
              ? null
              : (v) => _set((p) => v == true ? (p..add(conn.id)) : (p..remove(conn.id))),
          visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onTap: () => _set((p) => on ? (p..remove(conn.id)) : (p..add(conn.id))),
      );
    }

    Widget groupHeading(HostBlock block, {required bool active}) {
      // (Its hosts that can be ticked: not one that is SFTP only.)
      final ids = [
        for (final c in block.hosts)
          if (widget.unavailable(c.connection, l10n) == null) c.connection.id,
      ];
      final ticked = ids.where(widget.picked.contains).length;
      final value = ticked == 0 ? false : (ticked == ids.length ? true : null);
      final id = block.group?.id ?? 'none';
      return HostGroupHeading(
        group: block.group,
        count: '$ticked/${ids.length}',
        leading: Checkbox(
          key: ValueKey(active ? '$prefix-active-group-$id' : '$prefix-group-$id'),
          tristate: true,
          value: value,
          onChanged: ids.isEmpty ? null : (_) => _set((p) => value == true ? (p..removeAll(ids)) : (p..addAll(ids))),
          visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }

    int countIn(List<HostBlock> blocks) => blocks.fold(0, (n, b) => n + b.hosts.length);

    final list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (layout.split) ...[
          HostSectionHeading(active: true, count: countIn(layout.active)),
          for (final b in layout.active) ...[
            groupHeading(b, active: true),
            for (final c in b.hosts) hostRow(c),
          ],
          if (layout.rest.isNotEmpty) HostSectionHeading(active: false, count: countIn(layout.rest)),
        ],
        for (final b in layout.rest) ...[
          groupHeading(b, active: false),
          for (final c in b.hosts) hostRow(c),
        ],
      ],
    );
    final none = Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Text(
        all.isEmpty ? l10n.hostPanelEmpty : l10n.broadcastToHostsNoMatch(query),
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12.5, color: ZestTokens.textTertiary),
      ),
    );

    final top = <Widget>[
      Row(
        children: [
          Expanded(
            child: ZestListSearchField(
              key: ValueKey('$prefix-hosts-search'),
              controller: _search,
              focusNode: _searchFocus,
              hintText: l10n.broadcastToHostsSearch,
              onChanged: (_) {},
            ),
          ),
          const SizedBox(width: 14),
          ActiveFirstToggle(place: widget.place),
        ],
      ),
      if (widget.quickPicks)
        _QuickPicks(
          picked: widget.picked,
          onChanged: widget.onChanged,
          keyPrefix: prefix,
          // Only what can be ticked.
          canRun: {
            for (final c in all)
              if (widget.unavailable(c.connection, l10n) == null) c.connection.id,
          },
        ),
      const SizedBox(height: 4),
    ];

    return LayoutBuilder(builder: (context, box) {
      if (!box.hasBoundedHeight) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [...top, if (shown.isEmpty) none else list],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ...top,
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: widget.minListHeight),
              child: shown.isEmpty
                  ? none
                  : Scrollbar(
                      controller: _scroll,
                      child: SingleChildScrollView(
                        key: ValueKey('$prefix-hosts-list'),
                        controller: _scroll,
                        child: Padding(padding: const EdgeInsetsDirectional.only(end: 10), child: list),
                      ),
                    ),
            ),
          ),
        ],
      );
    });
  }
}

/// Chips that tick hosts at once: those the Server monitor says ask for a
/// restart, have updates waiting or are over a limit, and those open (the
/// aim: make "Reboot needed" and "Updates pending"
/// actionable). They read what the monitor already found, and check nothing.
/// A chip whose hosts are all ticked unticks them; a chip with no hosts is not
/// shown.
class _QuickPicks extends ConsumerWidget {
  const _QuickPicks({required this.picked, required this.onChanged, required this.keyPrefix, required this.canRun});

  final Set<String> picked;
  final ValueChanged<Set<String>> onChanged;
  final String keyPrefix;
  final Set<String> canRun;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final facts = ref.watch(monitorHostFactsProvider);
    final open = ref.watch(openHostIdsProvider);
    Widget? chip(String name, String label, IconData icon, Color color, Set<String> ids) {
      final hosts = ids.intersection(canRun);
      if (hosts.isEmpty) return null;
      final allTicked = hosts.every(picked.contains);
      return _QuickChip(
        key: ValueKey('$keyPrefix-quick-$name'),
        label: label,
        count: hosts.length,
        icon: icon,
        color: color,
        on: allTicked,
        onTap: () => onChanged(allTicked ? ({...picked}..removeAll(hosts)) : {...picked, ...hosts}),
      );
    }

    final chips = [
      chip('reboot', l10n.hostRebootNeeded, LucideIcons.rotateCcw, ZestTokens.statusWarning, facts.rebootNeeded),
      chip('updates', l10n.hostsQuickUpdates, LucideIcons.packageCheck, ZestTokens.brandInk, facts.updatesPending),
      chip('warnings', l10n.hostsQuickWarnings, LucideIcons.alertTriangle, ZestTokens.statusCritical, facts.warnings),
      chip('open', l10n.broadcastToHostsIsOpen, LucideIcons.circleDot, ZestTokens.statusHealthy, open),
    ].whereType<Widget>().toList();
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(spacing: 6, runSpacing: 6, children: chips),
    );
  }
}

class _QuickChip extends StatelessWidget {
  const _QuickChip({
    super.key,
    required this.label,
    required this.count,
    required this.icon,
    required this.color,
    required this.on,
    required this.onTap,
  });

  final String label;
  final int count;
  final IconData icon;
  final Color color;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: on,
      child: Material(
        color: on ? ZestTokens.brandSubtle : ZestTokens.surfaceChip,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(7),
          side: BorderSide(color: on ? ZestTokens.brandBorder : ZestTokens.borderSubtle),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(7),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 13, color: color),
                const SizedBox(width: 6),
                Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary)),
                const SizedBox(width: 5),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: ZestTokens.textSecondary,
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
