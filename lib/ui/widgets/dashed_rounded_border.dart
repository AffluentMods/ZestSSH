import 'package:flutter/material.dart';

/// A rounded edge drawn in dashes, over [fill]: what holds nothing yet or
/// adds something (None's level pill, New vault, a group's empty tile).
/// Each dash is [dash] long with [gap] between dashes.
class DashedRoundedBorder extends Decoration {
  const DashedRoundedBorder({
    required this.color,
    required this.radius,
    this.fill = Colors.transparent,
    this.dash = 4,
    this.gap = 3,
  });

  final Color color;
  final double radius;
  final Color fill;
  final double dash;
  final double gap;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _DashedPainter(this);
}

class _DashedPainter extends BoxPainter {
  _DashedPainter(this.d);

  final DashedRoundedBorder d;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null) return;
    final rrect = RRect.fromRectAndRadius((offset & size).deflate(0.5), Radius.circular(d.radius));
    if (d.fill.a > 0) canvas.drawRRect(rrect, Paint()..color = d.fill);
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = d.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final metric in path.computeMetrics()) {
      var t = 0.0;
      while (t < metric.length) {
        canvas.drawPath(metric.extractPath(t, (t + d.dash).clamp(0, metric.length)), paint);
        t += d.dash + d.gap;
      }
    }
  }
}
