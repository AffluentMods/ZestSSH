import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/mac_keychain.dart';
import 'package:zestssh/services/profiles/profile_boot.dart';
import 'package:zestssh/services/profiles/profile_list.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/services/profiles/profile_vault.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

import 'profile_world.dart';

/// The plugin on a Mac, as it is in the legacy keychain: readAll fails with
/// errSecParam, on every Mac; each read works.
class _Plugin extends FlutterSecureStoragePlatform with MockPlatformInterfaceMixin {
  final kept = <String, String>{};
  final deleted = <String>[];
  final reads = <String>[];

  /// The items a person said no to, in the system's question.
  bool Function(String name)? denied;

  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) async => kept.containsKey(key);
  @override
  Future<void> delete({required String key, required Map<String, String> options}) async {
    deleted.add(key);
    kept.remove(key);
  }

  @override
  Future<void> deleteAll({required Map<String, String> options}) async => throw StateError('it takes the first it matches');
  @override
  Future<String?> read({required String key, required Map<String, String> options}) async {
    reads.add(key);
    if (denied?.call(key) ?? false) throw PlatformException(code: 'Unexpected security result code', message: 'Code: -128');
    return kept[key];
  }

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) async =>
      throw PlatformException(code: 'Unexpected security result code', message: 'Code: -50', details: -50);
  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) async =>
      kept[key] = value;
}

/// A plugin whose every read fails with [failure].
class _Failing extends FlutterSecureStoragePlatform with MockPlatformInterfaceMixin {
  _Failing(this.failure);

  final Object failure;
  int reads = 0;

