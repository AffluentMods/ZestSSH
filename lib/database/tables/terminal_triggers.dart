import 'package:drift/drift.dart';

/// User-defined "trigger / highlight rules" (v37): a regular expression that
/// ZestSSH watches for in a session's output. On a match a trigger can raise a
/// notification and/or highlight the matching text in the terminal.
///
/// A synced property of the user's config (mirrors [Snippets] /
/// [PortForwardRules]): rides the existing cloud sync with newest-wins +
/// tombstones. `updatedAt` is nullable and auto-bumped by the universal trigger
/// registered in `AppDatabase._updatedAtTriggerTables`.
class TerminalTriggers extends Table {
  TextColumn get id => text()();
  TextColumn get name => text().withLength(min: 1, max: 255)();

  /// The pattern to watch for. A Dart-flavoured regular expression, matched
  /// against ANSI-stripped output lines.
  TextColumn get pattern => text().withLength(min: 1, max: 2048)();

  BoolColumn get caseSensitive =>
      boolean().withDefault(const Constant(false))();

  /// Raise an alert in the notification center when the pattern matches.
  BoolColumn get notify => boolean().withDefault(const Constant(true))();

  /// Colour the matching text in the terminal when the pattern matches.
  BoolColumn get highlight => boolean().withDefault(const Constant(false))();

  /// Optional custom highlight colour (ARGB int). NULL = the feature's default
  /// (brand amber). Only meaningful when [highlight] is true.
  IntColumn get highlightColor => integer().nullable()();

  /// Play the alert sound with the notification (only meaningful with [notify]).
  BoolColumn get playSound => boolean().withDefault(const Constant(false))();

  /// The host this rule is scoped to, or NULL for "every host". Stored as a
  /// plain connection id (no FK): if the host is later deleted the rule simply
  /// stops matching, which is harmless.
  TextColumn get connectionId => text().nullable()();

  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt => dateTime()();

  /// Nullable + auto-bumped by the universal newest-wins trigger; drives cloud
  /// sync. Restore preserves the incoming value untouched.
  DateTimeColumn get updatedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
