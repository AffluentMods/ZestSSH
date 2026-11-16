import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

import 'profile_world.dart';

/// The one store every keychain access goes through.
void main() {
  late ProfileWorld world;
  late AppDatabase db;
  late ActiveProfile alice;
  late ProfileKeychain keychain;
  const uid = 'account-alice';

  setUp(() async {
    world = await ProfileWorld.create();
    Profiles.turnOn();
    db = await openPlayed(await Directory(p.join(world.root.path, 'a')).create(), 'x');
    await SecretSeal.forProfile(db);
    alice = ActiveProfile(id: 'aaaa', dir: Directory(p.join(world.base.path, 'profiles', 'aaaa')), uid: uid);
    Profiles.bind(alice);
    keychain = ProfileKeychain(world.device, profile: () => alice, tree: () => db);
  });
  tearDown(() async {
    await db.close();
    await world.dispose();
  });

  test('a store\'s name is the profile\'s, sealed; a device name stays as it is', () async {
    await keychain.write(key: 'identity_key_k', value: 'PRIVATE');
    await keychain.write(key: 'security_pin_hash', value: 'hash');
    await keychain.write(key: 'vault_slots', value: 'slots');
    expect(world.device.kept.containsKey('identity_key_k'), isFalse);
    expect(SecretSeal.isSealed(world.device.kept['p.aaaa.identity_key_k']), isTrue);
    expect(world.device.kept['security_pin_hash'], 'hash');
    expect(world.device.kept['vault2_slots'], 'slots', reason: 'a new name for the slots');
    expect(world.device.kept.containsKey('vault_slots'), isFalse);
    expect(await keychain.read(key: 'identity_key_k'), 'PRIVATE');
    expect(await keychain.read(key: 'vault_slots'), 'slots');
  });

  test('a sealed entry is bound to its whole name: moved to another, it does not open', () async {
    await keychain.write(key: 'identity_key_k', value: 'PRIVATE');
    world.device.kept['p.aaaa.identity_key_other'] = world.device.kept['p.aaaa.identity_key_k']!;
    expect(await keychain.read(key: 'identity_key_other'), isNull);
  });

  test('what opens the database cannot be sealed by the seal in it', () async {
    await keychain.write(key: KeychainNames.databaseKey, value: 'a' * 64);
    expect(world.device.kept['p.aaaa.${KeychainNames.databaseKey}'], 'a' * 64);
    expect(await keychain.readAll(), isNot(contains(KeychainNames.databaseKey)), reason: 'and no sweep sees it');
  });

  test('every clean-up sees only its own profile\'s names', () async {
    final bob = ActiveProfile(id: 'bbbb', dir: Directory(world.root.path), uid: 'account-bob');
    final bobDb = await openPlayed(await Directory(p.join(world.root.path, 'b')).create(), 'y');
    await SecretSeal.forProfile(bobDb);
    final bobKeychain = ProfileKeychain(world.device, profile: () => bob, tree: () => bobDb);
    await keychain.write(key: 'identity_key_a', value: 'A');
    await bobKeychain.write(key: 'identity_key_b', value: 'B');
    world.device.kept['security_pin_hash'] = 'hash';

    expect((await keychain.readAll()).keys, ['identity_key_a']);
    expect((await bobKeychain.readAll()).keys, ['identity_key_b']);
    // One of Bob's written while his database was closed is plain: no seal hides
    // it, and only its name says whose it is.
    world.device.kept['p.bbbb.identity_key_waiting'] = 'plain until his next open';
    expect((await keychain.readAll()).keys, ['identity_key_a']);
    await keychain.deleteAll();
    expect(await keychain.readAll(), isEmpty);
    expect(await bobKeychain.read(key: 'identity_key_b'), 'B');
    expect(world.device.kept['p.bbbb.identity_key_waiting'], 'plain until his next open');
    expect(world.device.kept['security_pin_hash'], 'hash');
    await bobDb.close();
  });

  test('the clean-up after a restore deletes the secrets of its own profile\'s lost hosts and no other\'s', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final bob = ActiveProfile(id: 'bbbb', dir: Directory(world.root.path), uid: 'account-bob');
    final bobDb = await openPlayed(await Directory(p.join(world.root.path, 'b')).create(), 'y');
    await SecretSeal.forProfile(bobDb);
    final bobKeychain = ProfileKeychain(world.device, profile: () => bob, tree: () => bobDb);
    await bobKeychain.write(key: 'identity_key_of_bob', value: 'BOB');
    world.device.kept['p.bbbb.identity_key_waiting'] = 'plain until his next open';

    // Alice restores: a leftover secret of hers goes, and Bob's, named the same
    // way and not among her keys, stay, the plain one no seal hides among them.
    await keychain.write(key: 'identity_key_leftover', value: 'LEFT');
    final sync = SyncDataService(
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
      secureStorage: keychain,
      settingsService: SettingsService(prefs),
    );
    final result = await sync.restoreAll({'schema_version': 1, 'identities': const []});
    expect(result.success, isTrue);
    expect(await keychain.read(key: 'identity_key_leftover'), isNull, reason: 'the sweep ran');
    expect(await bobKeychain.read(key: 'identity_key_of_bob'), 'BOB');
    expect(world.device.kept['p.bbbb.identity_key_waiting'], 'plain until his next open');
    await bobDb.close();
  });

  test('a name holds no account id inside a profile, and a store still finds its own', () async {
    final store = AccountKeyStore(keychain, tree: () => db);
    const keys = StoredAccountKeys(StoredKeyState.confirmed, {'version': 1});
    await store.write(uid, keys);
    await keychain.write(key: 'orchard_device_key_v1.$uid', value: 'seed');
    await keychain.write(key: 'orchard_export_v1.$uid.team', value: 'export');
    await keychain.write(key: 'orchard_export_v1.$uid.team.sent', value: 'sent');
    expect(world.device.kept.keys.any((k) => k.contains(uid)), isFalse);
    expect(world.device.kept.containsKey('p.aaaa.account_keys_v1_me'), isTrue);
    expect(world.device.kept.containsKey('p.aaaa.orchard_export_v1.me.team.sent'), isTrue);
    expect((await store.read(uid))?.state, StoredKeyState.confirmed);
    expect(await keychain.read(key: 'orchard_export_v1.$uid.team.sent'), 'sent');
    expect((await keychain.readAll()).keys,
        containsAll(['account_keys_v1_$uid', 'orchard_device_key_v1.$uid', 'orchard_export_v1.$uid.team.sent']));
  });

  test('guest data takes in no account\'s team keys from a backup', () async {
    final guest = ActiveProfile(id: 'gggg', dir: Directory(world.root.path));
    final guestChain = ProfileKeychain(world.device, profile: () => guest, tree: () => db);
    final store = AccountKeyStore(guestChain, tree: () => db);
    // Whole keys, that a signed-in account's store would take.
    final keys = await (await AccountKeys.generate()).toSecretJson();
    final count = await store.importFromSync({'account-x': keys});
    expect(count, 0);
    expect((await guestChain.readAll()).keys.where((k) => k.startsWith('account_keys')), isEmpty);
  });

  test('with no profile open nothing of a person can be written, and nothing is read', () async {
    final none = ProfileKeychain(world.device, profile: () => null, tree: () => null);
    expect(await none.read(key: 'identity_key_k'), isNull);
    await expectLater(none.write(key: 'identity_key_k', value: 'x'), throwsA(isA<NoProfileOpen>()));
    await expectLater(none.delete(key: 'identity_key_k'), throwsA(isA<NoProfileOpen>()));
    expect(await none.readAll(), isEmpty);
    expect(world.device.kept.keys.where((k) => k.contains('identity_key')), isEmpty);
    // A device's own works.
    await none.write(key: 'security_lock_method', value: 'pin');
    expect(await none.read(key: 'security_lock_method'), 'pin');
  });

  test('with the database closed a sealed entry stays sealed, and the stores read it as none or wait', () async {
    await keychain.write(key: 'session_token', value: 'tok.en.here');
    final closed = ProfileKeychain(world.device, profile: () => alice, tree: () => null);
    expect(SecretSeal.isSealed(await closed.read(key: 'session_token')), isTrue);
    expect(await AccountSecret.sessionToken.read(closed, tree: () => null), isNull);
    expect(await AccountSecret.sessionToken.waitsForUnlock(closed, tree: () => null), isTrue);
    expect(await AccountSecret.sessionToken.read(keychain, tree: () => db), 'tok.en.here');
    final store = SecureStorageIdentitySecrets(closed);
    await keychain.write(key: 'identity_key_k', value: 'PRIVATE');
    expect(await store.read('k', IdentitySecret.privateKey), isNull);
  });

  test('written while the database was closed: kept as it is, and sealed at the next open', () async {
    final closed = ProfileKeychain(world.device, profile: () => alice, tree: () => null);
    await closed.write(key: 'device_session_v1', value: 'a session');
    expect(world.device.kept['p.aaaa.device_session_v1'], 'a session');
    expect(await keychain.sealWaiting(alice, await SecretSeal.of(db)), 1);
    expect(SecretSeal.isSealed(world.device.kept['p.aaaa.device_session_v1']), isTrue);
    expect(await keychain.read(key: 'device_session_v1'), 'a session');
  });

  test('an entry that opens no more reads as none, so it can be replaced, with the database open', () async {
    world.device.kept['p.aaaa.sync_salt'] = '${SecretSeal.prefix}AAAA';
    expect(await keychain.read(key: 'sync_salt'), isNull);
    expect((await keychain.readAll()).containsKey('sync_salt'), isFalse);
  });

  group('a team whose key cannot be read', () {
    late _AsideStorage storage;
    late OrchardDatabasesNotifier teams;
    final setAside = <String>[];

    setUp(() {
      setAside.clear();
      storage = _AsideStorage();
      SecretSeal.openTree = db;
      teams = OrchardDatabasesNotifier(
        OrchardDatabaseKeys(keychain, tree: () => db),
        storage: storage,
        onSetAside: setAside.add,
      );
    });
    tearDown(() async {
      await teams.closeAll();
      teams.dispose();
    });

    test('never deletes a database on a computer: it is set aside, and the team made again and said', () async {
      storage.held.add(kTeamA);
      await teams.open(kTeamA);
      expect(storage.deleted, isEmpty);
      expect(storage.asideIds, [kTeamA]);
      expect(setAside, [kTeamA]);
      expect(await keychain.read(key: OrchardDatabaseKeys.storageKey(kTeamA)), isNotNull, reason: 'a new key for it');
    });

    test('a key that reads is used, and nothing is set aside', () async {
      storage.held.add(kTeamA);
      await keychain.write(key: OrchardDatabaseKeys.storageKey(kTeamA), value: 'a' * 64);
      await teams.open(kTeamA);
      expect(storage.asideIds, isEmpty);
      expect(storage.deleted, isEmpty);
    });

    test('with the database closed it is not taken for lost', () async {
      storage.held.add(kTeamA);
      SecretSeal.openTree = null;
      await expectLater(teams.open(kTeamA), throwsStateError);
      expect(storage.asideIds, isEmpty);
    });

    test('one used where it lies, with no key: not set aside and not made again, for it may be another account\'s', () async {
      storage.held.add(kTeamB);
      Profiles.provisionalTeams.add(kTeamB);
      await expectLater(teams.open(kTeamB), throwsStateError);
      expect(storage.asideIds, isEmpty);
      expect(storage.deleted, isEmpty);
      expect(await keychain.read(key: OrchardDatabaseKeys.storageKey(kTeamB)), isNull);
    });

    test('forgetting one that was only used where it lies deletes nothing of it', () async {
      storage.held.add(kTeamB);
      Profiles.provisionalTeams.add(kTeamB);
      await teams.forget(kTeamB);
      expect(storage.deleted, isEmpty);
      expect(Profiles.provisionalTeams, isEmpty);
    });

    test('the file storage moves it and its side files, and leaves nothing behind', () async {
      Profiles.bind(ActiveProfile(id: 'aaaa', dir: await Directory(p.join(world.root.path, 'pf')).create(), uid: uid));
      final file = await AppDatabase.orchardDatabaseFile(kTeamC);
      await file.parent.create(recursive: true);
      await file.writeAsString('main');
      await File('${file.path}-wal').writeAsString('wal');
      const storage = FileOrchardDatabaseStorage();
      await storage.setAside(kTeamC);
      expect(file.existsSync(), isFalse);
      expect(File('${file.path}-wal').existsSync(), isFalse);
      final aside = Directory(p.join(file.parent.path, kTeamsSetAsideFolder)).listSync();
      expect(aside.length, 2);
      expect(await storage.list(), isEmpty, reason: 'set aside is not listed');
    });
  });
}

class _AsideStorage implements OrchardDatabaseStorage, SetsTeamsAside {
  final held = <String>{};
  final deleted = <String>[];
  final asideIds = <String>[];

  @override
  Future<bool> exists(String orchardId) async => held.contains(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async {
    held.add(orchardId);
    final db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    await db.customSelect('SELECT 1').get();
    return db;
  }

  @override
  Future<void> delete(String orchardId) async {
    deleted.add(orchardId);
    held.remove(orchardId);
  }

  @override
  Future<List<String>> list() async => held.toList();

  @override
  Future<void> setAside(String orchardId) async {
    asideIds.add(orchardId);
    held.remove(orchardId);
  }
}
