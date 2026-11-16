import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/database/daos/scheduled_tasks_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/models/scheduled_task.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/services/computer_task_scheduler.dart';
import 'package:zestssh/services/task_scheduler_service.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/platform_utils.dart' show isDesktopPlatform;

/// Where scheduled tasks run on this device: Android's WorkManager, even with
/// ZestSSH closed; a computer's own scheduler, while ZestSSH is open or in
/// the tray (4.0, [ComputerTaskScheduler]); none on iOS, which lets no app
/// run on a schedule.
enum ScheduledTasksHere { android, computer, none }

/// Where scheduled tasks run here ([debugScheduledTasksHere] in a test).
ScheduledTasksHere get scheduledTasksHere =>
    debugScheduledTasksHere ??
    (Platform.isAndroid
        ? ScheduledTasksHere.android
        : isDesktopPlatform
            ? ScheduledTasksHere.computer
            : ScheduledTasksHere.none);

/// A test's say in [scheduledTasksHere]; null asks the system.
@visibleForTesting
ScheduledTasksHere? debugScheduledTasksHere;

/// What a computer's scheduler hands the automation path for [task]: what
/// Android's worker hands it (MainActivity.kt), the task's API key by its id
/// and the task's own id, so that its last run is written to it. In the
/// app's own process, so no launch token stands in for Android's proof that
/// the app's scheduler sent it: nothing outside the app can call this.
Map<String, dynamic> scheduledRunPayload(ScheduledTask task) => {
      'action': task.action,
      'connection_id': task.connectionId,
      'api_key_id': task.apiKeyId,
      'scheduled_task_id': task.id,
      if (task.command != null) 'command': task.command,
      if (task.snippetName != null) 'snippet_name': task.snippetName,
      if (task.workflowId != null) 'workflow_id': task.workflowId,
    };

/// Where this device keeps its tasks: its Personal database, and the space
/// open where that is a team's (a task made there is kept there).
Set<ScheduledTasksDao> _taskDaos(Ref ref) {
  final daos = <ScheduledTasksDao>{ref.read(treeDatabaseProvider).scheduledTasksDao};
  try {
    daos.add(ref.read(scheduledTasksDaoProvider));
  } catch (_) {
    // A team's database that is not open: its Personal ones still run.
  }
  return daos;
}

/// A computer's scheduler (4.0): started when the app is unlocked, stopped
/// when it locks (app.dart). It runs a task through the automation path
/// Android's do, so the same refusals hold, and only while the app is
/// unlocked, the person has Squeezed and automation is on.
final computerTaskSchedulerProvider = Provider<ComputerTaskScheduler>((ref) {
  final scheduler = ComputerTaskScheduler(
    loadTasks: () async {
      final byId = <String, ScheduledTask>{};
      for (final dao in _taskDaos(ref)) {
        for (final t in await dao.getAll()) {
          byId.putIfAbsent(t.id, () => t);
        }
      }
      return byId.values.toList();
    },
    stillOn: (id) async {
      for (final dao in _taskDaos(ref)) {
        final task = await dao.getById(id);
        if (task != null) return task.enabled;
      }
      return false;
    },
    run: (task) => ref.read(automationProvider.notifier).handleAutomation(scheduledRunPayload(task)),
    // What the automation path refuses on first (refuseIfNothingRuns): a
    // task waits instead of being refused at every look.
    mayRun: () => ref.read(dbReadyProvider) && ref.read(isProProvider) && ref.read(automationProvider).enabled,
  );
  ref.onDispose(scheduler.stop);
  return scheduler;
});

/// Reactive stream of all scheduled tasks (newest first).
final scheduledTasksStreamProvider =
    StreamProvider<List<ScheduledTask>>((ref) {
  return ref.watch(scheduledTasksDaoProvider).watchAll();
});

/// Notifier for scheduled task CRUD operations + WorkManager bridge.
final scheduledTasksProvider =
    StateNotifierProvider<ScheduledTasksNotifier, AsyncValue<void>>((ref) {
  return ScheduledTasksNotifier(ref);
});

class ScheduledTasksNotifier extends StateNotifier<AsyncValue<void>> {
  final Ref _ref;

