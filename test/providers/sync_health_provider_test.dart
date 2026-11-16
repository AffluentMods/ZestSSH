// Real Argon2id key derivation (the weakest profile deriveKey accepts),
// done once for the file. Allow for a machine busy with the whole suite.
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync/dumb_store_sync_backend.dart';
import 'package:zestssh/services/sync_health.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/utils/error_translator.dart';

import '../helpers/memory_store_backend.dart';

/// How sync stands, as the status bar and the Account page read it, from
/// what the background sync says of itself (3.0): a store
/// that cannot be reached is a failure the app tries again by itself, and
/// the screens are told so.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const fast = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
  const storage = FlutterSecureStorage();
  const refused = SocketException('Connection refused');

  test('a store that cannot be reached: failing, with what is wrong, and tried again by the app itself', () async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final settings = SettingsService(prefs);
    await settings.setSyncMode('auto');
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final store = _Store(MemoryStore());
    final waiting = <Timer>[];
    final service = AutoSyncService(
      syncDataService: memoryDataService(db, storage, settings),
      settingsService: settings,
      secureStorage: storage,
      resolveBackend: () => store,
      timer: (wait, then) {
        final timer = Timer(const Duration(days: 1), then);
        waiting.add(timer);
        return timer;
      },
    );
    addTearDown(() {
      service.dispose();
      for (final t in waiting) {
        t.cancel();
      }
    });
    final salt = SyncService.generateSalt();
    final dek = SyncService.generateDek();
    final mek = await SyncService.deriveKey('correct-password', salt, params: fast);
    await storage.write(key: 'sync_salt', value: base64Encode(salt));
    final verHash = await SyncService.computeVerificationHash(mek);
    await service.storeSyncCredentials(dek, verHash, argon2Params: fast);
    // The store holds the account's vault, and this device has synced it.
    final v1 = await store.push(
      data: await memoryDataService(db, storage, settings).gatherAll(),
      dek: dek,
      salt: salt,
      verificationHash: verHash,
      wrappedDekPassword: await SyncService.wrapDek(dek, mek),
      createOnly: true,
      argon2Params: fast,
    );
    await settings.setSyncServerVersion(v1.version);

    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      autoSyncServiceProvider.overrideWithValue(service),
      syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 8, 12))),
    ]);
    addTearDown(container.dispose);
    final seen = <SyncHealthState>[];
    container.listen(syncHealthProvider, (_, next) => seen.add(next), fireImmediately: true);

    store.down = refused;
    await service.triggerSync();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final health = container.read(syncHealthProvider);
    expect(health.health, SyncHealth.failing);
    expect(
      health.problem,
      ErrorCodes.withCode(
          describeNetworkError(refused, subject: gl10n.errSubjectSyncServer).message, ErrorCodes.syncStoreUnreachable),
    );
    expect(health.retrying, isTrue, reason: 'what the service says of itself reaches the screens');

    // Back: nothing is failing, and nothing is said to be tried again.
    store.down = null;
    await service.syncNowManual();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final after = container.read(syncHealthProvider);
    expect(after.health, isNot(SyncHealth.failing));
    expect(after.retrying, isFalse);
  });
}

class _Store extends MemoryStoreBackend {
  _Store(super.store);

  Object? down;

  @override
  Future<RawObject?> readObject() {
    final failure = down;
    if (failure != null) return Future.error(failure);
    return super.readObject();
  }
}
