import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;

/// One choice of a [ZestSelect].
class ZestSelectItem<T> {
  const ZestSelectItem(
    this.value,
    this.label, {
    this.icon,
    this.leading,
    this.enabled = true,
    this.trailingIcon,
    this.swatch,
    this.badge,
    this.tag,
    this.note,
  });

  final T value;
  final String label;
  final IconData? icon;

  /// What stands before the label in place of an [icon]: a host's own icon.
  final Widget? leading;

  /// A smaller line under the label in the menu: why a choice that is not
  /// [enabled] cannot be chosen (a host that is SFTP only, for a command).
  final String? note;

  /// False: shown dimmed, and it cannot be chosen.
  final bool enabled;

  /// At the row's end: the lock on a choice the plan does not include.
  final IconData? trailingIcon;

  /// Colours before the label, a stripe each: a theme's.
  final List<Color>? swatch;

  /// A word after the label in the brand's ink: Pro, on a choice the plan
  /// does not include.
  final String? badge;

  /// A word after the label in a quiet outline: Custom, on a theme someone
  /// made.
  final String? tag;
}

/// A theme's colours, a stripe each, as a select shows them.
Widget _swatchOf(List<Color> colors) => Container(
      width: colors.length == 1 ? 14 : 28,
      height: 14,
      margin: const EdgeInsetsDirectional.only(end: 8),
      decoration: BoxDecoration(
        border: Border.all(color: ZestTokens.borderSubtle),
        borderRadius: BorderRadius.circular(3),
      ),
      clipBehavior: Clip.antiAlias,
      // Stretched: a coloured box with nothing in it takes no height of its own,
      // so the stripes did not show at all.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final c in colors) Expanded(child: ColoredBox(color: c))],
      ),
    );

/// Something a [ZestSelect]'s menu does besides choosing (New group, Create
/// a key): after the choices, under a hairline, in the brand's ink.
class ZestSelectAction {
  const ZestSelectAction(this.label, {required this.onPressed, this.icon, this.key});

  final String label;
  final IconData? icon;
  final VoidCallback onPressed;
  final Key? key;
}

/// The app's select: drawn as its inputs are (the theme's fill, hairline and
/// radius; 34 high on a computer, as its buttons and fields are, 44 on a phone), its menu opening under it
/// with a check on the value chosen. In place of Material's dropdowns, whose
/// underline, filled triangle and menu over the field matched nothing else.
class ZestSelect<T> extends StatefulWidget {
  const ZestSelect({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.width,
    this.hint,
    this.actions = const [],
    this.frame,
    this.accent = false,
    this.large = false,
    this.semanticLabel,
  });

  /// What is chosen, to a screen reader ("Theme"); left out, the name of the
  /// row it stands in ([ZestControlLabel]), where it is in one.
  final String? semanticLabel;

  /// The value chosen; null shows [hint].
  final T? value;
  final List<ZestSelectItem<T>> items;

  /// Null: shown disabled.
  final ValueChanged<T>? onChanged;

  /// Fixed width; null takes what the parent gives.
  final double? width;
  final String? hint;

  /// What the menu does besides choosing, after the choices.
  final List<ZestSelectAction> actions;

  /// Where given, the field the select is drawn in (a [ZestField.custom]
  /// shell, which is the surface): it is handed the value and its chevron,
  /// bare, and the whole field opens the menu, which hangs under it. Null:
  /// the select's own box.
  final Widget Function(Widget value)? frame;

  /// The value in the brand's ink: chosen apart from what it would be by
  /// default (a member's vault access set for them).
  final bool accent;

  /// The value a size up, as a phone's form draws its values (4.0 UI: the
  /// boxes of a phone's host form are 48 high).
  final bool large;

  @override
  State<ZestSelect<T>> createState() => _ZestSelectState<T>();
}

class _ZestSelectState<T> extends State<ZestSelect<T>> {
  final _menu = MenuController();
  bool _focused = false;
  bool _hover = false;

  /// The field's width when the menu last opened.
  double? _openWidth;

