// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'command_history_dao.dart';

// ignore_for_file: type=lint
mixin _$CommandHistoryDaoMixin on DatabaseAccessor<AppDatabase> {
  $CommandHistoryTable get commandHistory => attachedDatabase.commandHistory;
  CommandHistoryDaoManager get managers => CommandHistoryDaoManager(this);
}

class CommandHistoryDaoManager {
  final _$CommandHistoryDaoMixin _db;
  CommandHistoryDaoManager(this._db);
  $$CommandHistoryTableTableManager get commandHistory =>
      $$CommandHistoryTableTableManager(
        _db.attachedDatabase,
        _db.commandHistory,
      );
}
