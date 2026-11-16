import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Win32-only helper that initiates an OS-level window drag using the
/// classic `WM_NCLBUTTONDOWN + HTCAPTION` trick.
///
/// This makes the window follow the cursor as if the user grabbed its
/// title bar, which is exactly what Chrome does when you tear a tab off.
///
/// All methods are no-ops on non-Windows platforms.
class Win32WindowDrag {
  Win32WindowDrag._();

  static const int _WM_NCLBUTTONDOWN = 0x00A1;
  static const int _HTCAPTION = 2;

  // Lazily bind to user32.dll only on Windows.
  static final DynamicLibrary? _user32 =
      Platform.isWindows ? DynamicLibrary.open('user32.dll') : null;

  // ── FFI function typedefs ────────────────────────────────────

  // SendMessageW(HWND, UINT, WPARAM, LPARAM) -> LRESULT
  static final int Function(int hwnd, int msg, int wParam, int lParam)?
      _sendMessageW = _user32?.lookupFunction<
          IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr),
          int Function(int, int, int, int)>('SendMessageW');

  // ReleaseCapture() -> BOOL
  static final int Function()? _releaseCapture = _user32
      ?.lookupFunction<Int32 Function(), int Function()>('ReleaseCapture');

  // SetForegroundWindow(HWND) -> BOOL
  static final int Function(int)? _setForegroundWindow =
      _user32?.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'SetForegroundWindow');

  // FindWindowW(lpClassName, lpWindowName) -> HWND
  static final int Function(Pointer<Utf16>, Pointer<Utf16>)? _findWindowW =
      _user32?.lookupFunction<
          IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
          int Function(Pointer<Utf16>, Pointer<Utf16>)>('FindWindowW');

  // ── Public API ───────────────────────────────────────────────

  /// Initiate an OS-level title-bar drag on the window identified by
  /// [hwnd].  Call this while the mouse button is still held down --
  /// the OS takes over pointer capture and moves the window until the
  /// button is released.
  static void startDrag(int hwnd) {
    if (!Platform.isWindows || hwnd == 0) return;
    _setForegroundWindow?.call(hwnd);
    _releaseCapture?.call();
    _sendMessageW?.call(hwnd, _WM_NCLBUTTONDOWN, _HTCAPTION, 0);
  }

  /// Find a top-level window by its exact title.
  ///
  /// Returns 0 if no matching window is found or on non-Windows platforms.
  static int findWindowByTitle(String title) {
    if (!Platform.isWindows) return 0;
    final titlePtr = title.toNativeUtf16();
    try {
      return _findWindowW?.call(nullptr, titlePtr) ?? 0;
    } finally {
      calloc.free(titlePtr);
    }
  }
}
