import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/ui/windows/secondary_window_app.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/services/win32_window_drag.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';

/// Service that manages detached terminal windows via
/// [desktop_multi_window].
///
/// Each detached window runs an independent Flutter engine that
/// renders a single [DetachedTerminalWindow].  This service tracks
/// which session IDs are currently detached and provides methods to
/// detach, reattach, and communicate between windows.
class MultiWindowService {
  MultiWindowService._();

  static final MultiWindowService instance = MultiWindowService._();

  // ── State ──────────────────────────────────────────────────────

  /// Window controllers keyed by session ID.
  final Map<String, WindowController> _windows = {};

  /// Maps window IDs back to their primary session ID for tracking.
  final Map<int, String> _windowIdToSessionId = {};

  /// Session IDs that are currently shown in a secondary window.
  Set<String> get detachedSessionIds => Set.unmodifiable(_windows.keys);

  /// Get the window ID for a given session ID, or null if not detached.
  int? windowIdForSession(String sessionId) =>
      _windows[sessionId]?.windowId;

  // ── Reattach listeners ─────────────────────────────────────────

  final List<void Function(String sessionId)> _reattachListeners = [];

  void addReattachListener(void Function(String sessionId) callback) {
    _reattachListeners.add(callback);
  }

  void removeReattachListener(void Function(String sessionId) callback) {
    _reattachListeners.remove(callback);
  }

  void _notifyReattach(String sessionId) {
    for (final listener in List.of(_reattachListeners)) {
      listener(sessionId);
    }
  }

  // ── Window operations ──────────────────────────────────────────

  /// Maps window IDs to their OS window title (used for HWND lookup).
  final Map<int, String> _windowTitles = {};

  /// Detach a terminal session into its own window.
  ///
  /// If [paneTree] is provided, the new window will render a full pane
  /// layout instead of a single terminal. This allows detaching an
  /// entire split arrangement into its own window.
  ///
  /// Returns the `desktop_multi_window` window ID on success, or `null`
  /// if the window could not be created.
  Future<int?> detachSession({
    required String sessionId,
    required Offset position,
    required Size size,
    required String connectionLabel,
    PaneNode? paneTree,
  }) async {
    if (_windows.containsKey(sessionId)) {
      AppLogger.warning(
        'Session $sessionId is already detached - bringing to front',
      );
      return _windows[sessionId]?.windowId;
    }

    try {
      final payloadMap = <String, dynamic>{
        'sessionId': sessionId,
        'connectionLabel': connectionLabel,
        // The new window has no settings of its own: it renders in the
        // language this window is showing.
        'locale': gl10n.localeName,
        ...windowThemePayload(),
        // Nor does it read a person's settings: they are in the profile's
        // database. It is handed what it needs.
        ...await _windowSettingsPayload(),
      };

      // Include serialized pane tree if provided
      if (paneTree != null) {
        payloadMap['paneTree'] = paneTree.toJson();
      }

      final payload = jsonEncode(payloadMap);

      final window = await DesktopMultiWindow.createWindow(payload);
      // Security: use generic title - never expose connection details
      // (host, user, label) in the OS window title. Screen-sharing,
      // screenshots, and task-bar previews would leak server info.
      const title = 'ZestSSH - Terminal';

      // Center the window horizontally under the cursor and offset
      // vertically so the tab bar area sits right under the pointer.
      // This gives a natural feel when tearing off a tab.
      final windowX = position.dx - (size.width / 2);
      final windowY = position.dy - 42; // approximate tab bar offset
      window
        ..setFrame(Rect.fromLTWH(
          windowX,
          windowY,
          size.width,
          size.height,
        ))
        ..setTitle(title)
        ..show();

      _windows[sessionId] = window;
      _windowIdToSessionId[window.windowId] = sessionId;
      _windowTitles[window.windowId] = title;
      AppLogger.info('Detached session $sessionId to window ${window.windowId}');
      return window.windowId;
    } catch (e, stack) {
      AppLogger.error('Failed to detach session $sessionId', e, stack);
      return null;
    }
  }

  /// Get the native window handle (HWND on Windows) for a window managed
  /// by this service.
  ///
  /// Uses [Win32WindowDrag.findWindowByTitle] to locate the OS window
  /// because [desktop_multi_window] does not expose native handles.
  /// Returns 0 on non-Windows platforms or if the window is not found.
  int getNativeHandle(int windowId) {
    if (!Platform.isWindows) return 0;
    final title = _windowTitles[windowId];
    if (title == null) return 0;
    return Win32WindowDrag.findWindowByTitle(title);
  }

  // The text editor's windows of their own are kept by EditorWindows
  // (lib/ui/screens/editor/editor_windows.dart).

