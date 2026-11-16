import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/theme/app_colors.dart';

/// Where a menu opened from the button at [buttonContext] goes: over the
/// button, moved by [offset], the way a [PopupMenuButton] places its own.
RelativeRect menuPositionAt(
  BuildContext buttonContext, {
  Offset offset = Offset.zero,
}) {
  final button = buttonContext.findRenderObject()! as RenderBox;
  final overlay = Navigator.of(buttonContext).overlay!.context.findRenderObject()!
      as RenderBox;
  return RelativeRect.fromRect(
    Rect.fromPoints(
      button.localToGlobal(offset, ancestor: overlay),
      button.localToGlobal(
        button.size.bottomRight(Offset.zero) + offset,
        ancestor: overlay,
      ),
    ),
    Offset.zero & overlay.size,
  );
}

/// The three dots of a card or a row.
///
/// The button only says where it is: the menu is opened, and what was picked
/// in it is acted on, by the card or row that builds this button. A
/// [PopupMenuButton] acts on the pick itself, and only while it is still in
/// the tree. Three dots that show while the mouse is over their card are no
/// longer under the mouse once their own menu covers the card, so they were
/// removed while the menu was open and every pick was dropped: nothing in
/// the menu did anything.
///
/// Whoever builds it keeps it built while its menu is open, so the dots stay
/// where the menu came from:
///
/// ```dart
/// if (_hovering || _menuOpen) MenuDotsButton(onOpen: _openMenu),
/// ```
class MenuDotsButton extends StatelessWidget {
  const MenuDotsButton({
    super.key,
    required this.onOpen,
    required this.tooltip,
    this.icon = LucideIcons.moreVertical,
    this.offset = const Offset(0, 28),
    this.iconSize = 16,
    this.color,
  });

  /// Called with the place for the menu when the dots are pressed.
  final void Function(RelativeRect position) onOpen;

  final String tooltip;
  final IconData icon;

  /// How far below the button's top left corner the menu opens.
  final Offset offset;

  final double iconSize;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: () => onOpen(menuPositionAt(context, offset: offset)),
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      iconSize: 20,
      splashRadius: 14,
      icon: Icon(
        icon,
        size: iconSize,
        color: color ?? AppColors.v3TextSecondary,
      ),
    );
  }
}
