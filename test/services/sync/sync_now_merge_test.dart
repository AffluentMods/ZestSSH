// Real Argon2id key derivation (the weakest profile deriveKey accepts),
// done once for the file. Allow for a machine busy with the whole suite.
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync/zest_server_backend.dart';
import 'package:zestssh/services/sync_service.dart';

import '../../helpers/memory_store_backend.dart';

/// Profile > "Sync now" used to upload this device's data straight over the
/// store without merging what another device had pushed, so that device's
/// edits were lost (and it then pulled the older copy too). "Sync now" now
/// runs the background cycle's pull, merge and push. These pin it: the union
/// survives, it runs in Manual sync mode, and a store it cannot read is
/// reported as an error instead of a success.

Future<void> _addHost(AppDatabase db, String id) =>
    db.connectionsDao.insertConnection(ConnectionsCompanion(
      id: Value(id),
      label: Value('host-$id'),
      host: Value('$id.example.com'),
      port: const Value(22),
      protocol: const Value('ssh'),
      createdAt: Value(DateTime.utc(2026, 9, 22)),
      updatedAt: Value(DateTime.utc(2026, 9, 22)),
    ));

Future<Set<String>> _localHostIds(AppDatabase db) async =>
    (await db.connectionsDao.getAll()).map((c) => c.id).toSet();

Future<Set<String>> _storeHostIds(
    MemoryStoreBackend backend, SecretKey dek) async {
  final pulled = await backend.pull();
  final data = await SyncService.decrypt(pulled.encryptedData, dek);
  return (data['connections'] as List)
      .map((c) => (c as Map)['id'] as String)
      .toSet();
}

