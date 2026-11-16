import 'package:drift/drift.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/tables/scheduled_tasks.dart';

part 'scheduled_tasks_dao.g.dart';

@DriftAccessor(tables: [ScheduledTasks])
class ScheduledTasksDao extends DatabaseAccessor<AppDatabase>
    with _$ScheduledTasksDaoMixin {
  ScheduledTasksDao(super.db);

  /// Watch all scheduled tasks, newest first.
  Stream<List<ScheduledTask>> watchAll() {
    return (select(scheduledTasks)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .watch();
  }

  /// Get all scheduled tasks.
  Future<List<ScheduledTask>> getAll() {
    return (select(scheduledTasks)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .get();
  }

  /// Get a task by ID.
  Future<ScheduledTask?> getById(String id) {
    return (select(scheduledTasks)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// Insert or replace a task.
  Future<void> upsert(ScheduledTasksCompanion entry) {
    return into(scheduledTasks).insertOnConflictUpdate(entry);
  }

  /// Delete a task by ID.
  Future<int> deleteById(String id) {
    return (delete(scheduledTasks)..where((t) => t.id.equals(id))).go();
  }

  /// Update the enabled flag.
  Future<void> setEnabled(String id, bool enabled) {
    return (update(scheduledTasks)..where((t) => t.id.equals(id)))
        .write(ScheduledTasksCompanion(enabled: Value(enabled)));
  }

  /// Update last run info.
  Future<void> updateLastRun(String id, DateTime time, String? result) {
    return (update(scheduledTasks)..where((t) => t.id.equals(id))).write(
      ScheduledTasksCompanion(
        lastRunAt: Value(time),
        lastResult: Value(result),
      ),
    );
  }

  /// Get only enabled tasks.
  Future<List<ScheduledTask>> getEnabled() {
    return (select(scheduledTasks)
          ..where((t) => t.enabled.equals(true))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .get();
  }
}
