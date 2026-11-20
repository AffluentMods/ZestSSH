// Remote screens (4.0): the picture of one screen session, and its input.
//
// Frames: the engine keeps the remote picture and says when tiles changed
// (ScreenFrameReady); the controller takes them on the next vsync, at most one
// frame a vsync and never two at once (the engine merges what comes
// meanwhile), turns each tile into a ui.Image (raw RGBA in, an image out:
// nothing decoded in Dart; the spike's path A, 60 fps at 1440p) and swaps them
// in, disposing the ones they replace. While paused (the tab not in front, the
// window hidden) nothing is taken and the server sends nothing.
//
// Input: the mouse ([ScreenMouse]), fingers ([ScreenTouch]) and keys
// ([ScreenKeyboard]) through one [ScreenViewport], in remote pixels.
//
// Displays (4.0): a remote with several is shown one at a time, or
// all of them as one desktop ([displays], [showDisplay]). While one is
// shown the engine hands this controller that display's pixels only, as if
// it were the whole screen, and the pointer's places are moved back into
// the desktop as they go out.
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:zest_native/screen.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/model/screen_displays.dart';
import 'package:zestssh/features/screens/model/screen_session_details.dart';
import 'package:zestssh/features/screens/model/screen_view_size.dart';

import 'screen_keyboard.dart';
import 'screen_pointer.dart';
import 'screen_pointer_hold.dart';
import 'screen_sound_gate.dart';
import 'screen_touch.dart';
import 'screen_viewport.dart';

/// Turns a tile's pixels into an image.
typedef ScreenTileDecoder = Future<ui.Image> Function(ScreenTile tile);

/// [ScreenTileDecoder] of the app: the pixels as they are (RGBA, opaque),
/// through an ImmutableBuffer and a raw ImageDescriptor.
Future<ui.Image> decodeScreenTile(ScreenTile t) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(t.pixels);
  final descriptor = ui.ImageDescriptor.raw( // redaction: raw ok (raw pixels, not a Redactable)
    buffer,
    width: t.width,
    height: t.height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  try {
    final codec = await descriptor.instantiateCodec();
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  } finally {
    descriptor.dispose();
    buffer.dispose();
  }
}

/// One tile of the picture: where it goes (remote pixels) and its image.
class ScreenPictureTile {
  ScreenPictureTile(this.x, this.y, this.image);
  final int x;
  final int y;
  final ui.Image image;
}

/// The remote cursor's shape (the server leaves it out of the picture and
/// sends it apart): its image, null while hidden, and its hot spot.
class ScreenRemoteCursor {
  ScreenRemoteCursor(this.image, this.hotX, this.hotY);
  final ui.Image? image;
  final int hotX;
  final int hotY;
  bool get hidden => image == null;
}

/// What is drawn at the remote pointer over the picture.
enum ScreenCursorDraw {
  /// Nothing: the system's own pointer shows (a mouse before the server sent
  /// a shape), or no pointer is placed yet, or the server hides it.
  none,

  /// The shape the server sent.
  remote,

  /// An arrow of our own (Mouse pointer mode before the server sent a shape).
  arrow,
}

class ScreenController extends ChangeNotifier {
  ScreenController(this.session, {ScreenTileDecoder? decodeTile, PointerCapture? capture})
      : _decode = decodeTile ?? decodeScreenTile {
    hold = ScreenPointerHold(capture: capture ?? debugCapture ?? ChannelPointerCapture(), send: session.pointerRelative)
      ..addListener(notifyListeners);
    // Places are the shown display's; the remote takes the whole desktop's.
    pointer = ScreenPointer((x, y, buttons) => session.pointer(x + _shownX, y + _shownY, buttons));
    keyboard = ScreenKeyboard((keysym, scancode, down) => session.key(keysym, down: down, scancode: scancode));
    mouse = ScreenMouse(viewport: viewport, pointer: pointer, changed: notifyListeners);
    touch = ScreenTouch(viewport: viewport, pointer: pointer, changed: notifyListeners)
      // A phone's Mouse pointer mode with relative mouse on: movement as movement.
      ..sendRelative = session.pointerRelative;
    // The release key gets the pointer back before it does anything else.
    keyboard.onReleaseKey = releasePointer;
    _sub = session.events.listen(_onEvent);
    // Connected before this controller (connectTrusting returns once it is):
    // the size from the handshake, and any frame already waiting.
    session.connected.then((c) {
      if (_disposed) return;
      _protocol = c.info['protocol'] == 'rdp' ? 'RDP' : 'VNC';
      _relativeTaken = c.relativeMouse;
      _soundFrom(c);
      if (!viewport.hasRemote) _desktop(c.width, c.height, c.displays);
    }, onError: (Object _) {});
    _closed = session.isClosed;
    _pending = true;
    _schedule();
  }

