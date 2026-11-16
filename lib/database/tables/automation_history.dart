import 'package:drift/drift.dart';

/// Persisted log of automation executions (commands, snippets, batches, workflows).
///
/// Provides an audit trail of all headless SSH operations triggered
/// by external apps (Tasker, MacroDroid, Shortcuts) or internal workflows.
class AutomationHistory extends Table {
  TextColumn get id => text()();
  DateTimeColumn get timestamp => dateTime()();

  /// Action type: 'execute', 'snippet', 'batch', 'connect', 'workflow'.
  TextColumn get action => text().withLength(min: 1, max: 32)();

  /// Connection label or ID that was targeted.
  TextColumn get connectionId => text()();

  /// The command that was executed (or snippet name, or workflow name).
  TextColumn get command => text()();

  /// Snippet name, if action was 'snippet'.
  TextColumn get snippetName => text().nullable()();

  /// Command stdout output.
  TextColumn get stdout => text().withDefault(const Constant(''))();

  /// Command stderr output.
  TextColumn get stderr => text().withDefault(const Constant(''))();

  /// Process exit code (null if not available).
  IntColumn get exitCode => integer().nullable()();

  /// Whether the execution succeeded.
  BoolColumn get success => boolean()();

  /// Elapsed time in milliseconds.
  IntColumn get elapsedMs => integer()();

  @override
  Set<Column> get primaryKey => {id};
}
