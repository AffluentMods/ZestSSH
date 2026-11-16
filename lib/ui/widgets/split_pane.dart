import 'package:flutter/material.dart';
import 'package:zestssh/theme/app_colors.dart';

/// A resizable split pane layout for desktop terminal.
///
/// Splits the view either horizontally or vertically with a draggable
/// divider. Each pane can contain a terminal session.
class SplitPane extends StatefulWidget {
  final Widget first;
  final Widget second;
  final Axis axis;
  final double initialRatio;

  const SplitPane({
    super.key,
    required this.first,
    required this.second,
    this.axis = Axis.horizontal,
    this.initialRatio = 0.5,
  });

  @override
  State<SplitPane> createState() => _SplitPaneState();
}

class _SplitPaneState extends State<SplitPane> {
  late double _ratio;

  @override
  void initState() {
    super.initState();
    _ratio = widget.initialRatio;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isHorizontal = widget.axis == Axis.horizontal;
        final totalSize =
            isHorizontal ? constraints.maxWidth : constraints.maxHeight;
        final firstSize = totalSize * _ratio;
        final dividerSize = 6.0;
        final secondSize = (totalSize - firstSize - dividerSize).clamp(0.0, double.infinity);

        final children = <Widget>[
          // First pane
          SizedBox(
            width: isHorizontal ? firstSize : null,
            height: isHorizontal ? null : firstSize,
            child: widget.first,
          ),

          // Draggable divider
          MouseRegion(
            cursor: isHorizontal
                ? SystemMouseCursors.resizeColumn
                : SystemMouseCursors.resizeRow,
            child: GestureDetector(
              onPanUpdate: (details) {
                setState(() {
                  final delta = isHorizontal ? details.delta.dx : details.delta.dy;
                  _ratio = ((_ratio * totalSize + delta) / totalSize)
                      .clamp(0.15, 0.85);
                });
              },
              child: Container(
                width: isHorizontal ? dividerSize : null,
                height: isHorizontal ? null : dividerSize,
                color: AppColors.divider,
                child: Center(
                  child: Container(
                    width: isHorizontal ? 2 : 24,
                    height: isHorizontal ? 24 : 2,
                    decoration: BoxDecoration(
                      color: AppColors.textSecondary.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Second pane
          SizedBox(
            width: isHorizontal ? secondSize : null,
            height: isHorizontal ? null : secondSize,
            child: widget.second,
          ),
        ];

        if (isHorizontal) {
          return Row(children: children);
        } else {
          return Column(children: children);
        }
      },
    );
  }
}
