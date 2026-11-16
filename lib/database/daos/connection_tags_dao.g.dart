// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'connection_tags_dao.dart';

// ignore_for_file: type=lint
mixin _$ConnectionTagsDaoMixin on DatabaseAccessor<AppDatabase> {
  $ConnectionTagsTable get connectionTags => attachedDatabase.connectionTags;
  ConnectionTagsDaoManager get managers => ConnectionTagsDaoManager(this);
}

class ConnectionTagsDaoManager {
  final _$ConnectionTagsDaoMixin _db;
  ConnectionTagsDaoManager(this._db);
  $$ConnectionTagsTableTableManager get connectionTags =>
      $$ConnectionTagsTableTableManager(
        _db.attachedDatabase,
        _db.connectionTags,
      );
}
