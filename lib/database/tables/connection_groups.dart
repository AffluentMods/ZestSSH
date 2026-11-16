import 'package:drift/drift.dart';

/// Groups (folders) for organising connections.
class ConnectionGroups extends Table {
  TextColumn get id => text()();
  TextColumn get name => text().withLength(min: 1, max: 255)();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  BoolColumn get isExpanded => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt => dateTime()();

  /// Last-modified time - bumped on every edit; drives cloud-sync tombstone
  /// "newest wins" conflict resolution. Nullable: pre-v29 rows are backfilled
  /// to createdAt in the migration; a row never edited on v29+ stays null
  /// (treated as delete-wins).
  DateTimeColumn get updatedAt => dateTime().nullable()();

  /// User-picked accent color - an index into AppColors.v3GroupColors.
  /// Null = no explicit choice; the UI falls back to the legacy
  /// name-hash-derived color, so pre-existing groups keep looking
  /// exactly the way they always did until the user picks one.
  IntColumn get colorIndex => integer().nullable()();

  /// Optional custom accent colour (ARGB int). Overrides [colorIndex] when set;
  /// NULL = use the index / name-hash fallback. Additive + nullable.
  IntColumn get colorValue => integer().nullable()();

  /// User-picked folder icon - the codePoint of a const [IconData] from
  /// `folder_icon_catalog.dart`. Null = no explicit choice; the UI falls
  /// back to the default folder glyph (or a name-derived default), so
  /// pre-existing groups keep looking the way they always did until the
  /// user picks one. Stored as a codePoint (not raw IconData) so the
  /// release icon tree-shaker stays happy - see folder_icon_catalog.dart.
  IntColumn get iconCodePoint => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
