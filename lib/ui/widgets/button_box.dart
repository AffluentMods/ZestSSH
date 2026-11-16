import 'package:flutter/material.dart';

/// The box a button stands in: [height] tall where the button's words take a
/// line, and as tall as they are where they take more. A box of a fixed height
/// cut a second line at its top and bottom (at a large text size, key
/// generation's "Сгенерировать пару ключей" and the Upgrade page's "Получить
/// Squeezed"). The box is the button's tap target, as the fixed one was.
///
/// A button whose own least height is more than [height] is given one of
/// [height] in its style (`minimumSize`), or it stands taller than before.
class ButtonBox extends StatelessWidget {
  const ButtonBox({super.key, required this.height, this.width, required this.child});

  /// The box's height where the button's words take a line.
  final double height;

  /// The box's width, or null for the button's own.
  final double? width;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: height),
        child: Theme(
          data: Theme.of(context).copyWith(materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
          child: child,
        ),
      ),
    );
  }
}
