// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'networks_dao.dart';

// ignore_for_file: type=lint
mixin _$NetworksDaoMixin on DatabaseAccessor<AppDatabase> {
  $NetworksTable get networks => attachedDatabase.networks;
  $HostNetworkOverridesTable get hostNetworkOverrides =>
      attachedDatabase.hostNetworkOverrides;
  NetworksDaoManager get managers => NetworksDaoManager(this);
}

class NetworksDaoManager {
  final _$NetworksDaoMixin _db;
  NetworksDaoManager(this._db);
  $$NetworksTableTableManager get networks =>
      $$NetworksTableTableManager(_db.attachedDatabase, _db.networks);
  $$HostNetworkOverridesTableTableManager get hostNetworkOverrides =>
      $$HostNetworkOverridesTableTableManager(
        _db.attachedDatabase,
        _db.hostNetworkOverrides,
      );
}
