import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

/// Guards cross-device connection-TAG sync (blob schema_version 13). Tags were
/// previously absent from the payload, so they never propagated. Invariants:
/// (1) tags added on device A appear on device B; (2) a removal propagates;
/// (3) the gather -> restore -> gather round-trip is byte-stable (no echo push);
/// (4) tags for a connection that does NOT exist locally are ignored (no orphan
/// rows / resurrected tags for a tombstoned host).
SyncDataService _service(
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

Future<void> _seedConnection(AppDatabase db, String id) {
  return db.connectionsDao.insertConnection(
    ConnectionsCompanion(
      id: Value(id),
      label: Value('host-$id'),
      host: Value('$id.example.com'),
      port: const Value(22),
      protocol: const Value('ssh'),
      createdAt: Value(DateTime.utc(2026)),
      updatedAt: Value(DateTime.utc(2026)),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  const storage = FlutterSecureStorage();
  final key = List<int>.filled(32, 7);

  late AppDatabase src;
  late AppDatabase dst;

  setUp(() {
    src = AppDatabase.forTesting(NativeDatabase.memory());
    dst = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() async {
    await src.close();
    await dst.close();
  });

  Future<SettingsService> settings() async {
    SharedPreferences.setMockInitialValues(const {});
    return SettingsService(await SharedPreferences.getInstance());
  }

  test('tags added on device A appear on device B', () async {
    await _seedConnection(src, 'c1');
    await src.connectionTagsDao.addTag('c1', 'Prod'); // normalizes to 'prod'
    await src.connectionTagsDao.addTag('c1', 'db');

    final s = await settings();
    final blob = await _service(src, storage, s).gatherAll();
    // What this build writes (21 since the icon colour of a host).
    expect(blob['schema_version'], 22);
    expect(blob['connection_tags'], {
      'c1': ['db', 'prod'], // alphabetical, normalized
    });

    await _service(dst, storage, await settings()).restoreAll(blob);

    // The connection itself travels, and its tags land on the other device.
    expect((await dst.connectionsDao.getById('c1')), isNotNull);
    expect(await dst.connectionTagsDao.getTagsForConnection('c1'),
        ['db', 'prod']);
  });

  test('host-card icon override syncs; an oversized custom icon is dropped',
      () async {
    await src.connectionsDao.insertConnection(ConnectionsCompanion(
      id: const Value('c-icon'),
      label: const Value('hypervisor-a'),
      host: const Value('hypervisor-a.example.com'),
      port: const Value(22),
      protocol: const Value('ssh'),
      iconId: const Value('proxmox'),
      customIcon: const Value('AAAApng=='),
      createdAt: Value(DateTime.utc(2026)),
      updatedAt: Value(DateTime.utc(2026)),
    ));
    // A hostile blob: a custom icon far over the cap.
    await src.connectionsDao.insertConnection(ConnectionsCompanion(
      id: const Value('c-huge'),
      label: const Value('Huge'),
      host: const Value('huge.example.com'),
      port: const Value(22),
      protocol: const Value('ssh'),
      customIcon: Value('x' * (200 * 1024)),
      createdAt: Value(DateTime.utc(2026)),
      updatedAt: Value(DateTime.utc(2026)),
    ));

    final blob = await _service(src, storage, await settings()).gatherAll();
    await _service(dst, storage, await settings()).restoreAll(blob);

    final good = await dst.connectionsDao.getById('c-icon');
    expect(good!.iconId, 'proxmox');
    expect(good.customIcon, 'AAAApng==');

    // The oversized custom icon is refused on restore; the row still lands.
    final huge = await dst.connectionsDao.getById('c-huge');
    expect(huge, isNotNull);
    expect(huge!.customIcon, isNull);
  });

  test('round-trip is byte-stable: connection_tags + fingerprint match',
      () async {
    await _seedConnection(src, 'c1');
    await src.connectionTagsDao.addTag('c1', 'prod');
    await src.connectionTagsDao.addTag('c1', 'web');

    final blobA = await _service(src, storage, await settings()).gatherAll();
    await _service(dst, storage, await settings()).restoreAll(blobA);
    final blobB = await _service(dst, storage, await settings()).gatherAll();

    expect(blobB['connection_tags'], equals(blobA['connection_tags']));
    expect(
      SyncDataService.contentFingerprint(blobB, key),
      SyncDataService.contentFingerprint(blobA, key),
    );
  });

  test('a removed tag propagates (replace-per-connection)', () async {
    await _seedConnection(src, 'c1');
    await src.connectionTagsDao.addTag('c1', 'prod');
    await src.connectionTagsDao.addTag('c1', 'db');

    // First sync: both have [db, prod].
    await _service(dst, storage, await settings())
        .restoreAll(await _service(src, storage, await settings()).gatherAll());
    expect(await dst.connectionTagsDao.getTagsForConnection('c1'),
        ['db', 'prod']);

    // Remove one on src, sync again: dst reflects the removal.
    await src.connectionTagsDao.removeTag('c1', 'db');
    await _service(dst, storage, await settings())
        .restoreAll(await _service(src, storage, await settings()).gatherAll());
    expect(await dst.connectionTagsDao.getTagsForConnection('c1'), ['prod']);
  });

  test('tags for a connection that does not exist locally are ignored',
      () async {
    // A blob referencing a host that isn't in (and won't be restored to) dst.
    final blob = {
      'schema_version': 13,
      'connection_tags': {
        'ghost': ['prod'],
      },
    };
    // Must not throw and must not create an orphan tag row.
    await _service(dst, storage, await settings()).restoreAll(blob);
    expect(await dst.connectionTagsDao.getTagsForConnection('ghost'), isEmpty);
  });

  test('blob is byte-stable regardless of local tag insert order', () async {
    // Device A tags c1 then c2; device B (same connections) tags c2 then c1.
    // With the outer keys sorted, both must emit an IDENTICAL connection_tags
    // map + fingerprint, so B's pull doesn't trigger a redundant echo push.
    await _seedConnection(src, 'c1');
    await _seedConnection(src, 'c2');
    await src.connectionTagsDao.addTag('c1', 'prod');
    await src.connectionTagsDao.addTag('c2', 'dev');

    await _seedConnection(dst, 'c1');
    await _seedConnection(dst, 'c2');
    await dst.connectionTagsDao.addTag('c2', 'dev');
    await dst.connectionTagsDao.addTag('c1', 'prod');

    final a = await _service(src, storage, await settings()).gatherAll();
    final b = await _service(dst, storage, await settings()).gatherAll();
    expect(jsonEncode(a['connection_tags']), jsonEncode(b['connection_tags']));
    expect(
      SyncDataService.contentFingerprint(a, key),
      SyncDataService.contentFingerprint(b, key),
    );
  });

  test('orphan tags (connection gone) are swept on restore', () async {
    // A tag row for a connection that does not exist (e.g. left behind after a
    // tombstone deletion on another device). Any restore runs the orphan sweep.
    await dst.connectionTagsDao.addTag('ghost', 'prod');
    expect(await dst.connectionTagsDao.getTagsForConnection('ghost'), ['prod']);

    await _service(dst, storage, await settings())
        .restoreAll({'schema_version': 13});

    expect(await dst.connectionTagsDao.getTagsForConnection('ghost'), isEmpty);
  });
}
