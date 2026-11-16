// Real Argon2id key derivation (the weakest profile deriveKey accepts),
// done once for the file. Allow for a machine busy with the whole suite.
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/backup_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync/sync_manifest.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/services/sync_service.dart';

import '../../helpers/memory_store_backend.dart';

/// A store that keeps an old copy (found in a cryptography review).
/// Nothing inside the blob said how old it was, and everything outside it is
/// the store's word: a compromised backend, or anyone who can write to a
/// WebDAV, S3 or Drive store, kept an old real blob and served it under a
/// higher version. Every item unchanged on a device since its last sync went
/// back to the old copy (an old address, an old password) and the security
/// switches with it, and nothing was said.
///
/// Now the blob counts for itself, inside its encryption. A device that is
/// given one below the highest it saw merges it as a store that went back,
/// and says so.

const _fast = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
final _t0 = DateTime.utc(2026, 10, 1, 9);
final _t1 = DateTime.utc(2026, 10, 20, 9);

class _Device {
  _Device(this.db, this.settings, this.backend, this.data, this.sync);

  final AppDatabase db;
  final SettingsService settings;
  final MemoryStoreBackend backend;
  final SyncDataService data;
  final AutoSyncService sync;

  /// Host h1 at [address], changed at [at], and the device noting that it has
  /// something to send, as the app does.
  Future<void> host(String address, DateTime at, {String id = 'h1'}) async {
    await db.into(db.connections).insertOnConflictUpdate(
        ConnectionsCompanion.insert(id: id, label: 'Prod', host: address, createdAt: _t0, updatedAt: at));
    await settings.setSyncDirty(true);
  }

  Future<String?> address([String id = 'h1']) async => (await db.connectionsDao.getById(id))?.host;

  /// One sync as the app runs it by itself: what stopped it, or null.
  Future<String?> syncNow() async {
    await sync.triggerSync();
    return sync.activity.value.failure;
  }

  Future<int> seen() async => (await data.storeCountSeen()).count;
}

/// A store that lets [before] run once as a device is about to write to it:
/// another device that gets in first.
class _RacedStore extends MemoryStoreBackend {
  _RacedStore(super.store);

  Future<void> Function()? before;

  /// What time the store says it is, where it says (the hosted server does).
  DateTime Function()? serverNow;

  @override
  Future<SyncStatus> getStatus() async {
    final status = await super.getStatus();
    final now = serverNow?.call();
    if (now == null) return status;
    return SyncStatus(
      hasData: status.hasData,
      version: status.version,
      blobSize: status.blobSize,
      updatedAt: status.updatedAt,
      lastDevice: status.lastDevice,
      serverTime: now,
      hasRecovery: status.hasRecovery,
    );
  }

