import 'package:flutter/widgets.dart';

/// Fades a scrolling area out at an edge where more waits beyond it, so a
/// row is never cut hard at the frame (the settings pop-up's last row ended
/// mid-line). Reads the scrollable below it by its notifications, so any
/// list or scroll view works as it is. A dialog's own body does the same
/// (ZestDialogShell).
class ZestScrollFade extends StatefulWidget {
  const ZestScrollFade({super.key, required this.child, this.extent = 18, this.axis = Axis.vertical});

  final Widget child;

  /// How tall the fade is at each edge (how wide, across a row).
  final double extent;

  /// The way the area scrolls: a list fades at its top and its foot, a row
  /// that scrolls sideways (a phone's filter chips) at its start and its end.
  final Axis axis;

  @override
  State<ZestScrollFade> createState() => _ZestScrollFadeState();
}

class _ZestScrollFadeState extends State<ZestScrollFade> {
  bool _above = false;
  bool _below = false;

  bool _measure(ScrollMetrics m) {
    if (m.axis != widget.axis) return false;
    final above = m.pixels > 0.5;
    final below = m.pixels < m.maxScrollExtent - 0.5;
    if (above != _above || below != _below) {
      // After this frame: a notification can come in the middle of layout.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _above = above;
            _below = below;
          });
        }
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final vertical = widget.axis == Axis.vertical;
    final textDirection = Directionality.maybeOf(context) ?? TextDirection.ltr;
    // Always masked (opaque where nothing waits beyond an edge): adding the
    // mask only when needed rebuilds the scroll view below, which loses its
    // place.
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) => n.depth == 0 && _measure(n.metrics),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) => n.depth == 0 && _measure(n.metrics),
        child: ShaderMask(
          shaderCallback: (rect) {
            final length = vertical ? rect.height : rect.width;
            final edge = widget.extent / length.clamp(widget.extent * 2, double.infinity);
            return LinearGradient(
              // Sideways, from where the row starts (the right, in a language
              // read from right to left), where its first chip is.
              begin: vertical ? Alignment.topCenter : AlignmentDirectional.centerStart,
              end: vertical ? Alignment.bottomCenter : AlignmentDirectional.centerEnd,
              colors: [
                _above ? const Color(0x00000000) : const Color(0xFF000000),
                const Color(0xFF000000),
                const Color(0xFF000000),
                _below ? const Color(0x00000000) : const Color(0xFF000000),
              ],
              stops: [0, edge, 1 - edge, 1],
            ).createShader(rect, textDirection: textDirection);
          },
          blendMode: BlendMode.dstIn,
          child: widget.child,
        ),
      ),
    );
  }
}
