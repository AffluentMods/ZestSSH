import 'package:drift/drift.dart';

/// Persisted scheduled tasks for background SSH automation via WorkManager.
///
/// Each row represents one scheduled task that runs periodically or
/// at a specific daily/weekly time. The native Android WorkManager handles
/// the actual scheduling; this table stores the task configuration and
/// run history metadata.
class ScheduledTasks extends Table {
  /// Unique task ID (UUID). Also used as the WorkManager unique work name.
  TextColumn get id => text()();

  /// User-visible name for the task.
  TextColumn get name => text().withLength(min: 1, max: 255)();

  /// Action type: 'execute', 'snippet', 'workflow'.
  TextColumn get action => text().withLength(min: 1, max: 32)();

  /// Target connection ID.
  TextColumn get connectionId => text()();

  /// Shell command (for 'execute' action).
  TextColumn get command => text().nullable()();

  /// Snippet name (for 'snippet' action).
  TextColumn get snippetName => text().nullable()();

  /// Workflow ID (for 'workflow' action).
  TextColumn get workflowId => text().nullable()();

  /// Schedule type: 'interval', 'daily', 'weekly'.
  TextColumn get scheduleType => text().withLength(min: 1, max: 16)();

  /// Interval in minutes (for 'interval' schedule type).
  IntColumn get intervalMinutes =>
      integer().withDefault(const Constant(60))();

  /// Hour of day (0-23) for daily/weekly schedules.
  IntColumn get hour => integer().nullable()();

  /// Minute of hour (0-59) for daily/weekly schedules.
  IntColumn get minute => integer().nullable()();

  /// Day of week (1=Mon, 7=Sun) for weekly schedule.
  IntColumn get dayOfWeek => integer().nullable()();

  /// Whether the task is active.
  BoolColumn get enabled =>
      boolean().withDefault(const Constant(true))();

  /// ID of the automation API key to use for authentication.
  TextColumn get apiKeyId => text()();

  DateTimeColumn get createdAt => dateTime()();

  /// Timestamp of the last successful run.
  DateTimeColumn get lastRunAt => dateTime().nullable()();

  /// Summary of the last run result ('success', 'failure: ...').
  TextColumn get lastResult => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
