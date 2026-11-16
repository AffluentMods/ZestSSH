import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

/// The secrets of your keys, sync's key, your account's keys and the
/// Orchards' database keys, sealed while the encrypting lock is on (found
/// in a security review): they were kept in the
/// system's secure storage as they were, beside the database's key the lock
/// wraps behind the PIN, so whatever could read that storage read them
/// without the PIN.
const _pem = '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----';
final _orchardKey = 'ab' * 32;

SyncDataService _service(AppDatabase db, FlutterSecureStorage storage, SettingsService s) => SyncDataService(
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
    );

/// The secure storage, where a value is changed by someone else the moment
/// the sweep has listed them all.
class _ChangedMeanwhile extends FlutterSecureStorage {
  const _ChangedMeanwhile();

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    // A copy, as the system hands it over (the test's storage hands its own).
    final all = Map<String, String>.of(await super.readAll());
    await super.write(key: 'identity_password_i1', value: 'changed meanwhile');
    return all;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();
  late AppDatabase db;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  Future<void> identity(String id) => db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: id,
        label: '$id key',
        username: 'deploy',
        authMethod: 'publicKey',
        createdAt: DateTime.utc(2026, 10, 16),
      ));

  /// Every value in the storage, as kept.
  Future<Map<String, String>> kept() => storage.readAll();

  test('a sealed secret opens under its own slot alone; one kept as it was reads as it is', () async {
    await SecretSeal.setActive(db, true);
    final seal = await SecretSeal.of(db);
    final sealed = await seal.seal('identity_key_a', _pem);
    expect(sealed, startsWith(SecretSeal.prefix));
    expect(sealed, isNot(contains('OPENSSH')));
    expect(await seal.open('identity_key_a', sealed), _pem);
    await expectLater(seal.open('identity_key_b', sealed), throwsA(isA<SecretSealBroken>()),
        reason: 'moved to another secret\'s place it does not open');
    expect(await seal.open('identity_key_a', _pem), _pem);
    expect(await seal.seal('identity_key_a', _pem), isNot(sealed), reason: 'a fresh nonce each time');
  });

  test("the seal's key is made once and kept in the database; another database's seal does not open its secrets",
      () async {
    final first = await SecretSeal.of(db);
    expect(identical(await SecretSeal.of(db), first), isTrue);
    final store = LocalStateStore(db);
    expect(await store.read('secret_seal_key_v1'), isNull, reason: 'none until sealing is turned on');
    expect(first.active, isFalse);
    expect(await first.keep('identity_key_a', _pem), _pem);
    await SecretSeal.setActive(db, true);
    expect(first.active, isTrue);
    final made = await Future.wait([
      store.readOrCreate('demo', () => 'one'),
      store.readOrCreate('demo', () => 'two'),
    ]);
    expect(made[0], made[1], reason: 'two asking at once get the same one');
    expect(await store.readOrCreate('demo', () => 'three'), made[0], reason: 'a value once kept is never replaced');
    expect(await store.read('secret_seal_key_v1'), isNotNull);
    expect(await store.read('secret_seal_active_v1'), '1', reason: 'on, as the next start reads it');

    final sealed = await first.seal('sync_dek', 'ZGVr');
    final other = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(other.close);
    await expectLater((await SecretSeal.of(other)).open('sync_dek', sealed), throwsA(isA<SecretSealBroken>()),
        reason: 'one that never sealed has no key to open it with');
    await SecretSeal.setActive(other, true);
    await expectLater((await SecretSeal.of(other)).open('sync_dek', sealed), throwsA(isA<SecretSealBroken>()));
    await SecretSeal.setActive(db, false);
    await SecretSeal.setActive(db, true);
    expect(await first.open('sync_dek', sealed), 'ZGVr', reason: 'the same key, off and on again');
  });

  test('with sealing off a secret is kept as it was; turned on, every secret is sealed, those kept before as well, '
      'and each is read as it was by the place that reads it', () async {
    FlutterSecureStorage.setMockInitialValues({
      'identity_key_i1': _pem,
      'identity_password_i1': 'hunter2-demo',
      'sync_dek': 'ZGVrLWRlbW8=',
      'account_keys_v1_uid-a': jsonEncode(const StoredAccountKeys(StoredKeyState.confirmed, {'demo': 1}).toJson()),
      'orchard_db_key_o1': _orchardKey,
      'ca_key_c1': _pem,
      'session_email': 'person@example.com',
      'device_id': 'device-demo',
    });
    final secrets = SecureStorageIdentitySecrets(storage, sealedBy: db);
    await secrets.write('i2', IdentitySecret.passphrase, 'phrase-demo');
    expect((await kept())['identity_passphrase_i2'], 'phrase-demo', reason: 'sealing is off');

    expect(await sealSecretsAtRest(db, storage), 7);
    final all = await kept();
    for (final slot in [
      'identity_key_i1', 'identity_password_i1', 'identity_passphrase_i2', 'sync_dek', 'account_keys_v1_uid-a',
      'orchard_db_key_o1', 'ca_key_c1',
    ]) {
      expect(all[slot], startsWith(SecretSeal.prefix), reason: slot);
    }
    for (final clear in ['OPENSSH', 'hunter2-demo', 'phrase-demo', 'ZGVrLWRlbW8=', 'demo', _orchardKey]) {
      expect(all.entries.where((e) => SecretSeal.sealsSlot(e.key) && e.value.contains(clear)), isEmpty, reason: clear);
    }
    expect(all['session_email'], 'person@example.com', reason: 'not one of the sealed');
    expect(all['device_id'], 'device-demo');

    expect(await secrets.read('i1', IdentitySecret.privateKey), _pem);
    expect(await secrets.read('i1', IdentitySecret.password), 'hunter2-demo');
    expect(await secrets.read('i2', IdentitySecret.passphrase), 'phrase-demo');
    expect((await AccountKeyStore(storage, tree: () => db).read('uid-a'))!.secret, {'demo': 1});
    expect(await OrchardDatabaseKeys(storage, tree: () => db).read('o1'), _orchardKey);
    expect(await openKept(db, 'sync_dek', all['sync_dek']), 'ZGVrLWRlbW8=');

    // Written now, sealed; where it does not open, none; turned off, kept as
    // it is, and the sealed still open.
    await secrets.write('i3', IdentitySecret.privateKey, _pem);
    expect((await kept())['identity_key_i3'], startsWith(SecretSeal.prefix));
    await AccountKeyStore(storage, tree: () => db).write('uid-b', const StoredAccountKeys(StoredKeyState.confirmed, {'b': 2}));
    expect((await kept())['account_keys_v1_uid-b'], startsWith(SecretSeal.prefix));
    await OrchardDatabaseKeys(storage, tree: () => db).create('o2');
    expect((await kept())['orchard_db_key_o2'], startsWith(SecretSeal.prefix));

    await storage.write(key: 'identity_key_i4', value: '${SecretSeal.prefix}AAAA');
    expect(await secrets.read('i4', IdentitySecret.privateKey), isNull);
    expect(await const SecureStorageIdentitySecrets(storage).read('i1', IdentitySecret.privateKey), isNull,
        reason: 'with no database to open it, a sealed secret is none, never the sealed text');

    await SecretSeal.setActive(db, false);
    await secrets.write('i5', IdentitySecret.password, 'kept-as-is');
    expect((await kept())['identity_password_i5'], 'kept-as-is');
    expect(await secrets.read('i3', IdentitySecret.privateKey), _pem);
  });

  test('a secret changed while the sweep runs keeps its new value, sealed at the next', () async {
    FlutterSecureStorage.setMockInitialValues({'identity_password_i1': 'old', 'identity_key_i1': _pem});
    const racing = _ChangedMeanwhile();
    expect(await sealSecretsAtRest(db, racing), 1);
    expect((await kept())['identity_password_i1'], 'changed meanwhile');
    expect(await sealSecretsAtRest(db, storage), 1);
    expect(await openKept(db, 'identity_password_i1', (await kept())['identity_password_i1']), 'changed meanwhile');
  });

  test('sync and backups read the sealed secrets as they were and write them sealed', () async {
    SharedPreferences.setMockInitialValues(const {});
    final settings = SettingsService(await SharedPreferences.getInstance());
    await SecretSeal.setActive(db, true);
    await identity('i1');
    final secrets = SecureStorageIdentitySecrets(storage, sealedBy: db);
    await secrets.write('i1', IdentitySecret.privateKey, _pem);
    await secrets.write('i1', IdentitySecret.password, 'hunter2-demo');

    final blob = await _service(db, storage, settings).gatherAll();
    final sent = jsonEncode(blob);
    expect(sent, contains('hunter2-demo'), reason: 'opened for the (end-to-end encrypted) payload');
    expect(sent, isNot(contains(SecretSeal.prefix)), reason: 'never the sealed text');

    // Another device, its own database and seal.
    FlutterSecureStorage.setMockInitialValues({});
    final other = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(other.close);
    await SecretSeal.setActive(other, true);
    final result = await _service(other, storage, settings).restoreAll(blob);
    expect(result.success, isTrue);
    expect((await kept())['identity_key_i1'], startsWith(SecretSeal.prefix));
    final theirs = SecureStorageIdentitySecrets(storage, sealedBy: other);
    expect(await theirs.read('i1', IdentitySecret.privateKey), _pem);
    expect(await theirs.read('i1', IdentitySecret.password), 'hunter2-demo');
  });

  test('turning the encrypting lock on seals every secret; turning it off keeps new ones as they are, and the '
      'sealed still open', () async {
    FlutterSecureStorage.setMockInitialValues({'identity_key_i1': _pem, 'sync_dek': 'ZGVrLWRlbW8='});
    SharedPreferences.setMockInitialValues(const {});
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
    ]);
    addTearDown(container.dispose);
    container.read(databaseSessionProvider.notifier).seed(db);
    final lock = container.read(isAppLockedProvider.notifier);
    final secrets = SecureStorageIdentitySecrets(storage, sealedBy: db);

    await lock.enableEncryptingLock(pin: '482915');
    expect((await kept())['identity_key_i1'], startsWith(SecretSeal.prefix));
    expect((await kept())['sync_dek'], startsWith(SecretSeal.prefix));
    await secrets.write('i2', IdentitySecret.password, 'hunter2-demo');
    expect((await kept())['identity_password_i2'], startsWith(SecretSeal.prefix));

    await lock.disableEncryptingLock('482915');
    await secrets.write('i3', IdentitySecret.password, 'kept-as-is');
    expect((await kept())['identity_password_i3'], 'kept-as-is');
    expect(await secrets.read('i1', IdentitySecret.privateKey), _pem);
    expect(await secrets.read('i2', IdentitySecret.password), 'hunter2-demo');
  });

  // Turning the lock off removes the vault, then unseals. Stopped in between
  // (found in the whitepaper check), the app started again
  // with the vault off and sealing on: every secret written from then on
  // was sealed, and the sealed ones stayed so. Each open of the database now
  // puts that right.
  group('the lock off, sealing left on by a turning off that stopped part way', () {
    test('is put right at the next open: every secret opened, and new ones kept as they are', () async {
      FlutterSecureStorage.setMockInitialValues({'identity_key_i1': _pem, 'sync_dek': 'ZGVrLWRlbW8='});
      expect(await sealSecretsAtRest(db, storage), 2);
      // Stopped here: the vault is gone, sealing is on.
      final secrets = SecureStorageIdentitySecrets(storage, sealedBy: db);
      await secrets.write('i2', IdentitySecret.password, 'written-after');
      expect((await kept())['identity_password_i2'], startsWith(SecretSeal.prefix), reason: 'the gap');

      expect(await settleSecretsAtRest(db, storage, lockOn: false), 3);
      expect(await kept(), {'identity_key_i1': _pem, 'sync_dek': 'ZGVrLWRlbW8=', 'identity_password_i2': 'written-after'});
      expect((await SecretSeal.of(db)).active, isFalse);
      await secrets.write('i3', IdentitySecret.password, 'kept-as-is');
      expect((await kept())['identity_password_i3'], 'kept-as-is');
      expect(await settleSecretsAtRest(db, storage, lockOn: false), 0, reason: 'nothing left to do');
    });

    test('a sweep that stopped part way, sealing already off: what it left sealed is opened', () async {
      FlutterSecureStorage.setMockInitialValues({'identity_key_i1': _pem, 'sync_dek': 'ZGVrLWRlbW8='});
      await sealSecretsAtRest(db, storage);
      await SecretSeal.setActive(db, false);
      expect(await settleSecretsAtRest(db, storage, lockOn: false), 2);
      expect(await kept(), {'identity_key_i1': _pem, 'sync_dek': 'ZGVrLWRlbW8='});
    });

    test('a device whose lock never was on is left as it is; with the lock on, secrets are sealed as before', () async {
      FlutterSecureStorage.setMockInitialValues({'identity_key_i1': _pem});
      expect(await settleSecretsAtRest(db, storage, lockOn: false), 0);
      expect((await SecretSeal.of(db)).everOn, isFalse);
      expect(await kept(), {'identity_key_i1': _pem});
      expect(await settleSecretsAtRest(db, storage, lockOn: true), 1);
      expect((await kept())['identity_key_i1'], startsWith(SecretSeal.prefix));
    });

    test('the app does it at each open of the database, the lock on or off', () {
      final app = File('lib/app.dart').readAsStringSync().replaceAll('\r\n', '\n');
      expect(app, contains('settleSecretsAtRest(tree, ref.read(secureStorageProvider), lockOn: lockOn)'));
      expect(app, isNot(contains('if (!ref.read(settingsServiceProvider).encryptingLockEnabled) return;')));
      // Reached at each open: it is the first thing the open does, before
      // anything that could return early, and its own only way out is no
      // database (a line kept but moved out of reach passed, as a
      // review found).
      final open = app.substring(app.indexOf('void _onDbOpened() {'));
      expect(open.split('\n')[1].trim(), 'unawaited(_sealSecretsAtRest());');
      final seal = app.substring(app.indexOf('Future<void> _sealSecretsAtRest() async {'));
      final body = seal.substring(0, seal.indexOf('\n  }\n'));
      expect(RegExp(r'\breturn\b').allMatches(body).length, 1, reason: 'one way out');
      expect(body, contains('if (tree == null) return;'));
      expect(app, contains('profiles.onStart = _onDbOpened;'));
    });
  });

  test("which secrets are sealed; an Orchard's database has no seal of its own", () async {
    final orchard = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    addTearDown(orchard.close);
    expect(() => SecretSeal.of(orchard), throwsArgumentError);
    expect(SecretSeal.sealsSlot('identity_key_x'), isTrue);
    expect(SecretSeal.sealsSlot('sync_dek'), isTrue);
    expect(SecretSeal.sealsSlot('sync_dek_old'), isFalse);
    expect(SecretSeal.sealsSlot('session_token'), isTrue);
    expect(SecretSeal.sealsSlot('sync_verification_hash'), isTrue);
    expect(SecretSeal.sealsSlot('sync_backend_config'), isTrue);
    expect(SecretSeal.sealsSlot('cloud_accounts_v1'), isTrue);
    expect(SecretSeal.sealsSlot('device_session_v1'), isFalse, reason: 'names the device beside a sign-in; no bearer');
    expect(SecretSeal.sealsSlot('session_email'), isFalse);
    expect(SecretSeal.sealsSlot('sync_salt'), isFalse);
    expect(SecretSeal.sealsSlot('zestssh_db_encryption_key'), isFalse, reason: 'the lock keeps that one itself');
  });
}
