import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/account_sign_out.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/mac_keychain.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync/sync_provider_config.dart';
import 'package:zestssh/services/sync/unread_sync_store.dart';
import 'package:zestssh/ui/widgets/mac_keychain_notice.dart' show readAgainThenSync;

/// A Mac's keychain that macOS does not let ZestSSH read (found in a review of 3.4.2).
/// The read of the store sync uses threw, the hosted default stood for it for
/// the whole run, and nothing read it again: sync went to ZestSSH Cloud with
/// the keys of the person's own WebDAV or S3, a sign-out deleted those keys as
/// if they were ZestSSH Cloud's, and setting sync up again wrote the hosted
/// choice over the kept one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  const storage = FlutterSecureStorage();
  late AppDatabase db;
  late _Refusing mac;
  late FlutterSecureStoragePlatform before;

  const webdav = SyncProviderConfig(
    kind: SyncBackendKind.webdav,
    webdavUrl: 'https://dav.example.com/zest',
    webdavUsername: 'alex',
    webdavPassword: 'dav-pass-demo',
  );
  final dek = base64Encode(List.filled(32, 7));
  final salt = base64Encode(List.filled(16, 3));
  final check = base64Encode(List.filled(32, 9));

  /// A device whose sync is set up with [store] kept as its choice, and macOS
  /// saying no to that one item (and to nothing else) until [allow].
  Future<ProviderContainer> device({String? store, Set<String> denied = const {'sync_backend_config'}}) async {
    FlutterSecureStorage.setMockInitialValues({
      'sync_backend_config': ?store,
      'sync_dek': dek,
      'sync_salt': salt,
      'sync_verification_hash': check,
      'sync_setup_step': 'complete',
      'sync_setup_complete': 'true',
    });
    mac = _Refusing(FlutterSecureStoragePlatform.instance, denied);
    FlutterSecureStoragePlatform.instance = MacKeychain(mac);
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
      isProProvider.overrideWith((ref) => _Pro()),
      isCloudSyncProvider.overrideWith((ref) => _Juiced()),
    ]);
    addTearDown(c.dispose);
    c.read(databaseSessionProvider.notifier).seed(db);
    return c;
  }

  /// The person chooses Try again on the notice, and this time chooses
  /// Always Allow.
  Future<void> tryAgain(ProviderContainer c) async {
    mac.denied = const {};
    keychainDenials!.tryAgain();
    await c.read(syncProviderConfigProvider.notifier).readAgain();
  }

  setUp(() {
    L10nGlobal.update(en);
    before = FlutterSecureStoragePlatform.instance;
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    SecretSeal.openTree = null;
  });
  tearDown(() async {
    FlutterSecureStoragePlatform.instance = before;
    SecretSeal.openTree = null;
    await db.close();
  });

  test('refused, the store is not known: not ZestSSH Cloud, and every request to it says why', () async {
    final c = await device(store: jsonEncode(webdav.toJson()));
    final store = c.read(syncProviderConfigProvider.notifier);
    await store.ensureLoaded();

    expect(store.unknown, isTrue);
    expect(c.read(syncStoreKnownHostedProvider), isFalse, reason: 'never taken for ZestSSH Cloud');
    final backend = c.read(syncBackendProvider);
    expect(backend, isA<UnreadSyncStore>());
    expect(backend.kind.isHosted, isFalse);
    final refused = await backend.getStatus().then<Object?>((_) => null, onError: (Object e) => e);
    expect(refused, isA<SyncStoreUnknownException>());
    refused as SyncStoreUnknownException;
    expect(refused.keychain, isTrue);
    expect(refused.message, contains('ZS-1913'), reason: 'said as macOS not letting it read, with its code');
    expect(refused.detail, contains('-128'));
  });

  test('Sync now while it is not known goes nowhere and says the keychain', () async {
    final c = await device(store: jsonEncode(webdav.toJson()));
    await c.read(syncProviderConfigProvider.notifier).ensureLoaded();
    final sync = c.read(autoSyncServiceProvider);
    await expectLater(sync.syncNowManual(), throwsA(isA<SyncStoreUnknownException>()));
    expect(await storage.read(key: 'sync_dek'), dek, reason: 'nothing of sync\'s touched');
  });

  test('Try again reads it again, and sync goes on with the store of one\'s own', () async {
    final c = await device(store: jsonEncode(webdav.toJson()));
    final store = c.read(syncProviderConfigProvider.notifier);
    await store.ensureLoaded();
    expect(store.unknown, isTrue);

    // Asked again with nothing chosen: macOS is not asked, and it stays unknown.
    await store.ensureLoaded();
    expect(store.unknown, isTrue);
    expect(mac.asked, 1, reason: 'no question brought up again by itself');

    await tryAgain(c);
    expect(store.unknown, isFalse);
    expect(c.read(syncProviderConfigProvider).kind, SyncBackendKind.webdav);
    expect(c.read(syncProviderConfigProvider).webdavPassword, 'dav-pass-demo');
    expect(c.read(syncBackendProvider), isNot(isA<UnreadSyncStore>()));
    expect(c.read(syncStoreUnreadProvider), isNull);
  });

  test('a sign-out while it is not known deletes none of sync\'s keys; a store of one\'s own keeps them after',
      () async {
    final c = await device(store: jsonEncode(webdav.toJson()));
    await signOutAccountWith(c.read, signedOutElsewhere: true);
    expect(await storage.read(key: 'sync_dek'), dek);
    expect(await storage.read(key: 'sync_salt'), salt);
    expect(await storage.read(key: 'sync_verification_hash'), check);
    expect(c.read(settingsServiceProvider).syncDisconnectOwed, '', reason: 'owed until the store is known');

    await tryAgain(c);
    expect(await storage.read(key: 'sync_dek'), dek, reason: 'a store of one\'s own needs no account');
    expect(await storage.read(key: 'sync_salt'), salt);
    expect(c.read(settingsServiceProvider).syncDisconnectOwed, isNull);
  });

  test('... and where it turns out to be ZestSSH Cloud, the keys go once it is read, before anything syncs',
      () async {
    final c = await device(store: jsonEncode(const SyncProviderConfig.zestServer().toJson()));
    await signOutAccountWith(c.read, signedOutElsewhere: true);
    expect(await storage.read(key: 'sync_dek'), dek, reason: 'not known then');

    await tryAgain(c);
    expect(c.read(syncProviderConfigProvider.notifier).unknown, isFalse);
    expect(c.read(syncProviderConfigProvider).kind, SyncBackendKind.zestServer);
    expect(await storage.read(key: 'sync_dek'), isNull, reason: 'what that sign-out owed');
    expect(await storage.read(key: 'sync_salt'), isNull);
    expect(c.read(settingsServiceProvider).syncDisconnectOwed, isNull);
  });

  test('the kept choice is not written over while macOS does not let it be read', () async {
    final c = await device(store: jsonEncode(webdav.toJson()));
    final store = c.read(syncProviderConfigProvider.notifier);
    await store.ensureLoaded();
    await expectLater(store.save(const SyncProviderConfig.zestServer()), throwsA(isA<SyncStoreUnknownException>()));
    await expectLater(store.save(const SyncProviderConfig.zestServer(), overUnreadable: true),
        throwsA(isA<SyncStoreUnknownException>()),
        reason: 'not even by a choice made in the storage screen');
    mac.denied = const {};
    keychainDenials!.tryAgain();
    expect(jsonDecode((await storage.read(key: 'sync_backend_config'))!)['kind'], 'webdav');
  });

  test('a choice that was read and makes no sense: unknown too, and only a choice of the person\'s replaces it',
      () async {
    final c = await device(store: '{not json', denied: const {});
    final store = c.read(syncProviderConfigProvider.notifier);
    await store.ensureLoaded();
    expect(store.unknown, isTrue);
    expect(c.read(syncBackendProvider), isA<UnreadSyncStore>());

    // Background sync pauses with what it is (no keychain notice says it).
    final sync = c.read(autoSyncServiceProvider);
    await expectLater(sync.syncNowManual(), throwsA(isA<SyncStoreUnknownException>()));
    expect(sync.syncError.value, en.syncStoreNotRead);
    expect(sync.syncErrorNeedsSetup, isFalse, reason: 'setting sync up again would go to ZestSSH Cloud');

    await expectLater(store.save(webdav), throwsA(isA<SyncStoreUnknownException>()));
    await store.save(webdav, overUnreadable: true);
    expect(store.unknown, isFalse);
    expect(c.read(syncProviderConfigProvider).kind, SyncBackendKind.webdav);
  });

  // Run, not read: the order was checked only in app.dart's text (as a
  // review found).
  test('Try again on the keychain notice reads the store again before sync goes on, read or not', () async {
    final done = <String>[];
    await readAgainThenSync(
      readAgain: () async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        done.add('read');
      },
      sync: () async => done.add('sync'),
    );
    expect(done, ['read', 'sync']);
    done.clear();
    await expectLater(
        readAgainThenSync(readAgain: () async => throw StateError('refused'), sync: () async => done.add('sync')),
        throwsStateError);
    expect(done, ['sync'], reason: 'sync goes on with what there is');
    await readAgainThenSync(readAgain: () async {}, sync: () => null);
  });

  test('the app does that on Try again', () {
    final app = File('lib/app.dart').readAsStringSync();
    final start = app.indexOf('afterTryAgain:');
    final body = app.substring(start, app.indexOf('},', start));
    expect(body, contains('readAgainThenSync('));
    expect(body, contains('readAgain: () => ref.read(syncProviderConfigProvider.notifier).readAgain(),'));
    expect(body, contains('sync: () => mounted ? _autoSync?.triggerSync() : null,'));
  });
}

/// The keychain plugin of a Mac, over the test's own store: macOS says no to
/// a read of each of [denied].
class _Refusing extends FlutterSecureStoragePlatform with MockPlatformInterfaceMixin {
  _Refusing(this._inner, this.denied);

  final FlutterSecureStoragePlatform _inner;
  Set<String> denied;

  /// How many times macOS was asked about one of [denied].
  int asked = 0;

  @override
  Future<String?> read({required String key, required Map<String, String> options}) async {
    if (denied.contains(key)) {
      asked++;
      throw PlatformException(code: 'Unexpected security result code', message: 'Code: -128', details: -128);
    }
    return _inner.read(key: key, options: options);
  }

  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) =>
      _inner.write(key: key, value: value, options: options);

  @override
  Future<void> delete({required String key, required Map<String, String> options}) =>
      _inner.delete(key: key, options: options);

  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) =>
      _inner.containsKey(key: key, options: options);

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) => _inner.readAll(options: options);

  @override
  Future<void> deleteAll({required Map<String, String> options}) => _inner.deleteAll(options: options);
}

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