  @override
  Future<String?> read({required String key, required Map<String, String> options}) async {
    reads++;
    throw failure;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Plugin plugin;
  late MacKeychain store;
  late List<String> listed;
  Map<String, Object?>? asked;
  const options = {'accountName': 'flutter_secure_storage_service', 'useDataProtectionKeyChain': 'false', 'synchronizable': 'false'};

  void answer(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(MacKeychain.channel, handler);
  }

  setUp(() {
    plugin = _Plugin();
    store = MacKeychain(plugin);
    listed = [];
    asked = null;
    answer((call) async {
      expect(call.method, 'names');
      asked = Map<String, Object?>.from(call.arguments as Map);
      return listed;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(MacKeychain.channel, null);
  });

  test('readAll lists the names by themselves, and reads each one', () async {
    plugin.kept.addAll({'p.a.identity_key_1': 'one', 'profiles_v1': 'the list'});
    listed = ['p.a.identity_key_1', 'profiles_v1'];
    expect(await store.readAll(options: options), {'p.a.identity_key_1': 'one', 'profiles_v1': 'the list'});
    expect(plugin.reads, ['p.a.identity_key_1', 'profiles_v1']);
    expect(asked!['options'], options, reason: 'the same options as a read: the same service, the same keychain');
  });

  test('a name that went between the list and its read is simply not there', () async {
    plugin.kept['profiles_v1'] = 'the list';
    listed = ['p.a.gone_just_now', 'profiles_v1'];
    expect(await store.readAll(options: options), {'profiles_v1': 'the list'});
  });

  test('nothing kept is nothing, and a failure of the list is said, never read as nothing', () async {
    expect(await store.readAll(options: options), isEmpty);
    answer((call) async => throw PlatformException(code: 'keychain', message: 'Code: -25308'));
    await expectLater(store.readAll(options: options), throwsA(isA<PlatformException>()));
  });

  test('deleteAll goes through the names too', () async {
    plugin.kept.addAll({'a': '1', 'b': '2'});
    listed = ['a', 'b'];
    await store.deleteAll(options: options);
    expect(plugin.kept, isEmpty);
    expect(plugin.deleted, ['a', 'b']);
  });

  // 3.3.2: what macOS answers when it does not let the app in. A read said no to
  // was read again at the next turn of whatever wanted it (sync, a team's
  // rounds), and macOS asked again each time.
  group('macOS says no', () {
    PlatformException said(int status) => PlatformException(
        code: 'Unexpected security result code', message: 'Code: $status, Message: made up', details: status);

    test('each of its answers that means no is said as KeychainAccessDenied, a PlatformException still', () async {
      for (final status in [-128, -25293, -25308, -34018]) {
        expect(KeychainAccessDenied.statusOf(said(status)), status);
      }
      // As the plugin's message alone says it.
      expect(KeychainAccessDenied.statusOf(PlatformException(code: 'Unexpected security result code', message: 'Code: -128')),
          -128);
      // Anything else is not.
      expect(KeychainAccessDenied.statusOf(said(-50)), isNull);
      expect(KeychainAccessDenied.statusOf(said(-25300)), isNull);
      expect(KeychainAccessDenied.statusOf(StateError('Code: -128')), isNull);

      plugin.kept['k'] = 'v';
      plugin.denied = (name) => true;
      await expectLater(
          store.read(key: 'k', options: options),
          throwsA(isA<KeychainAccessDenied>()
              .having((e) => e.status, 'status', -128)
              .having((e) => e.asked, 'asked', isTrue)
              .having((e) => e, 'a PlatformException', isA<PlatformException>())));
    });

    test('an item said no to fails at once for the rest of the run, macOS is not asked again, and others are', () async {
      plugin.kept.addAll({'p.a.sync_dek': 'dek', 'p.a.identity_key_1': 'one'});
      plugin.denied = (name) => name == 'p.a.sync_dek';
      var told = 0;
      store.denials.addListener(() => told++);

      await expectLater(store.read(key: 'p.a.sync_dek', options: options), throwsA(isA<KeychainAccessDenied>()));
      expect(store.denials.any, isTrue);
      expect(told, 1);
      for (var i = 0; i < 3; i++) {
        await expectLater(store.read(key: 'p.a.sync_dek', options: options),
            throwsA(isA<KeychainAccessDenied>().having((e) => e.asked, 'asked', isFalse)));
      }
      // A write of it would ask as well: it waits too.
      await expectLater(store.write(key: 'p.a.sync_dek', value: 'new', options: options), throwsA(isA<KeychainAccessDenied>()));
      expect(plugin.kept['p.a.sync_dek'], 'dek');
      expect(plugin.reads.where((name) => name == 'p.a.sync_dek'), hasLength(1), reason: 'macOS was asked once');
      expect(await store.read(key: 'p.a.identity_key_1', options: options), 'one');

      // The person chooses Try again, and Always Allow this time.
      plugin.denied = null;
      store.denials.tryAgain();
      expect(store.denials.any, isFalse);
      expect(told, 2);
      expect(await store.read(key: 'p.a.sync_dek', options: options), 'dek');
      expect(plugin.reads.where((name) => name == 'p.a.sync_dek'), hasLength(2));
    });

    test('another failure is the plugin\'s own, as it was, and nothing is kept of it', () async {
      final failing = _Failing(said(-25300));
      final over = MacKeychain(failing);
      for (var i = 0; i < 2; i++) {
        await expectLater(over.read(key: 'k', options: options),
            throwsA(isA<PlatformException>().having((e) => e is KeychainAccessDenied, 'a no', isFalse)));
      }
      expect(over.denials.any, isFalse);
      expect(failing.reads, 2, reason: 'asked each time, as before');
    });
  });

  test('every other call is the plugin\'s own', () async {
    await store.write(key: 'k', value: 'v', options: options);
    expect(await store.read(key: 'k', options: options), 'v');
    expect(await store.containsKey(key: 'k', options: options), isTrue);
    await store.delete(key: 'k', options: options);
    expect(plugin.kept, isEmpty);
  });

  group('with the store installed, as main.dart does it', () {
    late FlutterSecureStoragePlatform before;
    setUp(() {
      before = FlutterSecureStoragePlatform.instance;
      FlutterSecureStoragePlatform.instance = store;
      // What the channel lists is what the plugin holds.
      answer((call) async => plugin.kept.keys.toList());
    });
    tearDown(() {
      FlutterSecureStoragePlatform.instance = before;
      Profiles.debugReset();
    });

    test('the released callers\' way there lists: the app\'s own keychain, and the profile\'s view of it', () async {
      final id = newProfileId();
      plugin.kept.addAll({'p.$id.identity_key_1': 'one', 'profiles_v1': 'the list', 'p.${newProfileId()}.other': 'no'});
      expect(await deviceKeychain.readAll(), hasLength(3));
      Profiles.turnOn();
      Profiles.bind(ActiveProfile(id: id, dir: Directory.systemTemp));
      expect(await appKeychain.readAll(), {'identity_key_1': 'one'});
      await deviceKeychain.deleteAll();
      expect(plugin.kept, isEmpty);
    });

    Future<ProfileWorld> computer() async {
      final world = await ProfileWorld.create();
      addTearDown(world.dispose);
      world.realDevice = deviceKeychain;
      return world;
    }

    test('a fresh install starts: its first question was the one that failed', () async {
      final world = await computer();
      final manager = world.launch();
      await manager.start();
      final db = await manager.openCurrent();
      expect(await hostsOf(db), isEmpty);
      await db.close();
    });

    test('a list asks nobody anything: names alone, with nothing read', () async {
      plugin.kept.addAll({'p.a.identity_key_1': 'one', 'profiles_v1': 'the list'});
      expect(await keychainNamesIn(deviceKeychain), unorderedEquals(['p.a.identity_key_1', 'profiles_v1']));
      expect(plugin.reads, isEmpty);
    });

    test('a profile\'s view reads its own entries, and no other\'s', () async {
      final id = newProfileId();
      final other = 'p.${newProfileId()}.identity_key_other';
      plugin.kept.addAll({'p.$id.identity_key_1': 'one', 'profiles_v1': 'the list', other: 'not read'});
      Profiles.turnOn();
      Profiles.bind(ActiveProfile(id: id, dir: Directory.systemTemp));
      expect(await appKeychain.readAll(), {'identity_key_1': 'one'});
      expect(plugin.reads, ['p.$id.identity_key_1']);
      plugin.reads.clear();
      expect(await (appKeychain as ProfileKeychain).names(), ['identity_key_1']);
      expect(plugin.reads, isEmpty);
    });

    test('a later start opens with nothing of its secrets read: no question about each, and a Deny cannot stop it', () async {
      final world = await computer();
      await makeOldDatabase(world, wal: 'host-in-wal');
      plugin.kept.addAll({
        KeychainNames.databaseKey: kOldKey,
        'identity_key_k1': 'PRIVATE KEY OF K1',
        'identity_key_k2': 'PRIVATE KEY OF K2',
        'session_token': 'made.up.token',
        'session_uid': 'account-alice',
      });
      final first = world.launch();
      await first.start();
      final db = await first.openCurrent();
      await db.close();
      Profiles.debugReset();

      plugin.reads.clear();
      plugin.denied = (name) => name.contains('identity_key');
      final next = world.launch();
      await next.start();
      final again = await next.openCurrent();
      expect(await hostsOf(again), ['host-in-main', 'host-in-wal']);
      expect(plugin.reads.where((name) => name.contains('identity_key') || name.contains('session_token')), isEmpty);
      await again.close();
    });

    test('what was written while the database was closed is what an open seals: it reads that, and no more', () async {
      final world = await computer();
      final first = world.launch();
      await first.start();
      final db = await first.openCurrent();
      final open = ProfileKeychain(deviceKeychain, profile: () => Profiles.current, tree: () => db);
      await open.write(key: 'identity_key_sealed', value: 'sealed long ago');
      await db.close();
      final closed = ProfileKeychain(deviceKeychain, profile: () => Profiles.current, tree: () => null);
      await closed.write(key: 'device_session_v1', value: 'written while it was closed');
      final prefix = Profiles.current!.prefix;
      expect(plugin.kept['${prefix}device_session_v1'], 'written while it was closed');
      Profiles.debugReset();

      plugin.reads.clear();
      final next = world.launch();
      await next.start();
      final again = await next.openCurrent();
      expect(plugin.reads, contains('${prefix}device_session_v1'));
      expect(plugin.reads, isNot(contains('${prefix}identity_key_sealed')));
      expect(SecretSeal.isSealed(plugin.kept['${prefix}device_session_v1']), isTrue);
      expect(plugin.kept.containsKey('$prefix${KeychainNames.sealWaits}'), isFalse, reason: 'nothing waits now');
      await again.close();
    });

    // The same report: each read of an item an older build made may bring up macOS's
    // question, and a start read the list of profiles five times (whether a move was
    // needed, three times; the start; the profile's opening) and the key of the
    // profile it opened twice (the lock's check; the opening).
    test('a later start reads the list of profiles once, and the key of the profile it opens once', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final world = await computer();
      // As on a Mac: a start that has a move to do waits for Firebase to say who is signed in.
      world.firebaseReported = () async {};
      Future<AppDatabase> startTheApp() async {
        await bootProfiles(rawPrefs: world.rawPrefs, sayMoving: () async {}, manager: (_) => world.launch());
        return ProfileManager.instance!.openCurrent();
      }

      await (await startTheApp()).close();
      Profiles.debugReset();

      plugin.reads.clear();
      final db = await startTheApp();
      final id = Profiles.current!.id;
      expect(plugin.reads.where((name) => name == ProfileList.name), hasLength(1));
      expect(plugin.reads.where((name) => name == ProfileVault.plainName(id)), hasLength(1));
      expect(await hostsOf(db), isEmpty, reason: 'and it opened');
      await db.close();
    });

    // A reported bug: macOS asked about the keychain over and over. The
    // sweep of leftover secrets ran after every pull that changed something, and read
    // every secret's value to learn their names: one question for each, each time.
    group('the sweep of leftover secrets after a pull reads names, never a secret', () {
      Future<(AppDatabase, SettingsService)> here() async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        SharedPreferences.setMockInitialValues(const {});
        return (db, SettingsService(await SharedPreferences.getInstance()));
      }

      SyncDataService service(AppDatabase db, FlutterSecureStorage storage, SettingsService settings) => SyncDataService(
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
            settingsService: settings,
          );

      Future<void> identity(AppDatabase db, String id) => db.into(db.identities).insert(IdentitiesCompanion.insert(
          id: id, label: 'key $id', username: 'demo', authMethod: 'publicKey', createdAt: DateTime.utc(2026, 11, 5)));

      // What another device sent: nothing of these keys.
      Future<Map<String, dynamic>> pulled() async {
        final (other, settings) = await here();
        return service(other, deviceKeychain, settings).gatherAll();
      }

      test('the system\'s keychain', () async {
        final (db, settings) = await here();
        await identity(db, 'live');
        plugin.kept.addAll({
          'identity_key_live': 'PRIVATE KEY OF LIVE',
          'identity_key_gone': 'PRIVATE KEY OF GONE',
          'identity_password_gone': 'made-up-password',
        });
        final blob = await pulled();
        plugin.reads.clear();
        final result = await service(db, deviceKeychain, settings).restoreAll(blob);
        expect(result.success, isTrue);
        // (A pull reads what this device holds of its live keys, once, to merge; the
        // sweep reads nothing, so a leftover's secret is never read at all.)
        expect(plugin.reads.where((name) => name.endsWith('_gone') || name == 'profiles_v1'), isEmpty);
        expect(plugin.reads.where((name) => name == 'identity_key_live'), hasLength(1));
        expect(plugin.kept.keys, contains('identity_key_live'));
        expect(plugin.kept.keys, isNot(contains('identity_key_gone')));
        expect(plugin.kept.keys, isNot(contains('identity_password_gone')));
      });

      test('a profile\'s view of it, as a computer has it', () async {
        final (db, settings) = await here();
        await identity(db, 'live');
        final profile = ActiveProfile(id: newProfileId(), dir: Directory.systemTemp);
        final prefix = profile.prefix;
        plugin.kept.addAll({
          '${prefix}identity_key_live': 'PRIVATE KEY OF LIVE',
          '${prefix}identity_key_gone': 'PRIVATE KEY OF GONE',
          'profiles_v1': 'the list',
        });
        final blob = await pulled();
        plugin.reads.clear();
        final keychain = ProfileKeychain(deviceKeychain, profile: () => profile, tree: () => db);
        final result = await service(db, keychain, settings).restoreAll(blob);
        expect(result.success, isTrue);
        expect(plugin.reads.where((name) => name.endsWith('_gone') || name == 'profiles_v1'), isEmpty);
        expect(plugin.reads.where((name) => name == '${prefix}identity_key_live'), hasLength(1));
        expect(plugin.kept.keys, contains('${prefix}identity_key_live'));
        expect(plugin.kept.keys, isNot(contains('${prefix}identity_key_gone')));
      });
    });

    test('someone who used it before moves, and every open goes on working', () async {
      final world = await computer();
      await makeOldDatabase(world, wal: 'host-in-wal');
      plugin.kept.addAll({
        KeychainNames.databaseKey: kOldKey,
        'identity_key_k1': 'PRIVATE KEY OF K1',
        'session_token': 'made.up.token',
        'session_uid': 'account-alice',
      });
      final manager = world.launch();
      await manager.start();
      final db = await manager.openCurrent();
      expect(await hostsOf(db), ['host-in-main', 'host-in-wal']);
      final keychain = ProfileKeychain(deviceKeychain, profile: () => Profiles.current, tree: () => db);
      expect(await keychain.read(key: 'identity_key_k1'), 'PRIVATE KEY OF K1');
      expect(plugin.kept.containsKey('identity_key_k1'), isFalse, reason: 'the original went');
      await db.close();
    });
  });
}
