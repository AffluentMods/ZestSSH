// Real Argon2id key derivation (the weakest profile deriveKey accepts),
// done once for the file. Allow for a machine busy with the whole suite.
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_health.dart';
import 'package:zestssh/services/sync_service.dart';

import '../../helpers/memory_store_backend.dart';

/// Sync paused on this device by its person, without taking it apart (3.0):
/// until a time, or until they resume it.
/// Nothing syncs by
/// itself meanwhile (a change made here, the app coming back to the front,
/// the network coming back, a try the store failed), the change made here is
/// kept to go later, Sync now still syncs, the pause outlasts a restart, and
/// it ends by itself at its time or when resumed, when what waited goes.

Future<void> _addHost(AppDatabase db, String id) =>
    db.connectionsDao.insertConnection(ConnectionsCompanion(
      id: Value(id),
      label: Value('host-$id'),
      host: Value('$id.example.com'),
      port: const Value(22),
      protocol: const Value('ssh'),
      createdAt: Value(DateTime.utc(2026, 10, 15)),
      updatedAt: Value(DateTime.utc(2026, 10, 15)),
    ));

/// A store that counts what is written to it, and can fail its writes.
class _Store extends MemoryStoreBackend {
  _Store(super.store);

  int writes = 0;
  Object? failWrites;

  @override
  Future<String?> writeObject(Uint8List bytes, {String? ifMatchEtag, bool ifAbsent = false}) {
    writes++;
    final failure = failWrites;
    if (failure != null) return Future.error(failure);
    return super.writeObject(bytes, ifMatchEtag: ifMatchEtag, ifAbsent: ifAbsent);
  }
}

/// The timers the service sets with its own timer, held by the test.
class _Timers {
  final waiting = <_Timer>[];

  Timer call(Duration wait, void Function() then) {
    final timer = _Timer(this, wait, then);
    waiting.add(timer);
    return timer;
  }

  void fire(_Timer timer) {
    waiting.remove(timer);
    timer.then();
  }
}

class _Timer implements Timer {
  _Timer(this._owner, this.wait, this.then);

  final _Timers _owner;
  final Duration wait;
  final void Function() then;

  @override
  void cancel() => _owner.waiting.remove(this);

  @override
  bool get isActive => _owner.waiting.contains(this);

  @override
  int get tick => 0;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const fast = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
  const storage = FlutterSecureStorage();

  late SettingsService settings;
  late AppDatabase device;
  late _Store store;
  late _Timers timers;
  late DateTime now;
  late SecretKey dek;
  late SecretKey mek;
  late Uint8List salt;
  late Uint8List verHash;
  final services = <AutoSyncService>[];

  setUpAll(() async {
    L10nGlobal.update(lookupAppLocalizations(const Locale('en')));
    salt = SyncService.generateSalt();
    dek = SyncService.generateDek();
    mek = await SyncService.deriveKey('correct-password', salt, params: fast);
    verHash = await SyncService.computeVerificationHash(mek);
  });

  /// The app's sync on this device, as it starts: a new one each time, as
  /// after a restart.
  AutoSyncService started() {
    final sync = AutoSyncService(
      syncDataService: memoryDataService(device, storage, settings),
      settingsService: settings,
      secureStorage: storage,
      resolveBackend: () => store,
      clock: () => now,
      timer: timers.call,
    );
    services.add(sync);
    return sync;
  }

  late AutoSyncService sync;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    settings = SettingsService(await SharedPreferences.getInstance());
    await settings.setSyncMode('auto');
    device = AppDatabase.forTesting(NativeDatabase.memory());
    store = _Store(MemoryStore());
    timers = _Timers();
    now = DateTime(2026, 10, 15, 9);
    sync = started();
    await storage.write(key: 'sync_salt', value: base64Encode(salt));
    await sync.storeSyncCredentials(dek, verHash, argon2Params: fast);

