import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zestssh/utils/logger.dart';

/// Manages the Android foreground service that keeps SSH connections
/// alive when the app is backgrounded.
///
/// On non-Android platforms, all methods are no-ops.
/// The native service just holds a persistent notification - the Dart
/// isolate handles all SSH traffic.
/// The lines the sessions notification lists when pulled down (3.2): each open
/// host's name once, in the order the sessions opened, with how many sessions
/// it has when more than one ("web-02 (2)"). Blank names are left out.
List<String> notificationSessionLines(Iterable<String> labels) {
  final counts = <String, int>{};
  for (final label in labels) {
    final name = label.trim();
    if (name.isEmpty) continue;
    counts[name] = (counts[name] ?? 0) + 1;
  }
  return [for (final e in counts.entries) e.value > 1 ? '${e.key} (${e.value})' : e.key];
}

class ForegroundService {
  static const _channel =
      MethodChannel('com.affluentlabs.zestssh/foreground');

  /// What is asked of the service, on any platform, for tests; null in the app.
  @visibleForTesting
  static void Function(String method, Map<String, Object?> arguments)? debugCalls;

  /// Start the foreground service with the given connection count, or bring its
  /// notification up to date. [sessionNames] are the lines the notification
  /// lists when pulled down (see [notificationSessionLines]).
  static Future<void> start({int connectionCount = 1, List<String> sessionNames = const []}) async {
    debugCalls?.call('startService', {'count': connectionCount, 'names': sessionNames});
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('startService', {'count': connectionCount, 'names': sessionNames});
    } catch (e) {
      AppLogger.error('Failed to start foreground service', e);
    }
  }

  /// Update the notification to reflect the current connection count.
  static Future<void> updateCount(int count) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('updateCount', {'count': count});
    } catch (e) {
      AppLogger.error('Failed to update foreground service count', e);
    }
  }

  /// Stop the foreground service (no active connections remaining).
  static Future<void> stop() async {
    debugCalls?.call('stopService', const {});
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stopService');
    } catch (e) {
      AppLogger.error('Failed to stop foreground service', e);
    }
  }
}
