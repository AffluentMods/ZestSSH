// The screen widget, path A: the Rust engine keeps the picture and hands over the tiles that
// changed (RGBA, opaque); each becomes a ui.Image (ImmutableBuffer + ImageDescriptor.raw, nothing
// decoded in Dart) drawn by a CustomPainter. Input goes the other way: pointer and keys to the
// engine, in remote pixels, X keysyms and scancodes. The view's size goes too (RDP resizes the
// desktop to it where the server allows). On phones: two touch modes (TouchMode), pinch to zoom
// and pan, and the soft keyboard's text (SoftKeyboard).
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:zest_native/screen.dart';

import 'keysyms.dart';

class _Tile {
  _Tile(this.x, this.y, this.image);
  final int x;
  final int y;
  final ui.Image image;
}

/// One painted frame's timings (microseconds on [ScreenSession.nowUs]'s clock).
class FrameTimes {
  FrameTimes(this.firstChangeUs, this.lastDoneUs, this.takenUs, this.imagesUs, this.paintedUs, this.tiles, this.bytes,
      this.updates);
  final int firstChangeUs;
  final int lastDoneUs;
  final int takenUs;
  final int imagesUs;
  final int paintedUs;
  final int tiles;
  final int bytes;
  final int updates;
}

/// Holds the tiles' images and turns frames from the session into them.
class ScreenController extends ChangeNotifier {
  ScreenController(this.session) {
    _sub = session.events.listen(_onEvent);
  }

  final ScreenSession session;
  late final StreamSubscription<ScreenEvent> _sub;
  final Map<int, _Tile> _tiles = {};
  int width = 0;
  int height = 0;
  int _tilesWidth = 0;
  int _tilesHeight = 0;
  bool _busy = false;
  bool _again = false;

  /// Every painted frame, for the measurements (the caller clears it).
  final List<FrameTimes> painted = [];
  void Function(String)? onClosed;

  /// The view's last layout: remote pixels to the view's local ones.
  double scale = 1;
  Offset origin = Offset.zero;

  /// While paused (the app in the background) frames stay in the engine, which merges them; on
  /// resume the latest picture is taken at once.
  bool _paused = false;
  bool get paused => _paused;
  set paused(bool v) {
    if (_paused == v) return;
    _paused = v;
    if (!v) _pull();
  }

  void _onEvent(ScreenEvent e) {
    switch (e) {
      case ScreenFrameReady():
        if (!_paused) _pull();
      case ScreenResized(:final width, :final height):
        this.width = width;
        this.height = height;
      case ScreenConnected(:final info):
        width = (info['width'] as num).toInt();
        height = (info['height'] as num).toInt();
      case ScreenClosed(:final error):
        onClosed?.call(error ?? 'closed');
      default:
    }
  }

  Future<void> _pull() async {
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    try {
      do {
        _again = false;
        final frame = session.takeFrame();
        if (frame == null) break;
        try {
          final images = await Future.wait(frame.tiles.map(_image));
          final imagesUs = ScreenSession.nowUs();
          // A new size: the frame holds every tile; the old ones go.
          if (frame.width != _tilesWidth || frame.height != _tilesHeight) {
            _clear();
            _tilesWidth = width = frame.width;
            _tilesHeight = height = frame.height;
          }
          for (var i = 0; i < images.length; i++) {
            final t = frame.tiles[i];
            // The whole screen as one image (Rust sends it when most tiles changed): it goes
            // under every tile, and the tiles it covers are dropped.
            final whole = t.width == frame.width && t.height == frame.height;
            if (whole) _clear();
            final key = whole ? -1 : t.y << 16 | t.x;
            _tiles.remove(key)?.image.dispose();
            _tiles[key] = _Tile(t.x, t.y, images[i]);
          }
          final first = frame.firstChangeUs, done = frame.lastDoneUs, taken = frame.takenUs;
          final n = frame.tiles.length, bytes = frame.bytes, updates = frame.updates;
          SchedulerBinding.instance.addPostFrameCallback((_) {
            painted.add(FrameTimes(first, done, taken, imagesUs, ScreenSession.nowUs(), n, bytes, updates));
          });
          notifyListeners();
        } finally {
          frame.free();
        }
      } while (_again);
    } finally {
      _busy = false;
    }
  }