    // The store holds host a1, and this device has synced it.
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
    store.writes = 0;
  });

  tearDown(() async {
    for (final s in services) {
      s.dispose();
    }
    services.clear();
    await device.close();
  });

  /// Waits for a cycle that was started to end.
  Future<void> settled([AutoSyncService? on]) async {
    final s = on ?? sync;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    while (s.isSyncing) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    await Future<void>.delayed(Duration.zero);
  }

  /// A change made on this device, as the app says it: a host added.
  Future<void> changeMadeHere(String host) async {
    await _addHost(device, host);
    sync.notifyLocalChange();
  }

  /// Every way sync runs by itself, tried: the app coming back to the
  /// front, and the network coming back (a change made here goes by the
  /// same cycle, after a wait).
  Future<void> everythingThatRunsByItself() async {
    await sync.triggerSync();
    sync.networkChanged();
    await settled();
  }

  test('until resumed: nothing syncs by itself, the change made here is kept, and resuming sends it', () async {
    await sync.pause();
    expect(sync.pausedNow?.until, isNull);
    await changeMadeHere('a2');
    await everythingThatRunsByItself();
    expect(store.writes, 0);
    expect(settings.syncDirty, isTrue, reason: 'kept, to go later');
    expect(timers.waiting, isEmpty, reason: 'nothing set to end it');

    await sync.endPause();
    await settled();
    expect(sync.pausedNow, isNull);
    expect(settings.syncPause, isNull);
    expect(store.writes, 1, reason: 'what waited goes now');
  });

  test('a sync due by the clock is not due while paused', () async {
    await settings.setLastSyncTime(DateTime.now().subtract(const Duration(hours: 1)));
    expect(sync.checkSyncDue(), isTrue);
    await sync.pause();
    expect(sync.checkSyncDue(), isFalse);
  });

  test('paused again for another length: the end set before is let go', () async {
    await sync.pause(until: now.add(const Duration(hours: 1)));
    expect(timers.waiting, hasLength(1));
    await sync.pause();
    expect(timers.waiting, isEmpty, reason: 'until resumed: nothing ends it by itself');
    await sync.pause(until: now.add(const Duration(days: 1)));
    expect(timers.waiting.single.wait, const Duration(days: 1));
  });

  test('Sync now still syncs while paused, and the pause stays', () async {
    await sync.pause();
    await changeMadeHere('a2');
    await sync.syncNowManual();
    expect(store.writes, 1);
    expect(sync.pausedNow, isNotNull);
    await changeMadeHere('a3');
    await everythingThatRunsByItself();
    expect(store.writes, 1);
  });

  test('for an hour: it ends by itself then, and what waited goes', () async {
    await sync.pause(until: now.add(const Duration(hours: 1)));
    await changeMadeHere('a2');
    await everythingThatRunsByItself();
    expect(store.writes, 0);
    final end = timers.waiting.single;
    expect(end.wait, const Duration(hours: 1));

    now = now.add(const Duration(hours: 1));
    timers.fire(end);
    await settled();
    expect(sync.pausedNow, isNull);
    expect(settings.syncPause, isNull);
    expect(store.writes, 1);
  });

  test('it outlasts a restart; one whose time passed while the app was closed is forgotten, and sync runs', () async {
    await sync.pause(until: now.add(const Duration(hours: 1)));
    sync.dispose();
    services.remove(sync);
    timers.waiting.clear();

    // Started again within the hour: still paused, ending at its time.
    now = now.add(const Duration(minutes: 20));
    sync = started();
    sync.startAutoSync();
    await settled();
    expect(sync.pausedNow, isNotNull);
    expect(timers.waiting.single.wait, const Duration(minutes: 40));
    await changeMadeHere('a2');
    await everythingThatRunsByItself();
    expect(store.writes, 0);
    sync.dispose();
    services.remove(sync);
    timers.waiting.clear();

    // Started again after it: forgotten, and the change that waited goes.
    now = now.add(const Duration(hours: 1));
    sync = started();
    sync.startAutoSync();
    await settled();
    expect(settings.syncPause, isNull);
    expect(store.writes, 1);
  });

  test('a store that fails Sync now while paused is not tried again by itself', () async {
    await sync.pause();
    await changeMadeHere('a2');
    store.failWrites = const SocketException('Connection refused');
    await expectLater(sync.syncNowManual(), throwsA(isA<SyncException>()));
    expect(timers.waiting, isEmpty, reason: 'no try set for later');
  });

  group('how it is said', () {
    SyncHealthState said({SyncPause? pause, String? problem, bool dirty = false}) => syncHealthOf(
          configured: true,
          mode: 'auto',
          running: false,
          problem: problem,
          paused: false,
          pause: pause,
          confirmedAt: DateTime(2026, 10, 15, 8),
          dirty: dirty,
          dirtySince: DateTime(2026, 10, 14),
          now: DateTime(2026, 10, 15, 9),
        );

    test('paused, until when, and whether changes wait; not as a failure from before, nor as a device behind',
        () {
      final until = DateTime(2026, 10, 15, 10);
      final h = said(pause: SyncPause(until: until), problem: 'The keys do not match.', dirty: true);
      expect(h.health, SyncHealth.paused);
      expect(h.pause?.until, until);
      expect(h.waiting, isTrue);
      expect(said(pause: const SyncPause()).health, SyncHealth.paused);
      expect(said(pause: const SyncPause()).waiting, isFalse);
    });

    test('a pause whose time has passed is no pause', () {
      expect(said(pause: SyncPause(until: DateTime(2026, 10, 15, 8, 59))).health, SyncHealth.upToDate);
      expect(said().health, SyncHealth.upToDate);
    });
  });
}
