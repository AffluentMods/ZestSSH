// The app's windows, played: what was opened with what, what was said to
// which window, which are still open.
import 'dart:convert';
import 'dart:ui';

import 'package:zestssh/ui/screens/editor/editor_windows.dart' show EditorWindowBackend;

class FakeWindowBackend implements EditorWindowBackend {
  int _next = 1;

  /// The payload each window was opened with, decoded, by window id.
  final payloads = <int, Map<String, dynamic>>{};
  final placed = <int, (Rect, String)>{};
  final focused = <int>[];
  final closed = <int>[];

  /// Every call made into a window: (window, method, arguments).
  final calls = <(int, String, Object?)>[];

  /// The windows still open.
  final open = <int>{};

  /// Set to make the next window fail to open.
  Object? failCreate;

  /// Calls to the main window (id 0) are answered by this.
  Future<Object?> Function(String method, Object? arguments)? main;

  @override
  Future<int> createWindow(String payload) async {
    final fail = failCreate;
    if (fail != null) throw fail;
    final id = _next++;
    payloads[id] = jsonDecode(payload) as Map<String, dynamic>;
    open.add(id);
    return id;
  }

  @override
  Future<void> place(int id, Rect frame, String title) async => placed[id] = (frame, title);

  @override
  Future<void> focus(int id) async => focused.add(id);

  @override
  Future<Object?> invoke(int id, String method, [Object? arguments]) async {
    calls.add((id, method, arguments));
    if (id == 0) return main?.call(method, arguments);
    if (!open.contains(id)) throw StateError('no window $id');
    return '';
  }

  @override
  Future<List<int>> windowIds() async => open.toList();

  @override
  Future<void> close(int id) async {
    closed.add(id);
    open.remove(id);
  }
}
