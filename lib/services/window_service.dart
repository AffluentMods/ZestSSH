import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zestssh/services/tray_service.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// Compile-time escape hatch: build with `--dart-define=ZEST_NATIVE_FRAME=true`
/// to use the standard Windows title bar instead of the frameless custom one.
/// The frameless window's custom WM_NCCALCSIZE resize path can trigger an
/// ANGLE/D3D11 swapchain loss (black screen on move / resize / monitor change)
/// on some GPUs; a native frame lets the OS own the resize and sidesteps it.
/// Defaults false, so normal builds are completely unchanged.
const bool kNativeWindowFrame = bool.fromEnvironment('ZEST_NATIVE_FRAME');

/// Closes the app's window for good, once whatever closing does is done:
/// the tray icon goes first, since on Windows the process ends with the
/// window (windows/runner/main.cpp) and the tray plugin is never told.
Future<void> destroyAppWindow() async {
  await TrayService.instance?.removeIcon();
  await windowManager.destroy();
}

/// Manages the desktop window - size, fullscreen, always-on-top.
///
/// Always centers on launch for reliability across monitor configurations.
class WindowService with WindowListener {
  static WindowService? _instance;
  static WindowService? get instance => _instance;

  bool _isFullscreen = false;
  bool _isAlwaysOnTop = false;
  VoidCallback? _onCloseRequested;

  /// What closes the window while nothing that set [setOnCloseRequested] is
  /// there: the app locked (the shell goes with it), or started locked.
  VoidCallback? _onCloseWithoutShell;

  /// Live fullscreen state for widgets that lay out around the OS chrome
  /// (the pill bar's macOS traffic-light inset). Follows the real window,
  /// whichever way it entered fullscreen (our toggle, the green button, the
  /// system shortcut).
  static final ValueNotifier<bool> fullscreen = ValueNotifier<bool>(false);

  /// Fired when the window loses the foreground (minimized or blurred) and
  /// regains it (restored or focused). Used by the agentless Server Monitor
  /// poller so it only polls while the app is actually in the foreground.
  VoidCallback? _onForegroundLost;
  VoidCallback? _onForegroundGained;

  static const _minSize = Size(800, 500);
  static const _defaultSize = Size(1200, 800);

  WindowService._();

  /// For a test of what a close reaches.
  @visibleForTesting
  WindowService.forTesting();

  /// Initialise the window manager. Call once from main().
  static Future<void> init(SharedPreferences prefs) async {
    if (!isDesktopPlatform) return;

    await windowManager.ensureInitialized();

    _instance = WindowService._();

    // Use minimal options - we do positioning ourselves AFTER show,
    // because the waitUntilReadyToShow callback is VoidCallback
    // (fire-and-forget), so awaits inside it silently drop.
    // Frameless: hide the OS caption bar so the app's own 48px pill bar IS
    // the title bar (drag region + in-theme window controls live there -
    // see PillBar). This removes the mismatched light-grey Windows chrome
    // that made the app read as a mobile port bolted onto a desktop frame.
    // Resizable borders are retained by window_manager; only the caption
    // bar is hidden. If the window ever becomes undraggable, reverting to
    // TitleBarStyle.normal restores the OS chrome.
    final options = const WindowOptions(
      minimumSize: _minSize,
      title: 'ZestSSH',
      titleBarStyle:
          kNativeWindowFrame ? TitleBarStyle.normal : TitleBarStyle.hidden,
      // macOS: keep the native traffic-light buttons (close / minimize / zoom)
      // visible over the hidden title bar - the app uses them there instead of
      // drawing its own controls (see PillBar). No-op on Windows/Linux.
      windowButtonVisibility: true,
      backgroundColor: Color(0xFF0A0A0A),
      skipTaskbar: false,
    );

    await windowManager.waitUntilReadyToShow(options);

    // These are properly awaited (not inside a VoidCallback):
    await windowManager.setSize(_defaultSize);
    await windowManager.center();
    await windowManager.show();
    await windowManager.focus();

    // Safety net: verify we're actually on-screen
    await _validateWindowPosition();

    windowManager.addListener(_instance!);
    AppLogger.info('Window manager initialised');
  }

  /// Set a callback for when the user attempts to close the window.
  void setOnCloseRequested(VoidCallback callback) {
    _onCloseRequested = callback;
    windowManager.setPreventClose(true);
  }

  /// [callback], set with [setOnCloseRequested], is no longer there to answer:
  /// its screen has gone, and a close sent to it answered nothing, which left
  /// a window nothing but the system could close.
  void clearOnCloseRequested(VoidCallback callback) {
    if (_onCloseRequested == callback) _onCloseRequested = null;
  }

