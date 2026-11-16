// Remote screens (4.0): a ScreenNative for tests, with no Rust behind it. It records what a
// session asks of the engine, and plays the engine's side: events (as rust/src/screen/mod.rs sends
// them, delivered asynchronously as a NativeCallable.listener delivers them), frames and the
// number of bytes waiting.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'screen_native.dart';

/// One session the fake opened.
class FakeScreenSession {
  FakeScreenSession(this.handle, this.request, this._onEvent);
  final int handle;

  /// The start request, decoded (it holds the password: tests only).
  final Map<String, Object?> request;
  final ScreenNativeEvent _onEvent;

  final fed = BytesBuilder(copy: true);
  bool ended = false;
  ({bool network, String message})? failed;
  final pointers = <(int, int, int)>[];

  /// Each movement sent as movement ([ScreenNative.pointerRelative]): dx, dy, buttons.
  final relativePointers = <(int, int, int)>[];
  final keys = <(int keysym, int scancode, bool down)>[];
  final clipboard = <String>[];

  /// Each time the app said whether the clipboard is shared ([ScreenNative.clipboardShare]).
  final clipboardShares = <bool>[];

  /// Each time the app said whether the remote's sound plays ([ScreenNative.sound]).
  final sounds = <bool>[];
  final resizes = <(int, int)>[];

  /// Each layout the app asked for ([ScreenNative.displays]), decoded.
  final layouts = <List<Map<String, Object?>>>[];

  /// Each part the session's reader was shown ([ScreenNative.show]): x, y, width, height (a
  /// width or height of 0: all of the picture).
  final shown = <(int, int, int, int)>[];

  /// The views open, by number: the rectangle and the divisor each was opened with.
  final views = <int, ({int x, int y, int width, int height, int divide})>{};

  /// What a view gives next ([ScreenNative.viewTakeFrame]), by its number.
  final viewFrames = <int, List<ScreenFrame>>{};
  int _nextView = 1;
  int fullRefreshes = 0;
  int pauses = 0;
  int resumes = 0;
  bool closed = false;
  bool released = false;
  final frames = <ScreenFrame>[];

  /// What [ScreenNative.feed] answers: bytes waiting in the engine.
  int queued = 0;

  bool _closedSent = false;

  /// An engine event, delivered on a later turn of the event loop. Nothing after CLOSED.
  void emit(int kind, {int a = 0, Uint8List? data}) {
    if (_closedSent) throw StateError('the engine sends nothing after CLOSED');
    if (kind == ScreenEventKind.closed) _closedSent = true;
    scheduleMicrotask(() => _onEvent(kind, a, data));
  }

  void emitJson(int kind, Map<String, Object?> json) => emit(kind, data: utf8.encode(jsonEncode(json)));

  /// The handshake done, with the server's facts.
  void connect({String name = 'demo', int width = 1280, int height = 800, String security = 'None'}) =>
      emitJson(ScreenEventKind.connected, {'name': name, 'width': width, 'height': height, 'security': security});

  /// The remote's displays, as the engine tells them: rectangles of the picture.
  void displays(List<List<int>> rects) => emitJson(ScreenEventKind.displays, {'displays': rects});

  /// Bytes the engine writes for the server.
  void send(List<int> bytes) => emit(ScreenEventKind.send, data: Uint8List.fromList(bytes));

  /// The session ends, as the engine reports it.
  void closeWith(String reason, String message, {Map<String, Object?> extra = const {}}) => emitJson(
    ScreenEventKind.closed,
    {'reason': reason, 'message': message, if (reason != 'local') 'error': message, ...extra},
  );

  bool get closedSent => _closedSent;
}

/// [ScreenNative] for tests.
class FakeScreenNative implements ScreenNative {
  FakeScreenNative({this.refuse = false});

  /// Every open is refused (handle 0), as a build without the engine would.
  bool refuse;
  final sessions = <FakeScreenSession>[];
  int _next = 1;
  int clock = 0;

  /// Called as each session opens (a test plays the engine's side from here).
  void Function(FakeScreenSession session)? onOpen;

