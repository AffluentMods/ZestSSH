import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/account_sign_out.dart' show signOutAccountWith;
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account_secrets.dart';
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

/// A Mac's keychain whose reads of the items named in [failing] fail as macOS makes
/// them fail: [error] (a no to its question by default); everything else is
/// [inner]'s.
class _Failing implements FlutterSecureStorage {
  _Failing(this.inner);
  final MemoryKeychain inner;
  final failing = <String>{};
  Object Function() error = () => KeychainAccessDenied(-128);

  @override
  dynamic noSuchMethod(Invocation i) {
    final key = i.namedArguments[#key] as String?;
    if (i.memberName == #read && failing.contains(key)) return Future<String?>.error(error());
    return inner.noSuchMethod(i);
  }
}

/// 3.4.1: the Mac build has no Firebase (no GoogleService-Info.plist), so its sign-in
/// is the browser sign-in's session in the keychain. 3.3.3's ZS-1914 fix kept the
/// data open only where Firebase kept the sign-in: on a real Mac a session the
/// keychain did not show still locked the account's data and opened empty guest
/// data, and one it refused left the person signed out with nothing said of it. A
/// Mac is played as the app makes one: the platform's store is a MacKeychain
/// (installKeychainStore), and no Firebase.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const uid = 'account-alice';
  final l10n = lookupAppLocalizations(const Locale('en'));

  late ProfileWorld world;
  late FlutterSecureStoragePlatform platformBefore;
  late Future<void> Function(String) endBefore;

  setUp(() async {
    world = await ProfileWorld.create();
    platformBefore = FlutterSecureStoragePlatform.instance;
    // A Mac: what main.dart's installKeychainStore puts in place. The world's own
    // keychain stands in for what it holds.
    FlutterSecureStoragePlatform.instance = MacKeychain(platformBefore);
    endBefore = ProfileController.endSession;
    ProfileController.endSession = (_) async {};
  });
  tearDown(() async {
    ProfileController.endSession = endBefore;
    FlutterSecureStoragePlatform.instance = platformBefore;
    await world.dispose();
  });

  ProviderContainer app(AppDatabase db, {FlutterSecureStorage? device}) {
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(ProfilePreferences.instance!),
      secureStorageProvider.overrideWithValue(ProfileKeychain(device ?? world.device)),
      isProProvider.overrideWith((ref) => _Pro()),
      isCloudSyncProvider.overrideWith((ref) => _Juiced()),
      deviceSessionServiceProvider.overrideWithValue(_Devices()),
    ]);
    c.read(databaseSessionProvider.notifier).seed(db);
    addTearDown(c.dispose);
    return c;
  }

  /// The browser sign-in of [who] from what is on screen, its session written as
  /// storeDesktopSession does, with a host of its own.
  Future<void> signIn(ProviderContainer c, ProfileController profiles, String who) async {
    final label = '$who@example.com';
    await profiles.openForAccount(uid: who, label: label, bearer: 'fresh-$who');
    final store = c.read(secureStorageProvider);
    await AccountSecret.sessionToken.write(store, 'session-of-$who');
    await store.write(key: 'session_uid', value: who);
    await store.write(key: 'session_email', value: label);
    c.read(desktopSessionProvider.notifier).state = UserProfile(uid: who, email: label);
    await profiles.sessionKept();
    await addHost(c.read(databaseSessionProvider)!, 'host-of-$who');
  }

  /// A Mac with [who]'s data on screen, signed in through the browser, its locked
  /// copy at ZestSSH Cloud.
  Future<(ProfileManager, ProviderContainer, ProfileController)> macSignedIn([String who = uid]) async {
    expect(world.firebaseReported, isNull, reason: 'the Mac build has no Firebase');
    final manager = world.launch();
    await manager.start();
    final guest = await manager.openCurrent();
    SecretSeal.openTree = guest;
    final c = app(guest);
    final profiles = c.read(profileControllerProvider);
    await signIn(c, profiles, who);
    expect(manager.currentEntry!.uid, who);
    return (manager, c, profiles);
  }

  /// The app ends.
  Future<void> quit(ProviderContainer c) async {
    await c.read(databaseSessionProvider)?.close();
    SecretSeal.openTree = null;
    Profiles.debugReset();
  }

  /// The app starts again, as main.dart and app.dart do, with [device] as the
  /// keychain its stores read.
  Future<(ProfileManager, ProviderContainer, ProfileController)> start({FlutterSecureStorage? device}) async {
    final manager = world.launch();
    await manager.start();
    final db = await manager.openCurrent();
    SecretSeal.openTree = db;
    final c = app(db, device: device);
    final profiles = c.read(profileControllerProvider);
    await profiles.afterOpened();
    return (manager, c, profiles);
  }

  String sessionName(String id, String who) => KeychainNames.full(id, who, AccountSecret.sessionToken.slot);

  /// Waits for what a notice's action does, which it does not wait for.
  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  List<AppNotification> said(ProviderContainer c) => c.read(notificationCenterProvider).history;

  AppNotification? signInNotice(ProviderContainer c) =>
      said(c).where((n) => n.id == ProfileController.signInNotReadNotice).firstOrNull;

  /// The account's data is on screen and open, its key here, and no guest data in its
  /// place.
  Future<void> expectStillOpen(ProfileManager manager, ProviderContainer c, String id, [String who = uid]) async {
    expect(manager.currentEntry!.id, id, reason: 'never empty guest data in its place');
    expect(manager.currentEntry!.uid, who);
    expect(manager.list.byId(id)!.state, ProfileState.open, reason: 'nothing locks, and nothing is hidden');
    expect(world.device.kept.containsKey(ProfileVault.plainName(id)), isTrue, reason: 'its key is never dropped');
    expect(await hostsOf(c.read(databaseSessionProvider)!), ['host-of-$who']);
    expect(said(c).any((n) => n.title == l10n.profileLockedTitle || n.title == l10n.profileHiddenTitle), isFalse);
  }

  group('a start on a Mac, with no Firebase', () {
    test('(a) the session is read: the account is in, and nothing is said', () async {
      final (manager, c0, _) = await macSignedIn();
      final id = manager.currentEntry!.id;
      await quit(c0);

      final (next, c, _) = await start();
      await expectStillOpen(next, c, id);
      expect(signInNotice(c), isNull);
      await quit(c);
    });

    test('(c) the session is not there to read, and nobody signed out: the data stays open, and Sign in is said',
        () async {
      final (manager, c0, _) = await macSignedIn();
      final id = manager.currentEntry!.id;
      await quit(c0);
      // After the update the keychain no longer shows the item (a new signature).
      world.device.kept.remove(sessionName(id, uid));

      final (next, c, _) = await start();
      await expectStillOpen(next, c, id);
      final notice = signInNotice(c);
      expect(notice, isNotNull, reason: 'never unsaid');
      expect(notice!.title, l10n.profileSignInNotReadTitle);
      expect(notice.body, contains('ZS-1914'));
      expect(notice.actionLabel, l10n.profileSignIn);

      // Each start after it the same, until the person signs in: nothing locks later.
      await quit(c);
      final (again, c2, _) = await start();
      await expectStillOpen(again, c2, id);
      await quit(c2);
    });

    test('(b) macOS is told no for the session: the data stays open, and Try again reads it again', () async {
      final (manager, c0, _) = await macSignedIn();
      final id = manager.currentEntry!.id;
      await quit(c0);
      final refusing = _Failing(world.device)..failing.add(sessionName(id, uid));

      final (next, c, _) = await start(device: refusing);
      await expectStillOpen(next, c, id);
      final notice = signInNotice(c);
      expect(notice, isNotNull, reason: 'never unsaid');
      expect(notice!.body, contains('ZS-1914'));
      expect(notice.body, contains('Always Allow'), reason: 'what to choose when macOS asks');
      expect(notice.actionLabel, l10n.macKeychainTryAgain);
      expect(notice.details, contains('KeychainAccessDenied'));
      expect(c.read(currentUserProvider), isNull);

      // Try again, with Always Allow chosen this time: the account is in again as it was.
      refusing.failing.clear();
      notice.onAction!();
      await until(() => c.read(currentUserProvider) != null);
      expect(signInNotice(c), isNull);
      expect(c.read(currentUserProvider)?.uid, uid);
      await expectStillOpen(next, c, id);
      await quit(c);
    });

    test('(b) Try again with macOS still saying no: the same notice, and still nothing locks', () async {
      final (manager, c0, _) = await macSignedIn();
      final id = manager.currentEntry!.id;
      await quit(c0);
      final refusing = _Failing(world.device)..failing.add(sessionName(id, uid));

      final (next, c, _) = await start(device: refusing);
      signInNotice(c)!.onAction!();
      await until(() => signInNotice(c) != null);
      expect(signInNotice(c)?.actionLabel, l10n.macKeychainTryAgain);
      await expectStillOpen(next, c, id);
      await quit(c);
    });

    test('(c) any other failure of the read (errSecInteractionNotAllowed, or one not known): the same', () async {
      final (manager, c0, _) = await macSignedIn();
      final id = manager.currentEntry!.id;
      await quit(c0);
      for (final error in <Object Function()>[
        () => KeychainAccessDenied(-25308),
        () => PlatformException(code: 'Unexpected security result code', message: 'Code: -25291', details: -25291),
      ]) {
        final failing = _Failing(world.device)
          ..failing.add(sessionName(id, uid))
          ..error = error;
        final (next, c, _) = await start(device: failing);
        await expectStillOpen(next, c, id);
        expect(signInNotice(c)?.actionLabel, l10n.macKeychainTryAgain);
        await quit(c);
      }
    });

    test('(e) offline: the session is read from the keychain, and nothing waits for ZestSSH Cloud', () async {
      final (manager, c0, _) = await macSignedIn();
      final id = manager.currentEntry!.id;
      await quit(c0);
      world.cloud.down = true;

      final (next, c, _) = await start();
      await expectStillOpen(next, c, id);
      expect(signInNotice(c), isNull);
      await quit(c);
    });

    test("the person's own sign-out, stopped before its lock: finished at the next start, and said", () async {
      final (manager, c0, profiles) = await macSignedIn();
      final id = manager.currentEntry!.id;
      // What signOutAccountWith does before the lock: noted, then the session goes.
      await profiles.signOutBegins();
      await AccountSecret.sessionToken.delete(c0.read(secureStorageProvider));
      await quit(c0);

      final (next, c, _) = await start();
      expect(next.list.byId(id)!.state, ProfileState.locked);
      expect(next.currentEntry!.uid, isNull, reason: 'guest data now');
      expect(said(c).any((n) => n.title == l10n.profileLockedTitle), isTrue, reason: 'guest data never opens unsaid');
      expect(signInNotice(c), isNull);
      await quit(c);
    });

    test('signed out from elsewhere (ZestSSH Cloud says so): it locks, as a sign-out does', () async {
      final (manager, c, _) = await macSignedIn();
      final id = manager.currentEntry!.id;
      await signOutAccountWith(c.read, signedOutElsewhere: true);
      expect(manager.list.byId(id)!.state, ProfileState.locked);
      expect(manager.currentEntry!.uid, isNull);
      await quit(c);
    });

    test(
        'a sign-in whose session could not be written: the data it opened stays open with Sign in (by '
        'design), and another account here still opens it only with its own sign-in',
        () async {
      expect(world.firebaseReported, isNull, reason: 'the Mac build has no Firebase');
      final manager = world.launch();
      await manager.start();
      final guest = await manager.openCurrent();
      SecretSeal.openTree = guest;
      final c = app(guest);
      final profiles = c.read(profileControllerProvider);
      // The sign-in opens the account's data; writing its session to the keychain
      // fails (account_sign_in.dart says so with SessionNotStored).
      await profiles.openForAccount(uid: 'alex', label: 'alex@example.com', bearer: 'fresh-alex');
      await addHost(c.read(databaseSessionProvider)!, 'host-of-alex');
      await profiles.sessionNotKept();
      final alex = manager.currentEntry!.id;
      await expectStillOpen(manager, c, alex, 'alex');
      expect(signInNotice(c)?.actionLabel, l10n.profileSignIn, reason: 'never unsaid: sign in again');
      expect(c.read(currentUserProvider), isNull, reason: 'nobody is signed in on screen');

      // Someone else signs in on this computer: alex's data is not theirs to open.
      await profiles.nextSignInIs(mine: false);
      await signIn(c, profiles, 'sam');
      expect(manager.currentEntry!.uid, 'sam');
      expect(manager.list.byId(alex)!.state, ProfileState.open, reason: 'a switch locks nothing on a Mac');
      expect(profiles.accountsHere.singleWhere((a) => a.entry.id == alex).needsSignIn, isTrue);
      await expectLater(profiles.switchTo(alex), throwsA(isA<ProfileCannotOpen>()), reason: 'only with its own sign-in');
      expect(manager.currentEntry!.uid, 'sam');
      // Nor from guest data, now that two people have accounts here.
      await profiles.switchToGuest();
      expect(manager.currentEntry!.uid, isNull);
      await expectLater(profiles.switchTo(alex), throwsA(isA<ProfileCannotOpen>()));
      expect(manager.currentEntry!.uid, isNull);
      await quit(c);
    });

    test('a switch away from an account whose session the start did not read: nothing locks', () async {
      final (manager, c0, profiles0) = await macSignedIn('alex');
      await profiles0.nextSignInIs(mine: true);
      await signIn(c0, profiles0, 'sam');
      final sam = manager.list.byUid('sam')!.id;
      final alex = manager.list.byUid('alex')!.id;
      await quit(c0);
      world.device.kept.remove(sessionName(sam, 'sam'));

      final (next, c, profiles) = await start();
      await expectStillOpen(next, c, sam, 'sam');
      await profiles.switchTo(alex);
      expect(next.currentEntry!.id, alex);
      expect(next.list.byId(sam)!.state, ProfileState.open, reason: 'a switch is no sign-out');
      expect(world.device.kept.containsKey(ProfileVault.plainName(sam)), isTrue);
      await quit(c);
    });
  });

  group('a computer whose keychain answers whole (Windows, Linux), as before', () {
    setUp(() => FlutterSecureStoragePlatform.instance = platformBefore);

    test('an account with no session at a start: a sign-out that stopped, which locks and says so', () async {
      final (manager, c0, _) = await macSignedIn();
      final id = manager.currentEntry!.id;
      await quit(c0);
      world.device.kept.remove(sessionName(id, uid));

      final (next, c, _) = await start();
      expect(next.list.byId(id)!.state, ProfileState.locked);
      expect(said(c).any((n) => n.title == l10n.profileLockedTitle), isTrue);
      await quit(c);
    });

    test('a sign-in whose session could not be written: the profile it opened locks again, as its comment says',
        () async {
      final manager = world.launch();
      await manager.start();
      final guest = await manager.openCurrent();
      SecretSeal.openTree = guest;
      final c = app(guest);
      final profiles = c.read(profileControllerProvider);
      await profiles.openForAccount(uid: 'alex', label: 'alex@example.com', bearer: 'fresh-alex');
      final alex = manager.currentEntry!.id;
      await profiles.sessionNotKept();
      expect(manager.list.byId(alex)!.state, isNot(ProfileState.open));
      expect(manager.currentEntry!.uid, isNull, reason: 'guest data now');
      await quit(c);
    });

    test('a read that fails is no sign-out there either, and is left to the app as it was', () async {
      final (manager, c0, _) = await macSignedIn();
      final id = manager.currentEntry!.id;
      await quit(c0);
      final failing = _Failing(world.device)
        ..failing.add(sessionName(id, uid))
        ..error = () => PlatformException(code: 'read-failed');
      final next = world.launch();
      await next.start();
      final db = await next.openCurrent();
      SecretSeal.openTree = db;
      final c = app(db, device: failing);
      await expectLater(c.read(profileControllerProvider).afterOpened(), throwsA(isA<PlatformException>()));
      expect(next.list.byId(id)!.state, ProfileState.open);
      await quit(c);
    });
  });
}
