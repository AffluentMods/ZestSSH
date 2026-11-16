import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/profile_list.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';
import 'package:zestssh/services/profiles/profile_vault.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/session_transcript_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/services/vault_slot_service.dart';
import 'package:zestssh/ui/screens/profile/widgets/guest_data_question.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

import 'profile_world.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(false);
  @override
  Future<void> refresh() async {}
  @override
  void signedOut() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Juiced extends StateNotifier<bool> implements CloudSyncStatusNotifier {
  _Juiced() : super(false);
  @override
  Future<void> refresh() async {}
  @override
  void signedOut() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Devices implements DeviceSessionService {
  @override
  Future<void> signOutHere({Duration within = const Duration(seconds: 6)}) async {}
  @override
  Future<void> forget() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The plugin's interface over the kept map: what SessionTranscriptService reaches.
class _OverMemory extends FlutterSecureStoragePlatform with MockPlatformInterfaceMixin {
  _OverMemory(this.kept);
  final Map<String, String> kept;
  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) async => kept.containsKey(key);
  @override
  Future<void> delete({required String key, required Map<String, String> options}) async => kept.remove(key);
  @override
  Future<void> deleteAll({required Map<String, String> options}) async => kept.clear();
  @override
  Future<String?> read({required String key, required Map<String, String> options}) async => kept[key];
  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) async => Map.of(kept);
  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) async =>
      kept[key] = value;
}

class _Recording implements SyncDataService {
  _Recording(this.real);
  final SyncDataService real;
  Map<String, dynamic>? got;
  @override
  Future<SyncRestoreResult> restoreAll(Map<String, dynamic> data, {SyncMergeBase? merge, bool asBackup = false}) {
    got = data;
    return real.restoreAll(data, merge: merge, asBackup: asBackup);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Refusing implements SyncDataService {
  @override
  Future<SyncRestoreResult> restoreAll(Map<String, dynamic> data, {SyncMergeBase? merge, bool asBackup = false}) async =>
      const SyncRestoreResult(success: false, recordsRestored: 0, error: 'written by a newer version');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The question at a first sign-in on a computer with guest data,
/// and what comes of each answer.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const uid = 'account-sam';

  late ProfileWorld world;
  setUp(() async => world = await ProfileWorld.create());
  tearDown(() => world.dispose());

  SyncDataService serviceOf(AppDatabase db, ActiveProfile profile) => SyncDataService(
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
        secureStorage: world.keychainOf(profile, db),
        settingsService: SettingsService(world.rawPrefs),
      );

  /// Guest data on screen, with two hosts and a key with its secret.
  Future<(ProfileManager, AppDatabase)> guestWithHosts() async {
    final manager = world.launch();
    await manager.start();
    final db = await manager.openCurrent();
    SecretSeal.openTree = db;
    await addHost(db, 'guest-host-1');
    await addHost(db, 'guest-host-2');
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
          id: 'guest-key',
          label: 'a key',
          username: 'demo',
          authMethod: 'publicKey',
          createdAt: DateTime.utc(2026, 10, 30),
        ));
    await world.keychainOf(Profiles.current!, db).write(key: 'identity_key_guest-key', value: 'PRIVATE KEY OF THE GUEST');
    return (manager, db);
  }

  Future<AppDatabase> signIn(ProfileManager manager, AppDatabase from) async {
    final prepared = await manager.prepare(await manager.planForAccount(uid: uid, label: 'sam@example.com', bearer: 'b'));
    await from.close();
    await manager.commit(prepared);
    SecretSeal.openTree = prepared.db;
    await manager.settleLockedCopy(db: prepared.db, bearer: 'b');
    return prepared.db;
  }

