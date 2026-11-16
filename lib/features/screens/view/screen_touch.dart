// Remote screens (4.0): fingers on the picture. Raw pointer events through a
// small state machine (no gesture arena, so nothing waits on a recognizer),
// the spike's (day 4), in two modes:
//
// | Gesture             | Touch                        | Mouse pointer (a trackpad)                  |
// |---------------------|------------------------------|---------------------------------------------|
// | Tap                 | click where the finger is    | click at the pointer                        |
// | Double tap          | double click there           | double click at the pointer                 |
// | Hold 500 ms         | right click there            | lift: right click; drag: left drag          |
// | One-finger drag     | left drag                    | moves the pointer by the finger's distance  |
// | Two-finger drag     | wheel, a notch per 24 px     | the same, at the pointer                    |
// | Pinch               | zoom about the fingers       | the same                                    |
// | Two-finger tap      | right click                  | right click                                 |
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';

import 'screen_pointer.dart';
import 'screen_viewport.dart';

/// How a finger drives the remote pointer.
enum ScreenTouchMode {
  /// Taps click where the finger is; hold for a right click, drag for a left drag.
  touch,

  /// A trackpad: a finger moves the pointer, a tap clicks where it is; hold
  /// then drag for a left drag, hold and lift for a right click.
  mousePointer,
}

enum _Gesture { none, one, move, drag, two, zoom, scroll, three, done }

class ScreenTouch {
  ScreenTouch({required this.viewport, required this.pointer, required this.changed, this.onHold});

  final ScreenViewport viewport;
  final ScreenPointer pointer;

  /// The picture or the drawn pointer moved: repaint.
  final void Function() changed;

  /// A hold became a right click (Touch) or was recognised (Mouse pointer):
  /// the view gives a haptic tick.
  void Function()? onHold;

  ScreenTouchMode mode = ScreenTouchMode.touch;

  /// Pinch and pan only, nothing sent (view only).
  bool sendInput = true;

  /// Relative mouse in Mouse pointer mode (4.0): a finger's
  /// movement goes to the remote as movement ([sendRelative]), not as a
  /// place, and so do its clicks, its drags and the wheel. For a game or
  /// a 3D program, which turns its view by how far the mouse moved. Touch
  /// mode is as it is: a finger on a pixel is a place.
  bool get relative => _relative;
  bool _relative = false;
  set relative(bool on) {
    if (_relative == on) return;
    // A drag under way lets go of its button the way it pressed it.
    cancel();
    _relative = on;
    _rx = _ry = 0;
  }

  /// Movement to the remote as movement: (dx, dy) with these buttons down.
  void Function(int dx, int dy, int buttons)? sendRelative;

  /// How many of the mouse's counts one logical pixel of a finger's way
  /// is: a swipe across a phone is about an inch of a mouse's travel.
  static const relativeSpeed = 2.0;

  // Parts of a count that wait for the next movement.
  double _rx = 0;
  double _ry = 0;

  bool get _rel => _relative && mode == ScreenTouchMode.mousePointer && sendRelative != null;

  /// Three fingers moved sideways (4.0): to the left is the next of
  /// the remote's displays (true), to the right the one before. It is the
  /// one thing three fingers mean, in every touch mode. Null, as it is
  /// while the remote has one display: a third finger changes nothing.
  void Function(bool next)? onDisplaySwipe;

  /// How far three fingers go sideways before the display changes.
  static const displaySwipe = 56.0;

  static const slop = 10.0;
  static const holdTime = Duration(milliseconds: 500);
  static const scrollStep = 24.0;

  /// A second tap this soon and this close clicks the first one's pixel, so
  /// the remote sees a double click however the finger landed.
  static const doubleTapTime = Duration(milliseconds: 400);
  static const doubleTapDistance = 24.0;

  /// Two fingers lifted within this of touching down: a right click.
  static const twoFingerTapTime = Duration(milliseconds: 400);

  /// How far apart the fingers must spread or close (a share of where they
  /// started) before two fingers zoom instead of scrolling.
  static const pinchStart = 0.12;

  final Map<int, Offset> _touches = {};
  _Gesture _g = _Gesture.none;
  Offset _start = Offset.zero;
  Timer? _hold;
  bool _held = false;
  double _startSpan = 1;
  Offset _startCentroid = Offset.zero;
  Offset _lastCentroid = Offset.zero;
  double _startZoom = 1;
  Offset _anchor = Offset.zero;
  Duration _twoStart = Duration.zero;
  Offset _threeStart = Offset.zero;
  final _wheel = WheelAccumulator(step: scrollStep);

  // The last tap, for a double tap: where (in the view), when, and the pixel it clicked.
  Offset? _lastTapAt;
  Duration _lastTapTime = Duration.zero;
  (int, int) _lastTapPixel = (0, 0);

  /// The pointer in Mouse pointer mode, in remote pixels (fractions kept while
  /// a finger moves it).
  double _px = 0;
  double _py = 0;

