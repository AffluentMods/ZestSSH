import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/account_sign_out.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/purchase_service.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync/sync_provider_config.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  Future<void> refresh() async {}

  @override
  void signedOut() => state = false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Juiced extends StateNotifier<bool> implements CloudSyncStatusNotifier {
  _Juiced() : super(true);

  @override
  Future<void> refresh() async {}

  @override
  void signedOut() => state = false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Devices extends Fake implements DeviceSessionService {
  @override
  Future<void> forget() async {}

  @override
  Future<void> signOutHere({Duration within = const Duration(seconds: 6)}) async {}
}

/// Signing out of the account forgets ZestSSH Cloud's sync on this device,
/// the account's own, and leaves a store of one's own syncing (found
/// in a security review): the sync keys stayed, and
/// sync ran on with them for the next account signed in here, pushing this
/// device's vault, under the key of the account before, into an empty store
/// of the new one; and a store of one's own, which needs no account, had its
/// setup reset, so the app said sync was off while it ran.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();
  final keys = {
    'sync_dek': base64Encode(List.filled(32, 7)),
    'sync_verification_hash': base64Encode(List.filled(32, 9)),
    'sync_salt': base64Encode(List.filled(16, 3)),
  };

  /// A device signed in to an account, with sync set up on [config]'s store.
  Future<ProviderContainer> device(SyncProviderConfig config, {String? uid}) async {
    SharedPreferences.setMockInitialValues(const {});
    FlutterSecureStorage.setMockInitialValues({
      'sync_backend_config': jsonEncode(config.toJson()),
      ...keys,
      'sync_setup_step': 'complete',
      'sync_setup_complete': 'true',
      'session_token': 'demo-session',
    });
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
      isProProvider.overrideWith((ref) => _Pro()),
      isCloudSyncProvider.overrideWith((ref) => _Juiced()),
      deviceSessionServiceProvider.overrideWithValue(_Devices()),
      if (uid != null) currentUserProvider.overrideWith((_) => UserProfile(uid: uid, email: '$uid@example.com')),
    ]);
    addTearDown(container.dispose);
    container.read(databaseSessionProvider.notifier).seed(db);
    expect(await container.read(syncSetupStateServiceProvider).isSyncActive(), isTrue);
    return container;
  }

  Future<Map<String, String?>> keysKept() async => {
        for (final key in keys.keys) key: await storage.read(key: key),
      };

  test("ZestSSH Cloud's sync is forgotten on this device: its keys, its salt and its setup", () async {
    final container = await device(const SyncProviderConfig.zestServer());
    // Signed out from another device: nothing is asked of the server.
    await signOutAccountWith(container.read, signedOutElsewhere: true);

    expect(await keysKept(), {for (final key in keys.keys) key: null});
    expect(await container.read(syncSetupStateServiceProvider).isSyncActive(), isFalse);
    expect(await storage.read(key: 'session_token'), isNull);
  });

  // Signing in again never costs the sync setup (found in a security review): a device
  // signed out without asking keeps it for the account, not where sync looks.
  test('a sign-out nobody asked for keeps what syncs this device, set aside for the account', () async {
    final container = await device(const SyncProviderConfig.zestServer(), uid: 'alex');
    await signOutAccountWith(container.read, signedOutElsewhere: true);

    expect(await keysKept(), {for (final key in keys.keys) key: null}, reason: 'not where sync looks for them');
    expect(await container.read(syncSetupStateServiceProvider).isSyncActive(), isFalse);
    expect(await container.read(keptSyncProvider).resume('alex'), isTrue);
    expect(await keysKept(), keys, reason: 'the same account finds them');
    expect(await container.read(syncSetupStateServiceProvider).isSyncActive(), isTrue);
  });

  test('the same sign-out for another account finds nothing', () async {
    final container = await device(const SyncProviderConfig.zestServer(), uid: 'alex');
    await signOutAccountWith(container.read, signedOutElsewhere: true);
    expect(await container.read(keptSyncProvider).resume('sam'), isFalse);
    expect(await keysKept(), {for (final key in keys.keys) key: null});
    expect(await storage.read(key: AccountSecret.keptSync.slot), isNull);
  });

  test("the person's own Sign out forgets it all, and the next sign-in is asked again", () async {
    final container = await device(const SyncProviderConfig.zestServer(), uid: 'alex');
    await container.read(settingsServiceProvider).setSyncTurnOnAsked(true);
    await signOutAccountWith(container.read);
    expect(await keysKept(), {for (final key in keys.keys) key: null});
    expect(await storage.read(key: AccountSecret.keptSync.slot), isNull);
    expect(await container.read(keptSyncProvider).resume('alex'), isFalse);
    expect(container.read(settingsServiceProvider).syncTurnOnAsked, isFalse);
  });

  // A computer kept the last account's tier after signing out, for whoever
  // used it next and after a restart too.
  test('the tier is Free at once, and the copy of it a computer kept is forgotten', () async {
    final container = await device(const SyncProviderConfig.zestServer());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('desktop_entitlement_pro', true);
    await prefs.setBool('desktop_entitlement_cloud_sync', true);
    await prefs.setInt('desktop_entitlement_checked_at', 1);
    expect(await PurchaseService.readCachedDesktopEntitlements(), isNotNull);

    await signOutAccountWith(container.read, signedOutElsewhere: true);
    expect(container.read(isProProvider), isFalse);
    expect(container.read(isCloudSyncProvider), isFalse);
    expect(await PurchaseService.readCachedDesktopEntitlements(), isNull,
        reason: 'the next start is not Squeezed or Juiced from it');
  });

  test('a store of one\'s own goes on syncing, set up as it was', () async {
    for (final config in [
      const SyncProviderConfig(
          kind: SyncBackendKind.webdav,
          webdavUrl: 'https://dav.example.com/zest',
          webdavUsername: 'alex',
          webdavPassword: 'demo'),
      const SyncProviderConfig(
          kind: SyncBackendKind.s3,
          s3Endpoint: 'https://s3.example.com',
          s3Region: 'us-east-1',
          s3Bucket: 'zest',
          s3AccessKeyId: 'demo',
          s3SecretAccessKey: 'demo'),
    ]) {
      final container = await device(config);
      await signOutAccountWith(container.read, signedOutElsewhere: true);

      expect(await keysKept(), keys, reason: config.kind.name);
      expect(await container.read(syncSetupStateServiceProvider).isSyncActive(), isTrue, reason: config.kind.name);
      expect(await storage.read(key: 'session_token'), isNull, reason: 'the account is signed out all the same');
    }
  });
}