void main() {
  // Two in-memory databases stand in for two devices; they never share an
  // executor, so drift's multiple-instances warning does not apply.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  // The weakest profile deriveKey accepts, to keep the test quick.
  const fast = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
  const storage = FlutterSecureStorage();

  late SettingsService settings;
  late AppDatabase deviceA;
  late AppDatabase deviceB;
  late MemoryStoreBackend backend;
  late AutoSyncService autoSyncA;
  late SecretKey dek;
  late SecretKey mek;
  late Uint8List salt;
  late Uint8List verHash;

  // The account's keys. Deriving them is the slow part, and no test changes
  // them, so it happens once: under a full-suite run a per-test derivation
  // could outlast the timeout and leave a half-finished setUp writing into
  // the next test's databases.
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
    deviceA = AppDatabase.forTesting(NativeDatabase.memory());
    deviceB = AppDatabase.forTesting(NativeDatabase.memory());
    backend = MemoryStoreBackend(MemoryStore());

    // Device A holds the account's keys, as after "Join" or "Sync now".
    autoSyncA = AutoSyncService(
      syncDataService: memoryDataService(deviceA, storage, settings),
      settingsService: settings,
      secureStorage: storage,
      resolveBackend: () => backend,
    );
    await storage.write(key: 'sync_salt', value: base64Encode(salt));
    await autoSyncA.storeSyncCredentials(dek, verHash, argon2Params: fast);

    // v1: the store holds host a1, and device A has synced it.
    await _addHost(deviceA, 'a1');
    final v1 = await backend.push(
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

    // v2: another device adds b1 and pushes. Device A has not pulled it.
    await _addHost(deviceB, 'a1');
    await _addHost(deviceB, 'b1');
    await backend.push(
      data: await memoryDataService(deviceB, storage, settings).gatherAll(),
      dek: dek,
      salt: salt,
      verificationHash: verHash,
      expectedVersion: v1.version,
      argon2Params: fast,
    );

    // Meanwhile device A adds a2 locally.
    await _addHost(deviceA, 'a2');
  });

  tearDown(() async {
    autoSyncA.dispose();
    await deviceA.close();
    await deviceB.close();
  });

  test('Sync now merges the other device\'s push before uploading', () async {
    final version = await autoSyncA.syncNowManual();

    expect(version, 3);
    expect(await _storeHostIds(backend, dek), {'a1', 'a2', 'b1'},
        reason: 'the store keeps both devices\' hosts');
    expect(await _localHostIds(deviceA), {'a1', 'a2', 'b1'},
        reason: 'device A received the other device\'s host');
  });

  test('Sync now runs when sync is set to Manual', () async {
    await settings.setSyncMode('manual');

    // The background trigger respects the mode and does nothing...
    await autoSyncA.triggerSync();
    expect(await _storeHostIds(backend, dek), {'a1', 'b1'});

    // ...while Sync now is an explicit request and runs anyway.
    await autoSyncA.syncNowManual();
    expect(await _storeHostIds(backend, dek), {'a1', 'a2', 'b1'});
  });

  group('keys the account no longer has (the server\'s 403 "Sync verification failed")', () {
    test('are told from every other refusal', () {
      expect(ZestServerBackend.keysDoNotMatch(403, '{"error":"Sync verification failed"}'), isTrue);
      expect(ZestServerBackend.keysDoNotMatch(403, '{"error":"Refused","code":"SYNC_VERIFICATION_FAILED"}'), isTrue);
      expect(ZestServerBackend.keysDoNotMatch(403, '{"error":"Forbidden"}'), isFalse, reason: 'a sign-in problem');
      expect(ZestServerBackend.keysDoNotMatch(500, '{"error":"Sync verification failed"}'), isFalse);
      expect(ZestServerBackend.keysDoNotMatch(403, '<html>nope</html>'), isFalse);
      expect(ZestServerBackend.keysDoNotMatch(403, '["Sync verification failed"]'), isFalse);
    });

    test('a push the server refuses for them says so in the app\'s words, and is sent once', () async {
      PackageInfo.setMockInitialValues(
          appName: 'ZestSSH', packageName: 'demo', version: '3.0.0', buildNumber: '1', buildSignature: '');
      var sent = 0;
      ZestServerBackend.debugHttpClient = MockClient((request) async {
        sent++;
        return http.Response('{"error":"Sync verification failed"}', 403);
      });
      addTearDown(() => ZestServerBackend.debugHttpClient = null);
      final server = ZestServerBackend(
        baseUrl: 'https://sync.northwind.example/v1',
        staticToken: 'demo-token',
        requiresEntitlement: false,
        kind: SyncBackendKind.custom,
      );
      await expectLater(
        server.push(data: {'connections': const <dynamic>[]}, dek: dek, salt: salt, verificationHash: verHash, argon2Params: fast),
        throwsA(isA<SyncKeysMismatchException>().having((e) => e.message, 'message', gl10n.syncKeysNoLongerMatch)),
      );
      expect(sent, 1);
    });

    test('pause sync and say why, and the store is not asked again until the person acts', () async {
      final refusing = _RefusingStore(backend.store)..refuse = SyncKeysMismatchException(gl10n.syncKeysNoLongerMatch);
      backend = refusing;
      await expectLater(autoSyncA.syncNowManual(), throwsA(isA<SyncKeysMismatchException>()));
      expect(autoSyncA.syncError.value, gl10n.syncKeysNoLongerMatch);
      expect(autoSyncA.activity.value.paused, isTrue);
      final asked = refusing.asked;
      expect(asked, greaterThan(0));
      await autoSyncA.triggerSync();
      await autoSyncA.triggerSync();
      expect(refusing.asked, asked, reason: 'paused: not sent again on every cycle');
    });

    test('every language says it its own way, naming the two buttons', () {
      final en = lookupAppLocalizations(const Locale('en'));
      for (final locale in AppLocalizations.supportedLocales) {
        final l = lookupAppLocalizations(locale);
        expect(l.syncKeysNoLongerMatch, contains(l.accountSyncNow), reason: '$locale');
        expect(l.syncKeysNoLongerMatch, contains(l.accountRestore), reason: '$locale');
        if (locale.languageCode != 'en') expect(l.syncKeysNoLongerMatch, isNot(en.syncKeysNoLongerMatch), reason: '$locale');
      }
    });
  });

  // What the notice of a pause goes by (3.0, a reported
  // bug): where the sync password proved here again ends the pause, it
  // offers the account page's "Sync now"; and a run somebody asked for is
  // answered on the screen it was asked on, not a second time by the app.
  group('cloud sync reset from another device (the server\'s 426 with the code SYNC_WAS_RESET)', () {
    ZestServerBackend serverAnswering(http.Response answer, void Function() onSent) {
      PackageInfo.setMockInitialValues(
          appName: 'ZestSSH', packageName: 'demo', version: '3.0.0', buildNumber: '1', buildSignature: '');
      ZestServerBackend.debugHttpClient = MockClient((request) async {
        onSent();
        return answer;
      });
      addTearDown(() => ZestServerBackend.debugHttpClient = null);
      return ZestServerBackend(
        baseUrl: 'https://sync.northwind.example/v1',
        staticToken: 'demo-token',
        requiresEntitlement: false,
        kind: SyncBackendKind.custom,
      );
    }

    test('is told from every other answer, by its code', () {
      expect(
          ZestServerBackend.wasReset(426, '{"error":"Cloud sync was reset on another device.","code":"SYNC_WAS_RESET"}'),
          isTrue);
      expect(
          ZestServerBackend.wasReset(
              426, '{"error":"Cloud Sync must be set up again on this version.","code":"REENROLL_REQUIRED"}'),
          isFalse);
      expect(ZestServerBackend.wasReset(426, '{"error":"Cloud sync was reset on another device."}'), isFalse,
          reason: 'by its code, not its words');
      expect(ZestServerBackend.wasReset(409, '{"code":"SYNC_WAS_RESET"}'), isFalse);
      expect(ZestServerBackend.wasReset(426, '<html>nope</html>'), isFalse);
      expect(ZestServerBackend.wasReset(426, '["SYNC_WAS_RESET"]'), isFalse);
    });

    test('a push the server answers with it says so in the app\'s words, and is sent once', () async {
      var sent = 0;
      final server = serverAnswering(
        http.Response('{"error":"Cloud sync was reset on another device.","code":"SYNC_WAS_RESET"}', 426),
        () => sent++,
      );
      await expectLater(
        server.push(data: {'connections': const <dynamic>[]}, dek: dek, salt: salt, verificationHash: verHash, argon2Params: fast),
        throwsA(isA<SyncWasResetException>().having((e) => e.message, 'message', gl10n.syncWasReset)),
      );
      expect(sent, 1);
      expect(gl10n.syncWasReset, contains('Nothing on this device was removed'));
    });

    test('another 426 is no reset: the data is not in the store, said in the app\'s words, with what the server '
        'said kept for the details', () async {
      final server = serverAnswering(
        http.Response('{"error":"Cloud Sync must be set up again on this version.","code":"REENROLL_REQUIRED"}', 426),
        () {},
      );
      await expectLater(
        server.push(data: {'connections': const <dynamic>[]}, dek: dek, salt: salt, verificationHash: verHash, argon2Params: fast),
        throwsA(allOf(
          isA<SyncSetupRequiredException>()
              .having((e) => e.message, 'message', gl10n.syncStoreDataMissing)
              .having((e) => e.detail, 'detail', contains('Cloud Sync must be set up again on this version.')),
          isNot(isA<SyncWasResetException>()),
        )),
      );
    });

    test('pauses sync, and what ends the pause is setting sync up again, not a password', () async {
      await settings.setSyncMode('auto');
      final refusing = _RefusingStore(backend.store)..refuse = SyncWasResetException(gl10n.syncWasReset);
      backend = refusing;
      await autoSyncA.triggerSync();
      expect(autoSyncA.syncError.value, gl10n.syncWasReset);
      expect(autoSyncA.activity.value.paused, isTrue);
      expect(autoSyncA.syncErrorNeedsSetup, isTrue);
      expect(autoSyncA.syncErrorNeedsPassword, isFalse);
      expect(autoSyncA.syncErrorFromManualRun, isFalse);
      // Paused: the store is not asked again on the next cycle.
      final asked = refusing.asked;
      await autoSyncA.triggerSync();
      expect(refusing.asked, asked);

      // Once a run goes through, nothing is said and no kind stands.
      refusing.refuse = null;
      await autoSyncA.syncNowManual();
      expect(autoSyncA.syncError.value, isNull);
      expect(autoSyncA.syncErrorNeedsSetup, isFalse);
    });
  });

  test('past the devices ZestSSH Cloud syncs for one person: the pause ends with a device signed out, not a new '
      'setup and not a password', () async {
    await settings.setSyncMode('auto');
    final refusing = _RefusingStore(backend.store)..refuse = SyncCloudDeviceLimitException(gl10n.syncCloudDeviceLimit);
    backend = refusing;
    await autoSyncA.triggerSync();
    expect(autoSyncA.syncError.value, gl10n.syncCloudDeviceLimit);
    expect(autoSyncA.syncErrorNeedsDeviceRoom, isTrue);
    expect(autoSyncA.syncErrorNeedsSetup, isFalse, reason: 'setting sync up again would not help');
    expect(autoSyncA.syncErrorNeedsPassword, isFalse);
    refusing.refuse = null;
    await autoSyncA.syncNowManual();
    expect(autoSyncA.syncErrorNeedsDeviceRoom, isFalse);
  });

  group('what kind of pause it is, for whoever says it', () {
    Future<void> rekeyTheStore() async {
      final status = await backend.getStatus();
      await backend.push(
        data: await memoryDataService(deviceB, storage, settings).gatherAll(),
        dek: SyncService.generateDek(),
        salt: salt,
        verificationHash: verHash,
        expectedVersion: status.version,
        argon2Params: fast,
      );
    }

    test('while nothing is said, neither kind stands', () {
      expect(autoSyncA.syncError.value, isNull);
      expect(autoSyncA.syncErrorNeedsPassword, isFalse);
      expect(autoSyncA.syncErrorNeedsSetup, isFalse);
      expect(autoSyncA.syncErrorFromManualRun, isFalse);
    });

    test('keys the store refuses, in a run somebody asked for: the sync password ends it, and the asker says it', () async {
      backend = _RefusingStore(backend.store)..refuse = SyncKeysMismatchException(gl10n.syncKeysNoLongerMatch);
      await expectLater(autoSyncA.syncNowManual(), throwsA(isA<SyncKeysMismatchException>()));
      expect(autoSyncA.syncErrorNeedsPassword, isTrue);
      expect(autoSyncA.syncErrorNeedsSetup, isFalse, reason: 'the vault is there: it is joined, not made again');
      expect(autoSyncA.syncErrorFromManualRun, isTrue);
    });

    test('the same in the background: the sync password ends it, and nobody asked', () async {
      await settings.setSyncMode('auto');
      backend = _RefusingStore(backend.store)..refuse = SyncKeysMismatchException(gl10n.syncKeysNoLongerMatch);
      await autoSyncA.triggerSync();
      expect(autoSyncA.syncError.value, gl10n.syncKeysNoLongerMatch);
      expect(autoSyncA.syncErrorNeedsPassword, isTrue);
      expect(autoSyncA.syncErrorFromManualRun, isFalse);
    });

    test('a store this device cannot read is the same kind: its keys are not the account\'s', () async {
      await rekeyTheStore();
      await expectLater(
        autoSyncA.syncNowManual(),
        throwsA(isA<SyncKeysMismatchException>().having((e) => e.message, 'message', gl10n.syncCannotDecrypt)),
      );
      expect(autoSyncA.syncErrorNeedsPassword, isTrue);
      expect(autoSyncA.syncErrorFromManualRun, isTrue);
    });

    test('and in the background', () async {
      await settings.setSyncMode('auto');
      await rekeyTheStore();
      await autoSyncA.triggerSync();
      expect(autoSyncA.syncError.value, gl10n.syncCannotDecrypt);
      // What failed, as the check of the encryption said it, for the details.
      expect(
          autoSyncA.syncErrorDetail,
          'Decryption failed - sync data may be corrupted or tampered with. '
          'If this persists, try restoring from a backup. (SecretBoxAuthenticationError)');
      expect(autoSyncA.syncErrorNeedsPassword, isTrue);
      expect(autoSyncA.syncErrorFromManualRun, isFalse);
    });

    test('a store that is not set up is not ended by the password: sync is set up again', () async {
      backend = _RefusingStore(backend.store)..refuse = SyncSetupRequiredException(gl10n.syncNowNotSetUp);
      await expectLater(autoSyncA.syncNowManual(), throwsA(isA<SyncSetupRequiredException>()));
      expect(autoSyncA.syncError.value, gl10n.syncNowNotSetUp);
      expect(autoSyncA.syncErrorNeedsPassword, isFalse);
      expect(autoSyncA.syncErrorNeedsSetup, isTrue);
      expect(autoSyncA.syncErrorFromManualRun, isTrue);
    });

    test('nor is a merge that fails', () async {
      await settings.setSyncMode('auto');
      final status = await backend.getStatus();
      await backend.push(
        data: {'schema_version': 99, 'connections': const <dynamic>[], 'identities': const <dynamic>[]},
        dek: dek,
        salt: salt,
        verificationHash: verHash,
        expectedVersion: status.version,
        argon2Params: fast,
      );
      await autoSyncA.triggerSync();
      expect(autoSyncA.syncError.value, gl10n.syncMergeFailed);
      expect(autoSyncA.syncErrorNeedsPassword, isFalse);
      expect(autoSyncA.syncErrorNeedsSetup, isFalse);
      expect(autoSyncA.syncErrorFromManualRun, isFalse);
    });

    test('nor is a store that says it holds more than sync data can be', () async {
      backend = _BloatedStore(backend.store);
      await expectLater(
        autoSyncA.syncNowManual(),
        throwsA(isA<SyncException>().having((e) => e.message, 'message', gl10n.syncTooLargeRefused)),
      );
      expect(autoSyncA.syncError.value, gl10n.syncTooLargeRefused);
      expect(autoSyncA.syncErrorDetail, contains('refused'));
      expect(autoSyncA.syncErrorNeedsPassword, isFalse);
      expect(autoSyncA.syncErrorNeedsSetup, isFalse);
      expect(autoSyncA.syncErrorFromManualRun, isTrue);
    });

    test('once a run goes through and nothing is said, neither kind stands', () async {
      final refusing = _RefusingStore(backend.store)..refuse = SyncKeysMismatchException(gl10n.syncKeysNoLongerMatch);
      backend = refusing;
      await expectLater(autoSyncA.syncNowManual(), throwsA(isA<SyncKeysMismatchException>()));
      expect(autoSyncA.syncErrorNeedsPassword, isTrue);
      refusing.refuse = null;
      await autoSyncA.syncNowManual();
      expect(autoSyncA.syncError.value, isNull);
      expect(autoSyncA.syncErrorNeedsPassword, isFalse);
      expect(autoSyncA.syncErrorNeedsSetup, isFalse);
      expect(autoSyncA.syncErrorFromManualRun, isFalse);
    });
  });

  test('Sync now surfaces a key mismatch instead of claiming success',
      () async {
    // Another device re-keyed the store: A's cached key can't read it.
    final otherDek = SyncService.generateDek();
    final status = await backend.getStatus();
    await backend.push(
      data: {'connections': const <dynamic>[], 'identities': const <dynamic>[]},
      dek: otherDek,
      salt: salt,
      verificationHash: verHash,
      expectedVersion: status.version,
      argon2Params: fast,
    );

    await expectLater(
        autoSyncA.syncNowManual(), throwsA(isA<SyncException>()));
    expect(await _localHostIds(deviceA), {'a1', 'a2'},
        reason: 'nothing was merged from a store it cannot read');
  });

  group('what the status shows', () {
    test('each run says it is running, then that it finished', () async {
      final seen = <SyncActivity>[];
      void record() => seen.add(autoSyncA.activity.value);
      autoSyncA.activity.addListener(record);
      addTearDown(() => autoSyncA.activity.removeListener(record));

      await autoSyncA.syncNowManual();
      expect(seen.map((a) => a.running), contains(true));
      final end = autoSyncA.activity.value;
      expect(end.running, isFalse);
      expect(end.configured, isTrue);
      expect(end.failure, isNull);
      expect(end.paused, isFalse);
    });

    test('a check that finds everything current counts as synced', () async {
      await autoSyncA.syncNowManual();
      final old = DateTime.now().subtract(const Duration(days: 2));
      await settings.setLastSyncTime(old);
      await settings.setSyncDirty(false);

      await autoSyncA.syncNowManual(); // nothing new either way
      expect(settings.lastSyncTime!.isAfter(old), isTrue,
          reason: 'the device confirmed it matches the account just now');
      expect(DateTime.now().difference(settings.lastSyncTime!).inMinutes, 0);
    });

    test('a background check with nothing to send counts as synced too', () async {
      await autoSyncA.syncNowManual();
      await settings.setSyncMode('auto');
      final old = DateTime.now().subtract(const Duration(days: 2));
      await settings.setLastSyncTime(old);
      await settings.setSyncDirty(false);
      final storeBefore = backend.store.counter;

      await autoSyncA.triggerSync();
      expect(backend.store.counter, storeBefore, reason: 'nothing was sent');
      expect(settings.lastSyncTime!.isAfter(old), isTrue);
      expect(autoSyncA.activity.value.failure, isNull);
    });

    test('a merge that fails stops the run and says so, instead of pushing', () async {
      // The store holds data this device cannot merge (here: a format from a
      // newer version).
      final status = await backend.getStatus();
      await backend.push(
        data: {
          'schema_version': 99,
          'connections': const <dynamic>[],
          'identities': const <dynamic>[],
        },
        dek: dek,
        salt: salt,
        verificationHash: verHash,
        expectedVersion: status.version,
        argon2Params: fast,
      );
      final storeBefore = backend.store.counter;

      await expectLater(
        autoSyncA.syncNowManual(),
        throwsA(isA<SyncException>()
            .having((e) => e.message, 'message', gl10n.syncMergeFailed)
            .having((e) => e.detail, 'detail', contains('newer version'))),
      );
      expect(autoSyncA.syncError.value, gl10n.syncMergeFailed);
      // What the restore said stands behind it, for the notice's report.
      expect(autoSyncA.syncErrorDetail, contains('newer version'));
      expect(autoSyncA.activity.value.failure, gl10n.syncMergeFailed);
      expect(backend.store.counter, storeBefore, reason: 'nothing was pushed over it');
    });

    test('a store this device cannot decrypt says so in the app\'s language, with what was thrown', () async {
      // Another device re-keyed the store: its data is sealed under a key
      // this device does not have. (It was said in English.)
      final status = await backend.getStatus();
      await backend.push(
        data: await memoryDataService(deviceB, storage, settings).gatherAll(),
        dek: SyncService.generateDek(),
        salt: salt,
        verificationHash: verHash,
        expectedVersion: status.version,
        argon2Params: fast,
      );
      final storeBefore = backend.store.counter;
      await expectLater(
        autoSyncA.syncNowManual(),
        throwsA(isA<SyncException>().having((e) => e.message, 'message', gl10n.syncCannotDecrypt)),
      );
      expect(autoSyncA.syncError.value, gl10n.syncCannotDecrypt);
      expect(autoSyncA.syncErrorDetail, isNotNull);
      expect(autoSyncA.syncErrorDetail, isNotEmpty);
      expect(backend.store.counter, storeBefore, reason: 'nothing was pushed over it');
    });

    test('a device set to Manual still shows sync as set up', () async {
      await settings.setSyncMode('manual');
      final other = AutoSyncService(
        syncDataService: memoryDataService(deviceA, storage, settings),
        settingsService: settings,
        secureStorage: storage,
        resolveBackend: () => backend,
      );
      addTearDown(other.dispose);
      expect(other.activity.value.configured, isFalse, reason: 'not read yet');
      other.startAutoSync();
      await pumpEventQueue();
      expect(other.activity.value.configured, isTrue);
    });

    test('changes that start waiting record when', () async {
      await settings.setSyncDirty(false);
      expect(settings.syncDirtySince, isNull);
      await settings.setSyncDirty(true);
      final since = settings.syncDirtySince!;
      await settings.setSyncDirty(true);
      expect(settings.syncDirtySince, since, reason: 'still the first change');
      await settings.setSyncDirty(false);
      expect(settings.syncDirtySince, isNull);
    });
  });
}

/// A store that refuses when told to, counting how often it is asked.
/// A store that says it holds a newer version far larger than sync data is.
class _BloatedStore extends MemoryStoreBackend {
  _BloatedStore(super.store);

  @override
  Future<SyncStatus> getStatus() async {
    final real = await super.getStatus();
    return SyncStatus(hasData: true, version: real.version + 1, blobSize: SyncService.maxBlobBytes + 1);
  }
}

class _RefusingStore extends MemoryStoreBackend {
  _RefusingStore(super.store);

  Object? refuse;
  int asked = 0;

  @override
  Future<SyncStatus> getStatus() {
    asked++;
    if (refuse != null) throw refuse!;
    return super.getStatus();
  }
}
