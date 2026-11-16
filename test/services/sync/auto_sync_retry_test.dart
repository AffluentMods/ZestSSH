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
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync/dumb_store_sync_backend.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/utils/error_translator.dart';

import '../../helpers/memory_store_backend.dart';

/// A store that cannot be reached is tried again, for as long as it takes
/// (3.0): what happens while the whole server is offline, and whether,
/// once it is back, things resync and all is
/// good.
///
/// It was not all good. Every failed try counted towards a pause, a server
/// that was down counted like keys that no longer match, and after three
/// tries background sync stopped until the app was started again or somebody
/// pressed "Sync now", with nothing said. A desktop left running through an
/// outage of half an hour stayed unsynced for days.
///
/// Now a try the store failed (it could not be reached, it answered with a
/// fault of its own, another device kept writing) sets the next try by
/// itself, later each time up to a quarter of an hour, and never gives up;
/// a network change tries at once; and the pause is left for what a person
/// has to do something about.

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

Future<Set<String>> _localHostIds(AppDatabase db) async => (await db.connectionsDao.getAll()).map((c) => c.id).toSet();

Future<Set<String>> _storeHostIds(MemoryStoreBackend backend, SecretKey dek) async {
  final pulled = await backend.pull();
  final data = await SyncService.decrypt(pulled.encryptedData, dek);
  return (data['connections'] as List).map((c) => (c as Map)['id'] as String).toSet();
}

/// A store the test can take away: while [down] is set, whatever is asked
/// of it fails with that. [failWrites] fails only what is written.
class _Store extends MemoryStoreBackend {
  _Store(super.store);

  Object? down;
  Object? failWrites;

  /// Fails what is fetched whole (a pull), while the store still says what
  /// it holds.
  Object? failPulls;

  /// While set, whatever is read waits for it: a try that is under way.
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
  Future<SyncPullResult> pull() {
    final failure = failPulls;
    if (failure != null) return Future.error(failure);
    return super.pull();
  }

  @override
  Future<String?> writeObject(Uint8List bytes, {String? ifMatchEtag, bool ifAbsent = false}) {
    writes++;
    final failure = down ?? failWrites;
    if (failure != null) return Future.error(failure);
    return super.writeObject(bytes, ifMatchEtag: ifMatchEtag, ifAbsent: ifAbsent);
  }
}

/// The timers the service sets, held by the test: none runs by itself.
class _Timers {
  final waiting = <_Timer>[];

  Timer call(Duration wait, void Function() then) {
    final timer = _Timer(this, wait, then);
    waiting.add(timer);
    return timer;
  }

  /// The wait of the one timer that is set.
  Duration get wait => waiting.single.wait;

  /// Lets the one timer that is set run.
  void fire() {
    final timer = waiting.single;
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
  const refused = SocketException('Connection refused');

  late SettingsService settings;
  late AppDatabase deviceA;
  late AppDatabase deviceB;
  late MemoryStore shared;
  late _Store store;
  late AutoSyncService sync;
  late _Timers timers;
  late DateTime now;
  late SecretKey dek;
  late SecretKey mek;
  late Uint8List salt;
  late Uint8List verHash;

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
    deviceA = AppDatabase.forTesting(NativeDatabase.memory());
    deviceB = AppDatabase.forTesting(NativeDatabase.memory());
    shared = MemoryStore();
    store = _Store(shared);
    timers = _Timers();
    now = DateTime(2026, 10, 8, 9);
    sync = AutoSyncService(
      syncDataService: memoryDataService(deviceA, storage, settings),
      settingsService: settings,
      secureStorage: storage,
      resolveBackend: () => store,
      clock: () => now,
      timer: timers.call,
    );
    await storage.write(key: 'sync_salt', value: base64Encode(salt));
    await sync.storeSyncCredentials(dek, verHash, argon2Params: fast);

    // The store holds host a1, and this device has synced it.
    await _addHost(deviceA, 'a1');
    final v1 = await store.push(
      data: await memoryDataService(deviceA, storage, settings).gatherAll(),
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
    await deviceA.close();
    await deviceB.close();
  });

  /// Waits for the try a timer or a network change started.
  Future<void> settled() async {
    await Future<void>.delayed(Duration.zero);
    while (sync.isSyncing) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    await Future<void>.delayed(Duration.zero);
  }