  void _toggle(BuildContext field, MenuController controller) {
    if (controller.isOpen) {
      controller.close();
      return;
    }
    final box = field.findRenderObject();
    final width = box is RenderBox && box.hasSize ? box.size.width : null;
    if (width != _openWidth) setState(() => _openWidth = width);
    controller.open();
  }

  @override
  Widget build(BuildContext context) {
    final phone = zestUsesSheets(context);
    final enabled = widget.onChanged != null;
    final deco = Theme.of(context).inputDecorationTheme;
    final open = _menu.isOpen;
    final border = (open || _focused ? deco.focusedBorder : deco.enabledBorder) as OutlineInputBorder?;
    ZestSelectItem<T>? chosen;
    for (final i in widget.items) {
      if (i.value == widget.value) chosen = i;
    }
    // 48 where a finger presses a choice (44 on a phone before).
    final touch = phone || touchSizedAt(context);
    final rowHeight = touch ? 48.0 : 32.0;
    final valueRow = Row(
      children: [
        if (chosen?.swatch != null) _swatchOf(chosen!.swatch!),
        if (chosen?.icon != null) ...[
          Icon(chosen!.icon, size: 14, color: ZestTokens.textSecondary),
          const SizedBox(width: 8),
        ],
        if (chosen?.leading != null) ...[
          chosen!.leading!,
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(
            chosen?.label ?? widget.hint ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: widget.large ? 15.5 : 13,
              color: chosen == null
                  ? (widget.large ? ZestTokens.textTertiary : ZestTokens.textPlaceholder)
                  : widget.accent
                      ? ZestTokens.brandInk
                      : ZestTokens.textPrimary,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Icon(open ? LucideIcons.chevronUp : LucideIcons.chevronDown,
            size: widget.large ? 18 : 14, color: ZestTokens.textSecondary),
      ],
    );
    return MenuAnchor(
      controller: _menu,
      alignmentOffset: const Offset(0, 4),
      onOpen: () => setState(() {}),
      onClose: () => setState(() {}),
      // At least as wide as the field, measured as it opens: under a wide
      // field it opened narrower and covered what was under it (found in a design
      // audit). The panel only keeps its minimum width when
      // its cross axis is constrained: by default it draws at its words'
      // width whatever the style says, so the 160 here never showed either.
      crossAxisUnconstrained: false,
      style: MenuStyle(
        minimumSize: WidgetStatePropertyAll(Size(math.max(widget.width ?? 160, _openWidth ?? 0), 0)),
      ),
      menuChildren: [
        for (final item in widget.items)
          MenuItemButton(
            key: ValueKey('zest-select-item-${item.value}'),
            onPressed: !item.enabled || !enabled ? null : () => widget.onChanged!(item.value),
            style: MenuItemButton.styleFrom(minimumSize: Size(0, rowHeight)),
            leadingIcon: SizedBox(
              width: 16,
              child: item.value == widget.value ? Icon(LucideIcons.check, size: 14, color: ZestTokens.brandInk) : null,
            ),
            trailingIcon: item.trailingIcon == null
                ? null
                : Icon(item.trailingIcon, size: 14, color: ZestTokens.textPlaceholder),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (item.swatch != null) _swatchOf(item.swatch!),
                if (item.icon != null) ...[
                  Icon(item.icon, size: 14, color: ZestTokens.textSecondary),
                  const SizedBox(width: 8),
                ],
                if (item.leading != null) ...[
                  item.leading!,
                  const SizedBox(width: 8),
                ],
                // The menu is held to the window's width: a longer name
                // wraps in its row.
                Flexible(
                  child: item.note == null
                      ? Text(
                          item.label,
                          style: TextStyle(
                            fontSize: 13,
                            color: item.enabled ? ZestTokens.textPrimary : ZestTokens.textPlaceholder,
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              item.label,
                              style: TextStyle(
                                fontSize: 13,
                                color: item.enabled ? ZestTokens.textPrimary : ZestTokens.textPlaceholder,
                              ),
                            ),
                            Text(
                              item.note!,
                              style: TextStyle(fontSize: 11, color: ZestTokens.textPlaceholder),
                            ),
                          ],
                        ),
                ),
                if (item.badge != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    item.badge!,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: ZestTokens.brandInk,
                    ),
                  ),
                ],
                if (item.tag != null) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      border: Border.all(color: ZestTokens.border),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      item.tag!,
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                        color: ZestTokens.textSecondary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        if (widget.actions.isNotEmpty) Divider(height: 9, thickness: 0.5, color: ZestTokens.border),
        for (final action in widget.actions)
          MenuItemButton(
            key: action.key,
            onPressed: !enabled ? null : action.onPressed,
            style: MenuItemButton.styleFrom(minimumSize: Size(0, rowHeight)),
            leadingIcon: SizedBox(
              width: 16,
              child: action.icon == null ? null : Icon(action.icon, size: 14, color: ZestTokens.brandInk),
            ),
            child: Text(
              action.label,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.brandInk),
            ),
          ),
      ],
      builder: (context, controller, _) {
        // To a screen reader: what it chooses, what is chosen, a button, and
        // whether its menu is open.
        // In a field's shell the shell's own label names it (its words are
        // left in), and the value is said once, as the value.
        // Where it has a name, the name and the value apart; where it has
        // none, the value shown is what it is said as, as before.
        final name = widget.semanticLabel ?? ZestControlLabel.maybeOf(context);
        Widget spoken(Widget child, {bool framed = false}) => Semantics(
              container: true,
              button: true,
              enabled: enabled,
              expanded: controller.isOpen,
              // Unnamed and on its own, it is said as the value it shows,
              // on its own node (the words were left to the focus's node
              // under it, and the button was said with no name: 4.0).
              label: name ?? (framed ? null : chosen?.label ?? widget.hint),
              value: name == null ? null : chosen?.label ?? widget.hint,
              excludeSemantics: !framed,
              onTap: !enabled ? null : () => _toggle(context, controller),
              child: child,
            );
        Widget focusable(Widget child) => FocusableActionDetector(
              enabled: enabled,
              mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
              onShowFocusHighlight: (v) => setState(() => _focused = v),
              onShowHoverHighlight: (v) => setState(() => _hover = v),
              actions: {
                ActivateIntent: CallbackAction<ActivateIntent>(
                  onInvoke: (_) => _toggle(context, controller),
                ),
              },
              child: child,
            );
        final frame = widget.frame;
        if (frame != null) {
          // In the field's shell, the whole field opens the menu, and the
          // focus is held inside it, so the shell's ring shows it.
          // To a screen reader, the whole field is the select.
          return spoken(MouseRegion(
            cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: !enabled ? null : () => _toggle(context, controller),
              excludeFromSemantics: true,
              child: frame(Opacity(opacity: enabled ? 1 : 0.45, child: focusable(ExcludeSemantics(excluding: name != null, child: valueRow)))),
            ),
          ), framed: true);
        }
        return Opacity(
          opacity: enabled ? 1 : 0.45,
          child: spoken(focusable(
            GestureDetector(
              onTap: !enabled ? null : () => _toggle(context, controller),
              child: Container(
                width: widget.width,
                // Its height, or more where larger text needs it.
                constraints: BoxConstraints(minHeight: touch ? 48 : 34),
                padding: const EdgeInsets.only(left: 12, right: 10, top: 4, bottom: 4),
                decoration: BoxDecoration(
                  color: _hover && enabled
                      ? Color.alphaBlend(ZestTokens.textPrimary.withValues(alpha: 0.03), deco.fillColor ?? Colors.transparent)
                      : deco.fillColor,
                  borderRadius: border?.borderRadius ?? BorderRadius.circular(8),
                  border: Border.fromBorderSide(border?.borderSide ?? BorderSide(color: ZestTokens.border)),
                ),
                child: valueRow,
              ),
            ),
          )),
        );
      },
    );
  }
}