  static Future<ui.Image> _image(ScreenTile t) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(t.pixels);
    final descriptor = ui.ImageDescriptor.raw(buffer, width: t.width, height: t.height, pixelFormat: ui.PixelFormat.rgba8888);
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return frame.image;
  }

  void _clear() {
    for (final t in _tiles.values) {
      t.image.dispose();
    }
    _tiles.clear();
  }

  // Input, in remote pixels.
  int _buttons = 0;
  int _lastX = 0;
  int _lastY = 0;
  /// What each held key sent at its key down: (keysym, scancode).
  final Map<PhysicalKeyboardKey, (int, int)> _down = {};

  (int, int) toRemote(Offset local) {
    final p = (local - origin) / scale;
    return (p.dx.floor().clamp(0, math.max(0, width - 1)), p.dy.floor().clamp(0, math.max(0, height - 1)));
  }

  Offset toLocal(int x, int y) => origin + Offset(x + 0.5, y + 0.5) * scale;

  static int _vncButtons(int flutter) =>
      (flutter & kPrimaryButton != 0 ? 1 : 0) |
      (flutter & kMiddleMouseButton != 0 ? 2 : 0) |
      (flutter & kSecondaryButton != 0 ? 4 : 0);

  /// When set, pointer events of other devices are dropped (the self-test's synthetic mouse,
  /// so the real one resting on the window cannot move the remote pointer meanwhile).
  int? onlyDevice;

  /// A mouse (or trackpad) event: the remote pointer goes where it is.
  void pointer(PointerEvent e) {
    if (onlyDevice != null && e.device != onlyDevice) return;
    final (x, y) = toRemote(e.localPosition);
    _lastX = x;
    _lastY = y;
    _px = x.toDouble();
    _py = y.toDouble();
    _buttons = _vncButtons(e.buttons);
    session.pointer(x, y, _buttons);
  }

  void scroll(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    if (onlyDevice != null && e.device != onlyDevice) return;
    final (x, y) = toRemote(e.localPosition);
    final bit = e.scrollDelta.dy < 0 ? 8 : 16;
    session.pointer(x, y, _buttons | bit);
    session.pointer(x, y, _buttons);
    _lastX = x;
    _lastY = y;
  }

  KeyEventResult key(KeyEvent e) {
    switch (e) {
      case KeyDownEvent():
        final k = keysymFor(e.logicalKey, e.character);
        final sc = scancodeFor(e.physicalKey);
        if (k == null && sc == 0) return KeyEventResult.ignored;
        _down[e.physicalKey] = (k ?? 0, sc);
        session.key(k ?? 0, down: true, scancode: sc);
      case KeyRepeatEvent():
        final held = _down[e.physicalKey];
        final k = held?.$1 ?? keysymFor(e.logicalKey, e.character);
        final sc = held?.$2 ?? scancodeFor(e.physicalKey);
        if (k == null && sc == 0) return KeyEventResult.ignored;
        session.key(k ?? 0, down: true, scancode: sc);
      case KeyUpEvent():
        final held = _down.remove(e.physicalKey);
        if (held == null) return KeyEventResult.ignored;
        session.key(held.$1, down: false, scancode: held.$2);
    }
    return KeyEventResult.handled;
  }

  /// Lets go of every key held (the view lost focus).
  void releaseKeys() {
    for (final (k, sc) in _down.values) {
      session.key(k, down: false, scancode: sc);
    }
    _down.clear();
  }

  // Text from the soft keyboard (an IME commits text, not keys).

  /// RDP: a character on a US key goes as that key's scancode (Shift added when it needs it), the
  /// rest as Unicode events (the session sends a keysym without a scancode that way). VNC (false):
  /// the character's keysym alone, so the server picks the modifiers.
  bool scancodeText = false;

  /// One key pressed and let go: (keysym, scancode).
  void tapKey(int keysym, int scancode) {
    session.key(keysym, down: true, scancode: scancode);
    session.key(keysym, down: false, scancode: scancode);
  }

  void typeText(String text) {
    for (final ch in text.runes) {
      if (ch == 0x0a || ch == 0x0d) {
        tapKey(0xff0d, 0x1c);
        continue;
      }
      if (ch == 0x09) {
        tapKey(0xff09, 0x0f);
        continue;
      }
      final keysym = keysymForChar(ch);
      final us = scancodeText ? usKey(ch) : null;
      if (us != null) {
        final sc = scancodeFor(us.$1);
        if (us.$2) session.key(0xffe1, down: true, scancode: 0x2a);
        tapKey(keysym, sc);
        if (us.$2) session.key(0xffe1, down: false, scancode: 0x2a);
      } else {
        tapKey(keysym, 0);
      }
    }
  }

  void backspace([int times = 1]) {
    for (var i = 0; i < times; i++) {
      tapKey(0xff08, 0x0e);
    }
  }

  // The viewport: the fit scale (whole remote visible, never above 1:1) times the person's zoom,
  // panned by [origin] within the content's bounds.

  /// Zoom on top of the fit scale (1 = fit).
  double zoom = 1;
  double _fit = 1;
  Size viewSizeNow = Size.zero;

  /// At most this many logical pixels per remote pixel when zoomed in.
  static const maxScale = 4.0;
  double get maxZoom => math.max(1.0, maxScale / _fit);

  /// Called by the painter with its size: computes [scale] and keeps [origin] in bounds.
  void layout(Size size) {
    viewSizeNow = size;
    if (width == 0 || height == 0 || size.isEmpty) return;
    _fit = math.min(1.0, math.min(size.width / width, size.height / height));
    zoom = zoom.clamp(1.0, maxZoom);
    scale = _fit * zoom;
    origin = _clamp(origin);
  }

  Offset _clamp(Offset o) {
    final size = viewSizeNow;
    double axis(double v, double content, double view) =>
        content <= view ? ((view - content) / 2).floorToDouble() : v.clamp(view - content, 0.0);
    return Offset(axis(o.dx, width * scale, size.width), axis(o.dy, height * scale, size.height));
  }

  /// Zoom to [z] keeping the remote point [anchor] (remote pixels) under [focal] (local).
  void zoomTo(double z, Offset anchor, Offset focal) {
    zoom = z.clamp(1.0, maxZoom);
    scale = _fit * zoom;
    origin = _clamp(focal - anchor * scale);
    notifyListeners();
  }

  void resetZoom() {
    zoom = 1;
    layout(viewSizeNow);
    notifyListeners();
  }

  // Touch: two modes, as Microsoft's clients have them.
  TouchMode touchMode = TouchMode.touch;

  /// The pointer in pointer mode (remote pixels, kept fractional while a finger moves it).
  double _px = 0;
  double _py = 0;
  (int, int) get pointerPosition => (_px.round().clamp(0, math.max(0, width - 1)), _py.round().clamp(0, math.max(0, height - 1)));

  static const _slop = 10.0;
  static const _longPressMs = 500;
  static const _scrollStep = 24.0;
  final Map<int, Offset> _touches = {};
  _Gesture _g = _Gesture.none;
  Offset _start = Offset.zero;
  Timer? _longPress;
  bool _held = false;
  double _startSpan = 1;
  Offset _startCentroid = Offset.zero;
  Offset _lastCentroid = Offset.zero;
  double _startZoom = 1;
  Offset _anchor = Offset.zero;
  double _scrollAcc = 0;
  int _twoStartUs = 0;

  /// What touch input did, for the self-test and the measurements: (what, at us).
  final List<(String, int)> touchLog = [];
  void _note(String what) => touchLog.add((what, ScreenSession.nowUs()));

  void _send(int x, int y, int buttons) {
    _lastX = x;
    _lastY = y;
    _buttons = buttons;
    session.pointer(x, y, buttons);
  }

  void _clickAt(int x, int y, int bit) {
    _send(x, y, 0);
    _send(x, y, bit);
    _send(x, y, 0);
  }

  Offset get _centroid {
    final p = _touches.values.take(2).toList();
    return (p[0] + p[1]) / 2;
  }

  double get _span {
    final p = _touches.values.take(2).toList();
    return math.max(1.0, (p[0] - p[1]).distance);
  }

  void touchDown(PointerDownEvent e) {
    if (onlyDevice != null && e.device != onlyDevice) return;
    _touches[e.pointer] = e.localPosition;
    if (_touches.length == 1) {
      _g = _Gesture.one;
      _start = e.localPosition;
      _held = false;
      _longPress?.cancel();
      _longPress = Timer(const Duration(milliseconds: _longPressMs), _onLongPress);
    } else if (_touches.length == 2 && _g == _Gesture.one) {
      _longPress?.cancel();
      _g = _Gesture.two;
      _startSpan = _span;
      _startCentroid = _lastCentroid = _centroid;
      _startZoom = zoom;
      _anchor = (_startCentroid - origin) / scale;
      _scrollAcc = 0;
      _twoStartUs = ScreenSession.nowUs();
    }
  }

  void _onLongPress() {
    if (_g != _Gesture.one) return;
    _held = true;
    if (touchMode == TouchMode.touch) {
      // Touch: hold for a right click at the finger.
      final (x, y) = toRemote(_start);
      _clickAt(x, y, 4);
      _note('right_click');
      _g = _Gesture.done;
    }
    // Pointer: decided when the finger moves (a left drag) or lifts (a right click).
  }

  void _movePointerBy(Offset localDelta, int buttons) {
    _px = (_px + localDelta.dx / scale).clamp(0, math.max(0, width - 1).toDouble());
    _py = (_py + localDelta.dy / scale).clamp(0, math.max(0, height - 1).toDouble());
    final (x, y) = pointerPosition;
    _send(x, y, buttons);
    // Keep the pointer in view: pan when it comes near an edge.
    final l = toLocal(x, y);
    const m = 24.0;
    final v = viewSizeNow;
    final dx = l.dx < m ? m - l.dx : (l.dx > v.width - m ? v.width - m - l.dx : 0.0);
    final dy = l.dy < m ? m - l.dy : (l.dy > v.height - m ? v.height - m - l.dy : 0.0);
    if (dx != 0 || dy != 0) origin = _clamp(origin + Offset(dx, dy));
    notifyListeners();
  }

  void touchMove(PointerMoveEvent e) {
    final prev = _touches[e.pointer];
    if (prev == null) return;
    final pos = e.localPosition;
    _touches[e.pointer] = pos;
    switch (_g) {
      case _Gesture.one:
        if ((pos - _start).distance <= _slop) return;
        _longPress?.cancel();
        if (touchMode == TouchMode.touch) {
          // Touch: a left drag from where the finger went down.
          final (sx, sy) = toRemote(_start);
          _send(sx, sy, 0);
          _send(sx, sy, 1);
          final (x, y) = toRemote(pos);
          _send(x, y, 1);
          _g = _Gesture.drag;
          _note('drag_start');
        } else if (_held) {
          // Pointer, after a hold: a left drag from the pointer.
          final (x, y) = pointerPosition;
          _send(x, y, 1);
          _g = _Gesture.drag;
          _note('drag_start');
          _movePointerBy(pos - _start, 1);
        } else {
          _g = _Gesture.move;
          _movePointerBy(pos - _start, 0);
        }
      case _Gesture.move:
        _movePointerBy(pos - prev, 0);
      case _Gesture.drag:
        if (touchMode == TouchMode.touch) {
          final (x, y) = toRemote(pos);
          _send(x, y, 1);
        } else {
          _movePointerBy(pos - prev, 1);
        }
      case _Gesture.two:
        if (_touches.length < 2) return;
        final c = _centroid;
        if ((_span / _startSpan - 1).abs() > 0.12) {
          _g = _Gesture.zoom;
          _note('zoom_start');
          zoomTo(_startZoom * _span / _startSpan, _anchor, c);
        } else if ((c - _startCentroid).distance > _slop) {
          _g = _Gesture.scroll;
          _lastCentroid = c;
          _note('scroll_start');
        }
      case _Gesture.zoom:
        if (_touches.length < 2) return;
        zoomTo(_startZoom * _span / _startSpan, _anchor, _centroid);
      case _Gesture.scroll:
        if (_touches.length < 2) return;
        final c = _centroid;
        _scrollAcc += c.dy - _lastCentroid.dy;
        _lastCentroid = c;
        final (x, y) = touchMode == TouchMode.touch ? toRemote(c) : pointerPosition;
        while (_scrollAcc.abs() >= _scrollStep) {
          // Fingers up: the content moves up, so the wheel turns down (button 5), as on a phone.
          final bit = _scrollAcc < 0 ? 16 : 8;
          _scrollAcc += _scrollAcc < 0 ? _scrollStep : -_scrollStep;
          _send(x, y, bit);
          _send(x, y, 0);
          _note(bit == 16 ? 'wheel_down' : 'wheel_up');
        }
      case _Gesture.none:
      case _Gesture.done:
    }
  }

  void touchUp(PointerEvent e, {bool cancelled = false}) {
    if (_touches.remove(e.pointer) == null) return;
    switch (_g) {
      case _Gesture.one:
        _longPress?.cancel();
        if (cancelled) break;
        if (touchMode == TouchMode.touch) {
          final (x, y) = toRemote(_start);
          _clickAt(x, y, 1);
          _note('tap');
        } else {
          final (x, y) = pointerPosition;
          _clickAt(x, y, _held ? 4 : 1);
          _note(_held ? 'right_click' : 'tap');
        }
      case _Gesture.drag:
        _send(_lastX, _lastY, 0);
        _note('drag_end');
      case _Gesture.two:
        // Two fingers tapped together: a right click.
        if (!cancelled && ScreenSession.nowUs() - _twoStartUs < 400000) {
          final (x, y) = touchMode == TouchMode.touch ? toRemote(_lastCentroid) : pointerPosition;
          _clickAt(x, y, 4);
          _note('right_click');
        }
      case _Gesture.move:
      case _Gesture.zoom:
      case _Gesture.scroll:
      case _Gesture.none:
      case _Gesture.done:
    }
    _g = _touches.isEmpty ? _Gesture.none : _Gesture.done;
  }

  /// The view's size in logical pixels (remote pixels at 1:1): told to the session once it has
  /// stayed the same for a moment (a window being dragged larger sends one request at the end).
  /// Off unless [followViewSize].
  bool followViewSize = false;
  Size _viewSize = Size.zero;
  Timer? _sizeTimer;
  void viewSize(Size size) {
    if (!followViewSize || size == _viewSize || size.isEmpty) return;
    _viewSize = size;
    _sizeTimer?.cancel();
    _sizeTimer = Timer(const Duration(milliseconds: 300), () {
      // RDP's widths are even: the one at or under the view's.
      final w = size.width.floor() & ~1, h = size.height.floor();
      if (w != width || h != height) session.resize(w, h);
    });
  }

  (int, int) get lastPointer => (_lastX, _lastY);

  @override
  void dispose() {
    _sizeTimer?.cancel();
    _longPress?.cancel();
    _sub.cancel();
    _clear();
    super.dispose();
  }
}

