import 'dart:ffi';
import 'dart:io';
import 'dart:ui';

import 'package:ffi/ffi.dart';

/// Where a tab dragged out of an editor window was let go, as the system
/// says (3.4.1): on the app's main window ([main]), on another of its windows
/// ([ours], titled [windowTitle]), or elsewhere, at [at] on the screen (in
/// the screen's pixels, as windows are placed).
class EditorDrop {
  const EditorDrop({this.main = false, this.ours = false, this.windowTitle, this.at});

  /// Nowhere the app can tell: a new window, where the system places it.
  const EditorDrop.unknown() : this();

  final bool main;
  final bool ours;
  final String? windowTitle;
  final Offset? at;
}

/// Tells where the pointer is, for a tab let go outside its window: on
/// Windows, the window under the pointer; elsewhere nothing (the tab goes to
/// a new window then, as a browser's does).
abstract class EditorDropResolver {
  const EditorDropResolver();

  factory EditorDropResolver.platform() => Platform.isWindows ? const _Win32DropResolver() : const _NoDropResolver();

  EditorDrop resolve();
}

class _NoDropResolver extends EditorDropResolver {
  const _NoDropResolver();

  @override
  EditorDrop resolve() => const EditorDrop.unknown();
}

final class _Point extends Struct {
  @Int32()
  external int x;
  @Int32()
  external int y;
}

class _Win32DropResolver extends EditorDropResolver {
  const _Win32DropResolver();

  static final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

  static final _getCursorPos =
      _user32.lookupFunction<Int32 Function(Pointer<_Point>), int Function(Pointer<_Point>)>('GetCursorPos');
  static final _windowFromPoint = _user32.lookupFunction<IntPtr Function(_Point), int Function(_Point)>('WindowFromPoint');
  static final _getAncestor = _user32.lookupFunction<IntPtr Function(IntPtr, Uint32), int Function(int, int)>('GetAncestor');
  static final _getClassName = _user32
      .lookupFunction<Int32 Function(IntPtr, Pointer<Utf16>, Int32), int Function(int, Pointer<Utf16>, int)>('GetClassNameW');
  static final _getWindowText = _user32
      .lookupFunction<Int32 Function(IntPtr, Pointer<Utf16>, Int32), int Function(int, Pointer<Utf16>, int)>('GetWindowTextW');
  static final _getWindowThreadProcessId = _user32
      .lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');
  static final _getCurrentProcessId = _kernel32.lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');

  /// GA_ROOT: the window's top-level window.
  static const int _gaRoot = 2;

  /// The main window's class (windows/runner/win32_window.cpp) and the
  /// windows of their own's (desktop_multi_window).
  static const String _mainClass = 'FLUTTER_RUNNER_WIN32_WINDOW';
  static const String _subClass = 'FlutterMultiWindow';

  @override
  EditorDrop resolve() {
    final point = calloc<_Point>();
    final pid = calloc<Uint32>();
    final buffer = calloc<Uint16>(256).cast<Utf16>();
    try {
      if (_getCursorPos(point) == 0) return const EditorDrop.unknown();
      final at = Offset(point.ref.x.toDouble(), point.ref.y.toDouble());
      final under = _windowFromPoint(point.ref);
      final root = under == 0 ? 0 : _getAncestor(under, _gaRoot);
      if (root == 0) return EditorDrop(at: at);
      _getWindowThreadProcessId(root, pid);
      if (pid.value != _getCurrentProcessId()) return EditorDrop(at: at);
      final className = _getClassName(root, buffer, 256) > 0 ? buffer.toDartString() : '';
      if (className == _mainClass) return EditorDrop(main: true, ours: true, at: at);
      final title = _getWindowText(root, buffer, 256) > 0 ? buffer.toDartString() : '';
      return EditorDrop(ours: className == _subClass || title.isNotEmpty, windowTitle: title, at: at);
    } catch (_) {
      return const EditorDrop.unknown();
    } finally {
      calloc.free(point);
      calloc.free(pid);
      calloc.free(buffer);
    }
  }
}
