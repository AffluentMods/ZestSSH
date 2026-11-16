import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/team/team_overview.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/team/team_view.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/desktop_providers.dart';

import 'roles_vaults_fixture.dart';

/// The Team area's Overview, Members and list of pages on a computer (3.0
/// UI), on a real record: the four
/// cards count what the record and the hosts say and open their pages; what
/// needs attention does what it did (turning away withdraws the invitation,
/// Review opens the review beside the Members list, where letting in adds
/// them); Members lists who waits, who is invited and the members, filtered;
/// the list of pages is grouped as designed, and a member sees no
/// Roles or Sign-in.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  Finder key(String k) => find.byKey(ValueKey(k));
  Finder inKey(String k, Finder f) => find.descendant(of: key(k), matching: f);

  group('Overview', () {
    // The Hosts card's line: one line,
    // as many vaults whole as fit, "+N" for the rest, so the four cards stay
    // level. Ten pixels a letter in the test's font.
    testWidgets('one line of parts: all where they fit, else the first ones and "+N", the first cut only alone',
        (tester) async {
      const parts = ['Shared 6', 'Production 4', 'Recovery 2'];
      Future<void> pump(double width) => tester.pumpWidget(MaterialApp(
            home: Center(
              child: SizedBox(
                width: width,
                // Made as tall as the tallest beside it, as the four cards are.
                child: const IntrinsicHeight(
                  child: Row(children: [
                    Expanded(child: OneLineParts(parts: parts, style: TextStyle(fontSize: 10))),
                  ]),
                ),
              ),
            ),
          ));
      String shown() => tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).join();

      await pump(400);
      expect(shown(), 'Shared 6 · Production 4 · Recovery 2');
      expect(tester.getSize(find.byType(OneLineParts)).height, 10, reason: 'one line high');
      await pump(300);
      expect(shown(), 'Shared 6 · Production 4 · +1');
      await pump(150);
      expect(shown(), 'Shared 6 · +2');
      // Not even the first fits: it is cut, and "+2" still stands.
      await pump(100);
      expect(find.text(' · +2'), findsOneWidget);
      expect(tester.widget<Text>(find.text('Shared 6')).overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
    });

    testWidgets('At a glance counts members, who waits, vaults, hosts by vault and rules, and opens their pages',
        (tester) async {
      final team = await buildRolesVaultsTeam(tester, samByCode: true);
      await tester.runAsync(() async {
        await team.service.setRules(team.orchardId, const RecordRules(require2fa: true, requireAppLock: true));
        await team.service.refresh();
      });
      final shown = await pumpRolesVaults(tester, team, page: TeamPage.overview);
      // Alex and Jordan; Sam (his code used) and Priya (invited) waiting.
      expect(inKey('team-stat-members', find.text('2')), findsOneWidget);
      expect(inKey('team-stat-members', find.text(l10n.teamStatJoining(2))), findsOneWidget);
      // Shared, Production and Recovery, the last for owners only.
      expect(inKey('team-stat-crates', find.text('3')), findsOneWidget);
      expect(inKey('team-stat-crates', find.text(l10n.teamStatOwnersOnly(1))), findsOneWidget);
      // Twelve hosts: the team's first vault first, then by name, every one
      // whole (4.0: At a glance's line wraps where it must; it was cut to
      // "+N").
      expect(inKey('team-stat-hosts', find.text('12')), findsOneWidget);
      expect(inKey('team-stat-hosts', find.text('Shared\u00a06 · Production\u00a04 · Recovery\u00a02')), findsOneWidget);
      // Two rules, by name.
      expect(inKey('team-stat-rules', find.text('2')), findsOneWidget);
      expect(
          inKey('team-stat-rules',
              find.text([l10n.orchardRulesTwoStep, l10n.orchardRulesAppLock].join(l10n.listSeparator))),
          findsOneWidget);

      for (final (stat, page) in [
        ('team-stat-members', TeamPage.members),
        ('team-stat-crates', TeamPage.crates),
        ('team-stat-rules', TeamPage.rules),
      ]) {
        shown.container.read(teamPageProvider.notifier).state = TeamPage.overview;
        await settleTeam(tester);
        await tester.tap(key(stat));
        await settleTeam(tester);
        expect(shown.container.read(teamPageProvider), page, reason: stat);
      }
      shown.container.read(teamPageProvider.notifier).state = TeamPage.overview;
      await settleTeam(tester);
      await tester.tap(key('team-stat-hosts'));
      await settleTeam(tester);
      expect(shown.container.read(activeSidebarNavProvider), NavSection.hosts, reason: 'the hosts are on the Hosts page');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('needs attention: the used code, the only owner; access for a set time with the time left',
        (tester) async {
      final team = await buildRolesVaultsTeam(tester, samByCode: true);
      // The page reads the clock when it is drawn, so the time left it shows
      // is the one of a moment between here and when it is looked at.
      final drawnFrom = DateTime.now();
      final shown = await pumpRolesVaults(tester, team, page: TeamPage.overview);
      final code = 'team-attn-code-${team.samInvite}';
      expect(inKey(code, find.text(l10n.attnCodeUsed('sam'))), findsOneWidget);
      expect(key('team-sole-owner'), findsOneWidget);
      expect(inKey('team-sole-owner', find.text(l10n.teamAttnSoleOwner)), findsOneWidget);
      expect(inKey('team-attention-title', find.text('2')), findsOneWidget, reason: 'the code and the only owner');
      // Jordan holds Production at Connect for two hours.
      final timed = 'team-access-timed-${RolesVaultsTeam.jordan}-${team.production}';
      expect(inKey(timed, find.text('jordan@example.com · Production')), findsOneWidget);
      final until = team.server.recordOf(team.orchardId).members[RolesVaultsTeam.jordan]!.timed[team.production]!.until;
      final left = {accessLeftText(until, l10n, now: drawnFrom), accessLeftText(until, l10n)};
      expect(inKey(timed, find.byWidgetPredicate((w) => w is Text && left.contains(w.data))), findsOneWidget,
          reason: 'one of $left');
      expect(inKey(timed, find.text(l10n.accessEndNow)), findsOneWidget);
      expect(key('team-access-give'), findsOneWidget, reason: 'beside the title');
      expect(inKey('team-see-all', find.text(l10n.teamSeeAllInTrust)), findsOneWidget);

      // Add a second owner: to Members.
      await tester.tap(key('team-callout-action'));
      await settleTeam(tester);
      expect(shown.container.read(teamPageProvider), TeamPage.members);

      // Review: the review beside the Members list.
      shown.container.read(teamPageProvider.notifier).state = TeamPage.overview;
      await settleTeam(tester);
      await tester.tap(key('attn-review-${team.samInvite}'));
      await settleTeam(tester);
      expect(shown.container.read(teamPageProvider), TeamPage.members);
      expect(key('review-panel-${team.samInvite}'), findsOneWidget);
      expect(key('review-keys-checked'), findsOneWidget, reason: 'his code checked his keys');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('Turn away withdraws the invitation the code made', (tester) async {
      final team = await buildRolesVaultsTeam(tester, samByCode: true);
      await pumpRolesVaults(tester, team, page: TeamPage.overview);
      await tester.tap(key('attn-turn-away-${team.samInvite}'));
      await settleTeam(tester);
      expect(team.server.withdrawn, [team.samInvite]);
      expect(key('team-attn-code-${team.samInvite}'), findsNothing);
      expect(team.server.recordOf(team.orchardId).members.containsKey('uid-sam'), isFalse);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('Members', () {
    testWidgets('who waits, who is invited and the members, each counted; the filter and Waiting narrow them',
        (tester) async {
      final team = await buildRolesVaultsTeam(tester, samByCode: true);
      await pumpRolesVaults(tester, team, page: TeamPage.members);
      expect(inKey('invites-waiting-title', find.text('1')), findsOneWidget);
      expect(inKey('invites-invited-title', find.text('1')), findsOneWidget);
      expect(inKey('members-title', find.text('2')), findsOneWidget);
      expect(inKey('invite-${team.samInvite}', find.text(l10n.keysCheckedPill)), findsOneWidget);
      expect(key('member-${RolesVaultsTeam.owner}'), findsOneWidget);
      // Jordan's Production for a while, on his row.
      expect(key('member-timed-${RolesVaultsTeam.jordan}-${team.production}'), findsOneWidget);
      expect(find.text(l10n.teamFilterAll(4)), findsOneWidget);
      expect(find.text(l10n.teamFilterWaiting(2)), findsOneWidget);

      // The filter: by address.
      await tester.enterText(find.descendant(of: key('members-filter'), matching: find.byType(EditableText)), 'jor');
      await settleTeam(tester);
      expect(key('member-${RolesVaultsTeam.jordan}'), findsOneWidget);
      expect(key('member-${RolesVaultsTeam.owner}'), findsNothing);
      expect(key('invite-${team.samInvite}'), findsNothing);
      expect(key('invites-invited-title'), findsNothing);
      await tester.enterText(find.descendant(of: key('members-filter'), matching: find.byType(EditableText)), 'nobody');
      await settleTeam(tester);
      expect(key('members-no-match'), findsOneWidget);
      await tester.enterText(find.descendant(of: key('members-filter'), matching: find.byType(EditableText)), '');
      await settleTeam(tester);

      // Waiting: the invitations alone.
      await tester.tap(find.text(l10n.teamFilterWaiting(2)));
      await settleTeam(tester);
      expect(key('invite-${team.samInvite}'), findsOneWidget);
      expect(key('members-title'), findsNothing);
      expect(key('member-${RolesVaultsTeam.jordan}'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('someone who used a code while the page was open shows as waiting, though nothing told the page',
        (tester) async {
      // The Members page kept the list from before, and listed the used code
      // as unused with nothing to review, while Seats (read fresh) said he
      // waited.
      final team = await buildRolesVaultsTeam(tester);
      await pumpRolesVaults(tester, team, page: TeamPage.members);
      expect(key('invites-waiting-title'), findsNothing);
      await tester.runAsync(() => samUsesACode(team));
      // No version bumped, no word from the server: the page reads again on its own.
      await tester.pump(const Duration(seconds: 31));
      await settleTeam(tester);
      expect(inKey('invites-waiting-title', find.text('1')), findsOneWidget);
      expect(key('invite-${team.samInvite}'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('who waits is a banner at the top, whose Review opens the review; none once it is open',
        (tester) async {
      final team = await buildRolesVaultsTeam(tester, samByCode: true);
      final shown = await pumpRolesVaults(tester, team, page: TeamPage.members);
      expect(key('members-waiting-banner'), findsOneWidget);
      expect(inKey('members-waiting-banner', find.textContaining('sam')), findsOneWidget);
      // Above the filter: the first thing on the page.
      expect(tester.getTopLeft(key('members-waiting-banner')).dy,
          lessThan(tester.getTopLeft(key('members-filter')).dy));
      await tester.tap(key('members-waiting-review'));
      await settleTeam(tester);
      expect(shown.container.read(teamReviewPanelProvider(team.orchardId)), team.samInvite);
      expect(key('review-panel-${team.samInvite}'), findsOneWidget);
      expect(key('members-waiting-banner'), findsNothing, reason: 'the review beside the list says it now');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('nobody waiting: no banner', (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      await pumpRolesVaults(tester, team, page: TeamPage.members);
      expect(key('members-waiting-banner'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('the review opens beside the list in place of a member, and Let in adds him', (tester) async {
      final team = await buildRolesVaultsTeam(tester, samByCode: true);
      final shown = await pumpRolesVaults(tester, team, page: TeamPage.members);
      await tester.tap(key('member-${RolesVaultsTeam.jordan}'));
      await settleTeam(tester);
      expect(key('member-panel-${RolesVaultsTeam.jordan}'), findsOneWidget);

      await tester.tap(key('invite-${team.samInvite}'));
      await settleTeam(tester);
      expect(key('review-panel-${team.samInvite}'), findsOneWidget);
      expect(key('member-panel-${RolesVaultsTeam.jordan}'), findsNothing, reason: 'one panel at a time');
      expect(shown.container.read(teamReviewPanelProvider(team.orchardId)), team.samInvite);

      await tester.tap(key('review-let-in'));
      await settleTeam(tester);
      expect(team.server.confirmations.last.inviteId, team.samInvite, reason: 'after Jordan, when the team was made');
      expect(team.server.recordOf(team.orchardId).members.containsKey('uid-sam'), isTrue);
      expect(key('review-panel-${team.samInvite}'), findsNothing, reason: 'closed once he is in');
      expect(key('member-uid-sam'), findsOneWidget, reason: 'listed with the members');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('Resend and Send a code instead stay on an invitation; withdrawing is in its menu', (tester) async {
      final team = await buildRolesVaultsTeam(tester, samByCode: true);
      await pumpRolesVaults(tester, team, page: TeamPage.members);
      final priya = (await tester.runAsync(() => team.service.invites(team.orchardId)))!
          .singleWhere((i) => i.email == 'priya@example.com')
          .id;
      expect(key('invite-resend-$priya'), findsOneWidget);
      expect(tester.widget(key('invite-resend-$priya')).runtimeType, tester.widget(key('invite-code-instead-$priya')).runtimeType,
          reason: 'side by side, one kind of button');
      expect(key('invite-code-instead-$priya'), findsOneWidget);
      await tester.tap(key('invite-resend-$priya'));
      await settleTeam(tester);
      expect(team.server.resent, ['priya@example.com']);
      await tester.tap(key('invite-more-$priya'));
      await settleTeam(tester);
      await tester.tap(key('invite-withdraw-$priya'));
      await settleTeam(tester);
      expect(team.server.withdrawn, [priya]);
      expect(key('invite-$priya'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });
    testWidgets('Invited: tick several, or all, and withdraw them together after asking', (tester) async {
      final team = await buildRolesVaultsTeam(tester, samByCode: true);
      await tester.runAsync(() async {
        await team.service.invite(team.orchardId, email: 'riley@example.com', role: team.member);
        await team.service.invite(team.orchardId, email: 'casey@example.com', role: team.member);
      });
      await pumpRolesVaults(tester, team, page: TeamPage.members);
      final ids = {
        for (final i in (await tester.runAsync(() => team.service.invites(team.orchardId)))!)
          if (i.email.isNotEmpty && !i.accepted) i.email: i.id,
      };
      expect(key('invites-picked-bar'), findsOneWidget);
      expect(key('invites-withdraw-picked'), findsNothing, reason: 'nothing ticked yet');
      await tester.tap(key('invite-pick-${ids['riley@example.com']}'));
      await tester.tap(key('invite-pick-${ids['casey@example.com']}'));
      await settleTeam(tester);
      expect(find.text(l10n.invitesSelected(2)), findsOneWidget);
      await tester.tap(key('invites-withdraw-picked'));
      await settleTeam(tester);
      expect(find.text(l10n.invitesWithdrawTitle(2)), findsOneWidget);
      await tester.tap(find.text(l10n.invitesWithdrawN(2)).last);
      await settleTeam(tester);
      expect(team.server.withdrawn.toSet(), {ids['riley@example.com'], ids['casey@example.com']});
      expect(key('invite-${ids['riley@example.com']}'), findsNothing);
      expect(key('invite-${ids['priya@example.com']}'), findsOneWidget, reason: 'one not ticked stays');
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('The list of pages', () {
    testWidgets('Overview alone, then People, Access and Records, the setup file at the foot', (tester) async {
      final team = await buildRolesVaultsTeam(tester, samByCode: true);
      await pumpRolesVaults(tester, team, page: TeamPage.overview);
      double top(String k) => tester.getTopLeft(key(k)).dy;
      final order = [
        'team-nav-overview',
        'team-nav-group-people',
        'team-nav-members',
        'team-nav-roles',
        'team-nav-seats',
        'team-nav-group-access',
        'team-nav-crates',
        'team-nav-rules',
        'team-nav-signIn',
        'team-nav-group-records',
        'team-nav-activity',
        'team-nav-trust',
        'team-nav-settings',
        'team-nav-setup',
      ];
      for (var i = 1; i < order.length; i++) {
        expect(top(order[i]), greaterThan(top(order[i - 1])), reason: '${order[i - 1]} above ${order[i]}');
      }
      expect(inKey('team-nav-group-access', find.text(l10n.teamGroupAccess.toUpperCase())), findsOneWidget);
      // The setup file at the foot of the list.
      expect(top('team-nav-setup'), greaterThan(900 - 60));
      // Who waits to join, beside Members.
      expect(inKey('team-nav-members', find.text('2')), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a member sees no Roles, Sign-in, Activity or setup file', (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      final owner = (await tester.runAsync(team.summary))!;
      final member = OrchardSummary(
        id: owner.id,
        name: owner.name,
        role: team.member,
        can: const {},
        crates: owner.crates.where((c) => !c.ownersOnly).toList(),
        defaultCrateId: owner.defaultCrateId,
      );
      await pumpRolesVaults(tester, team, page: TeamPage.overview, as: member);
      for (final p in [TeamPage.roles, TeamPage.signIn, TeamPage.activity, TeamPage.setup]) {
        expect(key('team-nav-${p.name}'), findsNothing, reason: p.name);
      }
      for (final p in [TeamPage.overview, TeamPage.members, TeamPage.seats, TeamPage.crates, TeamPage.rules, TeamPage.trust]) {
        expect(key('team-nav-${p.name}'), findsOneWidget, reason: p.name);
      }
      expect(teamPagesFor(member), isNot(contains(TeamPage.roles)));
      // No Invite people for one who may not invite.
      expect(key('team-invite'), findsNothing);
      expect(TeamInitials.lettersOf('jordan.lee@example.com'), 'JL');
      expect(TeamInitials.lettersOf('alex@example.com'), 'AL');
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
