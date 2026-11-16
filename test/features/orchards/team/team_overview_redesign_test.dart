import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart' show newRecordKindsOn;
import 'package:zestssh/features/orchards/team/team_phone.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/utils/platform_utils.dart';

import 'roles_vaults_fixture.dart';

/// The Overview as the 4.0 design draws it, and the new Team
/// settings page:
/// Needs attention first; At a glance beside it on a computer and under it
/// on a phone; no Danger zone and no Rename on the Overview; Rename and
/// Delete team on Team settings, reached from the Overview's link and from
/// the team's list of pages.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  Finder key(String k) => find.byKey(ValueKey(k));
  Finder inKey(String k, Finder f) => find.descendant(of: key(k), matching: f);

  setUp(() => newRecordKindsOn.value = true);

  group('a computer', () {
    testWidgets('Needs attention first, At a glance on the right; no Danger zone, no Rename', (tester) async {
      final team = await buildRolesVaultsTeam(tester, samByCode: true);
      await pumpRolesVaults(tester, team, page: TeamPage.overview);
      final attention = tester.getRect(key('team-attention'));
      final glance = tester.getRect(key('team-glance'));
      final access = tester.getRect(key('team-access'));
      // What needs this account leads the page, its counts beside it.
      expect(attention.top, lessThan(access.top));
      expect(glance.left, greaterThan(attention.right));
      expect(glance.top, closeTo(tester.getRect(key('team-attention-title')).top, 1));
      expect(glance.width, closeTo(312, 1));
      // The rows say something and open their pages.
      expect(inKey('team-stat-members', find.text(l10n.teamStatJoining(2))), findsOneWidget);
      expect(inKey('team-stat-crates', find.text(l10n.teamStatOwnersOnly(1))), findsOneWidget);
      expect(inKey('team-stat-hosts', find.text('Shared\u00a06 · Production\u00a04 · Recovery\u00a02')), findsOneWidget);
      // Deleting and renaming are not everyday things.
      expect(key('team-delete-zone'), findsNothing);
      expect(key('team-delete'), findsNothing);
      expect(key('team-rename'), findsNothing);
      // One orange: Invite people (the theme's filled button).
      final filled = find.byWidgetPredicate((w) => w is FilledButton);
      expect(filled, findsOneWidget);
      expect(find.descendant(of: filled, matching: find.text(l10n.teamInvitePeople)), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('Team settings, from the Overview and from the list of pages: Rename and Delete team', (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      final shown = await pumpRolesVaults(tester, team, page: TeamPage.overview);
      expect(key('team-nav-settings'), findsOneWidget);
      // At the foot of the list, over the setup file.
      expect(tester.getTopLeft(key('team-nav-settings')).dy, lessThan(tester.getTopLeft(key('team-nav-setup')).dy));
      expect(tester.getTopLeft(key('team-nav-settings')).dy, greaterThan(tester.getTopLeft(key('team-nav-trust')).dy));
      await tester.tap(key('team-settings-open'));
      await settleTeam(tester);
      expect(shown.container.read(teamPageProvider), TeamPage.settings);
      expect(find.text(l10n.teamPageSettings), findsWidgets);
      expect(inKey('team-settings-name', find.text('Platform team')), findsOneWidget);
      expect(key('team-delete-zone'), findsOneWidget);
      expect(key('team-delete'), findsOneWidget);

      // Rename opens the rename window.
      await tester.tap(key('team-rename'));
      await settleTeam(tester);
      expect(find.byType(TextField), findsOneWidget);
      await tester.tap(find.text(l10n.cancel).last);
      await settleTeam(tester);

      // And back from the list.
      await tester.tap(key('team-nav-overview'));
      await settleTeam(tester);
      await tester.tap(key('team-nav-settings'));
      await settleTeam(tester);
      expect(shown.container.read(teamPageProvider), TeamPage.settings);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('an admin renames on Team settings, and is told only an owner deletes',
        (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      final owner = (await tester.runAsync(team.summary))!;
      OrchardSummary as(String role) => OrchardSummary(
            id: owner.id,
            name: owner.name,
            role: role,
            can: role == FixedRoles.admin ? RoleCan.all : const {},
            crates: owner.crates,
            defaultCrateId: owner.defaultCrateId,
          );
      await pumpRolesVaults(tester, team, page: TeamPage.settings, as: as(FixedRoles.admin));
      expect(key('team-rename'), findsOneWidget);
      expect(key('team-delete'), findsNothing);
      expect(key('team-settings-delete-owners'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a member has no Team settings', (tester) async {
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
      expect(key('team-nav-settings'), findsNothing);
      expect(key('team-settings-open'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('At a glance is a list of buttons a screen reader names, opened from the keyboard', (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      final shown = await pumpRolesVaults(tester, team, page: TeamPage.overview);
      final handle = tester.ensureSemantics();
      expect(tester.getSemantics(key('team-stat-rules')), matchesSemantics(isButton: true, hasTapAction: true,
          isFocusable: true, hasFocusAction: true, label: '0\n${l10n.orchardRules}\n${l10n.teamStatRulesNone}'));
      handle.dispose();
      expect(find.text(l10n.teamAtAGlance.toUpperCase()), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(shown.container.read(teamPageProvider), TeamPage.overview);
    });
  });

  group('a phone', () {
    testWidgets('Needs attention, then At a glance under it; Team settings from the bar and the list', (tester) async {
      debugTouchLayout = true;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final team = await buildRolesVaultsTeam(tester, samByCode: true);
        await pumpRolesVaults(tester, team,
            page: TeamPage.overview,
            size: const Size(430, 932),
            body: const TeamPhonePageScreen(page: TeamPage.overview));
        final attention = tester.getRect(key('team-attention'));
        final glance = tester.getRect(key('team-glance'));
        expect(glance.top, greaterThanOrEqualTo(attention.bottom));
        expect(glance.left, closeTo(attention.left, 1));
        expect(key('team-settings-open'), findsOneWidget);
        expect(key('team-rename'), findsNothing);
        expect(key('team-delete'), findsNothing);
        // Each row of At a glance is 48 high or more.
        expect(tester.getSize(key('team-stat-members')).height, greaterThanOrEqualTo(48));
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));

        await pumpRolesVaults(tester, team,
            page: TeamPage.overview, size: const Size(430, 932), body: const TeamPhoneScreen());
        expect(key('team-phone-settings'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));

        await pumpRolesVaults(tester, team,
            page: TeamPage.settings,
            size: const Size(430, 932),
            body: const TeamPhonePageScreen(page: TeamPage.settings));
        expect(key('team-rename'), findsOneWidget);
        expect(key('team-delete'), findsOneWidget);
        expect(tester.getSize(key('team-rename')).height, greaterThanOrEqualTo(44));
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      } finally {
        debugTouchLayout = null;
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
