import 'package:drift/drift.dart';

/// Lightweight, free-form labels users can attach to connections.
///
/// Unlike groups (a host belongs to at most one), a host can have many
/// tags. Tag strings are normalised on write (lowercase, trimmed, internal
/// whitespace collapsed) so "Prod" and "prod " collapse to the same tag -
/// keeps autocomplete tight and avoids visual duplicates in the filter
/// strip.
///
/// References [Connections.id] without an `ON DELETE CASCADE` so the DAO
/// can be unit-tested in isolation. Cleanup happens explicitly when a
/// connection is deleted, mirroring how snippets and connect-via refs
/// are handled elsewhere in the codebase.
@TableIndex(name: 'idx_connection_tags_tag', columns: {#tag})
@TableIndex(name: 'idx_connection_tags_conn', columns: {#connectionId})
class ConnectionTags extends Table {
  /// Reference to `connections.id`. Cleaned up explicitly by the
  /// connection delete path (no FK cascade).
  TextColumn get connectionId => text()();

  /// The tag value, lowercased and trimmed. Length capped at 32 to keep
  /// chip rendering predictable on cards and the filter strip.
  TextColumn get tag => text().withLength(min: 1, max: 32)();

  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {connectionId, tag};
}
