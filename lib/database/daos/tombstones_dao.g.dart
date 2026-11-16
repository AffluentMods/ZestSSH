// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'tombstones_dao.dart';

// ignore_for_file: type=lint
mixin _$TombstonesDaoMixin on DatabaseAccessor<AppDatabase> {
  $TombstonesTable get tombstones => attachedDatabase.tombstones;
  TombstonesDaoManager get managers => TombstonesDaoManager(this);
}

class TombstonesDaoManager {
  final _$TombstonesDaoMixin _db;
  TombstonesDaoManager(this._db);
  $$TombstonesTableTableManager get tombstones =>
      $$TombstonesTableTableManager(_db.attachedDatabase, _db.tombstones);
}