  FakeScreenSession? byHandle(int handle) {
    for (final s in sessions) {
      if (s.handle == handle) return s;
    }
    return null;
  }

  FakeScreenSession _s(int handle) => byHandle(handle) ?? (throw StateError('no fake session $handle'));

  @override
  int open(String requestJson, ScreenNativeEvent onEvent) {
    if (refuse) return 0;
    final s = FakeScreenSession(_next++, (jsonDecode(requestJson) as Map).cast<String, Object?>(), onEvent);
    sessions.add(s);
    onOpen?.call(s);
    return s.handle;
  }

  @override
  int feed(int handle, Uint8List data) {
    final s = _s(handle);
    s.fed.add(data);
    return s.queued;
  }

  @override
  void feedEnd(int handle) => _s(handle).ended = true;

  @override
  void feedFail(int handle, {required bool network, required String message}) =>
      _s(handle).failed = (network: network, message: message);

  @override
  void pointer(int handle, int x, int y, int buttons) => _s(handle).pointers.add((x, y, buttons));

  @override
  void pointerRelative(int handle, int dx, int dy, int buttons) =>
      _s(handle).relativePointers.add((dx, dy, buttons));

  @override
  void key(int handle, int keysym, int scancode, {required bool down}) =>
      _s(handle).keys.add((keysym, scancode, down));

  @override
  void clipboard(int handle, String text) => _s(handle).clipboard.add(text);

  @override
  void clipboardShare(int handle, {required bool on}) => _s(handle).clipboardShares.add(on);

  @override
  void sound(int handle, {required bool on}) => _s(handle).sounds.add(on);

  @override
  void resize(int handle, int width, int height) => _s(handle).resizes.add((width, height));

  @override
  bool displays(int handle, String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return false;
    }
    if (decoded is! List || decoded.any((d) => d is! Map || d['width'] is! int || d['height'] is! int)) return false;
    _s(handle).layouts.add([for (final d in decoded) (d as Map).cast<String, Object?>()]);
    return true;
  }

  @override
  void show(int handle, int x, int y, int width, int height) => byHandle(handle)?.shown.add((x, y, width, height));

  /// As the engine: 0 for a session that is gone, an empty rectangle, a divisor that is not
  /// 1 to 16, or a seventeenth view.
  @override
  int viewOpen(int handle, int x, int y, int width, int height, int divide) {
    final s = byHandle(handle);
    if (s == null || s.closed || s.closedSent) return 0;
    if (width <= 0 || height <= 0 || divide < 1 || divide > 16 || s.views.length >= 16) return 0;
    final view = s._nextView++;
    s.views[view] = (x: x, y: y, width: width, height: height, divide: divide);
    return view;
  }

  @override
  ScreenFrame? viewTakeFrame(int handle, int view) {
    final s = byHandle(handle);
    if (s == null || s.closed || !s.views.containsKey(view)) return null;
    final frames = s.viewFrames[view];
    return frames == null || frames.isEmpty ? null : frames.removeAt(0);
  }

  @override
  bool viewAlive(int handle, int view) {
    final s = byHandle(handle);
    return s != null && !s.closed && !s.closedSent && s.views.containsKey(view);
  }

  @override
  void viewClose(int handle, int view) => byHandle(handle)?.views.remove(view);

  @override
  void fullRefresh(int handle) => _s(handle).fullRefreshes++;

  @override
  void pause(int handle) => _s(handle).pauses++;

  @override
  void resume(int handle) => _s(handle).resumes++;

  @override
  ScreenFrame? takeFrame(int handle) {
    final s = _s(handle);
    return s.frames.isEmpty ? null : s.frames.removeAt(0);
  }

  @override
  int nowUs() => clock;

  /// As the engine: the thread joined; a session the app closed reports CLOSED (local) itself.
  @override
  void close(int handle) {
    final s = _s(handle);
    if (s.closed) return;
    s.closed = true;
    if (!s.closedSent) s.closeWith('local', 'closed');
  }

  @override
  void release(int handle) => _s(handle).released = true;
}
