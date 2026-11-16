import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/host_address.dart';

/// Manages app shortcuts (iOS Quick Actions / Android App Shortcuts).
///
/// Provides one-tap connection launching from the OS-level app icon
/// long-press menu. Shows the 4 most recently connected servers.
class ShortcutService {
  static const QuickActions _quickActions = QuickActions();

  /// The host of the shortcut last picked, until something connects to it:
  /// set as the app starts and while it runs, and told to whoever listens
  /// (it was read once, as the home screen started).
  static final pendingConnection = ValueNotifier<String?>(null);

  /// Get and clear any pending connection ID from a shortcut launch.
  static String? consumePendingConnectionId() {
    final id = pendingConnection.value;
    pendingConnection.value = null;
    return id;
  }

  /// A shortcut of the app's icon picked, [type] naming it.
  static void picked(String type) {
    AppLogger.info('Quick action triggered: $type');
    if (type.startsWith('connect_')) {
      pendingConnection.value = type.replaceFirst('connect_', '');
    }
  }

  /// Initialize shortcut handling. Call once on app startup.
  static void initialize() {
    // Desktop platforms don't support quick actions
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) return;

    _quickActions.initialize(picked);
  }

  /// Update shortcuts with the most recently connected servers.
  ///
  /// Call this after a successful connection or on app startup
  /// when connection data is available.
  static Future<void> updateShortcuts(List<Connection> recentConnections) async {
    // Desktop platforms don't support quick actions
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) return;

    try {
      final shortcuts = recentConnections
          .take(4) // iOS supports max 4 quick actions
          .map((conn) {
        final label = conn.label.isNotEmpty
            ? conn.label
            : hostWithPort(conn.host, conn.port);

        return ShortcutItem(
          type: 'connect_${conn.id}',
          localizedTitle: label,
          icon: Platform.isAndroid ? 'ic_shortcut_connect' : 'ConnectIcon',
        );
      }).toList();

      await _quickActions.setShortcutItems(shortcuts);
      AppLogger.info('Updated ${shortcuts.length} app shortcuts');
    } catch (e) {
      AppLogger.error('Failed to update shortcuts', e);
    }
  }

  /// Clear all shortcuts.
  static Future<void> clearShortcuts() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) return;

    try {
      await _quickActions.clearShortcutItems();
    } catch (e) {
      AppLogger.error('Failed to clear shortcuts', e);
    }
  }
}
