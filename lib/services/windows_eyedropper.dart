import 'dart:ffi';
import 'dart:io';
import 'dart:ui' show Color;

import 'package:ffi/ffi.dart';

/// Windows-only screen colour sampler.
///
/// Reads the colour of the pixel currently under the mouse cursor using plain
/// Win32 GDI calls - no global hook, no extra window, no native plugin. The
/// caller drives sampling on a short timer (see the colour picker's "Pick"
/// flow): each tick calls [sample], which returns the colour under the cursor
/// wherever it is on screen (over any window), so the user can hover anywhere
/// and watch a live preview.
///
/// FFI idiom mirrors [Win32WindowDrag] (`DynamicLibrary.open` + `lookupFunction`
/// bound lazily and guarded by [Platform.isWindows]). Every method is a safe
/// no-op / null on non-Windows platforms.
///
/// Limitations (inherent to the hook-free approach):
///  * Sampling only advances while [sample] is called on a timer; there is no
///    OS-level "click anywhere to commit" - the caller commits from its own UI
///    (click "Pick" again, or press Enter) and cancels with Esc.
///  * `GetPixel` reads the desktop DC at device pixels; on mixed-DPI multi-
///    monitor setups a colour is still returned, just at the physical pixel
///    under the cursor.
///  * `GetPixel` can return `CLR_INVALID` (e.g. cursor over a protected / GPU
///    surface); [sample] returns null in that case rather than a bogus colour.
final class _Point extends Struct {
  @Int32()
  external int x;

  @Int32()
  external int y;
}

class WindowsEyedropper {
  WindowsEyedropper();

  /// `GetPixel` failure sentinel (0xFFFFFFFF).
  static const int _clrInvalid = 0xFFFFFFFF;

  // Lazily bind to the two system DLLs, only on Windows. `DynamicLibrary.open`
  // never fails for these on Windows, but stay defensive so a failure degrades
  // to "unsupported" instead of throwing at class-load.
  static final DynamicLibrary? _user32 =
      Platform.isWindows ? _tryOpen('user32.dll') : null;
  static final DynamicLibrary? _gdi32 =
      Platform.isWindows ? _tryOpen('gdi32.dll') : null;

  static DynamicLibrary? _tryOpen(String name) {
    try {
      return DynamicLibrary.open(name);
    } catch (_) {
      return null;
    }
  }

  // GetCursorPos(LPPOINT) -> BOOL
  static final int Function(Pointer<_Point>)? _getCursorPos =
      _user32?.lookupFunction<Int32 Function(Pointer<_Point>),
          int Function(Pointer<_Point>)>('GetCursorPos');

  // GetDC(HWND) -> HDC   (NULL HWND => the whole screen)
  static final int Function(int)? _getDC = _user32
      ?.lookupFunction<IntPtr Function(IntPtr), int Function(int)>('GetDC');

  // ReleaseDC(HWND, HDC) -> int
  static final int Function(int, int)? _releaseDC =
      _user32?.lookupFunction<Int32 Function(IntPtr, IntPtr),
          int Function(int, int)>('ReleaseDC');

  // GetPixel(HDC, int X, int Y) -> COLORREF (0x00BBGGRR) or CLR_INVALID
  static final int Function(int, int, int)? _getPixel =
      _gdi32?.lookupFunction<Uint32 Function(IntPtr, Int32, Int32),
          int Function(int, int, int)>('GetPixel');

  /// Whether screen colour sampling is available on this platform. `false`
  /// everywhere except Windows (and there only if the Win32 entry points bound).
  static bool get isSupported =>
      Platform.isWindows &&
      _getCursorPos != null &&
      _getDC != null &&
      _getPixel != null &&
      _releaseDC != null;

  // One reusable POINT buffer per instance (allocated on first [sample]); freed
  // in [dispose] so timer-driven sampling doesn't churn native memory.
  Pointer<_Point>? _pointBuf;
  bool _disposed = false;

  /// Sample the pixel currently under the cursor as an opaque [Color].
  ///
  /// Returns null on any failure - non-Windows, disposed, unbound entry points,
  /// a `GetCursorPos`/`GetDC` failure, or `GetPixel` returning `CLR_INVALID`.
  /// The screen DC is acquired and released on every call so nothing leaks.
  Color? sample() {
    if (_disposed || !isSupported) return null;
    final getCursorPos = _getCursorPos!;
    final getDC = _getDC!;
    final getPixel = _getPixel!;
    final releaseDC = _releaseDC!;

    final buf = _pointBuf ??= calloc<_Point>();
    if (getCursorPos(buf) == 0) return null;

    final hdc = getDC(0); // 0 == NULL HWND == screen DC
    if (hdc == 0) return null;
    try {
      final cref = getPixel(hdc, buf.ref.x, buf.ref.y);
      if (cref == _clrInvalid || cref < 0) return null;
      // COLORREF is 0x00BBGGRR.
      final r = cref & 0xFF;
      final g = (cref >> 8) & 0xFF;
      final b = (cref >> 16) & 0xFF;
      return Color.fromARGB(0xFF, r, g, b);
    } finally {
      releaseDC(0, hdc);
    }
  }

  /// Release the native POINT buffer. Idempotent. Safe to call on any platform.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final buf = _pointBuf;
    if (buf != null) {
      calloc.free(buf);
      _pointBuf = null;
    }
  }
}
