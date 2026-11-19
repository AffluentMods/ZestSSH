import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/widgets/os_icon.dart';
import 'package:zestssh/core/widgets/status_pill.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/features/hosts/host_screens.dart';
import 'package:zestssh/features/monitoring/monitor_state_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart';

import '../host_health_summary.dart';
import '../state/host_multi_select.dart';
import '../state/host_sort_mode.dart';
import '../state/hosts_page_prefs.dart';
import 'host_card.dart';

typedef HostRow = ({HostCardData data, ConnectionWithDetails connectionWithDetails});

// The columns' shares of the width, the head and every row alike.
const _kHost = 20;
int hostsColumnFlex(HostsListColumn c) => switch (c) {
      // Before the rest: cut, an address loses the part that tells hosts apart.
      HostsListColumn.address => 19,
      HostsListColumn.group => 12,
      // Room for a warning's chip whole, its number too, in a longer language.
      HostsListColumn.health => 17,
      HostsListColumn.status => 13,
      // Room for its head whole in a longer language ("ZULETZT GENUTZT").
      HostsListColumn.lastUsed => 15,
      HostsListColumn.tags => 11,
    };

/// The sort a column's head sorts by (the tags have none).
HostSortMode? sortOfColumn(HostsListColumn? c) => switch (c) {
      null => HostSortMode.alphabetical,
      HostsListColumn.address => HostSortMode.ipAddress,
      HostsListColumn.group => HostSortMode.groupColor,
      HostsListColumn.health => HostSortMode.health,
      HostsListColumn.status => HostSortMode.status,
      HostsListColumn.lastUsed => HostSortMode.recent,
      HostsListColumn.tags => null,
    };

/// The width of the room at the end of each row: the head's column picker,
/// a row's menu.
const _kEnd = 32.0;

/// The end column's width: [_kEnd], a finger's 48 where the controls are
/// touch sized (its buttons' targets).
double _endWidth(BuildContext context) => touchSizedAt(context) ? 48 : _kEnd;

/// When a host was last connected, in the Last used column:
/// "Now", minutes, hours ("2h ago"), "Yesterday",
/// days ("6d ago"), then the date ("Oct 8"), with the year where it is not
/// this one.
String hostLastUsedWords(AppLocalizations l10n, DateTime when, {DateTime? now}) {
  final at = now ?? DateTime.now();
  final diff = at.difference(when);
  if (diff.isNegative || diff.inSeconds < 60) return l10n.hostsListNow;
  if (diff.inHours < 24) return timeAgoWords(l10n, when, now: at);
  final today = DateTime(at.year, at.month, at.day);
  final day = DateTime(when.year, when.month, when.day);
  if (today.difference(day).inDays <= 1) return l10n.hostsListYesterday;
  if (diff.inDays < 7) return timeAgoWords(l10n, when, now: at);
  if (when.year == at.year) return DateFormat.MMMd(l10n.localeName).format(when);
  return DateFormat.yMMMd(l10n.localeName).format(when);
}

/// The Hosts page as a list: one row a
/// host, in columns: the host (its icon and name), its address, its group,
/// its health (its worst metric), whether it is connected, and when it was
/// last used; the tags too where chosen ([HostsListColumn]). Every head
/// sorts by its column, the active one with an arrow ([sortMode], a second
/// click turns it round); the picker at the head's end chooses the columns.
/// A click opens a host in the panel, a double click connects, a right click
/// or its ⋯ is its menu, as on the cards. Selection works as on the cards:
/// Ctrl-click (Cmd on a Mac) adds or takes out a host, Shift-click selects a
/// range in the order of the rows, and in selection mode a click toggles
/// ([hostSelectionClick]).
class HostsTable extends ConsumerStatefulWidget {
  const HostsTable({
    super.key,
    required this.rows,
    required this.selectedHostId,
    required this.onSelect,
    required this.onConnect,
    required this.onMenu,
    this.onSelectionGesture,
    this.columns = HostsPagePrefs.defaultColumns,
    this.onColumnsChanged,
    this.sortMode,
    this.reversed = false,
    this.onSort,
  });

  /// A click changed the selection: the page takes the keyboard.
  final VoidCallback? onSelectionGesture;

  final List<HostRow> rows;
  final String? selectedHostId;
  final ValueChanged<ConnectionWithDetails> onSelect;
  final ValueChanged<ConnectionWithDetails> onConnect;
  final void Function(Offset position, HostRow row) onMenu;

