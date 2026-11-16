/// Scheduled tasks on a computer (4.0). Android's run by WorkManager, even
/// with ZestSSH closed; a computer's are run by the app itself, while it is
/// open or in the tray (and unlocked), through the same automation path as
/// Android's (AutomationNotifier.handleAutomation), so the same refusals
/// hold: Squeezed, automation on, the task's API key there and allowed for
/// runs with nobody there, no Telnet host and no remote screen unattended.
///
/// When a task is due, as Android's are:
///  * every N minutes: at once when it is made or turned back on (Android
///    enqueues it with no delay), then N minutes after its last run (15 at
///    the least, WorkManager's least);
///  * daily or weekly: at its time, the first one after it was made, turned
///    back on, or last ran.
///
/// A run missed while the app was closed, locked or busy is not made up for
/// several times over: the task runs once, as soon as it can, and its next
/// run counts from that one (WorkManager runs a periodic job whose time
/// passed once, as soon as it may). Unlike WorkManager, a daily or weekly
/// task keeps its time after a late run (WorkManager counts its day from
/// the late run, so its time drifts).
///
/// Pure Dart: the clock, the tasks and the run are given, so tests can move
/// time on.
library;

import 'dart:async';

import 'package:zestssh/database/database.dart' show ScheduledTask;
import 'package:zestssh/models/scheduled_task.dart';
import 'package:zestssh/utils/logger.dart';

/// WorkManager's least interval, which the app keeps to on every system.
const int kLeastTaskIntervalMinutes = 15;

/// When a task of [type] is next due, counted from [from]: for an interval,
/// [from] itself where it is not a run (the task was made or turned back
/// on, and runs at once) and [intervalMinutes] after it where it is; for a
/// daily or weekly task, the first time of its day (or of its day of the
/// week, [dayOfWeek], 1 Monday to 7 Sunday) after [from]. A time in the
/// past means due now. Wall clock times: a change to or from summer time
/// keeps a daily task at its hour.
DateTime scheduledTaskNextDue({
  required ScheduleType type,
  required int intervalMinutes,
  int? hour,
  int? minute,
  int? dayOfWeek,
  required DateTime from,
  required bool fromIsRun,
}) {
  switch (type) {
    case ScheduleType.interval:
      if (!fromIsRun) return from;
      final every = intervalMinutes < kLeastTaskIntervalMinutes ? kLeastTaskIntervalMinutes : intervalMinutes;
      return from.add(Duration(minutes: every));
    case ScheduleType.daily:
    case ScheduleType.weekly:
      final h = (hour ?? 9).clamp(0, 23);
      final m = (minute ?? 0).clamp(0, 59);
      final local = from.toLocal();
      var days = 0;
      if (type == ScheduleType.weekly) days = ((dayOfWeek ?? 1).clamp(1, 7) - local.weekday) % 7;
      var at = DateTime(local.year, local.month, local.day + days, h, m);
      if (!at.isAfter(local)) {
        at = DateTime(local.year, local.month, local.day + days + (type == ScheduleType.weekly ? 7 : 1), h, m);
      }
      return at;
  }
}

/// Runs a computer's scheduled tasks while the app is open or in the tray.
class ComputerTaskScheduler {
  ComputerTaskScheduler({
    required this.loadTasks,
    required this.stillOn,
    required this.run,
    required this.mayRun,
    DateTime Function()? clock,
    this.tickEvery = const Duration(seconds: 20),
  }) : clock = clock ?? DateTime.now;

  /// Every task this device holds (its Personal ones, and the space's open).
  final Future<List<ScheduledTask>> Function() loadTasks;

  /// Whether task [id] is still there and on, asked again just before it
  /// runs: a task deleted or turned off while it waited for another runs
  /// nothing.
  final Future<bool> Function(String id) stillOn;

  /// Runs [task] (the app: its automation path, which writes the task's last
  /// run).
  final Future<void> Function(ScheduledTask task) run;

  /// Whether anything may run now: the app unlocked, Squeezed, automation on.
  /// Where not, due tasks wait, and run once when it may.
  final bool Function() mayRun;

  final DateTime Function() clock;

  /// How often the app looks for due tasks.
  final Duration tickEvery;

  /// When each task was last started here (its last run as the database
  /// has it is written when the run ends, and not at all where the write
  /// failed): never twice for one time.
  final Map<String, DateTime> _startedAt = {};

  /// When each task was turned back on here: an interval task runs at once,
  /// a daily or weekly one waits for its next time, as on Android.
  final Map<String, DateTime> _enabledAt = {};

  Timer? _timer;
  bool _busy = false;

  /// Whether a run is under way.
  bool get busy => _busy;

  /// Starts looking for due tasks (again after a lock): first after
  /// [firstAfter], then every [tickEvery].
  void start({Duration firstAfter = const Duration(seconds: 10)}) {
    if (_timer != null) return;
    AppLogger.info('Scheduled tasks: this computer runs them while ZestSSH is open');
    _timer = Timer(firstAfter, () {
      unawaited(tick());
      _timer = Timer.periodic(tickEvery, (_) => unawaited(tick()));
    });
  }

  /// Stops looking (the app locked, or ended). A run under way finishes.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Task [id] was turned on again (its switch).
  void noteEnabled(String id) => _enabledAt[id] = clock();

  /// Task [id] was deleted.
  void noteDeleted(String id) {
    _startedAt.remove(id);
    _enabledAt.remove(id);
  }

  /// When [task] is next due here (in the past: due now).
  DateTime nextDue(ScheduledTask task) {
    var from = task.createdAt;
    var isRun = false;
    void take(DateTime? at, bool run) {
      if (at != null && at.isAfter(from)) {
        from = at;
        isRun = run;
      }
    }

    take(task.lastRunAt, true);
    take(_startedAt[task.id], true);
    take(_enabledAt[task.id], false);
    return scheduledTaskNextDue(
      type: ScheduleType.fromKey(task.scheduleType),
      intervalMinutes: task.intervalMinutes,
      hour: task.hour,
      minute: task.minute,
      dayOfWeek: task.dayOfWeek,
      from: from,
      fromIsRun: isRun,
    );
  }

  /// Runs every task that is due, one at a time, each once, the one due
  /// longest first. Nothing while another tick's runs are under way (a long
  /// run is never started twice), or while nothing may run. The ids run.
  Future<List<String>> tick() async {
    if (_busy || !mayRun()) return const [];
    _busy = true;
    final ran = <String>[];
    try {
      final now = clock();
      final List<ScheduledTask> tasks;
      try {
        tasks = await loadTasks();
      } catch (e) {
        AppLogger.warning('Scheduled tasks: the tasks could not be read: $e');
        return const [];
      }
      final due = [
        for (final t in tasks)
          if (t.enabled && !nextDue(t).isAfter(now)) t,
      ]..sort((a, b) => nextDue(a).compareTo(nextDue(b)));
      for (final task in due) {
        if (!mayRun()) break;
        if (!await stillOn(task.id)) {
          AppLogger.info('Scheduled tasks: a task was deleted or turned off before its turn; nothing ran');
          noteDeleted(task.id);
          continue;
        }
        AppLogger.info('Scheduled tasks: running a task that is due');
        _startedAt[task.id] = clock();
        try {
          await run(task);
        } catch (e) {
          AppLogger.warning('Scheduled tasks: a run ended with an error: $e');
        }
        ran.add(task.id);
      }
    } finally {
      _busy = false;
    }
    return ran;
  }
}
