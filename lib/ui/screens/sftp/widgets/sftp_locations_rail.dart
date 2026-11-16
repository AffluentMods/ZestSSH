import 'package:flutter/material.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/hit_area.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart' show ZestPressable;
import 'package:zestssh/services/profiles/profile_preferences.dart';

void _noop() {}

/// One clickable location in the rail.
class RailItem {
  const RailItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.id,
    this.reorderable = false,
    this.trailing,
    this.pathHint,
    this.selected = false,
    this.stale = false,
    this.onSecondaryTap,
    this.isDivider = false,
  })  : isSection = false,
        note = null;

  /// A hairline separating removable pins from the fixed drives / filesystem
  /// roots below them.
  const RailItem.divider()
      : icon = LucideIcons.minus,
        label = '',
        onTap = _noop,
        id = null,
        reorderable = false,
        trailing = null,
        pathHint = null,
        selected = false,
        stale = false,
        onSecondaryTap = null,
        isDivider = true,
        isSection = false,
        note = null;

  /// A small caption over a group of rows of their own (a team host's shared
  /// bookmarks, 4.0), with [note] on hover where there is one. Like a
  /// divider, it ends the reorderable pins above it.
  const RailItem.section({required this.label, this.note})
      : icon = LucideIcons.users,
        onTap = _noop,
        id = null,
        reorderable = false,
        trailing = null,
        pathHint = null,
        selected = false,
        stale = false,
        onSecondaryTap = null,
        isDivider = false,
        isSection = true;

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Stable identity for drag-reorder (the pin path). Null for non-reorderable
  /// rows (drives, roots, divider).
  final String? id;

  /// Whether this row can be drag-reordered (pins yes, drives/roots no).
  final bool reorderable;

  /// Optional right-aligned mono text (e.g. free space).
  final String? trailing;

  /// Optional path, shown small under the label and ellipsized from the LEFT so
  /// the identifying end survives (`…www/html`, not `/var/www…`).
  final String? pathHint;

  /// Whether this location is the one currently shown by its pane.
  final bool selected;

  /// A pin whose path no longer resolves - dimmed with a warn glyph, never
  /// dropped. Clicking still fires [onTap] (offer repoint/remove).
  final bool stale;

  /// Right-click / long-press action (pin context menu: rename / remove). The
  /// pointer's global position is passed so the menu can anchor at the cursor.
  /// Returns a future that completes when the menu closes, so the row can hold
  /// its "targeted" highlight for exactly that span.
  final Future<void> Function(Offset globalPosition)? onSecondaryTap;

  /// When true this "item" is a hairline separating pins from fixed roots.
  final bool isDivider;

  /// When true this "item" is a caption over the rows after it
  /// ([RailItem.section]).
  final bool isSection;

  /// A caption's words on hover, or none.
  final String? note;
}

/// A labelled group of locations. Its HEADER doubles as the source picker for
/// the pane it drives: a two-square glyph shows which pane
/// (left/right) it controls, and tapping it opens the source picker.
class RailGroup {
  const RailGroup({
    required this.label,
    required this.items,
    this.paneSide,
    this.sourceIcon,
    this.sourceIconColor,
    this.dotColor,
    this.latencyLabel,
    this.onHeaderTap,
    this.onHeaderHover,
    this.onEmptyAreaMenu,
    this.onReorderPins,
  });

  final String label;
  final List<RailItem> items;

  /// Which pane this group drives: 0 = left, 1 = right. Null → a plain,
  /// non-picker group header (no two-square glyph, not tappable).
  final int? paneSide;

  final IconData? sourceIcon;
  final Color? sourceIconColor;

  /// Reachability dot colour for a remote source (stands in for the icon).
  final Color? dotColor;

  /// Latency label for a remote source, e.g. "12 ms".
  final String? latencyLabel;

  /// Opens the source picker for this pane. Receives the header's global
  /// bottom-left so the popover can anchor under it.
  final void Function(Offset anchor)? onHeaderTap;

