import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:zestssh/theme/app_colors.dart';

/// The position within a pane where a dragged session can be dropped.
enum DropPosition { top, bottom, left, right, center }

/// Visual overlay that indicates where a dragged session header will be placed.
///
/// Each pane is divided into 5 drop regions:
/// ```
/// ┌──────────────────────┐
/// │         TOP          │  ← top 25%
/// ├────┬────────────┬────┤
/// │ L  │   CENTER   │ R  │  ← left/right 25%, center 50%
/// ├────┴────────────┴────┤
/// │        BOTTOM        │  ← bottom 25%
/// └──────────────────────┘
/// ```
///
/// - TOP: Split pane, dragged session goes on top
/// - BOTTOM: Split pane, dragged session goes on bottom
/// - LEFT: Split pane, dragged session goes on left
/// - RIGHT: Split pane, dragged session goes on right
/// - CENTER: Swap sessions
class PaneDropZone extends StatelessWidget {
  /// Whether this drop zone is currently being hovered over.
  final bool isActive;

  /// The drop position this zone represents.
  final DropPosition position;

  const PaneDropZone({
    super.key,
    required this.isActive,
    required this.position,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: isActive
            ? AppColors.brandOrange.withValues(alpha: 0.2)
            : Colors.transparent,
        border: isActive
            ? Border.all(
                color: AppColors.brandOrange.withValues(alpha: 0.6),
                width: 2,
              )
            : null,
        borderRadius: BorderRadius.circular(8),
      ),
      child: isActive
          ? Center(
              child: Icon(
                _iconForPosition(position),
                size: 24,
                color: AppColors.accentInk.withValues(alpha: 0.8),
              ),
            )
          : null,
    );
  }

  IconData _iconForPosition(DropPosition pos) {
    return switch (pos) {
      DropPosition.top => LucideIcons.arrowUpToLine,
      DropPosition.bottom => LucideIcons.arrowDownToLine,
      DropPosition.left => LucideIcons.alignHorizontalJustifyStart,
      DropPosition.right => LucideIcons.alignHorizontalJustifyEnd,
      DropPosition.center => LucideIcons.arrowLeftRight,
    };
  }
}

/// A container that overlays a pane during drag operations, detecting which
/// of the 5 drop regions the cursor is hovering over.
class PaneDropOverlay extends StatefulWidget {
  /// Called when the user drops on a specific position.
  final void Function(DropPosition position)? onDrop;

  /// Whether the overlay should be visible (a drag is in progress).
  final bool visible;

  /// The child pane widget to overlay.
  final Widget child;

  const PaneDropOverlay({
    super.key,
    required this.child,
    this.onDrop,
    this.visible = false,
  });

  @override
  State<PaneDropOverlay> createState() => _PaneDropOverlayState();
}

class _PaneDropOverlayState extends State<PaneDropOverlay> {
  DropPosition? _hoveredPosition;

  DropPosition? _hitTest(Offset localPosition, Size size) {
    final dx = localPosition.dx / size.width;
    final dy = localPosition.dy / size.height;

    // Top 25%
    if (dy < 0.25) return DropPosition.top;
    // Bottom 25%
    if (dy > 0.75) return DropPosition.bottom;
    // Left 25% of the middle band
    if (dx < 0.25) return DropPosition.left;
    // Right 25% of the middle band
    if (dx > 0.75) return DropPosition.right;
    // Center
    return DropPosition.center;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (widget.visible)
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = Size(
                  constraints.maxWidth,
                  constraints.maxHeight,
                );
                return MouseRegion(
                  onHover: (event) {
                    final pos = _hitTest(event.localPosition, size);
                    if (pos != _hoveredPosition) {
                      setState(() => _hoveredPosition = pos);
                    }
                  },
                  onExit: (_) {
                    setState(() => _hoveredPosition = null);
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTapUp: (details) {
                      final pos = _hitTest(details.localPosition, size);
                      if (pos != null) {
                        widget.onDrop?.call(pos);
                      }
                    },
                    child: Stack(
                      children: [
                        // Top zone
                        Positioned(
                          left: 0,
                          right: 0,
                          top: 0,
                          height: constraints.maxHeight * 0.25,
                          child: PaneDropZone(
                            isActive: _hoveredPosition == DropPosition.top,
                            position: DropPosition.top,
                          ),
                        ),
                        // Bottom zone
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          height: constraints.maxHeight * 0.25,
                          child: PaneDropZone(
                            isActive:
                                _hoveredPosition == DropPosition.bottom,
                            position: DropPosition.bottom,
                          ),
                        ),
                        // Left zone (middle band)
                        Positioned(
                          left: 0,
                          top: constraints.maxHeight * 0.25,
                          width: constraints.maxWidth * 0.25,
                          height: constraints.maxHeight * 0.5,
                          child: PaneDropZone(
                            isActive: _hoveredPosition == DropPosition.left,
                            position: DropPosition.left,
                          ),
                        ),
                        // Right zone (middle band)
                        Positioned(
                          right: 0,
                          top: constraints.maxHeight * 0.25,
                          width: constraints.maxWidth * 0.25,
                          height: constraints.maxHeight * 0.5,
                          child: PaneDropZone(
                            isActive:
                                _hoveredPosition == DropPosition.right,
                            position: DropPosition.right,
                          ),
                        ),
                        // Center zone (middle band)
                        Positioned(
                          left: constraints.maxWidth * 0.25,
                          top: constraints.maxHeight * 0.25,
                          width: constraints.maxWidth * 0.5,
                          height: constraints.maxHeight * 0.5,
                          child: PaneDropZone(
                            isActive:
                                _hoveredPosition == DropPosition.center,
                            position: DropPosition.center,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
