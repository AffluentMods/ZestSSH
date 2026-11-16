import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/account_sign_out.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account/local_data_wiper.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/profile_list.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';
import 'package:zestssh/services/profiles/profile_vault.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/vault_slot_service.dart';

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

/// Deleting: an account's or a profile's data goes while the profile is still
/// open, and nothing of another profile, the app lock or the list is touched.
/// (Account deletion and Delete all local data signed out first and then wiped
/// whatever was open: with profiles that would be the guest data, every other
/// profile's keys and the lock.)
void main() {
  const alice = 'account-alice';
  const bob = 'account-bob';
  const pin = '4242';

  late ProfileWorld world;
  setUp(() async => world = await ProfileWorld.create());
  tearDown(() => world.dispose());

  /// Guest data with a host, Bob signed out and locked, Alice on screen, with a
  /// host, a secret, a setting and files of each.
  Future<(ProfileManager, AppDatabase, String, String, String)> threeProfiles({bool lock = false}) async {
    final manager = world.launch();
    await manager.start();
    var db = await manager.openCurrent();
    await addHost(db, 'guest-host');
    final guest = manager.currentEntry!.id;
    await world.keychainOf(Profiles.current!, db).write(key: 'identity_key_g', value: 'GUEST KEY');
    await manager.prefs.setString('terminal_theme', 'guest-theme');

    Future<AppDatabase> signIn(String uid, AppDatabase from) async {
      final plan = await manager.planForAccount(uid: uid, label: '$uid@example.com', bearer: 't');
      final prepared = await manager.prepare(plan);
      await from.close();
      await manager.commit(prepared);
      await manager.settleLockedCopy(db: prepared.db, bearer: 't', replace: plan.replaceSecret);
      return prepared.db;
    }

    db = await signIn(bob, db);
    await addHost(db, 'bob-host');
    final bobId = manager.currentEntry!.id;
    await world.keychainOf(Profiles.current!, db).write(key: 'identity_key_b', value: 'BOB KEY');
    await manager.lockCurrent();
    final next = await manager.openGuest();
    await db.close();
    db = await signIn(alice, next);
    await addHost(db, 'alice-host');
    final aliceId = manager.currentEntry!.id;
    await world.keychainOf(Profiles.current!, db).write(key: 'identity_key_a', value: 'ALICE KEY');
    await manager.prefs.setString('terminal_theme', 'alice-theme');
    final docs = world.folders.documents;
    for (final id in [guest, bobId, aliceId]) {
      final logs = await Directory(p.join(docs.path, 'ZestSSH', 'session-logs', id)).create(recursive: true);
      await File(p.join(logs.path, 'a.log')).writeAsString('log of $id');
    }
    await world.rawPrefs.setDouble('desktop_sidebar_width', 300);
    world.device.kept['security_lock_method'] = 'pin';
    if (lock) {
      final keys = {for (final id in manager.list.withKeyHere) id: await manager.keyHexOf(manager.list.byId(id)!)};
      final slots = VaultSlotService(ProfileKeychain(world.device, profile: () => Profiles.current));
      manager.vaultKey = await manager.vault.turnOn(keys: keys, slots: slots, pin: pin);
    }
    return (manager, db, guest, bobId, aliceId);
  }

  Future<void> wipeOpen(ProfileManager manager, AppDatabase db, String id) async {
    SecretSeal.openTree = db;
    final targets = WipeTargets(
      ownedDirectories: [Directory(p.join(world.folders.documents.path, 'ZestSSH', 'session-logs', id))],
    );
    await LocalDataWiper(
      database: db,
      secureStorage: ProfileKeychain(world.device),
      preferences: manager.prefs,
      targets: targets,
      deleteDatabaseCopies: () async {},
      listMigrationBackups: () async => const [],
    ).wipe();
  }

  test('a wipe of the profile on screen touches nothing of another profile, the lock or the list', () async {
    final (manager, db, guest, bobId, aliceId) = await threeProfiles(lock: true);
    final bobEntries = world.rawNames(bobId);
    final guestEntries = world.rawNames(guest);
    final slots = world.device.kept[ProfileVault.slotsName];
    final bobLog = File(p.join(world.folders.documents.path, 'ZestSSH', 'session-logs', bobId, 'a.log'));
    final aliceBackup = File(p.join(world.folders.documents.path, 'ZestSSH', 'backups', aliceId, 'zestssh_auto_1.zest'));
    final bobBackup = File(p.join(world.folders.documents.path, 'ZestSSH', 'backups', bobId, 'zestssh_auto_1.zest'));
    await aliceBackup.create(recursive: true);
    await bobBackup.create(recursive: true);

    await wipeOpen(manager, db, aliceId);
    expect(await hostsOf(db), isEmpty);
    expect(await world.keychainOf(Profiles.current!, db).read(key: 'identity_key_a'), isNull);
    expect(manager.prefs.getString('terminal_theme'), isNull);
    // The device's settings stay.
    expect(world.rawPrefs.getDouble('desktop_sidebar_width'), 300);
    // Its key stays while its database is open.
    expect(world.device.kept.containsKey(ProfileVault.wrappedName(aliceId)), isTrue);

    await manager.markCurrentRemoving();
    final guestDb = await manager.openGuest();
    await db.close();
    await manager.finishRemovals();

    expect(manager.list.byId(aliceId), isNull);
    expect(ProfilePaths.ofProfile(world.base, aliceId).existsSync(), isFalse);
    expect(world.rawNames(aliceId), isEmpty);
    expect(Directory(p.join(world.folders.documents.path, 'ZestSSH', 'session-logs', aliceId)).existsSync(), isFalse);
    expect(aliceBackup.existsSync(), isFalse, reason: 'the local backup destination\'s copies are the profile\'s');
    expect(bobBackup.existsSync(), isTrue);
    // The others are as they were.
    expect(world.rawNames(bobId), bobEntries);
    expect(world.rawNames(guest), guestEntries);
    expect(bobLog.existsSync(), isTrue);
    expect(world.device.kept[ProfileVault.slotsName], slots);
    expect(world.device.kept['security_lock_method'], 'pin');
    expect(manager.list.byId(bobId)!.state, ProfileState.locked);
    expect(manager.currentEntry!.id, guest);
    expect(await hostsOf(guestDb), ['guest-host']);
    expect(manager.prefs.getString('terminal_theme'), 'guest-theme');
    expect(await world.keychainOf(Profiles.current!, guestDb).read(key: 'identity_key_g'), 'GUEST KEY');
    await guestDb.close();
  });

  test('a removal that stopped is finished at the next start, and touches no other', () async {
    final (manager, db, guest, bobId, aliceId) = await threeProfiles();
    await wipeOpen(manager, db, aliceId);
    await manager.markCurrentRemoving();
    await db.close();
    Profiles.debugReset();

    final next = world.launch();
    await next.start();
    expect(next.list.byId(aliceId), isNull);
    expect(ProfilePaths.ofProfile(world.base, aliceId).existsSync(), isFalse);
    expect(world.rawNames(aliceId), isEmpty);
    expect(next.currentEntry!.id, guest);
    expect(next.list.byId(bobId), isNotNull);
    final opened = await next.openCurrent();
    expect(await hostsOf(opened), ['guest-host']);
    await opened.close();
  });

  test('wiping guest data leaves new guest data, and the account profiles as they were', () async {
    final (manager, db, guest, bobId, aliceId) = await threeProfiles();
    // Alice locks, and guest data is on screen.
    await manager.lockCurrent();
    final guestDb = await manager.openGuest();
    await db.close();
    expect(manager.currentEntry!.id, guest);
    await wipeOpen(manager, guestDb, guest);
    await manager.markCurrentRemoving();
    final fresh = await manager.openGuest();
    await guestDb.close();
    await manager.finishRemovals();
    expect(manager.currentEntry!.uid, isNull);
    expect(manager.currentEntry!.id, isNot(guest));
    expect(await hostsOf(fresh), isEmpty);
    expect(manager.list.byId(aliceId)!.state, ProfileState.locked);
    expect(manager.list.byId(bobId)!.state, ProfileState.locked);
    expect(world.rawNames(guest), isEmpty);
    await fresh.close();
  });

  test('a deleted account: its profile stays open until the person answers, and is never locked', () async {
    final (manager, db, guest, _, aliceId) = await threeProfiles();
    expect(await manager.copies.confirmed(aliceId), isNotNull);
    await manager.markAccountGone();
    expect(manager.list.byId(aliceId)!.state, ProfileState.gone);
    expect(await manager.copies.confirmed(aliceId), isNull, reason: 'ZestSSH Cloud holds no secret for it any more');
    expect(world.device.kept[ProfileVault.plainName(aliceId)], isNotNull);

    // Kept: it is the guest data now, and what there was before is set aside
    // whole. Nothing is merged, and nothing is lost.
    await manager.keepCurrentAsGuest();
    expect(manager.currentEntry!.id, aliceId);
    expect(manager.currentEntry!.uid, isNull);
    expect(manager.list.guest!.id, aliceId);
    expect(manager.list.byId(guest)!.state, ProfileState.kept);
    expect(world.rawNames(guest), isNotEmpty);
    expect(await hostsOf(db), ['alice-host']);
    expect(Profiles.current!.uid, isNull);
    await db.close();
  });

  test('a deleted account whose question was never answered: kept at the next start, as nothing says otherwise', () async {
    final (manager, db, _, _, aliceId) = await threeProfiles();
    await manager.markAccountGone();
    await db.close();
    Profiles.debugReset();
    final next = world.launch();
    await next.start();
    final opened = await next.openCurrent();
    expect(next.currentEntry!.id, aliceId);
    expect(next.currentEntry!.uid, isNull);
    expect(await hostsOf(opened), ['alice-host']);
    await opened.close();
  });

  test('everything on this computer: every profile, what waits, the lock and the list', () async {
    final (manager, db, guest, bobId, aliceId) = await threeProfiles(lock: true);
    await HeldEntries(world.device).put('account_keys_v1_someone', 'held', vaultKey: manager.vaultKey);
    await Directory(ProfilePaths.heldTeams(world.base).path).create(recursive: true);
    await File(p.join(ProfilePaths.heldTeams(world.base).path, '$kTeamA.db')).writeAsString('held team');
    // What lies outside any profile's folder: what stayed where it was at the
    // move, and the app's own log files. A backup the person exported is theirs.
    final docs = world.folders.documents, support = world.folders.support;
    final loose = [
      File(p.join(docs.path, 'ZestSSH', 'session-logs', 'held-open.log')),
      File(p.join(docs.path, 'ZestSSH', 'transcripts', 'held-open.bin')),
      File(p.join(docs.path, 'ZestSSH', 'backups', 'zestssh_auto_1.zest')),
      File(p.join(support.path, 'ZestSSH', 'backups', 'zestssh_auto_2.zest')),
      File(p.join(docs.path, 'profile', 'avatar_1.png')),
      File(p.join(support.path, 'zestssh_logs_1.txt')),
    ];
    final exported = File(p.join(docs.path, 'ZestSSH', 'backups', 'zestssh_backup_1.zest'));
    for (final file in [...loose, exported]) {
      await file.create(recursive: true);
    }

    await manager.beginWipeEverything();
    expect(await manager.vault.hasSlots(), isFalse);
    final guestDb = await manager.openGuest();
    await db.close();
    await manager.finishWipeEverything();

    final newGuest = manager.currentEntry!;
    expect(manager.list.entries.map((e) => e.id), [newGuest.id]);
    for (final id in [guest, bobId, aliceId]) {
      expect(world.rawNames(id), isEmpty);
      expect(ProfilePaths.ofProfile(world.base, id).existsSync(), isFalse);
    }
    expect(world.device.kept.keys.where((k) => k.startsWith('held.')), isEmpty);
    expect(world.device.kept.containsKey('security_lock_method'), isFalse);
    expect(ProfilePaths.heldTeams(world.base).existsSync(), isFalse);
    expect(world.rawPrefs.getKeys(), isEmpty);
    expect(await hostsOf(guestDb), isEmpty);
    for (final file in loose) {
      expect(file.existsSync(), isFalse, reason: p.basename(file.path));
    }
    expect(exported.existsSync(), isTrue, reason: 'it is the person\'s, where they put it');
    await guestDb.close();
    // It starts as a clean computer.
    Profiles.debugReset();
    final next = world.launch();
    expect((await next.start()).lockOn, isFalse);
    final opened = await next.openCurrent();
    await opened.close();
  });

  test('everything on this computer, stopped in between: the next start finishes it', () async {
    final (manager, db, guest, bobId, aliceId) = await threeProfiles(lock: true);
    await HeldEntries(world.device).put('account_keys_v1_someone', 'held', vaultKey: manager.vaultKey);
    await manager.beginWipeEverything();
    await db.close();
    Profiles.debugReset();

    final next = world.launch();
    expect((await next.start()).lockOn, isFalse);
    expect(next.list.entries.map((e) => e.id), [next.currentEntry!.id]);
    for (final id in [guest, bobId, aliceId]) {
      expect(world.rawNames(id), isEmpty);
      expect(ProfilePaths.ofProfile(world.base, id).existsSync(), isFalse);
    }
    expect(world.device.kept.keys.where((k) => k.startsWith('held.')), isEmpty);
    expect(world.device.kept.containsKey('security_lock_method'), isFalse);
    expect(world.rawPrefs.getKeys(), isEmpty);
    final opened = await next.openCurrent();
    expect(await hostsOf(opened), isEmpty);
    await opened.close();
    // Once: what is made after it is not touched by the start after that.
    Profiles.debugReset();
    final again = world.launch();
    final id = next.currentEntry!.id;
    await again.start();
    expect(again.currentEntry!.id, id);
  });

  group('the sign-out the deleting flows use', () {
    late ProviderContainer container;
    tearDown(() => container.dispose());

    ProviderContainer app(AppDatabase db) {
      final c = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(ProfilePreferences.instance!),
        secureStorageProvider.overrideWithValue(ProfileKeychain(world.device)),
        isProProvider.overrideWith((ref) => _Pro()),
        isCloudSyncProvider.overrideWith((ref) => _Juiced()),
        deviceSessionServiceProvider.overrideWithValue(_Devices()),
      ]);
      c.read(databaseSessionProvider.notifier).seed(db);
      return c;
    }

    test('signing out for a wipe leaves the profile open: what is wiped is the account\'s, never the guest\'s', () async {
      final (manager, db, guest, _, aliceId) = await threeProfiles();
      container = app(db);
      await container.read(syncProviderConfigProvider.notifier).ensureLoaded();
      await signOutAccountWith(container.read, lock: false);
      expect(manager.currentEntry!.id, aliceId);
      expect(container.read(databaseSessionProvider), same(db));
      expect(await hostsOf(container.read(treeDatabaseProvider)), ['alice-host']);
      expect(manager.list.byId(guest)!.state, ProfileState.open);
      await db.close();
    });

    test('the session goes while the app lock has the database closed: it locks all the same, and the PIN opens guest data',
        () async {
      final (manager, db, guest, _, aliceId) = await threeProfiles(lock: true);
      container = app(db);
      await manager.locked();
      await container.read(databaseSessionProvider.notifier).close();

      await container.read(profileControllerProvider).lockAfterSignOut();
      expect(manager.list.byId(aliceId)!.state, ProfileState.locked);
      expect(manager.list.current, guest);
      expect(world.device.kept.containsKey(ProfileVault.wrappedName(aliceId)), isFalse);
      expect(container.read(databaseSessionProvider), isNull, reason: 'nothing opens without the PIN');
      expect(manager.prefs.loaded, isFalse, reason: 'nothing of the account stays in memory');

      manager.vaultKey = await VaultSlotService(ProfileKeychain(world.device, profile: () => Profiles.current)).unlockVaultKey(pin: pin);
      final opened = await manager.openCurrent();
      expect(await hostsOf(opened), ['guest-host']);
      expect(manager.prefs.getString('terminal_theme'), 'guest-theme');
      await opened.close();
    });

    test('a profile that does not open after the PIN: the next right PIN opens guest data, built afresh, and the profile stays',
        () async {
      final (manager, db, guest, _, aliceId) = await threeProfiles(lock: true);
      container = app(db);
      // What the app's state built from the person's settings, and holds on to.
      final built = Provider((ref) => ref.read(settingsServiceProvider).terminalThemeId);
      expect(container.read(built), 'alice-theme');
      await manager.locked();
      await container.read(databaseSessionProvider.notifier).close();

      final profiles = container.read(profileControllerProvider);
      expect(profiles.canOpenOther, isTrue);
      await profiles.openOtherAfterFailure();
      expect(manager.list.current, guest);
      expect(manager.list.byId(aliceId)!.state, ProfileState.open, reason: 'nothing of it changes');
      expect(world.device.kept.containsKey(ProfileVault.wrappedName(aliceId)), isTrue);

      await container.read(isAppLockedProvider.notifier).unlockVault(pin: pin);
      final opened = container.read(databaseSessionProvider)!;
      expect(await hostsOf(opened), ['guest-host']);
      expect(container.read(built), 'guest-theme', reason: 'nothing of the one before stays');
      await opened.close();
    });

    test('an ordinary sign-out locks the profile and opens guest data, with the app\'s own state built afresh', () async {
      final (manager, db, guest, _, aliceId) = await threeProfiles();
      container = app(db);
      await container.read(syncProviderConfigProvider.notifier).ensureLoaded();
      expect(container.read(profileControllerProvider).on, isTrue);
      await signOutAccountWith(container.read);
      expect(manager.currentEntry!.id, guest);
      expect(manager.list.byId(aliceId)!.state, ProfileState.locked);
      final open = container.read(databaseSessionProvider)!;
      expect(await hostsOf(open), ['guest-host']);
      expect(container.read(settingsServiceProvider).terminalThemeId, 'guest-theme');
      expect(world.device.kept.containsKey(ProfileVault.plainName(aliceId)), isFalse);
      await open.close();
    });
  });

  test('settings of a store that is a test\'s own are as they were', () async {
    SharedPreferences.setMockInitialValues({'terminal_theme': 'x'});
    expect((await SharedPreferences.getInstance()).getString('terminal_theme'), 'x');
  });
}
