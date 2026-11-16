import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import '../../../core/theme/zest_colors.dart';
import '../../groups/models/group.dart';
import 'dart:math' as math;

class GroupFilterChips extends ConsumerWidget {
  const GroupFilterChips({
    super.key,
    required this.groups,
    required this.totalHostCount,
    required this.ungroupedHostCount,
    required this.selectedGroupId,
    required this.onSelect,
    required this.onCreateGroup,
    this.onEditGroup,
    this.onDropOnGroup,
  });
  final List<HostGroup> groups;
  final int totalHostCount;

  /// How many hosts belong to no group. Drives the trailing "Ungrouped N"
  /// filter chip (which replaced the old duplicate Groups-cards section).
  final int ungroupedHostCount;
  final String? selectedGroupId;
  final ValueChanged<String?> onSelect;

  /// Fired by the trailing "+ New group" chip. The page routes this to the
  /// shared group editor (`GroupEditorPanel.showAdaptive`).
  final VoidCallback onCreateGroup;

  /// Fired when a REAL group chip is right-clicked (or its hover pencil is
  /// tapped) with the group's id. The page routes this to the shared group
  /// editor (`GroupEditorPanel.showAdaptive(groupId: id)`). The special
  /// "All" / "Ungrouped" / "New group" chips never fire it. Null disables the
  /// affordance entirely.
  final void Function(String groupId)? onEditGroup;

  /// Sentinel [selectedGroupId] value meaning "show only ungrouped hosts". A
  /// real group id can never collide with it, so the page's filter switches on
  /// this to filter `groupId == null`.
  static const String ungroupedFilterId = '__zest_ungrouped__';