  /// The columns shown besides the host's own.
  final Set<HostsListColumn> columns;

  /// The picker changed the columns (null: no picker).
  final ValueChanged<Set<HostsListColumn>>? onColumnsChanged;

  /// The sort the rows are in, its head marked with an arrow, which points
  /// up where it is [reversed].
  final HostSortMode? sortMode;
  final bool reversed;

  /// A head was clicked: sort by its column.
  final ValueChanged<HostSortMode>? onSort;

  @override
  ConsumerState<HostsTable> createState() => _HostsTableState();
}

class _HostsTableState extends ConsumerState<HostsTable> {
  /// Ctrl (Cmd) or Shift is held: a row answers a click on its release
  /// alone, so a selection click never also opens the host.
  bool _selectionKeyHeld = false;

  @override
  void initState() {
    super.initState();
    _selectionKeyHeld = hostSelectionKeyHeld();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent _) {
    final held = hostSelectionKeyHeld();
    if (held != _selectionKeyHeld && mounted) setState(() => _selectionKeyHeld = held);
    return false;
  }

  void _tap(HostRow row) {
    final order = [for (final r in widget.rows) r.data.id];
    if (hostSelectionClick(ref, row.data.id, order, panelHostId: widget.selectedHostId)) {
      widget.onSelectionGesture?.call();
      return;
    }
    widget.onSelect(row.connectionWithDetails);
  }

  String _nameOf(AppLocalizations l10n, HostsListColumn? c) => switch (c) {
        null => l10n.hostsListName,
        HostsListColumn.address => l10n.hostsListAddress,
        HostsListColumn.group => l10n.hostsListGroup,
        HostsListColumn.health => l10n.hostPanelHealth,
        HostsListColumn.status => l10n.hostsListStatus,
        HostsListColumn.lastUsed => l10n.hostsListLastUsed,
        HostsListColumn.tags => l10n.hostsListTags,
      };

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    final multi = ref.watch(hostMultiSelectProvider);
    final releaseOnly = multi.active || _selectionKeyHeld;
    final l10n = AppLocalizations.of(context)!;
    return LayoutBuilder(builder: (context, box) {
      // A narrow pane keeps the columns that say the most.
      final narrow = box.maxWidth < 620;
      final shown = [
        for (final c in HostsListColumn.values)
          if (widget.columns.contains(c) &&
              !(narrow && (c == HostsListColumn.group || c == HostsListColumn.lastUsed || c == HostsListColumn.tags)))
            c,
      ];
      return Container(
        key: const ValueKey('hosts-table'),
        decoration: BoxDecoration(
          color: ZestTokens.surfaceElevated,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: ZestTokens.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Container(
              // A finger's 48 where the controls are touch sized (each head
              // sorts: 4.0, the accessibility pass).
              height: touchSizedAt(context) ? 49 : 38,
              padding: const EdgeInsets.only(left: 14, right: 6),
              decoration: BoxDecoration(
                color: ZestTokens.surfaceRaisedAlt,
                border: Border(bottom: BorderSide(color: ZestTokens.borderSubtle)),
              ),
              child: Row(
                children: [
                  if (multi.active) const SizedBox(width: 28),
                  Expanded(flex: _kHost, child: _head(l10n, null)),
                  for (final c in shown) Expanded(flex: hostsColumnFlex(c), child: _head(l10n, c)),
                  SizedBox(
                    width: _endWidth(context),
                    child: widget.onColumnsChanged == null ? null : _ColumnPicker(
                      columns: widget.columns,
                      nameOf: (c) => _nameOf(l10n, c),
                      onChanged: widget.onColumnsChanged!,
                    ),
                  ),
                ],
              ),
            ),
            for (var i = 0; i < rows.length; i++)
              _Row(
                key: ValueKey('hosts-row-${rows[i].data.id}'),
                row: rows[i],
                columns: shown,
                last: i == rows.length - 1,
                selected: multi.active ? multi.isSelected(rows[i].data.id) : rows[i].data.id == widget.selectedHostId,
                checkbox: multi.active,
                onSelect: releaseOnly ? null : () => widget.onSelect(rows[i].connectionWithDetails),
                onConnect: releaseOnly ? null : () => widget.onConnect(rows[i].connectionWithDetails),
                onTap: releaseOnly ? () => _tap(rows[i]) : null,
                onMenu: (at) => widget.onMenu(at, rows[i]),
                // Its own screen (4.0): a screen host opens as any host does.
                onOpenScreen: multi.active ? null : widget.onConnect,
              ),
          ],
        ),
      );
    });
  }

  Widget _head(AppLocalizations l10n, HostsListColumn? c) {
    final sort = sortOfColumn(c);
    return _HeadCell(
      key: ValueKey('hosts-head-${c?.name ?? 'host'}'),
      label: _nameOf(l10n, c),
      active: sort != null && sort == widget.sortMode,
      reversed: widget.reversed,
      onTap: sort == null || widget.onSort == null ? null : () => widget.onSort!(sort),
    );
  }
}

