// Mosh, built in (4.0): the native layer a Mosh session talks to. The Rust library
// ([RustMoshNative], rust/src/mosh through rust/src/lib.rs's zest_mosh_* functions) or a fake in
// tests (mosh_testing.dart).
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'mosh_bindings.dart';

/// What the native layer calls a session back with: rust/src/mosh/mod.rs's event kinds, a
/// number, and bytes (already copied into Dart memory and freed natively), or null.
typedef MoshNativeEvent = void Function(int kind, int a, Uint8List? data);

/// rust/src/mosh/mod.rs's `event` kinds.
abstract final class MoshEventKind {
  /// Terminal output (the server's screen diffs).
  static const hostBytes = 1;

  /// The server answered for the first time (JSON: address).
  static const connected = 2;

  /// Once a second (JSON: last_heard_ms, srtt_ms).
  static const status = 3;

  /// The session ended (JSON: reason, message); the last event.
  static const closed = 4;

  /// For the log (JSON).
  static const info = 5;
}

/// The native Mosh client, one handle per session.
abstract interface class MoshNative {
  /// Starts a session from [requestJson] (rust/src/mosh/mod.rs OpenRequest; it holds the session
  /// key: the native copy is wiped once read). [onEvent] gets every event, CLOSED last. Returns
  /// the handle, or 0 when the request is refused.
  int open(String requestJson, MoshNativeEvent onEvent);

  /// What was typed.
  void keys(int handle, Uint8List data);

  /// The terminal's size in characters.
  void resize(int handle, int cols, int rows);

  /// Ends the session (the server is told). Returns at once; CLOSED comes later and is the last
  /// event: [onEvent] stays callable until then.
  void close(int handle);

  /// [onEvent] of [handle] is no longer needed: called once its CLOSED event was delivered.
  void release(int handle);
}

/// [MoshNative] over the Rust library: callbacks through a `NativeCallable.listener` per session
/// (Rust calls it from the session's thread; Dart gets the messages on the isolate's loop, in
/// order).
class RustMoshNative implements MoshNative {
  RustMoshNative();

  final _callables = <int, NativeCallable<MoshCallbackC>>{};

  @override
  int open(String requestJson, MoshNativeEvent onEvent) {
    final callable = NativeCallable<MoshCallbackC>.listener((int handle, int kind, int a, Pointer<Uint8> data, int len) {
      Uint8List? bytes;
      if (data != nullptr) {
        bytes = Uint8List.fromList(data.asTypedList(len));
        zestMoshFreeBytesC(data, len);
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
      handle = zestMoshOpenC(json.cast(), callable.nativeFunction);
    } finally {
      // The request holds the session key: wiped before it is freed (the Dart string cannot be).
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
  void keys(int handle, Uint8List data) {
    if (data.isEmpty) return;
    final p = malloc<Uint8>(data.length);
    try {
      p.asTypedList(data.length).setAll(0, data);
      zestMoshKeysC(handle, p, data.length);
    } finally {
      // What was typed may be a password: not left in freed memory.
      p.asTypedList(data.length).fillRange(0, data.length, 0);
      malloc.free(p);
    }
  }

  @override
  void resize(int handle, int cols, int rows) => zestMoshResizeC(handle, cols, rows);

  @override
  void close(int handle) => zestMoshCloseC(handle);

  @override
  void release(int handle) => _callables.remove(handle)?.close();
}