  /// What closes the window while the shell is not there.
  void setOnCloseWithoutShell(VoidCallback callback) {
    _onCloseWithoutShell = callback;
    windowManager.setPreventClose(true);
  }

  /// Register foreground-transition callbacks. [onLost] fires on minimize /
  /// blur, [onGained] on restore / focus. Safe to call before or after the
  /// window listener is attached.
  void setForegroundCallbacks({
    VoidCallback? onLost,
    VoidCallback? onGained,
  }) {
    _onForegroundLost = onLost;
    _onForegroundGained = onGained;
  }

  // ── Public API ──────────────────────────────────────────────────

  bool get isFullscreen => _isFullscreen;
  bool get isAlwaysOnTop => _isAlwaysOnTop;

  Future<void> toggleFullscreen() async {
    _isFullscreen = !_isFullscreen;
    fullscreen.value = _isFullscreen;
    await windowManager.setFullScreen(_isFullscreen);
  }

  Future<void> setFullscreen(bool value) async {
    _isFullscreen = value;
    fullscreen.value = value;
    await windowManager.setFullScreen(value);
  }

  Future<void> toggleAlwaysOnTop() async {
    _isAlwaysOnTop = !_isAlwaysOnTop;
    await windowManager.setAlwaysOnTop(_isAlwaysOnTop);
  }

  Future<void> setAlwaysOnTop(bool value) async {
    _isAlwaysOnTop = value;
    await windowManager.setAlwaysOnTop(value);
  }

  Future<void> minimize() => windowManager.minimize();
  Future<void> maximize() => windowManager.maximize();
  Future<void> restore() => windowManager.restore();
  Future<void> close() => windowManager.close();
  Future<bool> isMaximized() => windowManager.isMaximized();

  Future<void> setTitle(String title) => windowManager.setTitle(title);

  // ── Window Listener ─────────────────────────────────────────────

  @override
  void onWindowResize() {}

  @override
  void onWindowMove() {}

  @override
  void onWindowMaximize() {}

  @override
  void onWindowUnmaximize() {}

  @override
  void onWindowMinimize() => _onForegroundLost?.call();

  @override
  void onWindowRestore() => _onForegroundGained?.call();

  @override
  void onWindowBlur() => _onForegroundLost?.call();

  @override
  void onWindowFocus() => _onForegroundGained?.call();

  @override
  void onWindowEnterFullScreen() {
    _isFullscreen = true;
    fullscreen.value = true;
  }

  @override
  void onWindowLeaveFullScreen() {
    _isFullscreen = false;
    fullscreen.value = false;
  }

  @override
  void onWindowClose() async {
    final close = _onCloseRequested ?? _onCloseWithoutShell;
    if (close != null) {
      close();
    } else {
      await destroyAppWindow();
    }
  }

  /// Clean up listener on app exit.
  void dispose() {
    windowManager.removeListener(this);
  }

  // ── Position validation ────────────────────────────────────────

  /// Check if the window center point is within reasonable screen bounds.
  /// If not (e.g. saved position on a disconnected monitor), center it.
  static Future<void> _validateWindowPosition() async {
    try {
      final position = await windowManager.getPosition();
      final size = await windowManager.getSize();
      final centerX = position.dx + size.width / 2;
      final centerY = position.dy + size.height / 2;

      final isVisible = centerX > -100 && centerX < 10000 &&
          centerY > -100 && centerY < 5000;

      if (!isVisible) {
        AppLogger.info(
          'Window center ($centerX, $centerY) off-screen - centering',
        );
        await windowManager.center();
      }
    } catch (e) {
      await windowManager.center();
    }
  }

  // ── Secondary window helpers ───────────────────────────────────

  /// Get the current main window position and size for calculating
  /// where to place secondary (detached) windows.
  Future<Rect> getWindowFrame() async {
    final position = await windowManager.getPosition();
    final size = await windowManager.getSize();
    return Rect.fromLTWH(position.dx, position.dy, size.width, size.height);
  }

  /// Calculate a sensible position for a new secondary window,
  /// offset from the main window so it doesn't overlap completely.
  Future<Offset> getSecondaryWindowPosition({
    Offset? dragPosition,
    int windowIndex = 0,
  }) async {
    if (dragPosition != null) return dragPosition;

    final frame = await getWindowFrame();
    // Cascade offset: each new window shifts 30px right and 30px down
    final cascadeOffset = 30.0 * (windowIndex + 1);
    return Offset(
      frame.right + cascadeOffset,
      frame.top + cascadeOffset,
    );
  }
}