/// How a finger drives the remote pointer: [touch], taps are clicks where the finger is (hold
/// for a right click, drag for a left drag); [pointer], a trackpad: a finger moves the pointer,
/// a tap clicks where it is (hold then drag for a left drag, hold and lift for a right click).
/// Both: two fingers drag to scroll, pinch to zoom (and pan), tap together for a right click.
enum TouchMode { touch, pointer }

enum _Gesture { none, one, move, drag, two, zoom, scroll, done }

class _ScreenPainter extends CustomPainter {
  _ScreenPainter(this.c) : super(repaint: c);
  final ScreenController c;

  @override
  void paint(Canvas canvas, Size size) {
    c.viewSize(size);
    c.layout(size);
    if (c.width == 0 || c.height == 0) return;
    final s = c.scale;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(c.origin.dx, c.origin.dy);
    canvas.scale(s);
    // No edge anti-aliasing: tiles side by side would each cover half of a boundary pixel and
    // leave a faint seam.
    final paint = Paint()
      ..isAntiAlias = false
      ..filterQuality = s < 1 ? FilterQuality.low : FilterQuality.none;
    for (final t in c._tiles.values) {
      canvas.drawImage(t.image, Offset(t.x.toDouble(), t.y.toDouble()), paint);
    }
    canvas.restore();
    // Pointer mode: the remote servers leave the pointer out of the picture (the Cursor
    // pseudo-encoding), so draw one where it is.
    if (c.touchMode == TouchMode.pointer) {
      final (x, y) = c.pointerPosition;
      final p = c.origin + Offset(x.toDouble(), y.toDouble()) * s;
      final arrow = Path()
        ..moveTo(p.dx, p.dy)
        ..lineTo(p.dx, p.dy + 18)
        ..lineTo(p.dx + 5, p.dy + 13)
        ..lineTo(p.dx + 12, p.dy + 13)
        ..close();
      canvas.drawPath(arrow, Paint()..color = Colors.white);
      canvas.drawPath(arrow, Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2);
    }
  }

