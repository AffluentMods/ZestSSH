import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/hosts/widgets/hosts_band.dart' show BandMenuRow;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/kbd.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart';

// The pieces of a list's selection (3.4,
// first drawn for the hosts): the box on each item, Select on the
// list's line, the head's box over the items, the floating bar at the foot
// of the page with its key hints, and a phone's top bar. Shared by every
// list that selects (hosts, keys, snippets, port forwards), so all of them
// look and work alike.

/// Where a menu of the bar opens: at its button, the menu itself choosing
/// above or below so that it stays inside the window (the bar is at the
/// window's foot, so it opens upward).
RelativeRect selectionMenuAt(RenderBox button, RenderBox overlay) {
  final rect = Rect.fromPoints(
    button.localToGlobal(Offset.zero, ancestor: overlay),
    button.localToGlobal(button.size.bottomRight(Offset.zero), ancestor: overlay),
  );
  return RelativeRect.fromRect(rect, Offset.zero & overlay.size);
}

/// The box before a selectable item while its list is selecting: checked
/// when the item is selected, a dash where some of what it stands for is
/// (the head's box over the items).
class SelectBox extends StatelessWidget {
  const SelectBox({super.key, required this.checked, this.size = 18, this.partial = false});

  final bool checked;
  final double size;

  /// Some of what it stands for is selected (the box over the items): a
  /// dash, filled.
  final bool partial;

  @override
  Widget build(BuildContext context) {
    final on = checked || partial;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: on ? ZestColors.accentPrimary : Colors.transparent,
        borderRadius: BorderRadius.circular(size * 0.24),
        border: Border.all(color: on ? ZestColors.accentPrimary : ZestColors.borderStrong, width: 1.2),
      ),
      child: checked
          ? Icon(LucideIcons.check, size: size * 0.62, color: ZestColors.onBrand)
          : partial
              ? Icon(LucideIcons.minus, size: size * 0.62, color: ZestColors.onBrand)
              : null,
    );
  }
}

/// One action of the bar: an icon and its words, quiet until hovered; red
/// for one that removes. Its tooltip names the key that does it, where one
/// does ([shortcut]).
class SelectionBarItem extends StatefulWidget {
  const SelectionBarItem({
    super.key,
    required this.icon,
    required this.label,
    required this.enabled,
    this.onTap,
    this.onAnchoredTap,
    this.trailing,
    this.shortcut,
    this.destructive = false,
    this.primary = false,
    this.showIcon = true,
    this.iconOnly = false,
  });

  /// The bar's main action (Edit…): filled with the brand.
  final bool primary;

  /// Its icon is drawn (Delete is its word alone, in red).
  final bool showIcon;

  /// Its icon alone (the close), its words in its tooltip.
  final bool iconOnly;

  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback? onTap;

  /// For an action that opens a menu at itself: called with its own context.
  final void Function(BuildContext anchor)? onAnchoredTap;

  /// A small chevron after the words: the action opens a choice.
  final IconData? trailing;
  final String? shortcut;
  final bool destructive;

  static TextStyle get labelStyle => const TextStyle(fontSize: 12, fontWeight: FontWeight.w500);

  /// The width of the ⋯ button.
  static const double moreWidth = 36;

  /// Runs the action (from the bar, or from the ⋯ menu with [anchor]).
  void run(BuildContext anchor) {
    if (onAnchoredTap != null) {
      onAnchoredTap!(anchor);
    } else {
      onTap?.call();
    }
  }

  @override
  State<SelectionBarItem> createState() => _SelectionBarItemState();
}