  /// Hover in/out - used to outline the pane this group drives.
  final void Function(bool hovering)? onHeaderHover;

  /// Right-click / long-press on the empty rail area under this group's pins,
  /// anchored at the cursor. Opens "Add bookmark" / "Restore defaults". Null →
  /// no menu.
  final void Function(Offset globalPos)? onEmptyAreaMenu;

  /// Drag-reorder of this group's pins: (oldIndex, newIndex) into the pin list.
  /// Null → pins are not reorderable.
  final void Function(int oldIndex, int newIndex)? onReorderPins;
}

/// The left rail: a source-picker header per pane, plus that pane's quick-jump
/// locations. Purely presentational - the screen
/// supplies the groups + navigation callbacks.
class SftpLocationsRail extends StatefulWidget {
  const SftpLocationsRail({super.key, required this.groups, this.onCollapse});

  final List<RailGroup> groups;

  /// Collapse the rail to a thin strip. Null → no toggle.
  final VoidCallback? onCollapse;

  @override
  State<SftpLocationsRail> createState() => _SftpLocationsRailState();
}

class _SftpLocationsRailState extends State<SftpLocationsRail> {
  static const String _prefsKey = 'sftp_rail_split';
  // Keep at least ~2 rows in each region so neither can be crushed to nothing.
  static const double _minRatio = 0.16;

  double _ratio = 0.5;

  @override
  void initState() {
    super.initState();
    appPreferences().then((p) {
      final v = p.getDouble(_prefsKey);
      if (v != null && mounted) {
        setState(() => _ratio = v.clamp(_minRatio, 1 - _minRatio));
      }
    });
  }

  void _saveRatio() {
    appPreferences().then((p) => p.setDouble(_prefsKey, _ratio));
  }