/// A column's name in the head row: capitals, one line; where it sorts, an
/// arrow on the active one and a faint up-down mark on the others.
class _HeadCell extends StatefulWidget {
  const _HeadCell({super.key, required this.label, required this.active, required this.reversed, this.onTap});

  final String label;
  final bool active;
  final bool reversed;
  final VoidCallback? onTap;

  @override
  State<_HeadCell> createState() => _HeadCellState();
}

class _HeadCellState extends State<_HeadCell> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.onTap != null;
    final fg = widget.active || (_hover && on) ? ZestTokens.textPrimary : ZestTokens.textMuted;
    final text = Text(
      widget.label.toUpperCase(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontFamily: 'JetBrainsMono',
        fontSize: 10,
        fontWeight: widget.active ? FontWeight.w700 : FontWeight.w600,
        letterSpacing: 0.8,
        color: fg,
      ),
    );
    if (!on) return Align(alignment: AlignmentDirectional.centerStart, child: text);
    // The whole cell sorts, not its words alone.
    final sortBy = AppLocalizations.of(context)!.hostsListSortBy(widget.label);
    return Tooltip(
      message: sortBy,
      waitDuration: const Duration(milliseconds: 600),
      excludeFromSemantics: true,
      // Reached with Tab, said as "Sort by Host" and whether it is the sort
      // in use (its capitals were read letter by letter).
      child: ZestPressable(
            onTap: widget.onTap,
            onHover: (h) => setState(() => _hover = h),
            semanticLabel: sortBy,
            selected: widget.active,
            excludeChildSemantics: true,
            minSize: 0,
            borderRadius: 4,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: text),
                    const SizedBox(width: 5),
                    widget.active
                        ? Icon(widget.reversed ? LucideIcons.arrowUp : LucideIcons.arrowDown,
                            key: const ValueKey('hosts-head-arrow'), size: 12, color: ZestTokens.brandInk)
                        : Icon(LucideIcons.chevronsUpDown,
                            size: 11, color: _hover ? ZestTokens.textTertiary : ZestTokens.textPlaceholder),
                  ],
                ),
            ),
      ),
    );
  }
}

/// The head's column picker: a menu of the columns that can be hidden, each
/// ticked where it is shown; it stays open while columns are ticked.
class _ColumnPicker extends StatelessWidget {
  const _ColumnPicker({required this.columns, required this.nameOf, required this.onChanged});

  final Set<HostsListColumn> columns;
  final String Function(HostsListColumn) nameOf;
  final ValueChanged<Set<HostsListColumn>> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13);
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(ZestTokens.surfaceRaisedAlt),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: ZestTokens.borderStrong),
        )),
      ),
      alignmentOffset: const Offset(-180, 4),
      menuChildren: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Text(
            l10n.hostsListColumns.toUpperCase(),
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 10,
              letterSpacing: 1,
              fontWeight: FontWeight.w600,
              color: ZestTokens.textTertiary,
            ),
          ),
        ),
        for (final c in HostsListColumn.values)
          MenuItemButton(
            key: ValueKey('hosts-column-${c.name}'),
            closeOnActivate: false,
            leadingIcon: SizedBox(
              width: 16,
              child: columns.contains(c) ? Icon(LucideIcons.check, size: 14, color: ZestTokens.brandInk) : null,
            ),
            style: MenuItemButton.styleFrom(
              foregroundColor: ZestTokens.textPrimary,
              textStyle: text,
              minimumSize: const Size(200, 34),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            onPressed: () => onChanged(columns.contains(c) ? ({...columns}..remove(c)) : {...columns, c}),
            child: Text(nameOf(c)),
          ),
      ],
      builder: (context, controller, _) => Tooltip(
        message: l10n.hostsListColumns,
        waitDuration: const Duration(milliseconds: 500),
        excludeFromSemantics: true,
        child: ZestPressable(
              key: const ValueKey('hosts-columns'),
              onTap: () => controller.isOpen ? controller.close() : controller.open(),
              semanticLabel: l10n.hostsListColumns,
              expanded: controller.isOpen,
              excludeChildSemantics: true,
              minSize: 0,
              borderRadius: 6,
              child: SizedBox(
                width: _endWidth(context),
                height: touchSizedAt(context) ? 48 : 32,
                child: Icon(LucideIcons.columns, size: 15, color: ZestTokens.textTertiary),
              ),
        ),
      ),
    );
  }
}

