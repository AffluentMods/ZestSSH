// Remote screens (4.0): where the remote picture sits in its view. A base scale
// from the scaling mode (fit, fill, one to one), the person's zoom on top of
// it, and an origin (the remote's top left in the view's logical pixels) kept
// in bounds. Smaller than the view, the picture is centred on whole logical
// pixels inside the safe area; larger (zoomed), it may go under the edges and
// pans within its own bounds. Remote pixels in, logical pixels out, and back.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// How the picture is scaled in its view.
enum ScreenFit {
  /// The whole remote screen visible, never above one remote pixel per
  /// logical pixel (a small remote desktop stays sharp in a big window).
  fit,

  /// The whole remote screen visible and as large as the view allows,
  /// keeping its shape (a small remote desktop is enlarged).
  fill,

  /// One remote pixel per pixel of this display (device pixels), as the
  /// remote's own monitor shows it; larger than the view, it pans.
  oneToOne,
}

class ScreenViewport {
  /// At most this many logical pixels per remote pixel, zoomed in.
  static const maxScale = 4.0;

  ScreenFit fit = ScreenFit.fit;

  /// The remote screen's size in its own pixels (0 until it is known).
  int remoteWidth = 0;
  int remoteHeight = 0;

  Size _view = Size.zero;
  EdgeInsets _insets = EdgeInsets.zero;
  double _dpr = 1;

  /// The person's zoom on top of the base scale (1: none).
  double _zoom = 1;
  Offset _origin = Offset.zero;

  Size get viewSize => _view;
  EdgeInsets get insets => _insets;
  double get devicePixelRatio => _dpr;
  bool get hasRemote => remoteWidth > 0 && remoteHeight > 0;

  /// The view's size, the part of it kept clear at fit ([insets]: the safe
  /// area of a phone's notch and gesture edges) and its device pixel ratio.
  void setView(Size size, {EdgeInsets insets = EdgeInsets.zero, double devicePixelRatio = 1}) {
    _view = size;
    _insets = insets;
    _dpr = devicePixelRatio > 0 ? devicePixelRatio : 1;
  }

  void setRemote(int width, int height) {
    remoteWidth = math.max(0, width);
    remoteHeight = math.max(0, height);
  }

  Rect get _inner {
    final r = _insets.deflateRect(Offset.zero & _view);
    return r.width > 0 && r.height > 0 ? r : Offset.zero & _view;
  }

  /// Logical pixels per remote pixel before the zoom.
  double get baseScale {
    if (!hasRemote || _view.isEmpty) return 1;
    final inner = _inner;
    final whole = math.min(inner.width / remoteWidth, inner.height / remoteHeight);
    return switch (fit) {
      ScreenFit.fit => math.min(1.0, whole),
      ScreenFit.fill => math.min(maxScale, whole),
      ScreenFit.oneToOne => 1 / _dpr,
    };
  }

  double get maxZoom => math.max(1.0, maxScale / baseScale);
  double get zoom => _zoom.clamp(1.0, maxZoom);
  bool get isZoomed => zoom > 1.0001;

  /// Logical pixels per remote pixel.
  double get scale => baseScale * zoom;

  /// The remote screen's top left in the view, in bounds.
  Offset get origin => _clamp(_origin);

  /// The picture's rectangle in the view.
  Rect get pictureRect => origin & Size(remoteWidth * scale, remoteHeight * scale);

  Offset _clamp(Offset o) {
    final s = scale, inner = _inner;
    // [slack]: how far up the picture may go past its bounds (the keyboard).
    double axis(double v, double content, double view, double innerStart, double innerExtent, double slack) {
      // Smaller than the safe area: centred in it, on a whole logical pixel.
      // (A hair over, as 800 x 0.51375 comes out, is still the same size.)
      if (content <= innerExtent + 1e-6) {
        final centred = (innerStart + math.max(0.0, innerExtent - content) / 2).floorToDouble();
        return slack == 0 ? centred : v.clamp(centred - slack, centred);
      }
      // Larger: anywhere that leaves no gap inside the view.
      final lo = math.min(0.0, view - content), hi = math.max(0.0, view - content);
      return v.clamp(lo - slack, hi);
    }

    return Offset(
      axis(o.dx, remoteWidth * s, _view.width, inner.left, inner.width, 0),
      axis(o.dy, remoteHeight * s, _view.height, inner.top, inner.height, _obscuredBottom),
    );
  }

