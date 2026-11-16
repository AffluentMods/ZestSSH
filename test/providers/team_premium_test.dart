import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/services/purchase_service.dart';

/// The Orchards a test says this device has.
class _Teams implements OrchardDatabaseStorage {
  _Teams(this.ids);

  final List<String> ids;

  @override
  Future<bool> exists(String orchardId) async => ids.contains(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async => throw UnimplementedError();

  @override
  Future<void> delete(String orchardId) async {}

  @override
  Future<List<String>> list() async => ids;
}

/// Squeezed and Juiced for the members of a paid team, on a phone:
/// RevenueCat, a phone's own answer,
/// knows nothing of teams, so the phone also asks ZestSSH Cloud, which
/// counts the team; a computer's answer is ZestSSH Cloud's already. Here
/// RevenueCat is not set up (it says Free), and ZestSSH Cloud's answer is
/// the test's.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late int asked;
  late bool? answer;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TeamPremium.debugReset();
    TeamPremium.debugPhone = true;
    asked = 0;
    answer = true;
    TeamPremium.ask = () async {
      asked++;
      return answer;
    };
  });

  tearDown(() {
    TeamPremium.debugPhone = null;
    TeamPremium.debugReset();
  });

  Future<ProviderContainer> container(
      {bool signedIn = true, List<String> teams = const ['team-1'], String uid = 'alex'}) async {
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      authStateProvider.overrideWith((ref) => const Stream.empty()),
      currentUserProvider.overrideWith((ref) => signedIn ? UserProfile(uid: uid) : null),
      orchardDatabaseStorageProvider.overrideWithValue(_Teams(teams)),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  Future<ProviderContainer> phone(
      {bool signedIn = true, List<String> teams = const ['team-1'], String uid = 'alex'}) async {
    final c = await container(signedIn: signedIn, teams: teams, uid: uid);
    c.read(isProProvider);
    c.read(isCloudSyncProvider);
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    return c;
  }

  test('a member of a paid team gets Squeezed and Juiced on a phone, without a purchase of their own', () async {
    final c = await phone();
    expect(c.read(isProProvider), kOrchardsEnabled);
    expect(c.read(isCloudSyncProvider), kOrchardsEnabled);
    expect(asked, kOrchardsEnabled ? 1 : 0, reason: 'once for both, not once each');
  });

  test('an answer that does not come keeps the last; leaving the team takes them back', () async {
    final c = await phone();
    answer = null;
    expect(await c.read(isProProvider.notifier).forceRefresh(), kOrchardsEnabled);
    expect(c.read(isProProvider), kOrchardsEnabled, reason: 'ZestSSH Cloud not reached: as before');
    answer = false;
    expect(await c.read(isProProvider.notifier).forceRefresh(), isFalse);
    await c.read(isCloudSyncProvider.notifier).forceRefresh();
    expect(c.read(isProProvider), isFalse);
    expect(c.read(isCloudSyncProvider), isFalse);
  });

  test('a start with no network keeps the last answer this device had for the account, not for another', () async {
    await phone();
    TeamPremium.debugReset(); // the app started again
    answer = null; // and ZestSSH Cloud cannot be reached
    final again = await phone();
    expect(again.read(isProProvider), kOrchardsEnabled);
    expect(again.read(isCloudSyncProvider), kOrchardsEnabled);

    TeamPremium.debugReset();
    final other = await phone(uid: 'robin');
    expect(other.read(isProProvider), isFalse, reason: "another account's answer is not this one's");
  });

  test('a team joined later: a forced check of either asks again, and gives it', () async {
    answer = false;
    final c = await phone();
    expect(c.read(isProProvider), isFalse);
    expect(c.read(isCloudSyncProvider), isFalse);
    answer = true;
    expect(await c.read(isCloudSyncProvider.notifier).forceRefresh(), kOrchardsEnabled);
    expect(c.read(isCloudSyncProvider), kOrchardsEnabled);
    expect(await c.read(isProProvider.notifier).forceRefresh(), kOrchardsEnabled);
    expect(c.read(isProProvider), kOrchardsEnabled);
  });

  test('asked at most once a minute, unless forced', () async {
    final c = await phone();
    final before = asked;
    await c.read(isProProvider.notifier).refresh();
    await c.read(isCloudSyncProvider.notifier).refresh();
    expect(asked, before, reason: 'the last answer, under a minute old');
    await c.read(isProProvider.notifier).forceRefresh();
    expect(asked, kOrchardsEnabled ? before + 1 : 0);
  });

  test('nobody else asks anything new: signed out, or with no team on this device', () async {
    final out = await phone(signedIn: false);
    expect(out.read(isProProvider), isFalse);
    final none = await phone(teams: const []);
    expect(none.read(isProProvider), isFalse);
    expect(none.read(isCloudSyncProvider), isFalse);
    await none.read(isProProvider.notifier).forceRefresh();
    expect(asked, 0);
  });

  test("ZestSSH Cloud's answer says the team apart", () {
    expect(PurchaseService.webEntitlementsFrom({'pro': true, 'cloudSync': true, 'team': {'active': true, 'orchard_id': 'o'}}),
        (pro: true, cloudSync: true, team: true));
    expect(PurchaseService.webEntitlementsFrom({'pro': false, 'cloudSync': false, 'team': {'active': false, 'orchard_id': null}}),
        (pro: false, cloudSync: false, team: false));
    expect(PurchaseService.webEntitlementsFrom({'pro': true, 'cloud_sync': true}), (pro: true, cloudSync: true, team: false),
        reason: 'a server from before teams');
    expect(PurchaseService.webEntitlementsFrom({'team': true})?.team, isFalse, reason: 'not what the server sends');
    expect(PurchaseService.webEntitlementsFrom('not an answer'), isNull);
  });

  test("a computer takes ZestSSH Cloud's own answer, which counts the team: nothing more is asked", () async {
    TeamPremium.debugPhone = false;
    final c = await container();
    expect(await TeamPremium.active(c.read(_refProvider)), isFalse);
    expect(await TeamPremium.active(c.read(_refProvider), force: true), isFalse);
    expect(asked, 0);
  });

  // 4.0, the plan's chip: a member whose plan
  // comes from a team's seat never sees the fruit names.
  test("a seat is said as one: the account's plan is a team seat, and leaving the team or signing out ends it",
      () async {
    final c = await phone();
    expect(c.read(teamSeatProvider), kOrchardsEnabled);
    expect(c.read(accountPlanProvider), kOrchardsEnabled ? AccountPlan.teamSeat : AccountPlan.free);
    answer = false;
    await c.read(isProProvider.notifier).forceRefresh();
    await c.read(isCloudSyncProvider.notifier).forceRefresh();
    expect(c.read(teamSeatProvider), isFalse);
    expect(c.read(accountPlanProvider), AccountPlan.free);

    answer = true;
    await c.read(isProProvider.notifier).forceRefresh();
    expect(c.read(teamSeatProvider), kOrchardsEnabled);
    c.read(isProProvider.notifier).signedOut();
    expect(c.read(teamSeatProvider), isFalse, reason: 'signed out, it is nobody\'s');
  });

  test("the answer a computer keeps for a start with no network is the account's own", () async {
    final c = await container();
    final ref = c.read(_refProvider);
    expect(TeamPremium.keptFor(ref), isFalse, reason: 'nothing kept yet');
    await TeamPremium.keep(ref, true);
    expect(TeamPremium.keptFor(ref), isTrue);
    final robin = await container(uid: 'robin');
    expect(TeamPremium.keptFor(robin.read(_refProvider)), isFalse, reason: "another account's");
    await TeamPremium.keep(ref, false);
    expect(TeamPremium.keptFor(ref), isFalse);
    final out = await container(signedIn: false);
    expect(TeamPremium.keptFor(out.read(_refProvider)), isFalse);
  });
}

/// A [Ref] for calling [TeamPremium.active] directly.
final _refProvider = Provider<Ref>((ref) => ref);
