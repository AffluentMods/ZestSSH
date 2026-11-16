import 'dart:ffi';
import 'dart:io' show OSError;

import 'package:ffi/ffi.dart';

const _waitObject0 = 0;

typedef _CreateSemaphoreNative =
    IntPtr Function(
      Pointer<Void> attributes,
      Int32 initial,
      Int32 maximum,
      Pointer<Utf16> name,
    );
typedef _CreateSemaphoreDart =
    int Function(
      Pointer<Void> attributes,
      int initial,
      int maximum,
      Pointer<Utf16> name,
    );
typedef _WaitNative = Uint32 Function(IntPtr handle, Uint32 milliseconds);
typedef _WaitDart = int Function(int handle, int milliseconds);
typedef _ReleaseSemaphoreNative =
    Int32 Function(IntPtr handle, Int32 count, Pointer<Int32> previous);
typedef _ReleaseSemaphoreDart =
    int Function(int handle, int count, Pointer<Int32> previous);
typedef _CloseHandleNative = Int32 Function(IntPtr handle);
typedef _CloseHandleDart = int Function(int handle);

/// A lock every program of this Windows session sees by [name] (`Local\...`),
/// a packaged one (a Microsoft Store app) among them: a semaphore of one
/// (kernel32's CreateSemaphoreW). A semaphore and not a mutex: a mutex is
/// held by a thread, and Dart can go on on another one after an await.
///
/// Taken with [tryTake], which never waits: a caller that is to wait asks
/// again. Given back with [release], or by Windows where the program ends,
/// once no program holds the name open.
class WindowsNamedLock {
  WindowsNamedLock._(this._handle);

  final int _handle;
  bool _released = false;

  static final _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final _create = _kernel32
      .lookupFunction<_CreateSemaphoreNative, _CreateSemaphoreDart>(
        'CreateSemaphoreW',
      );
  static final _wait = _kernel32.lookupFunction<_WaitNative, _WaitDart>(
    'WaitForSingleObject',
  );
  static final _releaseSemaphore = _kernel32
      .lookupFunction<_ReleaseSemaphoreNative, _ReleaseSemaphoreDart>(
        'ReleaseSemaphore',
      );
  static final _close = _kernel32
      .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');

  /// The lock, where no one holds it; null where someone does. Throws an
  /// [OSError] where Windows gives no such lock at all.
  static WindowsNamedLock? tryTake(String name) {
    final wide = name.toNativeUtf16();
    final int handle;
    try {
      handle = _create(nullptr, 1, 1, wide);
    } finally {
      calloc.free(wide);
    }
    if (handle == 0) throw const OSError('CreateSemaphoreW');
    if (_wait(handle, 0) == _waitObject0) return WindowsNamedLock._(handle);
    _close(handle);
    return null;
  }

  /// Gives the lock back. Once.
  void release() {
    if (_released) return;
    _released = true;
    _releaseSemaphore(_handle, 1, nullptr);
    _close(_handle);
  }
}