  /// The remote pixel under [local] (a point in the view), inside the screen.
  (int, int) toRemote(Offset local) {
    final p = (local - origin) / scale;
    return (
      p.dx.floor().clamp(0, math.max(0, remoteWidth - 1)),
      p.dy.floor().clamp(0, math.max(0, remoteHeight - 1)),
    );
  }

  /// [local] in remote pixels, fractions kept and not limited to the screen.
  Offset toRemoteOffset(Offset local) => (local - origin) / scale;

  /// Where the remote point ([x], [y]) is in the view.
  Offset toLocal(double x, double y) => origin + Offset(x, y) * scale;

  /// Zooms to [zoom] keeping the remote point [anchor] (remote pixels) under
  /// [focal] (the view's), as a pinch does.
  void zoomTo(double zoom, Offset anchor, Offset focal) {
    _zoom = zoom.clamp(1.0, maxZoom);
    _origin = _clamp(focal - anchor * scale);
  }

  /// Moves the picture by [delta] (logical pixels), within its bounds.
  void panBy(Offset delta) => _origin = _clamp(origin + delta);

  /// Back to the base scale, the whole screen in view (at fit).
  /// What the person made of the view: its scaling, zoom and where it is
  /// panned ([restore] gives them to the view of the same screen connected
  /// again).
  ScreenViewKept kept() => ScreenViewKept(fit: fit, zoom: _zoom, origin: _origin);

  /// Back to what [kept] took. The zoom and the origin are kept in bounds as
  /// they are read, so a remote screen that came back another size is never
  /// shown out of its view.
  void restore(ScreenViewKept kept) {
    fit = kept.fit;
    _zoom = kept.zoom;
    _origin = kept.origin;
  }

  void resetZoom() {
    _zoom = 1;
    _origin = _clamp(_origin);
  }

  /// The bottom of the view a soft keyboard covers, in logical pixels. The
  /// picture keeps its size (it never shrinks to a strip above the keyboard)
  /// and may slide up by this much, so what is under the keyboard can be
  /// brought above it ([reveal]).
  double get obscuredBottom => _obscuredBottom;
  double _obscuredBottom = 0;
  set obscuredBottom(double value) {
    final o = origin;
    _obscuredBottom = math.max(0, value);
    _origin = o;
  }

  /// Pans so the remote point ([x], [y]) is at least [margin] logical pixels
  /// inside the part of the view the keyboard leaves ([obscuredBottom]).
  /// Nothing moves for a point already there, or along an axis where the
  /// picture cannot move.
  void reveal(double x, double y, {double margin = 24}) {
    final p = toLocal(x, y);
    final visible = Rect.fromLTWH(0, 0, _view.width, math.max(0, _view.height - _obscuredBottom));
    final m = math.min(margin, visible.shortestSide / 4);
    final r = visible.deflate(m);
    if (r.isEmpty) return;
    final dx = p.dx < r.left ? r.left - p.dx : (p.dx > r.right ? r.right - p.dx : 0.0);
    final dy = p.dy < r.top ? r.top - p.dy : (p.dy > r.bottom ? r.bottom - p.dy : 0.0);
    if (dx != 0 || dy != 0) panBy(Offset(dx, dy));
  }
}

/// A view's scaling, zoom and pan, kept across a reconnect ([ScreenViewport.kept]).
class ScreenViewKept {
  const ScreenViewKept({required this.fit, required this.zoom, required this.origin});

  final ScreenFit fit;
  final double zoom;
  final Offset origin;
}
