import 'dart:async';
import 'dart:io' show SocketException;

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/certs/crate_authorities.dart';
import 'package:zestssh/features/orchards/directory/orchard_directory_api.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_overview.dart';
import 'package:zestssh/features/orchards/team/team_phone.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/team/team_trust.dart';
import 'package:zestssh/features/orchards/team/team_view.dart';
import 'package:zestssh/features/orchards/widgets/fingerprint_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart' show TeamInitials;
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/services/cloud/cloud_statement.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/utils/redactor.dart';

import '../../../helpers/record_statements.dart';

import '../../../visual/shots_util.dart';

import '../fake_crate_server.dart';

/// The Team destination (3.0), on a real Orchard record: an owner
/// who is the only one, a member nobody compared yet, and an admin removed
/// and added again with keys their old ones never vouched for.
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

  late OrchardService service;
  late OrchardDatabasesNotifier databases;
  late OrchardSummary summary;
  late Uint8List head;
  late String memberRole;

  /// [faces]: Alice's account shows a name and a picture (to-do 59).
  Future<void> setUpOrchard(WidgetTester tester, {bool faces = false}) async {
    FlutterSecureStorage.setMockInitialValues({});
    final storage = _MemoryStorage();
    addTearDown(() async {
      for (final db in storage.dbs.values) {
        try {
          await db.close();
        } catch (_) {}
      }
    });
    late AccountKeys myKeys;
    final server = FakeCrateServer(accountUid: 'owner-1');
    if (faces) {
      server.names['alice'] = 'Alice Example';
      server.pictures['alice'] = 'https://lh3.googleusercontent.com/a/alice';
    }
    databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage);
    service = OrchardService(
      server: server,
      databases: databases,
      author: () async => CrateAuthor(uid: 'owner-1', keys: myKeys),
    );
    await tester.runAsync(() async {
      myKeys = await AccountKeys.generate();
      final aliceKeys = await AccountKeys.generate();
      final bob1 = await AccountKeys.generate();
      final bob2 = await AccountKeys.generate();
      await server.publish('owner-1', myKeys, email: 'me@example.com');
      await server.publish('alice', aliceKeys, email: 'alice@example.com');
      await server.publish('bob', bob1, email: 'bob@example.com');
      final orchardId = await service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
      memberRole = server.recordOf(orchardId).roles.values.single.id;
      Future<void> append(String type, Map<String, Object?> body) async {
        final r = server.recordOf(orchardId);
        await server.appendAs('owner-1', orchardId, [
          await signRecordEntry(myKeys,
              orchardId: orchardId, seq: r.seq + 1, prev: r.head, type: type, body: body, by: 'owner-1'),
        ], checkCopies: false);
      }

      await append(RecordTypes.memberAdd,
          {...recordKeysBody(await aliceKeys.publish('alice')), 'uid': 'alice', 'role': memberRole});
      await append(RecordTypes.memberAdd,
          {
            ...recordKeysBody(await bob1.publish('bob')),
            'uid': 'bob',
            'role': FixedRoles.admin,
            'verified': await comparedStatement(myKeys, 'owner-1', orchardId, await bob1.publish('bob')),
          });
      await service.refresh();
      await server.publish('bob', bob2, email: 'bob@example.com');
      await append(RecordTypes.memberRemove, {'uid': 'bob'});
      await append(RecordTypes.memberAdd,
          {
            ...recordKeysBody(await bob2.publish('bob')),
            'uid': 'bob',
            'role': FixedRoles.admin,
            'verified': await comparedStatement(myKeys, 'owner-1', orchardId, await bob2.publish('bob')),
          });
      await service.refresh();
      final db = await databases.open(orchardId);
      summary = await readOrchardSummary(db, orchardId);
      head = (await LocalRecord.load(db, orchardId)).head;
    });
  }

  Future<ProviderContainer> pumpTeam(WidgetTester tester, {OrchardSummary? as, List<Override> extra = const []}) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      orchardServiceProvider.overrideWithValue(service),
      orchardDatabasesProvider.overrideWith((ref) => databases),
      activeOrchardProvider.overrideWithValue(AsyncData(as ?? summary)),
      orchardSummariesProvider.overrideWith((ref) async => [as ?? summary]),
      connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
      deviceLockProvider.overrideWith((ref) async => (on: true, minutes: 5)),
      recordingModeProvider.overrideWith((ref) => false),
      recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ...extra,
    ]);
    addTearDown(container.dispose);
    container.read(activeSidebarNavProvider.notifier).state = NavSection.team;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: TeamView()),
      ),
    ));
    await settle(tester);
    return container;
  }

  Finder inKey(String key, Finder f) => find.descendant(of: find.byKey(ValueKey(key)), matching: f);

  testWidgets('the Overview: the only owner, what needs this account, and the record in words', (tester) async {
    await setUpOrchard(tester);
    await pumpTeam(tester);

    expect(find.byKey(const ValueKey('team-sole-owner')), findsOneWidget);
    expect(inKey('team-attn-keys-bob', find.text(l10n.teamAttnKeysChanged('bob@example.com'))), findsOneWidget);
    expect(inKey('team-attn-unverified', find.text(l10n.teamAttnNotVerified(1))), findsOneWidget);
    expect(inKey('team-stat-members', find.text('3')), findsOneWidget);
    expect(inKey('team-stat-crates', find.text('1')), findsOneWidget);

    // Newest first, each with its author: this account, as "You".
    expect(inKey('team-change-5', find.text(l10n.teamChangeMemberAddedAgain('bob@example.com', l10n.orchardRoleAdmin))),
        findsOneWidget);
    expect(inKey('team-change-4', find.text(l10n.teamChangeMemberRemoved('bob@example.com'))), findsOneWidget);
    expect(inKey('team-change-2', find.text(l10n.teamChangeMemberAdded('alice@example.com', 'Member'))),
        findsOneWidget);
    expect(inKey('team-change-1', find.text(l10n.teamChangeCreated)), findsOneWidget);
    expect(inKey('team-change-1', find.textContaining(l10n.teamYou)), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const ValueKey('team-change-5'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('team-change-1'))).dy));

    // An owner sees every page, and the Overview counts what needs them.
    for (final p in TeamPage.values) {
      expect(find.byKey(ValueKey('team-nav-${p.name}')), findsOneWidget, reason: p.name);
    }
    // The badge counts what the Overview lists, the only owner too (it left
    // that out before a design review).
    expect(inKey('team-attention-title', find.text('3')), findsOneWidget);
    expect(inKey('team-nav-overview', find.text('3')), findsOneWidget);
    // Rename is on Team settings now (4.0), its link at the top.
    expect(find.byKey(const ValueKey('team-rename')), findsNothing);
    expect(find.byKey(const ValueKey('team-settings-open')), findsOneWidget);
    expect(find.byKey(const ValueKey('team-invite')), findsOneWidget);

    // "Add a second owner" goes to Members, whose Invite is the page's.
    await tester.tap(find.byKey(const ValueKey('team-callout-action')));
    await settle(tester);
    expect(find.byKey(const ValueKey('orchard-invites')), findsOneWidget);
    expect(find.byKey(const ValueKey('invite-someone')), findsNothing);
    // Nobody invited: no heading over an empty list.
    expect(find.text(l10n.orchardInvitesTitle), findsNothing);
    expect(find.byKey(const ValueKey('team-invite')), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a page scrolled under its header is cut by a rule; at its top there is none', (tester) async {
    await setUpOrchard(tester);
    await pumpTeam(tester);
    tester.view.physicalSize = const Size(1400, 520);
    await settle(tester);
    Color rule() => tester.widget<Container>(find.byKey(const ValueKey('team-header-rule'))).color!;
    expect(rule(), Colors.transparent);
    final page = find.descendant(of: find.byType(TeamView), matching: find.byType(SingleChildScrollView)).first;
    await tester.drag(page, const Offset(0, -200));
    await settle(tester);
    // Cards slid under the header with nothing between (a design
    // review).
    expect(rule(), isNot(Colors.transparent));
    await tester.drag(page, const Offset(0, 400));
    await settle(tester);
    expect(rule(), Colors.transparent);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a certificate authority that needs a new key: on the Overview for owners, counted, opened', (tester) async {
    await setUpOrchard(tester);
    final production = summary.crates.single.id;
    await pumpTeam(tester, extra: [
      crateAuthoritiesProvider(summary.id).overrideWith((ref) async => {
            production: CrateAuthorityView(
              crateId: production,
              on: true,
              generation: 1,
              ttlMinutes: 1440,
              principals: const {
                'owner': ['root'],
              },
              keyCrate: 'vault',
              publicKeys: {1: Uint8List(32)},
              newKeyNeeded: true,
            ),
          }),
    ]);
    expect(inKey('team-attn-authority-$production', find.text(l10n.teamAttnAuthorityNewKey('Production'))),
        findsOneWidget);
    expect(inKey('team-nav-overview', find.text('4')), findsOneWidget, reason: 'counted with the rest, the only owner too');
    await tester.tap(inKey('team-attn-authority-$production', find.text(l10n.teamReview)));
    await settle(tester);
    expect(find.text(l10n.certDialogTitle('Production')), findsOneWidget);
    expect(find.byKey(const ValueKey('cert-editor-new-key-needed')), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets("what the company's directory asks for: on the Overview, counted, and opened on its own", (tester) async {
    await setUpOrchard(tester);
    final pending = [
      {'id': 1, 'kind': 'remove', 'email': 'alice@example.com', 'uid': 'alice', 'role': null},
      {'id': 2, 'kind': 'add', 'email': 'new@example.com', 'uid': null, 'role': 'admin'},
    ];
    final api = OrchardDirectoryApi(
      client: MockClient((request) async => http.Response(
          jsonEncode({'enabled': true, 'scim_url': 'https://api.test/scim/v2/o', 'last_contact': null,
            'groups': const [], 'pending': pending, 'held': const []}),
          200,
          headers: {'content-type': 'application/json'})),
      baseUrl: 'https://api.test/v1',
      bearer: () async => 't',
    );
    await pumpTeam(tester, extra: [orchardDirectoryApiProvider.overrideWithValue(api)]);
    expect(inKey('team-attn-directory', find.text(l10n.directoryAttention(2))), findsOneWidget);
    expect(inKey('team-nav-overview', find.text('4')), findsOneWidget, reason: 'the two before, the only owner, and this');

    await tester.tap(inKey('team-attn-directory', find.text(l10n.directoryReview)));
    await settle(tester);
    expect(find.byKey(const ValueKey('directory-change-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('directory-change-2')), findsOneWidget);
    expect(find.text(l10n.directoryTurnOff), findsNothing, reason: 'the queue alone');
    await tester.tap(find.text(l10n.close).last);
    await settle(tester);
  });

  testWidgets('Trust: every entry, its author and keys, and the head to compare', (tester) async {
    await setUpOrchard(tester);
    // The first entry as one kept before first-seen dates were noted.
    await tester.runAsync(() async => (await databases.open(summary.id))
        .customStatement('UPDATE orchard_record_entries SET first_seen = NULL WHERE seq = 1'));
    await pumpTeam(tester);
    await tester.tap(find.byKey(const ValueKey('team-see-all')));
    await settle(tester);

    expect(find.text(l10n.teamTrustChecked(5)), findsOneWidget);
    for (var seq = 1; seq <= 5; seq++) {
      expect(find.byKey(ValueKey('team-trust-$seq')), findsOneWidget);
    }
    expect(inKey('team-trust-3', find.text(l10n.teamTrustKeysVersion(1))), findsOneWidget);
    // When this device first saw each entry: today, bar the one kept before.
    expect(tester.widget<Text>(find.byKey(const ValueKey('team-trust-seen-5'))).data, l10n.teamSeenToday);
    expect(tester.widget<Text>(find.byKey(const ValueKey('team-trust-seen-1'))).data, l10n.teamSeenEarlier);
    final words = recordHeadWords(head);
    expect(words.split(' ').length, 6);
    expect(find.text(words), findsOneWidget);
  });

  testWidgets('a member sees no Roles or Sign-in, and no Rename or Invite', (tester) async {
    await setUpOrchard(tester);
    final member = OrchardSummary(
      id: summary.id,
      name: summary.name,
      role: memberRole,
      crates: summary.crates,
      defaultCrateId: summary.defaultCrateId,
    );
    await pumpTeam(tester, as: member);
    expect(find.byKey(const ValueKey('team-nav-roles')), findsNothing);
    expect(find.byKey(const ValueKey('team-nav-signIn')), findsNothing);
    expect(find.byKey(const ValueKey('team-nav-activity')), findsNothing, reason: 'owners read the activity');
    expect(find.byKey(const ValueKey('team-nav-crates')), findsOneWidget);
    expect(find.byKey(const ValueKey('team-rename')), findsNothing);
    expect(find.byKey(const ValueKey('team-invite')), findsNothing);
    expect(find.text(l10n.teamYouAreMember), findsOneWidget);
  });

  testWidgets('change these next: kept when someone lost access, listed until each is marked', (tester) async {
    await setUpOrchard(tester);
    ExposedKey key(String id, String label) => ExposedKey(
        id: id, label: label, username: 'deploy', authMethod: 'password', crateId: summary.defaultCrateId!, hosts: const []);
    await tester.runAsync(() => service.keepChangeNext(
          summary.id,
          'bob',
          OrchardExposure(reveal: [key('k-reveal', 'staging deploy key')], connect: [key('k-connect', 'api password')], closed: const {}),
        ));
    // Kept under the entry that removed Bob (the fourth), revealable first.
    final kept = (await tester.runAsync(() => service.changeNext(summary.id)))!;
    expect([for (final i in kept) (i.entrySeq, i.rank, i.keyId, i.couldReveal, i.done)], [
      (4, 1, 'k-reveal', true, false),
      (4, 2, 'k-connect', false, false),
    ]);
    // Kept again: nothing doubles.
    await tester.runAsync(() => service.keepChangeNext(
        summary.id, 'bob', OrchardExposure(reveal: [key('k-reveal', 'x')], connect: const [], closed: const {})));
    expect((await tester.runAsync(() => service.changeNext(summary.id)))!, hasLength(2));

    await pumpTeam(tester);
    expect(find.text(l10n.teamChangeNextTitle.toUpperCase()), findsOneWidget);
    expect(find.textContaining(l10n.teamChangeNextLeft(2, 2)), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const ValueKey('team-change-next-item-k-reveal'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('team-change-next-item-k-connect'))).dy));
    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('team-change-next-item-k-reveal')), matching: find.text(l10n.teamMarkChanged)));
    await settle(tester);
    expect(find.byKey(const ValueKey('team-change-next-item-k-reveal')), findsNothing);
    expect(find.textContaining(l10n.teamChangeNextLeft(1, 2)), findsOneWidget);
    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('team-change-next-item-k-connect')), matching: find.text(l10n.teamMarkChanged)));
    await settle(tester);
    expect(find.text(l10n.teamChangeNextTitle.toUpperCase()), findsNothing, reason: 'all marked: the list goes');
    expect(((await tester.runAsync(() => service.changeNext(summary.id)))!).every((i) => i.done), isTrue);
  });

  testWidgets("Members: a click opens the member's panel, and its actions are the list's", (tester) async {
    await setUpOrchard(tester);
    final c = await pumpTeam(tester);
    c.read(teamPageProvider.notifier).state = TeamPage.members;
    await settle(tester);
    expect(find.byKey(const ValueKey('member-panel-alice')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('member-alice')));
    await settle(tester);
    final panel = find.byKey(const ValueKey('member-panel-alice'));
    expect(panel, findsOneWidget);
    Finder inPanel(Finder f) => find.descendant(of: panel, matching: f);
    expect(inPanel(find.text('Member')), findsWidgets);
    expect(inPanel(find.text(l10n.memberPanelNever)), findsOneWidget);
    expect(inPanel(find.text(l10n.crateLevelUse)), findsOneWidget, reason: 'the first role uses Production');
    expect(inPanel(find.text(l10n.orchardMemberNotVerified)), findsOneWidget);

    // Compared from the panel: verified by you.
    await tester.tap(find.byKey(const ValueKey('member-panel-check')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.orchardVerifyMatch));
    await settle(tester);
    expect(inPanel(find.text(l10n.orchardMemberVerifiedByYou)), findsOneWidget);

    // What Suspend and Remove do, under the app's own section header in red
    // (a red heading in sans of its own).
    await tester.scrollUntilVisible(find.byKey(const ValueKey('member-panel-danger')), 200,
        scrollable: inPanel(find.byType(Scrollable)).first);
    expect(
        tester
            .widget<ZestSectionHeader>(
                inPanel(find.descendant(of: find.byKey(const ValueKey('member-panel-danger')), matching: find.byType(ZestSectionHeader))))
            .danger,
        isTrue);

    // Suspend from the footer goes through the same confirmation.
    await tester.tap(find.byKey(const ValueKey('member-panel-suspend')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.orchardSuspendTitle('alice@example.com')), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await tester.pumpAndSettle();

    // Your own row: your words, no changes to yourself beyond stepping down.
    await tester.tap(find.byKey(const ValueKey('member-owner-1')));
    await settle(tester);
    expect(find.descendant(of: find.byKey(const ValueKey('member-panel-owner-1')), matching: find.byKey(const ValueKey('my-fingerprint'))),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('member-panel-close')));
    await settle(tester);
    expect(find.byKey(const ValueKey('member-panel-owner-1')), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  // As designed: a name first with the address
  // under it, and the account's picture, or the initials where there is
  // none; recording mode masks both lines and shows no picture.
  testWidgets("Members: a member's name first, the address under it, and their picture", (tester) async {
    addTearDown(() => Redactor.instance.enabled = false);
    await setUpOrchard(tester, faces: true);
    final c = await pumpTeam(tester);
    c.read(teamPageProvider.notifier).state = TeamPage.members;
    await settle(tester);

    Finder inRow(String uid, Finder f) => find.descendant(of: find.byKey(ValueKey('member-$uid')), matching: f);
    const picture = ValueKey('team-face-picture');
    expect(inRow('alice', find.text('Alice Example')), findsOneWidget);
    expect(inRow('alice', find.textContaining('alice@example.com')), findsOneWidget);
    expect(inRow('alice', find.byKey(picture)), findsOneWidget);
    // (A picture that does not load, as none does in a test, shows the initials.)
    expect(inRow('alice', find.byType(TeamInitials)), findsOneWidget);
    // No name: the address alone, and the initials.
    expect(inRow('bob', find.text('bob@example.com')), findsOneWidget);
    expect(inRow('bob', find.byKey(picture)), findsNothing);
    expect(inRow('bob', find.byType(TeamInitials)), findsOneWidget);

    // Found by the name as well as by the address.
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('members-filter')), matching: find.byType(TextField)),
        'alice ex');
    await settle(tester);
    expect(find.byKey(const ValueKey('member-alice')), findsOneWidget);
    expect(find.byKey(const ValueKey('member-bob')), findsNothing);
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('members-filter')), matching: find.byType(TextField)),
        '');
    await settle(tester);

    // The panel: the name, the address under it, the picture.
    await tester.tap(find.byKey(const ValueKey('member-alice')));
    await settle(tester);
    final panel = find.byKey(const ValueKey('member-panel-alice'));
    expect(find.descendant(of: panel, matching: find.text('Alice Example')), findsOneWidget);
    expect(find.descendant(of: panel, matching: find.byKey(const ValueKey('member-panel-address'))), findsOneWidget);
    expect(find.descendant(of: panel, matching: find.byKey(picture)), findsOneWidget);

    // Recording mode: both lines masked, no picture anywhere.
    Redactor.instance.enabled = true;
    c.read(recordingModeProvider.notifier).state = true;
    await settle(tester);
    expect(find.textContaining('Alice Example'), findsNothing);
    expect(find.textContaining('alice@example.com'), findsNothing);
    expect(find.byKey(picture), findsNothing);
    expect(inRow('alice', find.byType(TeamInitials)), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets("Members: a member's panel left open is closed once the page is left, not opened again by itself",
      (tester) async {
    await setUpOrchard(tester);
    final c = await pumpTeam(tester);
    c.read(teamPageProvider.notifier).state = TeamPage.members;
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('member-alice')));
    await settle(tester);
    expect(find.byKey(const ValueKey('member-panel-alice')), findsOneWidget);

    // Another page, and back: the list, with no panel.
    c.read(teamPageProvider.notifier).state = TeamPage.overview;
    await settle(tester);
    c.read(teamPageProvider.notifier).state = TeamPage.members;
    await settle(tester);
    expect(find.byKey(const ValueKey('member-alice')), findsOneWidget);
    expect(find.byKey(const ValueKey('member-panel-alice')), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  test('first-seen dates read as today, yesterday, a weekday, then the date', () {
    final now = DateTime(2026, 9, 25, 9);
    String label(DateTime? d) => teamSeenLabel(d, l10n, 'en', now);
    expect(label(null), l10n.teamSeenEarlier);
    expect(label(DateTime(2026, 9, 25, 0, 5)), l10n.teamSeenToday);
    expect(label(DateTime(2026, 9, 24, 23, 59)), l10n.teamSeenYesterday);
    expect(label(DateTime(2026, 9, 21)), 'Monday');
    expect(label(DateTime(2026, 9, 18)), 'Sep 18');
    expect(label(DateTime(2025, 12, 31)), 'Dec 31, 2025');
    // A date ahead of this device's clock still reads as today.
    expect(label(DateTime(2026, 9, 26)), l10n.teamSeenToday);
  });

  test('which pages an Orchard offers', () {
    OrchardSummary o({String role = FixedRoles.owner, String status = 'active', String? problem}) => OrchardSummary(
          id: 'o',
          name: 'Acme',
          role: role,
          crates: const [],
          defaultCrateId: null,
          status: status,
          recordProblem: problem,
        );
    expect(teamPagesFor(o()), TeamPage.values);
    // Everyone whose membership counts sees the seats; owners buy them.
    // The setup file is for those who run the Orchard: owners and admins.
    expect(teamPagesFor(o(role: FixedRoles.admin)), [
      TeamPage.overview,
      TeamPage.members,
      TeamPage.seats,
      TeamPage.crates,
      TeamPage.rules,
      TeamPage.setup,
      TeamPage.trust,
      TeamPage.settings,
    ]);
    expect(teamPagesFor(o(role: 'a-role-the-owners-made')),
        [TeamPage.overview, TeamPage.members, TeamPage.seats, TeamPage.crates, TeamPage.rules, TeamPage.trust]);
    // Held back by a rule: the rules to read, nothing to manage.
    expect(teamPagesFor(o(status: 'rules')), [TeamPage.overview, TeamPage.members, TeamPage.rules, TeamPage.trust]);
    expect(teamPagesFor(o(status: 'suspended')), [TeamPage.overview, TeamPage.members, TeamPage.trust]);
    expect(teamPagesFor(o(problem: 'forked')), [TeamPage.overview, TeamPage.members, TeamPage.trust]);
  });

  testWidgets('leaving the Orchard for the Tree while on Team goes back to Hosts', (tester) async {
    final container = ProviderContainer(overrides: [
      activeOrchardProvider.overrideWithValue(const AsyncData(null)),
    ]);
    addTearDown(container.dispose);
    container.read(activeSidebarNavProvider.notifier).state = NavSection.team;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: TeamView())),
    ));
    await tester.pump();
    expect(container.read(activeSidebarNavProvider), NavSection.hosts);
  });

  testWidgets('an Orchard closed by its offline limit says so', (tester) async {
    final container = ProviderContainer(overrides: [
      activeOrchardProvider.overrideWithValue(AsyncData(OrchardSummary.closedOffline('o'))),
    ]);
    addTearDown(container.dispose);
    container.read(activeSidebarNavProvider.notifier).state = NavSection.team;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: TeamView()),
      ),
    ));
    await tester.pump();
    expect(find.byKey(const ValueKey('team-closed-offline')), findsOneWidget);
    expect(container.read(activeSidebarNavProvider), NavSection.team);
  });

  // "Connect to the internet to open it again" sends someone looking for a
  // fault of their own when the service is the one that cannot be reached
  // (3.0).
  group('an Orchard closed by its offline limit, and how ZestSSH Cloud stands', () {
    final en = lookupAppLocalizations(const Locale('en'));

    /// The app's knowledge of the service after its check met [met] and the
    /// status service said [said] (null: it gave no statement).
    CloudReachService reachAfter(Object met, CloudStatement? said, {bool withStatus = true}) {
      final reach = CloudReachService(
        check: () async => met is int ? met : throw met,
        status: withStatus ? () async => said : null,
        timer: (wait, then) => Timer(const Duration(days: 1), () {}),
      );
      addTearDown(reach.dispose);
      return reach;
    }

    const at = 1791474000;
    const down = CloudStatement(down: true, at: at, until: at + 900, since: at - 3600, keyId: 'k1');
    const up = CloudStatement(down: false, at: at, until: at + 900, since: 0, keyId: 'k1');
    const refused = SocketException('Connection refused');

    Future<void> show(WidgetTester tester, CloudReachService reach, {required bool phone}) async {
      final container = ProviderContainer(overrides: [
        activeOrchardProvider.overrideWithValue(AsyncData(OrchardSummary.closedOffline('o'))),
        cloudReachProvider.overrideWithValue(reach),
      ]);
      addTearDown(container.dispose);
      container.read(activeSidebarNavProvider.notifier).state = NavSection.team;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: phone ? const TeamPhoneScreen() : const Scaffold(body: TeamView()),
        ),
      ));
      await tester.pump();
    }

    String shown(WidgetTester tester, {required bool phone}) => tester
        .widget<Text>(find.byKey(ValueKey(phone ? 'team-phone-closed-offline' : 'team-closed-offline')))
        .data!;

    for (final phone in [false, true]) {
      final where = phone ? 'on a phone' : 'on a computer';

      testWidgets('$where: nothing known of the service, it says to connect to the internet', (tester) async {
        await show(tester, reachAfter(200, null), phone: phone);
        expect(shown(tester, phone: phone), en.orchardClosedOfflineError);
      });

      testWidgets('$where: the service down, it says that nothing needs doing, and says it when that turns out',
          (tester) async {
        final reach = reachAfter(refused, down);
        await show(tester, reach, phone: phone);
        expect(shown(tester, phone: phone), en.orchardClosedOfflineError, reason: 'not yet known');
        await tester.runAsync(() => reach.checkNow());
        await tester.pump();
        await tester.pump();
        expect(reach.state.value.reach, CloudReach.down);
        expect(shown(tester, phone: phone), en.orchardClosedOfflineCloud);
        expect(shown(tester, phone: phone), isNot(contains('Connect to the internet')));
      });

      testWidgets('$where: the device offline, it says to connect to the internet', (tester) async {
        final reach = reachAfter(refused, down)..networkChanged(up: false);
        await show(tester, reach, phone: phone);
        await tester.runAsync(() => reach.checkNow());
        await tester.pump();
        await tester.pump();
        expect(reach.state.value.reach, CloudReach.deviceOffline);
        expect(shown(tester, phone: phone), en.orchardClosedOfflineError);
      });
    }

    test('which of the two it is, for each way the service can stand', () {
      String of(CloudReach? reach) => orchardClosedOfflineText(en, reach);
      for (final reach in [CloudReach.down, CloudReach.notResponding, CloudReach.fault]) {
        expect(of(reach), en.orchardClosedOfflineCloud, reason: '$reach: ours, and nothing for the person to do');
      }
      for (final reach in <CloudReach?>[
        null,
        CloudReach.unknown,
        CloudReach.answering,
        CloudReach.deviceOffline,
        CloudReach.nothingReached,
        CloudReach.blocked,
        CloudReach.notSecure,
      ]) {
        expect(of(reach), en.orchardClosedOfflineError, reason: '$reach: something on this side to see to');
      }
      expect(en.orchardClosedOfflineCloud, contains('Nothing needs doing on this device'));
      expect(en.orchardClosedOfflineCloud, contains('opens again by itself'));
    });

    test('a message about a closed Orchard says the same, from what the app knows', () async {
      expect(orchardErrorMessage(const OrchardClosedOffline('o'), en), en.orchardClosedOfflineError);
      final reach = reachAfter(503, down);
      currentCloudReach = reach;
      addTearDown(() => currentCloudReach = null);
      await reach.checkNow();
      expect(orchardErrorMessage(const OrchardClosedOffline('o'), en), en.orchardClosedOfflineCloud);
      final blocked = reachAfter(refused, up);
      currentCloudReach = blocked;
      await blocked.checkNow();
      expect(orchardErrorMessage(const OrchardClosedOffline('o'), en), en.orchardClosedOfflineError);
    });
  });

  testWidgets('openTeamPage opens the page asked for', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    late WidgetRef captured;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Consumer(builder: (context, ref, _) {
        captured = ref;
        return const SizedBox();
      })),
    ));
    expect(openTeamPage(captured, TeamPage.rules), isTrue);
    expect(container.read(activeSidebarNavProvider), NavSection.team);
    expect(container.read(teamPageProvider), TeamPage.rules);
  });
  /// The Team on a phone (3.0): More, Team opens the page list
  /// at /team, and each page at /team/<page>.
  Future<GlobalKey> pumpTeamPhone(WidgetTester tester, {String themeId = 'default_dark'}) async {
    final theme = BuiltInThemes.getById(themeId);
    AppColors.applyTheme(theme.colorScheme);
    addTearDown(() => AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme));
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      orchardServiceProvider.overrideWithValue(service),
      orchardDatabasesProvider.overrideWith((ref) => databases),
      activeOrchardProvider.overrideWithValue(AsyncData(summary)),
      orchardSummariesProvider.overrideWith((ref) async => [summary]),
      connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
      deviceLockProvider.overrideWith((ref) async => (on: true, minutes: 5)),
      recordingModeProvider.overrideWith((ref) => false),
      recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
    ]);
    addTearDown(container.dispose);
    final router = GoRouter(initialLocation: Routes.team, routes: [
      GoRoute(path: '/', builder: (_, _) => const Scaffold(body: Text('home'))),
      GoRoute(path: Routes.team, builder: (_, _) => const TeamPhoneScreen()),
      GoRoute(
        path: Routes.teamPage,
        builder: (_, state) => TeamPhonePageScreen(
          page: TeamPage.values.firstWhere((p) => p.name == state.pathParameters['page']),
        ),
      ),
    ]);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: theme.toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          routerConfig: router,
        ),
      ),
    ));
    await settle(tester);
    return key;
  }

  testWidgets('on a phone: the pages as a list, each full screen, links between them followed', (tester) async {
    // A phone: dialogs open as sheets there.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await setUpOrchard(tester);
    await pumpTeamPhone(tester);
    for (final p in TeamPage.values) {
      expect(find.byKey(ValueKey('team-phone-${p.name}')), findsOneWidget, reason: p.name);
    }
    expect(find.text(l10n.teamYouAreOwner), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('team-phone-overview')));
    await settle(tester);
    expect(find.byKey(const ValueKey('team-sole-owner')), findsOneWidget);
    expect(find.byKey(const ValueKey('team-settings-open')), findsOneWidget);
    expect(find.byKey(const ValueKey('team-invite')), findsOneWidget);
    // "Add a second owner" opens Members, on top.
    await tester.ensureVisible(find.byKey(const ValueKey('team-callout-action')));
    await tester.tap(find.byKey(const ValueKey('team-callout-action')));
    await settle(tester);
    expect(find.text('alice@example.com'), findsWidgets);
    // One list on a phone: a tap compares codes with them, as in the
    // dialog; the desktop's side panel never opens.
    await tester.tap(find.byKey(const ValueKey('member-alice')));
    await settle(tester);
    expect(find.byKey(const ValueKey('member-panel-alice')), findsNothing);
    expect(find.byType(CompareCodes), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    await tester.pump(const Duration(seconds: 5));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('on a phone, every page fits: nothing drawn past its edge', (tester) async {
    // A phone: dialogs open as sheets there.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await setUpOrchard(tester);
    await pumpTeamPhone(tester);
    for (final page in TeamPage.values) {
      await tester.tap(find.byKey(ValueKey('team-phone-${page.name}')));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(TeamPhonePageScreen), findsOneWidget, reason: page.name);
      expect(tester.takeException(), isNull, reason: page.name);
      GoRouter.of(tester.element(find.byType(TeamPhonePageScreen))).pop();
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
    }
    await tester.pump(const Duration(seconds: 5));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('on a phone, a member sees no Roles or Sign-in', (tester) async {
    // A phone: dialogs open as sheets there.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await setUpOrchard(tester);
    summary = OrchardSummary(
      id: summary.id,
      name: summary.name,
      role: memberRole,
      crates: summary.crates,
      defaultCrateId: summary.defaultCrateId,
    );
    await pumpTeamPhone(tester);
    expect(find.byKey(const ValueKey('team-phone-roles')), findsNothing);
    expect(find.byKey(const ValueKey('team-phone-signIn')), findsNothing);
    expect(find.byKey(const ValueKey('team-phone-members')), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    debugDefaultTargetPlatformOverride = null;
  });

  // Pictures of the Team pages, drawn with the real fonts (see
  // test/visual/shots_util.dart); off unless asked for.
  for (final themeId in ['default_dark', 'default_light']) {
    testWidgets('pictures of the Team on a phone, $themeId', (tester) async {
      await tester.runAsync(loadShotFonts);
      realShadows();
      await setUpOrchard(tester);
      final key = await pumpTeamPhone(tester, themeId: themeId);
      await saveShot(tester, key, 'phone-team-$themeId', pixelRatio: 2);
      for (final page in [TeamPage.overview, TeamPage.members, TeamPage.trust]) {
        await tester.tap(find.byKey(ValueKey('team-phone-${page.name}')));
        await settle(tester);
        await tester.pump(const Duration(milliseconds: 400));
        // A tall screen, to see the whole page.
        tester.view.physicalSize = const Size(390, 1700);
        await settle(tester);
        await saveShot(tester, key, 'phone-team-${page.name}-$themeId', pixelRatio: 2);
        tester.view.physicalSize = const Size(390, 844);
        GoRouter.of(tester.element(find.byType(TeamPhonePageScreen))).pop();
        await settle(tester);
        await tester.pump(const Duration(milliseconds: 400));
      }
      plainShadows();
      await tester.pump(const Duration(seconds: 5));
    }, skip: !shotsEnabled);

    testWidgets('pictures of the Team pages, $themeId', (tester) async {
      await tester.runAsync(loadShotFonts);
      await setUpOrchard(tester);
      ExposedKey exposed(String id, String label) => ExposedKey(
          id: id, label: label, username: 'deploy', authMethod: 'password', crateId: summary.defaultCrateId!, hosts: const []);
      await tester.runAsync(() => service.keepChangeNext(
            summary.id,
            'bob',
            OrchardExposure(
              reveal: [exposed('k1', 'staging deploy key')],
              connect: [exposed('k2', 'web-01 password')],
              closed: const {},
            ),
          ));
      final theme = BuiltInThemes.getById(themeId);
      AppColors.applyTheme(theme.colorScheme);
      addTearDown(() => AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme));
      tester.view.physicalSize = const Size(1240, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      final container = ProviderContainer(overrides: [
        orchardServiceProvider.overrideWithValue(service),
        orchardDatabasesProvider.overrideWith((ref) => databases),
        activeOrchardProvider.overrideWithValue(AsyncData(summary)),
        orchardSummariesProvider.overrideWith((ref) async => [summary]),
        connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
        deviceLockProvider.overrideWith((ref) async => (on: true, minutes: 5)),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ]);
      addTearDown(container.dispose);
      container.read(activeSidebarNavProvider.notifier).state = NavSection.team;
      await tester.pumpWidget(RepaintBoundary(
        key: key,
        child: UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme.toThemeData(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Scaffold(backgroundColor: ZestColors.bgContent, body: const TeamView()),
          ),
        ),
      ));
      await settle(tester);
      await saveShot(tester, key, 'team-overview-$themeId');
      for (final page in [TeamPage.trust, TeamPage.members]) {
        container.read(teamPageProvider.notifier).state = page;
        await settle(tester);
        await saveShot(tester, key, 'team-${page.name}-$themeId');
      }
      // Alice's panel: her role, access and verification.
      await tester.tap(find.byKey(const ValueKey('member-alice')));
      await settle(tester);
      await saveShot(tester, key, 'team-member-panel-$themeId');
      // Comparing codes with Alice from her panel: both lists side by side.
      await tester.tap(find.byKey(const ValueKey('member-panel-check')));
      await tester.pumpAndSettle();
      await saveShot(tester, key, 'team-compare-$themeId');
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
      // "Confirm it's you", saying what a suspension does.
      unawaited(confirmItsYou(tester.element(find.byType(TeamView)), (
        what: l10n.stepUpSuspend('bob@example.com', 'Acme Orchard'),
        effects: [l10n.stepUpEffectCutOff('bob@example.com'), l10n.stepUpEffectKeysReplaced],
      )));
      await tester.pumpAndSettle();
      await saveShot(tester, key, 'team-stepup-$themeId');
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
    }, skip: !shotsEnabled);
  }
}

/// Lets the database and crypto work finish (checking the record's
/// signatures takes a moment of real time), then the frames.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
    if (i >= 2 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pump(const Duration(milliseconds: 300));
}