  ScheduledTasksNotifier(this._ref) : super(const AsyncValue.data(null));

  /// Create a new scheduled task and enqueue it in WorkManager.
  Future<void> createTask({
    required String name,
    required ScheduledTaskAction action,
    required String connectionId,
    String? command,
    String? snippetName,
    String? workflowId,
    required ScheduleType scheduleType,
    required int intervalMinutes,
    int? hour,
    int? minute,
    int? dayOfWeek,
    required String apiKeyId,
  }) async {
    state = const AsyncValue.loading();
    try {
      final id = const Uuid().v4();
      final dao = _ref.read(scheduledTasksDaoProvider);

      // Verify the API key ID exists before scheduling
      final keys = _ref.read(automationKeysProvider);
      final keyExists = keys.any((k) => k.id == apiKeyId);
      if (!keyExists) {
        throw StateError('API key not found: $apiKeyId');
      }

      // Calculate effective interval for daily/weekly
      final effectiveInterval = _calculateEffectiveInterval(
        scheduleType: scheduleType,
        intervalMinutes: intervalMinutes,
        hour: hour,
        minute: minute,
        dayOfWeek: dayOfWeek,
      );

      // Calculate initial delay for daily/weekly schedules
      final initialDelay = _calculateInitialDelay(
        scheduleType: scheduleType,
        intervalMinutes: intervalMinutes,
        hour: hour,
        minute: minute,
        dayOfWeek: dayOfWeek,
      );

      // Persist to database
      await dao.upsert(ScheduledTasksCompanion(
        id: Value(id),
        name: Value(name),
        action: Value(action.key),
        connectionId: Value(connectionId),
        command: Value(command),
        snippetName: Value(snippetName),
        workflowId: Value(workflowId),
        scheduleType: Value(scheduleType.key),
        intervalMinutes: Value(effectiveInterval),
        hour: Value(hour),
        minute: Value(minute),
        dayOfWeek: Value(dayOfWeek),
        enabled: const Value(true),
        apiKeyId: Value(apiKeyId),
        createdAt: Value(DateTime.now()),
      ));

      // Resolve workflow name for the WorkManager payload
      String? workflowName;
      if (action == ScheduledTaskAction.workflow && workflowId != null) {
        // One of your Tree's, whichever space is on screen: no other runs on a
        // schedule.
        final wfDao = _ref.read(treeDatabaseProvider).workflowsDao;
        final wf = await wfDao.getById(workflowId);
        workflowName = wf?.name;
      }

      // Enqueue in WorkManager - pass only the key ID, not the raw secret.
      // (A computer's scheduler finds the new task by itself: it is due at
      // once where it runs every N minutes, as Android runs it.)
      // The worker passes the ID via the intent; the Flutter automation
      // handler looks up the actual key from secure storage at runtime.
      await TaskSchedulerService.scheduleRecurring(
        taskId: id,
        action: action.key,
        connectionId: connectionId,
        command: command,
        apiKeyId: apiKeyId,
        intervalMinutes: effectiveInterval,
        initialDelayMinutes: initialDelay,
        snippetName: snippetName,
        workflowId: workflowId,
        workflowName: workflowName,
      );

      AppLogger.info('ScheduledTasks: created "$name" (id=$id)');
      state = const AsyncValue.data(null);
    } catch (e, st) {
      AppLogger.error('ScheduledTasks: failed to create task', e, st);
      state = AsyncValue.error(e, st);
    }
  }

