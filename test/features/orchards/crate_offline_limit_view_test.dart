import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/crate_offline.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_changes.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart' show accessTimeText;
import 'package:zestssh/features/orchards/team/team_words.dart';
import 'package:zestssh/features/orchards/widgets/crate_offline_limit_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_crates.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart' show signInRefresherProvider;
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart' show orchardChangeErrorMessage, orchardSubtitle;
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/services/cloud/cloud_statement.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/utils/redactor.dart';

import '../../helpers/phone_host_card.dart';

import 'fake_crate_server.dart';
import 'vaults_window_helper.dart';

/// A Crate's own offline limit on screen (3.0): owners
/// choose it on the Crate's row, after a yes that says what it means when a
/// limit is new or shorter than the one there is; everyone else is told the
/// limit the Crate has; a Crate that is closed on the device says its limit
/// and offers no change; a host of a closed Crate says so before anyone
/// connects; and the Changes page names the change, with how long.

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

  /// Whether this build can have an outage of ZestSSH Cloud's proven to it.
  var statusService = false;

  setUpAll(() async {
    for (final uid in ['owner-1', 'alice']) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    statusService = false;
  });

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

  /// When each device last reached ZestSSH Cloud, and its clock.
  var now = 1790000000;
  var last = 1790000000;

  /// Acme with the owner and alice, a member who may use Production. Both
  /// devices reached ZestSSH Cloud a moment ago.
  Future<void> build(WidgetTester tester) => tester.runAsync(() async {
        now = 1790000000;
        last = now;
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
        for (final s in [owner, alice]) {
          attachDeviceContact(await s.databases.open(orchardId),
              DeviceContact(read: () => OrchardContact(lastContact: last, latest: now), now: () => now));
        }
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
      {List<Override> extra = const []}) async {
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
        cloudReachStateProvider.overrideWith((ref) => Stream.value(const CloudReachState(CloudReach.deviceOffline))),
        // Whether this build has a status service to ask (a made-up one).
        cloudStatusConfigProvider.overrideWithValue(CloudStatusConfig(
          url: statusService ? 'https://status.example/v1/now' : '',
          service: 'api.example',
          keys: statusService ? {'k1': List<int>.filled(32, 7)} : const {},
        )),
        ...extra,
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: SingleChildScrollView(child: child(summary, crate))),
      ),
    ));
    await settle(tester);
  }

  int inRecord() => server.recordOf(orchardId).crates[crateId]!.offlineHours;
  Widget line(OrchardSummary o, CrateSummary c) => CrateOfflineLimitLine(orchard: o, crate: c);
  Finder control() => find.byKey(ValueKey('crate-offline-$crateId'));
  Finder note() => find.byKey(ValueKey('crate-offline-note-$crateId'));

  /// Picks [label] in the owner's list of limits.
  Future<void> pick(WidgetTester tester, String label) async {
    await tester.tap(control());
    await settle(tester);
    await tester.tap(find.text(label).last);
    await settle(tester);
  }

  testWidgets('an owner chooses a limit after a yes that says what it means; a longer one, or none, is not asked '
      'about', (tester) async {
    await build(tester);
    await pump(tester, owner, line);
    expect(note(), findsNothing);
    expect(find.text(l10n.orchardRulesOffline), findsOneWidget);
    expect(tester.widget<ZestSelect<int>>(control()).value, 0);
    expect(find.text(l10n.orchardRulesOfflineOff), findsOneWidget);
    // What is offered: none, a working day, a day, three days, a week,
    // thirty days.
    expect(CrateOfflineLimitLine.choices, [0, 8, 24, 72, 168, 720]);
    await tester.tap(control());
    await settle(tester);
    for (final label in ['8 hours', '1 day', '3 days', '7 days', '30 days']) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    await tester.tap(find.text('1 day').last);
    await settle(tester);

    // The question says what it means, for whom, and what stays open.
    expect(find.text(l10n.crateOfflineSetTitle('Production', '1 day')), findsOneWidget);
    // A lead and short points of what follows (3.0 UI: it was one paragraph).
    final points = [l10n.vaultUiOfflineSetClosed, l10n.vaultUiOfflineSetEvery, l10n.vaultUiOfflineSetOpen];
    expect(find.text(l10n.vaultUiOfflineSetLead), findsOneWidget);
    for (final point in points) {
      expect(find.text(point), findsOneWidget, reason: point);
    }
    final said = [l10n.vaultUiOfflineSetLead, ...points].join(' ').toLowerCase();
    for (final part in [
      'closes this vault until it does',
      'its hosts do not connect',
      'cannot be used or shown',
      'every device, yours included',
      'Sessions that are already open stay open',
      'Each device checks it',
    ]) {
      expect(said, contains(part.toLowerCase()));
    }
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(inRecord(), 0, reason: 'declined: nothing sent');
    expect(tester.widget<ZestSelect<int>>(control()).value, 0);

    await pick(tester, '1 day');
    final scope = ProviderScope.containerOf(tester.element(control()));
    final listed = scope.read(orchardListVersionProvider);
    await tester.tap(find.text(l10n.crateOfflineSetConfirm).last);
    await settle(tester);
    expect(inRecord(), 24);
    expect(server.appends.last, [RecordTypes.crateSet]);
    // (On a computer what the app says goes to its notices.)
    final saved = scope.read(notificationCenterProvider).history.first;
    expect((saved.title, saved.severity), (l10n.orchardChangeSaved, NotificationSeverity.success));
    expect(scope.read(orchardListVersionProvider), greaterThan(listed), reason: 'whatever lists the Crates looks again');
    await tester.pump(const Duration(seconds: 10));
    await pump(tester, owner, line);
    expect(tester.widget<ZestSelect<int>>(control()).value, 24);

    // The same again: nothing asked, nothing sent.
    final sent = server.appends.length;
    await pick(tester, '1 day');
    expect(find.byType(ZestConfirmDialog), findsNothing);
    expect(server.appends.length, sent);

    // Longer: it keeps nobody out sooner, so it is set at once.
    await pick(tester, '3 days');
    expect(find.byType(ZestConfirmDialog), findsNothing);
    expect(inRecord(), 72);
    await tester.pump(const Duration(seconds: 10));
    await pump(tester, owner, line);
    expect(tester.widget<ZestSelect<int>>(control()).value, 72);

    // Shorter: asked again, with the new length.
    await pick(tester, '8 hours');
    expect(find.text(l10n.crateOfflineSetTitle('Production', '8 hours')), findsOneWidget);
    await tester.tap(find.text(l10n.crateOfflineSetConfirm).last);
    await settle(tester);
    expect(inRecord(), 8);
    await tester.pump(const Duration(seconds: 10));
    await pump(tester, owner, line);

    // None: taken off at once.
    await pick(tester, l10n.orchardRulesOfflineOff);
    expect(find.byType(ZestConfirmDialog), findsNothing);
    expect(inRecord(), 0);
    await tester.pump(const Duration(seconds: 10));

    // What could not be sent is said, and nothing is claimed.
    await pump(tester, owner, line);
    late String why;
    await tester.runAsync(() async {
      server.down = true;
      try {
        await owner.setCrateOfflineLimit(orchardId, crateId, 720);
        fail('sent to a server that is away');
      } catch (e) {
        why = orchardChangeErrorMessage(e, l10n);
      }
    });
    final before = ProviderScope.containerOf(tester.element(control())).read(orchardListVersionProvider);
    await pick(tester, '30 days');
    await tester.tap(find.text(l10n.crateOfflineSetConfirm).last);
    await settle(tester);
    final failed = ProviderScope.containerOf(tester.element(control())).read(notificationCenterProvider).history.first;
    // (A long message is a title and what follows it.)
    expect(failed.severity, NotificationSeverity.error);
    expect([failed.title, failed.body].whereType<String>().join(' '), why);
    expect(why, contains('ZestSSH Cloud is not responding'));
    expect(ProviderScope.containerOf(tester.element(control())).read(orchardListVersionProvider), before);
    server.down = false;
    expect(inRecord(), 0);
    expect(tester.widget<ZestSelect<int>>(control()).onChanged, isNotNull, reason: 'and it can be tried again');
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('ZestSSH Cloud wants a recent sign-in for it: the person is told what is about to change, and it is '
      'set once they have signed in again', (tester) async {
    await build(tester);
    var signedInAgain = 0;
    var signsIn = true;
    final again = [
      signInRefresherProvider.overrideWithValue((context, ref, {wrongAccount}) async {
        signedInAgain++;
        if (signsIn) server.requireRecentSignIn = false;
        return signsIn;
      }),
    ];
    server.requireRecentSignIn = true;
    await pump(tester, owner, line, extra: again);
    await pick(tester, '1 day');
    await tester.tap(find.text(l10n.crateOfflineSetConfirm).last);
    await settle(tester);
    // Asked to confirm it is them, with the change named; nothing is set.
    expect(find.text(l10n.stepUpTitle), findsOneWidget);
    expect(find.text(l10n.stepUpCrateOffline('Production')), findsOneWidget);
    expect(inRecord(), 0);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect((signedInAgain, inRecord()), (0, 0), reason: 'declined: nobody signs in, nothing is set');
    final scope = ProviderScope.containerOf(tester.element(control()));
    expect(scope.read(notificationCenterProvider).history, isEmpty, reason: 'and nothing is said to have happened');

    // A sign-in that does not go through sets nothing either.
    signsIn = false;
    await pick(tester, '1 day');
    await tester.tap(find.text(l10n.crateOfflineSetConfirm).last);
    await settle(tester);
    await tester.tap(find.text(l10n.devicesSignInAgainTitle).last);
    await settle(tester);
    expect((signedInAgain, inRecord()), (1, 0));
    expect(scope.read(notificationCenterProvider).history, isEmpty);

    // Signed in again: set.
    signsIn = true;
    await pick(tester, '1 day');
    await tester.tap(find.text(l10n.crateOfflineSetConfirm).last);
    await settle(tester);
    await tester.tap(find.text(l10n.devicesSignInAgainTitle).last);
    await settle(tester);
    expect((signedInAgain, inRecord()), (2, 24));
    expect(scope.read(notificationCenterProvider).history.first.title, l10n.orchardChangeSaved);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('where an outage of ours can be proven, the question says that it does not count', (tester) async {
    await build(tester);
    await pump(tester, owner, line);
    await pick(tester, '1 day');
    expect(find.textContaining(l10n.orchardRulesOfflineOutageNote(7)), findsNothing);
    // Where none can be, it counts, and the question says so with the way
    // on.
    expect(find.text(l10n.orchardRulesOfflineOutageCounts(7)), findsOneWidget);
    expect(l10n.orchardRulesOfflineOutageCounts(7), contains('counts too'));
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);

    statusService = true;
    await pump(tester, owner, line);
    await pick(tester, '1 day');
    expect(find.text(l10n.orchardRulesOfflineOutageNote(7)), findsOneWidget, reason: 'one of its points');
    expect(find.text(l10n.orchardRulesOfflineOutageCounts(7)), findsNothing);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(inRecord(), 0);
  });

  testWidgets('everyone else is told the limit a Crate has, and a limit that is none of the choices is shown as '
      'what it is', (tester) async {
    await build(tester);
    // No limit: a member is told nothing.
    await pump(tester, alice, line);
    expect(note(), findsNothing);
    expect(control(), findsNothing);
    expect(find.text(l10n.orchardRulesOffline), findsNothing);

    // A day and a half, set elsewhere (a setup file, say).
    await tester.runAsync(() => owner.setCrateOfflineLimit(orchardId, crateId, 36));
    await pump(tester, alice, line);
    expect(note(), findsOneWidget);
    expect(find.text(l10n.crateOfflineNote('36 hours')), findsOneWidget);
    expect(control(), findsNothing, reason: 'a member changes nothing');
    await pump(tester, owner, line);
    expect(tester.widget<ZestSelect<int>>(control()).value, isNull);
    expect(find.text('36 hours'), findsOneWidget);
    expect(note(), findsNothing);

    // Whole days are said as days.
    await tester.runAsync(() => owner.setCrateOfflineLimit(orchardId, crateId, 168));
    await pump(tester, alice, line);
    expect(find.text(l10n.crateOfflineNote('7 days')), findsOneWidget);

    // An owner whose device is not taking part in the Orchard just now
    // (held back, suspended, a record it stopped following) is told the
    // limit and changes nothing.
    await pump(
        tester,
        owner,
        (o, c) => CrateOfflineLimitLine(
            orchard: OrchardSummary(
                id: o.id, name: o.name, role: o.role, crates: o.crates, defaultCrateId: o.defaultCrateId, status: 'rules'),
            crate: c));
    expect(control(), findsNothing);
    expect(find.text(l10n.crateOfflineNote('7 days')), findsOneWidget);
  });

  testWidgets('on the Crates page: the limit stands on the row, and a Crate that is closed on the device says its '
      'limit and offers no change', (tester) async {
    await build(tester);
    await tester.runAsync(() => owner.setCrateOfflineLimit(orchardId, crateId, 24));
    Widget crates(OrchardSummary o, CrateSummary c) => OrchardCratesView(orchardId: orchardId);
    await pump(tester, owner, crates);
    await openVaultTab(tester, crateId, VaultTab.offline);
    expect(tester.widget<ZestSelect<int>>(control()).value, 24);
    expect(note(), findsNothing);

    final closing = find.byKey(ValueKey('crate-closing-$crateId'));
    expect(closing, findsNothing);

    // Away, and not yet in the last quarter of the limit: nothing more.
    now = last + 18 * 3600 - 1;
    await pump(tester, owner, crates);
    await openVaultTab(tester, crateId, VaultTab.offline);
    expect(closing, findsNothing);

    // In the last quarter: the row says when, and the choice is still there
    // (the device may be back in contact the next moment).
    now = last + 18 * 3600;
    await pump(tester, owner, crates);
    await openVaultTab(tester, crateId, VaultTab.offline);
    expect(
        find.descendant(
            of: closing, matching: find.text(l10n.crateClosesAt(accessTimeText(last + 24 * 3600, l10n)))),
        findsOneWidget);
    expect(tester.widget<ZestSelect<int>>(control()).value, 24);
    expect(find.byKey(ValueKey('crate-closed-$crateId')), findsNothing);

    // A day and a second away: closed here, an owner's device too, and
    // what has closed is no longer about to.
    now = last + 24 * 3600 + 1;
    await pump(tester, owner, crates);
    await openVaultTab(tester, crateId, VaultTab.offline);
    expect(find.byKey(ValueKey('crate-closed-$crateId')), findsOneWidget);
    expect(closing, findsNothing);
    expect(control(), findsNothing);
    expect(find.text(l10n.crateOfflineNote('1 day')), findsOneWidget);

    // Back in contact: the choice again.
    last = now;
    await pump(tester, owner, crates);
    await openVaultTab(tester, crateId, VaultTab.offline);
    expect(tester.widget<ZestSelect<int>>(control()).value, 24);
    expect(note(), findsNothing);
    expect(closing, findsNothing);
  });

  testWidgets("the switcher says when an Orchard's own limit is about to close all of it here, after what keeps "
      'the account out of it already', (tester) async {
    await build(tester);
    await tester.runAsync(() => owner.setRules(orchardId, const RecordRules(offlineHours: 24)));
    Widget subtitle(OrchardSummary o, CrateSummary c) => Consumer(
        builder: (context, ref, _) => Text(orchardSubtitle(o, ref, l10n), key: const ValueKey('subtitle')));
    String shown() => tester.widget<Text>(find.byKey(const ValueKey('subtitle'))).data!;
    final role = l10n.orchardTeamRole(l10n.orchardRoleOwner);
    final when = l10n.orchardTeamRole(l10n.offlineClosesShort(accessTimeText(last + 24 * 3600, l10n)));
    expect(when, isNot(role));

    await pump(tester, owner, subtitle);
    expect(shown(), role);
    now = last + 18 * 3600 - 1;
    await pump(tester, owner, subtitle);
    expect(shown(), role);
    now = last + 18 * 3600;
    await pump(tester, owner, subtitle);
    expect(shown(), when);
    // Back in contact: the role again.
    last = now;
    await pump(tester, owner, subtitle);
    expect(shown(), role);

    // What keeps the account out already is what is said: an Orchard that
    // is closed, a membership that is suspended, ended or waiting to be
    // let back in, rules that are not met, a record that does not sync.
    OrchardSummary about(
            {bool closed = false, String status = 'active', String? problem, List<String> unmet = const []}) =>
        OrchardSummary(
            id: orchardId,
            name: 'Acme',
            role: FixedRoles.owner,
            crates: const [],
            defaultCrateId: null,
            status: status,
            recordProblem: problem,
            rulesUnmet: unmet,
            closedOffline: closed,
            closesAt: last + 24 * 3600);
    for (final (summary, said) in [
      (about(), l10n.offlineClosesShort(accessTimeText(last + 24 * 3600, l10n))),
      (about(closed: true), l10n.orchardClosedOfflineShort),
      (about(status: kRecoveryWaitStatus), l10n.orchardWaitingRecoveryShort),
      (about(status: 'suspended'), l10n.orchardMemberSuspended),
      (about(status: 'ended'), l10n.orchardMemberEnded),
      (about(status: 'rules', unmet: ['two_step']), l10n.orchardRulesNotMet),
      (about(problem: 'does not verify'), l10n.orchardNotSyncing),
    ]) {
      await pump(tester, owner, (o, c) => subtitle(summary, c));
      expect(shown(), l10n.orchardTeamRole(said));
    }
  });

  testWidgets("on a phone, a host's card says its Crate is closed on the device before anyone connects",
      (tester) async {
    await build(tester);
    await tester.runAsync(() => owner.setCrateOfflineLimit(orchardId, crateId, 24));
    final card = await phoneHostCard(tester, 'web1');
    final needs = await phoneHostCardNeeds(tester);
    List<Override> onScreen() => [
          activeSpaceProvider.overrideWith((ref) => OrchardSpace(orchardId)),
          itemCratesProvider('host').overrideWith((ref) => Stream.value({'web1': crateId})),
          ...needs,
        ];
    final mark = find.byKey(const ValueKey('host-closed-mark-web1'));
    await pump(tester, owner, (o, c) => card, extra: onScreen());
    expect(find.text('Web 1'), findsOneWidget);
    expect(mark, findsNothing, reason: 'open');
    now = last + 24 * 3600 + 1;
    await pump(tester, owner, (o, c) => card, extra: onScreen());
    expect(mark, findsOneWidget);
    expect(tester.widget<Tooltip>(find.ancestor(of: mark, matching: find.byType(Tooltip))).message,
        l10n.hostCrateClosed);
    last = now;
    await pump(tester, owner, (o, c) => card, extra: onScreen());
    expect(mark, findsNothing, reason: 'back in contact');
  });

  testWidgets('a host of a Crate that is closed on the device says so before anyone connects', (tester) async {
    await build(tester);
    await tester.runAsync(() => owner.setCrateOfflineLimit(orchardId, crateId, 24));
    List<Override> onScreen() => [
          activeSpaceProvider.overrideWith((ref) => OrchardSpace(orchardId)),
          itemCratesProvider('host').overrideWith((ref) => Stream.value({'web1': crateId})),
        ];
    Widget notes(OrchardSummary o, CrateSummary c) => const Column(children: [
          HostCrateClosedNote(connectionId: 'web1'),
          HostCrateClosedNote(connectionId: 'web1', compact: true),
          // A host that has not been placed is in the Crate new items go
          // into.
          HostCrateClosedNote(connectionId: 'new1', compact: true),
        ]);
    final line = find.byKey(const ValueKey('host-closed-note-web1'));
    final mark = find.byKey(const ValueKey('host-closed-mark-web1'));
    final unplaced = find.byKey(const ValueKey('host-closed-mark-new1'));

    await pump(tester, owner, notes, extra: onScreen());
    expect((line.evaluate().length, mark.evaluate().length, unplaced.evaluate().length), (0, 0, 0), reason: 'open');

    now = last + 24 * 3600 + 1;
    await pump(tester, owner, notes, extra: onScreen());
    expect(line, findsOneWidget);
    expect(mark, findsOneWidget);
    expect(unplaced, findsOneWidget);
    expect(find.text(l10n.hostCrateClosed), findsOneWidget);
    expect(tester.widget<Tooltip>(find.ancestor(of: mark, matching: find.byType(Tooltip))).message,
        l10n.hostCrateClosed);
    // A member's device, away as long, says the same.
    await pump(tester, alice, notes, extra: onScreen());
    expect(line, findsOneWidget);
    // A host of another Crate does not.
    await pump(tester, owner, notes, extra: [
      activeSpaceProvider.overrideWith((ref) => OrchardSpace(orchardId)),
      itemCratesProvider('host').overrideWith(
          (ref) => Stream.value({'web1': '00000000-0000-4000-8000-000000000000', 'new1': '00000000-0000-4000-8000-000000000000'})),
    ]);
    expect((line.evaluate().length, mark.evaluate().length, unplaced.evaluate().length), (0, 0, 0));
    // In your Tree nothing is closed.
    await pump(tester, owner, notes, extra: [activeSpaceProvider.overrideWith((ref) => const TreeSpace())]);
    expect(line, findsNothing);

    // Back in contact: nothing is said.
    last = now;
    await pump(tester, owner, notes, extra: onScreen());
    expect((line.evaluate().length, mark.evaluate().length, unplaced.evaluate().length), (0, 0, 0));
  });

  test('the mark stands where a host says other things of its Crate: on its card, small, and on its panel', () {
    // (Nothing shows a whole card or panel in a test; this at least holds
    // the two lines in place.)
    String source(String name) => File('lib/features/hosts/widgets/$name').readAsStringSync();
    expect('HostCrateClosedNote(connectionId: widget.data.id, compact: true)'.allMatches(source('host_card.dart')),
        hasLength(1));
    expect('HostCrateClosedNote(connectionId: conn.id)'.allMatches(source('host_panel.dart')), hasLength(1));
  });

  test('the words: a length of whole days is said in days and anything else in hours, the Changes page names the '
      'Crate and the length, in every language', () {
    expect(offlineSpanWords(l10n, 8), '8 hours');
    expect(offlineSpanWords(l10n, 24), '1 day');
    expect(offlineSpanWords(l10n, 36), '36 hours');
    expect(offlineSpanWords(l10n, 72), '3 days');
    expect(offlineSpanWords(l10n, 1), '1 hour');
    expect(offlineSpanWords(l10n, 8760), '365 days');
    TeamChange change(TeamChangeKind kind, {int? hours}) =>
        TeamChange(seq: 9, kind: kind, by: 'uid-owner', byKeyVersion: 1, crateId: 'c1', hours: hours);
    String words(TeamChange c, AppLocalizations l) => teamChangeText(c, l,
        nameOf: (uid) => uid ?? '', crateName: (id) => id == 'c1' ? 'Production' : '?', roleName: (id) => id);
    expect(words(change(TeamChangeKind.crateOfflineSet, hours: 24), l10n), 'Set an offline limit of 1 day for Production');
    expect(words(change(TeamChangeKind.crateOfflineSet, hours: 8), l10n), 'Set an offline limit of 8 hours for Production');
    expect(words(change(TeamChangeKind.crateOfflineOff), l10n), 'Took the offline limit off Production');
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      final day = offlineSpanWords(l, 24);
      final hours = offlineSpanWords(l, 8);
      expect(day, l.orchardRulesOfflineDays(1), reason: '$locale');
      expect(hours, l.orchardRulesOfflineHours(8), reason: '$locale');
      final set = words(change(TeamChangeKind.crateOfflineSet, hours: 24), l);
      final off = words(change(TeamChangeKind.crateOfflineOff), l);
      expect(set, allOf(contains('Production'), contains(day)), reason: '$locale');
      expect(words(change(TeamChangeKind.crateOfflineSet, hours: 8), l), contains(hours), reason: '$locale');
      expect(off, contains('Production'), reason: '$locale');
      expect(off, isNot(set), reason: '$locale');
      expect(off, isNot(l.teamChangeCrateSettings('Production')), reason: '$locale');
      // On the screens.
      expect(l.crateOfflineNote(day), contains(day), reason: '$locale');
      expect(l.crateOfflineSetTitle('Production', day), allOf(contains('Production'), contains(day)),
          reason: '$locale');
      expect(l.stepUpCrateOffline('Production'), contains('Production'), reason: '$locale');
      for (final said in [l.crateOfflineTooltip]) {
        expect(said, contains('ZestSSH Cloud'), reason: '$locale');
      }
      expect(l.hostCrateClosed, isNotEmpty, reason: '$locale');
      expect(l.crateOfflineSetConfirm, isNotEmpty, reason: '$locale');
    }
  });
}