  @override
  Widget build(BuildContext context) {
    final groups = widget.groups;
    return Container(
      width: 186,
      decoration: BoxDecoration(
        // Rail is --panel, same canvas as the panes; only the
        // right hairline separates them.
        color: AppColors.sftpPanel,
        border: Border(right: BorderSide(color: AppColors.divider, width: 1)),
      ),
      child: Column(
        children: [
          if (widget.onCollapse != null)
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: AppLocalizations.of(context)!.desktopCollapseSidebar,
                icon: const Icon(LucideIcons.chevronsLeft, size: 15),
                color: AppColors.textSecondary,
                visualDensity: VisualDensity.compact,
                onPressed: widget.onCollapse,
              ),
            ),
          // Two independently-scrolling regions with a draggable divider so a
          // host with twenty pins can't push the other source off the bottom.
          // Headers stay pinned; the split persists. One group
          // (rare) falls back to a single scroll region.
          if (groups.length == 2)
            Expanded(
              child: LayoutBuilder(builder: (context, c) {
                final h = c.maxHeight;
                return Column(
                  children: [
                    Expanded(
                      flex: (_ratio * 1000).round(),
                      child: _RailRegion(group: groups[0]),
                    ),
                    _RailDivider(
                      onDrag: (dy) => setState(() => _ratio =
                          (_ratio + (h > 0 ? dy / h : 0))
                              .clamp(_minRatio, 1 - _minRatio)),
                      onDragEnd: _saveRatio,
                      onReset: () {
                        setState(() => _ratio = 0.5);
                        _saveRatio();
                      },
                    ),
                    Expanded(
                      flex: ((1 - _ratio) * 1000).round(),
                      child: _RailRegion(group: groups[1]),
                    ),
                  ],
                );
              }),
            )
          else
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  for (final group in groups) ...[
                    _RailHeader(group: group),
                    for (final item in group.items) _railChild(item),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// One rail child: a 1px hairline for a divider item (the pins/roots separator),
/// a caption for a section, else the location row.
Widget _railChild(RailItem item) {
  if (item.isDivider) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      child: Divider(height: 1, thickness: 1, color: AppColors.divider),
    );
  }
  if (item.isSection) return _RailSection(item: item);
  return _RailRow(item: item);
}

/// A section's caption: a small icon and words, a heading to a screen reader,
/// with its note on hover.
class _RailSection extends StatelessWidget {
  const _RailSection({required this.item});
  final RailItem item;

  @override
  Widget build(BuildContext context) {
    Widget caption = Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 3),
        child: Row(
          children: [
            Icon(item.icon, size: 12, color: AppColors.onSurfaceDim),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.onSurfaceDim,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    final note = item.note;
    if (note != null && note.isNotEmpty) {
      caption = Tooltip(
        message: note,
        waitDuration: const Duration(milliseconds: 350),
        child: caption,
      );
    }
    return caption;
  }
}

/// One rail region - a PINNED group header, that group's pins (drag to reorder)
/// then the fixed drives/roots, and a latency footer. Right-click the empty
/// area for "Add bookmark / Restore defaults".
class _RailRegion extends StatelessWidget {
  const _RailRegion({required this.group});
  final RailGroup group;

  @override
  Widget build(BuildContext context) {
    final items = group.items;
    // Items before the first divider or section are the reorderable pins; it
    // and everything after (a team's bookmarks, the fixed drives/roots) are not.
    final dividerIdx = items.indexWhere((i) => i.isDivider || i.isSection);
    final pins = dividerIdx < 0 ? items : items.sublist(0, dividerIdx);
    final rest = dividerIdx < 0 ? const <RailItem>[] : items.sublist(dividerIdx);
    final canReorder = group.onReorderPins != null && pins.length > 1;

    Widget pinList;
    if (pins.isEmpty) {
      pinList = const SizedBox.shrink();
    } else if (canReorder) {
      pinList = ReorderableListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        padding: EdgeInsets.zero,
        itemCount: pins.length,
        onReorderItem: (oldIndex, newIndex) {
          if (newIndex != oldIndex) group.onReorderPins!(oldIndex, newIndex);
        },
        itemBuilder: (ctx, i) {
          final item = pins[i];
          // The whole row is the drag handle, so click-drag anywhere reorders;
          // a plain tap still navigates (InkWell.onTap fires through).
          return ReorderableDragStartListener(
            key: ValueKey(item.id ?? 'pin$i'),
            index: i,
            child: _railChild(item),
          );
        },
      );
    } else {
      pinList = Column(
        mainAxisSize: MainAxisSize.min,
        children: [for (final item in pins) _railChild(item)],
      );
    }

    Widget body = ListView(
      padding: const EdgeInsets.only(bottom: 6),
      children: [
        pinList,
        for (final item in rest) _railChild(item),
      ],
    );
    if (group.onEmptyAreaMenu != null) {
      body = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapUp: (d) => group.onEmptyAreaMenu!(d.globalPosition),
        // The right click's menu under a long press too where the controls are
        // touch sized (a tablet, 4.0): a finger has no right button.
        onLongPressStart: touchSizedAt(context) ? (d) => group.onEmptyAreaMenu!(d.globalPosition) : null,
        child: body,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RailHeader(group: group),
        Expanded(child: body),
        // Latency moved off the header to here, so the host name gets the room.
        if (group.latencyLabel != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
            child: Row(
              children: [
                if (group.dotColor != null) ...[
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                        color: group.dotColor, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  group.latencyLabel!,
                  style: TextStyle(
                    fontSize: 10,
                    fontFamily: 'JetBrainsMono',
                    color: AppColors.onSurfaceDim,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The draggable divider between the two rail regions - drag to resize, double-
/// tap to split evenly.
class _RailDivider extends StatefulWidget {
  const _RailDivider({
    required this.onDrag,
    required this.onDragEnd,
    required this.onReset,
  });

  final ValueChanged<double> onDrag;
  final VoidCallback onDragEnd;
  final VoidCallback onReset;

  @override
  State<_RailDivider> createState() => _RailDividerState();
}

class _RailDividerState extends State<_RailDivider> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (d) => widget.onDrag(d.delta.dy),
        onVerticalDragEnd: (_) => widget.onDragEnd(),
        onDoubleTap: widget.onReset,
        child: Container(
          height: 9,
          color: Colors.transparent,
          alignment: Alignment.center,
          // 26 x 2 grab bar, --border-lift, brand on hover.
          child: Container(
            width: 26,
            height: 2,
            decoration: BoxDecoration(
              color: _hover ? AppColors.brandOrange : AppColors.sftpBorderLift,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ),
      ),
    );
  }
}

/// The group header. When [RailGroup.paneSide] is set it's the pane's source
/// picker: a two-square target glyph (filled on the driven side), the source
/// label + latency, and a chevron; tapping opens the picker.
class _RailHeader extends StatelessWidget {
  const _RailHeader({required this.group});
  final RailGroup group;

  @override
  Widget build(BuildContext context) {
    final isPicker = group.paneSide != null && group.onHeaderTap != null;
    // The source header is a 32px --raised-2 pill, radius 6, one hairline
    // border. The label is the host name alone.
    Widget pill(Widget child) => Container(
          height: 32,
          margin: const EdgeInsets.fromLTRB(6, 4, 6, 4),
          decoration: BoxDecoration(
            color: AppColors.sftpRaised2,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.divider, width: 1),
          ),
          child: child,
        );
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 2, 4),
      child: Row(
        children: [
          if (group.paneSide != null) ...[
            _PaneTargetGlyph(side: group.paneSide!),
            const SizedBox(width: 7),
          ] else
            Container(
              width: 2,
              height: 10,
              margin: const EdgeInsets.only(right: 7),
              decoration: BoxDecoration(
                color: AppColors.brandOrange,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          // Remote source: a status dot stands in for the icon; local: the icon.
          if (group.dotColor != null)
            Container(
              width: 7,
              height: 7,
              margin: const EdgeInsets.only(right: 6),
              decoration:
                  BoxDecoration(color: group.dotColor, shape: BoxShape.circle),
            )
          else if (group.sourceIcon != null) ...[
            Icon(group.sourceIcon,
                size: 13,
                color: group.sourceIconColor ?? AppColors.textSecondary),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              group.label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.onSurface,
              ),
            ),
          ),
          // Latency no longer rides the header (it stole room from the host
          // name) - it moved to the bottom of the region (see _RailRegion).
          if (isPicker) ...[
            const SizedBox(width: 4),
            Icon(LucideIcons.chevronDown,
                size: 13, color: AppColors.textSecondary),
          ],
        ],
      ),
    );

    if (!isPicker) return pill(header);
    // The whole header IS the picker now - no ⋮ overflow. "Restore defaults" and
    // "Add bookmark" moved to a right-click menu on the empty rail area below.
    void open() {
      final box = context.findRenderObject() as RenderBox?;
      final anchor = box == null
          ? Offset.zero
          : box.localToGlobal(Offset(0, box.size.height));
      group.onHeaderTap!(anchor);
    }

    // A button to a screen reader and a stop of Tab that Enter or Space
    // opens, ringed in the accent with the focus; its target takes in the
    // pill's hairline, 32 high (4.0 accessibility pass: a GestureDetector
    // alone, 30 high).
    final pickerArea = HitArea(
      grow: const EdgeInsets.symmetric(vertical: 1),
      child: ZestPressable(onTap: open, minSize: 0, borderRadius: 6, child: header),
    );
    return pill(MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => group.onHeaderHover?.call(true),
      onExit: (_) => group.onHeaderHover?.call(false),
      child: pickerArea,
    ));
  }
}


/// Two small squares with the driven side filled - "this group controls the
/// left / right pane".
class _PaneTargetGlyph extends StatelessWidget {
  const _PaneTargetGlyph({required this.side});
  final int side;

  @override
  Widget build(BuildContext context) {
    Widget cell(bool filled) => Container(
          width: 6,
          height: 9,
          decoration: BoxDecoration(
            color: filled ? AppColors.brandOrange : Colors.transparent,
            border: Border.all(
              color: filled ? AppColors.brandOrange : AppColors.onSurfaceDim,
              width: 1,
            ),
          ),
        );
    final l10n = AppLocalizations.of(context)!;
    return Tooltip(
      message: side == 0
          ? l10n.sftpControlsLeftPane
          : l10n.sftpControlsRightPane,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [cell(side == 0), const SizedBox(width: 1), cell(side == 1)],
      ),
    );
  }
}

class _RailRow extends StatefulWidget {
  const _RailRow({required this.item});
  final RailItem item;

  @override
  State<_RailRow> createState() => _RailRowState();
}

class _RailRowState extends State<_RailRow> {
  bool _hover = false;
  bool _menuOpen = false;
  Offset _lastPointer = Offset.zero;

  Future<void> _openMenu(Future<void> Function(Offset) cb) async {
    setState(() => _menuOpen = true);
    try {
      await cb(_lastPointer);
    } finally {
      if (mounted) setState(() => _menuOpen = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final labelColor = item.stale
        ? AppColors.onSurfaceDim
        : (item.selected ? AppColors.onSurface : AppColors.textSecondary);
    final onCtx = item.onSecondaryTap;
    // Selected to a screen reader while it is the folder the pane shows (the
    // accent's wash said it to the eye only).
    final row = Semantics(
      selected: item.selected,
      button: true,
      child: MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Listener(
        onPointerDown: (e) => _lastPointer = e.position,
        child: InkWell(
        onTap: item.onTap,
      onSecondaryTap: onCtx == null ? null : () => _openMenu(onCtx),
      onLongPress: onCtx == null ? null : () => _openMenu(onCtx),
      child: Container(
        constraints: const BoxConstraints(minHeight: 28),
        margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          // brand-wash marks the folder the pane is showing; the menu-open
          // "targeted" hold uses --raised-2 so one channel never means two
          // things. Plain hover lifts to --raised.
          color: item.selected
              ? AppColors.brandOrange.withValues(alpha: 0.10)
              : (_menuOpen
                  ? AppColors.sftpRaised2
                  : (_hover ? AppColors.surface : null)),
          borderRadius: BorderRadius.circular(6),
        ),
        // One line, 28px: folder glyph + label (which now gets the FULL width -
        // the path moved to a hover tooltip so "Documents" isn't squeezed to
        // "Docu…"). A drive keeps its free-space readout inline on the right.
        child: Row(
          children: [
            Icon(
              item.stale ? LucideIcons.alertTriangle : item.icon,
              size: 14,
              color: item.stale
                  ? AppColors.sftpWarn
                  : (item.selected
                      ? AppColors.brandOrange
                      : AppColors.textSecondary),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: labelColor),
              ),
            ),
            // Free-space readout on a drive / filesystem root.
            if (item.trailing != null) ...[
              const SizedBox(width: 8),
              Text(
                item.trailing!,
                style: TextStyle(
                  fontSize: 10,
                  fontFamily: 'JetBrainsMono',
                  color: AppColors.onSurfaceDim,
                ),
              ),
            ],
          ],
        ),
      ),
      ),
      ),
      ),
    );
    // The full path shows on HOVER, not inline - so it never eats the label's
    // width. Only when the path differs from the label (a plain "/root" pin's
    // label already IS its path).
    final tip = item.pathHint;
    if (tip != null && tip.isNotEmpty) {
      return Tooltip(
        message: tip,
        waitDuration: const Duration(milliseconds: 350),
        child: row,
      );
    }
    return row;
  }
}
