// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'identities_dao.dart';

// ignore_for_file: type=lint
mixin _$IdentitiesDaoMixin on DatabaseAccessor<AppDatabase> {
  $IdentitiesTable get identities => attachedDatabase.identities;
  IdentitiesDaoManager get managers => IdentitiesDaoManager(this);
}

class IdentitiesDaoManager {
  final _$IdentitiesDaoMixin _db;
  IdentitiesDaoManager(this._db);
  $$IdentitiesTableTableManager get identities =>
      $$IdentitiesTableTableManager(_db.attachedDatabase, _db.identities);
}