class _SelectionBarItemState extends State<SelectionBarItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    // A removing action's red as text on the bar at 4.5:1 or better (the red
    // itself was under it in every theme).
    final base = widget.destructive ? ZestColors.inkOn(ZestColors.statusError, ZestColors.bgElevated) : ZestColors.textPrimary;
    final fg = widget.primary
        ? (widget.enabled ? ZestColors.onBrand : ZestColors.textTertiary)
        : (widget.enabled ? base : ZestColors.textTertiary);
    final Color fill;
    if (widget.primary) {
      fill = widget.enabled
          ? (_hovering ? Color.lerp(ZestColors.accentPrimary, Colors.white, 0.08)! : ZestColors.accentPrimary)
          : ZestColors.textPrimary.withValues(alpha: 0.06);
    } else {
      fill = _hovering && widget.enabled
          ? (widget.destructive
              ? ZestColors.statusError.withValues(alpha: 0.12)
              : ZestColors.textPrimary.withValues(alpha: 0.05))
          : Colors.transparent;
    }
    // Reached with Tab, pressed with Enter or Space, a mouse's 32 high (a
    // finger's 48) around its drawing (4.0, the accessibility pass).
    final item = ZestPressable(
        onTap: widget.enabled ? () => widget.run(context) : null,
        onHover: (h) => setState(() => _hovering = h),
        semanticLabel: widget.iconOnly ? widget.label : null,
        excludeChildSemantics: widget.iconOnly,
        child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: EdgeInsets.symmetric(horizontal: widget.iconOnly ? 8 : (widget.primary ? 14 : 10), vertical: 7),
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(8)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.showIcon) Icon(widget.icon, size: widget.iconOnly ? 17 : 15, color: fg),
                if (widget.showIcon && !widget.iconOnly) const SizedBox(width: 7),
                if (!widget.iconOnly)
                  Text(
                    widget.label,
                    style: SelectionBarItem.labelStyle.copyWith(
                      color: fg,
                      fontSize: widget.primary ? 13 : 12.5,
                      fontWeight: widget.primary ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                if (widget.trailing != null) ...[
                  const SizedBox(width: 4),
                  Icon(widget.trailing, size: 14, color: fg),
                ],
              ],
            ),
          ),
    );
    if (widget.shortcut == null && !widget.iconOnly) return item;
    return Tooltip(
      message: widget.shortcut == null ? widget.label : '${widget.label} (${widget.shortcut})',
      waitDuration: const Duration(milliseconds: 500),
      // Its label says it where the tooltip only repeats it.
      excludeFromSemantics: widget.shortcut == null,
      child: item,
    );
  }
}

/// The count of selected items on the page's bar ("42
/// selected"): a click offers every item shown, or none.
class SelectionCountLabel extends StatelessWidget {
  const SelectionCountLabel({super.key, required this.label, required this.tooltip, required this.onTap});

  final String label;
  final String tooltip;
  final void Function(BuildContext anchor) onTap;

  @override
  Widget build(BuildContext context) {
    // Said as it changes (a live region: "3 selected"), reached with Tab, a
    // mouse's 32 high.
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: Semantics(
        liveRegion: true,
        child: ZestPressable(
          key: const ValueKey('bulk-count'),
          onTap: () => onTap(context),
          borderRadius: 4,
          child: Text(
            label,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: ZestColors.textPrimary),
          ),
        ),
      ),
    );
  }
}

/// How to select more, in a quiet line over the page's bar:
/// each key as a key, then what it does; [extra] after them, where the list
/// has more to say.
class SelectionHints extends StatelessWidget {
  const SelectionHints({super.key, required this.toggleKey, this.extra});

  final String toggleKey;

  /// A last quiet line of words (the hosts': Tags and Move open the editor
  /// at their field).
  final String? extra;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final words = TextStyle(fontSize: 12, color: ZestColors.textTertiary);
    Widget hint(List<String> keys, String what) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final k in keys) ...[Kbd(k), const SizedBox(width: 4)],
            const SizedBox(width: 2),
            Text(what, style: words),
          ],
        );
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 16,
      runSpacing: 4,
      children: [
        hint([toggleKey], l10n.bulkHintAdd),
        hint(['Shift'], l10n.bulkHintRange),
        hint([toggleKey, 'A'], l10n.bulkHintAll),
        hint(['Esc'], l10n.bulkHintClears),
        if (extra != null) Text(extra!, style: words),
      ],
    );
  }
}

/// The bar's ⋯: the actions that did not fit on its one row, as a menu.
class SelectionMoreButton extends StatelessWidget {
  const SelectionMoreButton({super.key, required this.enabled, required this.tooltip, required this.items});

