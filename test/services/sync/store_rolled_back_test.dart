// Real Argon2id key derivation (the weakest profile deriveKey accepts),
// done once for the file. Allow for a machine busy with the whole suite.
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_service.dart';

import '../../helpers/memory_store_backend.dart';

/// A sync store that comes back older than the devices that sync to it (3.0:
/// sync is fixed for a store that comes
/// back older than a device).
///
/// That is what a restore from a backup is, for ZestSSH Cloud as for a
/// store of somebody's own: the store holds version 40 again, and the devices
/// are at 45. A device only ever fetched from a store that was AHEAD of it,
/// and sent its changes on top of the version it believed the store to have.
/// So a store that had gone back was never fetched from, what it had lost was
/// never sent again unless something changed on the device, and when
/// something did change the store refused it ("another device wrote first"),
/// for ever. And once the store's count had caught up with a device's, a
/// device took a store that held something else under the same number for
/// its own.
///
/// Now a store that is not where the device left it (behind it, or at its
/// number with another content) is fetched from and merged like any other
/// device's work, and what the device holds that the store does not is sent.

Future<void> _addHost(AppDatabase db, String id) =>
    db.connectionsDao.insertConnection(ConnectionsCompanion(
      id: Value(id),
      label: Value('host-$id'),
      host: Value('$id.example.com'),
      port: const Value(22),
      protocol: const Value('ssh'),
      createdAt: Value(DateTime.utc(2026, 10, 8)),
      updatedAt: Value(DateTime.utc(2026, 10, 8)),
    ));

/// One device of the account: its own database, its own settings, its own
/// sync service, and its own way to the one store.
class _Device {
  _Device(this.name, this.db, this.settings, this.backend, this.sync);

  final String name;
  final AppDatabase db;
  final SettingsService settings;
  final MemoryStoreBackend backend;
  final AutoSyncService sync;

  Future<Set<String>> hosts() async => (await db.connectionsDao.getAll()).map((c) => c.id).toSet();

  /// Adds [id] here and marks the device as having something to send, as
  /// the app does when a synced table is written.
  Future<void> add(String id) async {
    await _addHost(db, id);
    await settings.setSyncDirty(true);
  }

  /// One sync as the app runs it by itself (on a change, on its timer, when
  /// it comes to the front): what stopped it, as the screens show it, or null.
  Future<String?> syncNow() async {
    await sync.triggerSync();
    return sync.activity.value.failure;
  }

  int get version => settings.syncServerVersion;
}

/// What the store held at some moment: a backup of it.
class _Backup {
  _Backup(MemoryStore store)
      : bytes = store.bytes == null ? null : Uint8List.fromList(store.bytes!),
        etag = store.etag;

  final Uint8List? bytes;
  final String? etag;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const fast = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
  const storage = FlutterSecureStorage();

  late MemoryStore shared;
  late SecretKey dek;
  late SecretKey mek;
  late Uint8List salt;
  late Uint8List verHash;
  final devices = <_Device>[];

  setUpAll(() async {
    salt = SyncService.generateSalt();
    dek = SyncService.generateDek();
    mek = await SyncService.deriveKey('correct-password', salt, params: fast);
    verHash = await SyncService.computeVerificationHash(mek);
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    shared = MemoryStore();
    devices.clear();
    await storage.write(key: 'sync_salt', value: base64Encode(salt));
  });

  tearDown(() async {
    for (final d in devices) {
      d.sync.dispose();
      await d.db.close();
    }
  });

  /// A device with settings of its own (each its own instance, with its own
  /// values in memory, as on a machine of its own).
  Future<_Device> device(String name) async {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues(const {});
    final settings = SettingsService(await SharedPreferences.getInstance());
    await settings.setSyncMode('auto');
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final backend = MemoryStoreBackend(shared);
    final sync = AutoSyncService(
      syncDataService: memoryDataService(db, storage, settings),
      settingsService: settings,
      secureStorage: storage,
      resolveBackend: () => backend,
    );
    await sync.storeSyncCredentials(dek, verHash, argon2Params: fast);
    final d = _Device(name, db, settings, backend, sync);
    devices.add(d);
    return d;
  }

  Future<Set<String>> storeHosts() async {
    final pulled = await MemoryStoreBackend(shared).pull();
    final data = await SyncService.decrypt(pulled.encryptedData, dek);
    return (data['connections'] as List).map((c) => (c as Map)['id'] as String).toSet();
  }