class _Row extends ConsumerStatefulWidget {
  const _Row({
    super.key,
    required this.row,
    required this.columns,
    required this.last,
    required this.selected,
    required this.onSelect,
    required this.onConnect,
    required this.onMenu,
    this.onTap,
    this.checkbox = false,
    this.onOpenScreen,
  });

  final HostRow row;

  /// Opens one of the host's own screens: its monitor button after its name,
  /// and a screen reader's action (none while hosts are selected).
  final ValueChanged<ConnectionWithDetails>? onOpenScreen;
  final List<HostsListColumn> columns;
  final bool last;
  final bool selected;

  /// Selection mode: a box before the host, ticked where it is selected.
  final bool checkbox;

  /// On press (opens the panel), and on a double click (connects); null
  /// where a click is answered on release instead ([onTap]).
  final VoidCallback? onSelect;
  final VoidCallback? onConnect;
  final VoidCallback? onTap;
  final ValueChanged<Offset> onMenu;

  @override
  ConsumerState<_Row> createState() => _RowState();
}

class _RowState extends ConsumerState<_Row> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final d = widget.row.data;
    final label = AppColors.resolveConnectionLabelColorOrNull(
      connColorValue: d.colorValue,
      connColorIndex: d.colorIndex,
      inheritedGroupColor: d.groupColor,
    );
    final mono = TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, color: ZestTokens.textTertiary);
    Widget cell(HostsListColumn c) => switch (c) {
          HostsListColumn.address => Text(
              Redactable.freeText(d.subtitle).displayIn(ref),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono,
            ),
          HostsListColumn.group => _GroupCell(name: d.groupName, color: d.groupColor),
          HostsListColumn.health => Align(alignment: AlignmentDirectional.centerStart, child: HostHealthCell(health: d.health)),
          HostsListColumn.status => _StatusCell(status: d.status),
          HostsListColumn.lastUsed => Text(
              d.lastConnected == null ? l10n.hostsListNever : hostLastUsedWords(l10n, d.lastConnected!),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono.copyWith(color: ZestTokens.textSecondary),
            ),
          // As many tags as the column holds, on one line: the ones that
          // would not fit go below it, out of sight, and never over the next
          // column.
          HostsListColumn.tags => SizedBox(
              height: 20,
              child: Wrap(
                spacing: 4,
                runSpacing: 8,
                clipBehavior: Clip.hardEdge,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [for (final t in d.tags.take(3)) HostTagChip(tag: t)],
              ),
            ),
        };
    final touch = touchSizedAt(context);
    // The row to a screen reader, one sentence in the columns' order (it read
    // five fragments and said nothing of a muted metric).
    final health = HostHealthCell.spoken(d.health, l10n);
    final spoken = [
      Redactable.host(d.name).displayIn(ref),
      if (d.subtitle.isNotEmpty) Redactable.freeText(d.subtitle).displayIn(ref),
      d.groupName == null ? l10n.hostPanelUngrouped : Redactable.group(d.groupName!).displayIn(ref),
      ?health,
      d.status == HostStatus.online || d.status == HostStatus.connecting ? l10n.hostsListOpen : l10n.hostsListClosed,
      '${l10n.hostsListLastUsed}: ${d.lastConnected == null ? l10n.hostsListNever : hostLastUsedWords(l10n, d.lastConnected!)}',
      if (d.pinned) l10n.phoneHostsPinned,
      ...d.tags,
    ].join(', ');
    void menuAtRow() => widget.onMenu(globalCentreOf(context));
    final openScreen = widget.onOpenScreen;
    final screens = openScreen == null ? const <ConnectionWithDetails>[] : ref.watch(screensOfHostProvider(d.id));
    // Reached with Tab, opened with Enter (a computer's press opens the
    // panel), its menu under Shift+F10, the menu key and a reader's action.
    return ZestPressable(
        onTapDown: widget.onSelect,
        onDoubleTap: widget.onConnect,
        onTap: widget.onTap,
        onHover: (h) => setState(() => _hover = h),
        onSecondaryTapUp: (e) => widget.onMenu(e.globalPosition),
        // The right click's menu under a long press too where the controls are
        // touch sized (a tablet, 4.0): a finger has no right button.
        onLongPress: touch ? menuAtRow : null,
        onContextMenu: menuAtRow,
        semanticActions: {
          if (widget.onConnect != null) CustomSemanticsAction(label: l10n.commonConnect): widget.onConnect!,
          CustomSemanticsAction(label: l10n.hostsListHostMenu): menuAtRow,
          if (screens.isNotEmpty)
            CustomSemanticsAction(label: hostScreenButtonLabel(l10n, ref, screens)): () =>
                pickHostScreen(context, ref, screens, openScreen!, at: globalCentreOf(context)),
        },
        semanticLabel: spoken,
        checked: widget.checkbox ? widget.selected : null,
        selected: !widget.checkbox && widget.selected,
        excludeChildSemantics: true,
        minSize: 0,
        borderRadius: 0,
        child: Container(
          // Grows with the text where the system's text is larger (it was 44
          // high whatever the size); a finger's 48 on a touch screen.
          constraints: BoxConstraints(minHeight: touch ? 48 : 44),
          padding: const EdgeInsets.only(right: 6),
          decoration: BoxDecoration(
            color: widget.selected
                ? Color.alphaBlend(ZestTokens.brand.withValues(alpha: 0.07), ZestTokens.surfaceElevated)
                : (_hover ? ZestTokens.surfaceRaisedAlt : Colors.transparent),
            border: widget.last ? null : Border(bottom: BorderSide(color: ZestTokens.borderSubtle)),
          ),
          child: Row(
            children: [
              // The host's colour (its own, or its group's), as its card's
              // stripe, as tall as the row.
              Container(width: 3, constraints: BoxConstraints(minHeight: touch ? 48 : 44), color: label ?? Colors.transparent),
              const SizedBox(width: 11),
              if (widget.checkbox) ...[
                HostSelectBox(checked: widget.selected, size: 18),
                const SizedBox(width: 10),
              ],
              Expanded(
                flex: _kHost,
                child: Row(
                  children: [
                    HostIcon(
                      iconId: d.iconId,
                      customIcon: d.customIcon,
                      osId: d.osId,
                      iconColor: d.iconColor,
                      labelColor: label,
                      size: 26,
                      cornerRadius: 7,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: RedactedText(
                        Redactable.host(d.name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: ZestTokens.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (d.pinned) ...[
                      const SizedBox(width: 6),
                      Icon(LucideIcons.pin, size: 11, color: ZestTokens.brandInk),
                    ],
                    if (d.tmuxSessions > 0) ...[
                      const SizedBox(width: 6),
                      TmuxSessionsBadge(count: d.tmuxSessions, compact: true),
                    ],
                    // Its own screen, one press away (4.0).
                    if (screens.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      HostScreenButton(hostId: d.id, onOpen: openScreen!, size: touch ? 44 : 26, iconSize: 14),
                    ],
                    const SizedBox(width: 8),
                  ],
                ),
              ),
              for (final c in widget.columns)
                Expanded(
                  flex: hostsColumnFlex(c),
                  child: Padding(padding: const EdgeInsetsDirectional.only(end: 8), child: cell(c)),
                ),
              SizedBox(
                width: _endWidth(context),
                child: _RowMenuButton(
                  key: ValueKey('host-row-menu-${d.id}'),
                  shown: _hover || widget.selected,
                  onMenu: widget.onMenu,
                ),
              ),
            ],
          ),
        ),
    );
  }
}

/// A row's ⋯: the host's menu, as a right click opens it, below the button.
/// Quiet until the row is under the pointer or selected.
class _RowMenuButton extends StatelessWidget {
  const _RowMenuButton({super.key, required this.shown, required this.onMenu});

  final bool shown;
  final ValueChanged<Offset> onMenu;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // A pointer's 32 high (it was 30); the row's own button to a screen
    // reader holds its More actions. Quiet, but at 3:1 or more, until the
    // row is under the pointer (it was the turned-off grey).
    return Tooltip(
      message: l10n.hostsListHostMenu,
      waitDuration: const Duration(milliseconds: 500),
      child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (e) {
              final box = context.findRenderObject();
              onMenu(box is RenderBox ? box.localToGlobal(box.size.bottomLeft(Offset.zero)) : e.globalPosition);
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: SizedBox(
                width: _endWidth(context),
                height: touchSizedAt(context) ? 48 : 32,
                child: Icon(
                  LucideIcons.moreHorizontal,
                  size: 16,
                  color: shown ? ZestTokens.textSecondary : ZestTokens.textTertiary,
                ),
              ),
            ),
      ),
    );
  }
}

