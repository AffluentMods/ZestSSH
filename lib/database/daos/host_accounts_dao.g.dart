// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'host_accounts_dao.dart';

// ignore_for_file: type=lint
mixin _$HostAccountsDaoMixin on DatabaseAccessor<AppDatabase> {
  $HostAccountsTable get hostAccounts => attachedDatabase.hostAccounts;
  $IdentitiesTable get identities => attachedDatabase.identities;
  $ConnectionGroupsTable get connectionGroups =>
      attachedDatabase.connectionGroups;
  $SnippetsTable get snippets => attachedDatabase.snippets;
  $ConnectionsTable get connections => attachedDatabase.connections;
  HostAccountsDaoManager get managers => HostAccountsDaoManager(this);
}

class HostAccountsDaoManager {
  final _$HostAccountsDaoMixin _db;
  HostAccountsDaoManager(this._db);
  $$HostAccountsTableTableManager get hostAccounts =>
      $$HostAccountsTableTableManager(_db.attachedDatabase, _db.hostAccounts);
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
