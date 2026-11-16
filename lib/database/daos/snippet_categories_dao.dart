import 'package:drift/drift.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/tables/snippet_categories.dart';

part 'snippet_categories_dao.g.dart';

/// DAO for the lazy per-category metadata rows (order / color / hidden).
///
/// Every write here is an UPSERT so the caller never has to know whether the
/// category already has a row - the first color/hidden/order change creates it.
@DriftAccessor(tables: [SnippetCategories])
class SnippetCategoriesDao extends DatabaseAccessor<AppDatabase>
    with _$SnippetCategoriesDaoMixin {
  SnippetCategoriesDao(super.db);

  /// Watch all metadata rows ordered by [SnippetCategories.sortOrder] then
  /// name. The UI merges these against the live snippet categories.
  Stream<List<SnippetCategory>> watchAll() {
    return (select(snippetCategories)
          ..orderBy([
            (t) => OrderingTerm(expression: t.sortOrder),
            (t) => OrderingTerm(expression: t.name),
          ]))
        .watch();
  }

  Future<List<SnippetCategory>> getAll() => select(snippetCategories).get();

  Future<SnippetCategory?> getByName(String name) {
    return (select(snippetCategories)..where((t) => t.name.equals(name)))
        .getSingleOrNull();
  }

  /// Upsert a full (or partial) metadata row. Absent companion fields keep
  /// their existing value on conflict and fall back to column defaults on
  /// insert.
  Future<void> upsert(SnippetCategoriesCompanion entry) {
    return into(snippetCategories).insertOnConflictUpdate(entry);
  }

  /// Persist a new category ordering: writes `sortOrder = index` for each
  /// name, creating lazy rows as needed. Only [sortOrder] is touched, so an
  /// existing color/hidden state is preserved.
  Future<void> updateOrder(List<String> orderedNames) async {
    await batch((b) {
      for (var i = 0; i < orderedNames.length; i++) {
        b.insert(
          snippetCategories,
          SnippetCategoriesCompanion(
            name: Value(orderedNames[i]),
            sortOrder: Value(i),
          ),
          onConflict: DoUpdate(
            (_) => SnippetCategoriesCompanion(sortOrder: Value(i)),
          ),
        );
      }
    });
  }

  /// Set (or clear, with null) the category's accent color. Upserts so an
  /// uncustomized category gets its row on first pick. A non-null [colorValue]
  /// (ARGB int) overrides the palette index with an arbitrary custom colour;
  /// index and value are alternatives, so both are always written.
  Future<void> setColor(String name, int? colorIndex, {int? colorValue}) {
    return into(snippetCategories).insertOnConflictUpdate(
      SnippetCategoriesCompanion(
        name: Value(name),
        colorIndex: Value(colorIndex),
        colorValue: Value(colorValue),
      ),
    );
  }

  /// Flip the hidden flag. Upserts so hiding an uncustomized category works.
  Future<void> setHidden(String name, bool hidden) {
    return into(snippetCategories).insertOnConflictUpdate(
      SnippetCategoriesCompanion(
        name: Value(name),
        hidden: Value(hidden),
      ),
    );
  }

  /// Move the metadata row from [oldName] to [newName], preserving its
  /// order/color/hidden. A no-op when [oldName] has no lazy row yet.
  ///
  /// NOT atomic on its own - the higher-level rename runs this together with
  /// the bulk snippet-category rewrite inside one transaction.
  Future<void> rename(String oldName, String newName) async {
    final existing = await getByName(oldName);
    if (existing == null) return;
    // Clear any pre-existing row at the target so the PK move can't collide
    // (renaming onto an existing category merges into it).
    await (delete(snippetCategories)..where((t) => t.name.equals(newName)))
        .go();
    await (update(snippetCategories)..where((t) => t.name.equals(oldName)))
        .write(SnippetCategoriesCompanion(name: Value(newName)));
  }

  /// Delete a category's metadata row (its snippets keep their category
  /// string and simply revert to default styling).
  ///
  /// Named `deleteByName` rather than `delete` so it doesn't shadow the
  /// inherited `delete<T>(table)` builder used by [rename] above.
  Future<void> deleteByName(String name) => transaction(() async {
        // Delete-propagation tombstone (entityId = the category name PK) so
        // the category metadata is removed on other devices; in the delete's
        // transaction, so a delete a team vault refuses leaves none.
        await attachedDatabase.tombstonesDao.mark('snippet_categories', name);
        await (delete(snippetCategories)..where((t) => t.name.equals(name))).go();
      });
}
