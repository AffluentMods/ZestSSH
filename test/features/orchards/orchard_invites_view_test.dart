import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/widgets/fingerprint_view.dart';
import 'package:zestssh/features/orchards/widgets/invite_people_dialog.dart' show inviteAddressFileProvider;
import 'package:zestssh/features/orchards/widgets/orchard_invites.dart';
import 'package:zestssh/features/orchards/widgets/orchard_members.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/utils/redactor.dart';

import 'fake_crate_server.dart';

/// The invitation screens (3.0): an owner sees who waits, compares
/// their fingerprint and adds them, or withdraws an invitation; an admin
/// offers the roles below their own and no more access than they hold; the
/// invited person accepts and then has their own fingerprint to read out.

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

  late _MemoryStorage storage;
  late FakeCrateServer server;
  late OrchardService service;
  late AccountKeys myKeys;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    storage = _MemoryStorage();
  });

  tearDown(() async {
    for (final db in storage.dbs.values) {
      await db.close();
    }
  });

  OrchardService serviceFor(String uid) => OrchardService(
        server: server,
        databases:
            OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
        author: () async => CrateAuthor(uid: uid, keys: myKeys),
      );

  /// Pumps a button that runs [open], with [summaries] as the Orchards on
  /// this device, and taps it.
  Future<void> openWith(WidgetTester tester, void Function(BuildContext, WidgetRef) open,
      {List<OrchardSummary> summaries = const [], List<String> proven = const [], List<Override> more = const []}) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        orchardServiceProvider.overrideWithValue(service),
        orchardSummariesProvider.overrideWith((ref) async => summaries),
        orchardProvenDomainsProvider.overrideWith((ref, id) async => proven),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
        ...more,
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => open(context, ref),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await settle(tester);
  }

  testWidgets('an owner compares the fingerprint of someone who accepted and adds them, or withdraws',
      (tester) async {
    server = FakeCrateServer(accountUid: 'owner-1');
    late PublishedAccountKeys newcomer;
    late String orchardId;
    late String crateId;
    late String bobInvite;
    late String newInvite;
    await tester.runAsync(() async {
      myKeys = await AccountKeys.generate();
      service = serviceFor('owner-1');
      final newKeys = await AccountKeys.generate();
      newcomer = await newKeys.publish('new-1');
      await server.publish('owner-1', myKeys, email: 'me@example.com');
      await server.publish('new-1', newKeys, email: 'new@example.com');
      orchardId = await service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
      crateId = server.orchardsById[orchardId]!.crates.single.id;
      final role = server.recordOf(orchardId).roles.values.single.id;
      await service.invite(orchardId, email: 'bob@example.com', role: role);
      await service.invite(orchardId, email: 'new@example.com', role: role);
      final invites = await service.invites(orchardId);
      bobInvite = invites.firstWhere((i) => i.email == 'bob@example.com').id;
      newInvite = invites.firstWhere((i) => i.email == 'new@example.com').id;
      server.acceptAs(orchardId, newInvite, 'new-1');
      await service.refresh();
    });
    final summary = OrchardSummary(
      id: orchardId,
      name: 'Acme',
      role: FixedRoles.owner,
      can: RoleCan.all,
      crates: [
        CrateSummary(id: crateId, name: 'Production', level: 'manage', switches: CrateSwitches.all),
      ],
      defaultCrateId: crateId,
      invitesWaiting: 1,
    );

    await openWith(tester, (context, ref) => showOrchardMembers(context, ref, orchardId), summaries: [summary]);

    expect(find.text(l10n.orchardInvitesTitle), findsOneWidget);
    Finder inRow(String id, Finder f) => find.descendant(of: find.byKey(ValueKey('invite-$id')), matching: f);
    expect(inRow(newInvite, find.text(l10n.orchardInviteStatusAccepted)), findsOneWidget);
    expect(inRow(bobInvite, find.text(l10n.orchardInviteStatusSent)), findsOneWidget);
    expect(inRow(newInvite, find.text('Member')), findsOneWidget, reason: 'the role by its name');
    expect(inRow(bobInvite, find.text(l10n.orchardInviteSummary('Member', 1))), findsOneWidget,
        reason: 'the role by its name, and the one Crate it opens');
    // Under "Waiting for you" and "Invited", the one who waits first.
    expect(find.text(l10n.waitingForYouTitle.toUpperCase()), findsOneWidget);
    expect(find.text(l10n.invitedSectionTitle.toUpperCase()), findsOneWidget);
    expect(find.byKey(ValueKey('invite-confirm-$bobInvite')), findsNothing,
        reason: 'nothing to compare before they accept');
    // Those waiting on a comparison come first.
    expect(tester.getTopLeft(find.byKey(ValueKey('invite-$newInvite'))).dy,
        lessThan(tester.getTopLeft(find.byKey(ValueKey('invite-$bobInvite'))).dy));

    await tester.tap(find.byKey(ValueKey('invite-confirm-$newInvite')));
    await tester.pumpAndSettle();
    expect(fingerprintOf(newcomer.fingerprint), findsOneWidget,
        reason: 'the words to compare, from the keys they published');
    // What they get, as it is signed, beside the words: the role, each
    // vault with its level, and when the access ends.
    Finder offered(Finder f) => find.descendant(of: find.byKey(ValueKey('invite-offer-$newInvite')), matching: f);
    expect(offered(find.text('Member')), findsOneWidget);
    expect(offered(find.text('Production')), findsOneWidget);
    expect(offered(find.text(l10n.inviteAccessNever)), findsOneWidget);
    await tester.tap(find.text(l10n.orchardInviteConfirmMatch));
    await settle(tester);
    expect(server.confirmations.single.inviteId, newInvite);
    expect(server.confirmations.single.entry.body['key_version'], newcomer.version);
    expect(server.recordOf(orchardId).members.containsKey('new-1'), isTrue);
    expect(toasted(tester, l10n.orchardInviteConfirmed('new@example.com')), isTrue);
    expect(find.byKey(ValueKey('invite-$newInvite')), findsNothing);
    expect(find.descendant(of: find.byKey(const ValueKey('member-new-1')), matching: find.text(l10n.orchardMemberVerifiedByYou)),
        findsOneWidget, reason: 'added, and verified by the one who compared');

    await tester.tap(find.byKey(ValueKey('invite-withdraw-$bobInvite')));
    await settle(tester);
    expect(server.withdrawn, [bobInvite]);
    expect(find.byKey(ValueKey('invite-$bobInvite')), findsNothing);
    await tester.pump(const Duration(seconds: 5)); // the toasts time out
  });

  testWidgets('an invitation this device made, listed with another offer, lets nobody in from here', (tester) async {
    final relisting = _Relisting();
    server = relisting;
    late String orchardId;
    late String crateId;
    late String newInvite;
    await tester.runAsync(() async {
      myKeys = await AccountKeys.generate();
      service = serviceFor('owner-1');
      final newKeys = await AccountKeys.generate();
      await server.publish('owner-1', myKeys, email: 'me@example.com');
      await server.publish('new-1', newKeys, email: 'new@example.com');
      orchardId = await service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
      crateId = server.orchardsById[orchardId]!.crates.single.id;
      final role = server.recordOf(orchardId).roles.values.single.id;
      await service.invite(orchardId, email: 'new@example.com', role: role);
      newInvite = (await service.invites(orchardId)).single.id;
      server.acceptAs(orchardId, newInvite, 'new-1');
      await service.refresh();
    });
    // The server lists the invitation as Admin.
    relisting.role = FixedRoles.admin;
    final summary = OrchardSummary(
      id: orchardId,
      name: 'Acme',
      role: FixedRoles.owner,
      can: RoleCan.all,
      crates: [CrateSummary(id: crateId, name: 'Production', level: 'manage', switches: CrateSwitches.all)],
      defaultCrateId: crateId,
      invitesWaiting: 1,
    );
    await openWith(tester, (context, ref) => showOrchardMembers(context, ref, orchardId), summaries: [summary]);
    await tester.tap(find.byKey(ValueKey('invite-confirm-$newInvite')));
    await settle(tester);
    expect(find.byKey(const ValueKey('invitee-fingerprint')), findsNothing, reason: 'nothing to compare: nobody is let in');
    // (A long message is told as its first sentence and the rest.)
    final told = ProviderScope.containerOf(tester.element(find.text('open').first))
        .read(notificationCenterProvider)
        .history
        .any((n) => n.title.isNotEmpty && l10n.orchardInviteOfferChangedAddress.startsWith(n.title));
    expect(told, isTrue);
    expect(server.confirmations, isEmpty);
    expect(server.recordOf(orchardId).members.containsKey('new-1'), isFalse);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an admin offers the roles below their own, and no more access than they hold; a partial address is refused',
      (tester) async {
    server = FakeCrateServer(accountUid: 'admin-1');
    late String orchardId;
    late String role;
    await tester.runAsync(() async {
      myKeys = await AccountKeys.generate();
      service = serviceFor('admin-1');
      orchardId = await service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
      role = server.recordOf(orchardId).roles.values.single.id;
    });
    final summary = OrchardSummary(
      id: orchardId,
      name: 'Acme',
      role: FixedRoles.admin,
      can: RoleCan.all,
      crates: [
        CrateSummary(id: 'crate-read', name: 'Production', level: 'use', switches: levelSwitches(CrateLevel.use)),
        CrateSummary(id: 'crate-own', name: 'Staging', level: 'manage', switches: levelSwitches(CrateLevel.manage)),
        const CrateSummary(
            id: 'crate-owners', name: 'Keys', level: 'manage', ownersOnly: true, switches: CrateSwitches.all),
      ],
      defaultCrateId: 'crate-own',
    );

    await openWith(tester, (context, ref) => showInviteDialog(context, ref, summary));

    expect(find.byKey(ValueKey('invite-role-$role')), findsOneWidget);
    expect(find.text('Member'), findsOneWidget, reason: 'the role by the name the owners gave it');
    expect(find.byKey(const ValueKey('invite-role-admin')), findsNothing, reason: 'only owners add admins');
    ZestSelect<CrateLevel?> levels(String crateId) => tester.widget<ZestSelect<CrateLevel?>>(find.descendant(
        of: find.byKey(ValueKey('invite-crate-$crateId')), matching: find.byType(ZestSelect<CrateLevel?>)));
    // Each vault: the role's own level (none here), and the levels above it
    // this account may hand on.
    expect(levels('crate-read').items.map((i) => i.value), [null, CrateLevel.connect, CrateLevel.use]);
    expect(levels('crate-own').items.map((i) => i.value), [null, ...CrateLevel.values]);
    expect(levels('crate-read').value, isNull, reason: 'the role decides until a level is picked');
    expect(find.byKey(const ValueKey('invite-crate-crate-owners')), findsNothing,
        reason: 'an owners-only Crate is never offered');

    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('invite-email')), matching: find.byType(TextField)),
        'not-an-address');
    await tester.tap(find.text(l10n.orchardInviteSend));
    await settle(tester);
    expect(find.text(l10n.orchardInviteEmailInvalid), findsOneWidget);
    expect(server.sentInvites, isEmpty);

    // Staging on top, at edit (an "Extra" above the role).
    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('invite-crate-crate-own')), matching: find.byType(ZestSelect<CrateLevel?>)));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byKey(ValueKey('zest-select-item-${CrateLevel.edit}')), matching: find.text(l10n.crateLevelEdit)));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const ValueKey('invite-crate-crate-own')), matching: find.text(l10n.inviteVaultExtra)),
        findsOneWidget);
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('invite-email')), matching: find.byType(TextField)),
        ' New@Example.com ');
    await tester.tap(find.text(l10n.orchardInviteSend));
    await settle(tester);
    final sent = server.sentInvites.single;
    expect(sent.email, 'new@example.com');
    expect(sent.role, role);
    expect(sent.grants, {'crate-own': levelSwitches(CrateLevel.edit)});
    expect(toasted(tester, l10n.orchardInviteSent('new@example.com')), isTrue);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('many at once: pasted in any shape or read from a CSV, each checked, repeats sent once, '
      'what is no address left out', (tester) async {
    server = FakeCrateServer(accountUid: 'owner-1');
    late String orchardId;
    await tester.runAsync(() async {
      myKeys = await AccountKeys.generate();
      service = serviceFor('owner-1');
      orchardId = await service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    });
    final summary = OrchardSummary(
      id: orchardId,
      name: 'Acme',
      role: FixedRoles.owner,
      can: RoleCan.all,
      crates: const [],
      defaultCrateId: null,
    );
    await openWith(tester, (context, ref) => showInviteDialog(context, ref, summary),
        more: [inviteAddressFileProvider.overrideWithValue(() async => 'name,email\nCasey,casey@example.com\nJordan,jordan@example.com\n')]);
    Finder field() => find.descendant(of: find.byKey(const ValueKey('invite-email')), matching: find.byType(TextField));
    await tester.enterText(field(), 'jordan@example.com, sam@example.com\nriley@example.com riley@example.com not-an-address ');
    await tester.pump();
    expect(find.byKey(const ValueKey('invite-check')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('invite-check-riley@example.com')), matching: find.text(l10n.inviteCheckTwice)),
        findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('invite-check-not-an-address')), matching: find.text(l10n.inviteCheckBad)),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('invite-import-csv')));
    await settle(tester);
    expect(find.byKey(const ValueKey('invite-check-casey@example.com')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('invite-check-jordan@example.com')), matching: find.text(l10n.inviteCheckTwice)),
        findsOneWidget, reason: 'jordan was in the paste and the file');
    await tester.tap(find.text(l10n.inviteSendSeveral));
    await settle(tester);
    expect(server.sentInvites.map((i) => i.email).toList()..sort(),
        ['casey@example.com', 'jordan@example.com', 'riley@example.com', 'sam@example.com']);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('guests: once a domain is proven, an address outside it needs an owner and an end date', (tester) async {
    server = FakeCrateServer(accountUid: 'owner-1');
    late String orchardId;
    late String role;
    await tester.runAsync(() async {
      myKeys = await AccountKeys.generate();
      service = serviceFor('owner-1');
      orchardId = await service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
      role = server.recordOf(orchardId).roles.values.single.id;
    });
    OrchardSummary as(String who) =>
        OrchardSummary(id: orchardId, name: 'Acme', role: who, can: RoleCan.all, crates: const [], defaultCrateId: null);
    Finder email() => find.descendant(of: find.byKey(const ValueKey('invite-email')), matching: find.byType(TextField));

    // An admin: the address outside the domain is for owners.
    await openWith(tester, (context, ref) => showInviteDialog(context, ref, as(FixedRoles.admin)),
        proven: const ['example.com']);
    await tester.enterText(email(), 'guest@other.example');
    await tester.pump();
    expect(find.text(l10n.orchardGuestOwnersOnly), findsOneWidget);
    await tester.tap(find.text(l10n.orchardInviteSend));
    await settle(tester);
    expect(server.sentInvites, isEmpty);
    await tester.enterText(email(), 'someone@example.com');
    await tester.pump();
    expect(find.byKey(const ValueKey('invite-guest')), findsNothing, reason: "at the Orchard's own domain");
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);

    // An owner: a guest needs an end date first.
    await openWith(tester, (context, ref) => showInviteDialog(context, ref, as(FixedRoles.owner)),
        proven: const ['example.com']);
    await tester.enterText(email(), 'guest@other.example');
    await tester.pump();
    expect(find.text(l10n.orchardGuestNote), findsOneWidget);
    await tester.tap(find.text(l10n.orchardInviteSend));
    await settle(tester);
    expect(server.sentInvites, isEmpty);
    await tester.tap(find.byKey(const ValueKey('invite-ends')));
    await settle(tester);
    await tester.tap(find.text(l10n.inviteAccessPick));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('end-pick')));
    await settle(tester);
    await tester.tap(find.text('OK'));
    await settle(tester);
    await tester.tap(find.text(l10n.save).last);
    await settle(tester);
    await tester.tap(find.text(l10n.orchardInviteSend));
    await settle(tester);
    final sent = server.sentInvites.single;
    expect((sent.email, sent.role), ('guest@other.example', role));
    expect(sent.endsAt, isNotNull);
    await tester.pump(const Duration(seconds: 5));
  });

  test('the server refusing a guest is said plainly', () {
    expect(inviteErrorMessage(const OrchardServerException(409, 'end-too-far'), l10n), l10n.orchardEndTooFar);
    expect(orchardChangeErrorMessage(const OrchardServerException(409, 'end-too-far'), l10n), l10n.orchardEndTooFar);
    expect(inviteErrorMessage(const OrchardServerException(403, 'guest-owners-only'), l10n), l10n.orchardGuestOwnersOnly);
    expect(inviteErrorMessage(const OrchardServerException(409, 'guest-needs-end'), l10n), l10n.orchardGuestNeedsEnd);
    expect(orchardChangeErrorMessage(const OrchardServerException(409, 'guest-needs-end'), l10n), l10n.orchardGuestNeedsEnd);
  });

  test("what the team's record refuses on Compare and add is said as the refusal it is, not as this device failing", () {
    expect(inviteErrorMessage(const OrchardRecordRefused('only owners make admins'), l10n), l10n.orchardErrorRefused);
    expect(inviteErrorMessage(const OrchardRecordRefused('would leave no owner with an approved device'), l10n),
        l10n.deviceErrorLastOwner);
    expect(inviteErrorMessage(const OrchardRecordRefused('only owners make admins'), l10n), isNot(l10n.orchardErrorNotDone));
  });

  testWidgets('the invited person accepts, then has their fingerprint to read out; declining removes one',
      (tester) async {
    server = FakeCrateServer(accountUid: 'new-1');
    await tester.runAsync(() async {
      myKeys = await AccountKeys.generate();
      service = serviceFor('new-1');
    });
    MyInvite invite(String id, String? by,
            {RecordTracking tracking = RecordTracking.none,
            int sessionLogs = 0,
            bool exported = false,
            int watched = 0,
            int? endsAt}) =>
        MyInvite(
          id: id,
          orchardId: 'orchard-$id',
          role: 'member',
          crates: 2,
          expiresAt: DateTime.utc(2026, 10, 8, 12),
          accepted: false,
          invitedBy: by,
          tracking: tracking,
          exported: exported,
          sessionLogs: sessionLogs,
          watched: watched,
          endsAt: endsAt,
        );
    // A guest's access ends on a set day, apart from when the invitation lapses.
    const ends = 1798761600; // 1 January 2027, 00:00 UTC
    server.mine.addAll([
      invite('a', 'owner@example.com',
          tracking: const RecordTracking(history: true, activity: true),
          sessionLogs: 2,
          exported: true,
          watched: 1,
          endsAt: ends),
      invite('b', null),
      invite('c', null, endsAt: 9007199254740991),
    ]);

    await openWith(tester, (context, ref) => showMyInvitations(context));

    expect(find.text(l10n.myInvitationFrom('owner@example.com')), findsOneWidget);
    expect(find.text(l10n.myInvitationFromSomeone), findsNWidgets(2));
    expect(find.text(l10n.myInvitationDetails(l10n.orchardRoleMember, 2, DateTime.utc(2026, 10, 8, 12).toLocal())),
        findsNWidgets(3));
    // When the access offered would end, where it does.
    expect(tester.widget<Text>(find.byKey(const ValueKey('my-invite-ends-a'))).data,
        l10n.myInvitationAccessEnds(DateTime.fromMillisecondsSinceEpoch(ends * 1000).toLocal()));
    expect(find.byKey(const ValueKey('my-invite-ends-b')), findsNothing);
    // One offered further off than a date can say stands too.
    expect(tester.widget<Text>(find.byKey(const ValueKey('my-invite-ends-c'))).data, contains('275760'));
    // What each team records, before they decide.
    expect(find.descendant(of: find.byKey(const ValueKey('my-invite-tracking-a')),
        matching: find.text(l10n.myInvitationRecords('version history, activity'))), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('my-invite-tracking-b')),
        matching: find.text(l10n.myInvitationRecordsNothing)), findsOneWidget);
    // That its events are sent on to a system of its own, only where
    // they are.
    expect(tester.widget<Text>(find.byKey(const ValueKey('my-invite-exported-a'))).data, l10n.myInvitationExported);
    expect(find.byKey(const ValueKey('my-invite-exported-b')), findsNothing);
    // And how many of the Crates offered log sessions.
    expect(find.text(l10n.myInvitationSessionLogs(2)), findsOneWidget);
    expect(find.byKey(const ValueKey('my-invite-session-logs-b')), findsNothing);
    // And in how many their sessions are watched.
    expect(tester.widget<Text>(find.byKey(const ValueKey('my-invite-watched-a'))).data, l10n.myInvitationWatched(1));
    expect(l10n.myInvitationWatched(1), 'Vaults you would open whose sessions are watched: 1.');
    expect(find.byKey(const ValueKey('my-invite-watched-b')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('my-invite-accept-a')));
    await settle(tester);
    expect(server.accepted, ['a']);
    expect(find.byKey(const ValueKey('my-invite-accept-a')), findsNothing);
    expect(find.text(l10n.myInvitationAcceptedNote), findsOneWidget);
    final fingerprint = (await tester.runAsync(() => myKeys.publish('new-1')))!.fingerprint;
    expect(fingerprintOf(fingerprint), findsOneWidget, reason: 'their own words, to read out');

    await tester.tap(find.byKey(const ValueKey('my-invite-decline-b')));
    await settle(tester);
    expect(server.declined, ['b']);
    expect(find.byKey(const ValueKey('my-invite-b')), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });
}

