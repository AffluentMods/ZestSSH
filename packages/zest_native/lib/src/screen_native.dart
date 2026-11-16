// Remote screens (4.0): the native layer a ScreenSession talks to. The Rust library
// ([RustScreenNative], rust/src/screen through rust/src/lib.rs's zest_screen_* functions) or a fake
// in tests (screen_testing.dart). The session decodes what the native layer reports (kind, a,
// bytes) the same way for both, so the fake exercises the real decoding.
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'screen_bindings.dart';

/// What the native layer calls a session back with: rust/src/screen/mod.rs's event kinds, a
/// number, and bytes (already copied into Dart memory and freed natively), or null.
typedef ScreenNativeEvent = void Function(int kind, int a, Uint8List? data);

/// rust/src/screen/mod.rs's `event` kinds.
abstract final class ScreenEventKind {
  static const send = 1;
  static const connected = 2;
  static const frame = 3;
  static const closed = 4;
  static const drained = 5;
  static const clipboard = 6;
  static const bell = 7;
  static const resize = 8;
  static const info = 9;
  static const cursor = 10;

  /// The remote's displays, as rectangles of the picture (RDP; 4.0).
  static const displays = 11;
}

/// One changed tile: where it goes, and its pixels (RGBA, opaque, `width * height * 4` bytes), a
/// view into the frame's memory, valid until [ScreenFrame.free].
class ScreenTile {
  ScreenTile(this.x, this.y, this.width, this.height, this.pixels);
  final int x;
  final int y;
  final int width;
  final int height;
  final Uint8List pixels;
}

/// The tiles that changed since the last frame was taken. Their pixels may live in native memory:
/// copy what is needed, then [free] it (once; later calls do nothing).
class ScreenFrame {
  ScreenFrame({
    required this.seq,
    required this.width,
    required this.height,
    required this.updates,
    required this.tiles,
    this.firstChangeUs = 0,
    this.lastDoneUs = 0,
    this.takenUs = 0,
    void Function()? onFree,
  }) : _onFree = onFree;

  /// The frame's number (the newest update in it).
  final int seq;

  /// The whole screen's size.
  final int width;
  final int height;

  /// Server updates merged into it.
  final int updates;
  final List<ScreenTile> tiles;

  /// On [ScreenNative.nowUs]'s clock: the oldest change in it reached the engine, the newest
  /// update ended, it was packed.
  final int firstChangeUs;
  final int lastDoneUs;
  final int takenUs;

  final void Function()? _onFree;
  bool _freed = false;

  bool get isFreed => _freed;

  /// The pixels' bytes, every tile together.
  int get bytes => tiles.fold(0, (n, t) => n + t.pixels.length);

  void free() {
    if (_freed) return;
    _freed = true;
    _onFree?.call();
  }
}

/// The native screen engine, one handle per session.
abstract interface class ScreenNative {
  /// Starts a session from [requestJson] (rust/src/screen/mod.rs OpenRequest, UTF-8 JSON; it may
  /// hold a password: the native copy is wiped once read). [onEvent] gets every event, CLOSED
  /// last. Returns the handle, or 0 when the request is refused (a wrong request, or no engine
  /// for its kind in this build).
  int open(String requestJson, ScreenNativeEvent onEvent);

  /// Bytes the channel received; returns how many wait unread in the engine.
  int feed(int handle, Uint8List data);

  /// The channel ended cleanly.
  void feedEnd(int handle);

  /// The channel failed: [network] true for the network under SSH, false for SSH itself.
  void feedFail(int handle, {required bool network, required String message});

  void pointer(int handle, int x, int y, int buttons);

  /// The mouse moved by ([dx], [dy]) with [buttons] down: sent as movement where the session
  /// asked for relative mouse and its server takes it, else nothing.
  void pointerRelative(int handle, int dx, int dy, int buttons);
  void key(int handle, int keysym, int scancode, {required bool down});
  void clipboard(int handle, String text);

  /// Whether the clipboard is shared with the remote from now on. An RDP session with the
  /// clipboard's channel: off wipes the text given by [clipboard] and takes none of the
  /// server's. Nothing for VNC.
  void clipboardShare(int handle, {required bool on});

