import 'package:drift/drift.dart';

/// Saved command snippets for quick execution in terminal sessions.
///
/// Users can save frequently-used commands and replay them with
/// a single tap from the terminal toolbar or in-terminal drawer.
class Snippets extends Table {
  TextColumn get id => text()();
  TextColumn get label => text().withLength(min: 1, max: 255)();
  TextColumn get command => text().withLength(min: 1, max: 4096)();

  /// Optional category for grouping snippets (e.g. 'Docker', 'Git', 'System')
  TextColumn get category => text().nullable()();

  /// Show confirmation dialog before executing.
  BoolColumn get confirmBeforeRun =>
      boolean().withDefault(const Constant(false))();

  /// Whether this is a built-in default snippet (not deletable by free users).
  BoolColumn get isDefault =>
      boolean().withDefault(const Constant(false))();

  /// Optional JSON metadata (schema v23): a snippet description and per-variable
  /// descriptions. Shape: `{"description": "…", "variables": {"NAME": "…"}}`.
  /// Nullable - untouched snippets store NULL. Variable *defaults* live in the
  /// command (`${VAR:-default}`), not here. Decoded via `parseSnippetMetadata`.
  TextColumn get metadata => text().nullable()();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}
