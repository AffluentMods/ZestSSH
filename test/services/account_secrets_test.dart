import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/cloud_accounts.dart';
import 'package:zestssh/features/cloud_import/cloud_machine.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/account_sign_out.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/account_bearer.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/secret_seal.dart';
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

/// The account's sign-in token and the sync password's verification value,
/// kept as they were while the encrypting lock was on:
/// whatever could read the system's secure storage without the PIN held what
/// ZestSSH Cloud needs to push to the cloud copy or purge it. Now they are
/// sealed like every other secret that opens data ([AccountSecret]).
const _token = 'eyJhbGciOiJIUzI1NiJ9.demo-session.signature';
const _check = 'Y2hlY2stdmFsdWUtZGVtby0zMi1ieXRlcy1sb25nISE=';

/// A store of one's own, as sync keeps it: its password is the secret.
const _webdav = SyncProviderConfig(
  kind: SyncBackendKind.webdav,
  webdavUrl: 'https://dav.example.com/zest',
  webdavUsername: 'alex',
  webdavPassword: 'dav-pass-demo',
);
final _store = jsonEncode(_webdav.toJson());

/// A cloud account hosts are imported from, with its API token.
CloudAccount _cloud({String id = 'a1'}) => CloudAccount(
    id: id,
    provider: CloudProvider.digitalocean,
    label: 'DO main',
    fields: const {CloudField.token: 'dop_v1_demo_token'},
    groupName: 'DO main');
final _clouds = jsonEncode([_cloud().toJson()]);