  ProviderContainer app(AppDatabase db) {
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(ProfilePreferences.instance!),
      secureStorageProvider.overrideWithValue(ProfileKeychain(world.device)),
      isProProvider.overrideWith((ref) => _Pro()),
      isCloudSyncProvider.overrideWith((ref) => _Juiced()),
      deviceSessionServiceProvider.overrideWithValue(_Devices()),
    ]);
    c.read(databaseSessionProvider.notifier).seed(db);
    addTearDown(c.dispose);
    return c;
  }

  group('what it holds', () {
    test('asked with an account on screen: its hosts and keys, and nothing changes by asking', () async {
      final (manager, guest) = await guestWithHosts();
      final guestId = manager.currentEntry!.id;
      expect(await manager.lookAtGuest(), isNull, reason: 'guest data is what is on screen');
      final db = await signIn(manager, guest);
      final summary = await manager.lookAtGuest();
      expect(summary!.hosts, 2);
      expect(summary.keys, 1);
      expect(manager.list.byId(guestId)!.state, ProfileState.open);
      await db.close();
    });

    test('no guest data on this computer: nothing to ask', () async {
      final manager = world.launch();
      await manager.start();
      expect(await manager.lookAtGuest(), isNull);
    });

    test('an empty guest profile: said as empty, so nothing is asked', () async {
      final manager = world.launch();
      await manager.start();
      final guest = await manager.openCurrent();
      SecretSeal.openTree = guest;
      final db = await signIn(manager, guest);
      expect((await manager.lookAtGuest())!.empty, isTrue);
      await db.close();
    });
  });

  group('when it is asked', () {
    test('a new account, once its session is written, and not before; a known account, never', () async {
      final (manager, guest) = await guestWithHosts();
      final c = app(guest);
      final profiles = c.read(profileControllerProvider);
      var asked = 0;
      profiles.onGuestData = () => asked++;

      await profiles.openForAccount(uid: uid, label: 'sam@example.com', bearer: 'b');
      expect(asked, 0, reason: 'not while the session is being written');
      await world.keychainOf(Profiles.current!, c.read(databaseSessionProvider)).write(key: 'session_token', value: 'made.up.token');
      await profiles.sessionKept();
      expect(asked, 1);

      // Signed out, and in again: it was asked.
      await profiles.lockAfterSignOut();
      await profiles.openForAccount(uid: uid, label: 'sam@example.com', bearer: 'b');
      await world.keychainOf(Profiles.current!, c.read(databaseSessionProvider)).write(key: 'session_token', value: 'made.up.token');
      await profiles.sessionKept();
      expect(asked, 1);
      await c.read(databaseSessionProvider)!.close();
    });

    test('a sign-in whose session could not be written asks nothing', () async {
      final (manager, guest) = await guestWithHosts();
      expect(manager.currentEntry!.uid, isNull);
      final c = app(guest);
      final profiles = c.read(profileControllerProvider);
      var asked = 0;
      profiles.onGuestData = () => asked++;
      await profiles.openForAccount(uid: uid, label: 'sam@example.com', bearer: 'b');
      await profiles.sessionNotKept();
      expect(asked, 0);
      await c.read(databaseSessionProvider)!.close();
    });
  });

  group('kept', () {
    test('nothing moves: the account is empty, guest data is whole behind it, and it can still come in later', () async {
      final (manager, guest) = await guestWithHosts();
      final guestId = manager.currentEntry!.id;
      final db = await signIn(manager, guest);
      expect(await hostsOf(db), isEmpty);
      expect(manager.list.byId(guestId)!.state, ProfileState.open);
      expect(world.rawNames(guestId), isNotEmpty);

      // Later, from the account page.
      await manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: world.keychainOf(Profiles.current!, db));
      expect(await hostsOf(db), ['guest-host-1', 'guest-host-2']);
      await db.close();
    });
  });

  group('brought in', () {
    test('hosts and keys are the account\'s, sealed for it; the guest profile is gone, and locked with the account', () async {
      final (manager, guest) = await guestWithHosts();
      final guestId = manager.currentEntry!.id;
      final db = await signIn(manager, guest);
      await addHost(db, 'the-account-had-this');
      final id = manager.currentEntry!.id;
      final mine = world.keychainOf(Profiles.current!, db);
      await manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: mine);

      expect(await hostsOf(db), ['guest-host-1', 'guest-host-2', 'the-account-had-this']);
      expect(await mine.read(key: 'identity_key_guest-key'), 'PRIVATE KEY OF THE GUEST');
      expect(SecretSeal.isSealed(world.device.kept[KeychainNames.full(id, uid, 'identity_key_guest-key')]), isTrue);
      // Nothing of it stays in the open.
      expect(manager.list.byId(guestId), isNull);
      expect(world.rawNames(guestId), isEmpty);
      expect(ProfilePaths.ofProfile(world.base, guestId).existsSync(), isFalse);

      // Signed out: guest data is a new, empty one, and what came in is locked.
      SecretSeal.openTree = null;
      expect(await manager.lockCurrent(), SignOutEnd.locked);
      final fresh = await manager.openGuest();
      await db.close();
      SecretSeal.openTree = fresh;
      expect(await hostsOf(fresh), isEmpty);
      expect(world.device.kept.containsKey(ProfileVault.plainName(id)), isFalse);
      final back = await signIn(manager, fresh);
      expect(await hostsOf(back), ['guest-host-1', 'guest-host-2', 'the-account-had-this']);
      await back.close();
    });

    test('with the app lock on: guest data opens with the vault key, and it comes the same', () async {
      final (manager, guest) = await guestWithHosts();
      final guestId = manager.currentEntry!.id;
      final db = await signIn(manager, guest);
      final keys = {for (final id in manager.list.withKeyHere) id: await manager.keyHexOf(manager.list.byId(id)!)};
      final slots = VaultSlotService(ProfileKeychain(world.device, profile: () => Profiles.current));
      manager.vaultKey = await manager.vault.turnOn(keys: keys, slots: slots, pin: '4242');
      expect(world.device.kept.containsKey(ProfileVault.plainName(guestId)), isFalse);

      expect((await manager.lookAtGuest())!.hosts, 2);
      final mine = world.keychainOf(Profiles.current!, db);
      await manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: mine);
      expect(await hostsOf(db), ['guest-host-1', 'guest-host-2']);
      expect(await mine.read(key: 'identity_key_guest-key'), 'PRIVATE KEY OF THE GUEST');
      expect(world.rawNames(guestId), isEmpty);
      await db.close();
    });

    test('what guest data deleted once is none of this account\'s business', () async {
      final (manager, guest) = await guestWithHosts();
      await guest.tombstonesDao.mark('connections', 'the-account-had-this', at: DateTime.utc(2031));
      final db = await signIn(manager, guest);
      final at = DateTime.utc(2030);
      await db.into(db.connections).insert(
          ConnectionsCompanion.insert(id: 'the-account-had-this', label: 'x', host: 'x.example.com', createdAt: at, updatedAt: at));
      await manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: world.keychainOf(Profiles.current!, db));
      expect(await hostsOf(db), contains('the-account-had-this'));
      expect(await db.tombstonesDao.getAll(), isEmpty, reason: 'a sync would carry it to every device of the account');
      await db.close();
    });

    test('its settings and its team keys stay out of what comes: the account\'s are the account\'s', () async {
      final (manager, guest) = await guestWithHosts();
      final db = await signIn(manager, guest);
      final into = _Recording(serviceOf(db, Profiles.current!));
      await manager.bringGuestInto(into, db: db, keychain: world.keychainOf(Profiles.current!, db));
      expect(into.got!.containsKey('settings'), isFalse);
      expect(into.got!.containsKey('account_keys'), isFalse);
      expect(into.got!.containsKey('connections'), isTrue);
      await db.close();
    });

    test('session logs come along, and a name taken here is not written over', () async {
      final (manager, guest) = await guestWithHosts();
      final guestId = manager.currentEntry!.id;
      final db = await signIn(manager, guest);
      final id = manager.currentEntry!.id;
      final logs = Directory(p.join(world.folders.documents.path, 'ZestSSH', 'session-logs'));
      final theirs = await Directory(p.join(logs.path, guestId)).create(recursive: true);
      final mine = await Directory(p.join(logs.path, id)).create(recursive: true);
      await File(p.join(theirs.path, 'a.log')).writeAsString('the guest\'s');
      await File(p.join(theirs.path, 'b.log')).writeAsString('the guest\'s b');
      await File(p.join(mine.path, 'a.log')).writeAsString('the account\'s');
      await manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: world.keychainOf(Profiles.current!, db));
      expect(File(p.join(mine.path, 'a.log')).readAsStringSync(), 'the account\'s');
      expect(File(p.join(mine.path, 'a (2).log')).readAsStringSync(), 'the guest\'s');
      expect(File(p.join(mine.path, 'b.log')).readAsStringSync(), 'the guest\'s b');
      expect(theirs.existsSync(), isFalse);
      await db.close();
    });

    group('recordings', () {
      late FlutterSecureStoragePlatform before;
      setUp(() {
        before = FlutterSecureStoragePlatform.instance;
        FlutterSecureStoragePlatform.instance = _OverMemory(world.device.kept);
      });
      tearDown(() => FlutterSecureStoragePlatform.instance = before);

      Future<String> recordingAt(ProfileWorld world, String id, String name, String text) async {
        final folder = await Directory(p.join(world.folders.documents.path, 'ZestSSH', 'transcripts', id)).create(recursive: true);
        final path = p.join(folder.path, name);
        expect(await SessionTranscriptService.saveTextToPath(text, path, encrypt: true), path);
        return path;
      }

      test('an account with no recordings of its own takes their key, and each opens', () async {
        final (manager, guest) = await guestWithHosts();
        final guestId = manager.currentEntry!.id;
        await recordingAt(world, guestId, 'one.zesttx', 'what the guest recorded');
        final db = await signIn(manager, guest);
        final id = manager.currentEntry!.id;
        await manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: ProfileKeychain(world.device));
        final path = p.join(world.folders.documents.path, 'ZestSSH', 'transcripts', id, 'one.zesttx');
        expect(await SessionTranscriptService.readFromFile(path), 'what the guest recorded');
        await db.close();
      });

      test('an account with its own: each is opened with their key and encrypted with its own, and all open', () async {
        final (manager, guest) = await guestWithHosts();
        final guestId = manager.currentEntry!.id;
        await recordingAt(world, guestId, 'one.zesttx', 'what the guest recorded');
        final db = await signIn(manager, guest);
        final id = manager.currentEntry!.id;
        final own = await recordingAt(world, id, 'own.zesttx', 'what the account recorded');
        await manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: ProfileKeychain(world.device));
        final path = p.join(world.folders.documents.path, 'ZestSSH', 'transcripts', id, 'one.zesttx');
        expect(await SessionTranscriptService.readFromFile(path), 'what the guest recorded');
        expect(await SessionTranscriptService.readFromFile(own), 'what the account recorded');
        await db.close();
      });
    });
  });

  group('whatever goes wrong, nothing is lost', () {
    test('it cannot be brought in: guest data is as it was, it is said, and it can be tried again', () async {
      final (manager, guest) = await guestWithHosts();
      final guestId = manager.currentEntry!.id;
      final db = await signIn(manager, guest);
      await expectLater(
        manager.bringGuestInto(_Refusing(), db: db, keychain: world.keychainOf(Profiles.current!, db)),
        throwsStateError,
      );
      expect(manager.list.byId(guestId)!.state, ProfileState.open);
      expect(world.rawNames(guestId), isNotEmpty);
      expect((await manager.lookAtGuest())!.hosts, 2);
      await db.close();
    });

    for (final boundary in ['guest:restored', 'guest:tables', 'guest:secrets', 'guest:files', 'guest:listed']) {
      test('stopped at $boundary: the hosts are at one place or both, and the next start goes on', () async {
        final (first, guest) = await guestWithHosts();
        final guestId = first.currentEntry!.id;
        final signedIn = await signIn(first, guest);
        final id = first.currentEntry!.id;
        await signedIn.close();
        SecretSeal.openTree = null;
        Profiles.debugReset();

        world.stop = (at) {
          if (at == boundary) throw const PlayedStop('here');
        };
        final manager = world.launch();
        await manager.start();
        final db = await manager.openCurrent();
        SecretSeal.openTree = db;
        expect(manager.currentEntry!.id, id);
        expect(
          await untilStopped(() => manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: world.keychainOf(Profiles.current!, db))),
          isTrue,
        );
        world.stop = null;
        expect(await hostsOf(db), ['guest-host-1', 'guest-host-2']);
        await db.close();
        SecretSeal.openTree = null;
        Profiles.debugReset();

        final next = world.launch();
        await next.start();
        final again = await next.openCurrent();
        SecretSeal.openTree = again;
        expect(await hostsOf(again), ['guest-host-1', 'guest-host-2']);
        expect(await world.keychainOf(Profiles.current!, again).read(key: 'identity_key_guest-key'), 'PRIVATE KEY OF THE GUEST');
        if (next.list.byId(guestId) != null) {
          await next.bringGuestInto(serviceOf(again, Profiles.current!), db: again, keychain: world.keychainOf(Profiles.current!, again));
        }
        expect(next.list.byId(guestId), isNull);
        expect(world.rawNames(guestId), isEmpty);
        expect(await hostsOf(again), ['guest-host-1', 'guest-host-2']);
        await again.close();
      });
    }

    test('something holds one of its files: the guest profile stays, as that file would go with it, and it is said', () async {
      final (manager, guest) = await guestWithHosts();
      final guestId = manager.currentEntry!.id;
      final db = await signIn(manager, guest);
      final logs = Directory(p.join(world.folders.documents.path, 'ZestSSH', 'session-logs', guestId));
      await logs.create(recursive: true);
      final log = File(p.join(logs.path, 'held.log'));
      await log.writeAsString('open in an editor');
      final held = await log.open(mode: FileMode.append);
      await expectLater(
        manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: world.keychainOf(Profiles.current!, db)),
        throwsA(isA<GuestFilesHeld>().having((e) => e.count, 'count', 1)),
      );
      expect(manager.list.byId(guestId)!.state, ProfileState.open);
      expect(world.rawNames(guestId), isNotEmpty);
      expect(log.existsSync(), isTrue);
      await held.close();
      // Let go of, it goes through, and the hosts are not there twice.
      await manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: world.keychainOf(Profiles.current!, db));
      expect(await hostsOf(db), ['guest-host-1', 'guest-host-2']);
      expect(manager.list.byId(guestId), isNull);
      expect(File(p.join(world.folders.documents.path, 'ZestSSH', 'session-logs', manager.currentEntry!.id, 'held.log')).readAsStringSync(), 'open in an editor');
      await db.close();
    }, skip: Platform.isWindows ? false : 'a file held open stops a rename on Windows alone');

    for (final bringing in [false, true]) {
      test('its database fails its upgrade as it is ${bringing ? 'brought in' : 'looked at'}: it is put back as it was, and the next try opens it', () async {
        final (manager, guest) = await guestWithHosts();
        final guestId = manager.currentEntry!.id;
        await (await signIn(manager, guest)).close();
        SecretSeal.openTree = null;
        Profiles.debugReset();

        // A later release: its upgrade fails halfway, once.
        var failing = true;
        world.openDatabase = (dir, hex) async {
          if (failing && dir.path.contains(guestId)) {
            await File(p.join(dir.path, 'zestssh.db')).writeAsBytes(const [1, 2, 3], flush: true);
            throw StateError('no such table: the_new_one');
          }
          return openPlayed(dir, hex);
        };
        final later = world.launch();
        await later.start();
        final db = await later.openCurrent();
        SecretSeal.openTree = db;
        final service = serviceOf(db, Profiles.current!);
        final keychain = world.keychainOf(Profiles.current!, db);
        if (bringing) {
          await expectLater(later.bringGuestInto(service, db: db, keychain: keychain), throwsStateError);
        } else {
          expect(await later.lookAtGuest(), isNull);
        }
        expect(later.list.byId(guestId), isNotNull);

        failing = false;
        expect((await later.lookAtGuest())!.hosts, 2);
        await later.bringGuestInto(service, db: db, keychain: keychain);
        expect(await hostsOf(db), ['guest-host-1', 'guest-host-2']);
        await db.close();
      });
    }

    test('guest data that does not open is not asked about, and stays', () async {
      final (manager, guest) = await guestWithHosts();
      final guestId = manager.currentEntry!.id;
      final db = await signIn(manager, guest);
      world.device.kept[ProfileVault.plainName(guestId)] = 'bb00';
      expect(await manager.lookAtGuest(), isNull);
      await expectLater(
        manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: world.keychainOf(Profiles.current!, db)),
        throwsA(isA<WrongKey>()),
      );
      expect(manager.list.byId(guestId)!.state, ProfileState.open);
      await db.close();
    });
  });

  group('on the screen', () {
    final l10n = lookupAppLocalizations(const Locale('en'));

    Future<(BuildContext, WidgetRef, _Profiles)> host(WidgetTester tester, {GuestDataSummary? found}) async {
      debugTopSnackBarOnPhone = true;
      addTearDown(() => debugTopSnackBarOnPhone = null);
      SharedPreferences.setMockInitialValues({});
      final prefs = await tester.runAsync(SharedPreferences.getInstance);
      final profiles = _Profiles(found);
      late BuildContext context;
      late WidgetRef ref;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs!),
          profileControllerProvider.overrideWithValue(profiles),
          currentUserProvider.overrideWith((_) => const UserProfile(uid: uid, email: 'sam@example.com')),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: Consumer(builder: (c, r, _) {
            context = c;
            ref = r;
            return GuestDataRow(
              builder: (_, summary, onChoose) => TextButton(onPressed: onChoose, child: Text(l10n.guestDataRowDesc(summary.hosts))),
            );
          })),
        ),
      ));
      await tester.pumpAndSettle();
      return (context, ref, profiles);
    }

    testWidgets('the question says how many, and whose: Keep is an answer, and closing it is too', (tester) async {
      final (context, ref, profiles) = await host(tester);
      unawaited(showGuestDataQuestion(context, ref, const GuestDataSummary(hosts: 12, keys: 2)));
      await tester.pumpAndSettle();
      expect(find.text(l10n.guestDataQuestion(12, 'sam@example.com')), findsOneWidget);
      await tester.tap(find.text(l10n.guestDataKeep));
      await tester.pumpAndSettle();
      expect(profiles.brought, 0);
    });

    for (final (how, close) in <(String, Future<void> Function(WidgetTester))>[
      ('the cross', (tester) => tester.tap(find.byTooltip(l10n.close))),
      ('Escape', (tester) => tester.sendKeyEvent(LogicalKeyboardKey.escape)),
      ('a tap outside it', (tester) => tester.tapAt(const Offset(4, 4))),
    ]) {
      testWidgets('$how: nothing is brought, and the question is gone', (tester) async {
        final (context, ref, profiles) = await host(tester);
        unawaited(showGuestDataQuestion(context, ref, const GuestDataSummary(hosts: 12, keys: 2)));
        await tester.pumpAndSettle();
        await close(tester);
        await tester.pumpAndSettle();
        expect(find.text(l10n.guestDataBring), findsNothing);
        expect(profiles.brought, 0);
      });
    }

    testWidgets('what stayed is said, where something cannot come', (tester) async {
      final (context, ref, profiles) = await host(tester);
      profiles.failure = const GuestKindsStayed(['orchard_info']);
      unawaited(showGuestDataQuestion(context, ref, const GuestDataSummary(hosts: 12, keys: 2)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.guestDataBring));
      await tester.pumpAndSettle();
      expect(find.text(l10n.guestDataKindsStayed), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('a secret that will not read back says it could not be brought', (tester) async {
      final (context, ref, profiles) = await host(tester);
      profiles.failure = const GuestSecretsNotBrought(1);
      unawaited(showGuestDataQuestion(context, ref, const GuestDataSummary(hosts: 12, keys: 2)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.guestDataBring));
      await tester.pumpAndSettle();
      expect(find.text(l10n.guestDataNotBrought), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('keys alone are said as keys', (tester) async {
      final (context, ref, _) = await host(tester);
      unawaited(showGuestDataQuestion(context, ref, const GuestDataSummary(hosts: 0, keys: 2)));
      await tester.pumpAndSettle();
      expect(find.text(l10n.guestDataQuestionKeys(2, 'sam@example.com')), findsOneWidget);
    });

    testWidgets('Bring: it comes in, and says so', (tester) async {
      final (context, ref, profiles) = await host(tester);
      unawaited(showGuestDataQuestion(context, ref, const GuestDataSummary(hosts: 12, keys: 2)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.guestDataBring));
      await tester.pumpAndSettle();
      expect(profiles.brought, 1);
      expect(find.text(l10n.guestDataBrought), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('Bring that fails says so, and what to do', (tester) async {
      final (context, ref, profiles) = await host(tester);
      profiles.fails = true;
      unawaited(showGuestDataQuestion(context, ref, const GuestDataSummary(hosts: 12, keys: 2)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.guestDataBring));
      await tester.pumpAndSettle();
      expect(find.text(l10n.guestDataNotBrought), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('Bring with a file held says what came and what to do', (tester) async {
      final (context, ref, profiles) = await host(tester);
      profiles.failure = const GuestFilesHeld(1);
      unawaited(showGuestDataQuestion(context, ref, const GuestDataSummary(hosts: 12, keys: 2)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.guestDataBring));
      await tester.pumpAndSettle();
      expect(find.text(l10n.guestDataFilesHeld), findsOneWidget);
      expect(find.text(l10n.guestDataNotBrought), findsNothing);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('the account page has it for as long as there is anything to bring', (tester) async {
      final (_, _, profiles) = await host(tester, found: const GuestDataSummary(hosts: 3, keys: 0));
      expect(find.text(l10n.guestDataRowDesc(3)), findsOneWidget);
      await tester.tap(find.text(l10n.guestDataRowDesc(3)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.guestDataBring));
      await tester.pumpAndSettle();
      expect(profiles.brought, 1);
      // Nothing left: the row goes.
      expect(find.text(l10n.guestDataRowDesc(3)), findsNothing);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('nothing to bring: no row', (tester) async {
      await host(tester, found: const GuestDataSummary(hosts: 0, keys: 0));
      expect(find.text(l10n.guestDataRowDesc(0)), findsNothing);
      await host(tester);
      expect(find.byType(TextButton), findsNothing);
    });

    test('the app asks once the session is written, and the page has the row', () {
      final app = File('lib/app.dart').readAsStringSync();
      expect(app, contains('profiles.onGuestData = () => unawaited(_askAboutGuestData());'));
      final page = File('lib/ui/screens/profile/profile_screen.dart').readAsStringSync();
      expect(page, contains('GuestDataRow('));
    });
  });
}

class _Profiles implements ProfileController {
  _Profiles(this.found);
  GuestDataSummary? found;
  int brought = 0;
  bool fails = false;
  Object? failure;

  @override
  Future<GuestDataSummary?> guestData() async => found;

  @override
  Future<void> bringGuestData() async {
    if (fails) throw StateError('it could not');
    if (failure != null) throw failure!;
    brought++;
    found = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
