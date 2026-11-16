import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

/// Account keys in the sync payload (blob schema_version 18, 3.0):
/// confirmed keys travel, others do not, and a receiving device stores them
/// as unverified until they match what the server published.
SyncDataService _service(
        AppDatabase db, FlutterSecureStorage storage, SettingsService s,
        {String? account = 'uid-a'}) =>
    SyncDataService(
      database: db,
      connectionsDao: db.connectionsDao,
      identitiesDao: db.identitiesDao,
      groupsDao: db.connectionGroupsDao,
      knownHostsDao: db.knownHostsDao,
      snippetsDao: db.snippetsDao,
      snippetCategoriesDao: db.snippetCategoriesDao,
      portForwardRulesDao: db.portForwardRulesDao,
      networksDao: db.networksDao,
      connectionTagsDao: db.connectionTagsDao,
      secureStorage: storage,
      settingsService: s,
      accountUid: () => account,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();

  late AppDatabase db;
  late SettingsService settings;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    settings = SettingsService(await SharedPreferences.getInstance());
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  test('only confirmed keys travel, by account, in a v18 blob', () async {
    final store = AccountKeyStore(storage);
    final confirmed = await (await AccountKeys.generate()).toSecretJson();
    await store.write('uid-a',
        StoredAccountKeys(StoredKeyState.confirmed, confirmed));
    await store.write(
        'uid-b',
        StoredAccountKeys(StoredKeyState.pending,
            await (await AccountKeys.generate()).toSecretJson()));

    final blob = await _service(db, storage, settings).gatherAll();
    // Written by this build (21 since the icon colour); account keys came in 18.
    expect(blob['schema_version'], 22);
    expect(blob['account_keys'], {'uid-a': confirmed});
  });

  test('the receiving device stores them unverified, and a round trip is '
      'stable', () async {
    final keys = await (await AccountKeys.generate()).toSecretJson();
    final service = _service(db, storage, settings);
    final result = await service.restoreAll({
      'schema_version': 18,
      'connections': const <dynamic>[],
      'identities': const <dynamic>[],
      'account_keys': {'uid-a': keys},
    });
    expect(result.success, isTrue);

    final stored = await AccountKeyStore(storage).read('uid-a');
    expect(stored!.state, StoredKeyState.synced);
    expect(jsonEncode(stored.secret), jsonEncode(keys));
    // Not confirmed yet, so this device does not send them on.
    expect((await service.gatherAll())['account_keys'], isEmpty);
  });

  test('a newly confirmed set changes the fingerprint, so its push is sent',
      () async {
    final service = _service(db, storage, settings);
    final dek = List<int>.filled(32, 7);
    final before =
        SyncDataService.contentFingerprint(await service.gatherAll(), dek);
    await AccountKeyStore(storage).write(
        'uid-a',
        StoredAccountKeys(StoredKeyState.confirmed,
            await (await AccountKeys.generate()).toSecretJson()));
    final after =
        SyncDataService.contentFingerprint(await service.gatherAll(), dek);
    expect(after, isNot(before));
  });

  // A device keeps the keys of every account signed in on it; each went
  // into the payload of whichever was signed in, so into its cloud copy and
  // its other devices (found in the whitepaper re-check).
  group("only the signed-in account's keys", () {
    Future<(Map<String, dynamic>, Map<String, dynamic>)> twoAccounts() async {
      final store = AccountKeyStore(storage);
      final a = await (await AccountKeys.generate()).toSecretJson();
      final b = await (await AccountKeys.generate()).toSecretJson();
      await store.write('uid-a', StoredAccountKeys(StoredKeyState.confirmed, a));
      await store.write('uid-b', StoredAccountKeys(StoredKeyState.confirmed, b));
      return (a, b);
    }

    test('go out: the account signed in sends its own, none signed out', () async {
      final (a, b) = await twoAccounts();
      expect((await _service(db, storage, settings).gatherAll())['account_keys'], {'uid-a': a});
      expect((await _service(db, storage, settings, account: 'uid-b').gatherAll())['account_keys'], {'uid-b': b});
      expect((await _service(db, storage, settings, account: null).gatherAll())['account_keys'], isEmpty,
          reason: 'a backup made signed out carries no account keys');
      expect((await _service(db, storage, settings, account: 'uid-c').gatherAll())['account_keys'], isEmpty);
    });

    test("the app's sync service sends the keys of the account signed in", () async {
      final (_, b) = await twoAccounts();
      final c = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
        treeDatabaseProvider.overrideWithValue(db),
        currentUserProvider.overrideWith((ref) => const UserProfile(uid: 'uid-b')),
      ]);
      addTearDown(c.dispose);
      expect((await c.read(syncDataServiceProvider).gatherAll())['account_keys'], {'uid-b': b});
    });

    // It sent every account's: one account's team keys reached another's sync
    // data. Such a session reads its id from its token now
    // (session_account_uid_test).
    test('a computer whose session does not know its account sends none: which are its own it cannot tell',
        () async {
      await twoAccounts();
      expect(
          (await _service(db, storage, settings, account: AccountKeyStore.unknownAccount).gatherAll())['account_keys'],
          isEmpty);
    });

    test("come in: the account signed in takes its own; signed out, every account's, unverified", () async {
      final a = await (await AccountKeys.generate()).toSecretJson();
      final b = await (await AccountKeys.generate()).toSecretJson();
      Map<String, dynamic> blob() => {
            'schema_version': 22,
            'connections': const <dynamic>[],
            'identities': const <dynamic>[],
            'account_keys': {'uid-a': a, 'uid-b': b},
          };
      expect((await _service(db, storage, settings).restoreAll(blob())).success, isTrue);
      final store = AccountKeyStore(storage);
      expect((await store.read('uid-a'))!.state, StoredKeyState.synced);
      expect(await store.read('uid-b'), isNull, reason: "another account's keys, from an older device, stay out");

      FlutterSecureStorage.setMockInitialValues({});
      expect((await _service(db, storage, settings, account: null).restoreAll(blob())).success, isTrue);
      expect((await store.read('uid-a'))!.state, StoredKeyState.synced);
      expect((await store.read('uid-b'))!.state, StoredKeyState.synced,
          reason: 'a backup restored before signing in keeps them, none trusted before it matches the server');
    });
  });

  test('an older client refuses a newer blob instead of dropping the keys',
      () async {
    // The guard every schema bump relies on, from the receiving side: this
    // build accepts 22 and refuses anything newer.
    expect(SyncDataService.supportedSchemaVersion, 22);
    final result = await _service(db, storage, settings).restoreAll({
      'schema_version': 23,
      'connections': const <dynamic>[],
    });
    expect(result.success, isFalse);
  });
}