  final ScreenSession session;
  final ScreenTileDecoder _decode;
  final viewport = ScreenViewport();
  late final ScreenPointer pointer;
  late final ScreenKeyboard keyboard;
  late final ScreenMouse mouse;
  late final ScreenTouch touch;

  /// Holds this computer's pointer while relative mouse is on ([relativeMouse]).
  late final ScreenPointerHold hold;

  /// The computer's part that holds the pointer, for tests (the app's own
  /// channel otherwise).
  @visibleForTesting
  static PointerCapture? debugCapture;
  late final StreamSubscription<ScreenEvent> _sub;

  final Map<int, ScreenPictureTile> _tiles = {};
  int _tilesWidth = 0;
  int _tilesHeight = 0;
  bool _pending = false;
  bool _scheduled = false;

  // The frame rate limit: while this runs, no frame is taken.
  Timer? _gate;
  int _frameLimit = 0;
  bool _taking = false;
  bool _paused = false;
  bool _closed = false;
  bool _disposed = false;

  /// Frames shown so far (the stats line in debug builds).
  int framesShown = 0;

  /// The remote's displays and the one shown; [ScreenDisplays.several] only
  /// where the remote has more than one.
  final displays = ValueNotifier<ScreenDisplays>(ScreenDisplays.none);

  // The whole remote desktop's size, the displays the engine told (as
  // rectangles of it), the display its person wants shown (null: all), and
  // where the part shown now starts in the desktop.
  int _desktopWidth = 0;
  int _desktopHeight = 0;
  List<ScreenDisplayRect> _rects = const [];
  int? _wanted;
  int _shownX = 0;
  int _shownY = 0;
  bool _partShown = false;

  // What each display's view was left at (its zoom and pan), by its number
  // (-1: all of them), for the session.
  final Map<int, ScreenViewKept> _viewOf = {};

  // Raised when what is shown changes: a frame taken before it is of the
  // other part, and is dropped.
  int _epoch = 0;

  /// The whole remote desktop's size (every display), where [width] and
  /// [height] are the shown part's.
  int get desktopWidth => _desktopWidth;
  int get desktopHeight => _desktopHeight;

  ScreenRemoteCursor? _cursor;
  int _cursorSeq = 0;

  int get width => viewport.remoteWidth;
  int get height => viewport.remoteHeight;

  /// Some picture has arrived.
  bool get hasPicture => _tiles.isNotEmpty;
  bool get isPaused => _paused;
  bool get isClosed => _closed;

  /// The tiles, in the order they are drawn.
  Iterable<ScreenPictureTile> get tiles => _tiles.values;

  /// The server's cursor, or null until it sends one.
  ScreenRemoteCursor? get remoteCursor => _cursor;

  void _setRemote(int w, int h) {
    viewport.setRemote(w, h);
    if (touch.mode == ScreenTouchMode.mousePointer && !pointer.placed) touch.placePointer(w ~/ 2, h ~/ 2);
    notifyListeners();
  }

  // The remote's sound (4.0).

  bool _soundPlays = false;
  String? _soundUnavailable;
  bool _soundWanted = true;
  bool _soundAllowed = false;

  /// The session plays the remote's sound (an RDP host that plays it, on
  /// a device with an output).
  bool get soundPlays => _soundPlays;

  /// The session asked for sound and connected without it: why, in the
  /// engine's words (no output here, no sound in this build).
  String? get soundUnavailable => _soundUnavailable;

  /// Its person's switch for this session (on until turned off).
  bool get soundWanted => _soundWanted;
  set soundWanted(bool on) {
    if (on == _soundWanted) return;
    _soundWanted = on;
    _applySound();
    notifyListeners();
  }

  /// Whether the view lets sound play now: it is seen (no recording
  /// cover over it, the app not locked, a phone's app in front). False
  /// until the view says so, so nothing plays before it is looked at.
  bool get soundAllowed => _soundAllowed;
  set soundAllowed(bool on) {
    if (on == _soundAllowed) return;
    _soundAllowed = on;
    _applySound();
  }

  void _soundFrom(ScreenConnected c) {
    _soundPlays = c.sound != null;
    _soundUnavailable = c.soundUnavailable;
    // A session starts silent (asked for so: the session's request says
    // "off"), a reconnect's too: its gate says only a change from that.
    _applySound();
  }

  /// This view holds the session's sound open while it is seen and its
  /// person wants it ([ScreenSoundGate]); the session plays while any view
  /// of it does, and nothing blocks it.
  void _applySound() {
    if (!_soundPlays || _disposed || _closed) return;
    ScreenSoundGate.of(session).hold(this, on: _soundWanted && _soundAllowed);
  }