  @override
  bool shouldRepaint(_ScreenPainter old) => old.c != c;
}

/// The soft keyboard's client: an IME commits text and deletions into an editing value, not keys.
/// The value is kept at two spaces; each change is compared with it (what was deleted becomes
/// BackSpace keys, what was added becomes text through [ScreenController.typeText]) and the value
/// goes back to the two spaces. Visible-password input, so keyboards neither compose nor correct.
class SoftKeyboard with TextInputClient {
  SoftKeyboard(this.controller);
  final ScreenController controller;
  TextInputConnection? _conn;
  static const _base = TextEditingValue(text: '  ', selection: TextSelection.collapsed(offset: 2));
  TextEditingValue _value = _base;

  /// Text and deletions it sent, for the self-test: (what, at us).
  final List<(String, int)> sent = [];

  bool get shown => _conn?.attached ?? false;

  void show() {
    if (!shown) {
      _conn = TextInput.attach(
        this,
        const TextInputConfiguration(
          inputType: TextInputType.visiblePassword,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          inputAction: TextInputAction.newline,
          keyboardAppearance: Brightness.dark,
        ),
      );
      _value = _base;
      _conn!.setEditingState(_base);
    }
    _conn!.show();
  }

  void hide() {
    _conn?.close();
    _conn = null;
  }

