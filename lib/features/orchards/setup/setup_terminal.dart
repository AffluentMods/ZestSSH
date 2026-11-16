import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// The terminal a command was typed in (3.0). On Windows a windowed
// program started from a terminal has no output stream of its own: what it
// writes goes nowhere unless whoever started it gave it a file or a pipe.
// The runner has attached to that terminal already; this points the app's
// output at it, and has it shown as UTF-8 for as long as the command runs,
// so that names read as they are written. Elsewhere there is nothing to do:
// a program started from a terminal writes to it.

abstract final class AdminTerminal {
  /// The terminal's own code page, to put back; null when it was left alone.
  static int? _codePage;

  static const _stdOutputHandle = 0xFFFFFFF5;
  static const _utf8 = 65001;

  /// Points what the app writes at the terminal it was started from, when
  /// its output goes nowhere else. Called before anything is written.
  /// True when it did.
  static bool open() {
    if (!Platform.isWindows || _codePage != null) return false;
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final getStdHandle = kernel32.lookupFunction<IntPtr Function(Uint32), int Function(int)>('GetStdHandle');
      final getConsoleMode = kernel32
          .lookupFunction<Int32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>('GetConsoleMode');
      final mode = calloc<Uint32>();
      try {
        final handle = getStdHandle(_stdOutputHandle);
        // No terminal at all (started from a shortcut), or the output was
        // sent to a file, a pipe or nowhere by whoever started it: as it is.
        if (handle == 0 || handle == -1 || getConsoleMode(handle, mode) == 0) return false;
      } finally {
        calloc.free(mode);
      }
      // The engine's own call for "the console changed": its output streams
      // are opened on the console the process is attached to.
      DynamicLibrary.open('flutter_windows.dll')
          .lookupFunction<Void Function(), void Function()>('FlutterDesktopResyncOutputStreams')();
      final getCodePage = kernel32.lookupFunction<Uint32 Function(), int Function()>('GetConsoleOutputCP');
      final setCodePage = kernel32.lookupFunction<Int32 Function(Uint32), int Function(int)>('SetConsoleOutputCP');
      final was = getCodePage();
      if (was != 0 && was != _utf8 && setCodePage(_utf8) != 0) _codePage = was;
      return true;
    } catch (_) {
      // Whatever it writes then goes where it went before: nowhere.
      return false;
    }
  }

  /// Leaves the terminal as it was found. Called just before the program
  /// ends.
  static void close() {
    final was = _codePage;
    if (was == null) return;
    _codePage = null;
    try {
      DynamicLibrary.open('kernel32.dll')
          .lookupFunction<Int32 Function(Uint32), int Function(int)>('SetConsoleOutputCP')(was);
    } catch (_) {
      // The terminal keeps showing UTF-8.
    }
  }
}
