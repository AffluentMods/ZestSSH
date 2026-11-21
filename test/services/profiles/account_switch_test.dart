import 'package:zestssh/providers/local_data_wipe.dart' show deleteAllLocalData, wipeThisDevice;
import 'package:zestssh/services/account/local_data_wiper.dart' show WipeTargets;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/connect_link.dart' show quickConnectLinkText;
import 'package:zestssh/features/keys/key_agent.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart' show MyInvite;
import 'package:zestssh/l10n/generated/app_localizations_en.dart';
import 'package:zestssh/providers/account_sign_out.dart' show signOutAccountWith;
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/cert_reminder_providers.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/idle_lock_providers.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/redaction_providers.dart' show redactionFleetRegistrar;
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/router/router.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/entitlement_diagnostics.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/profile_list.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';
import 'package:zestssh/services/profiles/profile_vault.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/purchase_service.dart';
import 'package:zestssh/services/shortcut_service.dart';
import 'package:zestssh/services/task_scheduler_service.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/report_scrub.dart';
import 'package:zestssh/utils/secret_clipboard.dart';

import 'profile_world.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(false);
  int asked = 0;
  @override
  Future<void> refresh() async => asked++;
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

class _Agent implements SystemAgent {
  final removed = <Set<String>>[];
  bool reachable = true;

