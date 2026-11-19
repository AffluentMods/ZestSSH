import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart';

/// The close button at the right of an editor's header (the docked host
/// editor, the detail panes on the shared detail scaffold): the one way out of the
/// editor, so it is drawn in the danger colour in every theme, on a faint tint
/// of it that deepens under the pointer and while pressed.
///
/// It is 32 square; the press is taken in [minTapTarget] around it (a
/// mouse's 32, a finger's 48), the keyboard reaches it with Tab and rings it,
/// and a screen reader says it as a button named Close.
class ZestCloseButton extends StatefulWidget {
  const ZestCloseButton({super.key, required this.onPressed, this.tooltip, this.focusNode});

  /// Null: turned off.
  final VoidCallback? onPressed;

  /// The tooltip and the screen reader's name; null: the localized "Close".
  final String? tooltip;

  final FocusNode? focusNode;

  /// The drawn size, square.
  static const double size = 32;

  @override
  State<ZestCloseButton> createState() => _ZestCloseButtonState();
}

class _ZestCloseButtonState extends State<ZestCloseButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final label = widget.tooltip ?? AppLocalizations.of(context)?.close ?? 'Close';
    final enabled = widget.onPressed != null;
    final red = ZestTokens.statusCritical;
    final tint = !enabled
        ? 0.0
        : _pressed
            ? 0.26
            : _hover
                ? 0.18
                : 0.10;
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Listener(
        onPointerDown: (_) => setState(() => _pressed = true),
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: ZestPressable(
          onTap: widget.onPressed,
          focusNode: widget.focusNode,
          onHover: (h) => setState(() => _hover = h),
          semanticLabel: label,
          excludeChildSemantics: true,
          borderRadius: 8,
          child: Opacity(
            opacity: enabled ? 1 : 0.4,
            child: Container(
              width: ZestCloseButton.size,
              height: ZestCloseButton.size,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: red.withValues(alpha: tint),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(LucideIcons.x, size: 20, color: red),
            ),
          ),
        ),
      ),
    );
  }
}
