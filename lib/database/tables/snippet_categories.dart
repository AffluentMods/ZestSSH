import 'package:drift/drift.dart';

/// Persisted per-category ("group") metadata for snippets: display order,
/// accent color, and hidden state.
///
/// The category itself is still a free-text string on [Snippets.category].
/// This table only holds the *metadata* for a category so that ordering,
/// color, and visibility PERSIST across restarts and SYNC between devices.
///
/// A row here is LAZY: it only exists once the user customizes a category
/// (picks a color, hides it, or drags it into a new order). Categories with
/// no row fall back to defaults - alphabetical order, no accent color,
/// visible. The first customization upserts the row.
@DataClassName('SnippetCategory')
class SnippetCategories extends Table {
  /// Category name - matches [Snippets.category] exactly. Primary key.
  TextColumn get name => text().withLength(min: 1, max: 128)();

  /// Display order in the grouped list. Lower values render first.
  /// Categories WITHOUT a row sort after all rowed categories,
  /// alphabetically.
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// User-picked accent color - an index into `AppColors.v3GroupColors`.
  /// Null = no explicit choice; the UI falls back to a neutral default,
  /// mirroring the connection-group color convention.
  IntColumn get colorIndex => integer().nullable()();

  /// Optional custom accent colour (ARGB int). Overrides [colorIndex] when set;
  /// NULL = use the index / neutral default. Additive + nullable.
  IntColumn get colorValue => integer().nullable()();

  /// When true, the category's snippet cards are collapsed out of the main
  /// list (recoverable via a "Show hidden" affordance). Persisted + synced.
  BoolColumn get hidden => boolean().withDefault(const Constant(false))();

  /// Last-modified time - bumped on every edit; drives cloud-sync tombstone
  /// "newest wins". Nullable (this table has no createdAt to backfill from; a
  /// row never edited on v29+ stays null = delete-wins).
  DateTimeColumn get updatedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {name};
}