  /// What it holds as a key is given; null where it cannot say.
  Set<String>? held = const {};
  var added = 0;
  @override
  Future<Set<String>> fingerprints() async => held ?? (throw StateError('it does not say'));
  @override
  Future<void> add(Uint8List request) async => added++;
  @override
  Future<void> remove(Set<String> fingerprints) async {
    if (!reachable) throw StateError('no agent here');
    removed.add(fingerprints);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A provider nobody in the app knows of: whatever a person's state is, it is built
/// again at a change of profile unless it is named to survive.
final _someoneNew = StateProvider<String>((_) => 'as built');

/// Accounts on one computer: the switch, the five, whose it is,
/// and Remove from this computer.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProfileWorld world;
  late List<String> ended;
  late Future<void> Function(String) endBefore;
  setUp(() async {
    world = await ProfileWorld.create();
    ended = [];
    endBefore = ProfileController.endSession;
    ProfileController.endSession = (bearer) async => ended.add(bearer);
  });
  tearDown(() async {
    ProfileController.endSession = endBefore;
    await world.dispose();
  });

  ProviderContainer app(AppDatabase db, {SystemAgent? agent}) {
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(ProfilePreferences.instance!),
      secureStorageProvider.overrideWithValue(ProfileKeychain(world.device)),
      isProProvider.overrideWith((ref) => _Pro()),
      isCloudSyncProvider.overrideWith((ref) => _Juiced()),
      deviceSessionServiceProvider.overrideWithValue(_Devices()),
      if (agent != null) systemAgentProvider.overrideWithValue(agent),
    ]);
    c.read(databaseSessionProvider.notifier).seed(db);
    addTearDown(c.dispose);
    return c;
  }

  /// Guest data on screen, as a computer starts.
  Future<(ProfileManager, ProviderContainer, ProfileController)> computer({SystemAgent? agent}) async {
    final manager = world.launch();
    await manager.start();
    final guest = await manager.openCurrent();
    SecretSeal.openTree = guest;
    final c = app(guest, agent: agent);
    return (manager, c, c.read(profileControllerProvider));
  }

  /// A browser sign-in of [uid] from what is on screen, with its session written, as
  /// storeDesktopSession does.
  Future<void> signIn(ProviderContainer c, ProfileController profiles, String uid, {List<String> hosts = const []}) async {
    final label = '$uid@example.com';
    await profiles.openForAccount(uid: uid, label: label, bearer: 'fresh-$uid');
    final store = c.read(secureStorageProvider);
    await AccountSecret.sessionToken.write(store, 'session-of-$uid');
    await store.write(key: 'session_uid', value: uid);
    await store.write(key: 'session_email', value: label);
    c.read(desktopSessionProvider.notifier).state = UserProfile(uid: uid, email: label);
    await profiles.sessionKept();
    final db = c.read(databaseSessionProvider)!;
    for (final h in hosts) {
      await addHost(db, h);
    }
  }

  /// A signed in with a host, then B on screen with a host.
  Future<(ProfileManager, ProviderContainer, ProfileController)> twoAccounts({SystemAgent? agent}) async {
    final (manager, c, profiles) = await computer(agent: agent);
    await signIn(c, profiles, 'alex', hosts: ['alex-host']);
    await signIn(c, profiles, 'sam', hosts: ['sam-host']);
    return (manager, c, profiles);
  }

  /// A signed in with a host, then another account of the same person on screen with
  /// a host (said to be "mine").
  Future<(ProfileManager, ProviderContainer, ProfileController)> twoOfMine({SystemAgent? agent}) async {
    final (manager, c, profiles) = await computer(agent: agent);
    await signIn(c, profiles, 'alex', hosts: ['alex-host']);
    await profiles.nextSignInIs(mine: true);
    await signIn(c, profiles, 'sam', hosts: ['sam-host']);
    return (manager, c, profiles);
  }

  String idOf(ProfileManager manager, String uid) => manager.list.byUid(uid)!.id;

  Future<List<String>> shown(ProviderContainer c) async {
    final sub = c.listen(allConnectionsProvider, (_, _) {});
    addTearDown(sub.close);
    final rows = await c.read(allConnectionsProvider.future);
    return [for (final r in rows) r.id]..sort();
  }

  group('a switch', () {
    test('opens the other account at once, with its own hosts and session, and the first stays signed in behind it', () async {
      final (manager, c, profiles) = await twoOfMine();
      expect(await shown(c), ['sam-host']);
      expect(c.read(currentUserProvider)?.uid, 'sam');

      await profiles.switchTo(idOf(manager, 'alex'));

      expect(manager.currentEntry!.uid, 'alex');
      expect(Profiles.current!.uid, 'alex');
      expect(await shown(c), ['alex-host']);
      expect(c.read(currentUserProvider)?.uid, 'alex', reason: 'its own session, with no sign-in');
      expect(await AccountSecret.sessionToken.read(c.read(secureStorageProvider)), 'session-of-alex');
      expect(manager.list.byUid('sam')!.state, ProfileState.open, reason: 'a switch locks nothing');
      expect(world.cloud.handBacks, isEmpty, reason: 'and asks ZestSSH Cloud for nothing');

      await profiles.switchTo(idOf(manager, 'sam'));
      expect(await shown(c), ['sam-host']);
      expect(c.read(currentUserProvider)?.uid, 'sam');
      await c.read(databaseSessionProvider)!.close();
    });

    test('guest data opens the same way, and the account stays signed in behind it', () async {
      final (manager, c, profiles) = await twoOfMine();
      await profiles.switchToGuest();
      expect(manager.currentEntry!.uid, isNull);
      expect(c.read(currentUserProvider), isNull);
      expect(await shown(c), isEmpty);
      expect(manager.list.byUid('sam')!.state, ProfileState.open);
      await c.read(databaseSessionProvider)!.close();
    });

    test('the settings of one account are never those of another', () async {
      final (manager, c, profiles) = await twoOfMine();
      final key = SettingsService.profileKeys.first;
      final prefs = ProfilePreferences.instance!;
      await prefs.setString(key, 'what sam chose');
      await profiles.switchTo(idOf(manager, 'alex'));
      expect(prefs.getString(key), isNull);
      await prefs.setString(key, 'what alex chose');
      await profiles.switchTo(idOf(manager, 'sam'));
      expect(prefs.getString(key), 'what sam chose');
      await c.read(databaseSessionProvider)!.close();
    });

    test('nothing of the old profile stays in a provider, and what survives is named here', () async {
      final (manager, c, profiles) = await twoOfMine();
      final before = c.read(databaseSessionProvider)!;
      c.read(_someoneNew.notifier).state = 'sam was here';
      c.read(activeSpaceProvider.notifier).state = const OrchardSpace('a-team-of-sams');
      c.read(connectionSearchQueryProvider.notifier).state = 'sam-host';
      c.read(myInvitesProvider.notifier).state = [
        MyInvite(id: 'i', orchardId: 'o', role: 'admin', crates: 1, expiresAt: DateTime.utc(2030), accepted: false),
      ];

      await profiles.switchTo(idOf(manager, 'alex'));

      expect(c.read(_someoneNew), 'as built', reason: 'every provider is built again, whatever it is');
      expect(c.read(activeSpaceProvider), isA<TreeSpace>());
      expect(c.read(connectionSearchQueryProvider), isEmpty);
      expect(c.read(myInvitesProvider), isEmpty);
      await expectLater(before.customSelect('SELECT 1').get(), throwsA(anything), reason: 'its database is closed');

      // One added here keeps a person's state across a change: a decision, not a slip.
      expect(survivesAChange.toSet(), {
        cloudReachProvider,
        sharedPreferencesProvider,
        secureStorageProvider,
        databaseSessionProvider,
        isAppLockedProvider,
        securityLockServiceProvider,
        vaultSlotServiceProvider,
        hardwareVaultServiceProvider,
        localAuthProvider,
        routerProvider,
        authStateProvider,
        idleClockProvider,
        profileControllerProvider,
      });
      await c.read(databaseSessionProvider)!.close();
    });

    test('what runs stops once and starts once, and what lives outside the app state is forgotten', () async {
      final (manager, c, profiles) = await twoOfMine();
      var stops = 0;
      var starts = 0;
      profiles.onStop = () => stops++;
      profiles.onStart = () {
        starts++;
        expect(c.read(currentUserProvider)?.uid, 'alex', reason: 'startup work finds the account that is on screen');
        expect(identical(SecretSeal.openTree, c.read(databaseSessionProvider)), isTrue);
      };
      ShortcutService.pendingConnection.value = 'sam-host';
      quickConnectLinkText.value = 'ssh://sam-host.example.com';
      unawaited(SecretClipboard.copy('sams-password'));
      PurchaseService.lastDiagnostic = EntitlementDiagnostic(at: DateTime.utc(2026, 10, 31), endpoint: 'played', error: 'sams');
      DeviceSessionHeader.current = 'a-session-of-sams';

      await profiles.switchTo(idOf(manager, 'alex'));

      expect(stops, 1);
      expect(starts, 1);
      expect(ShortcutService.pendingConnection.value, isNull);
      expect(quickConnectLinkText.value, isNull);
      expect(SecretClipboard.holding, isFalse, reason: 'a secret copied is not left for the next person');
      expect(PurchaseService.lastDiagnostic, isNull);
      expect(DeviceSessionHeader.current, isNull);
      await c.read(databaseSessionProvider)!.close();
    });

    test('a report is scrubbed of the names of the profile on screen, and never of the one before\'s', () async {
      final (manager, c, profiles) = await twoOfMine();
      addTearDown(ReportScrub.clearFolders);
      addTearDown(Redactor.instance.clearNames);
      Future<void> listsLoaded() async {
        c.read(redactionFleetRegistrar);
        await c.read(connectionsWithDetailsProvider.future);
        await Future<void>.delayed(Duration.zero);
      }

      final sub = c.listen(connectionsWithDetailsProvider, (_, _) {});
      addTearDown(sub.close);
      await listsLoaded();
      expect(ReportScrub.scrub('sam-host refused'), '<host> refused');

      await profiles.switchTo(idOf(manager, 'alex'));
      // Forgotten with the change, before the next profile's lists load.
      expect(ReportScrub.scrub('sam-host refused'), 'sam-host refused');
      final again = c.listen(connectionsWithDetailsProvider, (_, _) {});
      addTearDown(again.close);
      await listsLoaded();
      expect(ReportScrub.scrub('alex-host refused'), '<host> refused', reason: 'the next profile\'s are given');
      expect(ReportScrub.scrub('sam-host refused'), 'sam-host refused', reason: 'the one before\'s are not there');
      await c.read(databaseSessionProvider)!.close();
    });

    test('nothing of the old profile runs or writes after it: what runs is built anew, and its keychain is left alone', () async {
      final (manager, c, profiles) = await twoOfMine();
      final sam = idOf(manager, 'sam');
      final sync = c.read(autoSyncServiceProvider);
      final teams = c.read(orchardSyncSchedulerProvider);
      final monitors = c.read(agentlessMonitorPollerProvider.notifier);
      final checks = c.read(connectionHealthProvider.notifier);
      final reminders = c.read(certRemindersProvider);
      final before = c.read(databaseSessionProvider)!;

      await profiles.switchTo(idOf(manager, 'alex'));
      world.device.log.clear();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(identical(c.read(autoSyncServiceProvider), sync), isFalse);
      expect(identical(c.read(orchardSyncSchedulerProvider), teams), isFalse);
      expect(identical(c.read(agentlessMonitorPollerProvider.notifier), monitors), isFalse);
      expect(identical(c.read(connectionHealthProvider.notifier), checks), isFalse);
      expect(identical(c.read(certRemindersProvider), reminders), isFalse);
      final prefix = KeychainPrefix.of(sam);
      expect(world.device.log.where((l) => l.contains(prefix)), isEmpty);
      await expectLater(addHost(before, 'written-after-the-switch'), throwsA(anything));
      await c.read(databaseSessionProvider)!.close();
    });

    test('one signed out is no switch: its key is not to be had without its sign-in', () async {
      final (manager, c, profiles) = await twoOfMine();
      final alex = idOf(manager, 'alex');
      await profiles.switchTo(alex);
      await profiles.lockAfterSignOut();
      final copy = world.device.kept['${KeychainPrefix.of(alex)}${KeychainNames.lockedCopy}'];
      await expectLater(
        profiles.switchTo(alex),
        throwsA(isA<ProfileCannotOpen>().having((e) => e.code, 'code', 'profile-signed-in-long-ago')),
      );
      expect(manager.list.byId(alex)!.state, ProfileState.locked);
      expect(world.device.kept['${KeychainPrefix.of(alex)}${KeychainNames.lockedCopy}'], copy, reason: 'it opens as it did');
      await c.read(databaseSessionProvider)!.close();
    });

    test('a key the agent held before it was given is the person\'s own: it stays at every change', () async {
      final agent = _Agent()..held = {'SHA256:aaaa'};
      final (manager, c, profiles) = await twoOfMine(agent: agent);
      final db = c.read(databaseSessionProvider)!;
      Future<Identity> keyOf(String id, String print) async {
        await db.into(db.identities).insert(IdentitiesCompanion.insert(
              id: id,
              label: id,
              username: 'demo',
              authMethod: 'publicKey',
              publicKeyFingerprint: Value(print),
              createdAt: DateTime.utc(2026, 10, 31),
            ));
        return (db.select(db.identities)..where((t) => t.id.equals(id))).getSingle();
      }

      final pem = (await KeyGenerationService().generateEd25519(comment: 'test')).privatePem;
      final store = LocalStateStore(db);
      await giveKeyToAgent(agent, store, await keyOf('own', 'SHA256:aaaa'), pem);
      await giveKeyToAgent(agent, store, await keyOf('given', 'SHA256:bbbb'), pem);
      agent.held = null;
      await giveKeyToAgent(agent, store, await keyOf('unsaid', 'SHA256:cccc'), pem);
      expect(agent.added, 3);

      await profiles.switchTo(idOf(manager, 'alex'));
      expect(agent.removed.single, {'SHA256:bbbb', 'SHA256:cccc'});
      await c.read(databaseSessionProvider)!.close();
    });

    test('keys this profile gave the system agent are taken back; with no agent to reach the note stays', () async {
      final agent = _Agent();
      final (manager, c, profiles) = await twoOfMine(agent: agent);
      final db = c.read(databaseSessionProvider)!;
      await db.into(db.identities).insert(IdentitiesCompanion.insert(
            id: 'k',
            label: 'k',
            username: 'demo',
            authMethod: 'publicKey',
            publicKeyFingerprint: const Value('SHA256:aaaa'),
            createdAt: DateTime.utc(2026, 10, 30),
          ));
      final key = await (db.select(db.identities)..where((t) => t.id.equals('k'))).getSingle();
      await noteGivenToAgent(LocalStateStore(c.read(databaseSessionProvider)!), key);

      agent.reachable = false;
      await profiles.switchTo(idOf(manager, 'alex'));
      expect(agent.removed, isEmpty);
      expect(world.device.kept[agentKeysOwedName], contains('SHA256:aaaa'), reason: "owed, on the computer's list");

      agent.reachable = true;
      await profiles.switchTo(idOf(manager, 'sam'));
      expect(agent.removed.single, {'SHA256:aaaa'}, reason: 'what was owed goes at the next change, though alex gave none');
      expect(world.device.kept.containsKey(agentKeysOwedName), isFalse);
      await profiles.switchTo(idOf(manager, 'alex'));
      expect(agent.removed, hasLength(2), reason: "sam's own note still said so");

      await profiles.switchTo(idOf(manager, 'sam'));
      expect(agent.removed, hasLength(2), reason: 'no more, as the note is cleared');
      await c.read(databaseSessionProvider)!.close();
    });

    // Found in a review: a key's only record was its own
    // profile's note, written after the give, which went with the profile.
    Future<Identity> keyIn(AppDatabase db, String id, String print) async {
      await db.into(db.identities).insert(IdentitiesCompanion.insert(
            id: id,
            label: id,
            username: 'demo',
            authMethod: 'publicKey',
            publicKeyFingerprint: Value(print),
            createdAt: DateTime.utc(2026, 11, 5),
          ));
      return (db.select(db.identities)..where((t) => t.id.equals(id))).getSingle();
    }

    test("a key is on the computer's list before the agent has it, and a stop before its note leaves it said", () async {
      final agent = _Agent();
      final (manager, c, profiles) = await twoOfMine(agent: agent);
      final db = c.read(databaseSessionProvider)!;
      final keychain = c.read(secureStorageProvider);
      final pem = (await KeyGenerationService().generateEd25519(comment: 'test')).privatePem;
      final sam = manager.currentEntry!.id;
      final key = await keyIn(db, 'k', 'SHA256:eeee');
      // The app ends between the give and the profile's note: its database is gone.
      final closed = await openPlayed(await Directory(p.join(world.root.path, 'closed')).create(), 'x');
      await closed.close();
      await expectLater(giveKeyToAgent(agent, LocalStateStore(closed), key, pem, keychain: keychain), throwsA(anything));
      expect(agent.added, 1, reason: 'the agent has it');
      expect(world.device.kept[agentKeysOwedName], allOf(contains('SHA256:eeee'), contains(sam)));

      // A key the agent did not take is not owed.
      await expectLater(giveKeyToAgent(agent, LocalStateStore(db), await keyIn(db, 'k2', 'SHA256:ffff'), null, keychain: keychain),
          throwsA(isA<AgentAddFailed>()));
      expect(world.device.kept[agentKeysOwedName], isNot(contains('SHA256:ffff')));

      await profiles.switchTo(idOf(manager, 'alex'));
      expect(agent.removed.single, {'SHA256:eeee'});
      await c.read(databaseSessionProvider)!.close();
    });

    test('what a profile owes goes back at the next opening of another, after its take-back failed and it was removed', () async {
      final agent = _Agent();
      final (manager, c, profiles) = await twoOfMine(agent: agent);
      final pem = (await KeyGenerationService().generateEd25519(comment: 'test')).privatePem;
      await profiles.switchTo(idOf(manager, 'alex'));
      final alex = manager.currentEntry!.id;
      final db = c.read(databaseSessionProvider)!;
      await giveKeyToAgent(agent, LocalStateStore(db), await keyIn(db, 'k', 'SHA256:1111'), pem);
      expect(File(p.join(Profiles.current!.dir.path, 'agent_keys_given_v1.json')).existsSync(), isTrue);

      agent.reachable = false;
      await profiles.switchTo(idOf(manager, 'sam'));
      // Removed from Sam's screen (one person's), with the agent still out of reach.
      expect(await profiles.removeFromComputer(alex), isTrue);
      expect(manager.list.byId(alex), isNull);
      expect(agent.removed, isEmpty);
      expect(world.device.kept[agentKeysOwedName], contains('SHA256:1111'), reason: 'its note went with its folder; the list stays');

      agent.reachable = true;
      await profiles.afterOpened();
      expect(agent.removed.single, {'SHA256:1111'});
      expect(world.device.kept.containsKey(agentKeysOwedName), isFalse);
      await c.read(databaseSessionProvider)!.close();
    });

    test("Everything takes back what every profile's note says, not only the one on screen's", () async {
      final agent = _Agent();
      final (manager, c, profiles) = await twoOfMine(agent: agent);
      final pem = (await KeyGenerationService().generateEd25519(comment: 'test')).privatePem;
      await profiles.switchTo(idOf(manager, 'alex'));
      var db = c.read(databaseSessionProvider)!;
      await giveKeyToAgent(agent, LocalStateStore(db), await keyIn(db, 'k', 'SHA256:2222'), pem);
      agent.reachable = false;
      await profiles.switchTo(idOf(manager, 'sam'));
      agent.reachable = true;
      // As a build before the computer's list left it: only Alex's note says so.
      world.device.kept.remove(agentKeysOwedName);
      db = c.read(databaseSessionProvider)!;
      await giveKeyToAgent(agent, LocalStateStore(db), await keyIn(db, 'k3', 'SHA256:3333'), pem);

      await deleteAllLocalData(c.read, everything: true, targets: const WipeTargets());
      expect(agent.removed.expand((r) => r).toSet(), containsAll({'SHA256:2222', 'SHA256:3333'}));
      await c.read(databaseSessionProvider)!.close();
    });

    // Found in a review: the wipe deleted the record of the
    // keys an agent had not taken back, with nothing said.
    test('Delete all local data asks first where the agent did not take the keys back, and the wipe keeps their fingerprints (L-3)', () async {
      final agent = _Agent();
      final (manager, c, profiles) = await twoOfMine(agent: agent);
      final sam = manager.currentEntry!.id;
      final db = c.read(databaseSessionProvider)!;
      final pem = (await KeyGenerationService().generateEd25519(comment: 'test')).privatePem;
      await giveKeyToAgent(agent, LocalStateStore(db), await keyIn(db, 'k', 'SHA256:5555'), pem,
          keychain: c.read(secureStorageProvider));
      agent.reachable = false;

      var asked = 0;
      expect(await deleteAllLocalData(c.read, targets: const WipeTargets(), whenKeysStay: () async => ++asked < 0), isFalse);
      expect(asked, 1);
      expect(manager.currentEntry!.id, sam, reason: 'said no: nothing went');
      expect(await hostsOf(c.read(databaseSessionProvider)!), ['sam-host']);

      expect(await deleteAllLocalData(c.read, targets: const WipeTargets(), whenKeysStay: () async => ++asked > 0), isTrue);
      expect(asked, 2);
      expect(manager.list.byId(sam), isNull, reason: 'wiped');
      expect(world.device.kept[agentKeysOwedName], contains('SHA256:5555'), reason: "the computer's list outlives the wipe");

      agent.reachable = true;
      await profiles.afterOpened();
      expect(agent.removed.single, {'SHA256:5555'});

      // Nothing left in the agent: nothing to ask.
      expect(await deleteAllLocalData(c.read, targets: const WipeTargets(), whenKeysStay: () async => ++asked < 0), isTrue);
      expect(asked, 2);
      await c.read(databaseSessionProvider)!.close();
    });

    test('a note only in the database, from before its copy was kept beside it, is copied there at an opening', () async {
      final agent = _Agent();
      final (manager, c, profiles) = await twoOfMine(agent: agent);
      final db = c.read(databaseSessionProvider)!;
      await LocalStateStore(db).write('agent_keys_given_v1', jsonEncode(['SHA256:4444']));
      final copy = File(p.join(Profiles.current!.dir.path, 'agent_keys_given_v1.json'));
      expect(copy.existsSync(), isFalse);

      await profiles.afterOpened();
      expect(copy.readAsStringSync(), contains('SHA256:4444'));
      expect(agent.removed, isEmpty, reason: "this profile's own stay while it is on screen");

      // The app locks and the account signs out: only the copy can say which they are.
      await db.close();
      await takeBackAgentKeys(agent, null);
      expect(agent.removed.single, {'SHA256:4444'});
    });

    test('with the database closed (the app locked when an account signs out), what was given is still taken back', () async {
      final agent = _Agent();
      final (manager, c, profiles) = await twoOfMine(agent: agent);
      final db = c.read(databaseSessionProvider)!;
      await db.into(db.identities).insert(IdentitiesCompanion.insert(
            id: 'k',
            label: 'k',
            username: 'demo',
            authMethod: 'publicKey',
            publicKeyFingerprint: const Value('SHA256:dddd'),
            createdAt: DateTime.utc(2026, 11, 5),
          ));
      final key = await (db.select(db.identities)..where((t) => t.id.equals('k'))).getSingle();
      await noteGivenToAgent(LocalStateStore(db), key);
      final copy = File(p.join(Profiles.current!.dir.path, 'agent_keys_given_v1.json'));
      expect(copy.existsSync(), isTrue, reason: 'a copy beside the database, read while it is closed');
      expect(copy.readAsStringSync(), isNot(contains('PRIVATE')), reason: 'fingerprints only');
      await db.close();

      await takeBackAgentKeys(agent, null);
      expect(agent.removed.single, {'SHA256:dddd'});
      expect(copy.existsSync(), isFalse, reason: 'taken back, the copy goes');
      await takeBackAgentKeys(agent, null);
      expect(agent.removed, hasLength(1), reason: 'once');
    });

    test('keys this profile gave the system agent are taken back by Delete all local data, before the note goes with the data', () async {
      // Found in a security review: the wipe deleted the note of
      // which keys were given before anything read it, so they stayed in the
      // agent for the next person on this computer's login.
      final agent = _Agent();
      final (manager, c, profiles) = await twoOfMine(agent: agent);
      final db = c.read(databaseSessionProvider)!;
      await db.into(db.identities).insert(IdentitiesCompanion.insert(
            id: 'k',
            label: 'k',
            username: 'demo',
            authMethod: 'publicKey',
            publicKeyFingerprint: const Value('SHA256:dddd'),
            createdAt: DateTime.utc(2026, 11, 4),
          ));
      final key = await (db.select(db.identities)..where((t) => t.id.equals('k'))).getSingle();
      await noteGivenToAgent(LocalStateStore(db), key);

      await deleteAllLocalData(c.read, targets: const WipeTargets());
      expect(agent.removed, contains(equals({'SHA256:dddd'})));
    });

    // Found in a review: Android's WorkManager jobs kept
    // their command text after the wipe deleted their rows, and nothing cancelled them.
    test('Delete all local data cancels the job of every scheduled task (L-2)', () async {
      const channel = MethodChannel('com.affluentlabs.zestssh/scheduler');
      final asked = <String>[];
      TaskSchedulerService.debugAvailable = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        asked.add(call.method);
        return null;
      });
      addTearDown(() {
        TaskSchedulerService.debugAvailable = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      });
      final (manager, c, profiles) = await twoOfMine();
      await deleteAllLocalData(c.read, targets: const WipeTargets());
      expect(asked, contains('cancelAll'));
      await c.read(databaseSessionProvider)!.close();
    });

    test('a database that does not open: nothing stopped, nothing changed, and it can be tried again', () async {
      var fails = false;
      world.openDatabase = (dir, hex) {
        if (fails) throw const FileSystemException('played: it did not open');
        return openPlayed(dir, hex);
      };
      final (manager, c, profiles) = await twoOfMine();
      final db = c.read(databaseSessionProvider)!;
      final sam = idOf(manager, 'sam');
      final alex = idOf(manager, 'alex');
      var stops = 0;
      profiles.onStop = () => stops++;

      fails = true;
      await expectLater(profiles.switchTo(alex), throwsA(isA<ProfileCannotOpen>()));

      expect(stops, 0, reason: 'nothing closed for what could not open');
      expect(manager.list.current, sam);
      expect(Profiles.current!.id, sam);
      expect(identical(c.read(databaseSessionProvider), db), isTrue);
      expect(await hostsOf(db), ['sam-host']);

      fails = false;
      await profiles.switchTo(alex);
      expect(await shown(c), ['alex-host']);
      await c.read(databaseSessionProvider)!.close();
    });

    test('a change that stops halfway stays on what it was, with its seal and its settings, and goes when tried again', () async {
      final (manager, c, profiles) = await twoOfMine();
      final db = c.read(databaseSessionProvider)!;
      final sam = idOf(manager, 'sam');
      final alex = idOf(manager, 'alex');
      final key = SettingsService.profileKeys.first;
      await ProfilePreferences.instance!.setString(key, 'what sam chose');
      var starts = 0;
      profiles.onStart = () => starts++;

      // The keychain stops answering as the other profile is committed.
      world.device.stopAfter = 0;
      await expectLater(profiles.switchTo(alex), throwsA(isA<ProfileCannotOpen>()));
      world.device.stopAfter = null;

      expect(manager.list.current, sam);
      expect(Profiles.current!.id, sam);
      expect(identical(c.read(databaseSessionProvider), db), isTrue);
      expect(identical(SecretSeal.openTree, db), isTrue);
      expect(ProfilePreferences.instance!.getString(key), 'what sam chose');
      expect(starts, 1, reason: 'what stopped for it starts again');
      expect(await hostsOf(db), ['sam-host']);

      // Further along: its key is kept and the list is being written.
      world.device.stopAfter = 1;
      await expectLater(profiles.switchTo(alex), throwsA(isA<ProfileCannotOpen>()));
      world.device.stopAfter = null;
      expect(manager.list.current, sam, reason: 'the list says what is on screen');
      expect(Profiles.current!.id, sam);
      expect(identical(SecretSeal.openTree, db), isTrue);

      await profiles.switchTo(alex);
      expect(await shown(c), ['alex-host']);
      await c.read(databaseSessionProvider)!.close();
    });

    test('an account with no session of its own cannot stay behind another: a Mac on Firebase locks as it leaves', () async {
      final (manager, c, profiles) = await computer();
      world.firebase = 'alex';
      await profiles.afterFirebaseSignIn();
      expect(manager.currentEntry!.uid, 'alex');
      expect(profiles.heldByFirebase, isTrue);
      await manager.settleLockedCopy(db: c.read(databaseSessionProvider)!, bearer: 'b');

      world.firebase = 'sam';
      await profiles.afterFirebaseSignIn();

      expect(manager.currentEntry!.uid, 'sam');
      expect(manager.list.byUid('alex')!.state, ProfileState.locked);
      await c.read(databaseSessionProvider)!.close();
    });
  });

  group('whose it is', () {
    Map<String, bool> asks(ProfileController profiles) => {for (final a in profiles.accountsHere) a.entry.uid!: a.needsSignIn};

    test('nobody asked: another account asks for its sign-in, and what is signed out always does', () async {
      final (manager, c, profiles) = await twoAccounts();
      expect(profiles.accountsHere.singleWhere((a) => a.inUse).entry.uid, 'sam');
      expect(asks(profiles)['alex'], isTrue);
      await signIn(c, profiles, 'alex');
      expect(asks(profiles)['sam'], isTrue, reason: 'either way');
      await c.read(databaseSessionProvider)!.close();
    });

    test('another of mine opens at once, either way; someone else\'s asks, either way', () async {
      final (manager, c, profiles) = await computer();
      await signIn(c, profiles, 'alex');
      expect(profiles.addAsksWhose, isTrue);

      await profiles.nextSignInIs(mine: true);
      await signIn(c, profiles, 'alex-work');
      expect(asks(profiles)['alex'], isFalse);
      await profiles.switchTo(idOf(manager, 'alex'));
      expect(asks(profiles)['alex-work'], isFalse);

      await profiles.nextSignInIs(mine: false);
      await signIn(c, profiles, 'sam');
      expect(asks(profiles)['alex'], isTrue);
      expect(asks(profiles)['alex-work'], isTrue);
      await c.read(databaseSessionProvider)!.close();
    });

    test('kept across a start, in the list', () async {
      final (manager, c, profiles) = await computer();
      await signIn(c, profiles, 'alex');
      await profiles.nextSignInIs(mine: true);
      await signIn(c, profiles, 'alex-work');
      final mark = manager.list.byUid('alex')!.person;
      expect(mark, isNotNull);
      expect(manager.list.byUid('alex-work')!.person, mark);
      expect(world.device.kept[ProfileList.name], contains(mark));
      await c.read(databaseSessionProvider)!.close();
    });

    test('from guest data: one person\'s accounts open at once, and with two people here each asks', () async {
      final (manager, c, profiles) = await computer();
      await signIn(c, profiles, 'alex');
      await profiles.nextSignInIs(mine: true);
      await signIn(c, profiles, 'alex-work');
      await profiles.switchToGuest();
      expect(asks(profiles)['alex'], isFalse);

      await profiles.nextSignInIs(mine: false);
      await signIn(c, profiles, 'sam');
      await profiles.switchToGuest();
      expect(profiles.addAsksWhose, isFalse, reason: 'there is no one to call it another of');
      expect(asks(profiles)['alex'], isTrue);
      await c.read(databaseSessionProvider)!.close();
    });

    test('from guest data, a second person whose account is signed out cannot say Mine and become the first', () async {
      final (manager, c, profiles) = await computer();
      await signIn(c, profiles, 'alex', hosts: ['alex-host']);
      await profiles.nextSignInIs(mine: false);
      await signIn(c, profiles, 'sam', hosts: ['sam-host']);
      await profiles.lockAfterSignOut();
      if (!profiles.guestDataOnScreen) await profiles.switchToGuest();
      expect(manager.list.byUid('sam')!.state, isNot(ProfileState.open));
      expect(asks(profiles), {'alex': true, 'sam': true});
      expect(profiles.addAsksWhose, isFalse, reason: 'two people have accounts here, one of them signed out');

      // Told Mine all the same (the question shown by a mistake), Sam signs in again.
      await profiles.nextSignInIs(mine: true);
      await signIn(c, profiles, 'sam');
      expect(manager.list.byUid('sam')!.sameOwnerAs(manager.list.byUid('alex')!), isFalse);
      expect(asks(profiles)['alex'], isTrue, reason: "Alex's account asks for Alex's own sign-in");
      await c.read(databaseSessionProvider)!.close();
    });

    // Found in a review: only the account list asked
    // for the sign-in; a switch itself opened any account still signed in here.
    test("a switch never opens someone else's account, from another person's or from guest data: it takes its own sign-in", () async {
      final (manager, c, profiles) = await twoAccounts();
      final alex = idOf(manager, 'alex');
      final sam = idOf(manager, 'sam');
      Matcher refused() => throwsA(isA<ProfileCannotOpen>().having((e) => e.code, 'code', 'profile-signed-in-long-ago'));
      await expectLater(profiles.switchTo(alex), refused());
      expect(manager.currentEntry!.id, sam, reason: 'Sam stays where Sam was');
      expect(await shown(c), ['sam-host']);

      await profiles.switchToGuest();
      await expectLater(profiles.switchTo(alex), refused());
      await expectLater(profiles.switchTo(sam), refused());
      expect(profiles.guestDataOnScreen, isTrue);

      // Alex's own sign-in opens it.
      await signIn(c, profiles, 'alex');
      expect(manager.currentEntry!.id, alex);
      expect(await shown(c), ['alex-host']);
      await c.read(databaseSessionProvider)!.close();
    });

    // Found in a review: from guest data the people
    // were counted as the list stood, so the second person's removing their own account
    // made the computer the first's alone again.
    test("a second person who removes their own account leaves the computer two people's: from guest data the first's asks, stays, and is no one else's to claim", () async {
      final (manager, c, profiles) = await twoAccounts();
      final alex = idOf(manager, 'alex');
      expect(manager.currentEntry!.uid, 'sam');
      // Sam removes Sam's own account from the screen it is on: one confirmation.
      expect(await profiles.removeFromComputer(idOf(manager, 'sam')), isTrue);
      expect(profiles.guestDataOnScreen, isTrue);
      expect(manager.list.accounts.map((a) => a.uid), ['alex'], reason: "only Alex's is here now");

      final deletes = List.of(world.cloud.deletes);
      final account = profiles.accountsHere.single;
      expect(account.needsSignIn, isTrue, reason: "Alex's account asks for Alex's sign-in");
      expect(account.someoneElses, isTrue);
      await expectLater(
        profiles.removeFromComputer(alex),
        throwsA(isA<ProfileCannotOpen>().having((e) => e.code, 'code', 'profile-signed-in-long-ago')),
      );
      expect(manager.list.byId(alex)!.state, ProfileState.open, reason: "nothing of Alex's went");
      expect(world.cloud.deletes, deletes, reason: "Alex's copy at ZestSSH Cloud stays");

      // Sam signs in again, saying Mine all the same: nobody's but Sam's own.
      expect(profiles.addAsksWhose, isFalse, reason: 'there is no one person here to call it another of');
      await profiles.nextSignInIs(mine: true);
      await signIn(c, profiles, 'sam');
      expect(manager.list.byUid('sam')!.sameOwnerAs(manager.list.byId(alex)!), isFalse);
      expect(profiles.accountsHere.singleWhere((a) => a.id == alex).needsSignIn, isTrue);
      await c.read(databaseSessionProvider)!.close();
    });

    test('that this computer had two people is kept in the list across a start, and only Everything forgets it', () async {
      final (manager, c, profiles) = await twoAccounts();
      await profiles.removeFromComputer(idOf(manager, 'sam'));
      expect(world.device.kept[ProfileList.name], contains('"shared":true'));
      await c.read(databaseSessionProvider)!.close();
      Profiles.debugReset();

      final m2 = world.launch();
      await m2.start();
      final guest = await m2.openCurrent();
      SecretSeal.openTree = guest;
      final c2 = app(guest);
      final p2 = c2.read(profileControllerProvider);
      expect(p2.guestDataOnScreen, isTrue);
      expect(p2.accountsHere.single.needsSignIn, isTrue, reason: 'read from the list at the next start');

      // Alex removes Alex's own, from Alex's screen: no account is here, and it is still said.
      await signIn(c2, p2, 'alex');
      await p2.removeFromComputer(m2.list.byUid('alex')!.id);
      expect(m2.list.ofSomeone, isEmpty);
      expect(m2.list.shared, isTrue);
      await p2.wipeEverything();
      expect(m2.list.shared, isFalse);
      expect(world.device.kept[ProfileList.name], isNot(contains('"shared"')));
      await signIn(c2, p2, 'alex');
      await p2.switchToGuest();
      expect(p2.accountsHere.single.needsSignIn, isFalse, reason: "one person's again, after everything went");
      await c2.read(databaseSessionProvider)!.close();
    });

    test('from guest data with one person here, Mine still makes a sign-in that person\'s', () async {
      final (manager, c, profiles) = await computer();
      await signIn(c, profiles, 'alex');
      await profiles.switchToGuest();
      expect(profiles.addAsksWhose, isTrue);
      await profiles.nextSignInIs(mine: true);
      await signIn(c, profiles, 'alex-work');
      expect(manager.list.byUid('alex-work')!.sameOwnerAs(manager.list.byUid('alex')!), isTrue);
      expect(asks(profiles)['alex'], isFalse);
      await c.read(databaseSessionProvider)!.close();
    });

    test('what was said holds through a Try again: a sign-in that could not open, and then does', () async {
      final (manager, c, profiles) = await computer();
      await signIn(c, profiles, 'alex');
      final alex = manager.list.byUid('alex')!;
      await profiles.nextSignInIs(mine: true);
      world.cloud.down = false;
      // The account is known here and signed out; ZestSSH Cloud cannot be reached at first.
      manager.list.put(ProfileEntry(id: newProfileId(), uid: 'alex-work', label: 'w@example.com', state: ProfileState.locked));
      await manager.copies.settle(
        profile: ActiveProfile(id: manager.list.byUid('alex-work')!.id, dir: Directory(world.root.path)),
        hex: 'aa' * 32,
        seal: await SecretSeal.forProfile(c.read(databaseSessionProvider)!),
        bearer: 'b',
        api: world.cloud,
      );
      world.cloud.down = true;
      await expectLater(
        profiles.openForAccount(uid: 'alex-work', label: 'w@example.com', bearer: 'b'),
        throwsA(isA<ProfileCannotOpen>().having((e) => e.code, 'code', 'profile-offline')),
      );
      world.cloud.down = false;
      await signIn(c, profiles, 'sam');
      expect(manager.list.byUid('sam')!.person, manager.list.byId(alex.id)!.person, reason: 'the answer waited for its sign-in');
      profiles.forgetNextSignIn(await profiles.nextSignInIs(mine: false));
      await c.read(databaseSessionProvider)!.close();
    });

    test('a sign-in that does not come takes what was said with it', () async {
      final (manager, c, profiles) = await computer();
      await signIn(c, profiles, 'alex');
      profiles.forgetNextSignIn(await profiles.nextSignInIs(mine: true));
      await signIn(c, profiles, 'sam');
      expect(manager.list.byUid('sam')!.person, isNull);
      expect(asks(profiles)['alex'], isTrue);
      await c.read(databaseSessionProvider)!.close();
    });
  });

  group('five accounts', () {
    void fill(ProfileManager manager, int n, {ProfileState state = ProfileState.locked}) {
      for (var i = 0; i < n; i++) {
        manager.list.put(ProfileEntry(id: newProfileId(), uid: 'filler-$i', label: 'f$i@example.com', state: state));
      }
    }

    test('a sixth makes nothing: no folder, no entry, and the words say how to remove one, with a code', () async {
      final (manager, c, profiles) = await computer();
      fill(manager, 5);
      final before = manager.list.entries.length;
      final folders = ProfilePaths.root(world.base).listSync().length;
      expect(profiles.roomForAnotherAccount, isFalse);

      await expectLater(
        profiles.openForAccount(uid: 'sixth', label: 's@example.com', bearer: 'b'),
        throwsA(isA<ProfileCannotOpen>().having((e) => e.code, 'code', 'profile-too-many-accounts')),
      );
      expect(manager.list.entries, hasLength(before));
      expect(ProfilePaths.root(world.base).listSync(), hasLength(folders));
      expect(manager.currentEntry!.uid, isNull);

      final l10n = AppLocalizationsEn();
      final words = profileCannotOpenWords(l10n, const ProfileCannotOpen('profile-too-many-accounts'));
      expect(words, contains(l10n.accountRemoveAction));
      expect(words, endsWith('(${ErrorCodes.tooManyAccounts.code})'));
      await c.read(databaseSessionProvider)!.close();
    });

    test('guest data does not count, nor one that can never open, and a known account still opens at the limit', () async {
      final (manager, c, profiles) = await computer();
      fill(manager, 4);
      manager.list.put(ProfileEntry(id: newProfileId(), uid: 'gone-for-good', state: ProfileState.lost));
      expect(profiles.roomForAnotherAccount, isTrue);
      await signIn(c, profiles, 'alex');
      expect(profiles.roomForAnotherAccount, isFalse, reason: 'five now, with guest data beside them');
      await profiles.switchToGuest();
      await signIn(c, profiles, 'alex');
      expect(manager.currentEntry!.uid, 'alex');
      await c.read(databaseSessionProvider)!.close();
    });
  });

  group('Remove from this computer', () {
    bool folderThere(String id) => Directory(p.join(ProfilePaths.root(world.base).path, id)).existsSync();

    test('a signed-out account: its folder and keys go, and its copy stays at ZestSSH Cloud, with no session to delete it', () async {
      final (manager, c, profiles) = await twoOfMine();
      final alex = idOf(manager, 'alex');
      await profiles.switchTo(alex);
      final copies = Map.of(world.cloud.held);
      await profiles.lockAfterSignOut();
      await profiles.openForAccount(uid: 'sam', label: 'sam@example.com', bearer: 'b');
      await profiles.sessionKept();
      expect(manager.list.byId(alex)!.state, ProfileState.locked);

      expect(await profiles.removeFromComputer(alex), isTrue);

      expect(manager.list.byId(alex), isNull);
      expect(folderThere(alex), isFalse);
      expect(world.rawNames(alex), isEmpty);
      expect(world.cloud.deletes, isEmpty);
      expect(world.cloud.held.keys, containsAll(copies.keys));
      expect(ended, isEmpty);
      expect(manager.currentEntry!.uid, 'sam', reason: 'what is on screen is untouched');
      expect(await hostsOf(c.read(databaseSessionProvider)!), ['sam-host']);
      await c.read(databaseSessionProvider)!.close();
    });

    test('one signed in behind: its session ends and its copy goes at ZestSSH Cloud, as that account', () async {
      final (manager, c, profiles) = await twoOfMine();
      final alex = idOf(manager, 'alex');
      final copy = await manager.copies.confirmed(alex);
      expect(copy, isNotNull);

      expect(await profiles.removeFromComputer(alex), isTrue);

      expect(world.cloud.deletes, [copy!.id]);
      // As that account, not with the session of the one on screen.
      expect(world.cloud.deletesOnScreen, [false]);
      expect(ended, ['session-of-alex']);
      expect(manager.list.byId(alex), isNull);
      expect(folderThere(alex), isFalse);
      await c.read(databaseSessionProvider)!.close();
    });

    test('ZestSSH Cloud down: it goes from this computer all the same', () async {
      final (manager, c, profiles) = await twoOfMine();
      final alex = idOf(manager, 'alex');
      world.cloud.down = true;
      ProfileController.endSession = (_) => throw const SocketException('played: no route');
      expect(await profiles.removeFromComputer(alex), isTrue);
      expect(manager.list.byId(alex), isNull);
      await c.read(databaseSessionProvider)!.close();
    });

    test('the one on screen: guest data opens, it goes, and the other account stays signed in', () async {
      final (manager, c, profiles) = await twoAccounts();
      final sam = idOf(manager, 'sam');
      expect(await profiles.removeFromComputer(sam), isTrue);
      expect(manager.currentEntry!.uid, isNull);
      expect(c.read(currentUserProvider), isNull);
      expect(manager.list.byId(sam), isNull);
      expect(folderThere(sam), isFalse);
      expect(ended, ['session-of-sam']);
      expect(manager.list.byUid('alex')!.state, ProfileState.open);
      await c.read(databaseSessionProvider)!.close();
    });

    test("someone else's account goes only after its own sign-in, from the screen it is on then", () async {
      final (manager, c, profiles) = await twoAccounts();
      final alex = idOf(manager, 'alex');
      expect(profiles.accountsHere.singleWhere((a) => a.entry.uid == 'alex').someoneElses, isTrue);
      await expectLater(
        profiles.removeFromComputer(alex),
        throwsA(isA<ProfileCannotOpen>().having((e) => e.code, 'code', 'profile-signed-in-long-ago')),
      );
      expect(manager.list.byId(alex), isNotNull);
      expect(folderThere(alex), isTrue, reason: "nothing of Alex's went");
      expect(ended, isEmpty);

      // Alex signs in: on screen, the account is Alex's to remove.
      await signIn(c, profiles, 'alex');
      expect(manager.currentEntry!.uid, 'alex');
      expect(await profiles.removeFromComputer(alex), isTrue);
      expect(manager.list.byId(alex), isNull);
      expect(folderThere(alex), isFalse);
      await c.read(databaseSessionProvider)!.close();
    });

    test('from guest data, with two people here, neither account goes without its sign-in', () async {
      final (manager, c, profiles) = await twoAccounts();
      await profiles.switchToGuest();
      for (final uid in ['alex', 'sam']) {
        expect(profiles.accountsHere.singleWhere((a) => a.entry.uid == uid).someoneElses, isTrue);
        await expectLater(profiles.removeFromComputer(idOf(manager, uid)), throwsA(isA<ProfileCannotOpen>()));
      }
      expect(manager.list.accounts, hasLength(2));
      await c.read(databaseSessionProvider)!.close();
    });

    test('from guest data, with one person here, their account goes as before', () async {
      final (manager, c, profiles) = await twoOfMine();
      await profiles.switchToGuest();
      expect(profiles.accountsHere.every((a) => !a.someoneElses), isTrue, reason: 'one person here');
      expect(await profiles.removeFromComputer(idOf(manager, 'alex')), isTrue);
      expect(manager.list.byUid('alex'), isNull);
      await c.read(databaseSessionProvider)!.close();
    });

    // Found in a review: Everything took every other
    // person's profile with no sign-in of theirs, from guest data or another's account.
    test("Everything is refused, with nothing gone, where it would take someone else's account", () async {
      final (manager, c, profiles) = await twoAccounts();
      final alex = idOf(manager, 'alex');
      final sam = idOf(manager, 'sam');
      expect(profiles.mayDeleteEverything, isFalse, reason: "from Sam's account, Alex's is here");
      Matcher refused() => throwsA(isA<ProfileCannotOpen>().having((e) => e.code, 'code', 'profile-signed-in-long-ago'));
      await expectLater(deleteAllLocalData(c.read, everything: true, targets: const WipeTargets()), refused());
      expect(manager.currentEntry!.id, sam, reason: "Sam's own is not wiped either: nothing went");
      expect(await hostsOf(c.read(databaseSessionProvider)!), ['sam-host']);

      await profiles.switchToGuest();
      expect(profiles.mayDeleteEverything, isFalse);
      await expectLater(profiles.wipeEverything(), refused());
      await expectLater(wipeThisDevice(c.read, everything: true, targets: const WipeTargets()), refused());
      for (final id in [alex, sam]) {
        expect(manager.list.byId(id)!.state, ProfileState.open);
        expect(folderThere(id), isTrue);
      }
      // Guest data's own wipe is as before.
      await deleteAllLocalData(c.read, targets: const WipeTargets());
      expect(manager.list.byId(alex), isNotNull);
      await c.read(databaseSessionProvider)!.close();
    });

    test("Everything goes where every account here is the person's own, from guest data or their account", () async {
      final (manager, c, profiles) = await twoOfMine();
      expect(profiles.mayDeleteEverything, isTrue);
      await profiles.switchToGuest();
      expect(profiles.mayDeleteEverything, isTrue);
      await deleteAllLocalData(c.read, everything: true, targets: const WipeTargets());
      expect(manager.list.ofSomeone, isEmpty);
      await c.read(databaseSessionProvider)!.close();
    });

    test('guest data is not an account to remove', () async {
      final (manager, c, profiles) = await computer();
      final guest = manager.currentEntry!.id;
      expect(await profiles.removeFromComputer(guest), isTrue);
      expect(manager.list.byId(guest), isNotNull);
      await c.read(databaseSessionProvider)!.close();
    });
  });

  // Found in a security review: Put back opened an
  // account's data set aside at the next start, with its kept key, for whoever asked.
  group("data set aside is its own account's to put back or delete", () {
    File putBackFile() => File(p.join(ProfilePaths.root(world.base).path, 'put_back_v1'));

    /// [uid]'s profile as a start leaves one that did not open: set aside in the list.
    Future<String> setAside(ProfileManager manager, String uid) async {
      final entry = manager.list.byUid(uid)!;
      manager.list.put(entry.copyWith(state: ProfileState.setAside));
      await manager.list.write(world.device);
      return entry.id;
    }

    test("from someone else's account it is not said, not put back and not deleted; its own account can", () async {
      final (manager, c, profiles) = await twoAccounts();
      final alex = await setAside(manager, 'alex');
      expect(manager.currentEntry!.uid, 'sam');
      expect(await profiles.setAsideHere(), isFalse, reason: "Alex's, not Sam's to be told of");
      await profiles.askPutBack();
      expect(putBackFile().existsSync(), isFalse, reason: 'nothing of it opens at the next start');
      await profiles.deleteSetAside();
      expect(manager.list.byId(alex)!.state, ProfileState.setAside, reason: 'nothing of it went');

      // Alex signs in again (a new profile of Alex's): Alex is told, and puts it back.
      await signIn(c, profiles, 'alex');
      expect(manager.currentEntry!.uid, 'alex');
      expect(await profiles.setAsideHere(), isTrue, reason: "Alex's own account is told");
      await profiles.askPutBack();
      expect(putBackFile().readAsStringSync().trim(), alex);
      await c.read(databaseSessionProvider)!.close();
    });

    test("guest data set aside is anyone's here, as before; from guest data on a computer with one person's accounts, theirs too", () async {
      final (manager, c, profiles) = await twoOfMine();
      final alex = await setAside(manager, 'alex');
      expect(manager.currentEntry!.uid, 'sam');
      expect(await profiles.setAsideHere(), isTrue, reason: "Sam's and Alex's are one person's");
      await profiles.switchToGuest();
      expect(await profiles.setAsideHere(), isTrue);
      await profiles.askPutBack();
      expect(putBackFile().readAsStringSync().trim(), alex);
      await c.read(databaseSessionProvider)!.close();
    });

    test("from guest data on a computer that has had two people's accounts, only guest data's is anyone's", () async {
      final (manager, c, profiles) = await twoAccounts();
      await setAside(manager, 'alex');
      await profiles.removeFromComputer(idOf(manager, 'sam'));
      expect(profiles.guestDataOnScreen, isTrue);
      expect(manager.list.accounts, isEmpty, reason: "Alex's set aside, Sam's gone: no account is listed");
      expect(await profiles.setAsideHere(), isFalse, reason: "Alex's is Alex's");
      manager.list.put(ProfileEntry(id: newProfileId(), state: ProfileState.setAside));
      expect(await profiles.setAsideHere(), isTrue, reason: "guest data's is anyone's");
      await c.read(databaseSessionProvider)!.close();
    });

    // Found in a review: an account set aside was no
    // account in the people count, so from guest data the computer counted one person (Sam),
    // and Alex's data was told, put back, and opened at the next start with no sign-in.
    test("from guest data at the next start, another person's data set aside is not told, put back or deleted", () async {
      final (manager, c, profiles) = await twoAccounts();
      final alex = idOf(manager, 'alex');
      // Alex's data is the one that did not open after the PIN, and was set aside.
      await signIn(c, profiles, 'alex');
      expect(manager.currentEntry!.id, alex);
      await c.read(databaseSessionProvider)!.close();
      await manager.setAsideCurrent();
      expect(manager.list.byId(alex)!.state, ProfileState.setAside);
      Profiles.debugReset();

      final m2 = world.launch();
      await m2.start();
      final guest = await m2.openCurrent();
      SecretSeal.openTree = guest;
      final c2 = app(guest);
      final p2 = c2.read(profileControllerProvider);
      expect(m2.currentEntry!.uid, isNull);
      expect(m2.list.byUid('sam')!.state, ProfileState.open);
      expect(m2.list.peopleHere, 2, reason: 'Alex set aside is still a person here');
      expect(p2.accountsHere.single.needsSignIn, isTrue, reason: "Sam's asks from guest data, with Alex's here");
      expect(await p2.setAsideHere(), isFalse);
      await p2.askPutBack();
      expect(putBackFile().existsSync(), isFalse, reason: 'nothing of it opens at the next start');
      await p2.deleteSetAside();
      expect(m2.list.byId(alex)!.state, ProfileState.setAside, reason: 'nothing of it went');
      await guest.close();
    });
  });

  group('the list', () {
    test('says each account as it stands, and one that can never open as such; guest data set aside is reached', () async {
      final (manager, c, profiles) = await twoAccounts();
      final lost = ProfileEntry(id: newProfileId(), uid: 'gone-for-good', label: 'g@example.com', state: ProfileState.lost);
      manager.list.put(lost);
      final accounts = profiles.accountsHere;
      expect(accounts.singleWhere((a) => a.entry.uid == 'sam').inUse, isTrue);
      expect(accounts.singleWhere((a) => a.entry.uid == 'alex').inUse, isFalse);
      expect(accounts.singleWhere((a) => a.id == lost.id).lost, isTrue);
      expect(profiles.guestDataOnScreen, isFalse);
      await c.read(databaseSessionProvider)!.close();
    });

    test('guest data set aside comes back in place of what is guest data, which is set aside in turn', () async {
      final (manager, c, profiles) = await computer();
      final first = manager.currentEntry!.id;
      await addHost(c.read(databaseSessionProvider)!, 'first-guest-host');
      await signIn(c, profiles, 'alex');
      // The account is deleted and its data kept as guest data, as the deleting flow does.
      await profiles.accountGone();
      await profiles.keepAsGuest();
      final now = manager.currentEntry!.id;
      expect(manager.list.keptGuestData.single.id, first);

      await profiles.switchTo(first);

      expect(manager.currentEntry!.id, first);
      expect(manager.list.guest!.id, first);
      expect(manager.list.keptGuestData.single.id, now);
      expect(await hostsOf(c.read(databaseSessionProvider)!), ['first-guest-host']);
      await c.read(databaseSessionProvider)!.close();
    });

    test('a phone lists nothing and does nothing', () async {
      Profiles.debugReset();
      ProfileManager.instance = null;
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final profiles = c.read(profileControllerProvider);
      expect(profiles.accountsHere, isEmpty);
      expect(profiles.guestDataOnScreen, isFalse);
      await profiles.switchTo('anything');
      await profiles.switchToGuest();
      expect(await profiles.removeFromComputer('anything'), isTrue);
    });
  });

  group('the session of another account', () {
    test('ends quietly: an answer about it is never taken for the one on screen being signed out', () async {
      final signalled = sessionRevokedSignal.value;
      final deleted = <String>[];
      final client = MockClient((r) async {
        if (r.method == 'GET') return http.Response('{"id":"s-1"}', 200);
        deleted.add(r.url.path);
        return http.Response('{"code":"session-revoked"}', 401);
      });
      final api = DeviceSessionsApi(bearer: () async => 'old', client: client, baseUrl: 'http://played.invalid/v1');
      await api.endOwnSession();
      expect(deleted, ['/v1/sessions/s-1']);
      expect(sessionRevokedSignal.value, signalled);

      final gone = DeviceSessionsApi(
        bearer: () async => 'old',
        client: MockClient((_) async => http.Response('{"code":"session-revoked"}', 401)),
        baseUrl: 'http://played.invalid/v1',
      );
      await gone.endOwnSession();
      expect(sessionRevokedSignal.value, signalled);
    });
  });

  group('the app root', () {
    test('automation answers again after a change of profile: nothing else builds it anew', () {
      final app = File('lib/app.dart').readAsStringSync().replaceAll('\r\n', '\n');
      final opened = app.substring(app.indexOf('  void _onDbOpened() {'), app.indexOf('  Future<void> _afterProfileOpened() async {'));
      expect(opened, contains('ref.read(automationProvider);'));
    });

    test('its start restores the session the way a switch does, from one place', () {
      final app = File('lib/app.dart').readAsStringSync();
      expect(app, contains('keptDesktopSession(storage)'));
      final controller = File('lib/providers/profile_providers.dart').readAsStringSync();
      expect(controller, contains('keptDesktopSession(storage)'));
    });
  });

  group('a sign-out asks ZestSSH Cloud first whether it still holds the locked copy',
      () {
    // The copy was confirmed once, at the sign-in, and the lock trusted that alone:
    // deleted at ZestSSH Cloud since (under Locked copies on your computers, or with
    // the account), the sign-out dropped the only key to this computer's data.
    Future<(ProfileManager, ProviderContainer, ProfileController, String)> alexSignedIn() async {
      final (manager, c, profiles) = await computer();
      await signIn(c, profiles, 'alex', hosts: ['alex-host']);
      expect(world.cloud.held, hasLength(1), reason: 'its copy is confirmed at ZestSSH Cloud');
      return (manager, c, profiles, idOf(manager, 'alex'));
    }

    bool keyHere(String id) => world.device.kept.containsKey(ProfileVault.plainName(id));

    // What the notice after the sign-out says, if one was shown ("Your data is
    // hidden, not locked").
    final en = AppLocalizationsEn();
    String? hiddenSays(ProviderContainer c) => c
        .read(notificationCenterProvider)
        .history
        .where((n) => n.title == en.profileHiddenTitle)
        .map((n) => n.body)
        .lastOrNull;
    String said(String body) => ErrorCodes.withCode(body, ErrorCodes.profileHiddenNotLocked);

    test('it holds it: the sign-out locks, as ever', () async {
      final (manager, c, _, alex) = await alexSignedIn();
      await signOutAccountWith(c.read);
      expect(manager.list.byId(alex)!.state, ProfileState.locked);
      expect(keyHere(alex), isFalse);
      expect(hiddenSays(c), isNull);
      await c.read(databaseSessionProvider)!.close();
    });

    test('the copy was deleted there: the data is only hidden, its key kept, and the next sign-in opens it and '
        'locks it with a new copy', () async {
      final (manager, c, profiles, alex) = await alexSignedIn();
      world.cloud.held.clear();
      await signOutAccountWith(c.read);
      expect(manager.list.byId(alex)!.state, ProfileState.hidden);
      expect(keyHere(alex), isTrue, reason: "the only key to this computer's data was dropped");
      expect(world.device.kept['${KeychainPrefix.of(alex)}${KeychainNames.lockedCopy}'], isNull,
          reason: 'the copy ZestSSH Cloud no longer holds opens nothing, and is forgotten');
      expect(hiddenSays(c), said(en.profileHiddenCopyGoneBody));

      await signIn(c, profiles, 'alex');
      expect(idOf(manager, 'alex'), alex, reason: 'a new, empty profile');
      expect(await shown(c), ['alex-host']);
      expect(world.cloud.held, hasLength(1), reason: 'a new copy');
      expect(world.device.kept['${KeychainPrefix.of(alex)}${KeychainNames.lockedCopy}'], isNotNull);
      await c.read(databaseSessionProvider)!.close();
    });

    test('the account was deleted there: its data stays here as guest data', () async {
      final (manager, c, _, alex) = await alexSignedIn();
      world.cloud.accountGone = true;
      await signOutAccountWith(c.read);
      expect(manager.currentEntry!.id, alex);
      expect(manager.currentEntry!.uid, isNull, reason: 'guest data now');
      expect(manager.currentEntry!.state, ProfileState.open);
      expect(keyHere(alex), isTrue);
      expect(await shown(c), ['alex-host']);
      await c.read(databaseSessionProvider)!.close();
    });

    test('it cannot be asked: the data is only hidden, its key and its copy kept', () async {
      final (manager, c, profiles, alex) = await alexSignedIn();
      final copy = world.device.kept['${KeychainPrefix.of(alex)}${KeychainNames.lockedCopy}'];
      world.cloud.down = true;
      await signOutAccountWith(c.read);
      expect(manager.list.byId(alex)!.state, ProfileState.hidden);
      expect(keyHere(alex), isTrue);
      expect(world.device.kept['${KeychainPrefix.of(alex)}${KeychainNames.lockedCopy}'], copy);
      // What happened, said: ZestSSH Cloud was not reached to ask, so the data
      // was not locked. It once said the secret never got there (in
      // 3.3), which is the next case, not this one.
      expect(hiddenSays(c), said(en.profileHiddenUnreachableBody));

      world.cloud.down = false;
      await signIn(c, profiles, 'alex');
      expect(idOf(manager, 'alex'), alex);
      expect(await shown(c), ['alex-host']);
      await c.read(databaseSessionProvider)!.close();
    });

    test('a secret that never reached ZestSSH Cloud: the data is only hidden, and the notice says that', () async {
      final (manager, c, profiles) = await computer();
      world.cloud.down = true;
      await signIn(c, profiles, 'alex', hosts: ['alex-host']);
      final alex = idOf(manager, 'alex');
      expect(await manager.copies.confirmed(alex), isNull, reason: 'its copy never reached ZestSSH Cloud');
      world.cloud.down = false;
      await signOutAccountWith(c.read);
      expect(manager.list.byId(alex)!.state, ProfileState.hidden);
      expect(keyHere(alex), isTrue);
      expect(hiddenSays(c), said(en.profileHiddenBody));
      await c.read(databaseSessionProvider)!.close();
    });

    test('signed out from elsewhere, with no session left to ask with: it locks on the copy confirmed here', () async {
      final (manager, c, _, alex) = await alexSignedIn();
      await signOutAccountWith(c.read, signedOutElsewhere: true);
      expect(manager.list.byId(alex)!.state, ProfileState.locked);
      expect(keyHere(alex), isFalse);
      await c.read(databaseSessionProvider)!.close();
    });
  });

  group('what lives outside the app state', () {
    // Every mutable static and top-level store in lib, each either forgotten at a change
    // of profile (the call that does) or holding nothing of a person. One that is new
    // fails here until it is put in one or the other.
    const forgotten = <String, String>{
      'features/orchards/activity/activity_notes.dart _lastReveal': 'forgetLastReveals',
      'features/orchards/member_picture.dart _pictures': 'forgetMemberPictures',
      'features/orchards/member_picture.dart _noPictureAt': 'forgetMemberPictures',
      'features/orchards/orchard_unwatched.dart _unwatchedNotYet': 'forgetUnwatchedNotYet',
      'features/orchards/sessionlogs/team_session_logs.dart _writers': 'TeamSessionLogs.reset',
      'features/orchards/sessionlogs/team_session_logs.dart _early': 'TeamSessionLogs.reset',
      'features/orchards/sessionlogs/team_session_logs.dart _secrets': 'TeamSessionLogs.reset',
      'features/orchards/sessionlogs/team_session_logs.dart _endedStarting': 'TeamSessionLogs.reset',
      'features/orchards/sessionlogs/team_session_logs.dart logged': 'TeamSessionLogs.reset',
      'features/orchards/sessionlogs/team_session_logs.dart waiting': 'TeamSessionLogs.reset',
      'features/orchards/sessionlogs/team_session_logs.dart _following': 'TeamSessionLogs.reset',
      'features/orchards/watch/session_watch.dart _watches': 'SessionWatches.reset',
      'features/orchards/watch/session_watch.dart active': 'SessionWatches.reset',
      'features/sharing/session_shares.dart _hosts': 'SessionShares.stopAll',
      'features/sharing/session_shares.dart _listeners': 'SessionShares.stopAll',
      'features/sharing/session_shares.dart _names': 'SessionShares.stopAll',
      'features/sharing/session_shares.dart active': 'SessionShares.stopAll',
      'features/sharing/share_providers.dart _views': 'ShareViews.closeAll',
      'features/sharing/share_providers.dart _shares': 'ShareViews.closeAll',
      'features/sharing/share_providers.dart active': 'ShareViews.closeAll',
      'features/hosts/connect_link.dart quickConnectLinkText': 'quickConnectLinkText.value',
      'features/hosts/phone/phone_hosts_view.dart phoneGroupPickWanted': 'phoneGroupPickWanted.value',
      'providers/purchase_providers.dart _last': 'TeamPremium.forget',
      'providers/purchase_providers.dart _askedAt': 'TeamPremium.forget',
      'providers/purchase_providers.dart _asking': 'TeamPremium.forget',
      'services/account/device_sessions.dart current': 'DeviceSessionHeader.current',
      'services/deep_link_service.dart _early': 'DeepLinkService.forgetEarly',
      'services/deep_link_service.dart _unreadableWaiting': 'DeepLinkService.forgetEarly',
      'services/deep_link_service.dart _initialLink': 'DeepLinkService.forgetEarly',
      'services/deep_link_service.dart _initialAutomation': 'DeepLinkService.forgetEarly',
      'services/desktop_browser_sign_in.dart _waiting': 'DesktopBrowserSignIn.cancel',
      'services/desktop_browser_sign_in.dart pending': 'DesktopBrowserSignIn.cancel',
      'services/secret_seal.dart _openTree': 'SecretSeal.openTree',
      'services/secret_seal.dart _opened': 'SecretSeal.dropWaiters',
      'services/session_log_service.dart _logs': 'SessionLogService.endAll',
      'services/session_log_service.dart _pathBySession': 'SessionLogService.endAll',
      'services/session_transcript_service.dart _recorders': 'SessionTranscriptService.forgetAll',
      'services/purchase_service.dart lastDiagnostic': 'PurchaseService.lastDiagnostic',
      'services/shortcut_service.dart pendingConnection': 'ShortcutService.pendingConnection',
      'theme/terminal_themes.dart _customThemes': 'TerminalThemes.loadCustomThemes',
      'theme/terminal_themes.dart _customThemeNames': 'TerminalThemes.loadCustomThemes',
      'ui/screens/help/contact_support_screen.dart _draft': 'forgetContactSupportDraft',
      'ui/screens/help/report_issue_screen.dart _drafts': 'forgetReportIssueDrafts',
      'ui/screens/help/support_hub_compose.dart _draft': 'forgetSupportHubDraft',
      'ui/screens/help/support_hub_compose.dart _sendOut': 'forgetSupportHubDraft',
      'ui/screens/home/home_screen.dart manageSectionWanted': 'manageSectionWanted.value',
      'utils/logger.dart _kept': 'AppLogger.forget',
      'utils/report_scrub.dart _hosts': 'ReportScrub.forgetNames',
      'utils/report_scrub.dart _users': 'ReportScrub.forgetNames',
      'utils/secret_clipboard.dart _held': 'SecretClipboard.clear',
      'utils/secret_clipboard.dart _timer': 'SecretClipboard.clear',
      'ui/widgets/zest_a11y.dart _entry': 'forgetAnnouncements',
      'ui/widgets/zest_a11y.dart _gone': 'forgetAnnouncements',
      'ui/widgets/zest_a11y.dart _overlay': 'forgetAnnouncements',
      'ui/widgets/zest_a11y.dart _text': 'forgetAnnouncements',
    };

    test('each is forgotten by a call the change makes, or is said to hold nothing of a person', () {
      final found = _mutableStores();
      final unknown = found.where((f) => !forgotten.containsKey(f) && !_nobodys.contains(f)).toList()..sort();
      expect(unknown, isEmpty, reason: 'Say whether these hold a person\'s data: forget them at a change of profile (forgetWhatLivesOutsideTheAppState), or add them to _nobodys: ${unknown.join("; ")}');
      final gone = [...forgotten.keys, ..._nobodys].where((f) => !found.contains(f)).toList()..sort();
      expect(gone, isEmpty, reason: 'These are no longer there: take them off the lists: ${gone.join("; ")}');
      final source = File('lib/providers/profile_providers.dart').readAsStringSync();
      for (final call in forgotten.values.toSet()) {
        expect(source, contains(call), reason: call);
      }
    });

    // A singleton whose fields hold a person's things passes the scan above, which
    // reads a field's declared type only (found in a security review of 3.4.1: the editor's
    // windows of their own and their tabs, in EditorWindows.instance, outlived a
    // change of profile). Each is named here with the call that forgets it.
    const singletons = <String, String>{
      'ui/screens/editor/editor_windows.dart EditorWindows': 'EditorWindows.instance.closeAll()',
      'services/multi_window_service.dart MultiWindowService': 'MultiWindowService.instance.closeAllWindows()',
      // The remote screens shown in windows of their own (4.0): each window shows a session
      // of the profile, so each goes back to its tab before the sessions end.
      'features/screens/window/screen_windows.dart ScreenWindows': 'ScreenWindows.instance.closeAll()',
    };

    test('each singleton that holds windows or tabs is forgotten by a call the change makes', () {
      final stop = File('lib/providers/profile_providers.dart').readAsStringSync();
      final body = stop.substring(stop.indexOf('Future<void> _stopWhatRuns()'), stop.indexOf('Future<void> _flip('));
      for (final e in singletons.entries) {
        final [path, type] = e.key.split(' ');
        expect(File('lib/$path').readAsStringSync(), contains('static final $type instance'), reason: e.key);
        expect(body, contains(e.value), reason: '${e.value} in _stopWhatRuns');
      }
    });
  });
}