  /// Another device adds [host] and pushes it, by its own way to the store.
  Future<void> otherDevicePushes(String host) async {
    final theirs = MemoryStoreBackend(shared);
    final status = await theirs.getStatus();
    for (final id in await _storeHostIds(theirs, dek)) {
      if (!(await _localHostIds(deviceB)).contains(id)) await _addHost(deviceB, id);
    }
    await _addHost(deviceB, host);
    await theirs.push(
      data: await memoryDataService(deviceB, storage, settings).gatherAll(),
      dek: dek,
      salt: salt,
      verificationHash: verHash,
      expectedVersion: status.version,
      argon2Params: fast,
    );
  }

  group('a store that cannot be reached', () {
    test('is tried again and again, later each time up to a quarter of an hour, and sync is never paused', () async {
      store.down = refused;
      await sync.triggerSync();
      final waits = <Duration>[timers.wait];
      for (var i = 0; i < 9; i++) {
        timers.fire();
        await settled();
        waits.add(timers.wait);
      }
      expect(waits, const [
        Duration(seconds: 30),
        Duration(minutes: 1),
        Duration(minutes: 2),
        Duration(minutes: 5),
        Duration(minutes: 10),
        Duration(minutes: 15),
        Duration(minutes: 15),
        Duration(minutes: 15),
        Duration(minutes: 15),
        Duration(minutes: 15),
      ]);
      expect(waits, AutoSyncService.retryWaits + List.filled(4, AutoSyncService.retryWaits.last));
      expect(store.reads, 10, reason: 'every try asked the store');

      final said = sync.activity.value;
      expect(said.paused, isFalse, reason: 'nobody has to do anything');
      expect(said.retrying, isTrue);
      // The store here is one of the person's own (a WebDAV kind): what the
      // network said, and the code that says whose storage it is.
      expect(
        said.failure,
        ErrorCodes.withCode(
            describeNetworkError(refused, subject: gl10n.errSubjectSyncServer).message, ErrorCodes.syncStoreUnreachable),
      );
      expect(said.failure, endsWith('(ZS-1201)'));
      expect(sync.syncError.value, isNull, reason: 'no notice that sync has paused: it has not');
    });

    test('is not asked again before the wait is over, however often a sync is called for', () async {
      store.down = refused;
      await sync.triggerSync();
      expect(store.reads, 1);

      await sync.triggerSync();
      now = now.add(const Duration(seconds: 29));
      await sync.triggerSync();
      expect(store.reads, 1, reason: 'the wait is thirty seconds');
      expect(timers.waiting, hasLength(1), reason: 'and the try that waits is still the one');

      now = now.add(const Duration(seconds: 1));
      await sync.triggerSync();
      expect(store.reads, 2, reason: 'once the time is up, whatever calls for a sync gets one');
      expect(timers.wait, const Duration(minutes: 1), reason: 'and that try stands for the one that waited');
    });

    test('when it is back, the try that waited brings what another device pushed and sends what changed here',
        () async {
      store.down = refused;
      await sync.triggerSync();

      // Meanwhile: a change here, and one from another device.
      await _addHost(deviceA, 'a2');
      await settings.setSyncDirty(true);
      await otherDevicePushes('b1');
      expect(await _localHostIds(deviceA), {'a1', 'a2'});

      store.down = null;
      timers.fire();
      await settled();

      expect(await _localHostIds(deviceA), {'a1', 'a2', 'b1'});
      expect(await _storeHostIds(MemoryStoreBackend(shared), dek), {'a1', 'a2', 'b1'});
      expect(settings.syncDirty, isFalse);
      final said = sync.activity.value;
      expect(said.failure, isNull);
      expect(said.retrying, isFalse);
      expect(said.paused, isFalse);
      expect(timers.waiting, isEmpty, reason: 'nothing is left to try');

      // And the next failure starts from the short wait again.
      store.down = refused;
      await sync.triggerSync();
      expect(timers.wait, const Duration(seconds: 30));
    });

    test('a network change tries at once, and only when a try is waiting', () async {
      sync.networkChanged();
      await settled();
      expect(store.reads, 0, reason: 'with nothing waiting, a network change is no reason to sync');

      store.down = refused;
      await sync.triggerSync();
      expect(store.reads, 1);
      sync.networkChanged();
      await settled();
      expect(store.reads, 2, reason: 'not the end of the wait: now');
      expect(timers.wait, const Duration(minutes: 1), reason: 'still down: the second failure in a row');

      store.down = null;
      sync.networkChanged();
      await settled();
      expect(sync.activity.value.failure, isNull);
      expect(timers.waiting, isEmpty);
    });

    test('"Sync now" does not wait, and takes the place of the try that did', () async {
      store.down = refused;
      await sync.triggerSync();
      expect(timers.waiting, hasLength(1));

      store.down = null;
      await sync.syncNowManual();
      expect(timers.waiting, isEmpty);
      expect(sync.activity.value.failure, isNull);
      expect(sync.activity.value.retrying, isFalse);
    });

    test('the wait is over when its timer says so, whatever the clock says by then', () async {
      store.down = refused;
      await sync.triggerSync();
      // The clock is put back an hour (a time zone, a correction).
      now = now.subtract(const Duration(hours: 1));
      timers.fire();
      await settled();
      expect(store.reads, 2);
    });

    test('in automatic mode no wait is longer than the time between two checks', () async {
      await settings.setSyncIntervalMinutes(5);
      store.down = refused;
      await sync.triggerSync();
      final waits = <Duration>[timers.wait];
      for (var i = 0; i < 5; i++) {
        timers.fire();
        await settled();
        waits.add(timers.wait);
      }
      expect(waits, const [
        Duration(seconds: 30),
        Duration(minutes: 1),
        Duration(minutes: 2),
        Duration(minutes: 5),
        Duration(minutes: 5),
        Duration(minutes: 5),
      ]);
    });

    test('where sync is on every change there is no time between checks to hold a wait to', () async {
      await settings.setSyncMode('instant');
      await settings.setSyncIntervalMinutes(5);
      store.down = refused;
      await sync.triggerSync();
      for (var i = 0; i < 5; i++) {
        timers.fire();
        await settled();
      }
      expect(timers.wait, const Duration(minutes: 15));
    });

    test('a success of any kind ends the count: with something sent, with nothing to send, with nothing new to send',
        () async {
      Future<void> failTwice() async {
        store.down = refused;
        await sync.triggerSync();
        timers.fire();
        await settled();
        expect(timers.wait, const Duration(minutes: 1));
        store.down = null;
      }

      // Nothing to send: the store is asked, and this device is current.
      await failTwice();
      timers.fire();
      await settled();
      expect(sync.activity.value.failure, isNull);
      store.down = refused;
      await sync.triggerSync();
      expect(timers.wait, const Duration(seconds: 30), reason: 'after a check that found nothing to do');
      timers.fire();
      await settled();
      store.down = null;
      timers.fire();
      await settled();

      // Marked as changed, but what would be sent is what was last synced.
      await sync.syncNowManual();
      await failTwice();
      await settings.setSyncDirty(true);
      timers.fire();
      await settled();
      expect(settings.syncDirty, isFalse);
      store.down = refused;
      await sync.triggerSync();
      expect(timers.wait, const Duration(seconds: 30), reason: 'after a try that had nothing new to send');
    });

    test('where sync is by hand, a "Sync now" that fails sets no try of its own', () async {
      await settings.setSyncMode('manual');
      store.down = refused;
      await expectLater(sync.syncNowManual(), throwsA(isA<SyncException>()));
      expect(timers.waiting, isEmpty);
      expect(sync.activity.value.retrying, isFalse);
      expect(sync.activity.value.paused, isFalse);
      expect(sync.activity.value.failure, isNotNull);
    });
  });