  final bool enabled;
  final String tooltip;
  final List<SelectionBarItem> items;

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject();
    final overlay = Overlay.of(context).context.findRenderObject();
    if (box is! RenderBox || overlay is! RenderBox) return;
    final pick = await showMenu<int>(
      context: context,
      color: ZestColors.surfaceRaisedAlt,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: ZestColors.borderStrong),
      ),
      position: selectionMenuAt(box, overlay),
      items: [
        for (var i = 0; i < items.length; i++)
          PopupMenuItem(
            key: ValueKey('bulk-more-${(items[i].key as ValueKey<String>).value}'),
            value: i,
            height: 38,
            child: BandMenuRow(icon: items[i].icon, label: items[i].label),
          ),
      ],
    );
    if (pick != null && context.mounted) items[pick].run(context);
  }

  @override
  Widget build(BuildContext context) {
    final fg = enabled ? ZestColors.textPrimary : ZestColors.textTertiary;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      excludeFromSemantics: true,
      child: Builder(
        builder: (button) => ZestPressable(
          key: const ValueKey('bulk-more'),
          onTap: enabled ? () => _open(button) : null,
          semanticLabel: tooltip,
          excludeChildSemantics: true,
          child: Container(
            width: SelectionBarItem.moreWidth - 4,
            height: 28,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            alignment: Alignment.center,
            child: Icon(LucideIcons.moreHorizontal, size: 16, color: fg),
          ),
        ),
      ),
    );
  }
}

/// A thin upright line between groups of the bar's actions.
class SelectionBarDivider extends StatelessWidget {
  const SelectionBarDivider({super.key});

  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 22,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        color: ZestColors.borderSubtle,
      );
}

/// The page's selection bar as the design draws
/// it: [children] (the count, the actions, Delete, the close) in one pill
/// that floats at the foot of the page, [hints] over it, and the page fading
/// out under both. [barKey] is the pill's row.
class SelectionBarFrame extends StatelessWidget {
  const SelectionBarFrame({super.key, required this.hints, required this.children, this.barKey});

  final Widget hints;
  final List<Widget> children;
  final Key? barKey;

  @override
  Widget build(BuildContext context) {
    final page = Theme.of(context).scaffoldBackgroundColor;
    final bar = Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: ZestColors.bgElevated,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: ZestColors.borderStrong, width: 0.8),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 24, offset: const Offset(0, 8)),
          ],
        ),
        // One row where it fits; in a narrow window the actions wrap rather
        // than being cut off.
        child: Wrap(
          key: barKey,
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 4,
          children: children,
        ),
      ),
    );

    // The page fades out under the bar and its hints, so what scrolls behind
    // them (a list's rows) never reads through their words.
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [page.withValues(alpha: 0), page.withValues(alpha: 0.94), page],
          stops: const [0, 0.35, 1],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 14, 24, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // How to select more, quietly, over the bar.
            hints,
            const SizedBox(height: 8),
            Center(child: bar),
          ],
        ),
      ),
    );
  }
}

/// Select (Selecting while the list is selecting): starts and ends
/// selecting, on the list's own line. [tooltip] says what selecting does
/// there; [buttonKey] is the button's own (what a test taps).
class SelectToggleButton extends StatelessWidget {
  const SelectToggleButton({
    super.key,
    required this.selecting,
    required this.onTap,
    required this.tooltip,
    this.buttonKey,
  });

