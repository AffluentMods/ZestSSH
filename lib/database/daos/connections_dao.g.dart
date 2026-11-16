// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'connections_dao.dart';

// ignore_for_file: type=lint
mixin _$ConnectionsDaoMixin on DatabaseAccessor<AppDatabase> {
  $IdentitiesTable get identities => attachedDatabase.identities;
  $ConnectionGroupsTable get connectionGroups =>
      attachedDatabase.connectionGroups;
  $SnippetsTable get snippets => attachedDatabase.snippets;
  $ConnectionsTable get connections => attachedDatabase.connections;
  ConnectionsDaoManager get managers => ConnectionsDaoManager(this);
}

class ConnectionsDaoManager {
  final _$ConnectionsDaoMixin _db;
  ConnectionsDaoManager(this._db);
  $$IdentitiesTableTableManager get identities =>
      $$IdentitiesTableTableManager(_db.attachedDatabase, _db.identities);
  $$ConnectionGroupsTableTableManager get connectionGroups =>
      $$ConnectionGroupsTableTableManager(
        _db.attachedDatabase,
        _db.connectionGroups,
      );
  $$SnippetsTableTableManager get snippets =>
      $$SnippetsTableTableManager(_db.attachedDatabase, _db.snippets);
  $$ConnectionsTableTableManager get connections =>
      $$ConnectionsTableTableManager(_db.attachedDatabase, _db.connections);
}