/// Whether [message] was shown: on the screen (phones) or through the
/// notification center (desktop, where the tests run).
/// A server that lists every invitation with [role] once it is set.
class _Relisting extends FakeCrateServer {
  _Relisting() : super(accountUid: 'owner-1');

  String? role;

  @override
  Future<List<OrchardInvite>> invites(String orchardId) async => [
        for (final i in await super.invites(orchardId))
          role == null
              ? i
              : OrchardInvite(
                  id: i.id,
                  email: i.email,
                  role: role!,
                  grants: i.grants,
                  endsAt: i.endsAt,
                  expiresAt: i.expiresAt,
                  expired: i.expired,
                  invitedBy: i.invitedBy,
                  acceptedUid: i.acceptedUid,
                  acceptedKeys: i.acceptedKeys,
                  acceptedRulesUnmet: i.acceptedRulesUnmet,
                  acceptedProvider: i.acceptedProvider,
                  code: i.code,
                  acceptedDevice: i.acceptedDevice,
                ),
      ];
}

bool toasted(WidgetTester tester, String message) {
  if (find.text(message).evaluate().isNotEmpty) return true;
  // (The first: once, in a whole suite running beside another run, the
  // button's text was found twice here. Either is under the same scope.)
  final container = ProviderScope.containerOf(tester.element(find.text('open').first));
  return container
      .read(notificationCenterProvider)
      .history
      .any((n) => n.title == message || n.body == message);
}

/// Lets the database and crypto work finish (checking the record's
/// signatures takes a moment of real time), then the frames.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
    if (i >= 2 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}

/// The fingerprint widget showing [fp].
Finder fingerprintOf(List<int> fp) =>
    find.byWidgetPredicate((w) => w is FingerprintWords && listEquals(w.fingerprint, fp));
