import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// One monitored host as the tray needs it: an id to connect, and a label that
/// already carries a status glyph (the shell resolves the bucket so the service
/// stays decoupled from the monitor domain).
class TrayHostEntry {
  final String id;
  final String label;
  const TrayHostEntry({required this.id, required this.label});
}

/// System tray integration - shows tray icon with context menu.
///
/// Features:
/// - Minimize to tray
/// - Session count badge
/// - Live monitor health (critical count in the icon / tooltip / menu)
/// - Quick actions + per-host quick-connect from the tray menu
/// What the window's close button does with "close to tray" set: hide the
/// window where a tray icon is there to bring it back, and minimise it where
/// none is (a failed tray start, a desktop that shows no tray icons): hidden
/// with no icon, the window could not be found again while the app and its
/// sessions ran on (found in a code audit).
enum CloseToTray { hide, minimize }

CloseToTray closeToTrayAction({required bool trayReady}) => trayReady ? CloseToTray.hide : CloseToTray.minimize;

class TrayService with TrayListener {
  static TrayService? _instance;
  static TrayService? get instance => _instance;

  /// Whether the tray icon was put up (its icon, tooltip and menu set).
  static bool get ready => _ready;
  static bool _ready = false;

  VoidCallback? onShowWindow;
  VoidCallback? onQuickConnect;
  VoidCallback? onQuit;

  /// What Quit does while the shell is not there to set [onQuit]: the app
  /// locked, or started locked.
  VoidCallback? onQuitWithoutShell;

  /// Connect a specific host directly from the tray submenu.
  void Function(String connectionId)? onConnectHost;

  int _activeSessionCount = 0;
  int _criticalCount = 0;
  int _warningCount = 0;
  List<TrayHostEntry> _hosts = const [];

  TrayService._();

  static Future<void> init() async {
    if (!isDesktopPlatform) return;

    _instance = TrayService._();

    // Set tray icon - use the platform-appropriate icon.
    // tray_manager automatically prepends <exe_dir>/data/flutter_assets/
    // to the icon path, so the file must be a Flutter asset.
    // Windows requires .ico format for LoadImage(LR_LOADFROMFILE).
    String iconPath;
    if (Platform.isWindows) {
      iconPath = 'assets/app_icon.ico';
    } else if (Platform.isMacOS) {
      iconPath = 'assets/ZestSSH.png';
    } else {
      iconPath = 'assets/ZestSSH.png';
    }

    try {
      await trayManager.setIcon(iconPath);
      await trayManager.setToolTip('ZestSSH');
      await _instance!._updateMenu();
      trayManager.addListener(_instance!);
      // Rebuild the menu + tooltip in the new language when the user changes it
      // at runtime; without this the tray keeps the old language until restart.
      L10nGlobal.onLocaleChanged = () => _instance?.refresh();
      _ready = true;
      AppLogger.info('System tray initialised');
    } catch (e) {
      // Tray icon file might not exist yet - gracefully degrade
      AppLogger.warning('Tray init failed (icon missing?): $e');
    }
  }

  /// Rebuild the localized menu and tooltip, e.g. after a live language change.
  /// The icon is language-independent, so it is left untouched.
  Future<void> refresh() async {
    if (!isDesktopPlatform) return;
    _refreshTooltip();
    await _updateMenu();
  }

  /// Update the session count shown in tray menu.
  void updateSessionCount(int count) {
    if (_activeSessionCount == count) return;
    _activeSessionCount = count;
    _updateMenu();
    _refreshTooltip();
  }

  /// Push the current monitor health: the number of monitored hosts in the
  /// critical / warning buckets, plus the per-host list for the quick-connect
  /// submenu (labels already carry a status glyph). Cheap and idempotent -
  /// early-returns when nothing changed so the icon/menu only rebuild on a real
  /// transition.
  void updateMonitorState({
    required int critical,
    required int warning,
    required List<TrayHostEntry> hosts,
  }) {
    final sameHosts = _hosts.length == hosts.length &&
        List.generate(hosts.length, (i) => i).every(
          (i) => _hosts[i].id == hosts[i].id && _hosts[i].label == hosts[i].label,
        );
    if (critical == _criticalCount && warning == _warningCount && sameHosts) {
      return;
    }
    final criticalChanged = critical > 0 != _criticalCount > 0;
    _criticalCount = critical;
    _warningCount = warning;
    _hosts = hosts;
    if (criticalChanged) _applyIcon();
    _refreshTooltip();
    _updateMenu();
  }

