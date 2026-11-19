// Remote screens (4.0): a screen in a window of its own, the main
// window's side. The session stays the main window's: it opens the window,
// hands it what it starts with, passes on what only the owner is told while
// the window is open (screen_window_protocol.dart), and takes the screen
// back into its tab when the window says so, closes, or the session ends.
//
// One window a session. The window's title names no host.
import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:zest_native/screen.dart';
import 'package:zestssh/features/screens/window/screen_window_protocol.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/ui/screens/editor/editor_windows.dart' show EditorWindowBackend, PluginEditorWindowBackend;
import 'package:zestssh/ui/windows/secondary_window_app.dart' show windowThemePayload;
import 'package:zestssh/utils/logger.dart';

class _Shown {
  _Shown(this.windowId, this.events);
  final int windowId;
  final StreamSubscription<ScreenEvent> events;

  // What the window last said of itself; not in front until it says so.
  bool front = false;
}

/// The screens shown in windows of their own.
class ScreenWindows {
  ScreenWindows({EditorWindowBackend? backend, this.watchEvery = const Duration(seconds: 1)})
      : backend = backend ?? const PluginEditorWindowBackend();

  /// The app's own, for its whole life. A change of profile brings every
  /// screen back to its tab ([closeAll]) before the sessions end.
  static final ScreenWindows instance = ScreenWindows();

  /// How the app's windows are opened and reached (the editor's windows use
  /// the same): the plugin, or a test's stand-in.
  EditorWindowBackend backend;

  /// How often it is checked that each window is still open (its person may
  /// close it with the window's own button, which tells nobody).
  Duration watchEvery;

  /// The window's title: no host's name, as every window of its own.
  static const title = 'ZestSSH';

  /// The size a screen's window opens at.
  static const openSize = Size(1100, 720);

  final _shown = <String, _Shown>{};
  Timer? _watch;

  // What a session's tab does when its window's picture takes the keyboard.
  final _onFocus = <String, VoidCallback>{};

  /// Whether the window showing [sessionId] is in front, by its own word
  /// ([kScreenWindowFrontMethod]): false for a screen in no window, and for
  /// a window that has not said.
  bool isFront(String sessionId) => _shown[sessionId]?.front ?? false;

  /// What to do when the window showing [sessionId], in front, says its
  /// picture took the keyboard, or says it has come to the front (the tab
  /// sends this computer's clipboard to the remote); null takes it away.
  void onWindowFocus(String sessionId, VoidCallback? then) {
    if (then == null) {
      _onFocus.remove(sessionId);
    } else {
      _onFocus[sessionId] = then;
    }
  }

  /// What to do when the window showing [sessionId], in front, says its
  /// person pastes into the picture (the tab sends this computer's clipboard
  /// to the remote, and the window's key waits for that); null takes it away.
  void onWindowPaste(String sessionId, Future<void> Function()? then) {
    if (then == null) {
      _onPaste.remove(sessionId);
    } else {
      _onPaste[sessionId] = then;
    }
  }

  final _onPaste = <String, Future<void> Function()>{};

  /// The sessions shown in a window of their own now, by the tab's session
  /// id: a tab listens and shows "in its own window" in the picture's place.
  final ValueNotifier<Set<String>> shown = ValueNotifier(const {});

  bool isShown(String sessionId) => _shown.containsKey(sessionId);

  /// Opens a window of its own for [session] ([payload] names it), or brings
  /// the one it has to the front. False where there is no session to show or
  /// the window could not be opened; the screen then stays in its tab.
  Future<bool> open(ScreenSession session, ScreenWindowPayload payload, {Offset at = const Offset(120, 100)}) async {
    final sessionId = payload.sessionId;
    final have = _shown[sessionId];
    if (have != null) {
      try {
        await backend.focus(have.windowId);
      } catch (_) {
        // Gone a moment ago: the watch takes it back.
      }
      return true;
    }
    if (session.isClosed || session.isReader || session.handle != payload.handle) return false;
    final int id;
    try {
      id = await backend.createWindow(jsonEncode(<String, Object?>{
        ...payload.toJson(),
        // The new window has no settings of its own: it is handed them.
        'locale': gl10n.localeName,
        ...windowThemePayload(),
      }));
      await backend.place(id, at & openSize, title);
    } catch (e, stack) {
      AppLogger.error('A screen window could not be opened', e, stack);
      return false;
    }
    // Ended while the window was being made: nothing to show in it.
    if (session.isClosed) {
      unawaited(_close(id));
      return false;
    }
    final events = session.events.listen(
      (e) {
        final text = encodeScreenWindowEvent(e);
        if (text != null) unawaited(backend.invoke(id, kScreenWindowEventMethod, text).catchError((Object _) => null));
        // The session ended: the tab says how, and its window goes.
        if (e is ScreenClosed) unawaited(bringBack(sessionId));
      },
      onDone: () => unawaited(bringBack(sessionId)),
    );
    _shown[sessionId] = _Shown(id, events);
    _changed();
    AppLogger.info('Opened screen window $id');
    return true;
  }

  /// The screen of [sessionId] back in its tab: its window closes. Nothing
  /// where it has none.
  Future<void> bringBack(String sessionId) async {
    final s = _shown.remove(sessionId);
    if (s == null) return;
    _changed();
    // Not waited for: nothing more is passed on from here either way, and the
    // window should not stay open for as long as a stream takes to let go.
    unawaited(s.events.cancel());
    await _close(s.windowId);
  }

  Future<void> _close(int id) async {
    try {
      await backend.close(id);
    } catch (_) {
      // Closed already.
    }
  }

  /// A call from a window of its own ([from]) whose name starts with
  /// "screenWindow".
  Future<Object?> handle(String method, Object? arguments, int from) async {
    // Only the window that shows a screen speaks for it, whatever it says.
    final sessionId = _shown.entries.where((e) => e.value.windowId == from).map((e) => e.key).firstOrNull;
    if (sessionId == null) return '';
    if (method == kScreenWindowBackMethod) {
      await bringBack(sessionId);
    } else if (method == kScreenWindowFrontMethod) {
      final shown = _shown[sessionId]!;
      final was = shown.front;
      // Only a plain yes counts; anything else is no.
      shown.front = arguments == true;
      if (shown.front && !was) _onFocus[sessionId]?.call();
    } else if (method == kScreenWindowFocusMethod) {
      // The keyboard taken by a window that is not in front moves nothing.
      if (_shown[sessionId]!.front) _onFocus[sessionId]?.call();
    } else if (method == kScreenWindowPasteMethod) {
      // As the keyboard taken: a window that is not in front moves nothing.
      if (_shown[sessionId]!.front) await _onPaste[sessionId]?.call();
    }
    return '';
  }

  /// Every screen back in its tab (the app closing, the profile changing).
  Future<void> closeAll() async {
    for (final sessionId in _shown.keys.toList()) {
      await bringBack(sessionId);
    }
  }

  void _changed() {
    shown.value = Set.unmodifiable(_shown.keys.toSet());
    if (_shown.isEmpty) {
      _watch?.cancel();
      _watch = null;
    } else {
      _watch ??= Timer.periodic(watchEvery, (_) => unawaited(_look()));
    }
  }

  /// A window its person closed with its own button: the screen is back in
  /// its tab.
  Future<void> _look() async {
    final List<int> open;
    try {
      open = await backend.windowIds();
    } catch (_) {
      return;
    }
    final gone = [
      for (final e in _shown.entries)
        if (!open.contains(e.value.windowId)) e.key,
    ];
    for (final sessionId in gone) {
      await bringBack(sessionId);
    }
  }
}