  /// Called when a host card is dropped onto a chip. The first arg is
  /// the target group's id (null for the "All" / "Ungrouped" chips - which
  /// mean "ungroup the host"). The second is the dragged connection.
  ///
  /// When null, chips don't accept drops at all (chips are read-only).
  final void Function(String? groupId, ConnectionWithDetails item)?
      onDropOnGroup;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return SizedBox(
      // As tall as a chip's line of words with its room around them (26 left
      // the words 15 of the 16 they need), and taller as the text grows.
      height: math.max(26, _chipLineHeight(context) + 11),
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _Chip(
            label: l10n.zestHostsAll,
            count: totalHostCount,
            selected: selectedGroupId == null,
            onTap: () => onSelect(null),
            // Drop on "All" → ungrouped (clearGroupId).
            onAccept: onDropOnGroup == null
                ? null
                : (item) => onDropOnGroup!(null, item),
          ),
          const SizedBox(width: 8),
          ...groups.expand((g) => [
                _Chip(
                  dotColor: g.accentColor,
                  // Painted only; selection and drops still use g.id.
                  label: Redactable.group(g.name).displayIn(ref),
                  count: g.hostCount,
                  selected: selectedGroupId == g.id,
                  onTap: () => onSelect(g.id),
                  onSecondaryTap:
                      onEditGroup == null ? null : () => onEditGroup!(g.id),
                  onAccept: onDropOnGroup == null
                      ? null
                      : (item) => onDropOnGroup!(g.id, item),
                ),
                const SizedBox(width: 8),
              ]),
          // Ungrouped filter chip - replaces the old duplicate Groups-cards
          // section. Selecting it filters to hosts with no group; dropping a
          // host on it ungroups the host.
          _Chip(
            label: l10n.hostPanelUngrouped,
            count: ungroupedHostCount,
            selected: selectedGroupId == ungroupedFilterId,
            onTap: () => onSelect(ungroupedFilterId),
            onAccept: onDropOnGroup == null
                ? null
                : (item) => onDropOnGroup!(null, item),
          ),
          const SizedBox(width: 8),
          _Chip(
            icon: LucideIcons.plus,
            label: l10n.zestHostsNewGroup,
            selected: false,
            muted: true,
            onTap: onCreateGroup,
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatefulWidget {
  const _Chip({
    this.dotColor,
    this.icon,
    required this.label,
    this.count,
    required this.selected,
    this.muted = false,
    required this.onTap,
    this.onSecondaryTap,
    this.onAccept,
  });
  final Color? dotColor;
  final IconData? icon;
  final String label;

  /// Optional trailing host count, rendered in a dimmer weight after the label
  /// (e.g. "Nodes 3"). Null on the "+ New group" chip.
  final int? count;
  final bool selected;
  final bool muted;
  final VoidCallback onTap;

  /// Right-click handler. When non-null the chip is "editable": right-clicking
  /// fires it and a subtle pencil appears on hover (also firing it on tap).
  /// Null on the special "All" / "Ungrouped" / "New group" chips.
  final VoidCallback? onSecondaryTap;

  /// When non-null, the chip becomes a [DragTarget] for
  /// [ConnectionWithDetails] drags. Receiving the drop calls this
  /// callback with the dragged item.
  final ValueChanged<ConnectionWithDetails>? onAccept;

  @override
  State<_Chip> createState() => _ChipState();
}

class _ChipState extends State<_Chip> {
  bool _isHover = false;
  bool _pointerHover = false;

  @override
  Widget build(BuildContext context) {
    final Widget chip;
    if (widget.onAccept == null) {
      chip = _buildChip(context, isDropTarget: false);
    } else {
      chip = DragTarget<ConnectionWithDetails>(
        onWillAcceptWithDetails: (_) {
          setState(() => _isHover = true);
          return true;
        },
        onLeave: (_) => setState(() => _isHover = false),
        onAcceptWithDetails: (details) {
          setState(() => _isHover = false);
          widget.onAccept!(details.data);
        },
        builder: (_, _, _) => _buildChip(context, isDropTarget: _isHover),
      );
    }
    // Editable chips track a plain mouse hover so the pencil affordance can
    // reveal. Non-editable chips skip the MouseRegion entirely.
    if (widget.onSecondaryTap == null) return chip;
    return MouseRegion(
      onEnter: (_) => setState(() => _pointerHover = true),
      onExit: (_) => setState(() => _pointerHover = false),
      child: chip,
    );
  }

  Widget _buildChip(BuildContext context, {required bool isDropTarget}) {
    final bg = isDropTarget
        ? ZestColors.accentPrimary.withValues(alpha: 0.18)
        : (widget.selected ? ZestColors.textPrimary : ZestColors.bgSurface);
    final fg = isDropTarget
        ? ZestColors.accentInk
        : (widget.selected
            ? ZestColors.bgContent
            : (widget.muted
                ? ZestColors.textTertiary
                : ZestColors.textPrimary));
    final border = isDropTarget
        ? Border.all(
            color: ZestColors.accentPrimary.withValues(alpha: 0.65),
            width: 1,
          )
        : (widget.selected
            ? null
            : Border.all(color: ZestColors.borderDefault, width: 0.5));

    // Reveal a subtle pencil on hover for editable chips (right-click also
    // edits). Suppressed while a drop is hovering so it never fights the
    // drag-to-group highlight.
    final bool showPencil =
        widget.onSecondaryTap != null && _pointerHover && !isDropTarget;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: widget.onTap,
        onSecondaryTap: widget.onSecondaryTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(13),
            border: border,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.dotColor != null) ...[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: widget.dotColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 12, color: fg),
                const SizedBox(width: 4),
              ],
              Text(
                widget.label,
                style: TextStyle(
                  color: fg,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (widget.count != null) ...[
                const SizedBox(width: 6),
                Text(
                  '${widget.count}',
                  style: TextStyle(
                    // Dim the count relative to the label - unless the chip is
                    // selected, where the whole label already inverts.
                    color: isDropTarget || widget.selected
                        ? fg
                        : ZestColors.textTertiary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (showPencil) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onSecondaryTap,
                  child: Tooltip(
                    message: AppLocalizations.of(context)!.zestGroupEdit,
                    child: Icon(
                      LucideIcons.pencil,
                      size: 11,
                      color: fg.withValues(alpha: 0.75),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The height of a chip's line of words (11 high), at the text size the app
/// is drawn at.
double _chipLineHeight(BuildContext context) {
  final painter = TextPainter(
    text: TextSpan(
      text: 'Hg',
      style: DefaultTextStyle.of(context).style.merge(const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  final height = painter.height;
  painter.dispose();
  return height;
}
