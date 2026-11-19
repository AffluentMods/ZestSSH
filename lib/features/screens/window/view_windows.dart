// Remote screens (4.0), on Windows: a screen's window of its own drawn by the
// main window's engine, as a second view of it, in place of a window of the
// multi-window plugin with an engine of its own; the text editor's windows of
// their own the same way. Two engines in one process
// share ANGLE's one Direct3D device, and their threads drawing at once crashed
// in the graphics driver (a screen's picture is new images many times a
// second); one engine drawing every window never does.
//
// The runner opens the window and its view (windows/runner/view_windows.cpp,
// channel zestssh/view_windows); the main app draws the screen's window app
// (screenWindowApp, as a window of its own ran it) into that view
// ([ViewWindowsHost]), in this isolate: the calls between the tab and the
// window go straight across instead of over the plugin's channel.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/screens/window/screen_window_app.dart';
import 'package:zestssh/features/screens/window/screen_window_protocol.dart';
import 'package:zestssh/features/screens/window/screen_windows.dart';
import 'package:zestssh/ui/screens/editor/editor_windows.dart' show EditorWindowBackend, kMainWindowId;
import 'package:zestssh/ui/windows/editor_window.dart' show answerEditorWindowCall, editorWindowApp;

/// One window of the app's own drawn by this engine: its view and what it
/// shows.
typedef ViewWindow = ({ui.FlutterView view, Widget child});

/// The windows drawn as views of this engine, and the runner's side of them.
class ViewWindows {
  ViewWindows({MethodChannel? channel, ui.FlutterView? Function(int viewId)? viewOf})
      : _channel = channel ?? const MethodChannel('zestssh/view_windows'),
        _viewOf = viewOf ?? _platformView {
    _channel.setMethodCallHandler(_onCall);
  }

  /// The app's own.
  static final ViewWindows instance = ViewWindows();

  /// Where a screen's window is drawn by this engine: Windows (macOS and
  /// Linux keep the plugin's windows).
  static bool get supported => !kIsWeb && Platform.isWindows;

  final MethodChannel _channel;
  final ui.FlutterView? Function(int viewId) _viewOf;

  /// What each open window draws, by its id.
  final ValueNotifier<Map<int, ViewWindow>> windows = ValueNotifier(const {});

  /// The app lock as it stands: every window covers itself while it is on.
  final ValueNotifier<bool> locked = ValueNotifier(false);

  /// Someone is working in one of these windows: the app is not idle.
  VoidCallback onActivity = () {};

  /// What the main window answers a window's call with (main.dart's handler
  /// of the plugin's windows' calls, the same for these): the method, its
  /// arguments and the window it came from.
  Future<Object?> Function(String method, Object? arguments, int from)? mainCall;

  /// How long a new view may take to reach the framework.
  static const viewWait = Duration(seconds: 3);

  static ui.FlutterView? _platformView(int viewId) {
    for (final v in ui.PlatformDispatcher.instance.views) {
      if (v.viewId == viewId) return v;
    }
    return null;
  }

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method == 'closeRequested') {
      final id = (call.arguments as Map?)?['id'];
      if (id is int) await close(id);
    }
    return null;
  }

  /// A new window, hidden until [place], with a view of this engine: its id
  /// and its view.
  Future<(int, ui.FlutterView)> open({int width = 1100, int height = 720}) async {
    final answer = await _channel.invokeMapMethod<String, Object?>('open', {'width': width, 'height': height});
    final id = answer?['id'];
    final viewId = answer?['viewId'];
    if (id is! int || viewId is! int) throw StateError('The window could not be opened');
    final deadline = DateTime.now().add(viewWait);
    var view = _viewOf(viewId);
    while (view == null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
      view = _viewOf(viewId);
    }
    if (view == null) {
      unawaited(_channel.invokeMethod<void>('close', {'id': id}).catchError((Object _) {}));
      throw StateError('The window\'s view never came');
    }
    return (id, view);
  }

  /// Window [id] draws [child] in [view] from now on.
  void show(int id, ui.FlutterView view, Widget child) {
    windows.value = {...windows.value, id: (view: view, child: child)};
  }

  /// Window [id] at [frame] (logical pixels) with [title], shown.
  Future<void> place(int id, ui.Rect frame, String title) => _channel.invokeMethod<void>('place', {
        'id': id,
        'x': frame.left.round(),
        'y': frame.top.round(),
        'width': frame.width.round(),
        'height': frame.height.round(),
        'title': title,
      });

  Future<void> focus(int id) => _channel.invokeMethod<void>('focus', {'id': id});

  Future<void> fullScreen(int id, bool on) => _channel.invokeMethod<void>('fullScreen', {'id': id, 'on': on});

  /// The windows open.
  List<int> get ids => windows.value.keys.toList();

  /// Closes under way: a second close of the same window (its X while the
  /// session ends) waits for the first, so the view never goes from the
  /// engine before the frame without it is drawn.
  final Map<int, Future<void>> _closing = {};

  /// Window [id] closed: what it draws goes from the tree first, and only
  /// once that frame is drawn do its view and window go.
  Future<void> close(int id) => _closing[id] ??= _close(id).whenComplete(() {
        // (Not returned: whenComplete would wait for what it removes, itself.)
        _closing.remove(id);
      });

  Future<void> _close(int id) async {
    if (windows.value.containsKey(id)) {
      windows.value = {...windows.value}..remove(id);
      try {
        await WidgetsBinding.instance.endOfFrame.timeout(const Duration(seconds: 1));
      } catch (_) {
        // No frame came (nothing else to draw): the view is unused already.
      }
    }
    try {
      await _channel.invokeMethod<void>('close', {'id': id});
    } catch (_) {
      // Gone already.
    }
  }
}

