// Mosh, built in (4.0): the C functions of rust/src/lib.rs's zest_mosh_* family, used through
// RustMoshNative (mosh_native.dart). They are in the library only when it is built with the
// feature "mosh" (hook/build.dart, cargo_features from the app's pubspec); a @Native function is
// looked up on its first call, so a build without them fails only if one is called.
@DefaultAsset('package:zest_native/src/bindings.dart')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// The callback Rust calls from the session's thread: (session, kind, a, data, len).
typedef MoshCallbackC = Void Function(Uint64, Uint32, Int64, Pointer<Uint8>, Size);

@Native<Uint64 Function(Pointer<Utf8>, Pointer<NativeFunction<MoshCallbackC>>)>(symbol: 'zest_mosh_open')
external int zestMoshOpenC(Pointer<Utf8> request, Pointer<NativeFunction<MoshCallbackC>> callback);

@Native<Void Function(Uint64, Pointer<Uint8>, Size)>(symbol: 'zest_mosh_keys', isLeaf: true)
external void zestMoshKeysC(int handle, Pointer<Uint8> data, int len);

@Native<Void Function(Uint64, Uint32, Uint32)>(symbol: 'zest_mosh_resize', isLeaf: true)
external void zestMoshResizeC(int handle, int cols, int rows);

@Native<Void Function(Uint64)>(symbol: 'zest_mosh_close', isLeaf: true)
external void zestMoshCloseC(int handle);

@Native<Void Function(Pointer<Uint8>, Size)>(symbol: 'zest_mosh_free_bytes', isLeaf: true)
external void zestMoshFreeBytesC(Pointer<Uint8> data, int len);
