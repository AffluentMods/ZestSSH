import 'package:drift/drift.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/tables/workflows.dart';

part 'workflows_dao.g.dart';

@DriftAccessor(tables: [Workflows])
class WorkflowsDao extends DatabaseAccessor<AppDatabase>
    with _$WorkflowsDaoMixin {
  WorkflowsDao(super.db);

  /// Watch all workflows, newest first.
  Stream<List<WorkflowRow>> watchAll() {
    return (select(workflows)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .watch();
  }

  /// Get all workflows.
  Future<List<WorkflowRow>> getAll() {
    return (select(workflows)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .get();
  }

  /// Get a workflow by ID.
  Future<WorkflowRow?> getById(String id) {
    return (select(workflows)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// Insert or replace a workflow.
  Future<void> upsert(WorkflowsCompanion entry) {
    return into(workflows).insertOnConflictUpdate(entry);
  }

  /// Delete a workflow by ID.
  Future<int> deleteById(String id) {
    return (delete(workflows)..where((t) => t.id.equals(id))).go();
  }

  /// Update lastRunAt timestamp.
  Future<void> updateLastRun(String id, DateTime time) {
    return (update(workflows)..where((t) => t.id.equals(id)))
        .write(WorkflowsCompanion(lastRunAt: Value(time)));
  }
}