  /// Swap the tray icon to the alert-badged variant while any host is critical,
  /// back to the normal icon otherwise. Path-only API (no runtime recolor), so
  /// we ship two static assets. Best-effort: a missing asset never throws out.
  Future<void> _applyIcon() async {
    final critical = _criticalCount > 0;
    final String path;
    if (Platform.isWindows) {
      path = critical ? 'assets/app_icon_critical.ico' : 'assets/app_icon.ico';
    } else {
      path = critical ? 'assets/ZestSSH_critical.png' : 'assets/ZestSSH.png';
    }
    try {
      await trayManager.setIcon(path);
    } catch (e) {
      AppLogger.warning('Tray setIcon failed: $e');
    }
  }

  /// Rebuild the tooltip (all platforms) and title (mac/Linux render it beside
  /// the icon; Windows has no tray title) from the current session + health.
  void _refreshTooltip() {
    final parts = <String>[];
    if (_activeSessionCount > 0) {
      parts.add(gl10n.trayActiveSessions(_activeSessionCount));
    }
    if (_criticalCount > 0) {
      parts.add(gl10n.trayCriticalCount(_criticalCount));
    }
    final tooltip =
        parts.isEmpty ? 'ZestSSH' : gl10n.trayTooltipDetails(parts.join(', '));
    try {
      trayManager.setToolTip(tooltip);
    } catch (_) {/* tray may not be ready */}
    if (!Platform.isWindows) {
      try {
        trayManager.setTitle(
            _criticalCount > 0 ? gl10n.trayCriticalCount(_criticalCount) : '');
      } catch (_) {/* best-effort */}
    }
  }

  Future<void> _updateMenu() async {
    final sessionLabel = _activeSessionCount > 0
        ? gl10n.trayActiveSessions(_activeSessionCount)
        : gl10n.trayNoActiveSessions;

    // Health line: only shown once there ARE monitored hosts.
    String? healthLabel;
    if (_hosts.isNotEmpty) {
      if (_criticalCount > 0) {
        healthLabel = _warningCount > 0
            ? gl10n.trayCriticalWarning(_criticalCount, _warningCount)
            : gl10n.trayCriticalCount(_criticalCount);
      } else if (_warningCount > 0) {
        healthLabel = gl10n.trayWarningCount(_warningCount);
      } else {
        healthLabel = gl10n.trayAllHealthy;
      }
    }

    final items = <MenuItem>[
      MenuItem(label: 'ZestSSH', disabled: true),
      MenuItem.separator(),
      MenuItem(label: sessionLabel, disabled: true),
      if (healthLabel != null) MenuItem(label: healthLabel, disabled: true),
      MenuItem.separator(),
      MenuItem(key: 'show', label: gl10n.trayShowWindow),
      MenuItem(key: 'quick_connect', label: gl10n.trayQuickConnect),
      // Per-host quick-connect: each leaf connects a specific host directly.
      // The per-item onClick fires even for submenu leaves (tray_manager
      // dispatches onClick alongside the listener), so no key-switch change.
      if (_hosts.isNotEmpty)
        MenuItem.submenu(
          label: gl10n.trayConnectTo,
          submenu: Menu(
            items: [
              for (final host in _hosts)
                MenuItem(
                  key: 'connect:${host.id}',
                  label: host.label,
                  onClick: (_) {
                    _showWindow();
                    onConnectHost?.call(host.id);
                  },
                ),
            ],
          ),
        ),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: gl10n.trayQuit),
    ];

    await trayManager.setContextMenu(Menu(items: items));
  }

  // ── TrayListener ────────────────────────────────────────────────

  @override
  void onTrayIconMouseDown() {
    // Single click shows window
    _showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        _showWindow();
      case 'quick_connect':
        _showWindow();
        onQuickConnect?.call();
      case 'quit':
        (onQuit ?? onQuitWithoutShell)?.call();
    }
  }

  void _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
    onShowWindow?.call();
  }

  /// Takes the icon out of the notification area, for an app that is
  /// ending: on Windows the process ends with its window, before the tray
  /// plugin would be told the window went (windows/runner/main.cpp), and an
  /// icon left there stays until the pointer passes over it. A second of
  /// waiting at the most: a tray that does not answer does not hold the
  /// close.
  Future<void> removeIcon() async {
    try {
      await trayManager.destroy().timeout(const Duration(seconds: 1));
    } catch (e) {
      AppLogger.debug('Tray icon not removed: $e');
    }
  }

  void dispose() {
    trayManager.removeListener(this);
  }
}
