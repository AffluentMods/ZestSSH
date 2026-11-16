// The Rust library's C functions (rust/src/lib.rs). The asset is this library's own URI,
// package:zest_native/src/bindings.dart, which hook/build.dart builds the library under.
import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// `zest_native_version` in rust/src/lib.rs: a NUL-terminated string the library owns.
@Native<Pointer<Utf8> Function()>(symbol: 'zest_native_version', isLeaf: true)
external Pointer<Utf8> zestNativeVersionC();

/// `zest_ftps_open`: a new FTPS handle, not connected yet.
@Native<Uint64 Function()>(symbol: 'zest_ftps_open', isLeaf: true)
external int zestFtpsOpenC();

/// `zest_ftps_call`: one request (JSON) on a handle; blocks until it is done, so it is called on
/// a background isolate. The answer is freed with [zestStringFreeC].
@Native<Pointer<Utf8> Function(Uint64, Pointer<Utf8>)>(symbol: 'zest_ftps_call')
external Pointer<Utf8> zestFtpsCallC(int handle, Pointer<Utf8> request);

/// `zest_ftps_cancel`: asks a running transfer to stop; returns at once.
@Native<Void Function(Uint64)>(symbol: 'zest_ftps_cancel', isLeaf: true)
external void zestFtpsCancelC(int handle);

/// `zest_ftps_progress`: bytes the running transfer has moved; returns at once.
@Native<Uint64 Function(Uint64)>(symbol: 'zest_ftps_progress', isLeaf: true)
external int zestFtpsProgressC(int handle);

/// `zest_ftps_close`: QUIT and close_notify; can wait for the server, so on a background isolate.
@Native<Void Function(Uint64)>(symbol: 'zest_ftps_close')
external void zestFtpsCloseC(int handle);

/// `zest_string_free`: frees an answer of [zestFtpsCallC].
@Native<Void Function(Pointer<Utf8>)>(symbol: 'zest_string_free', isLeaf: true)
external void zestStringFreeC(Pointer<Utf8> s);
