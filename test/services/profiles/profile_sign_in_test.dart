import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:path/path.dart' as p;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/services/desktop_browser_sign_in.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/locked_copies.dart';
import 'package:zestssh/services/profiles/profile_list.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';
import 'package:zestssh/services/profiles/profile_vault.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/sign_in_code.dart';
import 'package:zestssh/services/vault_slot_service.dart';
import 'package:zestssh/ui/screens/profile/account_sign_in.dart';

import 'profile_world.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(false);

  @override
  Future<void> refresh() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Juiced extends StateNotifier<bool> implements CloudSyncStatusNotifier {
  _Juiced() : super(false);

  @override
  Future<void> refresh() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Signing in and out, in the design's order: a sign-in opens the account's
/// profile, or makes one, and only then is the session written into it; a
/// sign-out locks the profile with no server, and guest data opens.
void main() {
  const alice = 'account-alice';
  const bob = 'account-bob';
  const pin = '4242';

  late ProfileWorld world;
  setUp(() async => world = await ProfileWorld.create());
  tearDown(() => world.dispose());

  /// A clean computer with its guest data open.
  Future<(ProfileManager, AppDatabase)> started() async {
    final manager = world.launch();
    await manager.start();
    final db = await manager.openCurrent();
    return (manager, db);
  }

  /// [manager] opens the account [uid], and [from], the database open now, closes
  /// as the app's own flip closes it.
  Future<AppDatabase> signIn(ProfileManager manager, AppDatabase from, String uid, {String bearer = 'token'}) async {
    final plan = await manager.planForAccount(uid: uid, label: '$uid@example.com', bearer: bearer);
    final prepared = await manager.prepare(plan);
    await from.close();
    await manager.commit(prepared);
    await manager.settleLockedCopy(db: prepared.db, bearer: bearer, replace: plan.replaceSecret);
    return prepared.db;
  }

  Future<AppDatabase> signOut(ProfileManager manager, AppDatabase from) async {
    await manager.lockCurrent();
    final next = await manager.openGuest();
    await from.close();
    return next;
  }

  test('a new account gets a new, empty profile of its own, and the guest data stays as guest data', () async {
    final (manager, guestDb) = await started();
    await addHost(guestDb, 'guest-host');
    final guest = manager.currentEntry!;
    final db = await signIn(manager, guestDb, alice);
    final entry = manager.currentEntry!;
    expect(entry.id, isNot(guest.id));
    expect(entry.uid, alice);
    expect(Profiles.current!.uid, alice);
    expect(await hostsOf(db), isEmpty, reason: 'nothing of the guest\'s comes along by itself');
    expect(manager.list.guest!.id, guest.id);
    await db.close();
  });

  test('the secret: sealed until ZestSSH Cloud confirms it, sent again with the same id if the answer was lost, then forgotten',
      () async {
    final (manager, guestDb) = await started();
    world.cloud.answersLost = 1;
    final db = await signIn(manager, guestDb, alice);
    final id = manager.currentEntry!.id;
    // Taken, but the answer never came: no copy is confirmed, and the secret is
    // still here, sealed.
    expect(world.cloud.held.length, 1);
    expect(await manager.copies.confirmed(id), isNull);
    final secretEntry = '${KeychainPrefix.of(id)}${KeychainNames.lockedCopySecret}';
    expect(SecretSeal.isSealed(world.device.kept[secretEntry]), isTrue);
    final firstId = world.cloud.stores.single;

    // The next try: the same id, and it is one store.
    expect(await manager.settleLockedCopy(db: db, bearer: 'token'), isTrue);
    expect(world.cloud.stores, [firstId, firstId]);
    expect(world.cloud.held.length, 1);
    expect((await manager.copies.confirmed(id))!.id, firstId);
    expect(world.device.kept.containsKey(secretEntry), isFalse, reason: 'forgotten only now');
    expect(world.device.kept.containsKey('${KeychainPrefix.of(id)}${KeychainNames.lockedCopyNext}'), isFalse);
    await db.close();
  });

  test('signing out locks with no server: only the copy ZestSSH Cloud\'s secret opens stays, and guest data opens', () async {
    final (manager, guestDb) = await started();
    final db = await signIn(manager, guestDb, alice);
    await addHost(db, 'alice-host');
    await world.keychainOf(Profiles.current!, db).write(key: 'identity_key_k', value: 'PRIVATE');
    final id = manager.currentEntry!.id;
    world.cloud.down = true;

    final guest = await signOut(manager, db);
    expect(manager.list.byId(id)!.state, ProfileState.locked);
    expect(world.device.kept.containsKey(ProfileVault.plainName(id)), isFalse);
    expect(world.device.kept.containsKey(ProfileVault.wrappedName(id)), isFalse);
    expect(await manager.copies.confirmed(id), isNotNull);
    expect(manager.currentEntry!.uid, isNull);
    expect(await hostsOf(guest), isEmpty);
    // What was the account's reads as nothing, for the guest.
    expect(await world.keychainOf(Profiles.current!, guest).read(key: 'identity_key_k'), isNull);
    // Its entry is sealed by a seal nobody can reach now.
    final raw = world.device.kept[KeychainNames.full(id, alice, 'identity_key_k')];
    expect(SecretSeal.isSealed(raw), isTrue);
    await guest.close();
  });

  test('signing back in fetches the secret, opens the profile as it was left, and a new secret replaces it at once', () async {
    final (manager, guestDb) = await started();
    var db = await signIn(manager, guestDb, alice);
    await addHost(db, 'alice-host');
    final id = manager.currentEntry!.id;
    final oldCopy = (await manager.copies.confirmed(id))!.id;
    db = await signOut(manager, db);

    db = await signIn(manager, db, alice);
    expect(manager.currentEntry!.id, id);
    expect(await hostsOf(db), ['alice-host']);
    expect(world.cloud.handBacks, [oldCopy]);
    final newCopy = (await manager.copies.confirmed(id))!.id;
    expect(newCopy, isNot(oldCopy));
    expect(world.cloud.held.keys, [newCopy], reason: 'the old one is deleted at ZestSSH Cloud');
    expect(world.device.kept[ProfileVault.plainName(id)], isNotNull);
    await db.close();
  });

  test('a known account never gets a new profile because ZestSSH Cloud could not be reached', () async {
    final (manager, guestDb) = await started();
    var db = await signIn(manager, guestDb, alice);
    final id = manager.currentEntry!.id;
    db = await signOut(manager, db);
    final guestId = manager.currentEntry!.id;
    final foldersBefore = ProfilePaths.root(world.base).listSync().length;
    final listBefore = manager.list.entries.length;
    world.device.log.clear();

    world.cloud.down = true;
    await expectLater(
      manager.planForAccount(uid: alice, label: null, bearer: 'token'),
      throwsA(isA<ProfileCannotOpen>().having((e) => e.code, 'code', 'profile-offline')),
    );
    expect(manager.list.entries.length, listBefore);
    expect(manager.list.byId(id)!.state, ProfileState.locked);
    expect(manager.currentEntry!.id, guestId, reason: 'it stays where it is');
    expect(ProfilePaths.root(world.base).listSync().length, foldersBefore);
    expect(world.device.log, isEmpty, reason: 'nothing is written');
    await db.close();
  });

  test('a secret that wants a newer sign-in is said as that, and changes nothing', () async {
    final (manager, guestDb) = await started();
    var db = await signIn(manager, guestDb, alice);
    db = await signOut(manager, db);
    world.cloud.oldSignIn = true;
    await expectLater(
      manager.planForAccount(uid: alice, label: null, bearer: 'token'),
      throwsA(isA<ProfileCannotOpen>().having((e) => e.code, 'code', 'profile-signed-in-long-ago')),
    );
    await db.close();
  });

  test('a copy deleted at ZestSSH Cloud can never be opened: its folder is left, and a new profile is said', () async {
    final (manager, guestDb) = await started();
    var db = await signIn(manager, guestDb, alice);
    await addHost(db, 'alice-host');
    final id = manager.currentEntry!.id;
    db = await signOut(manager, db);
    world.cloud.held.clear();

    final plan = await manager.planForAccount(uid: alice, label: null, bearer: 'token');
    expect(plan.isFresh, isTrue);
    expect(plan.losing?.id, id);
    final prepared = await manager.prepare(plan);
    await db.close();
    await manager.commit(prepared);
    expect(manager.list.byId(id)!.state, ProfileState.lost);
    expect(manager.list.byUid(alice)!.id, isNot(id));
    expect(File(p.join(ProfilePaths.ofProfile(world.base, id).path, 'zestssh.db')).existsSync(), isTrue);
    await prepared.db.close();
  });

  test('a secret that never reached ZestSSH Cloud: signing out hides the profile, says so, and the next sign-in online locks it',
      () async {
    final (manager, guestDb) = await started();
    world.cloud.down = true;
    var db = await signIn(manager, guestDb, alice);
    final id = manager.currentEntry!.id;
    expect(await manager.copies.confirmed(id), isNull);

    expect(await manager.lockCurrent(), SignOutEnd.hidden);
    final guest = await manager.openGuest();
    await db.close();
    expect(manager.list.byId(id)!.state, ProfileState.hidden);
    expect(world.device.kept[ProfileVault.plainName(id)], isNotNull, reason: 'hidden, not locked: its key is still here');

    // Back online: signing in needs no secret to open it, and it is sealed in the
    // profile until ZestSSH Cloud has it. Then it can be locked.
    world.cloud.down = false;
    db = await signIn(manager, guest, alice);
    expect(manager.currentEntry!.id, id);
    expect(await manager.copies.confirmed(id), isNotNull);
    expect(await manager.lockCurrent(), SignOutEnd.locked);
    expect(world.device.kept.containsKey(ProfileVault.plainName(id)), isFalse);
    await db.close();
  });

  test('a signed-in profile opens offline, always: lock off and lock on', () async {
    var (manager, guestDb) = await started();
    final db = await signIn(manager, guestDb, alice);
    await addHost(db, 'alice-host');
    await db.close();

    world.cloud.down = true;
    Profiles.debugReset();
    manager = world.launch();
    expect((await manager.start()).lockOn, isFalse);
    expect(manager.currentEntry!.uid, alice);
    var offline = await manager.openCurrent();
    expect(await hostsOf(offline), ['alice-host']);
    await offline.close();

    // With the app lock: the PIN alone.
    final keys = {for (final id in manager.list.withKeyHere) id: await manager.keyHexOf(manager.list.byId(id)!)};
    final slots = VaultSlotService(ProfileKeychain(world.device, profile: () => Profiles.current));
    await manager.vault.turnOn(keys: keys, slots: slots, pin: pin);
    Profiles.debugReset();
    manager = world.launch();
    expect((await manager.start()).lockOn, isTrue);
    manager.vaultKey = await VaultSlotService(ProfileKeychain(world.device, profile: () => Profiles.current)).unlockVaultKey(pin: pin);
    offline = await manager.openCurrent();
    expect(await hostsOf(offline), ['alice-host']);
    await offline.close();
    expect(world.cloud.handBacks, isEmpty);
  });

  test('a sign-out that stopped after the list said locked is finished at the next start', () async {
    final (manager, guestDb) = await started();
    final db = await signIn(manager, guestDb, alice);
    final id = manager.currentEntry!.id;
    // The app ended after the list was written, before the keys went.
    world.device.stopAfter = 2;
    await untilStopped(() async {
      await manager.lockCurrent();
    });
    world.device.stopAfter = null;
    expect(world.device.kept[ProfileVault.plainName(id)], isNotNull);
    await db.close();
    Profiles.debugReset();

    final next = world.launch();
    await next.start();
    expect(next.list.byId(id)!.state, ProfileState.locked);
    expect(world.device.kept.containsKey(ProfileVault.plainName(id)), isFalse);
    expect(next.currentEntry?.uid, isNull, reason: 'guest data opens');
    final guest = await next.openCurrent();
    await guest.close();
  });

  test('two accounts in one team each have their own copy of it', () async {
    final (manager, guestDb) = await started();
    var db = await signIn(manager, guestDb, alice);
    final aliceDir = Profiles.current!.dir;
    await Directory(p.join(aliceDir.path, 'orchards')).create();
    await File(p.join(aliceDir.path, 'orchards', '$kTeamA.db')).writeAsString('alice\'s copy');
    db = await signOut(manager, db);
    db = await signIn(manager, db, bob);
    final bobFile = await AppDatabase.orchardDatabaseFile(kTeamA);
    expect(bobFile.path, startsWith(Profiles.current!.dir.path));
    expect(bobFile.existsSync(), isFalse);
    await bobFile.parent.create(recursive: true);
    await bobFile.writeAsString('bob\'s copy');
    expect(File(p.join(aliceDir.path, 'orchards', '$kTeamA.db')).readAsStringSync(), 'alice\'s copy');
    await db.close();
  });

  group('the sign-in on a computer, as the app runs it', () {
    late ProviderContainer container;
    late WidgetRef ref;
    late BuildContext context;

    Future<void> pumpApp(WidgetTester tester, ProfileManager manager, AppDatabase db) async {
      container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(ProfilePreferences.instance!),
        secureStorageProvider.overrideWithValue(ProfileKeychain(world.device)),
        isProProvider.overrideWith((ref) => _Pro()),
        isCloudSyncProvider.overrideWith((ref) => _Juiced()),
      ]);
      container.read(databaseSessionProvider.notifier).seed(db);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Consumer(builder: (c, r, _) {
            ref = r;
            context = c;
            return const SizedBox();
          }),
        ),
      ));
      await tester.pump();
    }

    tearDown(() {
      debugBrowserSession = null;
      container.dispose();
    });

    testWidgets('a sign-in ZestSSH Cloud refuses makes nothing on the device', (tester) async {
      late ProfileManager manager;
      late AppDatabase db;
      await tester.runAsync(() async {
        (manager, db) = await started();
        world.device.log.clear();
      });
      await pumpApp(tester, manager, db);
      final entriesBefore = manager.list.entries.length;
      debugBrowserSession = ({bool create = false}) async => throw const SignInCodeRefused(403, 'sign-in-code-refused');
      late bool signedIn;
      await tester.runAsync(() async {
        signedIn = await signInInBrowser(context, ref);
      });
      expect(signedIn, isFalse);
      expect(manager.list.entries.length, entriesBefore);
      expect(world.device.log, isEmpty, reason: 'not an entry');
      expect(ProfilePaths.root(world.base).listSync().whereType<Directory>().length, entriesBefore, reason: 'not a folder');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => db.close());
    });

    testWidgets('an account with no id is never "an unknown account": nothing is made for it', (tester) async {
      late ProfileManager manager;
      late AppDatabase db;
      await tester.runAsync(() async {
        (manager, db) = await started();
      });
      await pumpApp(tester, manager, db);
      final before = manager.list.entries.length;
      await tester.runAsync(() async {
        await expectLater(storeDesktopSession(ref, const BrowserSession(token: 'no.claims.here')), throwsA(isA<SessionNotStored>()));
      });
      expect(manager.list.entries.length, before);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => db.close());
    });

    testWidgets('the session is written into the profile only at the end', (tester) async {
      late ProfileManager manager;
      late AppDatabase guestDb;
      late AppDatabase aliceDb;
      await tester.runAsync(() async {
        (manager, guestDb) = await started();
        // Alice has been here, and is signed out.
        aliceDb = await signIn(manager, guestDb, alice);
        await addHost(aliceDb, 'alice-host');
        guestDb = await signOut(manager, aliceDb);
      });
      final aliceId = manager.list.byUid(alice)!.id;
      final tokenName = KeychainNames.full(aliceId, alice, 'session_token');
      await pumpApp(tester, manager, guestDb);

      var writtenAtTheHandBack = true;
      world.cloud.onHandBack = () {
        writtenAtTheHandBack = world.device.kept.containsKey(tokenName);
      };
      // Nothing else touches the keychain while the session is written: the two
      // overlapping lost a real person's keys on Windows, one sign-in in a hundred.
      final storedBefore = world.cloud.stores.length;
      var writtenAtTheStore = false;
      world.cloud.onStore = () {
        writtenAtTheStore = world.device.kept.containsKey(KeychainNames.full(aliceId, alice, 'session_uid'));
      };
      final guestId = manager.currentEntry!.id;
      await tester.runAsync(() async {
        await storeDesktopSession(ref, const BrowserSession(token: 'tok.en.here', uid: alice, email: 'alice@example.com'));
      });
      await tester.pump();
      expect(writtenAtTheHandBack, isFalse, reason: 'not before the profile was opened');
      expect(world.cloud.stores.length, storedBefore + 1, reason: 'done by the time it returns, and not left running');
      expect(writtenAtTheStore, isTrue, reason: 'told once the whole session is written');
      expect(manager.currentEntry!.id, aliceId);
      expect(world.device.kept.containsKey(tokenName), isTrue);
      expect(world.device.kept.containsKey(KeychainNames.full(guestId, null, 'session_token')), isFalse);
      final open = container.read(databaseSessionProvider)!;
      await tester.runAsync(() async {
        expect(await hostsOf(open), ['alice-host']);
      });
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => open.close());
    });

    testWidgets('a profile that has just opened waits for its session: it is no sign-out that stopped', (tester) async {
      late ProfileManager manager;
      late AppDatabase guestDb;
      await tester.runAsync(() async {
        (manager, guestDb) = await started();
      });
      await pumpApp(tester, manager, guestDb);
      final controller = container.read(profileControllerProvider);
      // As the app's root does, the moment the next profile is in place.
      Future<void>? asked;
      controller.onStart = () => asked = controller.afterOpened();
      await tester.runAsync(() async {
        await storeDesktopSession(ref, const BrowserSession(token: 'tok.en.here', uid: alice, email: 'alice@example.com'));
        await asked;
      });
      await tester.pump();
      expect(manager.currentEntry!.uid, alice);
      expect(manager.list.byUid(alice)!.state, ProfileState.open);
      final open = container.read(databaseSessionProvider)!;
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => open.close());
    });

    testWidgets('an account\'s profile with no session at a start: a sign-out that stopped, and it finishes', (tester) async {
      late ProfileManager manager;
      late AppDatabase guestDb;
      late AppDatabase aliceDb;
      await tester.runAsync(() async {
        (manager, guestDb) = await started();
        aliceDb = await signIn(manager, guestDb, alice);
      });
      SecretSeal.openTree = aliceDb;
      await pumpApp(tester, manager, aliceDb);
      await tester.runAsync(() async {
        await container.read(profileControllerProvider).afterOpened();
      });
      await tester.pump();
      expect(manager.currentEntry!.uid, isNull);
      expect(manager.list.byUid(alice)!.state, ProfileState.locked);
      final open = container.read(databaseSessionProvider)!;
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => open.close());
    });

    testWidgets('a known account with ZestSSH Cloud down: said, with a code and Try again, and it stays where it is', (tester) async {
      late ProfileManager manager;
      late AppDatabase guestDb;
      late AppDatabase aliceDb;
      await tester.runAsync(() async {
        (manager, guestDb) = await started();
        aliceDb = await signIn(manager, guestDb, alice);
        guestDb = await signOut(manager, aliceDb);
      });
      await pumpApp(tester, manager, guestDb);
      final guestId = manager.currentEntry!.id;
      world.cloud.down = true;
      debugBrowserSession = ({bool create = false}) async =>
          const BrowserSession(token: 'tok.en.here', uid: alice, email: 'alice@example.com');
      await tester.runAsync(() async {
        // Asks, and is answered by the test below.
        unawaited(signInInBrowser(context, ref));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.textContaining(lookupAppLocalizations(const Locale('en')).profileCannotOpenOffline), findsOneWidget);
      expect(find.textContaining('(${ErrorCodes.cloudNotResponding.code})'), findsOneWidget);
      expect(manager.currentEntry!.id, guestId);
      expect(container.read(databaseSessionProvider), same(guestDb));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => guestDb.close());
    });
  });

  group('what a sign-in that cannot open says', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    String words(String code, [Object? cause]) => profileCannotOpenWords(l10n, ProfileCannotOpen(code, cause));

    test('ZestSSH Cloud out of reach: what did not happen, then how it stands, with that code', () {
      final noAnswer = words('profile-offline', const SocketException('no route'));
      expect(noAnswer, startsWith(l10n.profileCannotOpenOffline));
      expect(noAnswer, endsWith('(${ErrorCodes.cloudNotResponding.code})'));
      final fault = words('profile-offline', const LockedCopyRefused(503, 'locked-copies-unavailable'));
      expect(fault, startsWith(l10n.profileCannotOpenOffline));
      expect(fault, endsWith('(${ErrorCodes.cloudFault.code})'));
    });

    test('each other case has a code of its own, and an answer that is no failure of the service is none of them', () {
      expect(words('profile-signed-in-long-ago'), endsWith('(${ErrorCodes.profileNeedsFreshSignIn.code})'));
      expect(words('profile-copy-broken'), endsWith('(${ErrorCodes.profileCopyDoesNotOpen.code})'));
      expect(words('profile-not-opened'), endsWith('(${ErrorCodes.profileDidNotOpen.code})'));
      expect(words('profile-offline', const LockedCopyRefused(429, 'too-many')), endsWith('(${ErrorCodes.profileDidNotOpen.code})'));
      expect(words('profile-offline'), endsWith('(${ErrorCodes.profileDidNotOpen.code})'));
    });
  });

  test('the ZestSSH Cloud client says what it was told', () {
    expect(const LockedCopyRefused(404, 'locked-copy-not-found').code, 'locked-copy-not-found');
    expect(profileControllerProvider, isNotNull);
  });
}

void unawaited(Future<void>? f) {}
