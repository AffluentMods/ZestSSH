// Remote screens (4.0): the picture's tiles under one transform, and the
// remote cursor over them. No edge anti-aliasing (tiles side by side would each
// cover half of a boundary pixel and leave a faint seam) and no filtering at or
// above one to one (crisp remote pixels when zoomed); a picture scaled down is
// smoothed a little so text stays legible. With smooth scaling on (4.0, step
// 4) the picture is smoothed wherever a remote pixel is not a whole number of
// the screen's own pixels.
import 'package:flutter/rendering.dart';
import 'package:zestssh/theme/app_colors.dart';

import 'screen_controller.dart';

class ScreenPainter extends CustomPainter {
  ScreenPainter(this.controller) : super(repaint: controller);

  final ScreenController controller;

  /// How the picture is filtered when one remote pixel is [scale] logical
  /// pixels on a screen with [devicePixelRatio] of its own pixels to a
  /// logical one.
  ///
  /// Not [smooth] (as it always was): a little smoothing below one to one,
  /// none at or above it. [smooth]: none only where a remote pixel is a
  /// whole number of the screen's pixels (one to one, or exactly twice or
  /// three times: nothing to smooth, and smoothing would only blur it);
  /// below that the better filter for a picture made smaller, above it the
  /// one that blends neighbouring pixels.
  static FilterQuality filterFor(double scale, double devicePixelRatio, {required bool smooth}) {
    if (!smooth) return scale < 1 ? FilterQuality.low : FilterQuality.none;
    final device = scale * (devicePixelRatio > 0 ? devicePixelRatio : 1);
    final whole = device.roundToDouble();
    if (whole >= 1 && (device - whole).abs() < 0.002) return FilterQuality.none;
    return device < 1 ? FilterQuality.medium : FilterQuality.low;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = controller;
    final v = c.viewport;
    if (!v.hasRemote || !c.hasPicture) return;
    final s = v.scale, o = v.origin;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(o.dx, o.dy);
    canvas.scale(s);
    final paint = Paint()
      ..isAntiAlias = false
      ..filterQuality = filterFor(s, v.devicePixelRatio, smooth: c.smoothScaling);
    for (final t in c.tiles) {
      canvas.drawImage(t.image, Offset(t.x.toDouble(), t.y.toDouble()), paint);
    }
    canvas.restore();
    _paintCursor(canvas, size);
  }

  void _paintCursor(Canvas canvas, Size size) {
    final c = controller;
    final (draw, x, y) = c.cursorDraw;
    if (draw == ScreenCursorDraw.none) return;
    final at = c.viewport.toLocal(x.toDouble(), y.toDouble());
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    switch (draw) {
      case ScreenCursorDraw.remote:
        final cursor = c.remoteCursor!;
        final image = cursor.image!;
        final k = c.cursorScale;
        final dst = Rect.fromLTWH(
          at.dx - cursor.hotX * k,
          at.dy - cursor.hotY * k,
          image.width * k,
          image.height * k,
        );
        canvas.drawImageRect(
          image,
          Offset.zero & Size(image.width.toDouble(), image.height.toDouble()),
          dst,
          Paint()
            ..isAntiAlias = false
            ..filterQuality = k < 1 ? FilterQuality.low : FilterQuality.none,
        );
      case ScreenCursorDraw.arrow:
        final arrow = Path()
          ..moveTo(at.dx, at.dy)
          ..lineTo(at.dx, at.dy + 18)
          ..lineTo(at.dx + 5, at.dy + 13)
          ..lineTo(at.dx + 12, at.dy + 13)
          ..close();
        canvas.drawPath(arrow, Paint()..color = AppColors.screenPointerFill);
        canvas.drawPath(
          arrow,
          Paint()
            ..color = AppColors.screenPointerEdge
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2,
        );
      case ScreenCursorDraw.none:
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(ScreenPainter oldDelegate) => oldDelegate.controller != controller;
}
