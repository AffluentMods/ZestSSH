import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/widgets/os_icon.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/dashed_rounded_border.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:zestssh/ui/widgets/zest_pressable.dart';

/// One kind of host in a group, drawn small on its tile: the icon its hosts
/// show.
class GroupKind {
  const GroupKind({this.iconId, this.customIcon, this.osId, this.iconColor});
  final String? iconId;
  final String? customIcon;
  final String? osId;
  final int? iconColor;
}

/// Whether a host is being dragged on the Hosts page now (its card's drag):
/// the hint to drop it on a group shows only then.
final hostDragActive = ValueNotifier<bool>(false);

/// What a group's tile shows.
class GroupTileData {
  const GroupTileData({
    required this.id,
    required this.name,
    required this.color,
    required this.icon,
    required this.hostCount,
    required this.openCount,
    this.kinds = const [],
  });

  /// Null for the hosts in no group.
  final String? id;
  final String name;
  final Color color;
  final IconData icon;
  final int hostCount;
  final int openCount;

  /// Up to four kinds of host it holds.
  final List<GroupKind> kinds;
}

/// The Groups section of the Hosts page (3.0):
/// each group a tile like a host's card, with its own icon and colour, how
/// many hosts it holds and the kinds of host in it. How many of a group's
/// hosts need attention is not on it (a second
/// number in colour beside the count confused more than it told; the
/// toolbar's "need attention" button finds them). A click shows only its hosts (again: all); a host dropped on a
/// tile moves into that group. The hosts in no group have a tile of
/// their own, and New group is the last.
class GroupTiles extends ConsumerWidget {
  const GroupTiles({
    super.key,
    required this.groups,
    required this.ungrouped,
    required this.columns,
    required this.itemWidth,
    required this.selectedId,
    required this.onSelect,
    required this.onMenu,
    required this.onDrop,
    this.onNewGroup,
    this.limit,
    this.carriedWith,
  });

  /// The hosts a drag of [host] carries (the selection it is one of), where
  /// a drag can carry several: a tile takes them when any of them is not in
  /// its group yet, and says how many it moves. Null: the host alone.
  final List<ConnectionWithDetails> Function(ConnectionWithDetails host)? carriedWith;

  final List<GroupTileData> groups;

  /// The hosts in no group (none: no tile).
  final GroupTileData? ungrouped;
  final int columns;
  final double itemWidth;

  /// The group shown alone ([ungroupedId] for the hosts in none).
  final String? selectedId;
  final ValueChanged<String?> onSelect;

  /// The tile's menu (a group's own, never the hosts in none): where to open.
  final void Function(String groupId, Offset at) onMenu;

  /// A host dropped on a tile ([groupId] null: out of its group).
  final void Function(String? groupId, ConnectionWithDetails host) onDrop;

  /// New group (null: this space adds none).
  final VoidCallback? onNewGroup;

  /// Show only this many tiles (the section folded).
  final int? limit;

  /// The id that stands for the hosts in no group.
  static const ungroupedId = '__ungrouped__';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final named = <Widget>[
      for (final g in groups)
        _GroupTile(
          key: ValueKey('group-tile-${g.id}'),
          data: g,
          selected: selectedId == g.id,
          onTap: () => onSelect(selectedId == g.id ? null : g.id),
          onMenu: (at) => onMenu(g.id!, at),
          onDrop: (host) => onDrop(g.id, host),
          dropTip: (host, count) =>
              count > 1 ? l10n.hostsSelDropTipMany(count, g.name) : l10n.hostsGroupDropTip(host, g.name),
          carriedWith: carriedWith,
        ),
    ];
    // Ungrouped and New group end the row, folded or not.
    final trailing = <Widget>[
      if (ungrouped != null)
        _GroupTile(
          key: const ValueKey('group-tile-ungrouped'),
          data: ungrouped!,
          muted: true,
          selected: selectedId == ungroupedId,
          onTap: () => onSelect(selectedId == ungroupedId ? null : ungroupedId),
          onDrop: (host) => onDrop(null, host),
          dropTip: (host, count) => count > 1 ? l10n.hostsSelUngroupTipMany(count) : l10n.hostsGroupUngroupTip(host),
          carriedWith: carriedWith,
        ),
      if (onNewGroup != null) _NewGroupTile(onTap: onNewGroup!),
    ];
    final all = [...named, ...trailing];
    final shown = limit == null || all.length <= limit!
        ? all
        : [...named.take((limit! - trailing.length).clamp(0, named.length)), ...trailing];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final t in shown) SizedBox(width: itemWidth, child: t),
      ],
    );
  }
}