  /// Where the drawn pointer is in Mouse pointer mode (remote pixels).
  (int, int) get pointerPosition => (
    _px.round().clamp(0, math.max(0, viewport.remoteWidth - 1)),
    _py.round().clamp(0, math.max(0, viewport.remoteHeight - 1)),
  );

  /// Puts the Mouse pointer mode's pointer at a remote pixel (a reconnect
  /// keeps it where it was).
  void placePointer(int x, int y) {
    _px = x.toDouble();
    _py = y.toDouble();
  }

  bool get active => _touches.isNotEmpty;

  /// The middle of every finger down.
  Offset get _middle => _touches.values.reduce((a, b) => a + b) / _touches.length.toDouble();

  Offset get _centroid {
    final p = _touches.values.take(2).toList();
    return (p[0] + p[1]) / 2;
  }

  double get _span {
    final p = _touches.values.take(2).toList();
    return math.max(1.0, (p[0] - p[1]).distance);
  }

  void _send(int x, int y, int buttons) {
    if (!sendInput) return;
    // Relative: the buttons, where the remote's pointer is.
    if (_rel) return sendRelative!(0, 0, buttons);
    pointer.send(x, y, buttons);
  }

  void _click(int x, int y, int button) {
    if (!sendInput) return;
    if (_rel) {
      sendRelative!(0, 0, button);
      sendRelative!(0, 0, 0);
      return;
    }
    pointer.click(x, y, button);
  }

  void _wheelAt(int x, int y, int bit, int notches) {
    if (!sendInput) return;
    if (_rel) {
      for (var i = 0; i < notches; i++) {
        sendRelative!(0, 0, bit);
        sendRelative!(0, 0, 0);
      }
      return;
    }
    pointer.wheel(x, y, bit, notches);
  }

  void down(PointerDownEvent e) {
    _touches[e.pointer] = e.localPosition;
    if (_touches.length == 1) {
      _g = _Gesture.one;
      _start = e.localPosition;
      _held = false;
      _hold?.cancel();
      _hold = Timer(holdTime, _onHold);
    } else if (_touches.length == 2 && (_g == _Gesture.one || _g == _Gesture.move)) {
      _hold?.cancel();
      _g = _Gesture.two;
      _startSpan = _span;
      _startCentroid = _lastCentroid = _centroid;
      _startZoom = viewport.zoom;
      _anchor = viewport.toRemoteOffset(_startCentroid);
      _wheel.reset();
      _twoStart = e.timeStamp;
    } else if (_touches.length == 3 &&
        onDisplaySwipe != null &&
        (_g == _Gesture.two || _g == _Gesture.zoom || _g == _Gesture.scroll)) {
      // A third finger: no longer a pinch, a scroll or a right click.
      _g = _Gesture.three;
      _threeStart = _middle;
    }
  }

  void _onHold() {
    if (_g != _Gesture.one) return;
    _held = true;
    onHold?.call();
    if (mode == ScreenTouchMode.touch) {
      final (x, y) = viewport.toRemote(_start);
      _click(x, y, ScreenButtons.right);
      _g = _Gesture.done;
      changed();
    }
    // Mouse pointer: a drag (a left drag) or the lift (a right click) decides.
  }

  void _movePointerBy(Offset localDelta, int buttons) {
    if (_rel) {
      // How far, not where: the picture's zoom means nothing to it, and no
      // pointer of this device is moved or kept in view.
      if (!sendInput) return;
      _rx += localDelta.dx * relativeSpeed;
      _ry += localDelta.dy * relativeSpeed;
      final (dx, dy) = (_rx.truncate(), _ry.truncate());
      if (dx == 0 && dy == 0) return;
      _rx -= dx;
      _ry -= dy;
      sendRelative!(dx, dy, buttons);
      return;
    }
    final s = viewport.scale;
    _px = (_px + localDelta.dx / s).clamp(0, math.max(0, viewport.remoteWidth - 1).toDouble());
    _py = (_py + localDelta.dy / s).clamp(0, math.max(0, viewport.remoteHeight - 1).toDouble());
    final (x, y) = pointerPosition;
    _send(x, y, buttons);
    // The pointer kept in view: the picture pans when it nears an edge.
    final l = viewport.toLocal(x.toDouble(), y.toDouble());
    const m = 24.0;
    final v = viewport.viewSize;
    final dx = l.dx < m ? m - l.dx : (l.dx > v.width - m ? v.width - m - l.dx : 0.0);
    final dy = l.dy < m ? m - l.dy : (l.dy > v.height - m ? v.height - m - l.dy : 0.0);
    if (dx != 0 || dy != 0) viewport.panBy(Offset(dx, dy));
    changed();
  }

