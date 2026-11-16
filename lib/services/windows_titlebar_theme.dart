import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';
import 'package:zestssh/utils/logger.dart';

/// Switches the Windows native window-frame (title bar + min/max/close
/// strip) between dark and light to match the active app theme.
///
/// Flutter on Windows draws inside the window but doesn't own the
/// title-bar background - DWM does. Without this helper, picking an
/// AMOLED Black / Dracula / etc. app theme leaves a glaring white
/// strip across the top of the window in dark mode, and dark-on-
/// dark-on-light when you switch to a light theme.
///
/// We poke DWM directly via `DwmSetWindowAttribute` using the
/// `DWMWA_USE_IMMERSIVE_DARK_MODE` attribute. The attribute id
/// changed between Windows 10 versions (was 19 on early 1903 builds,
/// 20 since 20H1) - we issue both calls and let the OS pick the one
/// it understands.
///
/// No-op on macOS / Linux / mobile. macOS already syncs the title-bar
/// chrome to the app's [Brightness] automatically via Cocoa; Linux
/// has no analogous concept (CSDs vary by compositor).
class WindowsTitleBar {
  /// Windows 10 20H1+ / Windows 11 - modern attribute id.
  static const int _kDwmDarkModeNew = 20;

  /// Windows 10 1809-1909 - legacy attribute id (deprecated but still
  /// honored on some builds).
  static const int _kDwmDarkModeOld = 19;

  /// Apply [dark] to the main Flutter window's native frame.
  ///
  /// Best-effort: any FFI / DWM failure is logged and swallowed -
  /// this is a polish feature, never worth crashing the app over.
  static void setDarkMode(bool dark) {
    if (!Platform.isWindows) return;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final dwmapi = DynamicLibrary.open('dwmapi.dll');

      // FindWindowW(LPCWSTR lpClassName, LPCWSTR lpWindowName) → HWND
      final findWindow = user32.lookupFunction<
          IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
          int Function(Pointer<Utf16>, Pointer<Utf16>)>('FindWindowW');

      // HRESULT DwmSetWindowAttribute(HWND, DWORD, LPCVOID, DWORD)
      final dwmSet = dwmapi.lookupFunction<
          Int32 Function(IntPtr, Uint32, Pointer<Uint32>, Uint32),
          int Function(int, int, Pointer<Uint32>, int)>(
        'DwmSetWindowAttribute',
      );

      // Flutter's Windows runner always registers its top-level
      // window with this class name. Beats hunting by title (which
      // changes when we call setTitle).
      final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
      try {
        final hwnd = findWindow(className, nullptr);
        if (hwnd == 0) {
          AppLogger.debug('TitleBar: Flutter window not found via FindWindowW');
          return;
        }
        final value = calloc<Uint32>()..value = dark ? 1 : 0;
        try {
          // Issue both attribute ids. The one DWM doesn't recognize
          // returns a non-zero HRESULT and is silently ignored.
          dwmSet(hwnd, _kDwmDarkModeNew, value, sizeOf<Uint32>());
          dwmSet(hwnd, _kDwmDarkModeOld, value, sizeOf<Uint32>());
        } finally {
          calloc.free(value);
        }
      } finally {
        calloc.free(className);
      }
    } catch (e) {
      AppLogger.warning('TitleBar: setDarkMode($dark) failed: $e');
    }
  }
}
