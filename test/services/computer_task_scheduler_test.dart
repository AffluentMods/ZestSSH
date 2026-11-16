import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart' show ScheduledTask;
import 'package:zestssh/models/scheduled_task.dart';
import 'package:zestssh/services/computer_task_scheduler.dart';

/// A computer's scheduled tasks (4.0): when each is due, a run missed while
/// the app was closed or locked made up for once, a run that takes long
/// never started twice, a task deleted or turned off while it waited, and
/// tasks turned back on, as Android's WorkManager runs them. The clock is a
/// test's; the tasks are a list the runs write their last run to, as the
/// app's automation path writes it to the database.
void main() {
  late DateTime now;
  late List<ScheduledTask> tasks;
  late List<String> ran;
  late bool mayRun;
  Completer<void>? holding;

  ScheduledTask task(String id,
          {ScheduleType type = ScheduleType.interval,
          int every = 60,
          int? hour,
          int? minute,
          int? day,
          required DateTime made,
          DateTime? last,
          bool on = true}) =>
      ScheduledTask(
        id: id,
        name: 'Task $id',
        action: 'execute',
        connectionId: 'web-01',
        command: 'uptime',
        scheduleType: type.key,
        intervalMinutes: every,
        hour: hour,
        minute: minute,
        dayOfWeek: day,
        enabled: on,
        apiKeyId: 'key-1',
        createdAt: made,
        lastRunAt: last,
      );

  ComputerTaskScheduler scheduler() => ComputerTaskScheduler(
        loadTasks: () async => List.of(tasks),
        stillOn: (id) async => tasks.any((t) => t.id == id && t.enabled),
        run: (t) async {
          ran.add(t.id);
          final hold = holding;
          if (hold != null) await hold.future;
          // What the automation path writes when the run ends.
          final i = tasks.indexWhere((x) => x.id == t.id);
          if (i >= 0) tasks[i] = tasks[i].copyWith(lastRunAt: Value(now), lastResult: const Value('success'));
        },
        mayRun: () => mayRun,
        clock: () => now,
      );

  setUp(() {
    now = DateTime(2026, 11, 16, 10, 0); // a Monday
    tasks = [];
    ran = [];
    mayRun = true;
    holding = null;
  });

  group('when a task is due', () {
    test('every N minutes: at once when made, then N minutes after each run, 15 at the least', () {
      final made = DateTime(2026, 11, 16, 9, 0);
      expect(scheduledTaskNextDue(type: ScheduleType.interval, intervalMinutes: 30, from: made, fromIsRun: false), made);
      expect(scheduledTaskNextDue(type: ScheduleType.interval, intervalMinutes: 30, from: made, fromIsRun: true),
          DateTime(2026, 11, 16, 9, 30));
      expect(scheduledTaskNextDue(type: ScheduleType.interval, intervalMinutes: 5, from: made, fromIsRun: true),
          DateTime(2026, 11, 16, 9, 15));
    });

    test('daily: the first time of the day after it was made or last ran', () {
      DateTime next(DateTime from) => scheduledTaskNextDue(
          type: ScheduleType.daily, intervalMinutes: 1440, hour: 2, minute: 30, from: from, fromIsRun: false);
      expect(next(DateTime(2026, 11, 16, 1, 0)), DateTime(2026, 11, 16, 2, 30));
      expect(next(DateTime(2026, 11, 16, 2, 30)), DateTime(2026, 11, 17, 2, 30), reason: 'not the moment it ran');
      expect(next(DateTime(2026, 11, 16, 9, 0)), DateTime(2026, 11, 17, 2, 30));
      expect(next(DateTime(2026, 11, 30, 23, 0)), DateTime(2026, 12, 1, 2, 30), reason: 'over the end of a month');
    });

    test('weekly: its day of the week at its time', () {
      DateTime next(DateTime from, int day) => scheduledTaskNextDue(
          type: ScheduleType.weekly, intervalMinutes: 10080, hour: 4, minute: 0, dayOfWeek: day, from: from, fromIsRun: true);
      final monday = DateTime(2026, 11, 16, 10, 0);
      expect(next(monday, 3), DateTime(2026, 11, 18, 4, 0), reason: 'Wednesday this week');
      expect(next(monday, 1), DateTime(2026, 11, 23, 4, 0), reason: "Monday's time has gone: next week");
      expect(next(DateTime(2026, 11, 16, 3, 0), 1), DateTime(2026, 11, 16, 4, 0), reason: 'later today');
      expect(next(monday, 7), DateTime(2026, 11, 22, 4, 0), reason: 'Sunday');
    });

    test('a new task every N minutes runs at the first look; a daily one made after its time waits for tomorrow',
        () async {
      tasks = [
        task('every', made: now.subtract(const Duration(minutes: 1))),
        task('daily', type: ScheduleType.daily, hour: 9, minute: 0, made: now.subtract(const Duration(minutes: 1))),
      ];
      final s = scheduler();
      expect(await s.tick(), ['every']);
      expect(s.nextDue(tasks[1]), DateTime(2026, 11, 17, 9, 0));
      expect(s.nextDue(tasks[0]), DateTime(2026, 11, 16, 11, 0));
    });
  });

  group('runs missed', () {
    test('a daily task missed three days while the app was closed runs once when it opens, then at its time', () async {
      tasks = [
        task('backup', type: ScheduleType.daily, hour: 2, minute: 0, made: DateTime(2026, 11, 1), last: DateTime(2026, 11, 13, 2, 0, 5)),
      ];
      // The app opens on Monday at 10:00: Saturday's, Sunday's and Monday's runs were missed.
      final s = scheduler();
      expect(await s.tick(), ['backup']);
      expect(await s.tick(), isEmpty, reason: 'once, not once for each day missed');
      now = now.add(const Duration(hours: 6));
      expect(await s.tick(), isEmpty);
      expect(s.nextDue(tasks.single), DateTime(2026, 11, 17, 2, 0), reason: 'its time is kept after a late run');
      now = DateTime(2026, 11, 17, 2, 0, 10);
      expect(await s.tick(), ['backup']);
      expect(ran, ['backup', 'backup']);
    });

    test('an interval task missed for hours runs once, and its next run counts from that one', () async {
      tasks = [task('disk', every: 30, made: DateTime(2026, 11, 10), last: DateTime(2026, 11, 15, 22, 0))];
      final s = scheduler();
      expect(await s.tick(), ['disk']);
      now = now.add(const Duration(minutes: 29));
      expect(await s.tick(), isEmpty);
      now = now.add(const Duration(minutes: 1));
      expect(await s.tick(), ['disk']);
    });

    test('the app closed then opened: a new scheduler reads the last run from the database and runs nothing twice',
        () async {
      tasks = [task('disk', every: 60, made: DateTime(2026, 11, 10), last: now.subtract(const Duration(minutes: 20)))];
      final first = scheduler();
      expect(await first.tick(), isEmpty, reason: 'ran 20 minutes ago');
      first.stop();
      // Closed for two hours, then opened: one run, as soon as it may.
      now = now.add(const Duration(hours: 2));
      final second = scheduler();
      expect(await second.tick(), ['disk']);
      expect(await second.tick(), isEmpty);
    });

    test('while nothing may run (locked, no Squeezed, automation off) tasks wait, and then run once', () async {
      tasks = [task('a', every: 15, made: DateTime(2026, 11, 10), last: now.subtract(const Duration(hours: 3)))];
      final s = scheduler();
      mayRun = false;
      expect(await s.tick(), isEmpty);
      now = now.add(const Duration(hours: 1));
      expect(await s.tick(), isEmpty);
      mayRun = true;
      expect(await s.tick(), ['a']);
      expect(await s.tick(), isEmpty);
    });

    test('a run that ends in an error is not tried again at once', () async {
      tasks = [task('a', every: 15, made: DateTime(2026, 11, 10))];
      final s = ComputerTaskScheduler(
        loadTasks: () async => tasks,
        stillOn: (_) async => true,
        run: (t) async {
          ran.add(t.id);
          throw StateError('the host did not answer');
        },
        mayRun: () => true,
        clock: () => now,
      );
      expect(await s.tick(), ['a']);
      expect(await s.tick(), isEmpty, reason: 'counted from when it started, though no last run was written');
      now = now.add(const Duration(minutes: 15));
      expect(await s.tick(), ['a']);
    });
  });

  group('runs that overlap', () {
    test('a run that takes long is never started a second time while it runs', () async {
      tasks = [task('slow', every: 15, made: DateTime(2026, 11, 10))];
      final s = scheduler();
      holding = Completer<void>();
      final first = s.tick();
      await Future<void>.delayed(Duration.zero);
      expect(s.busy, isTrue);
      // Twenty minutes on, it would be due again: the look finds a run under way.
      now = now.add(const Duration(minutes: 20));
      expect(await s.tick(), isEmpty);
      holding!.complete();
      expect(await first, ['slow']);
      // Its next run counts from when this one ended.
      expect(await s.tick(), isEmpty);
      now = now.add(const Duration(minutes: 15));
      expect(await s.tick(), ['slow']);
      expect(ran, ['slow', 'slow']);
    });

    test('tasks due together run one after another, the one due longest first', () async {
      tasks = [
        task('b', every: 60, made: DateTime(2026, 11, 10), last: now.subtract(const Duration(minutes: 61))),
        task('a', every: 60, made: DateTime(2026, 11, 10), last: now.subtract(const Duration(hours: 5))),
      ];
      expect(await scheduler().tick(), ['a', 'b']);
    });
  });

  group('tasks changed while they wait', () {
    test('a task deleted while it waits for another to finish runs nothing', () async {
      tasks = [
        task('first', every: 60, made: DateTime(2026, 11, 10), last: now.subtract(const Duration(hours: 3))),
        task('second', every: 60, made: DateTime(2026, 11, 10), last: now.subtract(const Duration(hours: 2))),
      ];
      final s = scheduler();
      holding = Completer<void>();
      final look = s.tick();
      await Future<void>.delayed(Duration.zero);
      expect(ran, ['first']);
      tasks.removeWhere((t) => t.id == 'second');
      s.noteDeleted('second');
      holding!.complete();
      expect(await look, ['first']);
      expect(ran, ['first']);
    });

    test('a task turned off while it waits runs nothing, and a turned off task is never due', () async {
      tasks = [
        task('first', every: 60, made: DateTime(2026, 11, 10), last: now.subtract(const Duration(hours: 3))),
        task('second', every: 60, made: DateTime(2026, 11, 10), last: now.subtract(const Duration(hours: 2))),
        task('off', every: 15, made: DateTime(2026, 11, 10), on: false),
      ];
      final s = scheduler();
      holding = Completer<void>();
      final look = s.tick();
      await Future<void>.delayed(Duration.zero);
      tasks[1] = tasks[1].copyWith(enabled: false);
      holding!.complete();
      expect(await look, ['first']);
    });

    test('turned back on: every N minutes runs at once, daily waits for its next time (no catch up), as on Android',
        () async {
      tasks = [
        task('every', every: 60, made: DateTime(2026, 11, 10), last: now.subtract(const Duration(minutes: 10))),
        task('daily', type: ScheduleType.daily, hour: 2, minute: 0, made: DateTime(2026, 11, 10), last: DateTime(2026, 11, 12, 2, 0, 3)),
      ];
      final s = scheduler();
      s.noteEnabled('every');
      s.noteEnabled('daily');
      expect(await s.tick(), ['every']);
      expect(s.nextDue(tasks[1]), DateTime(2026, 11, 17, 2, 0));
    });
  });

  test('started, it looks first after a short wait, then on its own beat; stopped, it looks no more', () async {
    tasks = [task('a', every: 15, made: DateTime(2026, 11, 10))];
    final s = ComputerTaskScheduler(
      loadTasks: () async => List.of(tasks),
      stillOn: (_) async => true,
      run: (t) async => ran.add(t.id),
      mayRun: () => true,
      clock: () => now,
      tickEvery: const Duration(milliseconds: 60),
    );
    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 250 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    s.start(firstAfter: const Duration(milliseconds: 100));
    expect(ran, isEmpty, reason: 'nothing at once: its first look waits');
    await until(() => ran.isNotEmpty);
    expect(ran, ['a']);
    // Sixteen minutes on (the clock is the test's), the beat finds it due again.
    now = now.add(const Duration(minutes: 16));
    await until(() => ran.length > 1);
    expect(ran, ['a', 'a']);
    s.stop();
    now = now.add(const Duration(hours: 1));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(ran, ['a', 'a']);
  });
}