  /// Toggle a task enabled/disabled.
  Future<void> setEnabled(String taskId, bool enabled) async {
    try {
      final dao = _ref.read(scheduledTasksDaoProvider);
      await dao.setEnabled(taskId, enabled);
      // A computer's: on again, it counts from now, as Android enqueues it
      // again (every N minutes at once, daily or weekly at its next time).
      if (enabled && scheduledTasksHere == ScheduledTasksHere.computer) {
        _ref.read(computerTaskSchedulerProvider).noteEnabled(taskId);
      }

      if (enabled) {
        // Re-schedule in WorkManager
        final task = await dao.getById(taskId);
        if (task != null) {
          // Verify the API key still exists
          final keys = _ref.read(automationKeysProvider);
          final keyExists = keys.any((k) => k.id == task.apiKeyId);
          if (!keyExists) {
            throw StateError('API key not found: ${task.apiKeyId}');
          }

          String? workflowName;
          if (task.action == 'workflow' && task.workflowId != null) {
            final wfDao = _ref.read(treeDatabaseProvider).workflowsDao;
            final wf = await wfDao.getById(task.workflowId!);
            workflowName = wf?.name;
          }

          final initialDelay = _calculateInitialDelay(
            scheduleType: ScheduleType.fromKey(task.scheduleType),
            intervalMinutes: task.intervalMinutes,
            hour: task.hour,
            minute: task.minute,
            dayOfWeek: task.dayOfWeek,
          );

          await TaskSchedulerService.scheduleRecurring(
            taskId: taskId,
            action: task.action,
            connectionId: task.connectionId,
            command: task.command,
            apiKeyId: task.apiKeyId,
            intervalMinutes: task.intervalMinutes,
            initialDelayMinutes: initialDelay,
            snippetName: task.snippetName,
            workflowId: task.workflowId,
            workflowName: workflowName,
          );
        }
      } else {
        await TaskSchedulerService.cancelTask(taskId);
      }

      AppLogger.info(
          'ScheduledTasks: ${enabled ? "enabled" : "disabled"} $taskId');
    } catch (e, st) {
      AppLogger.error('ScheduledTasks: failed to toggle task', e, st);
    }
  }

  /// Delete a task from database and cancel in WorkManager.
  Future<void> deleteTask(String taskId) async {
    try {
      await TaskSchedulerService.cancelTask(taskId);
      await _ref.read(scheduledTasksDaoProvider).deleteById(taskId);
      if (scheduledTasksHere == ScheduledTasksHere.computer) {
        _ref.read(computerTaskSchedulerProvider).noteDeleted(taskId);
      }
      AppLogger.info('ScheduledTasks: deleted $taskId');
    } catch (e, st) {
      AppLogger.error('ScheduledTasks: failed to delete task', e, st);
    }
  }

  /// Calculate the effective repeat interval in minutes.
  int _calculateEffectiveInterval({
    required ScheduleType scheduleType,
    required int intervalMinutes,
    int? hour,
    int? minute,
    int? dayOfWeek,
  }) {
    switch (scheduleType) {
      case ScheduleType.interval:
        // WorkManager minimum is 15 minutes
        return intervalMinutes.clamp(15, 999999);
      case ScheduleType.daily:
        return 24 * 60; // 1440 minutes
      case ScheduleType.weekly:
        return 7 * 24 * 60; // 10080 minutes
    }
  }

  /// Calculate the initial delay in minutes until the first run.
  ///
  /// For interval tasks, returns 0 (run immediately).
  /// For daily/weekly, calculates minutes until the next occurrence
  /// of the target time.
  int _calculateInitialDelay({
    required ScheduleType scheduleType,
    required int intervalMinutes,
    int? hour,
    int? minute,
    int? dayOfWeek,
  }) {
    if (scheduleType == ScheduleType.interval) return 0;

    final now = DateTime.now();
    final targetHour = hour ?? 9;
    final targetMinute = minute ?? 0;

    if (scheduleType == ScheduleType.daily) {
      var target = DateTime(
        now.year,
        now.month,
        now.day,
        targetHour,
        targetMinute,
      );
      // If the time has already passed today, schedule for tomorrow
      if (target.isBefore(now)) {
        target = target.add(const Duration(days: 1));
      }
      return target.difference(now).inMinutes;
    }

    if (scheduleType == ScheduleType.weekly) {
      final targetDay = dayOfWeek ?? 1; // Monday
      // DateTime.weekday: 1=Monday, 7=Sunday (matches our convention)
      var daysUntil = (targetDay - now.weekday) % 7;
      var target = DateTime(
        now.year,
        now.month,
        now.day + daysUntil,
        targetHour,
        targetMinute,
      );
      // If it's the target day but the time has passed, schedule next week
      if (target.isBefore(now)) {
        target = target.add(const Duration(days: 7));
      }
      return target.difference(now).inMinutes;
    }

    return 0;
  }
}