  group('the device\'s network changing, heard by the service while sync runs by itself', () {
    late StreamController<bool> network;
    late AutoSyncService listening;

    setUp(() {
      network = StreamController<bool>.broadcast();
      listening = AutoSyncService(
        syncDataService: memoryDataService(deviceA, storage, settings),
        settingsService: settings,
        secureStorage: storage,
        resolveBackend: () => store,
        clock: () => now,
        timer: timers.call,
        networkUp: () => network.stream,
      );
    });

    tearDown(() async {
      listening.dispose();
      await network.close();
    });

    Future<void> quiet() async {
      await Future<void>.delayed(Duration.zero);
      while (listening.isSyncing) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      await Future<void>.delayed(Duration.zero);
    }

    test('a network that came back lets the waiting try go at once; one that went away does nothing', () async {
      store.down = refused;
      listening.startAutoSync();
      await quiet();
      expect(store.reads, 1, reason: 'the try at the start');
      expect(timers.waiting, hasLength(1));

      network.add(false);
      await quiet();
      expect(store.reads, 1, reason: 'no network is no moment to try');

      network.add(true);
      await quiet();
      expect(store.reads, 2);

      store.down = null;
      network.add(true);
      await quiet();
      expect(listening.activity.value.failure, isNull);
      expect(timers.waiting, isEmpty);
      final reads = store.reads;
      network.add(true);
      await quiet();
      expect(store.reads, reads, reason: 'with nothing waiting, a network change is no reason to sync');
    });

    test('nothing listens once sync is stopped, and nothing where sync is by hand', () async {
      listening.startAutoSync();
      await quiet();
      expect(network.hasListener, isTrue);
      listening.stopAutoSync();
      await quiet();
      expect(network.hasListener, isFalse);

      await settings.setSyncMode('manual');
      listening.startAutoSync();
      await quiet();
      expect(network.hasListener, isFalse);
    });

    test('started twice, it listens once', () async {
      listening.startAutoSync();
      await quiet();
      listening.startAutoSync();
      await quiet();
      store.down = refused;
      await listening.triggerSync();
      final reads = store.reads;
      network.add(true);
      await quiet();
      expect(store.reads, reads + 1, reason: 'one try for one change, not one for every time sync was started');
    });

    test('a system that cannot say how its network stands: nothing breaks, and the wait runs its time', () async {
      store.down = refused;
      listening.startAutoSync();
      await quiet();
      network.addError(StateError('no such plugin on this system'));
      await quiet();
      expect(timers.waiting, hasLength(1));
      timers.fire();
      await quiet();
      expect(store.reads, 2);
    });
  });

