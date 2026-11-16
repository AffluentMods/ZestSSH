import 'package:drift/drift.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/tables/snippets.dart';

part 'snippets_dao.g.dart';

@DriftAccessor(tables: [Snippets])
class SnippetsDao extends DatabaseAccessor<AppDatabase>
    with _$SnippetsDaoMixin {
  SnippetsDao(super.db);

  /// Watch all snippets ordered by category then label.
  Stream<List<Snippet>> watchAll() {
    return (select(snippets)..orderBy([
          (t) => OrderingTerm(expression: t.category),
          (t) => OrderingTerm(expression: t.sortOrder),
          (t) => OrderingTerm(expression: t.label),
        ]))
        .watch();
  }

  /// Get all snippets.
  Future<List<Snippet>> getAll() => select(snippets).get();

  /// Get a snippet by ID.
  Future<Snippet?> getById(String id) {
    return (select(snippets)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Watch snippets filtered by category.
  Stream<List<Snippet>> watchByCategory(String category) {
    return (select(snippets)
          ..where((t) => t.category.equals(category))
          ..orderBy([
            (t) => OrderingTerm(expression: t.sortOrder),
            (t) => OrderingTerm(expression: t.label),
          ]))
        .watch();
  }

  /// Get distinct categories using a SELECT DISTINCT query.
  Future<List<String>> getCategories() async {
    final query = selectOnly(snippets, distinct: true)
      ..addColumns([snippets.category])
      ..where(snippets.category.isNotNull());
    final results = await query.get();
    return results.map((row) => row.read(snippets.category)!).toList()..sort();
  }

  Future<void> insertSnippet(SnippetsCompanion entry) {
    return into(snippets).insert(entry);
  }

  Future<void> updateSnippet(SnippetsCompanion entry) {
    return (update(
      snippets,
    )..where((t) => t.id.equals(entry.id.value))).write(entry);
  }

  Future<void> deleteSnippet(String id) => transaction(() async {
        // Delete-propagation tombstone so the snippet is removed on other
        // devices; in the delete's transaction, so a delete a team vault
        // refuses leaves none.
        await attachedDatabase.tombstonesDao.mark('snippets', id);
        await (delete(snippets)..where((t) => t.id.equals(id))).go();
      });

  /// Rewrite every snippet's [Snippets.category] from [oldCategory] to
  /// [newCategory] (used when a category is renamed). Bumps `updatedAt` so
  /// the change syncs. Runs within the caller's transaction for atomicity
  /// with the category-metadata move.
  Future<int> renameCategory(String oldCategory, String newCategory) {
    return (update(
      snippets,
    )..where((t) => t.category.equals(oldCategory))).write(
      SnippetsCompanion(
        category: Value(newCategory),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Clear the category on every snippet carrying [category] (they revert to
  /// Uncategorized). Bumps `updatedAt` so the change syncs. Used when a whole
  /// group is deleted - the commands are kept, only the grouping is removed.
  /// Runs within the caller's transaction for atomicity with the metadata drop.
  Future<int> clearCategory(String category) {
    return (update(snippets)..where((t) => t.category.equals(category))).write(
      SnippetsCompanion(
        category: const Value(null),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Delete all snippets.
  Future<void> deleteAll() => delete(snippets).go();
}