  final bool selecting;
  final VoidCallback onTap;
  final String tooltip;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final fg = selecting ? ZestColors.textPrimary : ZestColors.textSecondary;
    // Pressed anywhere in a mouse's 32 (a finger's 48) around it, reached
    // with Tab, said as a switch that is on while the list is selecting.
    return Tooltip(
      message: selecting ? '${l10n.bulkStopSelecting} (Esc)' : tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: ZestPressable(
        onTap: onTap,
        toggled: selecting,
        borderRadius: 7,
        child: Material(
        color: selecting ? ZestColors.surfaceChipStrong : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(7),
          side: BorderSide(color: selecting ? ZestColors.borderStrong : ZestColors.borderDefault),
        ),
        child: InkWell(
          key: buttonKey,
          borderRadius: BorderRadius.circular(7),
          canRequestFocus: false,
          excludeFromSemantics: true,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.checkSquare, size: 13, color: fg),
                const SizedBox(width: 6),
                Text(
                  selecting ? l10n.bulkSelectingButton : l10n.bulkSelectButton,
                  style: TextStyle(fontSize: 12, fontWeight: selecting ? FontWeight.w600 : FontWeight.w500, color: fg),
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

/// At the head of a list while it is selecting:
/// a box that selects every item shown, or none (a dash where
/// some are), how many of them are selected, and Clear selection. As tall as
/// the line it stands on, so nothing under it moves. Its parts' keys start
/// with [keyPrefix] ("host-selection-all").
class SelectionHead extends StatelessWidget {
  const SelectionHead({
    super.key,
    required this.shown,
    required this.selected,
    required this.onSelectShown,
    required this.onUnselectShown,
    required this.onClear,
    required this.tooltip,
    this.keyPrefix = 'selection',
  });

  /// The items shown, in their order.
  final List<String> shown;
  final Set<String> selected;
  final VoidCallback onSelectShown;
  final VoidCallback onUnselectShown;
  final VoidCallback onClear;

  /// What the box does ("Select every host shown, or none").
  final String tooltip;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final picked = shown.where(selected.contains).length;
    final all = picked == shown.length;
    // Its box and Clear selection are pressed anywhere in a mouse's 32 (a
    // finger's 48) around them, reached with Tab and said with their state
    // (they were 16 high, a bare tap each: 4.0, the accessibility pass).
    return SizedBox(
      key: ValueKey('$keyPrefix-head'),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: tooltip,
            excludeFromSemantics: true,
            child: ZestPressable(
                key: ValueKey('$keyPrefix-all'),
                onTap: all ? onUnselectShown : onSelectShown,
                semanticLabel: tooltip,
                checked: all,
                excludeChildSemantics: true,
                borderRadius: 4,
                child: SelectBox(checked: all, partial: picked > 0 && !all, size: 16),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              all ? l10n.bulkAllSelected(shown.length) : l10n.bulkSomeSelected(picked, shown.length),
              key: ValueKey('$keyPrefix-count'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: ZestColors.textSecondary),
            ),
          ),
          if (selected.isNotEmpty) ...[
            const SizedBox(width: 14),
            ZestPressable(
                key: ValueKey('$keyPrefix-clear'),
                onTap: onClear,
                borderRadius: 4,
                child: Text(
                  l10n.bulkClearSelection,
                  maxLines: 1,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ZestColors.textPrimary),
                ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The top bar while a phone's list is selecting: the close, how many are
/// selected, and Select all shown (none where [onSelectAll] is null).
class PhoneSelectionAppBar extends StatelessWidget implements PreferredSizeWidget {
  const PhoneSelectionAppBar({super.key, required this.count, required this.onClose, this.onSelectAll});

  final int count;
  final VoidCallback onClose;
  final VoidCallback? onSelectAll;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AppBar(
      key: const ValueKey('phone-selection-bar'),
      automaticallyImplyLeading: false,
      leading: IconButton(
        key: const ValueKey('phone-selection-close'),
        tooltip: l10n.bulkStopSelecting,
        icon: const Icon(LucideIcons.x),
        onPressed: onClose,
      ),
      titleSpacing: 0,
      title: Text(
        l10n.hostBulkActionSelectedCount(count),
        key: const ValueKey('phone-selection-count'),
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 19),
      ),
      actions: [
        TextButton(
          key: const ValueKey('phone-selection-all'),
          onPressed: onSelectAll,
          style: TextButton.styleFrom(foregroundColor: ZestTokens.textSecondary),
          child: Text(l10n.bulkSelectAllShown, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: 6),
      ],
    );
  }
}

/// Selected items the search hides, said over a phone's list, with Show,
/// which shows every item again.
class SelectionHiddenRow extends StatelessWidget {
  const SelectionHiddenRow({super.key, required this.text, required this.onShow});

  /// "2 selected are hidden by search".
  final String text;
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZestTokens.borderSubtle, width: 0.6),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.eye, size: 16, color: ZestTokens.textTertiary),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: TextStyle(fontSize: 13, color: ZestTokens.textSecondary))),
          TextButton(
            key: const ValueKey('phone-selection-show-hidden'),
            onPressed: onShow,
            style: TextButton.styleFrom(foregroundColor: ZestTokens.textPrimary),
            child: Text(l10n.bulkShowHidden, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