  @override
  TextEditingValue? get currentTextEditingValue => _value;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    final old = _value.text, now = value.text;
    // Still composing (a keyboard that ignores visiblePassword): wait for the commit.
    if (value.composing.isValid && !value.composing.isCollapsed) {
      _value = value;
      return;
    }
    var p = 0;
    while (p < old.length && p < now.length && old.codeUnitAt(p) == now.codeUnitAt(p)) {
      p++;
    }
    final deleted = old.length - p;
    final inserted = now.substring(p);
    if (deleted > 0) {
      controller.backspace(deleted);
      sent.add(('<bs x$deleted>', ScreenSession.nowUs()));
    }
    if (inserted.isNotEmpty) {
      controller.typeText(inserted);
      sent.add((inserted, ScreenSession.nowUs()));
    }
    if (now != _base.text || value.selection != _base.selection) {
      _value = _base;
      _conn?.setEditingState(_base);
    } else {
      _value = value;
    }
  }

  @override
  void performAction(TextInputAction action) {
    controller.tapKey(0xff0d, 0x1c);
    sent.add(('<enter>', ScreenSession.nowUs()));
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _conn = null;
  }
}

/// The remote screen: fills its space keeping the remote's shape, takes the pointer (mouse and
/// touch) and keys.
class RemoteScreenView extends StatelessWidget {
  const RemoteScreenView({super.key, required this.controller, this.focusNode});
  final ScreenController controller;
  final FocusNode? focusNode;

  static bool _isTouch(PointerEvent e) =>
      e.kind == PointerDeviceKind.touch || e.kind == PointerDeviceKind.stylus || e.kind == PointerDeviceKind.invertedStylus;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      autofocus: true,
      onKeyEvent: (_, e) => controller.key(e),
      onFocusChange: (has) => has ? null : controller.releaseKeys(),
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerHover: controller.pointer,
          onPointerMove: (e) => _isTouch(e) ? controller.touchMove(e) : controller.pointer(e),
          onPointerDown: (e) {
            focusNode?.requestFocus();
            _isTouch(e) ? controller.touchDown(e) : controller.pointer(e);
          },
          onPointerUp: (e) => _isTouch(e) ? controller.touchUp(e) : controller.pointer(e),
          onPointerCancel: (e) => _isTouch(e) ? controller.touchUp(e, cancelled: true) : null,
          onPointerSignal: controller.scroll,
          child: ColoredBox(
            color: Colors.black,
            child: CustomPaint(painter: _ScreenPainter(controller), size: Size.infinite),
          ),
        ),
      ),
    );
  }
}
