// Remote screens (4.0): the remote pointer, and a mouse or trackpad driving it.
// Every button the remote protocol has (RFB: left, middle, right, the wheel's
// four directions, back), a wheel notch per mouse wheel step, a trackpad's
// smooth scrolling gathered into notches, and a trackpad's pinch as zoom.
import 'package:flutter/gestures.dart';

import 'screen_viewport.dart';

/// The remote pointer's buttons, as the remote protocol numbers them.
abstract final class ScreenButtons {
  static const left = 1;
  static const middle = 2;
  static const right = 4;
  static const wheelUp = 8;
  static const wheelDown = 16;
  static const wheelLeft = 32;
  static const wheelRight = 64;

  /// The mouse's back button (button 8 in X's numbering). Forward has no bit.
  static const back = 128;

  /// Flutter's buttons ([PointerEvent.buttons]) to the remote's.
  static int fromFlutter(int buttons) =>
      (buttons & kPrimaryButton != 0 ? left : 0) |
      (buttons & kMiddleMouseButton != 0 ? middle : 0) |
      (buttons & kSecondaryButton != 0 ? right : 0) |
      (buttons & kBackMouseButton != 0 ? back : 0);
}

/// The remote pointer: where it was last sent (remote pixels) with the
/// buttons held. Nothing goes while [enabled] is false (view only).
class ScreenPointer {
  ScreenPointer(this._send);

  final void Function(int x, int y, int buttons) _send;

  int x = 0;
  int y = 0;
  int buttons = 0;

  /// A position has been sent: the remote pointer is somewhere we know.
  bool placed = false;
  bool enabled = true;

  void send(int x, int y, int buttons) {
    if (!enabled) return;
    this.x = x;
    this.y = y;
    this.buttons = buttons;
    placed = true;
    _send(x, y, buttons);
  }

  /// A click of [button] at ([x], [y]): there, down, up.
  void click(int x, int y, int button) {
    send(x, y, 0);
    send(x, y, button);
    send(x, y, 0);
  }

  /// [notches] turns of the wheel ([bit], one of the four wheel buttons) at
  /// ([x], [y]), the buttons held kept.
  void wheel(int x, int y, int bit, [int notches = 1]) {
    final held = buttons & ~(ScreenButtons.wheelUp | ScreenButtons.wheelDown | ScreenButtons.wheelLeft | ScreenButtons.wheelRight);
    for (var i = 0; i < notches; i++) {
      send(x, y, held | bit);
      send(x, y, held);
    }
  }

  /// Lets go of every button held (the view hidden, focus gone).
  void release() {
    if (buttons != 0) send(x, y, 0);
  }
}

/// Wheel notches out of a smooth scroll: one notch per [step] logical pixels,
/// the rest kept for the next movement.
class WheelAccumulator {
  WheelAccumulator({this.step = 24});

  final double step;
  double _x = 0;
  double _y = 0;

  void reset() => _x = _y = 0;

  /// Adds a content movement ([delta], logical pixels, as the content moves:
  /// fingers or content up is negative) and returns the notches it makes,
  /// as (bit, count) pairs. Content moving up shows what is below: the
  /// wheel turns down, as on a phone or a trackpad with natural scrolling.
  List<(int, int)> add(Offset delta) {
    _x += delta.dx;
    _y += delta.dy;
    final out = <(int, int)>[];
    final ny = (_y.abs() / step).floor();
    if (ny > 0) {
      out.add((_y < 0 ? ScreenButtons.wheelDown : ScreenButtons.wheelUp, ny));
      _y -= _y.sign * ny * step;
    }
    final nx = (_x.abs() / step).floor();
    if (nx > 0) {
      out.add((_x < 0 ? ScreenButtons.wheelRight : ScreenButtons.wheelLeft, nx));
      _x -= _x.sign * nx * step;
    }
    return out;
  }
}

/// A mouse or a trackpad over the picture.
class ScreenMouse {
  ScreenMouse({required this.viewport, required this.pointer, required this.changed});

  final ScreenViewport viewport;
  final ScreenPointer pointer;

  /// The picture moved (a pan or a zoom): repaint.
  final void Function() changed;

  /// While the pointer is this close to an edge of a picture larger than the
  /// view, moving toward the edge pans the picture (one to one, or zoomed).
  static const edge = 24.0;

  final _wheel = WheelAccumulator();
  double _panZoomStartZoom = 1;
  Offset _panZoomAnchor = Offset.zero;

  /// Hover, move, down or up: the remote pointer goes where it is.
  void event(PointerEvent e) {
    final (x, y) = viewport.toRemote(e.localPosition);
    pointer.send(x, y, ScreenButtons.fromFlutter(e.buttons));
    if (e is PointerMoveEvent || e is PointerHoverEvent) _edgePan(e.localPosition, e.delta);
    // The cursor drawn at the pointer follows it.
    changed();
  }

  void _edgePan(Offset at, Offset delta) {
    final view = viewport.viewSize, rect = viewport.pictureRect;
    var dx = 0.0, dy = 0.0;
    if (at.dx < edge && delta.dx < 0 && rect.left < 0) dx = -delta.dx * 2;
    if (at.dx > view.width - edge && delta.dx > 0 && rect.right > view.width) dx = -delta.dx * 2;
    if (at.dy < edge && delta.dy < 0 && rect.top < 0) dy = -delta.dy * 2;
    if (at.dy > view.height - edge && delta.dy > 0 && rect.bottom > view.height) dy = -delta.dy * 2;
    if (dx != 0 || dy != 0) viewport.panBy(Offset(dx, dy));
  }

  /// The wheel. A mouse's wheel gives one notch per step, whatever distance
  /// the system turns it into; a trackpad's scroll (or a mouse with smooth
  /// scrolling, which reports as one) is gathered into notches.
  void signal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final (x, y) = viewport.toRemote(e.localPosition);
    final d = e.scrollDelta;
    if (e.kind == PointerDeviceKind.mouse) {
      if (d.dy != 0) pointer.wheel(x, y, d.dy < 0 ? ScreenButtons.wheelUp : ScreenButtons.wheelDown);
      if (d.dx != 0) pointer.wheel(x, y, d.dx < 0 ? ScreenButtons.wheelLeft : ScreenButtons.wheelRight);
      return;
    }
    // scrollDelta says where the view would go; the content goes the other way.
    _notches(x, y, -d);
  }

  void _notches(int x, int y, Offset contentDelta) {
    for (final (bit, n) in _wheel.add(contentDelta)) {
      pointer.wheel(x, y, bit, n);
    }
  }

  // A trackpad's two fingers (Windows' precision touchpads, macOS): pan as
  // the wheel, pinch as zoom about the pointer.
  void panZoomStart(PointerPanZoomStartEvent e) {
    _wheel.reset();
    _panZoomStartZoom = viewport.zoom;
    _panZoomAnchor = viewport.toRemoteOffset(e.localPosition);
  }

  void panZoomUpdate(PointerPanZoomUpdateEvent e) {
    if ((e.scale - 1).abs() > 0.05) {
      viewport.zoomTo(_panZoomStartZoom * e.scale, _panZoomAnchor, e.localPosition);
      changed();
      return;
    }
    final (x, y) = viewport.toRemote(e.localPosition);
    _notches(x, y, e.panDelta);
  }

  void panZoomEnd(PointerPanZoomEndEvent e) => _wheel.reset();
}