/// Holds nothing of a person, each for a reason of its kind: the app's own machinery,
/// what a test sets, what is kept per database or client object and goes with it, a cache
/// of a fixed computation, or a device's own state.
const _nobodys = <String>{
  // Which build this is (the release or a community build), and the list of error codes: no person's.
  'config/official_identity.dart _official',
  'core/errors/error_codes.dart all',
  // Whether each remote screen session's sound plays: an Expando keyed by the session, holding
  // only on or off and which views want it; it goes with its session, which a change of profile
  // ends.
  'features/screens/view/screen_sound_gate.dart _gates',
  // The remote screen that takes the system keys now (4.1, Windows): one screen's controller, which
  // lets go when its view goes; a change of profile ends the sessions and their views.
  'features/screens/view/screen_key_grab.dart _owner',
  // The conversation with a security key: it holds what one sign-in asks while it runs (a label, the PIN
  // typed for it) and nothing once it ends; a change of profile ends the sessions that could ask.
  'services/fido/fido_signer.dart fidoSigner',
  // How a host name is looked up before plain http goes to it: the system's resolver, or a test's.
  'services/own_network_http.dart ownNetworkLookup',
  'core/data/os_catalog.dart _all',
  'core/data/os_catalog.dart _map',
  'database/daos/known_hosts_dao.dart _preferred',
  'database/database.dart orchardItemTables',
  'features/hosts/widgets/group_tiles.dart hostDragActive',
  'features/networks/pages/network_editor_page.dart _kColorChoices',
  'features/orchards/orchard_session_logs.dart _sessionLogRunNumber',
  'features/orchards/orchard_session_logs.dart _sessionLogStandings',
  'features/orchards/orchard_session_logs.dart _sessionLogWriters',
  'features/orchards/orchard_session_logs.dart _sessionLogSends',
  'features/orchards/record/local_record.dart _kept',
  'features/orchards/rules/crate_offline.dart _contacts',
  // Whether this run of the app was started for a command (zestssh admin): the run's, not a person's.
  'features/orchards/setup/setup_command_host.dart startedForACommand',
  // The lock this run of the app holds while it runs: the process's, not a person's.
  'services/app_instance_lock.dart _held',
  'features/orchards/sync/crate_server.dart newRecordKindsOn',
  'features/orchards/sync/crate_sync_engine.dart _writeLostCache',
  'features/orchards/sync/item_store.dart tablesOfKind',
  'features/orchards/sync/item_store.dart writtenOnlyWhenSet',
  'features/sharing/share_nudges.dart shareInviteNudges',
  'features/orchards/widgets/orchard_rules_view.dart _leaveGuards',
  // The fixed table of named keys (Enter, the arrows, F1 to F24) to X11 keysyms
  // for a remote screen: final only because LogicalKeyboardKey has its own ==, so
  // the map cannot be const; never written, no person's data.
  'features/screens/view/keysyms.dart _named',
  // The size a remote screen's view last had on this device (4.0, RDP's "Resize the remote"): a
  // window's width and height, which the next RDP session starts at. Nothing of a person or a host.
  'features/screens/model/screen_view_size.dart lastFollowed',
  'features/shortcuts/default_bindings.dart defaultShortcutBindings',
  'features/shortcuts/shortcut_key.dart _displayOverrides',
  'l10n/l10n_global.dart _current',
  'main.dart _adminArgs',
  'main.dart _earlyTerminalOutput',
  'main.dart _launchDeepLink',
  'main.dart _popOutLocked',
  'providers/terminal_providers.dart _terminalWordSeparators',
  'providers/theme_providers.dart kFreeAppThemeIds',
  'services/account/device_approval_alerts.dart deviceApprovalNudges',
  'services/account/device_sessions.dart _over',
  'services/account/device_sessions.dart sessionExpiredSignal',
  'services/account/device_sessions.dart sessionRevokedReason',
  'services/account/device_sessions.dart sessionRevokedSignal',
  'services/account/two_step_api.dart securityNudges',
  // (Whether an automatic backup is being made, and when the daily one was
  // last tried on going to the background: the run's, no person's data.)
  'services/auto_backup_service.dart _making',
  'services/auto_backup_service.dart _scheduledTriedOnLeaving',
  'services/auth_service.dart _firebaseAvailable',
  'services/auth_service.dart _firstReport',
  'services/away_for_sign_in.dart _since',
  'services/cloud/cloud_reach.dart currentCloudReach',
  'services/deep_link_service.dart _linkController',
  'services/deep_link_service.dart _unreadableLinks',
  'services/hardware_token/os_agent_key_pair.dart _knownSignatureAlgos',
  'services/hardware_token/os_agent_key_pair.dart _skSignatureAlgos',
  // The copy made before an upgrade, by the path of its database: never another
  // profile's, dropped once that database opens.
  'services/migration_backup_service.dart _madeThisRun',
  'services/notification_service.dart _channelsNamedIn',
  'services/notification_service.dart _initialized',
  'services/notification_service.dart _router',
  // A computer's system notifications (4.0): the plugin, whether this computer's switch is on and the
  // plugin started (the computer's setting, not a person's).
  'services/notification_service.dart _plugin',
  'services/notification_service.dart _computerOn',
  'services/notification_service.dart _computerReady',
  'services/pinned_http_client.dart _cachedClient',
  'services/pinned_http_client.dart onExchange',
  // Whether this platform's native libraries' licences were added to the licences page (once, at
  // start): a flag about the build, nothing of a person.
  'services/platform_licences.dart _registered',
  'services/profiles/active_profile.dart _current',
  'services/profiles/active_profile.dart _on',
  'services/profiles/active_profile.dart provisionalTeams',
  'services/profiles/keychain.dart _profileKeychain',
  'services/profiles/profile_manager.dart instance',
  'services/profiles/profile_preferences.dart instance',
  'services/purchase_service.dart _identityChain',
  'services/purchase_service.dart _initialized',
  'services/purchase_service.dart _lastSeenUid',
  'services/purchase_service.dart strandedAnonymousId',
  'services/server_stats_service.dart _osCache',
  'services/server_stats_service.dart _osInfoCache',
  'services/session_transcript_service.dart lastReadError',
  'services/session_transcript_service.dart lastSaveError',
  'services/secret_seal.dart _cache',
  'services/settings_service.dart _syncedSettingKeysSorted',
  'services/settings_service.dart deviceKeys',
  'services/settings_service.dart keptKeys',
  'services/settings_service.dart profileKeys',
  'services/settings_service.dart resetKeys',
  // What the Store copy did about the copy from zestssh.com at this start, said
  // once when the app is up: the PC's, before any profile opens.
  'services/store_handover_start.dart _notice',
  // And the names of the folders it set aside, said with it: the PC's as well.
  'services/store_handover_start.dart _setAsideSaid',
  'services/sync/zest_server_backend.dart _cachedClientVersion',
  'services/tray_service.dart _instance',
  // Whether the tray icon is up: the computer's, as the tray itself.
  'services/tray_service.dart _ready',
  'services/window_service.dart _instance',
  'services/window_service.dart fullscreen',
  'theme/terminal_themes.dart freeThemeIds',
  // Whether the app's root hears the kind of pointer pressed (4.0, the
  // density): off in tests, a switch of the harness's, no person's data.
  'theme/ui_density.dart enabled',
  'ui/screens/desktop/desktop_shell.dart _padTwins',
  'ui/screens/desktop/widgets/desktop_terminal_area.dart _filesOnlyKeys',
  'ui/screens/desktop/widgets/desktop_terminal_area.dart _sftpDockKeys',
  'ui/screens/desktop/widgets/monitor_table_view.dart _activeOverrideToast',
  'ui/screens/desktop/widgets/settings_inline_view.dart _kSettingsSearchIndex',
  'ui/screens/desktop/widgets/theme_designer_view.dart _accentTokens',
  'ui/screens/desktop/widgets/theme_designer_view.dart _allTokens',
  'ui/screens/desktop/widgets/theme_designer_view.dart _borderTokens',
  'ui/screens/desktop/widgets/theme_designer_view.dart _statusTokens',
  'ui/screens/desktop/widgets/theme_designer_view.dart _surfaceTokens',
  'ui/screens/desktop/widgets/theme_designer_view.dart _textTokens',
  // The editor's encoding tables, made once from constants, and its
  // highlighter's language rules.
  'ui/screens/editor/editor_codec.dart _reverseTables',
  'ui/screens/editor/editor_language.dart modes',
  'ui/screens/help/support_hub_compose.dart _formOnScreen',
  'ui/screens/home/widgets/quick_connect_bar.dart quickConnectFocusWanted',
  'ui/screens/notifications/notifications_screen.dart _permissionRequestedThisSession',
  // The lock screen's doors at the app's root (4.0): which one is mounted, the
  // app's own machinery; no person's data.
  'ui/screens/security/lock_curtain.dart _current',
  'ui/screens/settings/phone_settings_search.dart kPhoneSettingsIndex',
  'ui/screens/settings/widgets/custom_theme_builder.dart _quickSwatches',
  'ui/screens/sftp/sftp_dual_pane_screen.dart _binaryExtensions',
  'ui/screens/sftp/widgets/sftp_file_icon.dart _compoundExtensions',
  'ui/screens/sftp/widgets/sftp_file_icon.dart _extensions',
  'ui/screens/sftp/widgets/sftp_file_icon.dart _specialFilenames',
  'ui/screens/sync/sync_now.dart _running',
  'ui/screens/terminal/hardware_keyboard_use.dart _hardwareOnly',
  'ui/widgets/command_palette.dart _paletteOpen',
  'ui/widgets/top_snackbar.dart _activeMobileToast',
  'ui/widgets/top_snackbar.dart _topToastBars',
  'ui/widgets/zest_color_picker.dart _hueWheel',
  'ui/windows/secondary_window_app.dart mainWindowTheme',
  'utils/error_report.dart app',
  'utils/logger.dart _initialized',
  'utils/pointer_recovery.dart _down',
};