  group('what counts as the store failing', () {
    for (final (name, failure) in <(String, Object)>[
      ('the connection is refused', refused),
      ('no answer in time', TimeoutException('no answer', const Duration(seconds: 30))),
      ('the connection breaks', http.ClientException('Connection closed before full header was received')),
      ('the server answers with a fault of its own', const SyncException('Status check failed: Server error (HTTP 503)')),
      ('its certificate cannot be verified', const HandshakeException('CERTIFICATE_VERIFY_FAILED')),
    ]) {
      test('$name: tried again, not paused', () async {
        store.down = failure;
        for (var i = 0; i < 4; i++) {
          if (i == 0) {
            await sync.triggerSync();
          } else {
            timers.fire();
            await settled();
          }
        }
        expect(sync.activity.value.paused, isFalse);
        expect(sync.activity.value.retrying, isTrue);
        expect(store.reads, 4);
        expect(timers.wait, const Duration(minutes: 5));
      });
    }

    test('their own server answering with a fault: its words, with the code that says whose storage it is',
        () async {
      store.down = const SyncException('Status check failed: Server error (HTTP 503)');
      await sync.triggerSync();
      expect(sync.activity.value.failure, 'Status check failed: Server error (HTTP 503) (ZS-1201)');
      expect(sync.activity.value.retrying, isTrue);
    });

    test('what the store says in so many words is said as it was, and is still the store failing', () async {
      store.down = const SyncException('No sync data found');
      await sync.triggerSync();
      expect(sync.activity.value.failure, 'No sync data found');
      expect(sync.activity.value.retrying, isTrue);
    });

    test('what is written fails though what is read does not: tried again', () async {
      await _addHost(deviceA, 'a2');
      await settings.setSyncDirty(true);
      store.failWrites = refused;
      await sync.triggerSync();
      expect(store.writes, 1);
      expect(sync.activity.value.retrying, isTrue);
      expect(sync.activity.value.paused, isFalse);
      expect(settings.syncDirty, isTrue, reason: 'the change still waits to go');

      store.failWrites = null;
      timers.fire();
      await settled();
      expect(await _storeHostIds(MemoryStoreBackend(shared), dek), {'a1', 'a2'});
      expect(settings.syncDirty, isFalse);
    });

    test('the store says it holds something newer, and fetching it fails: tried again', () async {
      await otherDevicePushes('b1');
      store.failPulls = refused;
      for (var i = 0; i < 4; i++) {
        if (i == 0) {
          await sync.triggerSync();
        } else {
          timers.fire();
          await settled();
        }
      }
      expect(sync.activity.value.paused, isFalse);
      expect(sync.activity.value.retrying, isTrue);

      store.failPulls = null;
      timers.fire();
      await settled();
      expect(await _localHostIds(deviceA), {'a1', 'b1'});
    });

    test('something failing on this device is not the store failing: no try is set, and three of them pause sync',
        () async {
      // The store answers; what cannot be done is reading this device's own
      // data to send it.
      await settings.setSyncDirty(true);
      await deviceA.close();
      await sync.triggerSync();
      expect(store.reads, 1, reason: 'the store was asked, and answered');
      // Said as what it is: not "couldn't reach the sync server", which is
      // what every failure was called until this was held.
      expect(
        sync.activity.value.failure,
        ErrorCodes.withCode(gl10n.syncFailedOnDevice(gl10n.accountSyncNow), ErrorCodes.syncFailedHere),
      );
      expect(sync.activity.value.failure, isNot(contains(gl10n.errSubjectSyncServer)));
      expect(sync.activity.value.retrying, isFalse);
      expect(timers.waiting, isEmpty);
      expect(sync.activity.value.paused, isFalse);
      await sync.triggerSync();
      await sync.triggerSync();
      expect(sync.activity.value.paused, isTrue);
    });

    test('another device writing first, twice in one try: tried again later, not counted towards a pause', () async {
      await _addHost(deviceA, 'a2');
      await settings.setSyncDirty(true);
      store.failWrites = const SyncConflictException(serverVersion: 9, expectedVersion: 1);
      for (var i = 0; i < 4; i++) {
        if (i == 0) {
          await sync.triggerSync();
        } else {
          timers.fire();
          await settled();
        }
      }
      expect(sync.activity.value.paused, isFalse);
      expect(sync.activity.value.retrying, isTrue);
      // Said as what it is, in the person's language, with its code; what the
      // store answered is kept for the details. (It was "Version conflict:
      // server is at v9, expected v1. Pull and retry.")
      expect(sync.activity.value.failure, '${gl10n.syncOtherDeviceWroteFirst} (ZS-1203)');
      expect(sync.activity.value.failure, isNot(contains('conflict')));
      final told = await sync.syncNowManual().then<Object?>((_) => null, onError: (Object e) => e);
      expect(told, isA<SyncException>());
      expect((told! as SyncException).message, '${gl10n.syncOtherDeviceWroteFirst} (ZS-1203)');
      expect((told as SyncException).detail, contains('Version conflict: server is at v9, expected v1'));
    });

    test('every language has its own words for two devices syncing at the same moment', () {
      final english = lookupAppLocalizations(const Locale('en')).syncOtherDeviceWroteFirst;
      for (final locale in AppLocalizations.supportedLocales) {
        final said = lookupAppLocalizations(locale).syncOtherDeviceWroteFirst;
        expect(said.trim(), isNotEmpty, reason: '$locale');
        expect(said, isNot(contains('conflict')), reason: '$locale');
        if (locale.languageCode != 'en') expect(said, isNot(english), reason: '$locale');
      }
    });
  });

