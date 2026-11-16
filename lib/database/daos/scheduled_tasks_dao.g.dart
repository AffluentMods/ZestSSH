// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'scheduled_tasks_dao.dart';

// ignore_for_file: type=lint
mixin _$ScheduledTasksDaoMixin on DatabaseAccessor<AppDatabase> {
  $ScheduledTasksTable get scheduledTasks => attachedDatabase.scheduledTasks;
  ScheduledTasksDaoManager get managers => ScheduledTasksDaoManager(this);
}

class ScheduledTasksDaoManager {
  final _$ScheduledTasksDaoMixin _db;
  ScheduledTasksDaoManager(this._db);
  $$ScheduledTasksTableTableManager get scheduledTasks =>
      $$ScheduledTasksTableTableManager(
        _db.attachedDatabase,
        _db.scheduledTasks,
      );
}
