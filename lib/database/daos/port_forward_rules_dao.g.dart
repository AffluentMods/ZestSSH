// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'port_forward_rules_dao.dart';

// ignore_for_file: type=lint
mixin _$PortForwardRulesDaoMixin on DatabaseAccessor<AppDatabase> {
  $IdentitiesTable get identities => attachedDatabase.identities;
  $ConnectionGroupsTable get connectionGroups =>
      attachedDatabase.connectionGroups;
  $SnippetsTable get snippets => attachedDatabase.snippets;
  $ConnectionsTable get connections => attachedDatabase.connections;
  $PortForwardRulesTable get portForwardRules =>
      attachedDatabase.portForwardRules;
  $PortForwardNetworkOverridesTable get portForwardNetworkOverrides =>
      attachedDatabase.portForwardNetworkOverrides;
  PortForwardRulesDaoManager get managers => PortForwardRulesDaoManager(this);
}

class PortForwardRulesDaoManager {
  final _$PortForwardRulesDaoMixin _db;
  PortForwardRulesDaoManager(this._db);
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
  $$PortForwardRulesTableTableManager get portForwardRules =>
      $$PortForwardRulesTableTableManager(
        _db.attachedDatabase,
        _db.portForwardRules,
      );
  $$PortForwardNetworkOverridesTableTableManager
  get portForwardNetworkOverrides =>
      $$PortForwardNetworkOverridesTableTableManager(
        _db.attachedDatabase,
        _db.portForwardNetworkOverrides,
      );
}
