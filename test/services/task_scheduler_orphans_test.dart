import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/task_scheduler_service.dart';

/// WorkManager's jobs whose task has no row go (found in a review):
/// left by Delete all local data or a database that went, they kept their
/// command text and came up every interval for a task no screen showed, and nothing in
/// the app could cancel them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.affluentlabs.zestssh/scheduler');
  late List<MethodCall> calls;
  late List<Map<String, Object?>> jobs;

  setUp(() {
    calls = [];
    jobs = [];
    TaskSchedulerService.debugAvailable = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'getScheduledTasks' ? jobs : null;
    });
  });
  tearDown(() {
    TaskSchedulerService.debugAvailable = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('a job whose task has no row is cancelled; one with a row, and one that names no task, are left', () async {
    jobs = [
      {'id': '1', 'taskId': 'kept', 'state': 'ENQUEUED', 'runAttemptCount': 0},
      {'id': '2', 'taskId': 'gone', 'state': 'ENQUEUED', 'runAttemptCount': 0},
      {'id': '3', 'taskId': 'unknown', 'state': 'ENQUEUED', 'runAttemptCount': 0},
    ];
    expect(await TaskSchedulerService.cancelOrphans({'kept'}), 1);
    expect([for (final c in calls) if (c.method == 'cancelTask') (c.arguments as Map)['taskId']], ['gone']);
  });

  test('every job of a device with no task left goes', () async {
    jobs = [
      {'id': '1', 'taskId': 'a', 'state': 'ENQUEUED', 'runAttemptCount': 0},
      {'id': '2', 'taskId': 'b', 'state': 'RUNNING', 'runAttemptCount': 1},
    ];
    expect(await TaskSchedulerService.cancelOrphans(const {}), 2);
  });

  test('nothing is asked where there is no scheduler (a computer, an iPhone)', () async {
    TaskSchedulerService.debugAvailable = false;
    expect(await TaskSchedulerService.cancelOrphans(const {}), 0);
    expect(calls, isEmpty);
  });
}
