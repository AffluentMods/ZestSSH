// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'snippet_categories_dao.dart';

// ignore_for_file: type=lint
mixin _$SnippetCategoriesDaoMixin on DatabaseAccessor<AppDatabase> {
  $SnippetCategoriesTable get snippetCategories =>
      attachedDatabase.snippetCategories;
  SnippetCategoriesDaoManager get managers => SnippetCategoriesDaoManager(this);
}

class SnippetCategoriesDaoManager {
  final _$SnippetCategoriesDaoMixin _db;
  SnippetCategoriesDaoManager(this._db);
  $$SnippetCategoriesTableTableManager get snippetCategories =>
      $$SnippetCategoriesTableTableManager(
        _db.attachedDatabase,
        _db.snippetCategories,
      );
}