  group('what a person has to do something about still pauses sync', () {
    test('keys that are no longer the account\'s: paused at once, and no try is left waiting', () async {
      // A try was waiting after the store could not be reached...
      store.down = refused;
      await sync.triggerSync();
      expect(timers.waiting, hasLength(1));
      // ...and when it is reached, it refuses this device's keys.
      store.down = SyncKeysMismatchException(gl10n.syncKeysNoLongerMatch);
      timers.fire();
      await settled();
      expect(sync.activity.value.paused, isTrue);
      expect(sync.activity.value.retrying, isFalse);
      expect(sync.syncError.value, gl10n.syncKeysNoLongerMatch);
      expect(timers.waiting, isEmpty);
      final asked = store.reads;
      await sync.triggerSync();
      sync.networkChanged();
      await settled();
      expect(store.reads, asked, reason: 'paused: the store is left alone until somebody acts');
    });

    test('changes that cannot be merged here: three tries, then paused, with no try of its own in between',
        () async {
      // What the store holds is from a build newer than this one.
      final theirs = MemoryStoreBackend(shared);
      final status = await theirs.getStatus();
      final newer = await memoryDataService(deviceA, storage, settings).gatherAll();
      newer['schema_version'] = 9999;
      await theirs.push(
        data: newer,
        dek: dek,
        salt: salt,
        verificationHash: verHash,
        expectedVersion: status.version,
        argon2Params: fast,
      );

      await sync.triggerSync();
      expect(sync.activity.value.paused, isFalse);
      expect(sync.activity.value.retrying, isFalse, reason: 'the store did not fail: no wait is set');
      expect(timers.waiting, isEmpty);
      await sync.triggerSync();
      await sync.triggerSync();
      expect(sync.activity.value.paused, isTrue);
      expect(sync.syncError.value, gl10n.syncMergeFailed);
      final asked = store.reads;
      await sync.triggerSync();
      expect(store.reads, asked);
    });
  });

