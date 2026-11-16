import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/keys/key_agent.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/profile_list.dart';
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

class _NoAgent implements SystemAgent {
  @override
  Future<Set<String>> fingerprints() async => const {};
  @override
  Future<void> add(Uint8List request) async {}
  @override
  Future<void> remove(Set<String> fingerprints) async {}
}

/// One person was counted as someone else on their own computer, so Delete all
/// local data's Everything (42cb1a41) was refused with "someone else's
/// accounts are on this computer", and the computer was marked shared for good
/// (3ca1ee0c), a review found: another profile of the
/// account on screen (its data set aside) was someone else's to Everything, and
/// a new profile of an account whose locked copy was gone at ZestSSH Cloud lost
/// the mark that made the person's other account theirs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
      systemAgentProvider.overrideWithValue(_NoAgent()),
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

  Future<void> signIn(ProviderContainer c, ProfileController profiles, String uid) async {
    final label = '$uid@example.com';
    await profiles.openForAccount(uid: uid, label: label, bearer: 'fresh-$uid');
    final store = c.read(secureStorageProvider);
    await AccountSecret.sessionToken.write(store, 'session-of-$uid');
    await store.write(key: 'session_uid', value: uid);
    await store.write(key: 'session_email', value: label);
    c.read(desktopSessionProvider.notifier).state = UserProfile(uid: uid, email: label);
    await profiles.sessionKept();
  }

  test(
      "a person's own data set aside (one account, one person) is theirs to Everything, as it is to "
      'Put back and Delete', () async {
    final (manager, c, profiles) = await computer();
    await signIn(c, profiles, 'alex');
    final old = manager.currentEntry!.id;
    // Alex's profile does not open after the PIN at some start: set aside, as the app offers.
    await c.read(databaseSessionProvider)!.close();
    await manager.setAsideCurrent();
    Profiles.debugReset();

    final m2 = world.launch();
    await m2.start();
    final guest = await m2.openCurrent();
    SecretSeal.openTree = guest;
    final c2 = app(guest);
    final p2 = c2.read(profileControllerProvider);
    // Alex signs in again: a new profile of Alex's account.
    await signIn(c2, p2, 'alex');
    expect(m2.currentEntry!.uid, 'alex');
    expect(m2.list.byId(old)!.state, ProfileState.setAside);
    expect(m2.list.peopleHere, 1, reason: 'one account, one person');
    expect(m2.list.shared, isFalse);
    expect(await p2.setAsideHere(), isTrue, reason: "Alex's own set-aside data is Alex's to put back or delete");
    expect(p2.mayDeleteEverything, isTrue, reason: "everything here is Alex's own");
    await c2.read(databaseSessionProvider)!.close();
  });

  test(
      "one person's two accounts: after a sign-in whose locked copy was gone at ZestSSH Cloud the new "
      "profile keeps the person's mark: the other account is theirs, Everything is allowed and the "
      'computer is not shared', () async {
    final (manager, c, profiles) = await computer();
    await signIn(c, profiles, 'alex');
    await profiles.nextSignInIs(mine: true);
    await signIn(c, profiles, 'alexwork');
    final mark = manager.list.byUid('alex')!.person;
    expect(mark, isNotNull);
    expect(manager.list.byUid('alexwork')!.person, mark, reason: 'said to be one person');
    expect(manager.list.shared, isFalse);

    final alex = manager.list.byUid('alex')!.id;
    await profiles.switchTo(alex);
    await profiles.lockAfterSignOut();
    expect(manager.list.byId(alex)!.state, ProfileState.locked);
    // The copy at ZestSSH Cloud is gone (deleted under Locked copies from another computer).
    world.cloud.held.clear();
    await signIn(c, profiles, 'alex');
    expect(manager.currentEntry!.uid, 'alex');
    expect(manager.list.byId(alex)!.state, ProfileState.lost, reason: 'a new profile was made, as said');

    // What the person meets, before the cause.
    final seen = (
      everythingAllowed: profiles.mayDeleteEverything,
      shared: manager.list.shared,
      workAsksSignIn: profiles.accountsHere.firstWhere((a) => a.entry.uid == 'alexwork').needsSignIn,
      mark: manager.list.byUid('alex')!.person,
    );
    printOnFailure('seen: $seen');
    expect(seen.everythingAllowed, isTrue, reason: "both accounts here are this person's");
    expect(seen.shared, isFalse, reason: 'one person has ever been here');
    expect(seen.workAsksSignIn, isFalse, reason: "the person's own other account, signed in behind");
    expect(seen.mark, mark, reason: 'the same account of the same person');
    await c.read(databaseSessionProvider)!.close();
  });
}