/// The group cell: the group's colour as a dot and its name; "Ungrouped",
/// muted, for a host in none.
class _GroupCell extends StatelessWidget {
  const _GroupCell({required this.name, required this.color});

  final String? name;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (name == null) {
      return Text(
        AppLocalizations.of(context)!.hostPanelUngrouped,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        // Quiet, at 4.5:1 (the turned-off grey was under 3:1).
        style: TextStyle(color: ZestTokens.textTertiary, fontSize: 12.5),
      );
    }
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color ?? ZestTokens.textTertiary, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: RedactedText(
            Redactable.group(name!),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: ZestTokens.textSecondary, fontSize: 12.5),
          ),
        ),
      ],
    );
  }
}

/// Whether the host is connected: a green dot and "Connected" (a session up
/// or coming up), else "Not connected", quiet.
class _StatusCell extends StatelessWidget {
  const _StatusCell({required this.status});

  final HostStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final open = status == HostStatus.online || status == HostStatus.connecting;
    if (!open) {
      return Text(
        l10n.hostsListClosed,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: ZestTokens.textTertiary, fontSize: 12.5),
      );
    }
    final green = ZestTokens.statusHealthy;
    // On a light page the green words read at about 3:1 on white: a third of
    // the way to the text colour there.
    final ink = Theme.of(context).brightness == Brightness.light ? Color.lerp(green, ZestTokens.textPrimary, 0.35)! : green;
    return Row(
      children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(color: green, shape: BoxShape.circle)),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            l10n.hostsListOpen,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: ink, fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }
}