  Future<int> storeVersion() async => (await MemoryStoreBackend(shared).getStatus()).version;

  /// What the store holds as [id]'s label.
  Future<String> storeLabel(String id) async {
    final pulled = await MemoryStoreBackend(shared).pull();
    final data = await SyncService.decrypt(pulled.encryptedData, dek);
    return ((data['connections'] as List).cast<Map>().singleWhere((c) => c['id'] == id))['label'] as String;
  }

  /// [id]'s label on [d].
  Future<String> label(_Device d, String id) async => (await d.db.connectionsDao.getById(id))!.label;

  /// [id] renamed on [d] at [at], and [d] marked as having something to send.
  Future<void> rename(_Device d, String id, String to, DateTime at) async {
    await (d.db.update(d.db.connections)..where((c) => c.id.equals(id)))
        .write(ConnectionsCompanion(label: Value(to), updatedAt: Value(at)));
    await d.settings.setSyncDirty(true);
  }

  /// What the app's log says, from here to the end of the test, of a store
  /// that is not where a device left it.
  List<String> wentBackLog() {
    final said = <String>[];
    final level = Logger.root.level;
    Logger.root.level = Level.ALL;
    final listening = Logger.root.onRecord.listen((record) {
      if (record.message.contains('not where this device left it')) said.add('${record.level.name}: ${record.message}');
    });
    addTearDown(() {
      Logger.root.level = level;
      return listening.cancel();
    });
    return said;
  }

  /// The store as a backup of it gives it back: what it held then, under a
  /// tag of its own (a restored object is not the object that was there).
  void restore(_Backup backup) {
    shared
      ..bytes = backup.bytes == null ? null : Uint8List.fromList(backup.bytes!)
      ..counter += 100
      ..etag = 'restored-${shared.counter}';
  }

  /// The account set up by [first], which holds host a1 and has synced it.
  Future<void> setUpAccount(_Device first) async {
    await _addHost(first.db, 'a1');
    final v1 = await first.backend.push(
      data: await memoryDataService(first.db, storage, first.settings).gatherAll(),
      dek: dek,
      salt: salt,
      verificationHash: verHash,
      wrappedDekPassword: await SyncService.wrapDek(dek, mek),
      createOnly: true,
      argon2Params: fast,
    );
    await first.settings.setSyncServerVersion(v1.version);
    await first.settings.setLastSyncTime(DateTime.now());
    expect(await first.syncNow(), isNull);
  }

  /// Device A with a1, a2 and a3 synced one after the other (the store at
  /// version 3), and a backup taken when the store held a1 alone.
  Future<(_Device, _Backup)> threeVersions() async {
    final a = await device('A');
    await setUpAccount(a);
    final backup = _Backup(shared);
    expect(await storeVersion(), 1);
    await a.add('a2');
    expect(await a.syncNow(), isNull);
    await a.add('a3');
    expect(await a.syncNow(), isNull);
    expect(await storeVersion(), 3);
    expect(a.version, 3);
    expect(await storeHosts(), {'a1', 'a2', 'a3'});
    return (a, backup);
  }

