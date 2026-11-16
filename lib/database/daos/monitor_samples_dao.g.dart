// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'monitor_samples_dao.dart';

// ignore_for_file: type=lint
mixin _$MonitorSamplesDaoMixin on DatabaseAccessor<AppDatabase> {
  $MonitorSamplesTable get monitorSamples => attachedDatabase.monitorSamples;
  MonitorSamplesDaoManager get managers => MonitorSamplesDaoManager(this);
}

class MonitorSamplesDaoManager {
  final _$MonitorSamplesDaoMixin _db;
  MonitorSamplesDaoManager(this._db);
  $$MonitorSamplesTableTableManager get monitorSamples =>
      $$MonitorSamplesTableTableManager(
        _db.attachedDatabase,
        _db.monitorSamples,
      );
}
