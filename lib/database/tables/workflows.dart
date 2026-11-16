import 'package:drift/drift.dart';

/// Saved automation workflows - multi-step command sequences.
///
/// The workflow steps are stored as a JSON string in [stepsJson]
/// rather than a separate table, because steps are always loaded
/// and saved as a unit with their parent workflow.
@DataClassName('WorkflowRow')
class Workflows extends Table {
  TextColumn get id => text()();
  TextColumn get name => text().withLength(min: 1, max: 255)();
  TextColumn get description => text().nullable()();

  /// JSON-encoded list of WorkflowStep objects.
  TextColumn get stepsJson => text().withDefault(const Constant('[]'))();

  /// Whether the workflow is enabled (can be triggered externally).
  BoolColumn get enabled =>
      boolean().withDefault(const Constant(true))();

  /// Whether to send a notification on failure.
  BoolColumn get notifyOnFailure =>
      boolean().withDefault(const Constant(true))();

  /// Whether to send a notification on success.
  BoolColumn get notifyOnSuccess =>
      boolean().withDefault(const Constant(false))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get lastRunAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
