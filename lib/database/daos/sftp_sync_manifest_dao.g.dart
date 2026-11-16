// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sftp_sync_manifest_dao.dart';

// ignore_for_file: type=lint
mixin _$SftpSyncManifestDaoMixin on DatabaseAccessor<AppDatabase> {
  $SftpSyncManifestTable get sftpSyncManifest =>
      attachedDatabase.sftpSyncManifest;
  SftpSyncManifestDaoManager get managers => SftpSyncManifestDaoManager(this);
}

class SftpSyncManifestDaoManager {
  final _$SftpSyncManifestDaoMixin _db;
  SftpSyncManifestDaoManager(this._db);
  $$SftpSyncManifestTableTableManager get sftpSyncManifest =>
      $$SftpSyncManifestTableTableManager(
        _db.attachedDatabase,
        _db.sftpSyncManifest,
      );
}
