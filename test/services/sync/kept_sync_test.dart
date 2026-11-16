import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync/kept_sync.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync/sync_disconnect.dart';
import 'package:zestssh/services/sync_service.dart';

/// Signing in again never costs the sync setup (found in a security
/// review): a device signed out without being asked keeps what syncs it, set
/// aside for the account. The same account signing in finds sync as it was, with
/// no question; any other account finds nothing, and what was kept is gone first.
/// Else an account that keeps its data on ZestSSH Cloud is asked, once for each
/// sign-in, to bring this device back in.
class _Store extends Fake implements SyncBackend {
  _Store({this.hasData = true, this.kindIs = SyncBackendKind.zestServer, this.fails, this.noHosting = false});

  final bool hasData;
  final SyncBackendKind kindIs;
  final Object? fails;
  final bool noHosting;
  var asked = 0;

  @override
  SyncBackendKind get kind => kindIs;

  @override
  Future<void> verifyEntitlement() async {
    if (noHosting) throw const SyncHostingRequiredException('no hosting');
  }

  @override
  Future<SyncStatus> getStatus() async {
    asked++;
    if (fails != null) throw fails!;
    return SyncStatus(hasData: hasData, version: 3, blobSize: 2048);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late ProviderContainer c;
  late FlutterSecureStorage storage;
  late SettingsService settings;

  final dek = base64Encode(List.filled(32, 7));
  final verification = base64Encode(List.filled(32, 9));
  final salt = base64Encode(List.filled(16, 3));
  const baseValue = '{"connections/a":"hash"}';

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    FlutterSecureStorage.setMockInitialValues({
      'sync_dek': dek,
      'sync_verification_hash': verification,
      'sync_salt': salt,
      'sync_argon2_params': jsonEncode(const {'version': 2, 'memory': 8192, 'iterations': 1, 'parallelism': 1}),
      'sync_setup_complete': 'true',
      'sync_setup_step': 'complete',
    });
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
    ]);
    addTearDown(c.dispose);
    storage = const FlutterSecureStorage();
    settings = c.read(settingsServiceProvider);
    await settings.setSyncServerVersion(41);
    await settings.setSyncContentHash('content-of-41');
    await settings.setSyncDirty(true);
    await settings.setSyncRecoveryKeySet(true);
    await LocalStateStore(db).write('sync.base', baseValue);
  });

  Future<void> disconnect() => disconnectSyncOnThisDevice(
        autoSync: c.read(autoSyncServiceProvider),
        setup: c.read(syncSetupStateServiceProvider),
        settings: settings,
        secureStorage: storage,
        lockVault: () {},
      );

  KeptSync kept() => c.read(keptSyncProvider);

  /// A sign-out nobody asked for, as signOutAccount does it.
  Future<void> signedOutElsewhere(String uid) async {
    expect(await kept().keep(uid), isTrue);
    await disconnect();
  }

  test('while it is kept nothing that syncs can reach it: the keys are not where sync looks', () async {
    await signedOutElsewhere('alex');
    expect(await storage.read(key: 'sync_dek'), isNull);
    expect(await storage.read(key: 'sync_verification_hash'), isNull);
    expect(await storage.read(key: 'sync_salt'), isNull);
    expect(await c.read(syncSetupStateServiceProvider).isSyncActive(), isFalse);
    expect(await LocalStateStore(db).read('sync.base'), isNull);
    expect(settings.syncServerVersion, 0);
  });

  test('the same account signing in finds sync as it was, with no question', () async {
    await signedOutElsewhere('alex');
    final store = _Store();
    final next = await syncAfterSignIn(
      uid: 'alex',
      kept: kept(),
      setup: c.read(syncSetupStateServiceProvider),
      settings: settings,
      backend: () => store,
    );
    expect(next, SyncAfterSignIn.resumed);
    expect(store.asked, 0, reason: 'no question, and nothing to ask the store');
    expect(await storage.read(key: 'sync_dek'), dek);
    expect(await storage.read(key: 'sync_verification_hash'), verification);
    expect(await storage.read(key: 'sync_salt'), salt);
    expect(jsonDecode((await storage.read(key: 'sync_argon2_params'))!)['memory'], 8192);
    expect(await c.read(syncSetupStateServiceProvider).isSyncActive(), isTrue);
    expect(settings.syncServerVersion, 41);
    expect(settings.syncContentHash, 'content-of-41');
    expect(settings.syncDirty, isTrue, reason: 'changes waiting to go up still go up');
    expect(settings.syncRecoveryKeySet, isTrue);
    expect(await LocalStateStore(db).read('sync.base'), baseValue, reason: 'the three-way merge knows what it last synced');
    expect(await AccountSecret.keptSync.read(storage, tree: () => db), isNull, reason: 'used up');
    expect(await LocalStateStore(db).read('sync.base.aside'), isNull);
  });

  test('another account signing in finds nothing, and what was kept is gone first', () async {
    await signedOutElsewhere('alex');
    final store = _Store(hasData: false);
    final next = await syncAfterSignIn(
      uid: 'sam',
      kept: kept(),
      setup: c.read(syncSetupStateServiceProvider),
      settings: settings,
      backend: () => store,
    );
    expect(next, SyncAfterSignIn.nothing);
    expect(await AccountSecret.keptSync.read(storage, tree: () => db), isNull, reason: 'gone');
    expect(await storage.read(key: 'sync_dek'), isNull);
    expect(await LocalStateStore(db).read('sync.base.aside'), isNull);
    expect(await LocalStateStore(db).read('sync.base'), isNull);
    expect(await kept().resume('alex'), isFalse, reason: 'and it does not come back for the first account either');
  });

  test('a store set up meanwhile is not written over: what was kept is forgotten', () async {
    await signedOutElsewhere('alex');
    await c.read(syncSetupStateServiceProvider).markCompleteViaJoin(salt: List.filled(16, 8));
    await storage.write(key: 'sync_dek', value: 'of the other store');
    expect(await kept().resume('alex'), isFalse);
    expect(await storage.read(key: 'sync_dek'), 'of the other store');
    expect(await AccountSecret.keptSync.read(storage, tree: () => db), isNull);
  });

  test('sync not set up on this device: nothing is kept', () async {
    await disconnect();
    expect(await kept().keep('alex'), isFalse);
    expect(await AccountSecret.keptSync.read(storage, tree: () => db), isNull);
  });

  test('what was kept is sealed while sealing is on, and opens only with the database', () async {
    await SecretSeal.setActive(db, true);
    await signedOutElsewhere('alex');
    final raw = (await storage.read(key: AccountSecret.keptSync.slot))!;
    expect(SecretSeal.isSealed(raw), isTrue);
    expect(raw, isNot(contains(dek)));
    expect(await AccountSecret.keptSync.read(storage, tree: () => null), isNull, reason: 'locked: reads as none');
    expect(await kept().resume('alex'), isTrue);
    expect(SecretSeal.isSealed((await storage.read(key: 'sync_dek'))!), isTrue, reason: 'put back sealed');
    expect(SecretSeal.isSealed((await storage.read(key: 'sync_verification_hash'))!), isTrue);
  });

  group('the end of a sign-in with nothing kept', () {
    Future<SyncAfterSignIn> asked(_Store store) => syncAfterSignIn(
          uid: 'alex',
          kept: kept(),
          setup: c.read(syncSetupStateServiceProvider),
          settings: settings,
          backend: () => store,
        );

    test('an account that keeps its data on ZestSSH Cloud is asked, once', () async {
      await disconnect();
      expect(await asked(_Store()), SyncAfterSignIn.ask);
      expect(await asked(_Store()), SyncAfterSignIn.nothing, reason: 'Not now is not asked again');
      await settings.setSyncTurnOnAsked(false);
      expect(await asked(_Store()), SyncAfterSignIn.ask, reason: 'the next sign-in asks again');
    });

    test('an account with nothing on ZestSSH Cloud, or without it, is asked nothing', () async {
      await disconnect();
      expect(await asked(_Store(hasData: false)), SyncAfterSignIn.nothing);
      await settings.setSyncTurnOnAsked(false);
      expect(await asked(_Store(noHosting: true)), SyncAfterSignIn.nothing);
      expect(settings.syncTurnOnAsked, isTrue);
    });

    test('not knowing yet asks nothing, and the next start asks', () async {
      await disconnect();
      expect(await asked(_Store(fails: Exception('no network'))), SyncAfterSignIn.nothing);
      expect(settings.syncTurnOnAsked, isFalse);
      expect(await asked(_Store()), SyncAfterSignIn.ask);
    });

    test('a device already syncing, or on a store of its own, is asked nothing', () async {
      final mine = _Store();
      expect(await asked(mine), SyncAfterSignIn.nothing);
      expect(mine.asked, 0);
      await disconnect();
      await settings.setSyncTurnOnAsked(false);
      final own = _Store(kindIs: SyncBackendKind.webdav);
      expect(await asked(own), SyncAfterSignIn.nothing);
      expect(own.asked, 0);
    });
  });
}
