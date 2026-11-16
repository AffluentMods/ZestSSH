import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/mac_keychain.dart';
import 'package:zestssh/services/profiles/profile_list.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';
import 'package:zestssh/services/profiles/profile_vault.dart';
import 'package:zestssh/services/secret_seal.dart';

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

/// A Mac's keychain that says no to the items named in [refused], as macOS does to a
/// new build's read when Deny is chosen; everything else is [inner]'s.
class _Refusing implements FlutterSecureStorage {
  _Refusing(this.inner);
  final MemoryKeychain inner;
  final refused = <String>{};

  @override
  dynamic noSuchMethod(Invocation i) {
    final key = i.namedArguments[#key] as String?;
    if (i.memberName == #read && refused.contains(key)) {
      return Future<String?>.error(KeychainAccessDenied(-128));
    }
    return inner.noSuchMethod(i);
  }
}

/// The 3.3.3 hotfix: data on a Mac that looked wiped after an update.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const uid = 'account-alice';
  final l10n = lookupAppLocalizations(const Locale('en'));

  late ProfileWorld world;
  setUp(() async => world = await ProfileWorld.create());
  tearDown(() => world.dispose());

  Future<AppDatabase> signIn(ProfileManager manager, AppDatabase from, String who) async {
    final plan = await manager.planForAccount(uid: who, label: '$who@example.com', bearer: 'token');
    final prepared = await manager.prepare(plan);
    await from.close();
    await manager.commit(prepared);
    return prepared.db;
  }

