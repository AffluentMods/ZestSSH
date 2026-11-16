import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/crate_offline.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/widgets/crate_watched_view.dart';
import 'package:zestssh/features/orchards/widgets/member_dialogs.dart' show crateLevelName;
import 'package:zestssh/features/orchards/widgets/orchard_crates.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/utils/redactor.dart';

import '../../helpers/phone_host_card.dart';

import 'fake_crate_server.dart';
import 'vaults_window_helper.dart';
import 'package:flutter/services.dart';

/// Watched Crates on screen (3.0): owners turn watched sessions on
/// for a Crate after a yes that says what it means, and SFTP and forwarding
/// go off with it; everyone else sees that sessions there are watched; what
/// the Crate allows cannot be changed while it is watched; and a host whose
/// sessions are watched says so before anyone connects.

class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async => dbs.remove(orchardId);

  @override
  Future<List<String>> list() async => dbs.keys.toList();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  final keys = <String, AccountKeys>{};
  late FakeCrateServer server;
  late OrchardService owner;
  late OrchardService alice;
  late String orchardId;
  late String crateId;
  final storages = <_MemoryStorage>[];
  final devices = <OrchardService, ({_MemoryStorage storage, String uid})>{};

  setUpAll(() async {
    for (final uid in ['owner-1', 'alice']) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  tearDown(() async {
    for (final s in storages) {
      for (final db in s.dbs.values) {
        await db.close();
      }
    }
    storages.clear();
  });

  OrchardService onStorage(_MemoryStorage storage, String uid) {
    final service = OrchardService(
      server: server.as(uid),
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: uid, keys: keys[uid]!),
    );
    devices[service] = (storage: storage, uid: uid);
    return service;
  }

  OrchardService serviceFor(String uid) {
    final storage = _MemoryStorage();
    storages.add(storage);
    return onStorage(storage, uid);
  }

  Future<void> sync(OrchardService s) =>
      OrchardSyncCoordinator(service: s, server: s.server, databases: s.databases).syncAll();

  /// Acme with the owner and alice, a member who may use Production.
  Future<void> build(WidgetTester tester) => tester.runAsync(() async {
        server = FakeCrateServer(accountUid: 'owner-1');
        for (final uid in keys.keys) {
          await server.publish(uid, keys[uid]!, email: '$uid@example.com');
        }
        owner = serviceFor('owner-1');
        alice = serviceFor('alice');
        orchardId = await owner.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
        crateId = server.recordOf(orchardId).roles.values.single.crates.keys.single;
        await owner.invite(orchardId, email: 'alice@example.com', role: server.recordOf(orchardId).roles.values.single.id);
        server.acceptAs(orchardId, (await owner.invites(orchardId)).single.id, 'alice');
        await owner.confirmInvite(orchardId, (await owner.invites(orchardId)).single);
        await owner.refresh();
        await alice.refresh();
        await sync(alice);
      });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pump();
      if (i >= 2 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    await tester.pumpAndSettle();
  }

  /// [child] on screen as [as]'s device shows it, with the Orchard as that
  /// device has it now.
  Future<void> pump(WidgetTester tester, OrchardService as, Widget Function(OrchardSummary, CrateSummary) child,
      {List<Override> extra = const [], Locale locale = const Locale('en')}) async {
    final device = devices[as]!;
    as = onStorage(device.storage, device.uid);
    late OrchardSummary summary;
    await tester.runAsync(() async {
      await as.refresh();
      summary = await readOrchardSummary(await as.databases.open(orchardId), orchardId);
    });
    final crate = summary.crates.firstWhere((c) => c.id == crateId);
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final me = device.uid;
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        orchardServiceProvider.overrideWithValue(as),
        orchardDatabasesProvider.overrideWith((ref) => as.databases),
        orchardSummariesProvider.overrideWith((ref) async => [summary]),
        activeOrchardProvider.overrideWithValue(AsyncData(summary)),
        orchardAuthorProvider.overrideWithValue(OrchardAuthorSource(() async => CrateAuthor(uid: me, keys: keys[me]!))),
        connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
        deviceLockProvider.overrideWith((ref) async => (on: true, minutes: 5)),
        currentUserProvider.overrideWithValue(UserProfile(uid: me, email: '$me@example.com')),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
        ...extra,
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: Scaffold(body: SingleChildScrollView(child: child(summary, crate))),
      ),
    ));
    await settle(tester);
  }

  RecordCrate inRecord() => server.recordOf(orchardId).crates[crateId]!;

  testWidgets('owners turn watched sessions on after a yes that says what it means, and SFTP and forwarding go off '
      'with it; a member sees that sessions are watched', (tester) async {
    await build(tester);
    await tester.runAsync(
        () => owner.setCrateAllow(orchardId, crateId, {CrateSwitches.sftp, CrateSwitches.forward}));
    await pump(tester, owner, (o, c) => CrateWatchedLine(orchard: o, crate: c));
    final chip = find.byKey(ValueKey('crate-watched-$crateId'));
    expect(tester.widget<ZestSwitch>(chip).value, isFalse);
    expect(find.text(l10n.crateWatched), findsOneWidget);

    // The question says what it means, what goes off, that everyone is
    // told, and that it is the app that keeps the rule.
    await tester.tap(chip);
    await settle(tester);
    expect(find.text(l10n.crateWatchedOnTitle('Production')), findsOneWidget);
    // A lead and short points (3.0 UI: it was one paragraph).
    final watchedPoints = [
      l10n.vaultUiWatchedOnLead,
      l10n.vaultUiWatchedOnHeld,
      l10n.vaultUiWatchedOnOff,
      l10n.vaultUiWatchedOnAway,
      l10n.vaultUiToldEveryone,
      l10n.vaultUiWatchedOnApp,
    ];
    for (final point in watchedPoints) {
      expect(find.text(point), findsOneWidget, reason: point);
    }
    for (final said in [
      'someone else who manages the vault',
      'Typing is held while nobody watches',
      'SFTP, port forwarding and agent forwarding are switched off',
      // What an outage of ZestSSH Cloud means for it.
      'While ZestSSH Cloud cannot be reached nobody can be asked to watch',
      'everyone else waits',
      'Everyone who can open the vault is told',
      'no machine of ZestSSH\'s own stands between your members and your hosts',
    ]) {
      expect(watchedPoints.join(' '), contains(said));
    }
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect((inRecord().watched, inRecord().allow.length), (false, 2), reason: 'declined: nothing sent');

    await tester.tap(chip);
    await settle(tester);
    await tester.tap(find.text(l10n.crateWatchedTurnOn).last);
    await settle(tester);
    expect(inRecord().watched, isTrue);
    expect(inRecord().allow, isEmpty, reason: 'a watched Crate allows the terminal only');
    await tester.pump(const Duration(seconds: 10));
    await pump(tester, owner, (o, c) => CrateWatchedLine(orchard: o, crate: c));
    expect(tester.widget<ZestSwitch>(chip).value, isTrue);

    // alice, a member, is told they are watched and switches nothing.
    await tester.runAsync(() => sync(alice));
    await pump(tester, alice, (o, c) => CrateWatchedLine(orchard: o, crate: c));
    expect(find.byKey(ValueKey('crate-sessions-watched-$crateId')), findsOneWidget);
    expect(find.text(l10n.crateWatchedOnNote), findsOneWidget);
    expect(chip, findsNothing);

    // Off again, after a yes that says what stays off.
    await pump(tester, owner, (o, c) => CrateWatchedLine(orchard: o, crate: c));
    await tester.tap(chip);
    await settle(tester);
    expect(find.text(l10n.crateWatchedOffTitle('Production')), findsOneWidget);
    expect(find.text(l10n.crateWatchedOffBody), findsOneWidget);
    await tester.tap(find.text(l10n.crateWatchedTurnOff).last);
    await settle(tester);
    expect(inRecord().watched, isFalse);
    expect(inRecord().allow, isEmpty, reason: 'what it allows stays off until someone allows it again');
    await tester.pump(const Duration(seconds: 10));

    // Off, a member is told nothing.
    await tester.runAsync(() => sync(alice));
    await pump(tester, alice, (o, c) => CrateWatchedLine(orchard: o, crate: c));
    expect(find.byKey(ValueKey('crate-sessions-watched-$crateId')), findsNothing);
    expect(chip, findsNothing);
  });

  testWidgets('who connects while ZestSSH Cloud cannot be reached: a watched Crate says it to everyone, and owners '
      'change it after a yes that says what it means', (tester) async {
    await build(tester);
    Widget line(OrchardSummary o, CrateSummary c) => CrateWatchedLine(orchard: o, crate: c);
    final away = find.byKey(ValueKey('crate-unwatched-away-$crateId'));
    final change = find.byKey(ValueKey('crate-unwatched-away-change-$crateId'));
    Finder says(String text) => find.descendant(of: away, matching: find.text(text));

    // Its sessions are not watched: nothing is said of it, to anyone.
    await pump(tester, owner, line);
    expect(away, findsNothing);
    await tester.runAsync(() => owner.setCrateWatched(orchardId, crateId, true));

    // Watched: owners alone, until they say otherwise.
    await pump(tester, owner, line);
    expect(says(l10n.crateUnwatchedAwayOwnersNote), findsOneWidget);
    expect(change, findsOneWidget);
    expect(inRecord().unwatchedAway, isFalse);

    // The question says what it means, what is reported, that a device cut
    // off cannot tell why, and that everyone is told. Declined, nothing is
    // sent.
    await tester.tap(change);
    await settle(tester);
    expect(find.text(l10n.vaultUiAwayOnTitle('Production')), findsOneWidget);
    // A lead and short points (3.0 UI: it was one paragraph of ten lines).
    final awayPoints = [
      l10n.vaultUiAwayOnLead,
      l10n.vaultUiAwayOnRecord,
      l10n.vaultUiAwayOnTrust,
      l10n.vaultUiToldEveryone,
    ];
    for (final point in awayPoints) {
      expect(find.text(point), findsOneWidget, reason: point);
    }
    for (final said in [
      'Nobody can be asked to watch a session while ZestSSH Cloud is unreachable',
      'Owners may then connect with a reason',
      'so may everyone who may connect to this vault',
      "goes into the team's record once the device is back online",
      'The ZestSSH app keeps this rule',
      'cannot tell why a device is cut off',
      'Everyone who can open the vault is told',
    ]) {
      expect(awayPoints.join(' '), contains(said));
    }
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(inRecord().unwatchedAway, isFalse, reason: 'declined: nothing sent');

    await tester.tap(change);
    await settle(tester);
    await tester.tap(find.text(l10n.crateUnwatchedAwayAllow).last);
    await settle(tester);
    expect(inRecord().unwatchedAway, isTrue);
    expect(inRecord().watched, isTrue, reason: 'nothing else of the Crate changed');
    await tester.pump(const Duration(seconds: 10));
    await pump(tester, owner, line);
    expect(says(l10n.crateUnwatchedAwayEveryoneNote), findsOneWidget);
    expect(says(l10n.crateUnwatchedAwayOwnersNote), findsNothing);

    // alice, a member, reads which it is and changes nothing.
    await tester.runAsync(() => sync(alice));
    await pump(tester, alice, line);
    expect(says(l10n.crateUnwatchedAwayEveryoneNote), findsOneWidget);
    expect(change, findsNothing);

    // Owners alone again, after a yes that says what that means.
    await pump(tester, owner, line);
    await tester.tap(change);
    await settle(tester);
    expect(find.text(l10n.vaultUiAwayOffTitle('Production')), findsOneWidget);
    expect(find.text(l10n.vaultUiAwayOffLead), findsOneWidget);
    expect(find.text(l10n.vaultUiToldEveryone), findsOneWidget);
    expect(l10n.vaultUiAwayOffLead, contains('Everyone else waits until someone can be asked to watch'));
    await tester.tap(find.text(l10n.crateUnwatchedAwayOwnersOnly).last);
    await settle(tester);
    expect(inRecord().unwatchedAway, isFalse);
    await tester.pump(const Duration(seconds: 10));
    await tester.runAsync(() => sync(alice));
    await pump(tester, alice, line);
    expect(says(l10n.crateUnwatchedAwayOwnersNote), findsOneWidget);

    // Watching ends: the line goes with it, for everyone.
    await tester.runAsync(() => owner.setCrateWatched(orchardId, crateId, false));
    await pump(tester, owner, line);
    expect(away, findsNothing);
    await tester.runAsync(() => sync(alice));
    await pump(tester, alice, line);
    expect(away, findsNothing);
  });

  testWidgets('the line fits a narrow row in every language, with the way to change it', (tester) async {
    await build(tester);
    await tester.runAsync(() => owner.setCrateWatched(orchardId, crateId, true));
    for (final locale in AppLocalizations.supportedLocales) {
      for (final everyone in [false, true]) {
        await tester.runAsync(() => owner.setCrateUnwatchedAway(orchardId, crateId, everyone));
        await pump(tester, owner, (o, c) => SizedBox(width: 300, child: CrateWatchedLine(orchard: o, crate: c)),
            locale: locale);
        final t = lookupAppLocalizations(locale);
        expect(find.text(everyone ? t.crateUnwatchedAwayEveryoneNote : t.crateUnwatchedAwayOwnersNote), findsOneWidget,
            reason: '$locale');
        expect(find.byKey(ValueKey('crate-unwatched-away-change-$crateId')), findsOneWidget, reason: '$locale');
        expect(tester.takeException(), isNull, reason: '$locale: something does not fit');
        final row = tester.getRect(find.byKey(ValueKey('crate-unwatched-away-$crateId')));
        expect(row.width, lessThanOrEqualTo(300), reason: '$locale');
      }
    }
  });

  testWidgets('what a watched Crate allows is not offered for changing, and the row says why', (tester) async {
    await build(tester);
    await tester.runAsync(() => owner.setCrateAllow(orchardId, crateId, {CrateSwitches.sftp}));
    Widget crates(OrchardSummary o, CrateSummary c) => OrchardCratesView(orchardId: orchardId);
    // What its hosts allow: a switch each (4.0).
    ({bool selected, Object? onSelected}) allow(String what) {
      final s = tester.widget<ZestSwitch>(find.byKey(ValueKey('crate-allow-$crateId-$what')));
      return (selected: s.value, onSelected: s.onChanged);
    }

    await pump(tester, owner, crates);
    expect((allow('sftp').selected, allow('sftp').onSelected != null), (true, true));
    expect(find.byKey(ValueKey('crate-terminal-only-$crateId')), findsNothing);
    expect(find.byKey(ValueKey('crate-watched-$crateId')), findsOneWidget, reason: 'the switch is on the Crate\'s row');

    await tester.runAsync(() => owner.setCrateWatched(orchardId, crateId, true));
    await pump(tester, owner, crates);
    for (final what in ['sftp', 'forward', 'agent']) {
      expect((allow(what).selected, allow(what).onSelected), (false, null), reason: what);
    }
    expect(find.byKey(ValueKey('crate-terminal-only-$crateId')), findsOneWidget);
    expect(find.text(l10n.crateWatchedTerminalOnly), findsOneWidget);
    expect(tester.widget<ZestSwitch>(find.byKey(ValueKey('crate-watched-$crateId'))).value, isTrue);

    // No longer watched: what it allows can be set again.
    await tester.runAsync(() => owner.setCrateWatched(orchardId, crateId, false));
    await pump(tester, owner, crates);
    expect((allow('sftp').selected, allow('sftp').onSelected != null), (false, true));
    expect(find.byKey(ValueKey('crate-terminal-only-$crateId')), findsNothing);
  });

  // The same page, for a Crate that its own offline limit has closed on
  // this device (3.0).
  testWidgets('a Crate its own offline limit has closed on this device says so, and why, in place of what the '
      'account may do in it, and offers none of its settings for changing', (tester) async {
    await build(tester);
    Widget crates(OrchardSummary o, CrateSummary c) => OrchardCratesView(orchardId: orchardId);
    ZestSwitch toggle(String key) => tester.widget<ZestSwitch>(find.byKey(ValueKey(key)));
    // What its hosts allow: a switch each (4.0).
    ({Object? onSelected}) chip(String key) => (onSelected: toggle(key).onChanged);
    final closedLine = find.byKey(ValueKey('crate-closed-$crateId'));
    // Rename is in the vault's menu (4.0): whether the menu offers it.
    Future<bool> renames() async {
      await tester.tap(find.byKey(ValueKey('crate-more-$crateId')));
      await tester.pump(const Duration(milliseconds: 300));
      final offered = find.byKey(ValueKey('crate-rename-$crateId')).evaluate().isNotEmpty;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 300));
      return offered;
    }
    // Certificates are on their tab: whether it offers to set them up.
    Future<bool> certsOffered() async {
      await openVaultTab(tester, crateId, VaultTab.certificates);
      final shown = find.text(l10n.crateCertsSetUp).evaluate().isNotEmpty;
      await openVaultTab(tester, crateId, VaultTab.access);
      return shown;
    }
    final access = find.textContaining(l10n.crateYourAccess(crateLevelName(CrateLevel.manage, l10n)));
    // The device's clock, and when it last reached ZestSSH Cloud.
    var now = 1790000000;
    var last = now;
    await tester.runAsync(() async {
      attachDeviceContact(await owner.databases.open(orchardId),
          DeviceContact(read: () => OrchardContact(lastContact: last, latest: now), now: () => now));
      await owner.setCrateOfflineLimit(orchardId, crateId, 24);
    });
    List<Override> reach(CloudReach how) =>
        [cloudReachStateProvider.overrideWith((ref) => Stream.value(CloudReachState(how)))];

    // Open: what the account may do in it, and its settings to change.
    await pump(tester, owner, crates, extra: reach(CloudReach.answering));
    expect(closedLine, findsNothing);
    expect(access, findsOneWidget);
    expect(find.textContaining(l10n.orchardClosedOfflineShort), findsNothing);
    expect(await renames(), isTrue);
    expect(chip('crate-allow-$crateId-sftp').onSelected, isNotNull);
    expect(toggle('crate-confirm-reveal-$crateId').onChanged, isNotNull);
    final watchedSwitch = find.byKey(ValueKey('crate-watched-$crateId'));
    expect(watchedSwitch, findsOneWidget);
    expect(await certsOffered(), isTrue);

    // A day and a second away: closed, with what opens it again.
    now = last + 24 * 3600 + 1;
    await pump(tester, owner, crates, extra: reach(CloudReach.deviceOffline));
    expect(tester.widget<Text>(closedLine).data, l10n.crateClosedOfflineError('Production'));
    expect(find.textContaining(l10n.orchardClosedOfflineShort), findsOneWidget);
    expect(access, findsNothing, reason: 'it allows nothing just now, and is not said to');
    expect(find.textContaining(l10n.crateLevelCustom), findsNothing);
    expect(await renames(), isFalse);
    for (final what in ['sftp', 'forward', 'agent']) {
      expect(chip('crate-allow-$crateId-$what').onSelected, isNull, reason: what);
    }
    expect(toggle('crate-confirm-reveal-$crateId').onChanged, isNull);
    expect(find.descendant(of: find.byKey(ValueKey('vault-item-$crateId')), matching: find.text('Production')),
        findsOneWidget,
        reason: 'it is still listed, by its name');
    // Nothing of its own to look into or to set up until it is open again.
    expect(watchedSwitch, findsNothing);
    expect(await certsOffered(), isFalse);

    // Where ZestSSH Cloud is what cannot be reached, nobody is sent looking
    // for a fault of their own.
    await pump(tester, owner, crates, extra: reach(CloudReach.notResponding));
    expect(tester.widget<Text>(closedLine).data, l10n.crateClosedOfflineCloud('Production'));

    // Back in contact: as it was.
    last = now;
    await pump(tester, owner, crates, extra: reach(CloudReach.answering));
    expect(closedLine, findsNothing);
    expect(access, findsOneWidget);
    expect(await renames(), isTrue);
    expect(chip('crate-allow-$crateId-sftp').onSelected, isNotNull);
    expect(watchedSwitch, findsOneWidget);
    expect(await certsOffered(), isTrue);
  });

  testWidgets("on a phone, a host's card says its sessions are watched before connecting", (tester) async {
    await build(tester);
    final card = await phoneHostCard(tester, 'web1');
    final needs = await phoneHostCardNeeds(tester);
    List<Override> onScreen() => [
          activeSpaceProvider.overrideWith((ref) => OrchardSpace(orchardId)),
          itemCratesProvider('host').overrideWith((ref) => Stream.value({'web1': crateId})),
          ...needs,
        ];
    final mark = find.byKey(const ValueKey('host-watched-mark-web1'));
    await pump(tester, owner, (o, c) => card, extra: onScreen());
    expect(find.text('Web 1'), findsOneWidget);
    expect(mark, findsNothing, reason: 'off');
    await tester.runAsync(() => owner.setCrateWatched(orchardId, crateId, true));
    await pump(tester, owner, (o, c) => card, extra: onScreen());
    expect(mark, findsOneWidget);
    expect(tester.widget<Tooltip>(find.ancestor(of: mark, matching: find.byType(Tooltip))).message,
        l10n.hostSessionsWatched);
  });

  testWidgets('a host whose sessions are watched says so before connecting', (tester) async {
    await build(tester);
    List<Override> onScreen() => [
          activeSpaceProvider.overrideWith((ref) => OrchardSpace(orchardId)),
          itemCratesProvider('host').overrideWith((ref) => Stream.value({'web1': crateId})),
        ];
    Widget notes(OrchardSummary o, CrateSummary c) => const Column(children: [
          HostSessionsWatchedNote(connectionId: 'web1'),
          HostSessionsWatchedNote(connectionId: 'web1', compact: true),
        ]);
    await pump(tester, owner, notes, extra: onScreen());
    expect(find.byKey(const ValueKey('host-watched-note-web1')), findsNothing, reason: 'off');
    expect(find.byKey(const ValueKey('host-watched-mark-web1')), findsNothing);
    await tester.runAsync(() => owner.setCrateWatched(orchardId, crateId, true));
    await pump(tester, owner, notes, extra: onScreen());
    expect(find.byKey(const ValueKey('host-watched-note-web1')), findsOneWidget);
    expect(find.byKey(const ValueKey('host-watched-mark-web1')), findsOneWidget);
    expect(find.text(l10n.hostSessionsWatched), findsOneWidget);
    // A member sees it too.
    await tester.runAsync(() => sync(alice));
    await pump(tester, alice, notes, extra: onScreen());
    expect(find.byKey(const ValueKey('host-watched-note-web1')), findsOneWidget);
    // In your Tree nothing is watched.
    await pump(tester, owner, notes, extra: [activeSpaceProvider.overrideWith((ref) => const TreeSpace())]);
    expect(find.byKey(const ValueKey('host-watched-note-web1')), findsNothing);
  });
}