/// The four, as an app before this one kept them, and what a sign-out nobody
/// asked for sets aside.
Map<String, String> _asTheyWere() => {
      'session_token': _token,
      'sync_verification_hash': _check,
      'sync_backend_config': _store,
      'cloud_accounts_v1': _clouds,
      'sync_kept_for_account_v1': '{"uid":"alex","dek":"kept-demo"}',
      'lockout_recovery_v1': '{"email":"person@example.com","ticket":"ticket-demo","completes_at":"2026-11-06T09:00:00.000Z"}',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();
  late AppDatabase db;

  setUp(() {
    L10nGlobal.update(lookupAppLocalizations(const Locale('en')));
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    SecretSeal.openTree = null;
  });
  tearDown(() async {
    SecretSeal.openTree = null;
    await db.close();
  });

  Future<String?> raw(AccountSecret secret) => storage.read(key: secret.slot);

  test('with the lock off each is kept as it was and read as it was, as before', () async {
    for (final secret in AccountSecret.all) {
      await secret.write(storage, 'value-of-${secret.slot}', tree: () => db);
      expect(await raw(secret), 'value-of-${secret.slot}', reason: secret.slot);
      expect(await secret.read(storage, tree: () => db), 'value-of-${secret.slot}');
      expect(await secret.read(storage, tree: () => null), 'value-of-${secret.slot}',
          reason: 'nothing waits for an unlock with the lock off');
      expect(await secret.waitsForUnlock(storage, tree: () => null), isFalse);
    }
    expect(await raw(AccountSecret.sessionToken), isNot(startsWith(SecretSeal.prefix)),
        reason: 'reading one kept as it was seals nothing while sealing is off');
  });

  test('with the lock on each is kept sealed, opens with the database alone, and not with another one', () async {
    await SecretSeal.setActive(db, true);
    await AccountSecret.sessionToken.write(storage, _token, tree: () => db);
    await AccountSecret.syncVerification.write(storage, _check, tree: () => db);
    for (final (secret, value) in [(AccountSecret.sessionToken, _token), (AccountSecret.syncVerification, _check)]) {
      final kept = (await raw(secret))!;
      expect(kept, startsWith(SecretSeal.prefix), reason: secret.slot);
      expect(kept, isNot(contains(value)));
      expect(kept, isNot(contains('demo-session')));
      expect(await secret.read(storage, tree: () => db), value);

      // The app locked: none, never the sealed text, and it is known to wait
      // for the unlock (not a signed-out device).
      expect(await secret.read(storage, tree: () => null), isNull);
      expect(await secret.waitsForUnlock(storage, tree: () => null), isTrue);
      expect(await secret.waitsForUnlock(storage, tree: () => db), isFalse);

      final other = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(other.close);
      await SecretSeal.setActive(other, true);
      expect(await secret.read(storage, tree: () => other), isNull, reason: "another database's seal does not open it");
    }

    // Moved to the other's place, it does not open there.
    await storage.write(key: AccountSecret.syncVerification.slot, value: await raw(AccountSecret.sessionToken));
    expect(await AccountSecret.syncVerification.read(storage, tree: () => db), isNull);
  });

  test('by default the database open now is used: the account bearer reads the token while unlocked, none while '
      'locked', () async {
    await SecretSeal.setActive(db, true);
    SecretSeal.openTree = db;
    await AccountSecret.sessionToken.write(storage, _token);
    expect(await raw(AccountSecret.sessionToken), startsWith(SecretSeal.prefix));
    expect(await accountBearer(), _token);
    SecretSeal.openTree = null;
    expect(await accountBearer(), isNull);
  });

  test('one kept as it was by an app before this one is sealed the first time it is read while the lock is on',
      () async {
    FlutterSecureStorage.setMockInitialValues({'session_token': _token, 'sync_verification_hash': _check});
    await SecretSeal.setActive(db, true);

    // Locked: read as it is (an app before this one wrote it so), and left.
    expect(await AccountSecret.sessionToken.read(storage, tree: () => null), _token);
    expect(await raw(AccountSecret.sessionToken), _token);

    expect(await AccountSecret.sessionToken.read(storage, tree: () => db), _token);
    expect(await AccountSecret.syncVerification.read(storage, tree: () => db), _check);
    for (final secret in [AccountSecret.sessionToken, AccountSecret.syncVerification]) {
      expect(await raw(secret), startsWith(SecretSeal.prefix), reason: secret.slot);
    }
    expect(await AccountSecret.sessionToken.read(storage, tree: () => db), _token);
    expect(await AccountSecret.sessionToken.read(storage, tree: () => null), isNull);
  });

  test('the sweep at each unlock seals both as well', () async {
    FlutterSecureStorage.setMockInitialValues({..._asTheyWere(), 'session_email': 'person@example.com'});
    expect(await settleSecretsAtRest(db, storage, lockOn: true), 6);
    for (final secret in AccountSecret.all) {
      expect(await raw(secret), startsWith(SecretSeal.prefix), reason: secret.slot);
    }
    expect(await storage.read(key: 'session_email'), 'person@example.com');
    expect(await AccountSecret.sessionToken.read(storage, tree: () => db), _token);
    expect(await AccountSecret.syncVerification.read(storage, tree: () => db), _check);
    expect(await AccountSecret.syncStore.read(storage, tree: () => db), _store);
    expect(await AccountSecret.cloudImports.read(storage, tree: () => db), _clouds);
  });

  test('a line that stays up through a lock waits for the unlock instead of reading none', () async {
    await SecretSeal.setActive(db, true);
    await AccountSecret.sessionToken.write(storage, _token, tree: () => db);

    String? got;
    var done = false;
    unawaited(AccountSecret.sessionToken.readOnceOpen(storage).then((t) {
      got = t;
      done = true;
    }));
    await pumpEventQueue();
    expect(done, isFalse, reason: 'locked: it waits');

    SecretSeal.openTree = db;
    await pumpEventQueue();
    expect(done, isTrue);
    expect(got, _token);

    // Unlocked, or with nothing sealed, it reads at once.
    expect(await AccountSecret.sessionToken.readOnceOpen(storage), _token);
    await AccountSecret.sessionToken.delete(storage);
    SecretSeal.openTree = null;
    expect(await AccountSecret.sessionToken.readOnceOpen(storage), isNull, reason: 'signed out: none, at once');
  });

  group('the encrypting lock and signing out', () {
    Future<ProviderContainer> device() async {
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
        isProProvider.overrideWith((ref) => _Pro()),
        isCloudSyncProvider.overrideWith((ref) => _Juiced()),
      ]);
      addTearDown(container.dispose);
      container.read(databaseSessionProvider.notifier).seed(db);
      return container;
    }

    test('turning the lock on seals each; turning it off keeps them as they were again', () async {
      FlutterSecureStorage.setMockInitialValues(_asTheyWere());
      final container = await device();

      await container.read(isAppLockedProvider.notifier).enableEncryptingLock(pin: '482915');
      for (final secret in AccountSecret.all) {
        expect(await raw(secret), startsWith(SecretSeal.prefix), reason: secret.slot);
      }
      for (final clear in ['demo-session', 'dav-pass-demo', 'dop_v1_demo_token', 'dav.example.com', 'ticket-demo']) {
        expect((await storage.readAll()).values.where((v) => v.contains(clear)), isEmpty, reason: clear);
      }
      expect(await AccountSecret.sessionToken.read(storage), _token, reason: 'the database is open');
      // Signed in again while the lock is on: kept sealed.
      await AccountSecret.sessionToken.write(storage, '$_token-2');
      expect(await raw(AccountSecret.sessionToken), startsWith(SecretSeal.prefix));

      await container.read(isAppLockedProvider.notifier).disableEncryptingLock('482915');
      expect(await raw(AccountSecret.sessionToken), '$_token-2');
      expect(await raw(AccountSecret.syncVerification), _check);
      expect(await raw(AccountSecret.syncStore), _store);
      expect(await raw(AccountSecret.cloudImports), _clouds);
      await AccountSecret.sessionToken.write(storage, '$_token-3');
      expect(await raw(AccountSecret.sessionToken), '$_token-3', reason: 'written from now on as it is');
    });

    test('signing out forgets the token, sealed as it is', () async {
      FlutterSecureStorage.setMockInitialValues({'session_token': _token, 'session_email': 'person@example.com'});
      final container = await device();
      await sealSecretsAtRest(db, storage);
      expect(await raw(AccountSecret.sessionToken), startsWith(SecretSeal.prefix));

      await signOutAccountWith(container.read, signedOutElsewhere: true);
      expect(await raw(AccountSecret.sessionToken), isNull);
      expect(await storage.read(key: 'session_email'), isNull);
    });
  });

  group('the store sync uses, with what signs in to it', () {
    Future<ProviderContainer> container({bool unlocked = true}) async {
      final c = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
        isProProvider.overrideWith((ref) => _Pro()),
        isCloudSyncProvider.overrideWith((ref) => _Juiced()),
      ]);
      addTearDown(c.dispose);
      if (unlocked) c.read(databaseSessionProvider.notifier).seed(db);
      return c;
    }

    test('saved while the lock is on it is kept sealed, and read back whole', () async {
      await SecretSeal.setActive(db, true);
      final saving = await container();
      await saving.read(syncProviderConfigProvider.notifier).ensureLoaded();
      await saving.read(syncProviderConfigProvider.notifier).save(_webdav);
      final kept = (await raw(AccountSecret.syncStore))!;
      expect(kept, startsWith(SecretSeal.prefix));
      expect(kept, isNot(contains('dav-pass-demo')));

      final reading = await container();
      await reading.read(syncProviderConfigProvider.notifier).ensureLoaded();
      final config = reading.read(syncProviderConfigProvider);
      expect(config.kind, SyncBackendKind.webdav);
      expect(config.webdavPassword, 'dav-pass-demo');
    });

    test('started while the app is locked, the choice is read at the unlock: never lost, never taken for the '
        'default', () async {
      await SecretSeal.setActive(db, true);
      await AccountSecret.syncStore.write(storage, _store, tree: () => db);
      final locked = await container(unlocked: false);
      var loaded = false;
      unawaited(locked.read(syncProviderConfigProvider.notifier).ensureLoaded().then((_) => loaded = true));
      await pumpEventQueue();
      expect(loaded, isFalse, reason: 'startup waits for it before sync runs');
      expect(await raw(AccountSecret.syncStore), startsWith(SecretSeal.prefix), reason: 'nothing written over');

      locked.read(databaseSessionProvider.notifier).seed(db);
      await pumpEventQueue();
      expect(loaded, isTrue);
      expect(locked.read(syncProviderConfigProvider).kind, SyncBackendKind.webdav);
      expect(locked.read(syncProviderConfigProvider).webdavPassword, 'dav-pass-demo');
    });

    test('signing out with the lock on still knows the store is one of its own, and leaves its sync as it was',
        () async {
      FlutterSecureStorage.setMockInitialValues({
        ..._asTheyWere(),
        'sync_dek': base64Encode(List.filled(32, 7)),
        'sync_salt': base64Encode(List.filled(16, 3)),
        'sync_setup_step': 'complete',
        'sync_setup_complete': 'true',
      });
      await sealSecretsAtRest(db, storage);
      final c = await container();
      await signOutAccountWith(c.read, signedOutElsewhere: true);
      expect(await AccountSecret.syncVerification.read(storage), _check, reason: 'a store of its own goes on');
      expect(await AccountSecret.syncStore.read(storage), _store);
      expect(await raw(AccountSecret.sessionToken), isNull);
    });
  });

  group('the cloud accounts hosts are imported from', () {
    test('kept sealed while the lock is on, and read back with their tokens', () async {
      await SecretSeal.setActive(db, true);
      final store = CloudAccountStore(storage, tree: () => db);
      await store.save([_cloud()]);
      final kept = (await raw(AccountSecret.cloudImports))!;
      expect(kept, startsWith(SecretSeal.prefix));
      expect(kept, isNot(contains('dop_v1_demo_token')));
      expect((await store.load()).single.fields[CloudField.token], 'dop_v1_demo_token');
    });

    test('while the app is locked they are not read as none, so nothing writes them over', () async {
      await SecretSeal.setActive(db, true);
      await CloudAccountStore(storage, tree: () => db).save([_cloud()]);
      final before = await raw(AccountSecret.cloudImports);

      final locked = CloudAccountStore(storage, tree: () => null);
      await expectLater(locked.load(), throwsA(isA<SecretSealBroken>()));
      final container = ProviderContainer(overrides: [
        cloudAccountStoreProvider.overrideWithValue(locked),
        cloudAccountsProvider.overrideWith((ref) => CloudAccountsController(ref, locked,
            scan: (_, _) async => fail('nothing is checked while locked'))),
      ]);
      addTearDown(container.dispose);
      final controller = container.read(cloudAccountsProvider.notifier);
      await pumpEventQueue();
      await controller.checkAll();
      expect(await controller.checkOne('a1'), isNull);
      expect(await raw(AccountSecret.cloudImports), before, reason: 'kept as it was');
      controller.stop();
    });

    test('ones sealed by a database since reset read as none and can be replaced', () async {
      final gone = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(gone.close);
      await SecretSeal.setActive(gone, true);
      await CloudAccountStore(storage, tree: () => gone).save([_cloud()]);
      await SecretSeal.setActive(db, true);
      final store = CloudAccountStore(storage, tree: () => db);
      expect(await store.load(), isEmpty);
      await store.save([_cloud(id: 'a2')]);
      expect((await store.load()).single.id, 'a2');
    });
  });
}
