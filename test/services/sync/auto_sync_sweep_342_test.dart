// Real Argon2id key derivation (the weakest profile deriveKey accepts),
// done once for the file.
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync/dumb_store_sync_backend.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync_service.dart';

import '../../helpers/memory_store_backend.dart';

/// The background sync's small faults the 3.4.2 sweep found (L1 to L4).
///
/// L1: a throw while the store was resolved left sync "running" for the rest
/// of the run, and Sync now waited for ever. L2: a cycle in flight at a lock
/// armed a try again on the service the lock left behind. L3: Try again after
/// a device was signed out did nothing while a cycle ran. L4: a change made
/// while sync was Manual was not sent when the mode went back to Automatic.

Future<void> _addHost(AppDatabase db, String id) =>
    db.connectionsDao.insertConnection(ConnectionsCompanion(
      id: Value(id),
      label: Value('host-$id'),
      host: Value('$id.example.com'),
      port: const Value(22),
      protocol: const Value('ssh'),
      createdAt: Value(DateTime.utc(2026, 11, 7)),
      updatedAt: Value(DateTime.utc(2026, 11, 7)),
    ));

/// A store the test can take away ([down]), or hold a read of ([held]).
class _Store extends MemoryStoreBackend {
  _Store(super.store);

  Object? down;
  Completer<void>? held;
  int reads = 0;
  int writes = 0;

  @override
  Future<RawObject?> readObject() async {
    reads++;
    await held?.future;
    final failure = down;
    if (failure != null) throw failure;
    return super.readObject();
  }

  @override
  Future<String?> writeObject(Uint8List bytes, {String? ifMatchEtag, bool ifAbsent = false}) {
    writes++;
    final failure = down;
    if (failure != null) return Future.error(failure);
    return super.writeObject(bytes, ifMatchEtag: ifMatchEtag, ifAbsent: ifAbsent);
  }
}

/// The timers the service sets, held by the test.
class _Timers {
  final waiting = <Duration>[];

  Timer call(Duration wait, void Function() then) {
    waiting.add(wait);
    return Timer(const Duration(days: 1), then);
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const fast = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
  const storage = FlutterSecureStorage();
  const refused = SocketException('Connection refused');

  late SettingsService settings;
  late AppDatabase device;
  late _Store store;
  late AutoSyncService sync;
  late _Timers timers;
  late SecretKey dek;
  late SecretKey mek;
  late Uint8List salt;
  late Uint8List verHash;
  late SyncBackend Function() resolve;

  setUpAll(() async {
    salt = SyncService.generateSalt();
    dek = SyncService.generateDek();
    mek = await SyncService.deriveKey('correct-password', salt, params: fast);
    verHash = await SyncService.computeVerificationHash(mek);
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    settings = SettingsService(await SharedPreferences.getInstance());
    await settings.setSyncMode('auto');
    device = AppDatabase.forTesting(NativeDatabase.memory());
    store = _Store(MemoryStore());
    timers = _Timers();
    resolve = () => store;
    sync = AutoSyncService(
      syncDataService: memoryDataService(device, storage, settings),
      settingsService: settings,
      secureStorage: storage,
      resolveBackend: () => resolve(),
      timer: timers.call,
    );
    await storage.write(key: 'sync_salt', value: base64Encode(salt));
    await sync.storeSyncCredentials(dek, verHash, argon2Params: fast);
    await _addHost(device, 'a1');
    final v1 = await store.push(
      data: await memoryDataService(device, storage, settings).gatherAll(),
      dek: dek,
      salt: salt,
      verificationHash: verHash,
      wrappedDekPassword: await SyncService.wrapDek(dek, mek),
      createOnly: true,
      argon2Params: fast,
    );
    await settings.setSyncServerVersion(v1.version);
    await settings.setLastSyncTime(DateTime.now());
    store
      ..reads = 0
      ..writes = 0;
  });

  tearDown(() async {
    sync.dispose();
    await device.close();
  });

  test('a store that could not be resolved ends its cycle, and the next one, and Sync now, run', () async {
    resolve = () => throw StateError('no store to resolve');
    await sync.triggerSync().timeout(const Duration(seconds: 5));
    expect(sync.isSyncing, isFalse, reason: 'not left running');

    resolve = () => store;
    await sync.syncNowManual().timeout(const Duration(seconds: 10), onTimeout: () => fail('Sync now waited for ever'));
    expect(store.reads, greaterThan(0));
  });

  test('stopped, a cycle in flight that the store fails arms no try again; one begun after, does', () async {
    store.down = refused;
    store.held = Completer<void>();
    final inFlight = sync.triggerSync();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    sync.stopAutoSync();
    store.held!.complete();
    await inFlight;
    expect(timers.waiting, isEmpty, reason: 'no try again on a stopped service');

    store.held = null;
    sync.startAutoSync();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    while (sync.isSyncing) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(timers.waiting, isNotEmpty, reason: 'started again, a failure is tried again as before');
  });

  test('the one let go at a lock runs nothing more by itself', () async {
    store.down = refused;
    store.held = Completer<void>();
    final inFlight = sync.triggerSync();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    sync.retire();
    store.held!.complete();
    await inFlight;
    expect(timers.waiting, isEmpty);
    final source = File('lib/providers/core_providers.dart').readAsStringSync();
    expect(source, contains('ref.onDispose(service.retire);'), reason: 'the provider lets each one go');
  });

  test('Try again while a cycle runs waits for it, then runs, past the wait after a failure', () async {
    store.down = refused;
    await sync.triggerSync();
    expect(timers.waiting, isNotEmpty, reason: 'a try again set for later');
    store.down = null;

    store.held = Completer<void>();
    final running = sync.syncNowManual().then<Object?>((_) => null, onError: (Object e) => e);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(sync.isSyncing, isTrue);
    final readsBefore = store.reads;
    final again = sync.retryAfterFix();
    store.held!.complete();
    store.held = null;
    await running;
    await again.timeout(const Duration(seconds: 10));
    expect(store.reads, greaterThan(readsBefore + 1), reason: 'a cycle of its own ran after the one in flight');
  });

  test('a change made while Manual is marked, and goes when the mode is back to Automatic', () async {
    await settings.setSyncMode('manual');
    await sync.setUpHere();
    await settings.setSyncDirty(false);
    await _addHost(device, 'b2');
    sync.notifyLocalChange();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(settings.syncDirty, isTrue, reason: 'marked, though nothing is sent in Manual');
    expect(store.writes, 0);

    await settings.setSyncMode('auto');
    sync.startAutoSync();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    while (sync.isSyncing) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    sync.stopAutoSync();
    expect(store.writes, 1, reason: 'sent with the first cycle in Automatic');
    expect(settings.syncDirty, isFalse);
  });
}
