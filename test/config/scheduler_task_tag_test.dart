import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Java's String.hashCode.
int _javaHash(String s) {
  var h = 0;
  for (final c in s.codeUnits) {
    h = (31 * h + c) & 0xffffffff;
  }
  return h;
}

/// The order a java.util.HashSet made from [tags] (capacity 16, as
/// HashSet(Collection) makes it for three) gives them back: by bucket, then
/// as added.
List<String> _javaHashSetOrder(List<String> tags) {
  int bucket(String s) {
    final h = _javaHash(s);
    return (h ^ (h >>> 16)) & 15;
  }

  final indexed = [for (var i = 0; i < tags.length; i++) (i, bucket(tags[i]), tags[i])];
  indexed.sort((a, b) => a.$2 != b.$2 ? a.$2.compareTo(b.$2) : a.$1.compareTo(b.$1));
  return [for (final e in indexed) e.$3];
}

const _worker = 'com.affluentlabs.zestssh.scheduler.SshTaskWorker';
const _tag = 'zestssh_scheduled_task';
const _kotlin = 'android/app/src/main/kotlin/com/affluentlabs/zestssh/scheduler';

/// The orphaned-jobs sweep (728340f3) cancels WorkManager's jobs whose
/// task id has no row, by the id TaskSchedulerManager.getScheduledTasks
/// reports: the first tag that was not the app's own. WorkRequest.Builder
/// adds the worker's class name as a tag of every request, and WorkInfo
/// keeps the tags in a HashSet, so for about three tasks in four (uuid v4
/// ids) the class name came first: the orphan was "cancelled" by a name no
/// work has, and kept coming up every interval.
/// Android's files do not run here: they are read.
void main() {
  test('the Java order put the class name first for such a task id (why it was missed)', () {
    const taskId = 'b3b8a410-832e-47fd-869e-09fa258410fe';
    expect(_javaHashSetOrder([_worker, _tag, taskId]).firstWhere((t) => t != _tag), _worker);
  });

  test("a job's task id is the tag that is neither the app's own nor the worker's class name", () {
    final manager = File('$_kotlin/TaskSchedulerManager.kt').readAsStringSync().replaceAll('\r\n', '\n');
    final worker = File('$_kotlin/SshTaskWorker.kt').readAsStringSync();
    expect(worker, contains('package com.affluentlabs.zestssh.scheduler'));
    expect(worker, contains('class SshTaskWorker('), reason: 'the class whose name is $_worker');
    expect(manager, contains('val workerTag = SshTaskWorker::class.java.name'));
    expect(manager, contains('info.tags.firstOrNull { it != TAG_SCHEDULED_TASK && it != workerTag }'));
    expect(RegExp(r'tags\.firstOrNull').allMatches(manager), hasLength(1), reason: 'no other reading of the tags');
    // Each request is tagged with the app's tag and the task's id, as read.
    expect(RegExp(r'addTag\(TAG_SCHEDULED_TASK\)\s*addTag\(taskId\)').allMatches(manager), hasLength(2));
  });
}