  ProviderContainer app(AppDatabase? db) {
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(ProfilePreferences.instance!),
      secureStorageProvider.overrideWithValue(ProfileKeychain(world.device)),
      isProProvider.overrideWith((ref) => _Pro()),
      isCloudSyncProvider.overrideWith((ref) => _Juiced()),
      deviceSessionServiceProvider.overrideWithValue(_Devices()),
    ]);
    if (db != null) c.read(databaseSessionProvider.notifier).seed(db);
    addTearDown(c.dispose);
    return c;
  }

  /// A Mac with [uid]'s data open and its locked copy at ZestSSH Cloud, closed as the
  /// app ends. Returns the profile's id.
  Future<String> macAccountThatEnded() async {
    world.firebaseReported = () async {};
    world.firebase = uid;
    final manager = world.launch();
    await manager.start();
    final guest = await manager.openCurrent();
    final db = await signIn(manager, guest, uid);
    SecretSeal.openTree = db;
    await addHost(db, 'host-of-alice');
    expect(await manager.settleLockedCopy(db: db, bearer: 'b'), isTrue);
    final id = manager.currentEntry!.id;
    await db.close();
    SecretSeal.openTree = null;
    Profiles.debugReset();
    return id;
  }

  group('fix 1: Firebase reading nobody on a Mac is no sign-out', () {
    test('at a start, with nobody signed out: the data stays open, nothing locks, and it says Sign in again', () async {
      final id = await macAccountThatEnded();
      // The update: Firebase's own keychain item is not read, so it reports nobody.
      world.firebase = null;
      final manager = world.launch();
      await manager.start();
      final db = await manager.openCurrent();
      SecretSeal.openTree = db;
      final c = app(db);
      await c.read(profileControllerProvider).afterOpened();

      expect(manager.currentEntry!.id, id, reason: 'never empty guest data in its place');
      expect(manager.list.byId(id)!.state, ProfileState.open);
      expect(world.device.kept.containsKey(ProfileVault.plainName(id)), isTrue, reason: 'its key is never dropped');
      final open = c.read(databaseSessionProvider)!;
      expect(await hostsOf(open), ['host-of-alice']);
      final said = c.read(notificationCenterProvider).history;
      expect(said.any((n) => n.id == 'profile-sign-in-not-read' && n.title == l10n.profileSignInNotReadTitle), isTrue);
      expect(said.any((n) => n.body?.contains('ZS-1914') ?? false), isTrue);

      // The person signs in again: the notice goes, and the data is as it was.
      world.firebase = uid;
      await c.read(profileControllerProvider).afterOpened();
      expect(manager.currentEntry!.id, id);
      expect(c.read(notificationCenterProvider).history.any((n) => n.id == 'profile-sign-in-not-read'), isFalse);
      await open.close();
    });

    test('Firebase said the account was in and then nobody, in one run: a sign-out, which locks and says so', () async {
      final id = await macAccountThatEnded();
      final manager = world.launch();
      await manager.start();
      final db = await manager.openCurrent();
      SecretSeal.openTree = db;
      final c = app(db);
      await c.read(profileControllerProvider).afterOpened();
      expect(manager.list.byId(id)!.state, ProfileState.open);

      // Signed out from elsewhere: Firebase says nobody now.
      world.firebase = null;
      await c.read(profileControllerProvider).afterOpened();
      expect(manager.list.byId(id)!.state, ProfileState.locked);
      expect(manager.currentEntry!.uid, isNull);
      final said = c.read(notificationCenterProvider).history;
      expect(said.any((n) => n.title == l10n.profileLockedTitle), isTrue, reason: 'guest data never opens unsaid');
      await c.read(databaseSessionProvider)!.close();
    });
  });

  group('fix 1 (and the guest report): a refused read never makes new, empty guest data', () {
    test('a guest profile whose database key macOS refuses at start: it throws, and nothing is made, moved or deleted', () async {
      final manager = world.launch();
      await manager.start();
      final db = await manager.openCurrent();
      await addHost(db, 'host-of-guest');
      final id = manager.currentEntry!.id;
      await db.close();
      Profiles.debugReset();
      final listBefore = world.device.kept[ProfileList.name];

      final refusing = _Refusing(world.device)..refused.add(ProfileVault.plainName(id));
      world.realDevice = refusing;
      final next = world.launch();
      await next.start();
      await expectLater(next.openCurrent(), throwsA(isA<KeychainAccessDenied>()));
      expect(world.device.kept[ProfileList.name], listBefore, reason: 'the list is as it was');
      expect(world.device.kept.containsKey(ProfileVault.plainName(id)), isTrue);
      final folders = ProfilePaths.root(world.base).listSync().whereType<Directory>().map((d) => p.basename(d.path));
      expect(folders.where(isProfileId), [id], reason: 'no new profile');
      Profiles.debugReset();

      // macOS lets it read again (Always Allow): the same data opens.
      refusing.refused.clear();
      final again = world.launch();
      await again.start();
      final opened = await again.openCurrent();
      expect(again.currentEntry!.id, id);
      expect(await hostsOf(opened), ['host-of-guest']);
      await opened.close();
    });

    test('the list of profiles refused: the start throws, and no new guest data is made', () async {
      final manager = world.launch();
      await manager.start();
      final db = await manager.openCurrent();
      final id = manager.currentEntry!.id;
      await db.close();
      Profiles.debugReset();
      final refusing = _Refusing(world.device)..refused.addAll([ProfileList.name, ProfileList.copyName]);
      world.realDevice = refusing;
      final next = world.launch();
      await expectLater(next.start(), throwsA(isA<KeychainAccessDenied>()));
      final folders = ProfilePaths.root(world.base).listSync().whereType<Directory>().map((d) => p.basename(d.path));
      expect(folders.where(isProfileId), [id]);
    });

    test('a list that reads as nothing: the guest data in its folder opens again, never new empty data', () async {
      final manager = world.launch();
      await manager.start();
      final db = await manager.openCurrent();
      await addHost(db, 'host-of-guest');
      final id = manager.currentEntry!.id;
      await db.close();
      Profiles.debugReset();
      // The keychain no longer shows the list (its items gone from view, or deleted).
      world.device.kept.remove(ProfileList.name);
      world.device.kept.remove(ProfileList.copyName);

      final next = world.launch();
      await next.start();
      final opened = await next.openCurrent();
      expect(next.currentEntry!.id, id, reason: 'its own folder, not a new one');
      expect(next.currentEntry!.uid, isNull);
      expect(await hostsOf(opened), ['host-of-guest']);
      await opened.close();
    });

    test('a folder the list does not name, beside new empty guest data: set aside, said, and Put it back opens it', () async {
      final manager = world.launch();
      await manager.start();
      final db = await manager.openCurrent();
      await addHost(db, 'host-of-guest');
      final id = manager.currentEntry!.id;
      await db.close();
      Profiles.debugReset();
      // What 3.3.x could leave: a list naming only new, empty guest data.
      world.device.kept.remove(ProfileList.name);
      world.device.kept.remove(ProfileList.copyName);
      final emptyId = newProfileId();
      final empty = ProfileList()
        ..put(ProfileEntry(id: emptyId, made: 1))
        ..current = emptyId;
      await empty.write(world.device);

      final next = world.launch();
      await next.start();
      expect(next.list.byId(id)?.state, ProfileState.setAside);
      expect(await next.setAsideHere(), isTrue, reason: 'the notice of what was set aside says it');
      final fresh = await next.openCurrent();
      await next.askPutBack();
      await fresh.close();
      Profiles.debugReset();

      final back = world.launch();
      await back.start();
      final opened = await back.openCurrent();
      expect(back.currentEntry!.id, id);
      expect(await hostsOf(opened), ['host-of-guest']);
      await opened.close();
    });
  });

  group('fix 4: the first start with Firebase saying nobody', () {
    test('an account named with no session: the data is that account\'s, not guest data', () async {
      await makeOldDatabase(world, wal: 'host-in-wal');
      world.device.kept.addAll({KeychainNames.databaseKey: kOldKey, 'session_uid': uid, 'session_email': 'a@example.com'});
      world.firebaseReported = () async {};
      final manager = world.launch();
      await manager.start();
      final db = await manager.openCurrent();
      expect(manager.currentEntry!.uid, uid);
      await db.close();
    });

    test('an account was signed in, but which cannot be told: guest data for now, said, and the next sign-in asks', () async {
      await world.dispose();
      world = await ProfileWorld.create(prefs: {'desktop_entitlement_checked_at': 1793000000000});
      await makeOldDatabase(world, wal: 'host-in-wal');
      world.device.kept.addAll({KeychainNames.databaseKey: kOldKey, 'session_email': 'a@example.com'});
      world.firebaseReported = () async {};
      final manager = world.launch();
      await manager.start();
      final db = await manager.openCurrent();
      expect(manager.currentEntry!.uid, isNull);
      SecretSeal.openTree = db;
      final c = app(db);
      final profiles = c.read(profileControllerProvider);
      await profiles.afterOpened();
      final said = c.read(notificationCenterProvider).history;
      expect(said.any((n) => n.id == 'profile-whose-unknown' && (n.body?.contains('ZS-1915') ?? false)), isTrue);

      var asked = false;
      profiles.onGuestData = () => asked = true;
      world.firebase = uid;
      await profiles.afterOpened();
      expect(manager.currentEntry!.uid, uid);
      expect(asked, isTrue, reason: 'whether to bring the guest data in is asked');
      await c.read(databaseSessionProvider)!.close();
    });
  });
}