/// The screen windows' backend where they are views of this engine
/// ([ScreenWindows.backend] on Windows).
class ViewWindowsBackend implements EditorWindowBackend {
  ViewWindowsBackend([ViewWindows? windows]) : _w = windows ?? ViewWindows.instance;

  final ViewWindows _w;

  /// The editor's windows among them (the rest show screens).
  final Set<int> _editors = {};

  @override
  Future<int> createWindow(String payload) async {
    final raw = jsonDecode(payload) as Map<String, dynamic>;
    final screen = ScreenWindowPayload.fromJson(raw);
    final editor = raw['type'] == 'editor';
    if (screen == null && !editor) throw ArgumentError('Not a screen\'s or an editor\'s window');
    final (id, view) = await _w.open();
    if (screen != null) {
      _w.show(
        id,
        view,
        screenWindowApp(
          windowId: id,
          payload: screen,
          raw: raw,
          backend: _FromWindow(id, _w, close),
          locked: _w.locked,
          onActivity: () => _w.onActivity(),
          setFullScreen: (on) => _w.fullScreen(id, on),
        ),
      );
    } else {
      _editors.add(id);
      _w.show(
        id,
        view,
        // Providers of its own, as in an engine of its own: the editor's
        // tabs are its own, not the main window's editor's.
        ProvidersOfItsOwn(
            child: editorWindowApp(
          windowId: id,
          payload: raw,
          backend: _FromWindow(id, _w, close),
          locked: _w.locked,
          // As a window of its own says it: the main window's idle clock, and
          // the editor windows' last used.
          onActivity: () => unawaited(_w.mainCall?.call('activity', null, id)),
        )),
      );
    }
    return id;
  }

  @override
  Future<void> place(int id, ui.Rect frame, String title) => _w.place(id, frame, title);

  @override
  Future<void> focus(int id) => _w.focus(id);

  /// A call from the main window to window [id]: to its handler, here.
  @override
  Future<Object?> invoke(int id, String method, [Object? arguments]) => _editors.contains(id)
      ? answerEditorWindowCall(id, method, arguments)
      : answerScreenWindowCall(id, method, arguments);

  @override
  Future<List<int>> windowIds() async => _w.ids;

  @override
  Future<void> close(int id) {
    _editors.remove(id);
    return _w.close(id);
  }
}

/// What window [windowId] reaches the main window through: its calls go
/// straight to the main window's handler ([ViewWindows.mainCall]), as from a
/// window of its own; a screen's to [ScreenWindows] where none is set.
class _FromWindow implements EditorWindowBackend {
  _FromWindow(this.windowId, this._w, this._closeOwn);

  final int windowId;
  final ViewWindows _w;

  /// The backend's close (it forgets the window's kind too).
  final Future<void> Function(int id) _closeOwn;

  @override
  Future<Object?> invoke(int id, String method, [Object? arguments]) async {
    if (id != kMainWindowId) return null;
    final main = _w.mainCall;
    if (main != null) return main(method, arguments, windowId);
    return ScreenWindows.instance.handle(method, arguments, windowId);
  }

  @override
  Future<int> createWindow(String payload) async => throw UnsupportedError('A window opens no window');

  @override
  Future<void> place(int id, ui.Rect frame, String title) async => throw UnsupportedError('Not from a window');

  @override
  Future<void> focus(int id) async => throw UnsupportedError('Not from a window');

  @override
  Future<List<int>> windowIds() async => throw UnsupportedError('Not from a window');

  /// The window closing itself (an editor whose last tab closed).
  @override
  Future<void> close(int id) async {
    if (id != windowId) throw UnsupportedError('Not from a window');
    await _closeOwn(id);
  }
}

/// A provider container of [child]'s own, with no parent: what it reads is
/// its own, as in a window with an engine of its own.
class ProvidersOfItsOwn extends StatefulWidget {
  const ProvidersOfItsOwn({super.key, required this.child});

  final Widget child;

  @override
  State<ProvidersOfItsOwn> createState() => _ProvidersOfItsOwnState();
}

class _ProvidersOfItsOwnState extends State<ProvidersOfItsOwn> {
  final ProviderContainer _container = ProviderContainer();

  @override
  void dispose() {
    _container.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(container: _container, child: widget.child);
}

/// Draws every [ViewWindows] window, each in its own view, beside [child]
/// (the main window's app), under the same providers.
class ViewWindowsHost extends StatelessWidget {
  const ViewWindowsHost({super.key, required this.child, this.windows});

  final Widget child;

  /// The windows (tests give their own).
  final ViewWindows? windows;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Map<int, ViewWindow>>(
        valueListenable: (windows ?? ViewWindows.instance).windows,
        builder: (context, open, child) => ViewAnchor(
          view: open.isEmpty
              ? null
              : ViewCollection(views: [
                  for (final MapEntry(key: id, value: w) in open.entries)
                    View(key: ValueKey('view-window-$id'), view: w.view, child: w.child),
                ]),
          child: child!,
        ),
        child: child,
      );
}