  @override
  Future<({int version, int blobSize, DateTime? updatedAt})> push({
    required Map<String, dynamic> data,
    required SecretKey dek,
    required Uint8List salt,
    required Uint8List verificationHash,
    String? deviceId,
    Uint8List? wrappedDekPassword,
    Uint8List? wrappedDekRecovery,
    Uint8List? recoverySalt,
    Uint8List? recoveryHash,
    int? expectedVersion,
    bool createOnly = false,
    Map<String, dynamic>? argon2Params,
    Uint8List? authorizeHash,
    Uint8List? authorizeRecoveryHash,
  }) async {
    final hook = before;
    before = null;
    if (hook != null) await hook();
    return super.push(
      data: data,
      dek: dek,
      salt: salt,
      verificationHash: verificationHash,
      deviceId: deviceId,
      wrappedDekPassword: wrappedDekPassword,
      wrappedDekRecovery: wrappedDekRecovery,
      recoverySalt: recoverySalt,
      recoveryHash: recoveryHash,
      expectedVersion: expectedVersion,
      createOnly: createOnly,
      argon2Params: argon2Params,
      authorizeHash: authorizeHash,
      authorizeRecoveryHash: authorizeRecoveryHash,
    );
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
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
    mek = await SyncService.deriveKey('correct-password', salt, params: _fast);
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

  Future<_Device> device() async {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues(const {});
    final settings = SettingsService(await SharedPreferences.getInstance());
    await settings.setSyncMode('auto');
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final backend = _RacedStore(shared);
    final data = memoryDataService(db, storage, settings);
    final sync = AutoSyncService(
      syncDataService: data,
      settingsService: settings,
      secureStorage: storage,
      resolveBackend: () => backend,
    );
    await sync.storeSyncCredentials(dek, verHash, argon2Params: _fast);
    final d = _Device(db, settings, backend, data, sync);
    devices.add(d);
    return d;
  }

  /// The account set up by [first], holding whatever it holds, as setting sync
  /// up writes it.
  Future<void> setUpAccount(_Device first) async {
    final pushed = await first.backend.push(
      data: await first.data.gatherAll(),
      dek: dek,
      salt: salt,
      verificationHash: verHash,
      wrappedDekPassword: await SyncService.wrapDek(dek, mek),
      createOnly: true,
      argon2Params: _fast,
    );
    await first.settings.setSyncServerVersion(pushed.version);
    await first.settings.setLastSyncTime(DateTime.now());
    expect(await first.syncNow(), isNull);
  }

  SyncManifest manifest() => SyncManifest.fromBytes(shared.bytes!);

  Future<Map<String, dynamic>> storeData() async => SyncService.decrypt(manifest().encryptedData, dek);

  /// What the store holds, on the outside as it says itself: [data] under
  /// [version] (one more than now by default), written just now.
  Future<void> serve(Map<String, dynamic> data, {int? version}) async {
    final m = manifest();
    shared
      ..bytes = SyncManifest(
        version: version ?? m.version + 1,
        updatedAt: DateTime.now().toUtc(),
        salt: m.salt,
        argon2Params: m.argon2Params,
        encryptedData: await SyncService.encrypt(data, dek, salt),
        passwordHash: m.passwordHash,
        wrappedDekPassword: m.wrappedDekPassword,
      ).toBytes()
      ..counter += 1
      ..etag = 'served-${shared.counter}';
  }

  /// [data] as it was written [ago] back: what a store that keeps an old copy
  /// holds. (A test cannot wait for it to grow old.)
  Map<String, dynamic> aged(Map<String, dynamic> data, Duration ago) => {
        ...data,
        SyncDataService.storeCountAtField:
            DateTime.now().toUtc().subtract(ago).millisecondsSinceEpoch,
      };

  List<String> wentBackLog() {
    final said = <String>[];
    final level = Logger.root.level;
    Logger.root.level = Level.ALL;
    final listening = Logger.root.onRecord.listen((record) {
      if (record.message.contains('not where this device left it')) said.add(record.message);
    });
    addTearDown(() {
      Logger.root.level = level;
      return listening.cancel();
    });
    return said;
  }

  group('an old copy, served under a higher version', () {
    /// A device that synced host h1 at an old address with OSC 52 on, then
    /// moved it and turned OSC 52 off, and synced; and the old copy as the
    /// store kept it, well over the time a race explains.
    Future<(_Device, Map<String, dynamic>)> keptAnOldCopy() async {
      final a = await device();
      await a.host('old-bastion.example.com', _t0);
      await a.settings.setOsc52Clipboard(true);
      await setUpAccount(a);
      final old = aged(await storeData(), const Duration(days: 19));
      await a.host('new-bastion.example.com', _t1);
      await a.settings.setOsc52Clipboard(false);
      expect(await a.syncNow(), isNull);
      return (a, old);
    }

    test('takes nothing back, and goes back up: the address and the switch stay, and the person is told', () async {
      final (a, old) = await keptAnOldCopy();
      final log = wentBackLog();
      await serve(old, version: 99);

      expect(await a.syncNow(), isNull);
      expect(await a.address(), 'new-bastion.example.com', reason: 'an older copy is no change of another device');
      expect(a.settings.osc52Clipboard, isFalse, reason: 'a security switch does not go back either');
      expect(a.sync.storeWentBack.value, 1, reason: 'told, once');
      expect(log, hasLength(1));
      expect(log.single, contains('this device saw'));

      final back = await storeData();
      expect((back['connections'] as List).cast<Map>().single['host'], 'new-bastion.example.com');
      expect((back['settings'] as Map)['osc52_clipboard'], isFalse);
      expect(SyncDataService.storeCountOf(back), greaterThan(SyncDataService.storeCountOf(old)!));
    });

    test('a second device that holds the newer copy, unchanged since it last synced, the same', () async {
      final (a, old) = await keptAnOldCopy();
      final b = await device();
      expect(await b.syncNow(), isNull);
      expect(await b.address(), 'new-bastion.example.com');
      expect(b.settings.osc52Clipboard, isFalse);

      await serve(old, version: 99);
      expect(await b.syncNow(), isNull);
      expect(await b.address(), 'new-bastion.example.com');
      expect(b.settings.osc52Clipboard, isFalse);
      expect(b.sync.storeWentBack.value, 1);
      expect(a.sync.storeWentBack.value, 0, reason: 'it has not looked yet');
    });

    test('a store that keeps serving it is told of once in a run', () async {
      final (a, old) = await keptAnOldCopy();
      await serve(old, version: 99);
      expect(await a.syncNow(), isNull);
      await serve(old, version: 200);
      expect(await a.syncNow(), isNull);
      expect(a.sync.storeWentBack.value, 1);
      expect(await a.address(), 'new-bastion.example.com');
    });

    test('what another device really wrote since goes on being taken', () async {
      final (a, _) = await keptAnOldCopy();
      final b = await device();
      expect(await b.syncNow(), isNull);
      await b.host('newer-still.example.com', _t1.add(const Duration(days: 1)));
      await b.settings.setOsc52Clipboard(true);
      expect(await b.syncNow(), isNull);

      expect(await a.syncNow(), isNull);
      expect(await a.address(), 'newer-still.example.com');
      expect(a.settings.osc52Clipboard, isTrue, reason: 'changed there, and not gone back');
      expect(a.sync.storeWentBack.value, 0);
    });
  });

  group('a store genuinely restored from a backup', () {
    test('behind a device: keeps what is newer here and its settings', () async {
      final a = await device();
      await a.host('old.example.com', _t0);
      await a.settings.setOsc52Clipboard(true);
      await setUpAccount(a);
      final backup = Uint8List.fromList(shared.bytes!);
      final was = aged(await storeData(), const Duration(days: 3));
      await a.host('new.example.com', _t1);
      await a.settings.setOsc52Clipboard(false);
      expect(await a.syncNow(), isNull);

      // The restored file, as it was, then aged as it really would be.
      shared
        ..bytes = backup
        ..counter += 100
        ..etag = 'restored-${shared.counter}';
      await serve(was, version: manifest().version);

      expect(await a.syncNow(), isNull);
      expect(await a.address(), 'new.example.com');
      expect(a.settings.osc52Clipboard, isFalse, reason: 'it flipped back on every device');
      expect(a.sync.storeWentBack.value, 1);
      expect(((await storeData())['settings'] as Map)['osc52_clipboard'], isFalse);
    });

    test('at the restore: a setting changed on both sides, and one only there', () async {
      // The merge itself, as the audit proved it: the store is known to have
      // gone back.
      SharedPreferences.resetStatic();
      SharedPreferences.setMockInitialValues(const {});
      final settings = SettingsService(await SharedPreferences.getInstance());
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final data = memoryDataService(db, storage, settings);
      final key = List<int>.generate(32, (i) => i * 7 % 256);

      await settings.setOsc52Clipboard(true);
      final old = await data.gatherAll();
      await settings.setOsc52Clipboard(false);
      final base = SyncDataService.itemHashes(await data.gatherAll(), key);

      var result = await data.restoreAll({...old}, merge: SyncMergeBase(key: key, base: base, storeWentBack: true));
      expect(settings.osc52Clipboard, isFalse);
      expect(result.keptHere, 1, reason: 'kept here, so it is sent');

      // Changed here since the last sync as well: this device's stays.
      result = await data.restoreAll({...old}, merge: SyncMergeBase(key: key, base: const {}, storeWentBack: true));
      expect(settings.osc52Clipboard, isFalse);

      // One this device never set is not set from an old copy either.
      SharedPreferences.resetStatic();
      SharedPreferences.setMockInitialValues(const {});
      final fresh = SettingsService(await SharedPreferences.getInstance());
      final freshData = memoryDataService(db, storage, fresh);
      await freshData.restoreAll({...old}, merge: SyncMergeBase(key: key, base: const {}, storeWentBack: true));
      expect(fresh.osc52Clipboard, isFalse);

      // And a store that did not go back still brings another device's change.
      await freshData.restoreAll({...old}, merge: SyncMergeBase(key: key, base: const {}));
      expect(fresh.osc52Clipboard, isTrue);
    });

    test('an item with no time to tell by stays as it is here', () async {
      SharedPreferences.resetStatic();
      SharedPreferences.setMockInitialValues(const {});
      final settings = SettingsService(await SharedPreferences.getInstance());
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final data = memoryDataService(db, storage, settings);
      final key = List<int>.generate(32, (i) => i * 7 % 256);
      await db.customStatement("INSERT INTO snippet_categories (name, color_index) VALUES ('Ops', 1)");
      final old = await data.gatherAll();
      await db.customStatement("UPDATE snippet_categories SET color_index = 2, updated_at = NULL WHERE name = 'Ops'");
      final base = SyncDataService.itemHashes(await data.gatherAll(), key);
      for (final row in old['snippet_categories'] as List) {
        (row as Map)['updatedAt'] = null;
      }

      final result = await data.restoreAll(old, merge: SyncMergeBase(key: key, base: base, storeWentBack: true));
      expect(result.keptHere, greaterThan(0));
      final row = await db.customSelect("SELECT color_index FROM snippet_categories WHERE name = 'Ops'").getSingle();
      expect(row.read<int>('color_index'), 2);
    });
  });

  group('what is no alarm', () {
    test('every push counts on, whichever device makes it', () async {
      final a = await device();
      await a.host('a.example.com', _t0);
      await setUpAccount(a);
      final first = SyncDataService.storeCountOf(await storeData())!;
      final b = await device();
      expect(await b.syncNow(), isNull);
      expect(await b.seen(), first, reason: 'what it read');

      await b.host('b.example.com', _t1);
      expect(await b.syncNow(), isNull);
      expect(SyncDataService.storeCountOf(await storeData()), first + 1);
      expect(await b.seen(), first + 1);

      expect(await a.syncNow(), isNull);
      await a.host('c.example.com', _t1.add(const Duration(days: 1)));
      expect(await a.syncNow(), isNull);
      expect(SyncDataService.storeCountOf(await storeData()), first + 2);
      expect(a.sync.storeWentBack.value + b.sync.storeWentBack.value, 0);
    });

    test('two devices pushing near each other: the one that lost goes on from the winner', () async {
      final a = await device();
      await a.host('a.example.com', _t0);
      await setUpAccount(a);
      final b = await device();
      expect(await b.syncNow(), isNull);
      final start = await b.seen();

      await b.host('from-b.example.com', _t1, id: 'hb');
      await a.host('from-a.example.com', _t1, id: 'ha');
      // A gets in between B's look at the store and B's write: B's write is
      // refused, its count not kept, and it fetches, merges and writes again.
      (b.backend as _RacedStore).before = () async {
        expect(await a.syncNow(), isNull);
      };
      final log = wentBackLog();
      expect(await b.syncNow(), isNull);
      expect(await b.address('ha'), 'from-a.example.com');
      expect(SyncDataService.storeCountOf(await storeData()), start + 2, reason: 'A wrote one, and B one more');
      expect(b.sync.storeWentBack.value, 0);
      expect(log, isEmpty);

      expect(await a.syncNow(), isNull);
      expect(await a.address('hb'), 'from-b.example.com');
      expect(a.sync.storeWentBack.value, 0);
      expect(log, isEmpty);
    });

    test('equal counts: two pushes that both won, where a store takes the last write', () async {
      final a = await device();
      await a.host('a.example.com', _t0);
      await setUpAccount(a);
      final b = await device();
      expect(await b.syncNow(), isNull);

      // Both count from the same number.
      await b.host('from-b.example.com', _t1, id: 'hb');
      final bWrote = await b.data.gatherAll();
      await a.host('from-a.example.com', _t1, id: 'ha');
      expect(await a.syncNow(), isNull);
      expect(SyncDataService.storeCountOf(bWrote), await a.seen());

      await serve(bWrote);
      expect(await a.syncNow(), isNull);
      expect(a.sync.storeWentBack.value, 0, reason: 'nothing went back: another device wrote at the same moment');
      expect(await a.address('hb'), 'from-b.example.com');
    });

    test('a push that lost a race to two others: lower, and written just now: merged, and nothing said', () async {
      final a = await device();
      await a.host('a.example.com', _t0);
      await setUpAccount(a);
      final b = await device();
      expect(await b.syncNow(), isNull);

      await b.host('from-b.example.com', _t1, id: 'hb');
      final bWrote = await b.data.gatherAll();
      await a.host('a2.example.com', _t1);
      expect(await a.syncNow(), isNull);
      await a.host('a3.example.com', _t1.add(const Duration(hours: 1)));
      expect(await a.syncNow(), isNull);
      expect(SyncDataService.storeCountOf(bWrote)!, lessThan(await a.seen()));

      await serve(bWrote);
      expect(await a.syncNow(), isNull);
      expect(a.sync.storeWentBack.value, 0, reason: 'a push that lost a race is no old copy');
      expect(await a.address(), 'a3.example.com', reason: 'still merged as one that went back');
      expect(await a.address('hb'), 'from-b.example.com');
      expect((await storeData())['connections'], hasLength(2), reason: 'what it lacks went back');
    });

    test('a changed password writes what it read again: with a count of its own, and the time now', () async {
      final a = await device();
      await a.host('a.example.com', _t0);
      await setUpAccount(a);
      final read = aged(await storeData(), const Duration(days: 30));
      final stamped = await a.data.stampForPush(read);
      expect(SyncDataService.storeCountOf(stamped), SyncDataService.storeCountOf(read)! + 1);
      expect(stamped[SyncDataService.storeCountAtField], greaterThan(read[SyncDataService.storeCountAtField] as int));
      expect(stamped['connections'], read['connections']);

      // Read ahead of what this device saw: it goes on from what it read.
      final ahead = await a.data.stampForPush({...read, SyncDataService.storeCountField: 50});
      expect(SyncDataService.storeCountOf(ahead), 51);
    });
  });

  group('a blob with no count', () {
    test('an old copy with no count in it, on a device that has seen a count: takes nothing back, goes back up, '
        'and nobody is alarmed', () async {
      // A device that synced host h1 at an old address with OSC 52 on, then
      // moved it and turned OSC 52 off, and synced.
      final a = await device();
      await a.host('old-bastion.example.com', _t0);
      await a.settings.setOsc52Clipboard(true);
      await setUpAccount(a);
      final counted = await storeData();
      await a.host('new-bastion.example.com', _t1);
      await a.settings.setOsc52Clipboard(false);
      expect(await a.syncNow(), isNull);
      // The copy as a version before the count wrote it, or as a store kept
      // it from before there was one.
      final old = SyncDataService.withoutStoreCount(counted);
      expect(SyncDataService.storeCountOf(old), isNull);
      final seen = await a.seen();
      expect(seen, greaterThan(0));
      final log = wentBackLog();
      await serve(old, version: 99);

      expect(await a.syncNow(), isNull);
      expect(await a.address(), 'new-bastion.example.com', reason: 'an older copy is no change of another device');
      expect(a.settings.osc52Clipboard, isFalse, reason: 'a security switch does not go back either');
      expect(a.sync.storeWentBack.value, 0, reason: 'an older version of the app pushes such blobs too: no alarm');
      expect(log, hasLength(1));
      expect(log.single, contains('its data counts nothing'));
      expect(await a.seen(), greaterThanOrEqualTo(seen), reason: 'what it saw is never lowered');

      final back = await storeData();
      expect((back['connections'] as List).cast<Map>().single['host'], 'new-bastion.example.com');
      expect((back['settings'] as Map)['osc52_clipboard'], isFalse);
      expect(SyncDataService.storeCountOf(back), greaterThan(seen), reason: 'sent back, counted again');
    });

    test('a device that has seen no count takes a blob without one as ever', () async {
      final a = await device();
      expect(await a.seen(), 0);
      final stand = await a.data.compareStoreCount({'connections': const []});
      expect(stand.older, isFalse);
      expect(stand.wentBack, isFalse);
    });

    test('from a version before the count: its later edit is taken, with no alarm; the next push counts on', () async {
      final a = await device();
      await a.host('a.example.com', _t0);
      await setUpAccount(a);
      await a.host('a2.example.com', _t0.add(const Duration(days: 1)));
      expect(await a.syncNow(), isNull);
      final seen = await a.seen();

      // An old app read a blob, ignored the count, and pushed without it.
      final old = SyncDataService.withoutStoreCount(await storeData());
      expect(SyncDataService.storeCountOf(old), isNull);
      (old['connections'] as List).cast<Map>().single
        ..['host'] = 'from-old-app.example.com'
        ..['updatedAt'] = _t1.millisecondsSinceEpoch ~/ 1000;
      final log = wentBackLog();
      await serve(old);

      expect(await a.syncNow(), isNull);
      expect(await a.address(), 'from-old-app.example.com', reason: 'changed later than the copy here');
      expect(a.sync.storeWentBack.value, 0);
      expect(log, hasLength(1), reason: 'merged as a store that went back, and logged');
      // Nothing was kept here against it, so there is nothing to send back:
      // the store holds what the older version wrote until the next change.
      expect(await a.seen(), seen, reason: 'what it saw stays');
      expect(SyncDataService.storeCountOf(await storeData()), isNull);

      await a.host('a3.example.com', _t1.add(const Duration(days: 1)));
      expect(await a.syncNow(), isNull);
      expect(SyncDataService.storeCountOf(await storeData()), seen + 1);
    });

    test('the payload stays at its version: a build that knows nothing of the count loses nothing by it', () async {
      final a = await device();
      final data = await a.data.gatherAll();
      expect(data['schema_version'], SyncDataService.supportedSchemaVersion);
      expect(SyncDataService.supportedSchemaVersion, 22);
      // What says "nothing changed" does not see it: a count alone is no change
      // to send, and a pull followed by a gather is no echo.
      final key = List<int>.generate(32, (i) => i);
      expect(SyncDataService.contentFingerprint(data, key),
          SyncDataService.contentFingerprint(SyncDataService.withoutStoreCount(data), key));
      expect(SyncDataService.itemHashes(data, key), SyncDataService.itemHashes(SyncDataService.withoutStoreCount(data), key));
    });

    test('a count that is no count is none', () {
      for (final bad in <Object?>[null, 0, -3, '7', 1.5, 1 << 53]) {
        expect(SyncDataService.storeCountOf({SyncDataService.storeCountField: bad}), isNull, reason: '$bad');
      }
      expect(SyncDataService.storeCountOf({SyncDataService.storeCountField: 7}), 7);
    });
  });

  group('what a device knows', () {
    test('a brand new device takes what it is first given, and holds to it from there', () async {
      final a = await device();
      await a.host('old.example.com', _t0);
      await setUpAccount(a);
      final old = aged(await storeData(), const Duration(days: 3));
      await a.host('new.example.com', _t1);
      expect(await a.syncNow(), isNull);
      final newer = await storeData();

      // Stated in the whitepaper: older than any device saw, and it cannot know.
      await serve(old);
      final b = await device();
      expect(await b.syncNow(), isNull);
      expect(await b.address(), 'old.example.com');
      expect(b.sync.storeWentBack.value, 0);

      await serve(newer);
      expect(await b.syncNow(), isNull);
      expect(await b.address(), 'new.example.com');
      await serve(old);
      expect(await b.syncNow(), isNull);
      expect(await b.address(), 'new.example.com');
      expect(b.sync.storeWentBack.value, 1);
    });

    test('what a join reads counts as seen', () async {
      final a = await device();
      await a.host('a.example.com', _t0);
      await setUpAccount(a);
      final data = await storeData();
      final b = await device();
      await b.data.restoreAll(data);
      expect(await b.seen(), SyncDataService.storeCountOf(data));
      // Never lowered.
      await b.data.noteStoreCount(1);
      expect(await b.seen(), SyncDataService.storeCountOf(data));
    });

    test('kept per account: set aside with its keys, forgotten with sync', () async {
      final a = await device();
      await a.data.noteStoreCount(40);
      await a.data.setSyncBaseAside();
      await a.data.clearSyncBase();
      expect(await a.seen(), 0, reason: 'another account starts from nothing');
      await a.data.noteStoreCount(3);

      await a.data.takeSyncBaseBack();
      expect(await a.seen(), 40, reason: 'and the same account comes back to what it saw');

      await a.data.setSyncBaseAside();
      await a.data.clearSyncBase();
      await a.data.dropSyncBaseAside();
      await a.data.takeSyncBaseBack();
      expect(await a.seen(), 0, reason: 'dropped for good');
    });

    test('credentials cleared: what it saw of that store goes', () async {
      final a = await device();
      await a.data.noteStoreCount(40);
      await a.sync.clearSyncCredentials();
      expect(await a.seen(), 0);
    });

    test('reset all settings does not touch it', () async {
      final a = await device();
      await a.data.noteStoreCount(40);
      await a.settings.resetAllToDefaults();
      expect(await a.seen(), 40);
    });

    test('a backup holds no count, and restoring one says nothing of the store', () async {
      final a = await device();
      await a.host('a.example.com', _t0);
      final dir = await Directory.systemTemp.createTemp('store_count_');
      addTearDown(() => dir.delete(recursive: true));

      // A .zest of the old kind as a person may have one (no key derivation to
      // wait for), carrying a count all the same.
      final file = File('${dir.path}/old.zest');
      final data = await a.data.gatherAll();
      await file.writeAsBytes([...utf8.encode('ZEST'), 2, ...utf8.encode(jsonEncode({...data, SyncDataService.storeCountField: 900}))]);
      final result = await BackupService(a.data).importBackup(file.path, '', allowLegacyUnencrypted: true);
      expect(result.success, isTrue);
      expect(await a.seen(), 0);

      // And none is written: the export goes through this.
      expect(SyncDataService.withoutStoreCount(data).containsKey(SyncDataService.storeCountField), isFalse);
      expect(SyncDataService.withoutStoreCount(data).containsKey(SyncDataService.storeCountAtField), isFalse);
      expect(File('lib/services/backup_service.dart').readAsStringSync(),
          contains('SyncDataService.withoutStoreCount(await _syncDataService.gatherAll())'));
    });
  });

  test('a device whose clock the store says is wrong prunes no tombstone; once it is right, the old ones go '
      '(found in a security review)', () async {
    final a = await device();
    await a.host('a.example.com', _t0);
    await setUpAccount(a);
    await a.db.tombstonesDao.mark('connections', 'gone-long-ago', at: DateTime.now().subtract(const Duration(days: 800)));
    Future<bool> kept() async => (await a.db.tombstonesDao.getAll()).any((t) => t.entityId == 'gone-long-ago');

    // The device's clock is three years ahead of the store's.
    final store = a.backend as _RacedStore;
    store.serverNow = () => DateTime.now().toUtc().subtract(const Duration(days: 3 * 365));
    await a.host('b.example.com', DateTime.now());
    expect(await a.syncNow(), isNull);
    expect(a.sync.clockSkew.value, isNotNull);
    expect(a.data.clockInDoubt, isTrue);
    expect(await kept(), isTrue);

    store.serverNow = () => DateTime.now().toUtc();
    await a.host('c.example.com', DateTime.now());
    expect(await a.syncNow(), isNull);
    expect(a.sync.clockSkew.value, isNull);
    expect(a.data.clockInDoubt, isFalse);
    expect(await kept(), isFalse);
  });

  test('a push that fails counts for nothing', () async {
    final a = await device();
    await a.host('a.example.com', _t0);
    await setUpAccount(a);
    final seen = await a.seen();
    await a.host('a2.example.com', _t1);
    (a.backend as _RacedStore).before = () async => throw const SyncException('the store is down');
    await a.sync.triggerSync();
    expect(await a.seen(), seen);
    expect(a.settings.syncDirty, isTrue);
  });
}
