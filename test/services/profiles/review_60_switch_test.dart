// Accounts on one computer, from a review: a switch that stopped, what
// was said of a sign-in, and one wait for the browser at a time. Loopback only: the
// browser is never opened.
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/desktop_auth_server.dart' show BrowserSignInCancelled;
import 'package:zestssh/services/desktop_browser_sign_in.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';
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

void main() {
  late ProfileWorld world;
  late Future<void> Function(String) endBefore;
  setUp(() async {
    world = await ProfileWorld.create();
    endBefore = ProfileController.endSession;
    ProfileController.endSession = (bearer) async {};
  });
  tearDown(() async {
    ProfileController.endSession = endBefore;
    await world.dispose();
  });

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

  Future<(ProfileManager, ProviderContainer, ProfileController)> computer() async {
    final manager = world.launch();
    await manager.start();
    final guest = await manager.openCurrent();
    SecretSeal.openTree = guest;
    final c = app(guest);
    return (manager, c, c.read(profileControllerProvider));
  }

  Future<void> signIn(ProviderContainer c, ProfileController profiles, String uid, {SignInSaid? said}) async {
    final label = '$uid@example.com';
    await profiles.openForAccount(uid: uid, label: label, bearer: 'fresh-$uid', said: said);
    final store = c.read(secureStorageProvider);
    await AccountSecret.sessionToken.write(store, 'session-of-$uid');
    await store.write(key: 'session_uid', value: uid);
    await store.write(key: 'session_email', value: label);
    c.read(desktopSessionProvider.notifier).state = UserProfile(uid: uid, email: label);
    await profiles.sessionKept();
  }

  test('a switch that stopped, with the person left where they were, leaves sync running', () async {
    final (manager, c, profiles) = await computer();
    await signIn(c, profiles, 'alex');
    await signIn(c, profiles, 'sam');
    final alex = manager.list.byUid('alex')!.id;
    final sync = c.read(autoSyncServiceProvider);
    expect(sync.isSuspended, isFalse);

    world.device.stopAfter = 0;
    await expectLater(profiles.switchTo(alex), throwsA(isA<ProfileCannotOpen>()));
    world.device.stopAfter = null;

    expect(manager.list.current, manager.list.byUid('sam')!.id, reason: 'the person stayed');
    expect(identical(c.read(autoSyncServiceProvider), sync), isTrue, reason: 'nothing built it anew');
    final stillOff = sync.isSuspended;
    await c.read(databaseSessionProvider)!.close();
    expect(stillOff, isFalse, reason: 'Sync stays suspended until the app starts again: nothing resumes it, and a manual sync does nothing');
  });

  test('sync that something else had suspended before a switch that stopped stays suspended', () async {
    final (manager, c, profiles) = await computer();
    await signIn(c, profiles, 'alex');
    await signIn(c, profiles, 'sam');
    final sync = c.read(autoSyncServiceProvider);
    await sync.suspend();

    world.device.stopAfter = 0;
    await expectLater(profiles.switchTo(manager.list.byUid('alex')!.id), throwsA(isA<ProfileCannotOpen>()));
    world.device.stopAfter = null;

    final stillOff = sync.isSuspended;
    await c.read(databaseSessionProvider)!.close();
    expect(stillOff, isTrue);
  });

  test('two Add accounts at once: each sign-in goes with what its own flow was told', () async {
    final (manager, c, profiles) = await computer();
    await signIn(c, profiles, 'alex');
    final theirs = await profiles.nextSignInIs(mine: false);
    final mine = await profiles.nextSignInIs(mine: true);
    await signIn(c, profiles, 'sam', said: theirs);
    await signIn(c, profiles, 'alex-work', said: mine);
    final alex = manager.list.byUid('alex')!;
    final sam = manager.list.byUid('sam')!;
    final work = manager.list.byUid('alex-work')!;
    await c.read(databaseSessionProvider)!.close();
    expect(sam.sameOwnerAs(alex), isFalse);
    expect(work.sameOwnerAs(alex), isTrue);
  });

  test('the end of one Add account leaves what the other was told', () async {
    final (manager, c, profiles) = await computer();
    await signIn(c, profiles, 'alex');
    final theirs = await profiles.nextSignInIs(mine: false);
    final mine = await profiles.nextSignInIs(mine: true);
    profiles.forgetNextSignIn(theirs);
    // One that cannot say which flow it is of: only one is under way now.
    await signIn(c, profiles, 'alex-work');
    profiles.forgetNextSignIn(mine);
    final same = manager.list.byUid('alex-work')!.sameOwnerAs(manager.list.byUid('alex')!);
    await c.read(databaseSessionProvider)!.close();
    expect(same, isTrue);
  });

  test('a sign-in nobody asked about takes nothing from an Add account under way', () async {
    final (manager, c, profiles) = await computer();
    await signIn(c, profiles, 'alex');
    final mine = await profiles.nextSignInIs(mine: true);
    await signIn(c, profiles, 'sam', said: SignInSaid.nothing);
    await signIn(c, profiles, 'alex-work', said: mine);
    final alex = manager.list.byUid('alex')!;
    final sam = manager.list.byUid('sam')!;
    final work = manager.list.byUid('alex-work')!;
    await c.read(databaseSessionProvider)!.close();
    expect(sam.sameOwnerAs(alex), isFalse);
    expect(work.sameOwnerAs(alex), isTrue);
  });

  test('what a person said of a sign-in holds for that sign-in, whichever question came last', () async {
    final (manager, c, profiles) = await computer();
    await signIn(c, profiles, 'alex');
    // Add account: someone else's, its sign-in under way. Add account again: another
    // of mine. A sign-in that cannot say which flow it is of (a Mac's) comes next.
    await profiles.nextSignInIs(mine: false);
    await profiles.nextSignInIs(mine: true);
    // It may be the first one's, by that someone else.
    await signIn(c, profiles, 'sam');
    final alexRow = profiles.accountsHere.firstWhere((a) => a.entry.uid == 'alex');
    await c.read(databaseSessionProvider)!.close();
    expect(alexRow.needsSignIn, isTrue, reason: "Sam, said to be someone else, now opens Alex's account with no sign-in");
    expect(manager.list.byUid('sam')!.sameOwnerAs(manager.list.byUid('alex')!), isFalse);
  });

  test('a change of profile ends every sign-in that waits', () async {
    final pages = <Uri>[];
    Future<void> open(Uri page) async => pages.add(page);
    var firstDone = false;
    final first = DesktopBrowserSignIn.session(open: open).whenComplete(() => firstDone = true);
    unawaited(first.then<void>((_) {}, onError: (Object _) {}));
    while (pages.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final second = DesktopBrowserSignIn.session(open: open);
    while (pages.length < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    // What _stopWhatRuns does.
    DesktopBrowserSignIn.cancel();
    await expectLater(second, throwsA(isA<BrowserSignInCancelled>()));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final stillWaiting = !firstDone;

    // The first page finishes after the change of profile, on loopback.
    String? cameAs;
    if (stillWaiting) {
      final redirect = Uri.parse(pages.first.queryParameters['redirect']!);
      final back = redirect.replace(queryParameters: {
        'state': pages.first.queryParameters['state']!,
        'token': 'aaa.bbb.ccc',
        'email': 'someone@example.com',
        'uid': 'someone',
      });
      final client = HttpClient();
      try {
        final request = await client.getUrl(back);
        await (await request.close()).drain<void>();
      } finally {
        client.close(force: true);
      }
      final session = await first.timeout(const Duration(seconds: 5));
      cameAs = session.uid;
    }
    expect(stillWaiting, isFalse, reason: 'cancel() reached only the latest wait: the first still signed in, as $cameAs, up to 15 minutes later');
  });

  test('the page of the wait that took over stays up as the one before it ends', () async {
    final pages = <Uri>[];
    Future<void> open(Uri page) async => pages.add(page);
    final first = DesktopBrowserSignIn.session(open: open);
    unawaited(first.then<void>((_) {}, onError: (Object _) {}));
    while (pages.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final second = DesktopBrowserSignIn.session(open: open);
    while (pages.length < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(DesktopBrowserSignIn.pending.value?.uri, pages.last);
    DesktopBrowserSignIn.cancel();
    await expectLater(second, throwsA(isA<BrowserSignInCancelled>()));
    expect(DesktopBrowserSignIn.pending.value, isNull);
  });

  test('a wait stopped while its page still opens ends as cancelled', () async {
    final opening = Completer<void>();
    final wait = DesktopBrowserSignIn.session(open: (_) => opening.future);
    while (DesktopBrowserSignIn.pending.value == null) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    DesktopBrowserSignIn.cancel();
    // Nobody listens yet: an error said to nobody fails this test by itself.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    opening.complete();
    await expectLater(wait, throwsA(isA<BrowserSignInCancelled>()));
    expect(DesktopBrowserSignIn.pending.value, isNull);
  });
}