  /// Transfer a session from one window to another via method channel.
  Future<void> transferSession(
      int fromWindowId, int toWindowId, String sessionId) async {
    try {
      await DesktopMultiWindow.invokeMethod(
        toWindowId,
        'acceptSession',
        jsonEncode({
          'sessionId': sessionId,
        }),
      );
      AppLogger.info(
        'Transferred session $sessionId from window $fromWindowId '
        'to window $toWindowId',
      );
    } catch (e, stack) {
      AppLogger.error(
        'Failed to transfer session $sessionId from window '
        '$fromWindowId to $toWindowId',
        e,
        stack,
      );
    }
  }

  /// Tells every pop-out window whether the app is locked (3.0):
  /// they run apart from the main window and cover themselves while it is.
  Future<void> broadcastAppLock(bool locked) async {
    List<int> ids;
    try {
      ids = await DesktopMultiWindow.getAllSubWindowIds();
    } catch (_) {
      return; // No windows, or none can be reached.
    }
    for (final id in ids) {
      try {
        await DesktopMultiWindow.invokeMethod(id, 'appLock', locked ? '1' : '0');
      } catch (_) {
        // A window closing as this goes out.
      }
    }
  }

  /// What a window of its own is handed of a person's settings.
  static Future<Map<String, dynamic>> _windowSettingsPayload() async {
    final prefs = await appPreferences();
    return {
      'copyOnSelect': prefs.getBool('copy_on_select') ?? true,
      'shortcuts': prefs.getString('shortcut_overrides'),
      'nanoKeys': prefs.getBool('editor_nano_keys'),
      'minimap': prefs.getBool('editor_minimap'),
    };
  }

  /// Close all secondary windows (called during app shutdown).
  Future<void> closeAllWindows() async {
    for (final entry in Map.of(_windows).entries) {
      try {
        await DesktopMultiWindow.invokeMethod(
          entry.value.windowId,
          'close',
        );
      } catch (_) {
        // Window may already be closed
      }
    }
    _windows.clear();
    _windowTitles.clear();
  }

  // ── Accept session listeners ──────────────────────────────────

  final List<void Function(String sessionId)> _acceptSessionListeners = [];

  void addAcceptSessionListener(void Function(String sessionId) callback) {
    _acceptSessionListeners.add(callback);
  }

  void removeAcceptSessionListener(void Function(String sessionId) callback) {
    _acceptSessionListeners.remove(callback);
  }

  void _notifyAcceptSession(String sessionId) {
    for (final listener in List.of(_acceptSessionListeners)) {
      listener(sessionId);
    }
  }

  // ── Handle inter-window method calls ────────────────────────────

  /// Handle inter-window method calls.
  ///
  /// Called by `DesktopMultiWindow.setMethodHandler` in both the main
  /// window and secondary windows.
  Future<void> handleMethodCall(
    String method,
    dynamic arguments,
    int fromWindowId,
  ) async {
    switch (method) {
      case 'reattach':
        final sessionId = arguments as String?;
        if (sessionId != null) {
          _windows.remove(sessionId);
          _windowIdToSessionId.remove(fromWindowId);
          _windowTitles.remove(fromWindowId);
          _notifyReattach(sessionId);
          AppLogger.info(
            'Reattached session $sessionId from window $fromWindowId',
          );
        }

      case 'window_closed':
        final sessionId = arguments as String?;
        if (sessionId != null) {
          _windows.remove(sessionId);
          _windowIdToSessionId.remove(fromWindowId);
          _windowTitles.remove(fromWindowId);
          _notifyReattach(sessionId);
          AppLogger.info(
            'Secondary window $fromWindowId closed for session $sessionId',
          );
        }

      case 'acceptSession':
        // Receive a session transferred from another window
        try {
          final data = jsonDecode(arguments as String) as Map<String, dynamic>;
          final sessionId = data['sessionId'] as String?;
          if (sessionId != null) {
            _notifyAcceptSession(sessionId);
            AppLogger.info(
              'Accepted session $sessionId from window $fromWindowId',
            );
          }
        } catch (e) {
          AppLogger.error(
            'Failed to parse acceptSession arguments from '
            'window $fromWindowId',
            e,
          );
        }

      case 'requestReattach':
        // A detached window is requesting the main window to reattach
        // its session (e.g. when the detached window is closing)
        try {
          final data = jsonDecode(arguments as String) as Map<String, dynamic>;
          final sessionId = data['sessionId'] as String?;
          if (sessionId != null) {
            _windows.remove(sessionId);
            _windowIdToSessionId.remove(fromWindowId);
            _windowTitles.remove(fromWindowId);
            _notifyReattach(sessionId);
            AppLogger.info(
              'Reattach requested for session $sessionId from '
              'window $fromWindowId',
            );
          }
        } catch (e) {
          AppLogger.error(
            'Failed to parse requestReattach arguments from '
            'window $fromWindowId',
            e,
          );
        }

      default:
        AppLogger.warning(
          'Unknown multi-window method: $method from window $fromWindowId',
        );
    }
  }
}