  /// Whether the remote's sound is played from now on (an RDP session with the sound channel;
  /// off empties what waits). Nothing otherwise.
  void sound(int handle, {required bool on});
  void resize(int handle, int width, int height);

  /// The displays the remote should have from now on: JSON, a list of
  /// `{x, y, width, height, scale, primary}` (rust/src/screen/rdp_layout.rs DisplaySpec). False
  /// where the engine did not take the JSON as such a list.
  bool displays(int handle, String json);

  /// What [takeFrame] gives from now on: the rectangle [x], [y], [width], [height] of the
  /// picture (one of the remote's displays), its tiles' places from that rectangle's corner
  /// and the frame's size the rectangle's; or all of the picture (a width or height of 0).
  /// It starts with all of the part: take a frame after this without waiting to be told.
  void show(int handle, int x, int y, int width, int height);

  /// Opens a view on the rectangle [x], [y], [width], [height] of the session's picture, its
  /// own picture [divide] times smaller a side (1 to 16): its number, or 0 (no such session,
  /// sixteen open already, an empty rectangle).
  int viewOpen(int handle, int x, int y, int width, int height, int divide);

  /// A view's changed tiles, their places from the view's corner; null when none changed or
  /// the session or the view is gone ([viewAlive] tells which).
  ScreenFrame? viewTakeFrame(int handle, int view);
  bool viewAlive(int handle, int view);
  void viewClose(int handle, int view);
  void fullRefresh(int handle);
  void pause(int handle);
  void resume(int handle);

  /// The tiles that changed, or null when none did.
  ScreenFrame? takeFrame(int handle);

  /// Microseconds on the clock frames are stamped with.
  int nowUs();

  /// Ends the session. Returns within a few milliseconds whatever the session is busy with (it
  /// stops at its next piece of work); its CLOSED event may come after this returns, and is the
  /// last. [onEvent] stays callable until then.
  void close(int handle);

  /// [onEvent] of [handle] is no longer needed: called once its CLOSED event was delivered.
  void release(int handle);
}

/// [ScreenNative] over the Rust library: callbacks through a `NativeCallable.listener` per
/// session (Rust calls it from the session's thread; Dart gets the messages on the isolate's loop).
///
/// The functions exist only in a library built with the feature "vnc" or "rdp" (hook/build.dart,
/// cargo_features); a call into a library without them throws on its first use.
class RustScreenNative implements ScreenNative {
  RustScreenNative();

  final _callables = <int, NativeCallable<ScreenCallbackC>>{};
  final _buffers = <int, (Pointer<Uint8>, int)>{};

  @override
  int open(String requestJson, ScreenNativeEvent onEvent) {
    final callable = NativeCallable<ScreenCallbackC>.listener((int handle, int kind, int a, Pointer<Uint8> data, int len) {
      Uint8List? bytes;
      if (data != nullptr) {
        bytes = Uint8List.fromList(data.asTypedList(len));
        zestScreenFreeBytesC(data, len);
      }
      onEvent(kind, a, bytes);
    });
    final text = utf8.encode(requestJson);
    final json = malloc<Uint8>(text.length + 1);
    final int handle;
    try {
      json.asTypedList(text.length + 1)
        ..setAll(0, text)
        ..[text.length] = 0;
      handle = zestScreenOpenC(json.cast(), callable.nativeFunction);
    } finally {
      // The request may hold a password: wiped before it is freed (the Dart string cannot be).
      json.asTypedList(text.length + 1).fillRange(0, text.length + 1, 0);
      text.fillRange(0, text.length, 0);
      malloc.free(json);
    }
    if (handle == 0) {
      callable.close();
      return 0;
    }
    _callables[handle] = callable;
    return handle;
  }

  @override
  int feed(int handle, Uint8List data) {
    if (data.isEmpty) return 0;
    var (buffer, size) = _buffers[handle] ?? (nullptr, 0);
    if (data.length > size) {
      if (buffer != nullptr) malloc.free(buffer);
      size = data.length < 65536 ? 65536 : data.length;
      buffer = malloc<Uint8>(size);
      _buffers[handle] = (buffer, size);
    }
    buffer.asTypedList(data.length).setAll(0, data);
    return zestScreenFeedC(handle, buffer, data.length);
  }