  void move(PointerMoveEvent e) {
    final prev = _touches[e.pointer];
    if (prev == null) return;
    final pos = e.localPosition;
    _touches[e.pointer] = pos;
    switch (_g) {
      case _Gesture.one:
        if ((pos - _start).distance <= slop) return;
        _hold?.cancel();
        if (mode == ScreenTouchMode.touch) {
          // A left drag from where the finger went down.
          final (sx, sy) = viewport.toRemote(_start);
          _send(sx, sy, 0);
          _send(sx, sy, ScreenButtons.left);
          final (x, y) = viewport.toRemote(pos);
          _send(x, y, ScreenButtons.left);
          _g = _Gesture.drag;
        } else if (_held) {
          // After a hold: a left drag from the pointer.
          final (x, y) = pointerPosition;
          _send(x, y, ScreenButtons.left);
          _g = _Gesture.drag;
          _movePointerBy(pos - _start, ScreenButtons.left);
        } else {
          _g = _Gesture.move;
          _movePointerBy(pos - _start, 0);
        }
      case _Gesture.move:
        _movePointerBy(pos - prev, 0);
      case _Gesture.drag:
        if (mode == ScreenTouchMode.touch) {
          final (x, y) = viewport.toRemote(pos);
          _send(x, y, ScreenButtons.left);
        } else {
          _movePointerBy(pos - prev, ScreenButtons.left);
        }
      case _Gesture.two:
        if (_touches.length < 2) return;
        final c = _centroid;
        if ((_span / _startSpan - 1).abs() > pinchStart) {
          _g = _Gesture.zoom;
          viewport.zoomTo(_startZoom * _span / _startSpan, _anchor, c);
          changed();
        } else if ((c - _startCentroid).distance > slop) {
          _g = _Gesture.scroll;
          _lastCentroid = c;
        }
      case _Gesture.zoom:
        if (_touches.length < 2) return;
        // Zoom about the fingers, and pan with them: the remote point first
        // under them stays under them.
        viewport.zoomTo(_startZoom * _span / _startSpan, _anchor, _centroid);
        changed();
      case _Gesture.scroll:
        if (_touches.length < 2) return;
        final c = _centroid;
        final delta = c - _lastCentroid;
        _lastCentroid = c;
        final (x, y) = mode == ScreenTouchMode.touch ? viewport.toRemote(c) : pointerPosition;
        // Only the vertical wheel: a sideways wobble of two fingers is not a
        // sideways scroll.
        for (final (bit, n) in _wheel.add(Offset(0, delta.dy))) {
          _wheelAt(x, y, bit, n);
        }
      case _Gesture.three:
        if (_touches.length < 3) return;
        final d = _middle - _threeStart;
        // Sideways, and more sideways than up or down.
        if (d.dx.abs() >= displaySwipe && d.dx.abs() > d.dy.abs() * 2) {
          // Once for these fingers: they are done whatever they do next.
          _g = _Gesture.done;
          onDisplaySwipe?.call(d.dx < 0);
        }
      case _Gesture.none:
      case _Gesture.done:
    }
  }

  void up(PointerEvent e, {bool cancelled = false}) {
    if (_touches.remove(e.pointer) == null) return;
    switch (_g) {
      case _Gesture.one:
        _hold?.cancel();
        if (cancelled) break;
        if (mode == ScreenTouchMode.touch) {
          _tap(viewport.toRemote(_start), _start, e.timeStamp);
        } else {
          final (x, y) = pointerPosition;
          _click(x, y, _held ? ScreenButtons.right : ScreenButtons.left);
          changed();
        }
      case _Gesture.drag:
        _send(pointer.x, pointer.y, 0);
      case _Gesture.two:
        // Two fingers tapped together: a right click.
        if (!cancelled && e.timeStamp - _twoStart < twoFingerTapTime) {
          final (x, y) = mode == ScreenTouchMode.touch ? viewport.toRemote(_lastCentroid) : pointerPosition;
          _click(x, y, ScreenButtons.right);
          changed();
        }
      case _Gesture.move:
      case _Gesture.zoom:
      case _Gesture.scroll:
      case _Gesture.three:
      case _Gesture.none:
      case _Gesture.done:
    }
    _g = _touches.isEmpty ? _Gesture.none : _Gesture.done;
  }

  void _tap((int, int) pixel, Offset at, Duration time) {
    final last = _lastTapAt;
    // A double tap: the second click on the first's pixel.
    final again = last != null &&
        time - _lastTapTime <= doubleTapTime &&
        time >= _lastTapTime &&
        (at - last).distance <= doubleTapDistance;
    final (x, y) = again ? _lastTapPixel : pixel;
    _click(x, y, ScreenButtons.left);
    _lastTapAt = again ? null : at;
    _lastTapTime = time;
    _lastTapPixel = (x, y);
    changed();
  }

  /// Forgets the fingers (the view hidden or the session paused): a drag in
  /// progress lets go of its button.
  void cancel() {
    _hold?.cancel();
    if (_g == _Gesture.drag) _send(pointer.x, pointer.y, 0);
    _touches.clear();
    _g = _Gesture.none;
  }

  void dispose() => _hold?.cancel();
}
