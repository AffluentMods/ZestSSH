// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'connection_groups_dao.dart';

// ignore_for_file: type=lint
mixin _$ConnectionGroupsDaoMixin on DatabaseAccessor<AppDatabase> {
  $ConnectionGroupsTable get connectionGroups =>
      attachedDatabase.connectionGroups;
  ConnectionGroupsDaoManager get managers => ConnectionGroupsDaoManager(this);
}

class ConnectionGroupsDaoManager {
  final _$ConnectionGroupsDaoMixin _db;
  ConnectionGroupsDaoManager(this._db);
  $$ConnectionGroupsTableTableManager get connectionGroups =>
      $$ConnectionGroupsTableTableManager(
        _db.attachedDatabase,
        _db.connectionGroups,
      );
}
