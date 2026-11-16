// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'terminal_triggers_dao.dart';

// ignore_for_file: type=lint
mixin _$TerminalTriggersDaoMixin on DatabaseAccessor<AppDatabase> {
  $TerminalTriggersTable get terminalTriggers =>
      attachedDatabase.terminalTriggers;
  TerminalTriggersDaoManager get managers => TerminalTriggersDaoManager(this);
}

class TerminalTriggersDaoManager {
  final _$TerminalTriggersDaoMixin _db;
  TerminalTriggersDaoManager(this._db);
  $$TerminalTriggersTableTableManager get terminalTriggers =>
      $$TerminalTriggersTableTableManager(
        _db.attachedDatabase,
        _db.terminalTriggers,
      );
}