  group('a store restored from a backup, behind a device', () {
    test('gets back what it lost at the next sync, with nothing changed on the device', () async {
      final (a, backup) = await threeVersions();
      final log = wentBackLog();
      restore(backup);
      expect(await storeHosts(), {'a1'});

      expect(await a.syncNow(), isNull);
      expect(await storeHosts(), {'a1', 'a2', 'a3'}, reason: 'what the store lost is sent again');
      expect(log, hasLength(1), reason: 'said once, in the log, for whoever looks into it later');
      expect(log.single, startsWith('WARNING: '));
      expect(log.single, contains('store v1, this device v3'));
      // The next sync finds the store where the device left it.
      expect(await a.syncNow(), isNull);
      expect(log, hasLength(1));
      expect(await a.hosts(), {'a1', 'a2', 'a3'});
      expect(a.version, await storeVersion(), reason: 'and the device counts as the store counts');
      expect(a.settings.syncDirty, isFalse);
    });

    test('takes a change made on the device afterwards: the device is not left refused for ever', () async {
      final (a, backup) = await threeVersions();
      restore(backup);
      await a.add('a4');

      expect(await a.syncNow(), isNull, reason: 'it was "another device wrote first", at every try');
      expect(await storeHosts(), {'a1', 'a2', 'a3', 'a4'});
      expect(a.version, await storeVersion());
      // And it goes on from there like any other day.
      await a.add('a5');
      expect(await a.syncNow(), isNull);
      expect(await storeHosts(), {'a1', 'a2', 'a3', 'a4', 'a5'});
    });

    test('a second device that was as far ahead falls in line without writing anything', () async {
      final (a, backup) = await threeVersions();
      final b = await device('B');
      expect(await b.syncNow(), isNull);
      expect(await b.hosts(), {'a1', 'a2', 'a3'});
      expect(b.version, 3);

      restore(backup);
      expect(await a.syncNow(), isNull);
      final after = await storeVersion();
      final written = shared.counter;

      expect(await b.syncNow(), isNull);
      expect(await b.hosts(), {'a1', 'a2', 'a3'});
      expect(b.version, after);
      expect(shared.counter, written, reason: 'the store already holds all of it: nothing is written again');
      expect(b.settings.syncDirty, isFalse);
    });

    test('what another device added to the restored store is kept, and merged with what the store had lost', () async {
      final (a, backup) = await threeVersions();
      // A device that had not synced since the backup was taken.
      final c = await device('C');
      restore(backup);
      expect(await c.syncNow(), isNull);
      expect(await c.hosts(), {'a1'});
      await c.add('c1');
      expect(await c.syncNow(), isNull);
      expect(await storeHosts(), {'a1', 'c1'});
      expect(await storeVersion(), 2, reason: 'the store counts on from where the backup was');

      expect(await a.syncNow(), isNull);
      expect(await a.hosts(), {'a1', 'a2', 'a3', 'c1'});
      expect(await storeHosts(), {'a1', 'a2', 'a3', 'c1'});
      // And the other device gets it all at its next sync.
      expect(await c.syncNow(), isNull);
      expect(await c.hosts(), {'a1', 'a2', 'a3', 'c1'});
    });

    test('a host deleted on the device before the restore stays deleted', () async {
      final (a, backup) = await threeVersions();
      // a1 is in the backup; it is deleted here and that is synced.
      await a.db.tombstonesDao.mark('connections', 'a1');
      await a.db.connectionsDao.deleteConnection('a1');
      await a.settings.setSyncDirty(true);
      expect(await a.syncNow(), isNull);
      expect(await storeHosts(), {'a2', 'a3'});

      restore(backup);
      expect(await storeHosts(), {'a1'});
      expect(await a.syncNow(), isNull);
      expect(await a.hosts(), {'a2', 'a3'}, reason: 'the backup does not bring back what was deleted since');
      expect(await storeHosts(), {'a2', 'a3'});
    });

    test('a host edited after the backup keeps its edit, here and in the store; one edited in it since is taken',
        () async {
      // Found in a security review: an item
      // unchanged on the device since its last sync took the store's copy,
      // which a restored store holds as it was at the backup, so every edit
      // made since went back on every device that synced.
      final (a, backup) = await threeVersions();
      await rename(a, 'a1', 'web-a1', DateTime.utc(2026, 10, 9));
      expect(await a.syncNow(), isNull);
      expect(await storeLabel('a1'), 'web-a1');

      restore(backup);
      expect(await storeLabel('a1'), 'host-a1');
      expect(await a.syncNow(), isNull);
      expect(await label(a, 'a1'), 'web-a1', reason: 'the copy the backup holds is older: no change of another device');
      expect(await storeLabel('a1'), 'web-a1', reason: 'and the store gets the later one back');

      // A device that had not synced since the backup edits a1 in the
      // restored store, later than the device did: that is a change, and is
      // taken.
      restore(backup);
      final c = await device('C');
      expect(await c.syncNow(), isNull);
      await rename(c, 'a1', 'db-a1', DateTime.utc(2026, 10, 10));
      expect(await c.syncNow(), isNull);
      expect(await a.syncNow(), isNull);
      expect(await label(a, 'a1'), 'db-a1');
      expect(await storeLabel('a1'), 'db-a1');
    });
  });