  group('nothing is tried again once there is nothing to try', () {
    test('sync stopped: the try that waited is forgotten, and the count with it', () async {
      store.down = refused;
      await sync.triggerSync();
      timers.fire();
      await settled();
      expect(timers.wait, const Duration(minutes: 1));

      sync.stopAutoSync();
      expect(timers.waiting, isEmpty);

      await sync.triggerSync();
      expect(timers.wait, const Duration(seconds: 30), reason: 'a new start');
    });

    test('sync turned off on this device', () async {
      store.down = refused;
      await sync.triggerSync();
      await sync.clearSyncCredentials();
      expect(timers.waiting, isEmpty);
      expect(sync.activity.value.retrying, isFalse);
    });

    test('a try that was under way when the deletion of the account began sets no other', () async {
      store
        ..down = refused
        ..held = Completer<void>();
      unawaited(sync.triggerSync());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(sync.isSyncing, isTrue);
      final suspended = sync.suspend();
      store.held!.complete();
      await suspended;
      expect(timers.waiting, isEmpty, reason: 'or it would upload the data of this device again in the middle of it');
    });

    test('a try that was under way when the service went away sets no other', () async {
      final gone = AutoSyncService(
        syncDataService: memoryDataService(deviceA, storage, settings),
        settingsService: settings,
        secureStorage: storage,
        resolveBackend: () => store,
        clock: () => now,
        timer: timers.call,
      );
      store
        ..down = refused
        ..held = Completer<void>();
      unawaited(gone.triggerSync());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(gone.isSyncing, isTrue);
      gone.dispose();
      store.held!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      while (gone.isSyncing) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(timers.waiting, isEmpty);
    });

    test('the account being deleted', () async {
      store.down = refused;
      await sync.triggerSync();
      await sync.suspend();
      expect(timers.waiting, isEmpty);
      sync.networkChanged();
      await settled();
      expect(store.reads, 1);
    });
  });

  // Instant mode sends a change made here within a second; another device's
  // changes came only at start, back in front or with a change made here
  // (the 3.0 docs check). It looks for them on a timer too.
  group('instant mode', () {
    Future<void> settledAll() async {
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(Duration.zero);
        while (sync.isSyncing) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
      }
    }

    test("brings another device's change in every five minutes, with nothing changed here", () async {
      await settings.setSyncMode('instant');
      sync.startAutoSync();
      await settledAll();
      expect(timers.waiting.map((t) => t.wait), [AutoSyncService.instantPullEvery]);
      expect(AutoSyncService.instantPullEvery, const Duration(minutes: 5));

      await otherDevicePushes('b1');
      expect(await _localHostIds(deviceA), {'a1'});
      timers.fire();
      await settledAll();
      expect(await _localHostIds(deviceA), {'a1', 'b1'});
      expect(timers.waiting.map((t) => t.wait), [AutoSyncService.instantPullEvery], reason: 'and again after');
    });

    test('ends with the mode, a stop or a pause', () async {
      await settings.setSyncMode('instant');
      sync.startAutoSync();
      await settledAll();
      sync.stopAutoSync();
      expect(timers.waiting, isEmpty);

      sync.startAutoSync();
      await settledAll();
      await settings.setSyncMode('manual');
      sync.startAutoSync();
      expect(timers.waiting, isEmpty);

      await settings.setSyncMode('instant');
      sync.startAutoSync();
      await settledAll();
      await sync.pause();
      expect(timers.waiting.where((t) => t.wait == AutoSyncService.instantPullEvery), isEmpty);
    });
  });
}