/// A host's health in the list ([HostHealthSummary]): a warning or a
/// critical as the amber or red chip its card shows; a metric over its line
/// whose alerts the person muted or snoozed, quiet, after a bell struck
/// through; else its reading nearest a line, as plain text; nothing for a
/// host Server Monitor does not watch.
class HostHealthCell extends StatelessWidget {
  const HostHealthCell({super.key, required this.health});

  final HostHealthSummary health;

  /// What the cell says, in words for a screen reader (null for nothing).
  static String? spoken(HostHealthSummary h, AppLocalizations l10n) {
    String reading() => '${monitorMetricLabel(h.metric!, l10n)} ${monitorMetricValue(h.metric!, h.value!)}';
    return switch (h.kind) {
      HostHealthKind.none => null,
      HostHealthKind.warning || HostHealthKind.critical => h.chip?.tooltip,
      HostHealthKind.muted => '${reading()}, ${l10n.hostsListHealthMutedTip(monitorMetricLabel(h.metric!, l10n))}',
      HostHealthKind.plain => reading(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final h = health;
    String reading() => '${monitorMetricLabel(h.metric!, l10n)} ${monitorMetricValue(h.metric!, h.value!)}';
    final mono = TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, color: ZestTokens.textSecondary);
    switch (h.kind) {
      case HostHealthKind.none:
        return const SizedBox.shrink();
      case HostHealthKind.warning:
      case HostHealthKind.critical:
        final chip = h.chip;
        if (chip == null) return const SizedBox.shrink();
        return HostHealthChipView(chip: chip);
      case HostHealthKind.muted:
        return Tooltip(
          message: l10n.hostsListHealthMutedTip(monitorMetricLabel(h.metric!, l10n)),
          child: Row(
            key: const ValueKey('hosts-health-muted'),
            mainAxisSize: MainAxisSize.min,
            children: [
              // Quiet beside a plain reading, at 4.5:1; the struck bell says
              // it is muted, not the grey alone.
              Icon(LucideIcons.bellOff, size: 12, color: ZestTokens.textTertiary),
              const SizedBox(width: 5),
              Flexible(
                child: Text(reading(),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: mono.copyWith(color: ZestTokens.textTertiary)),
              ),
            ],
          ),
        );
      case HostHealthKind.plain:
        return Text(reading(), maxLines: 1, overflow: TextOverflow.ellipsis, style: mono);
    }
  }
}
