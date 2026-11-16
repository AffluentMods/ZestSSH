import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync/dumb_store_sync_backend.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/services/sync_service.dart';

/// One in-memory object store (a WebDAV/S3-style "dumb" store).
class MemoryStore {
  Uint8List? bytes;
  String? etag;
  int counter = 0;
}

class MemoryStoreBackend extends DumbStoreSyncBackend {
  final MemoryStore store;
  MemoryStoreBackend(this.store);

  @override
  SyncBackendKind get kind => SyncBackendKind.webdav;

  @override
  String get displayName => 'Memory';

  @override
  Future<void> checkConnection() async {}

  @override
  Future<RawObject?> readObject() async =>
      store.bytes == null ? null : RawObject(store.bytes!, store.etag);

  @override
  Future<String?> writeObject(Uint8List bytes,
      {String? ifMatchEtag, bool ifAbsent = false}) async {
    if (ifAbsent && store.bytes != null) {
      throw const SyncConflictException(serverVersion: -1, expectedVersion: -1);
    }
    if (ifMatchEtag != null && ifMatchEtag != store.etag) {
      throw const SyncConflictException(serverVersion: -1, expectedVersion: -1);
    }
    store.bytes = Uint8List.fromList(bytes);
    store.counter++;
    store.etag = 'etag-${store.counter}';
    return store.etag;
  }

  @override
  Future<void> deleteObject() async {
    store.bytes = null;
    store.etag = null;
  }
}

SyncDataService memoryDataService(
        AppDatabase db, FlutterSecureStorage storage, SettingsService s) =>
    SyncDataService(
      database: db,
      connectionsDao: db.connectionsDao,
      identitiesDao: db.identitiesDao,
      groupsDao: db.connectionGroupsDao,
      knownHostsDao: db.knownHostsDao,
      snippetsDao: db.snippetsDao,
      snippetCategoriesDao: db.snippetCategoriesDao,
      portForwardRulesDao: db.portForwardRulesDao,
      networksDao: db.networksDao,
      connectionTagsDao: db.connectionTagsDao,
      secureStorage: storage,
      settingsService: s,
    );