  /// This view goes while its screen is shown in a window of its own: what
  /// it held of the sound passes to that window, which is seen ([sessionId]'s
  /// window, ScreenSoundGate.ownWindow), so the sound goes on while it is.
  void handSoundToOwnWindow(String sessionId) {
    if (!_soundPlays || _disposed || _closed) return;
    ScreenSoundGate.of(session).handOver(this, ScreenSoundGate.ownWindow(sessionId));
  }

  // Relative mouse.

  bool _relativeTaken = false;
  bool _relativeMouse = false;

  /// The session asked its server for relative mouse movement and the
  /// server takes it: only then can [relativeMouse] be turned on.
  bool get relativeTaken => _relativeTaken;

  /// Relative mouse is on (4.0): a click in the picture then holds
  /// the pointer ([hold]) and the mouse's movement goes to the remote as
  /// movement. Turning it off lets go of the pointer. It stays off where
  /// the server does not take it, and in view only.
  bool get relativeMouse => _relativeMouse;
  set relativeMouse(bool on) {
    final next = on && _relativeTaken && !_viewOnly && !_closed;
    if (next == _relativeMouse) return;
    _relativeMouse = next;
    touch.relative = next;
    if (!next) hold.release();
    notifyListeners();
  }

  /// A mouse button went down in the picture: with relative mouse on, the
  /// pointer is held from now on (true), and this press is the one that
  /// took it, not a click for the remote.
  bool takePointer() {
    if (!_relativeMouse || hold.held || _paused || _closed) return false;
    unawaited(hold.grab());
    return true;
  }

  /// Lets go of the pointer where it is held (the release key, the picture
  /// losing the keyboard). True where it was held.
  bool releasePointer() {
    if (!hold.held) return false;
    hold.release();
    return true;
  }

  // The session's details.

  /// Numbers about the running session, sampled once a second while
  /// [detailsShown]: the last minute of bytes and frames, what the picture
  /// is drawn with, the desktop's size.
  final details = ValueNotifier<ScreenSessionDetails>(ScreenSessionDetails.none);

  String _protocol = '';
  Object? _graphics;
  Timer? _detailsTimer;
  int _detailsSeconds = 0;
  int _sampledIn = 0;
  int _sampledOut = 0;
  int _sampledFrames = 0;

  /// What measures the round trip to the remote computer, in milliseconds
  /// (null: no answer in time). Asked when the details open and every
  /// [roundTripEverySeconds] while they are shown, one question at a time.
  /// Null where nothing can measure it: the details then have no such row.
  /// Set by whoever opens the view (screenRoundTripOf).
  Future<int?> Function()? measureRoundTrip;

  /// How often the round trip is measured while the details are shown.
  static const roundTripEverySeconds = 5;
  int? _roundTripMs;
  bool _measuring = false;

  void _measureRoundTrip() {
    final measure = measureRoundTrip;
    final asked = _detailsTimer;
    if (measure == null || _measuring || asked == null) return;
    _measuring = true;
    unawaited(measure().then<int?>((ms) => ms, onError: (Object _) => null).then((ms) {
      _measuring = false;
      // Not for details closed, or opened anew, since it was asked.
      if (_disposed || !identical(_detailsTimer, asked)) return;
      _roundTripMs = ms != null && ms >= 0 ? ms : null;
      details.value = _detailsWith(details.value.last);
    }));
  }

