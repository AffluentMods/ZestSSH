import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// The lock screen's art (4.0): a warm
/// glow of the accent and a faint citrus slice on the panel colour. It is drawn
/// behind the lock screen, and on each half of the doors that split open onto
/// the app once the check passes ([LockCurtain]).
class LockArt extends StatelessWidget {
  const LockArt({super.key, required this.panel, required this.accent, required this.phone});

  /// The colour under everything: the theme's panel.
  final Color panel;

  /// The glow and the citrus: the theme's accent.
  final Color accent;

  /// A phone's layout: the slice larger and higher, behind the title.
  final bool phone;

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: LockArtPainter(panel: panel, accent: accent, phone: phone),
        child: const SizedBox.expand(),
      );
}

/// Paints [LockArt]: the panel, the glow (an ellipse 60% of the width and 52% of
/// the height, centred at 50% and 44%, the accent at 13% fading out at 72% of it)
/// and the citrus slice (580 wide on a computer, one and a half times the width on
/// a phone; the accent at 12%, its inner curves fainter still).
class LockArtPainter extends CustomPainter {
  LockArtPainter({required this.panel, required this.accent, required this.phone});

  final Color panel;
  final Color accent;
  final bool phone;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = panel);

    final glowAt = Offset(size.width * 0.5, size.height * 0.44);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset.zero,
          1,
          [accent.withValues(alpha: 0.13), accent.withValues(alpha: 0)],
          const [0, 0.72],
          TileMode.clamp,
          _scaleThenMove(size.width * 0.6, size.height * 0.52, glowAt),
        ),
    );

    final side = phone ? size.width * 1.5 : math.min(size.width * 0.8, 580.0);
    final at = phone ? Offset(size.width * 0.5, size.height * 0.30) : glowAt;
    final place = _scaleThenMove(side / 100, side / 100, at - Offset(side / 2, side / 2));
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6 * side / 100
      ..color = accent.withValues(alpha: 0.12);
    canvas.drawPath(_slice.transform(place), stroke);
    canvas.drawPath(_segments.transform(place), stroke..color = accent.withValues(alpha: 0.12 * 0.55));
  }

  @override
  bool shouldRepaint(LockArtPainter old) => old.panel != panel || old.accent != accent || old.phone != phone;
}

/// A matrix that scales by [sx] and [sy], then moves by [to].
Float64List _scaleThenMove(double sx, double sy, Offset to) => Float64List.fromList([
      sx, 0, 0, 0, //
      0, sy, 0, 0, //
      0, 0, 1, 0, //
      to.dx, to.dy, 0, 1,
    ]);

/// The slice in a box 100 wide: its rind (two rings), its heart, and the six
/// lines between its segments.
final Path _slice = Path()
  ..addOval(Rect.fromCircle(center: const Offset(50, 50), radius: 48))
  ..addOval(Rect.fromCircle(center: const Offset(50, 50), radius: 44.5))
  ..addOval(Rect.fromCircle(center: const Offset(50, 50), radius: 4))
  ..moveTo(50, 46)
  ..lineTo(50, 7.5)
  ..moveTo(53.5, 48.1)
  ..lineTo(86.8, 28.8)
  ..moveTo(53.5, 51.9)
  ..lineTo(86.8, 71.2)
  ..moveTo(50, 54)
  ..lineTo(50, 92.5)
  ..moveTo(46.5, 51.9)
  ..lineTo(13.2, 71.2)
  ..moveTo(46.5, 48.1)
  ..lineTo(13.2, 28.8);

/// The curves of the six segments, drawn fainter than the rest.
final Path _segments = Path()
  ..moveTo(50, 12)
  ..cubicTo(56, 22, 57, 34, 52, 44)
  ..moveTo(83, 32)
  ..cubicTo(72, 33, 62, 39, 56, 48)
  ..moveTo(83, 68)
  ..cubicTo(72, 67, 62, 61, 56, 52)
  ..moveTo(50, 88)
  ..cubicTo(56, 78, 57, 66, 52, 56)
  ..moveTo(17, 68)
  ..cubicTo(28, 67, 38, 61, 44, 52)
  ..moveTo(17, 32)
  ..cubicTo(28, 33, 38, 39, 44, 48);

/// The seam the doors part along, top to bottom: a gentle bow, like the edge of a
/// citrus segment (x = 50% + 4.5% sin(pi y), y from 0 to 1).
List<Offset> lockSeamPoints(Size size) => [
      for (var i = 0; i <= 40; i++)
        Offset(size.width * (0.5 + 0.045 * math.sin(math.pi * i / 40)), size.height * i / 40),
    ];

/// The seam as a line, for its glow while the doors part.
Path lockSeamPath(Size size) {
  final points = lockSeamPoints(size);
  final path = Path()..moveTo(points.first.dx, points.first.dy);
  for (final p in points.skip(1)) {
    path.lineTo(p.dx, p.dy);
  }
  return path;
}

/// Clips a copy of the art to one door: the left of the seam, or the right of it.
/// The left door reaches a hair past the seam, so no line shows between the two
/// while they are shut.
class LockDoorClipper extends CustomClipper<Path> {
  const LockDoorClipper({required this.left});

  final bool left;

  @override
  Path getClip(Size size) {
    final seam = lockSeamPoints(size);
    final path = Path();
    if (left) {
      path.moveTo(0, 0);
      for (final p in seam) {
        path.lineTo(p.dx + size.width * 0.0025, p.dy);
      }
      path.lineTo(0, size.height);
    } else {
      path.moveTo(seam.first.dx, seam.first.dy);
      for (final p in seam.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      path
        ..lineTo(size.width, size.height)
        ..lineTo(size.width, 0);
    }
    return path..close();
  }

  @override
  bool shouldReclip(LockDoorClipper old) => old.left != left;
}

/// The seam's glow: the accent along the seam, drawn from the top down to
/// [drawn] (0 to 1) of its length, at [opacity].
class LockSeamPainter extends CustomPainter {
  LockSeamPainter({required this.accent, required this.drawn, required this.opacity});

  final Color accent;
  final double drawn;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0 || drawn <= 0 || size.isEmpty) return;
    final whole = lockSeamPath(size);
    var path = whole;
    if (drawn < 1) {
      path = Path();
      for (final metric in whole.computeMetrics()) {
        path.addPath(metric.extractPath(0, metric.length * drawn), Offset.zero);
      }
    }
    final color = accent.withValues(alpha: opacity.clamp(0.0, 1.0));
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..color = color.withValues(alpha: color.a * 0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(LockSeamPainter old) => old.accent != accent || old.drawn != drawn || old.opacity != opacity;
}