/// The mutable static and top-level stores in lib, as `path name`.
Set<String> _mutableStores() {
  final staticField = RegExp(r'^\s+static\s+(late\s+)?(final\s+)?(.+?)\s+(\w+)\s*(=|;)');
  final topLevel = RegExp(r'^(late\s+)?(final\s+)?(?:([A-Za-z_][\w<>,\s?.()]*?)\s+)?(\w+)\s*(=|;)');
  final holdsThings = RegExp(r'Map<|Set<|List<|<.*>\{|<.*>\[|ValueNotifier|StreamController|Queue|Completer|Expando');
  final immutableType = RegExp(r'^(Color|Duration|TextStyle|RegExp|int|double)\b');
  final found = <String>{};
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final path = entity.path.replaceAll(r'\', '/').substring(4);
    if (path.endsWith('.g.dart') || path.contains('generated/') || path.startsWith('core/data/os_logos')) continue;
    if (path == 'services/app_updater.dart' || path == 'services/desktop_auth_server.dart') continue;
    if (path == 'services/hardware_token/ssh_agent_setup.dart') continue;
    for (final line in entity.readAsLinesSync()) {
      final isStatic = line.startsWith(' ') && line.trimLeft().startsWith('static ');
      if (!isStatic && (line.isEmpty || RegExp(r'^[\s/}@)\]]').hasMatch(line))) continue;
      if (!isStatic && RegExp(r'^(import|export|part|class|enum|abstract|typedef|extension|mixin|const|library|sealed|base)\b').hasMatch(line)) continue;
      final m = (isStatic ? staticField : topLevel).firstMatch(line);
      if (m == null) continue;
      final head = line.split('=').first;
      if (head.contains('(') || line.contains(' get ') || line.contains(' set ')) continue;
      if (line.contains(' const ') && !line.contains('Set<')) continue;
      final type = (m.group(3) ?? '').trim();
      final isFinal = m.group(2) != null || type == 'final' || type.endsWith(' final');
      final name = m.group(4)!;
      if (name.startsWith('debug') || name.startsWith('_debug')) continue;
      if (line.contains('Provider')) continue;
      if (immutableType.hasMatch(type) || RegExp(r'RegExp|Pattern|lookupFunction|AesGcm').hasMatch(line)) continue;
      if (isFinal && !holdsThings.hasMatch(line)) continue;
      found.add('$path $name');
    }
  }
  return found;
}