class _GroupTile extends ConsumerStatefulWidget {
  const _GroupTile({
    super.key,
    required this.data,
    required this.selected,
    required this.onTap,
    required this.onDrop,
    required this.dropTip,
    this.onMenu,
    this.muted = false,
    this.carriedWith,
  });

  final List<ConnectionWithDetails> Function(ConnectionWithDetails host)? carriedWith;

  final GroupTileData data;
  final bool selected;
  final bool muted;
  final VoidCallback onTap;
  final ValueChanged<Offset>? onMenu;
  final ValueChanged<ConnectionWithDetails> onDrop;
  /// What the tile says while hosts are held over it: [host] by name, or
  /// [count] of them.
  final String Function(String host, int count) dropTip;

  @override
  ConsumerState<_GroupTile> createState() => _GroupTileState();
}

class _GroupTileState extends ConsumerState<_GroupTile> {
  bool _hover = false;

  /// The keyboard is on the tile: its menu's button shows, as under a
  /// pointer.
  bool _focus = false;

  /// The host held over the tile, while one is.
  String? _over;

  /// How many hosts are held over the tile with it.
  int _overCount = 1;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final d = widget.data;
    final color = widget.muted ? ZestTokens.textTertiary : OsIcon.seen(d.color);
    return DragTarget<ConnectionWithDetails>(
      onWillAcceptWithDetails: (details) {
        // Into its own group is no move.
        final into = d.id;
        final carried = widget.carriedWith?.call(details.data) ?? [details.data];
        if (carried.every((c) => c.connection.groupId == into)) return false;
        final label = details.data.connection.label;
        setState(() {
          _over = Redactable.host(label.isNotEmpty ? label : details.data.connection.host).displayIn(ref);
          _overCount = carried.length;
        });
        return true;
      },
      onLeave: (_) => setState(() => _over = null),
      onAcceptWithDetails: (details) {
        setState(() => _over = null);
        widget.onDrop(details.data);
      },
      builder: (context, _, _) {
        final dropping = _over != null;
        final border = dropping
            ? ZestTokens.brand
            : widget.selected
                ? ZestTokens.brand
                : (_hover ? ZestTokens.borderStrong : ZestTokens.border);
        final fill = dropping
            ? Color.alphaBlend(ZestTokens.brand.withValues(alpha: 0.07), ZestTokens.surfaceElevated)
            : widget.selected
                ? Color.alphaBlend(ZestTokens.brand.withValues(alpha: 0.06), ZestTokens.surfaceElevated)
                : widget.muted
                    ? Colors.transparent
                    : (_hover ? ZestTokens.surfaceRaisedAlt : ZestTokens.surfaceElevated);
        final tile = AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(10),
            // Ungrouped too has a solid edge: only New group, which is no
            // group yet, is dashed.
            border: Border.all(color: border, width: dropping ? 1.5 : 1),
            boxShadow: dropping ? [BoxShadow(color: ZestTokens.brand.withValues(alpha: 0.10), spreadRadius: 3)] : null,
          ),
          // One line: the folder, the name, how many.
          child: Row(
            children: [
              // A neutral tile with the group's colour as a dot at its
              // corner (the tiles in their own colours made a rainbow row).
              SizedBox(
                width: 30,
                height: 30,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: ZestTokens.surfaceChip,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: ZestTokens.borderSubtle),
                      ),
                      child: Icon(d.icon, size: 15, color: ZestTokens.textSecondary),
                    ),
                    if (!widget.muted)
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: Container(
                          key: ValueKey('group-tile-colour-${d.id}'),
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(color: fill == Colors.transparent ? ZestTokens.surfaceBase : fill, width: 2),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: widget.muted
                    ? Text(d.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: ZestTokens.textSecondary, fontSize: 13, fontWeight: FontWeight.w600))
                    : RedactedText(
                        Redactable.group(d.name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: ZestTokens.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                      ),
              ),
              const SizedBox(width: 8),
              // The menu's button takes the count's place while the pointer
              // is over the tile.
              AnimatedOpacity(
                duration: const Duration(milliseconds: 100),
                opacity: (_hover || _focus) && widget.onMenu != null ? 0 : 1,
                child: Tooltip(
                  message: l10n.hostsMetaHostCount(d.hostCount),
                  child: Text('${d.hostCount}',
                      style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, color: ZestTokens.textTertiary)),
                ),
              ),
            ],
          ),
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // One button to a screen reader ("Web, 2 hosts", picked or not),
            // reached with Tab, its menu under Shift+F10 or the menu key and
            // a reader's action (4.0, the accessibility pass: it was a bare
            // tap, its menu only under a pointer).
            ZestPressable(
                onTap: widget.onTap,
                onHover: (h) => setState(() => _hover = h),
                onFocusChange: (f) => setState(() => _focus = f),
                onSecondaryTapUp: widget.onMenu == null ? null : (e) => widget.onMenu!(e.globalPosition),
                // The right click's menu under a long press too where the controls are
                // touch sized (a tablet, 4.0): a finger has no right button.
                onLongPress: widget.onMenu == null || !touchSizedAt(context)
                    ? null
                    : () => widget.onMenu!(globalCentreOf(context)),
                onContextMenu: widget.onMenu == null ? null : () => widget.onMenu!(globalCentreOf(context)),
                semanticActions: {
                  if (widget.onMenu != null)
                    CustomSemanticsAction(label: l10n.hostsGroupMenu): () => widget.onMenu!(globalCentreOf(context)),
                },
                semanticLabel:
                    '${widget.muted ? d.name : Redactable.group(d.name).displayIn(ref)}, ${l10n.hostsMetaHostCount(d.hostCount)}',
                selected: widget.selected,
                excludeChildSemantics: true,
                minSize: 0,
                borderRadius: 10,
                child: Stack(
                  children: [
                    tile,
                    if (widget.onMenu != null)
                      Positioned(
                        top: 0,
                        bottom: 0,
                        right: 6,
                        child: Center(child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 100),
                          opacity: _hover || _focus ? 1 : 0,
                          child: Tooltip(
                          message: l10n.hostsGroupMenu,
                          waitDuration: const Duration(milliseconds: 500),
                          child: GestureDetector(
                            key: ValueKey('group-tile-menu-${d.id}'),
                            onTapUp: (e) => widget.onMenu!(e.globalPosition),
                            child: Padding(
                              padding: const EdgeInsets.all(2),
                              child: Icon(LucideIcons.moreHorizontal, size: 15, color: ZestTokens.textSecondary),
                            ),
                          ),
                        ))),
                      ),
                  ],
                ),
            ),
            if (dropping)
              Padding(
                padding: const EdgeInsets.only(left: 12, top: 6),
                child: Text(
                  widget.dropTip(_over!, _overCount),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: ZestTokens.brandInk, fontSize: 11.5, fontWeight: FontWeight.w600),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _NewGroupTile extends StatefulWidget {
  const _NewGroupTile({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_NewGroupTile> createState() => _NewGroupTileState();
}

class _NewGroupTileState extends State<_NewGroupTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final fg = _hover ? ZestTokens.textPrimary : ZestTokens.textTertiary;
    return ZestPressable(
        key: const ValueKey('group-tile-new'),
        onTap: widget.onTap,
        onHover: (h) => setState(() => _hover = h),
        minSize: 0,
        borderRadius: 10,
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            color: _hover ? ZestTokens.surfaceElevated : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          foregroundDecoration: DashedRoundedBorder(
              color: _hover ? ZestTokens.brand : ZestTokens.borderStrong, radius: 10, dash: 5, gap: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(LucideIcons.plus, size: 14, color: fg),
              const SizedBox(width: 8),
              Text(AppLocalizations.of(context)!.hostsNewMenuGroup, style: TextStyle(color: fg, fontSize: 12.5)),
            ],
          ),
        ),
    );
  }
}