  @override
  void feedEnd(int handle) => zestScreenFeedEndC(handle);

  @override
  void feedFail(int handle, {required bool network, required String message}) {
    final text = utf8.encode(message);
    final p = malloc<Uint8>(text.isEmpty ? 1 : text.length);
    try {
      p.asTypedList(text.length).setAll(0, text);
      zestScreenFeedFailC(handle, network ? 2 : 1, p, text.length);
    } finally {
      malloc.free(p);
    }
  }

  @override
  void pointer(int handle, int x, int y, int buttons) => zestScreenPointerC(handle, x, y, buttons);

  @override
  void pointerRelative(int handle, int dx, int dy, int buttons) =>
      zestScreenPointerRelativeC(handle, dx, dy, buttons);

  @override
  void key(int handle, int keysym, int scancode, {required bool down}) =>
      zestScreenKeyC(handle, keysym, scancode, down ? 1 : 0);

  @override
  void clipboard(int handle, String text) {
    final bytes = utf8.encode(text);
    final p = malloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    try {
      p.asTypedList(bytes.length).setAll(0, bytes);
      zestScreenClipboardC(handle, p, bytes.length);
    } finally {
      // Clipboard text is the person's: not left in freed memory.
      p.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
      malloc.free(p);
    }
  }

  @override
  void clipboardShare(int handle, {required bool on}) => zestScreenClipboardShareC(handle, on ? 1 : 0);

  @override
  void sound(int handle, {required bool on}) => zestScreenSoundC(handle, on ? 1 : 0);

  @override
  void resize(int handle, int width, int height) => zestScreenResizeC(handle, width, height);

  @override
  bool displays(int handle, String json) {
    final bytes = utf8.encode(json);
    final p = malloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    try {
      p.asTypedList(bytes.length).setAll(0, bytes);
      return zestScreenDisplaysC(handle, p, bytes.length) == 0;
    } finally {
      malloc.free(p);
    }
  }

  @override
  void show(int handle, int x, int y, int width, int height) => zestScreenShowC(handle, x, y, width, height);

  @override
  int viewOpen(int handle, int x, int y, int width, int height, int divide) =>
      zestScreenViewOpenC(handle, x, y, width, height, divide);

  @override
  ScreenFrame? viewTakeFrame(int handle, int view) => _frame(zestScreenViewTakeFrameC(handle, view));

  @override
  bool viewAlive(int handle, int view) => zestScreenViewAliveC(handle, view) != 0;

  @override
  void viewClose(int handle, int view) => zestScreenViewCloseC(handle, view);

  @override
  void fullRefresh(int handle) => zestScreenFullRefreshC(handle);

  @override
  void pause(int handle) => zestScreenPauseC(handle);

  @override
  void resume(int handle) => zestScreenResumeC(handle);

  @override
  ScreenFrame? takeFrame(int handle) => _frame(zestScreenTakeFrameC(handle));

  /// A packet as a frame whose pixels stay in native memory until it is freed; null for none.
  static ScreenFrame? _frame(Pointer<ScreenFramePacketC> packet) {
    if (packet == nullptr) return null;
    final p = packet.ref;
    final all = p.pixels.asTypedList(p.pixelsLen);
    return ScreenFrame(
      seq: p.seq,
      width: p.width,
      height: p.height,
      updates: p.updates,
      tiles: [
        for (var i = 0; i < p.tileCount; i++)
          () {
            final t = (p.tiles + i).ref;
            final len = t.width * t.height * 4;
            return ScreenTile(t.x, t.y, t.width, t.height, Uint8List.sublistView(all, t.offset, t.offset + len));
          }(),
      ],
      firstChangeUs: p.firstChangeUs,
      lastDoneUs: p.lastDoneUs,
      takenUs: p.takenUs,
      onFree: () => zestScreenFreeFrameC(packet),
    );
  }

  @override
  int nowUs() => zestScreenNowUsC();

  @override
  void close(int handle) {
    zestScreenCloseC(handle);
    final buffer = _buffers.remove(handle);
    if (buffer != null) malloc.free(buffer.$1);
  }

  @override
  void release(int handle) => _callables.remove(handle)?.close();
}
