// Remote screens (4.0): the C functions of rust/src/lib.rs's zest_screen_* family, used through
// RustScreenNative (screen_native.dart). They are in the library only when it is built with the
// feature "vnc" or "rdp" (hook/build.dart, cargo_features from the app's pubspec); a @Native
// function is looked up on its first call, so a build without them fails only if one is called.
@DefaultAsset('package:zest_native/src/bindings.dart')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// The callback Rust calls from the session's thread: (session, kind, a, data, len).
typedef ScreenCallbackC = Void Function(Uint64, Uint32, Int64, Pointer<Uint8>, Size);

@Native<Uint64 Function(Pointer<Utf8>, Pointer<NativeFunction<ScreenCallbackC>>)>(symbol: 'zest_screen_open')
external int zestScreenOpenC(Pointer<Utf8> request, Pointer<NativeFunction<ScreenCallbackC>> callback);

@Native<Uint64 Function(Uint64, Pointer<Uint8>, Size)>(symbol: 'zest_screen_feed', isLeaf: true)
external int zestScreenFeedC(int handle, Pointer<Uint8> data, int len);

@Native<Void Function(Uint64)>(symbol: 'zest_screen_feed_end', isLeaf: true)
external void zestScreenFeedEndC(int handle);

/// The channel failed: reason 1 (the SSH connection or channel) or 2 (the network), a UTF-8 message.
@Native<Void Function(Uint64, Uint32, Pointer<Uint8>, Size)>(symbol: 'zest_screen_feed_fail', isLeaf: true)
external void zestScreenFeedFailC(int handle, int reason, Pointer<Uint8> message, int len);

@Native<Void Function(Uint64)>(symbol: 'zest_screen_pause', isLeaf: true)
external void zestScreenPauseC(int handle);

@Native<Void Function(Uint64)>(symbol: 'zest_screen_resume', isLeaf: true)
external void zestScreenResumeC(int handle);

@Native<Void Function(Uint64, Uint32, Uint32, Uint32)>(symbol: 'zest_screen_pointer', isLeaf: true)
external void zestScreenPointerC(int handle, int x, int y, int buttons);

/// The mouse moved by (dx, dy) with these buttons down: relative mouse (4.0).
@Native<Void Function(Uint64, Int32, Int32, Uint32)>(symbol: 'zest_screen_pointer_relative', isLeaf: true)
external void zestScreenPointerRelativeC(int handle, int dx, int dy, int buttons);

@Native<Void Function(Uint64, Uint32, Uint32, Uint32)>(symbol: 'zest_screen_key', isLeaf: true)
external void zestScreenKeyC(int handle, int keysym, int scancode, int down);

/// Text for the remote clipboard (UTF-8).
@Native<Void Function(Uint64, Pointer<Uint8>, Size)>(symbol: 'zest_screen_clipboard', isLeaf: true)
external void zestScreenClipboardC(int handle, Pointer<Uint8> text, int len);

/// Whether the clipboard is shared with the remote from now on (RDP's clipboard channel).
@Native<Void Function(Uint64, Int32)>(symbol: 'zest_screen_clipboard_share', isLeaf: true)
external void zestScreenClipboardShareC(int handle, int on);

/// Whether the remote's sound is played from now on (RDP's sound channel).
@Native<Void Function(Uint64, Int32)>(symbol: 'zest_screen_sound', isLeaf: true)
external void zestScreenSoundC(int handle, int on);

@Native<Void Function(Uint64, Uint32, Uint32)>(symbol: 'zest_screen_resize', isLeaf: true)
external void zestScreenResizeC(int handle, int width, int height);

/// The remote's displays from now on: UTF-8 JSON, a list of displays (4.0). 0, or -1
/// where the JSON is not such a list.
@Native<Int32 Function(Uint64, Pointer<Uint8>, Size)>(symbol: 'zest_screen_displays', isLeaf: true)
external int zestScreenDisplaysC(int handle, Pointer<Uint8> json, int len);

/// What the session's own reader takes from now on: a rectangle of the picture, or all of it
/// (a width or height of 0).
@Native<Void Function(Uint64, Uint32, Uint32, Uint32, Uint32)>(symbol: 'zest_screen_show', isLeaf: true)
external void zestScreenShowC(int handle, int x, int y, int width, int height);

/// A view on a rectangle of a session's picture: its number, or 0.
@Native<Uint32 Function(Uint64, Uint32, Uint32, Uint32, Uint32, Uint32)>(symbol: 'zest_screen_view_open', isLeaf: true)
external int zestScreenViewOpenC(int handle, int x, int y, int width, int height, int divide);

@Native<Pointer<ScreenFramePacketC> Function(Uint64, Uint32)>(symbol: 'zest_screen_view_take_frame', isLeaf: true)
external Pointer<ScreenFramePacketC> zestScreenViewTakeFrameC(int handle, int view);

@Native<Int32 Function(Uint64, Uint32)>(symbol: 'zest_screen_view_alive', isLeaf: true)
external int zestScreenViewAliveC(int handle, int view);

@Native<Void Function(Uint64, Uint32)>(symbol: 'zest_screen_view_close', isLeaf: true)
external void zestScreenViewCloseC(int handle, int view);

@Native<Void Function(Uint64)>(symbol: 'zest_screen_full_refresh', isLeaf: true)
external void zestScreenFullRefreshC(int handle);

@Native<Pointer<ScreenFramePacketC> Function(Uint64)>(symbol: 'zest_screen_take_frame', isLeaf: true)
external Pointer<ScreenFramePacketC> zestScreenTakeFrameC(int handle);

@Native<Void Function(Pointer<ScreenFramePacketC>)>(symbol: 'zest_screen_free_frame', isLeaf: true)
external void zestScreenFreeFrameC(Pointer<ScreenFramePacketC> packet);

@Native<Void Function(Pointer<Uint8>, Size)>(symbol: 'zest_screen_free_bytes', isLeaf: true)
external void zestScreenFreeBytesC(Pointer<Uint8> data, int len);

@Native<Int64 Function()>(symbol: 'zest_screen_now_us', isLeaf: true)
external int zestScreenNowUsC();

/// Joins the session's thread: can wait for it to finish its last step.
@Native<Void Function(Uint64)>(symbol: 'zest_screen_close')
external void zestScreenCloseC(int handle);

/// rust/src/screen/framebuffer.rs FrameTile.
final class ScreenFrameTileC extends Struct {
  @Uint32()
  external int x;
  @Uint32()
  external int y;
  @Uint32()
  external int width;
  @Uint32()
  external int height;
  @Uint64()
  external int offset;
}

/// rust/src/screen/framebuffer.rs FramePacket.
final class ScreenFramePacketC extends Struct {
  @Uint64()
  external int seq;
  @Uint32()
  external int width;
  @Uint32()
  external int height;
  @Uint32()
  external int tileCount;
  @Uint32()
  external int updates;
  external Pointer<ScreenFrameTileC> tiles;
  external Pointer<Uint8> pixels;
  @Uint64()
  external int pixelsLen;
  @Int64()
  external int firstChangeUs;
  @Int64()
  external int lastDoneUs;
  @Int64()
  external int takenUs;
}
