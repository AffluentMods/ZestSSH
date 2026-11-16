import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zestssh/utils/logger.dart';

/// Flutter bridge to the Android WorkManager scheduler via method channel.
///
/// All methods are no-ops on non-Android platforms (iOS, desktop).
/// On iOS, users are directed to use iOS Shortcuts Automations instead.
class TaskSchedulerService {
  static const _channel =
      MethodChannel('com.affluentlabs.zestssh/scheduler');

  /// Whether the scheduler is available on the current platform.
  static bool get isAvailable => debugAvailable ?? Platform.isAndroid;

  /// A test's say in [isAvailable], with the channel played.
  @visibleForTesting
  static bool? debugAvailable;

  /// Schedule a recurring periodic task via WorkManager.
  ///
  /// [intervalMinutes] minimum is 15 (WorkManager constraint).
  /// For daily/weekly tasks, the caller should convert to interval minutes
  /// or use [scheduleOneShot] with a calculated delay.
  ///
  /// [apiKeyId] is the ID (not the raw secret) of the automation API key.
  /// The worker passes the ID via the intent; the Flutter automation handler
  /// looks up the actual key from secure storage at execution time.
  static Future<void> scheduleRecurring({
    required String taskId,
    required String action,
    required String connectionId,
    String? command,
    required String apiKeyId,
    required int intervalMinutes,
    int initialDelayMinutes = 0,
    String? snippetName,
    String? workflowId,
    String? workflowName,
  }) async {
    if (!isAvailable) return;
    try {
      await _channel.invokeMethod('scheduleTask', {
        'taskId': taskId,
        'action': action,
        'connectionId': connectionId,
        'command': command,
        'apiKeyId': apiKeyId,
        'intervalMinutes': intervalMinutes,
        'initialDelayMinutes': initialDelayMinutes,
        'snippetName': snippetName,
        'workflowId': workflowId,
        'workflowName': workflowName,
      });
      AppLogger.info(
          'Scheduler: enqueued recurring task "$taskId" every ${intervalMinutes}m');
    } on PlatformException catch (e) {
      AppLogger.error('Scheduler: failed to schedule task "$taskId"', e);
      rethrow;
    }
  }

  /// Schedule a one-time delayed task via WorkManager.
  ///
  /// [apiKeyId] is the ID (not the raw secret) of the automation API key.
  /// The worker passes the ID via the intent; the Flutter automation handler
  /// looks up the actual key from secure storage at execution time.
  static Future<void> scheduleOneShot({
    required String taskId,
    required String action,
    required String connectionId,
    String? command,
    required String apiKeyId,
    required int delayMinutes,
    String? snippetName,
    String? workflowId,
    String? workflowName,
  }) async {
    if (!isAvailable) return;
    try {
      await _channel.invokeMethod('scheduleOneShot', {
        'taskId': taskId,
        'action': action,
        'connectionId': connectionId,
        'command': command,
        'apiKeyId': apiKeyId,
        'delayMinutes': delayMinutes,
        'snippetName': snippetName,
        'workflowId': workflowId,
        'workflowName': workflowName,
      });
      AppLogger.info(
          'Scheduler: enqueued one-shot task "$taskId" delay=${delayMinutes}m');
    } on PlatformException catch (e) {
      AppLogger.error(
          'Scheduler: failed to schedule one-shot "$taskId"', e);
      rethrow;
    }
  }

  /// Cancel a specific scheduled task.
  static Future<void> cancelTask(String taskId) async {
    if (!isAvailable) return;
    try {
      await _channel.invokeMethod('cancelTask', {'taskId': taskId});
      AppLogger.info('Scheduler: cancelled task "$taskId"');
    } on PlatformException catch (e) {
      AppLogger.error('Scheduler: failed to cancel task "$taskId"', e);
      rethrow;
    }
  }

  /// Cancel all scheduled tasks.
  static Future<void> cancelAll() async {
    if (!isAvailable) return;
    try {
      await _channel.invokeMethod('cancelAll');
      AppLogger.info('Scheduler: cancelled all tasks');
    } on PlatformException catch (e) {
      AppLogger.error('Scheduler: failed to cancel all tasks', e);
      rethrow;
    }
  }

  /// Cancels WorkManager's jobs whose task is not among [taskIds], the tasks this
  /// device holds rows of: a job left by a wipe or a database that went kept its
  /// command text and came up for a task no screen showed, and could not be cancelled
  /// from the app (found in a code review). Returns how many.
  static Future<int> cancelOrphans(Set<String> taskIds) async {
    if (!isAvailable) return 0;
    var cancelled = 0;
    for (final job in await getScheduledTasks()) {
      final id = job['taskId'];
      if (id is! String || id == 'unknown' || taskIds.contains(id)) continue;
      await cancelTask(id);
      cancelled++;
    }
    return cancelled;
  }

  /// Get information about all scheduled WorkManager tasks.
  ///
  /// Returns a list of maps with keys: id, taskId, state, runAttemptCount.
  static Future<List<Map<String, dynamic>>> getScheduledTasks() async {
    if (!isAvailable) return [];
    try {
      final result = await _channel.invokeMethod('getScheduledTasks');
      if (result is List) {
        return result
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList();
      }
      return [];
    } on PlatformException catch (e) {
      AppLogger.error('Scheduler: failed to get tasks', e);
      return [];
    }
  }
}
