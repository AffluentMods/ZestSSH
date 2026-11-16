// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'automation_history_dao.dart';

// ignore_for_file: type=lint
mixin _$AutomationHistoryDaoMixin on DatabaseAccessor<AppDatabase> {
  $AutomationHistoryTable get automationHistory =>
      attachedDatabase.automationHistory;
  AutomationHistoryDaoManager get managers => AutomationHistoryDaoManager(this);
}

class AutomationHistoryDaoManager {
  final _$AutomationHistoryDaoMixin _db;
  AutomationHistoryDaoManager(this._db);
  $$AutomationHistoryTableTableManager get automationHistory =>
      $$AutomationHistoryTableTableManager(
        _db.attachedDatabase,
        _db.automationHistory,
      );
}