  group('a store restored from a backup whose count has caught up with a device', () {
    test('is not taken for the store the device left: both sides get what the other has', () async {
      final (a, backup) = await threeVersions();
      final c = await device('C');
      restore(backup);
      expect(await c.syncNow(), isNull);
      await c.add('c1');
      expect(await c.syncNow(), isNull);
      await c.add('c2');
      expect(await c.syncNow(), isNull);
      expect(await storeVersion(), 3, reason: 'the very number device A is at, with another content');
      expect(a.version, 3);
      expect(await storeHosts(), {'a1', 'c1', 'c2'});

      expect(await a.syncNow(), isNull);
      expect(await a.hosts(), {'a1', 'a2', 'a3', 'c1', 'c2'});
      expect(await storeHosts(), {'a1', 'a2', 'a3', 'c1', 'c2'});
    });

    test('nor is it written over by a device that has something to send', () async {
      final (a, backup) = await threeVersions();
      final c = await device('C');
      restore(backup);
      expect(await c.syncNow(), isNull);
      await c.add('c1');
      expect(await c.syncNow(), isNull);
      await c.add('c2');
      expect(await c.syncNow(), isNull);
      expect(await storeVersion(), 3);

      await a.add('a4');
      expect(await a.syncNow(), isNull);
      expect(await storeHosts(), {'a1', 'a2', 'a3', 'a4', 'c1', 'c2'}, reason: 'what the other device sent is merged, not lost');
      expect(await a.hosts(), {'a1', 'a2', 'a3', 'a4', 'c1', 'c2'});
    });
  });

  group('what a device remembers of the store it left', () {
    test('is when the store was written, after sending to it and after fetching from it', () async {
      final (a, _) = await threeVersions();
      final sent = (await MemoryStoreBackend(shared).getStatus()).updatedAt!;
      expect(a.settings.syncStoreUpdatedAt!.millisecondsSinceEpoch, sent.millisecondsSinceEpoch);

      final b = await device('B');
      expect(await b.syncNow(), isNull);
      expect(b.version, 3);
      expect(b.settings.syncStoreUpdatedAt!.millisecondsSinceEpoch, sent.millisecondsSinceEpoch);
    });

    test('goes with the count it belonged to: a count set without it knows no time', () async {
      final a = await device('A');
      final when = DateTime.utc(2026, 10, 8, 9, 30);
      await a.settings.setSyncServerVersion(7, storeUpdatedAt: when);
      expect(a.settings.syncServerVersion, 7);
      expect(a.settings.syncStoreUpdatedAt, when);
      // Disconnecting, joining afresh, setting sync up again: each sets the
      // count alone, and the time of the store that was left goes with it.
      await a.settings.setSyncServerVersion(0);
      expect(a.settings.syncServerVersion, 0);
      expect(a.settings.syncStoreUpdatedAt, isNull);
    });

    test('a store written again at the very moment the device knows is the store it left', () async {
      // The count and the time are what tell: with both as the device knows
      // them, nothing is fetched.
      final (a, _) = await threeVersions();
      final written = shared.counter;
      final fetched = a.settings.syncContentHash;
      expect(await a.syncNow(), isNull);
      expect(shared.counter, written);
      expect(a.settings.syncContentHash, fetched);
    });
  });

  group('a store that is where the device left it', () {
    test('is not fetched again, and nothing is written, however often it is synced', () async {
      final (a, _) = await threeVersions();
      final written = shared.counter;
      for (var i = 0; i < 3; i++) {
        expect(await a.syncNow(), isNull);
      }
      expect(shared.counter, written);
      expect(a.version, 3);
    });

    test('another device\'s work is fetched as before, and nothing is sent back', () async {
      final (a, _) = await threeVersions();
      final log = wentBackLog();
      final b = await device('B');
      expect(await b.syncNow(), isNull);
      await b.add('b1');
      expect(await b.syncNow(), isNull);
      final written = shared.counter;

      expect(await a.syncNow(), isNull);
      expect(await a.hosts(), {'a1', 'a2', 'a3', 'b1'});
      expect(shared.counter, written, reason: 'a fetch is not answered with a write');
      expect(a.version, 4);
      expect(log, isEmpty, reason: 'a store that is ahead has not gone back, and is not said to have');
    });

    test("another device's change is taken even where that device's clock was behind this one's", () async {
      // Times decide nothing here: only a store that went back is held to
      // them (its copies may be older than what the device last synced).
      final (a, _) = await threeVersions();
      await rename(a, 'a1', 'web-a1', DateTime.utc(2026, 10, 12));
      expect(await a.syncNow(), isNull);
      final b = await device('B');
      expect(await b.syncNow(), isNull);
      await rename(b, 'a1', 'db-a1', DateTime.utc(2026, 10, 11));
      expect(await b.syncNow(), isNull);

      expect(await a.syncNow(), isNull);
      expect(await label(a, 'a1'), 'db-a1');
      expect(await storeLabel('a1'), 'db-a1');
    });
  });
}