  /// Whether the session's details are shown: only then is anything
  /// sampled. Turning it on starts a new minute.
  bool get detailsShown => _detailsTimer != null;
  set detailsShown(bool shown) {
    if (shown == detailsShown || _disposed) return;
    _detailsTimer?.cancel();
    _detailsTimer = null;
    if (!shown) return;
    _detailsSeconds = 0;
    _sampledIn = session.bytesIn;
    _sampledOut = session.bytesOut;
    _sampledFrames = framesShown;
    _roundTripMs = null;
    details.value = _detailsWith(const []);
    _detailsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _sample());
    _measureRoundTrip();
  }

  ScreenSessionDetails _detailsWith(List<ScreenSessionSample> last) => ScreenSessionDetails(
        last: last,
        drawnWith: ScreenSessionDetails.drawnWithFrom(_graphics),
        roundTripMs: _roundTripMs,
        width: _desktopWidth,
        height: _desktopHeight,
        protocol: _protocol,
      );

  void _sample() {
    if (_disposed) return;
    final (bytesIn, bytesOut, frames) = (session.bytesIn, session.bytesOut, framesShown);
    final sample = ScreenSessionSample(
      // One a second, counted: the timer's seconds, not a clock's.
      at: Duration(seconds: ++_detailsSeconds),
      bytesIn: bytesIn - _sampledIn,
      bytesOut: bytesOut - _sampledOut,
      frames: frames - _sampledFrames,
    );
    _sampledIn = bytesIn;
    _sampledOut = bytesOut;
    _sampledFrames = frames;
    final before = details.value.last;
    final kept = before.length < ScreenSessionDetails.keep ? before : before.sublist(before.length - ScreenSessionDetails.keep + 1);
    details.value = _detailsWith([...kept, sample]);
    if (_detailsSeconds % roundTripEverySeconds == 0) _measureRoundTrip();
  }

  // The displays.

  /// The desktop is [w] by [h] with these displays: the ones that are
  /// inside it count, and what is shown follows.
  void _desktop(int w, int h, List<ScreenDisplayRect> rects) {
    _desktopWidth = w;
    _desktopHeight = h;
    _rects = rects;
    _show(_wanted, keepView: true);
  }

  /// The displays as they are told to the app: those inside the desktop,
  /// numbered in the engine's order (the first is the primary one, which is
  /// how they are asked for); none where the engine told fewer than two.
  List<ScreenDisplay> get _known {
    final inside = [
      for (final r in _rects)
        if (r.x + r.width <= _desktopWidth && r.y + r.height <= _desktopHeight) r,
    ];
    if (inside.length < 2) return const [];
    return [
      for (final (i, r) in inside.take(ScreenDisplays.most).indexed)
        ScreenDisplay(index: i, x: r.x, y: r.y, width: r.width, height: r.height, primary: i == 0),
    ];
  }

  /// Shows display [index] alone, or all of them (null, or a number the
  /// remote has no display for). The view that display was left at (its
  /// zoom and pan) comes back with it.
  void showDisplay(int? index) => _show(index, keepView: false);

  /// The display after the one shown, or before it ([next] false), round
  /// the end; from all of them, the first or the last. Nothing where the
  /// remote has one display.
  void stepDisplay({required bool next}) {
    final d = displays.value;
    if (!d.several) return;
    final n = d.list.length;
    final at = d.shown;
    showDisplay(at == null ? (next ? 0 : n - 1) : (at + (next ? 1 : n - 1)) % n);
  }

  void _show(int? index, {required bool keepView}) {
    if (_disposed) return;
    final known = _known;
    final before = displays.value;
    // The wish is kept while the remote has no such display (it may come
    // with the next layout); what is shown is what there is.
    _wanted = index;
    final shown = index != null && index >= 0 && index < known.length ? index : null;
    final d = shown == null ? null : known[shown];
    final (x, y, w, h) = d == null ? (0, 0, _desktopWidth, _desktopHeight) : (d.x, d.y, d.width, d.height);
    final next = ScreenDisplays(list: known, shown: shown);
    final otherPart = (d != null) != _partShown || x != _shownX || y != _shownY;
    if (!otherPart) {
      // The same part: at most its size changed (the remote was resized, or
      // the session has just connected). The picture, the view and the
      // pointer stay as they are; the frame of the new size replaces the
      // tiles when it comes.
      if (next != before) displays.value = next;
      _displayKeys(next);
      if (w != width || h != height) {
        if (d != null) session.showPart(x, y, w, h);
        _setRemote(w, h);
      }
      return;
    }
    // Another part: the view of the one shown until now is kept for when it
    // is shown again, unless it went because the remote changed under it.
    if (!keepView && viewport.hasRemote) _viewOf[before.shown ?? -1] = viewport.kept();
    _epoch++;
    _shownX = x;
    _shownY = y;
    if (d == null) {
      session.showAll();
    } else {
      session.showPart(x, y, w, h);
    }
    _partShown = d != null;
    _clearTiles();
    _tilesWidth = 0;
    _tilesHeight = 0;
    final kept = _viewOf[shown ?? -1];
    if (kept != null) {
      viewport.restore(kept);
    } else {
      viewport.resetZoom();
    }
    // The pointer's place was the other part's.
    pointer.placed = false;
    touch.cancel();
    displays.value = next;
    _displayKeys(next);
    _setRemote(w, h);
    // The engine starts the part with all of it: taken without being told.
    _pending = true;
    _schedule();
  }

  /// Ctrl+Alt+Left and Right, and three fingers sideways, change the display
  /// only where there are several; else the keys are the remote's and a
  /// third finger is nothing.
  void _displayKeys(ScreenDisplays d) {
    final step = d.several ? (bool next) => stepDisplay(next: next) : null;
    keyboard.onDisplayKey = step;
    touch.onDisplaySwipe = step;
  }

  void _onEvent(ScreenEvent e) {
    if (_disposed) return;
    switch (e) {
      case ScreenFrameReady():
        _pending = true;
        _schedule();
      case ScreenConnected(:final width, :final height):
        _protocol = e.info['protocol'] == 'rdp' ? 'RDP' : 'VNC';
        _relativeTaken = e.relativeMouse;
        _soundFrom(e);
        _desktop(width, height, e.displays);
      case ScreenResized(:final width, :final height):
        // The displays of the new size follow (ScreenDisplaysChanged); until
        // then the ones known count only where they still fit.
        _desktop(width, height, _rects);
      case ScreenDisplaysChanged(:final displays):
        _desktop(_desktopWidth, _desktopHeight, displays);
      case ScreenCursor():
        unawaited(_takeCursor(e));
      case ScreenInfo(:final info) when info['graphics'] is Map:
        // What the server draws with, for the session's details.
        _graphics = info['graphics'];
      case ScreenInfo(:final info) when info['resize_unavailable'] == true:
        if (_followViewSize) {
          followViewSize = false;
          onResizeUnavailable?.call();
        }
      case ScreenClosed():
        _closed = true;
        hold.release();
        touch.cancel();
        notifyListeners();
      default:
    }
  }

  // Frames, at most one a vsync.

  void _schedule() {
    if (_scheduled || _taking || _paused || _idle || _closed || _disposed || !_pending || _gate != null) return;
    _scheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _scheduled = false;
      unawaited(_take());
    });
  }

  Future<void> _take() async {
    if (_paused || _idle || _closed || _disposed || !_pending) return;
    _pending = false;
    final epoch = _epoch;
    final frame = session.takeFrame();
    if (frame == null) return;
    _taking = true;
    List<ui.Image> images;
    try {
      images = await Future.wait(frame.tiles.map(_decode));
    } catch (_) {
      // A tile the device could not make an image of: the next frame, or a
      // refresh, brings the picture again.
      images = const [];
    } finally {
      frame.free();
      _taking = false;
    }
    // Disposed meanwhile, or another part is shown since: these are not its
    // pixels (the engine starts the new part with all of it).
    if (_disposed || epoch != _epoch) {
      for (final i in images) {
        i.dispose();
      }
      if (!_disposed) {
        _pending = true;
        _schedule();
      }
      return;
    }
    if (images.isNotEmpty) _apply(frame, images);
    // A limit: the next frame not before its time. What the server sends
    // meanwhile is merged by the engine, so nothing is lost, only drawn later.
    if (_frameLimit > 0) {
      _gate = Timer(Duration(microseconds: Duration.microsecondsPerSecond ~/ _frameLimit), () {
        _gate = null;
        _schedule();
      });
    }
    _schedule();
  }

  /// The most frames a second this view draws (4.0): 0 is no limit
  /// (one a frame of the screen, as it always was). It saves this device's
  /// battery and processor time; the server sends as it does.
  int get frameLimit => _frameLimit;
  set frameLimit(int value) {
    final limit = value < 0 ? 0 : value;
    if (limit == _frameLimit) return;
    _frameLimit = limit;
    // The new pace from now: a wait of the old one is not sat out.
    _gate?.cancel();
    _gate = null;
    if (!_disposed) _schedule();
  }

  void _apply(ScreenFrame frame, List<ui.Image> images) {
    // A new size: the frame holds every tile, the old ones go.
    if (frame.width != _tilesWidth || frame.height != _tilesHeight) {
      _clearTiles();
      _tilesWidth = frame.width;
      _tilesHeight = frame.height;
      if (frame.width != width || frame.height != height) viewport.setRemote(frame.width, frame.height);
    }
    for (var i = 0; i < images.length; i++) {
      final t = frame.tiles[i];
      // The whole screen as one image (the engine sends it when most tiles
      // changed): it goes under everything, and the tiles it covers go.
      final whole = t.x == 0 && t.y == 0 && t.width == frame.width && t.height == frame.height;
      if (whole) _clearTiles();
      final key = whole ? -1 : t.y << 16 | t.x;
      _tiles.remove(key)?.image.dispose();
      _tiles[key] = ScreenPictureTile(t.x, t.y, images[i]);
    }
    framesShown++;
    notifyListeners();
  }

  void _clearTiles() {
    for (final t in _tiles.values) {
      t.image.dispose();
    }
    _tiles.clear();
  }

  Future<void> _takeCursor(ScreenCursor c) async {
    final seq = ++_cursorSeq;
    // The server has no shape of its own (RDP): the system's pointer again,
    // as before any shape came.
    if (c.system) {
      _cursor?.image?.dispose();
      _cursor = null;
      notifyListeners();
      return;
    }
    ui.Image? image;
    if (!c.hidden) {
      // The colour of a clear pixel is cleared too, so nothing of it shows
      // however the image is blended (VNC's alpha is 0 or 255; RDP's shapes
      // come with their colours already multiplied by any alpha).
      final rgba = Uint8List.fromList(c.rgba);
      for (var i = 0; i + 3 < rgba.length; i += 4) {
        if (rgba[i + 3] == 0) rgba[i] = rgba[i + 1] = rgba[i + 2] = 0;
      }
      try {
        image = await _decode(ScreenTile(0, 0, c.width, c.height, rgba));
      } catch (_) {
        return;
      }
    }
    // A newer shape came meanwhile, or the view went.
    if (_disposed || seq != _cursorSeq) {
      image?.dispose();
      return;
    }
    _cursor?.image?.dispose();
    _cursor = ScreenRemoteCursor(image, c.hotX, c.hotY);
    notifyListeners();
  }

  // Pausing.

  /// The view is not seen (a tab behind another, the window hidden or
  /// minimized, the app locked): the server stops sending, nothing is taken,
  /// and the keys and buttons held are let go.
  void pause() {
    if (_paused || _disposed) return;
    _paused = true;
    keyboard.releaseAll();
    pointer.release();
    // Not in front: the pointer is this computer's.
    hold.release();
    touch.cancel();
    // (After the keys and buttons held were let go: their release is sent.)
    _gateInput();
    // Shown elsewhere meanwhile: the server goes on sending for that window.
    if (!_idle) session.pause();
  }

  /// Seen again: the server sends again, the whole screen first.
  void resume() {
    if (!_paused || _disposed) return;
    _paused = false;
    _gateInput();
    if (!_idle) session.resume();
    _pending = true;
    _schedule();
  }

  /// The picture is shown elsewhere (a window of its own, 4.0): this
  /// view takes no frames and sends nothing, and it no longer says whether
  /// the server sends, so a tab that is not seen does not stop the window's
  /// picture. Back here, what changed meanwhile is taken at once, and a
  /// view that is not seen pauses the server again.
  bool get idle => _idle;
  bool _idle = false;
  set idle(bool value) {
    if (_idle == value || _disposed) return;
    _idle = value;
    if (value) {
      keyboard.releaseAll();
      pointer.release();
      hold.release();
      touch.cancel();
      if (_paused) session.resume();
    } else if (_paused) {
      session.pause();
    } else {
      _pending = true;
      _schedule();
    }
    notifyListeners();
  }

  // Settings the tab drives.

  /// The picture is smoothed wherever a remote pixel is not a whole number
  /// of the screen's pixels (4.0). Off: sharp at one to one and
  /// above, as it always was.
  bool get smoothScaling => _smoothScaling;
  bool _smoothScaling = false;
  set smoothScaling(bool value) {
    if (_smoothScaling == value) return;
    _smoothScaling = value;
    if (!_disposed) notifyListeners();
  }

  /// Nothing goes to the remote (pinch and pan still work; F8 still opens the
  /// menu).
  bool get viewOnly => _viewOnly;
  bool _viewOnly = false;
  set viewOnly(bool value) {
    if (_viewOnly == value) return;
    if (value) {
      keyboard.releaseAll();
      pointer.release();
      touch.cancel();
      // Nothing is sent to a screen that is only looked at: no movement either.
      _relativeMouse = false;
      // A phone's fingers follow it: left on, they went on sending movement once view only
      // was off again, with the switch showing off.
      touch.relative = false;
      hold.release();
    }
    _viewOnly = value;
    _gateInput();
    notifyListeners();
  }

  /// Whether anything goes from this view to the remote: nothing while it
  /// is only looked at, and nothing while it is not seen (a tab behind
  /// another, a hidden window, a picture covered by recording mode, the
  /// app locked). A key sent from a panel or a bar that is still on the
  /// screen while the picture is covered goes nowhere.
  void _gateInput() {
    final sends = !_viewOnly && !_paused;
    pointer.enabled = sends;
    keyboard.enabled = sends;
    touch.sendInput = sends;
  }

  ScreenFit get fit => viewport.fit;
  set fit(ScreenFit value) {
    if (viewport.fit == value) return;
    viewport.fit = value;
    viewport.resetZoom();
    notifyListeners();
  }

  ScreenTouchMode get touchMode => touch.mode;
  set touchMode(ScreenTouchMode value) {
    if (touch.mode == value) return;
    touch.cancel();
    touch.mode = value;
    if (value == ScreenTouchMode.mousePointer) {
      if (pointer.placed) {
        touch.placePointer(pointer.x, pointer.y);
      } else {
        touch.placePointer(width ~/ 2, height ~/ 2);
      }
    }
    notifyListeners();
  }

  void resetZoom() {
    viewport.resetZoom();
    notifyListeners();
  }

  /// What the person made of this view, for the view of the same screen once
  /// it is connected again (iOS closes a screen in the background): the
  /// scaling, the zoom and pan, view only, Touch or Mouse pointer.
  ScreenControllerKept kept() =>
      ScreenControllerKept(view: viewport.kept(), viewOnly: viewOnly, touchMode: touchMode);

  /// Back to what [kept] took.
  void restore(ScreenControllerKept kept) {
    viewOnly = kept.viewOnly;
    touchMode = kept.touchMode;
    viewport.restore(kept.view);
    notifyListeners();
  }

  /// The last input came from a finger (true) or a mouse: it decides what is
  /// drawn at the pointer.
  bool get lastInputTouch => _lastInputTouch;
  bool _lastInputTouch = false;

  void noteInput({required bool touch}) {
    if (_lastInputTouch == touch) return;
    _lastInputTouch = touch;
    notifyListeners();
  }

  /// What the painter draws at the remote pointer, and where (remote pixels).
  (ScreenCursorDraw, int, int) get cursorDraw {
    if (_viewOnly) return (ScreenCursorDraw.none, 0, 0);
    final pointerMode = lastInputTouch && touch.mode == ScreenTouchMode.mousePointer;
    final (x, y) = pointerMode ? touch.pointerPosition : (pointer.x, pointer.y);
    // A finger sends movement, not a place: where the remote's pointer is is
    // the remote's to draw (a game hides it), and nothing is known of it here.
    if (pointerMode && _relativeMouse) return (ScreenCursorDraw.none, x, y);
    final c = _cursor;
    if (c != null) {
      // Off the picture the system's pointer shows; the remote's is not drawn at the edge.
      if (c.hidden || (!pointer.placed && !pointerMode) || (!pointerMode && mouse.outside)) {
        return (ScreenCursorDraw.none, x, y);
      }
      return (ScreenCursorDraw.remote, x, y);
    }
    return pointerMode ? (ScreenCursorDraw.arrow, x, y) : (ScreenCursorDraw.none, x, y);
  }

  /// The system's pointer over the picture: hidden while the server's shape
  /// is drawn in its place (or the server hides it) and while it is held
  /// for relative mouse (a computer's own part hides it too; on Linux this
  /// is what keeps it hidden), the usual arrow else, and over the bars beside
  /// the picture ([ScreenMouse.outside]).
  MouseCursor get mouseCursor => hold.held || !(_viewOnly || _cursor == null || mouse.outside)
      ? SystemMouseCursors.none
      : SystemMouseCursors.basic;

  /// The drawn cursor's size per remote pixel: the picture's, but never so
  /// small on a fitted picture that it is hard to find.
  double get cursorScale => math.max(viewport.scale, 0.75);

  /// The bottom of the view a phone's soft keyboard (and the key bar over it)
  /// covers: the picture keeps its size and slides up so that the pointer, or
  /// the last tap, stays above them ([ScreenViewport.reveal]). Called after a
  /// layout, never during one (it repaints).
  void setObscuredBottom(double value) {
    final before = viewport.obscuredBottom;
    if ((value - before).abs() < 0.5) return;
    viewport.obscuredBottom = value;
    if (value > before) {
      final pointerMode = touch.mode == ScreenTouchMode.mousePointer;
      if (pointerMode || pointer.placed) {
        final (x, y) = pointerMode ? touch.pointerPosition : (pointer.x, pointer.y);
        viewport.reveal(x + 0.5, y + 0.5);
      }
    }
    notifyListeners();
  }

  // The view's size.

  /// RDP's "resize the remote to fit": the view's size is told to the
  /// session once it has stayed the same for [resizeSettle]. Off by default
  /// (VNC servers that resize come in a later step). Turned on, the size the
  /// view has now is told at once; a server that takes no resize turns it
  /// off again ([onResizeUnavailable]).
  bool get followViewSize => _followViewSize;
  bool _followViewSize = false;
  set followViewSize(bool follow) {
    if (follow == _followViewSize) return;
    _followViewSize = follow;
    _resizeTimer?.cancel();
    if (!follow) return;
    _askedSize = Size.zero;
    _ask(viewport.viewSize, after: Duration.zero);
  }

  /// The server said it takes no resize (the engine's
  /// `{"resize_unavailable": true}`): [followViewSize] is off again, the
  /// picture stays fitted, and whoever shows the view says so.
  VoidCallback? onResizeUnavailable;

  static const resizeSettle = Duration(milliseconds: 300);
  Size _askedSize = Size.zero;
  Timer? _resizeTimer;

  /// The view laid out at [size], keeping [insets] clear at fit.
  void layoutView(Size size, {EdgeInsets insets = EdgeInsets.zero, double devicePixelRatio = 1}) {
    viewport.setView(size, insets: insets, devicePixelRatio: devicePixelRatio);
    if (_followViewSize) _ask(size, after: resizeSettle);
  }

  /// How many displays the host asks its remote for (its options, on this
  /// kind of device): a view that follows its size then asks for that many,
  /// each the view's size, where one display is asked to resize.
  int displayCount = 1;

  /// The most pixels the remote's whole desktop may have on this device
  /// (a phone's ceiling), or null: fewer displays are asked for where the
  /// view's size times [displayCount] would pass it.
  int? maxDesktopPixels;

  /// How large the host asks its remote to draw text, in percent (its
  /// options; 0: nothing said): kept in every layout a view asks for, so
  /// following the view's size never takes it back.
  int textScale = 0;

  /// Asks the remote for another text size in the running session (an RDP
  /// screen): the displays it has, each with [percent] (one of
  /// [ScreenOptions.textScales]; 0 says none). Kept for the layouts a view
  /// asks for after. A server that does not change a running session's
  /// displays leaves it as it is.
  void setTextScale(int percent) {
    final w = desktopWidth > 0 ? desktopWidth : width;
    final h = desktopHeight > 0 ? desktopHeight : height;
    if (_disposed || !ScreenOptions.textScales.contains(percent) || w <= 0 || h <= 0) return;
    textScale = percent;
    // Where the remote follows the view in the screen's own pixels, the
    // text made as much larger again (ScreenViewSize.scaleOn).
    if (_followViewSize) {
      percent = ScreenViewSize.scaleOn(
          percent, ScreenViewSize.ratioFor(viewport.devicePixelRatio, phone: maxDesktopPixels != null));
    }
    _sentScale = percent;
    final have = displays.value.list;
    session.setDisplays(have.length > 1
        ? [
            for (final d in have)
              ScreenDisplaySpec(
                  x: d.x, y: d.y, width: d.width, height: d.height, scale: percent, primary: d.primary),
          ]
        : [ScreenDisplaySpec(width: w, height: h, scale: percent, primary: true)]);
  }

  /// Tells the session the view's [size] once it has stayed the same for
  /// [after], where it is not the remote's already.
  void _ask(Size size, {required Duration after}) {
    // In the screen's own pixels, the text made as much larger: sharp on a
    // screen scaled above 100% (ScreenViewSize.ratioFor).
    final ratio = ScreenViewSize.ratioFor(viewport.devicePixelRatio, phone: maxDesktopPixels != null);
    if (size.isEmpty || (size == _askedSize && ratio == _askedRatio)) return;
    // The first time: the scale this session started with, the one given for
    // the view that last followed its tab (screen_shell_service's startScale).
    _sentScale ??= ScreenViewSize.scaleOn(textScale, ScreenViewSize.lastFollowedRatio);
    _askedSize = size;
    _askedRatio = ratio;
    ScreenViewSize.lastFollowed = size;
    ScreenViewSize.lastFollowedRatio = ratio;
    _resizeTimer?.cancel();
    _resizeTimer = Timer(after, () {
      if (_disposed || !_followViewSize) return;
      final pixels = ScreenViewSize.pixelsOf(size, ratio);
      final scale = ScreenViewSize.scaleOn(textScale, ratio);
      if (displayCount > 1) {
        final want =
            ScreenViewSize.displaysOf(displayCount, pixels, scale: scale, maxDesktopPixels: maxDesktopPixels);
        final have = displays.value.list;
        // The same size and the same scale: nothing to ask (a move to a
        // monitor scaled otherwise that gives the same pixels still asks).
        final same = scale == _sentScale &&
            have.length == want.length &&
            [for (final d in have) (d.x, d.width, d.height)].toString() ==
                [for (final d in want) (d.x, d.width, d.height)].toString();
        if (!same) session.setDisplays(want);
        _sentScale = scale;
        return;
      }
      final one = ScreenViewSize.displaysOf(1, pixels, scale: scale).first;
      final resized = one.width != width || one.height != height;
      if (scale != _sentScale) {
        // Another scale than the session has (a move to a monitor scaled
        // otherwise, back to 100% included): said with the size, as a
        // layout, since a resize keeps the session's scale.
        session.setDisplays([one]);
      } else if (resized) {
        session.resize(one.width, one.height);
      }
      _sentScale = scale;
    });
  }

  double _askedRatio = 1;

  /// The scale the remote was last asked for (null until the view first
  /// follows its tab; then the one the session started with).
  int? _sentScale;

  @override
  void dispose() {
    if (_disposed) return;
    // A view that goes no longer lets the sound play: the last one to go
    // silences it (unless it handed its part to a window of its own).
    if (_soundPlays && !_closed) ScreenSoundGate.of(session).release(this);
    _disposed = true;
    _resizeTimer?.cancel();
    _gate?.cancel();
    unawaited(_sub.cancel());
    hold
      ..removeListener(notifyListeners)
      ..dispose();
    _detailsTimer?.cancel();
    _detailsTimer = null;
    details.dispose();
    displays.dispose();
    touch.dispose();
    keyboard.dispose();
    _clearTiles();
    _cursor?.image?.dispose();
    _cursor = null;
    super.dispose();
  }
}

/// A screen view's settings kept across a reconnect ([ScreenController.kept]).
class ScreenControllerKept {
  const ScreenControllerKept({required this.view, required this.viewOnly, required this.touchMode});

  final ScreenViewKept view;
  final bool viewOnly;
  final ScreenTouchMode touchMode;
}
