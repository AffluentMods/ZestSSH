import 'package:flutter/material.dart';
import 'package:zestssh/models/pane_layout.dart';
import 'package:zestssh/theme/app_colors.dart';

export 'package:zestssh/models/pane_layout.dart' show LayoutPreset, layoutPresetNumber;

// ---------------------------------------------------------------------------
// LayoutDiagram - the miniature of an arrangement of panes
// ---------------------------------------------------------------------------

/// A small picture of an arrangement: each pane a rounded box, standing
/// where it stands on screen. Drawn from the arrangement's own shape, so a
/// picture can never show another arrangement than the one that is made.
class LayoutDiagram extends StatelessWidget {
  const LayoutDiagram({super.key, required this.shape, this.muted = false});

  final PaneShape shape;

  /// Drawn in neutral grey (an arrangement that is not to be had yet).
  final bool muted;

  // Instance getters (not `static final`) so they re-read the now-mutable
  // brand orange on each build - a `static final` snapshot would freeze at
  // first-access and ignore a user-chosen accent.
  Color get _fill => muted
      ? AppColors.v3TextTertiary.withValues(alpha: 0.18)
      : AppColors.brandOrange.withValues(alpha: 0.25);
  Color get _border => muted
      ? AppColors.v3TextTertiary.withValues(alpha: 0.45)
      : AppColors.brandOrange.withValues(alpha: 0.55);
  static const _gap = 2.0;
  static const _radius = BorderRadius.all(Radius.circular(3));

  @override
  Widget build(BuildContext context) => _draw(shape);

  Widget _draw(PaneShape shape) {
    if (shape is! ShapeSplit) {
      return Container(
        decoration: BoxDecoration(
          color: _fill,
          borderRadius: _radius,
          border: Border.all(color: _border, width: 1),
        ),
      );
    }
    final across = shape.axis == Axis.horizontal;
    return Flex(
      direction: shape.axis,
      // (Left to right whatever the language reads: the panes stand so.)
      textDirection: TextDirection.ltr,
      children: [
        for (var i = 0; i < shape.parts.length; i++) ...[
          if (i > 0) SizedBox(width: across ? _gap : 0, height: across ? 0 : _gap),
          Expanded(flex: shape.weight(i), child: _draw(shape.parts[i])),
        ],
      ],
    );
  }
}
