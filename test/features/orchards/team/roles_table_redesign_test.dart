import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/team/team_phone.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/widgets/role_levels.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/dashed_rounded_border.dart';
import 'package:zestssh/utils/platform_utils.dart';

import 'roles_vaults_fixture.dart';

/// The Roles page as the 4.0 design draws it:
/// each level a neutral pill with a meter of four steps and
/// its word (None dashed, with no steps), the In the team column in words,
/// every vault head with its hosts, a strip saying what each level allows;
/// on a phone the same as a card for each role.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  Finder key(String k) => find.byKey(ValueKey(k));

  /// The pill in [cell], and how many of its meter's steps are filled.
  (RoleLevelPill, int) pillIn(WidgetTester tester, Finder cell) {
    final pill = tester.widget<RoleLevelPill>(find.descendant(of: cell, matching: find.byType(RoleLevelPill)));
    final meter = tester.widget<RoleLevelMeter>(find.descendant(of: cell, matching: find.byType(RoleLevelMeter)));
    return (pill, meter.steps);
  }

  group('a computer', () {
    testWidgets('each level a neutral pill: its meter, its word, a chevron only where it changes, None dashed',
        (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      await pumpRolesVaults(tester, team, page: TeamPage.roles);
      for (final (role, vault, level, steps, word) in [
        (FixedRoles.owner, team.production, CrateLevel.manage, 4, l10n.crateLevelManage),
        (team.developers, team.production, CrateLevel.edit, 3, l10n.crateLevelEdit),
        (team.developers, team.shared, CrateLevel.use, 2, l10n.crateLevelUse),
        (team.member, team.shared, CrateLevel.use, 2, l10n.crateLevelUse),
        (team.member, team.production, null, 0, l10n.crateLevelNone),
      ]) {
        final cell = key('role-cell-$role-$vault');
        final (pill, filled) = pillIn(tester, cell);
        expect(pill.level, level, reason: '$role $vault');
        expect(filled, steps, reason: '$role $vault');
        expect(find.descendant(of: cell, matching: find.text(word)), findsOneWidget, reason: '$role $vault');
        // Owner's are what they are: no chevron. The others an owner changes.
        expect(pill.chevron, role != FixedRoles.owner, reason: '$role $vault');
      }
      // None is drawn dashed; a level solid, in the app's neutral colours.
      final none = tester.widget<AnimatedContainer>(find.descendant(
          of: key('role-cell-${team.member}-${team.production}'), matching: find.byType(AnimatedContainer)));
      expect(none.decoration, isA<DashedRoundedBorder>());
      final use = tester.widget<AnimatedContainer>(find.descendant(
          of: key('role-cell-${team.member}-${team.shared}'), matching: find.byType(AnimatedContainer)));
      final box = use.decoration! as BoxDecoration;
      expect(box.color, ZestTokens.surfaceRaised);
      expect(box.color, isNot(ZestTokens.brand));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('In the team in words; every vault head with its hosts, the owners-only one too', (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      await pumpRolesVaults(tester, team, page: TeamPage.roles);
      expect(find.text(l10n.rolesColumnInTeam.toUpperCase()), findsOneWidget);
      expect(find.descendant(of: key('roles-matrix'), matching: find.text('PEOPLE')), findsNothing);
      expect(tester.widget<Text>(key('role-can-owner-everything')).data, 'Everything');
      expect(tester.widget<Text>(key('role-can-${FixedRoles.admin}')).data, 'Invite, remove, change roles, add vaults');
      expect(tester.widget<Text>(key('role-can-${team.member}')).data, 'None');
      expect(tester.widget<Text>(key('roles-head-count-${team.production}')).data, '4 hosts');
      expect(tester.widget<Text>(key('roles-head-count-${team.shared}')).data, '6 hosts');
      expect(tester.widget<Text>(key('roles-head-count-${team.recovery}')).data, '2 hosts · Owners only');
      // Owners-only cells keep the lock and the words.
      expect(find.descendant(of: key('role-cell-${team.member}-${team.recovery}'), matching: find.text(l10n.crateOwnersOnly)),
          findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('what each level allows, in the app\'s own words, under the table', (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      await pumpRolesVaults(tester, team, page: TeamPage.roles);
      final strip = key('roles-levels');
      expect(strip, findsOneWidget);
      expect(find.descendant(of: strip, matching: find.text(l10n.rolesLevelsTitle)), findsOneWidget);
      expect(find.descendant(of: strip, matching: find.text(l10n.rolesLevelsLead)), findsOneWidget);
      for (final help in [
        l10n.rolesLevelNoneHelp,
        l10n.rolesLevelConnectHelp,
        l10n.rolesLevelUseHelp,
        l10n.rolesLevelEditHelp,
        l10n.rolesLevelManageHelp,
      ]) {
        expect(find.descendant(of: strip, matching: find.text(help)), findsOneWidget);
      }
      // Five across, left to right from None to Manage, under the table.
      final none = tester.getRect(key('roles-levels-none'));
      final manage = tester.getRect(key('roles-levels-manage'));
      expect(none.top, closeTo(manage.top, 0.5));
      expect(none.left, lessThan(manage.left));
      expect(tester.getRect(strip).top, greaterThan(tester.getRect(key('roles-matrix')).bottom));
      expect(tester.getRect(strip).width, closeTo(tester.getRect(key('roles-matrix')).width, 0.5));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a level is a button a screen reader names, and Enter opens it from the keyboard', (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      await pumpRolesVaults(tester, team, page: TeamPage.roles);
      final handle = tester.ensureSemantics();
      final level = key('role-level-${team.member}-${team.shared}');
      expect(
        tester.getSemantics(level),
        matchesSemantics(
          label: 'Member in Shared: Use',
          isButton: true,
          hasTapAction: true,
          hasFocusAction: true,
          isFocusable: true,
          hasEnabledState: false,
          hasExpandedState: true,
        ),
      );
      // Owner's: read, not pressed.
      expect(tester.getSemantics(find.bySemanticsLabel('Owner in Shared: Manage')),
          matchesSemantics(label: 'Owner in Shared: Manage'));
      handle.dispose();

      // Reached with Tab, opened with Enter.
      Focus.of(tester.element(find.descendant(of: level, matching: find.byType(GestureDetector)).first)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settleTeam(tester);
      expect(key('role-levels-${team.member}-${team.shared}'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('a phone', () {
    testWidgets('a card for each role: In the team in words, each vault with its hosts and level, the levels strip',
        (tester) async {
      debugTouchLayout = true;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final team = await buildRolesVaultsTeam(tester);
        await pumpRolesVaults(tester, team,
            page: TeamPage.roles, size: const Size(430, 932), body: const TeamPhonePageScreen(page: TeamPage.roles));
        // The vaults' names, read as the page is drawn (they were "Unnamed
        // vault" on a phone).
        expect(find.text(l10n.crateUnnamed), findsNothing);
        final member = key('role-${team.member}');
        await tester.scrollUntilVisible(member, 200, scrollable: find.byType(Scrollable).first);
        expect(find.descendant(of: member, matching: find.text('None')), findsWidgets);
        expect(tester.widget<Text>(key('role-can-${team.member}')).data, l10n.rolesInTeamNone);
        expect(tester.widget<Text>(key('role-can-${FixedRoles.admin}')).data, 'Invite, remove, change roles, add vaults');
        expect(tester.widget<Text>(key('role-can-${FixedRoles.owner}')).data, l10n.rolesEverything);
        final shared = key('role-cell-${team.member}-${team.shared}');
        expect(find.descendant(of: shared, matching: find.textContaining('Shared', findRichText: true)), findsOneWidget);
        expect(find.descendant(of: shared, matching: find.textContaining('6 hosts', findRichText: true)), findsOneWidget);
        final (pill, steps) = pillIn(tester, shared);
        expect((pill.level, steps, pill.chevron), (CrateLevel.use, 2, false));
        expect(find.descendant(of: key('role-cell-${team.member}-${team.recovery}'), matching: find.text(l10n.crateOwnersOnly)),
            findsOneWidget);
        // Owner manages every vault, the owners-only one too.
        expect(pillIn(tester, key('role-cell-${FixedRoles.owner}-${team.recovery}')).$1.level, CrateLevel.manage);
        // Its buttons are 48 by 48.
        final edit = find.descendant(of: member, matching: key('edit'));
        expect(tester.getSize(edit).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(edit).width, greaterThanOrEqualTo(48));
        await tester.scrollUntilVisible(key('roles-levels'), 300, scrollable: find.byType(Scrollable).first);
        expect(find.text(l10n.rolesLevelsTitle), findsOneWidget);
        // A tap on the card opens its editor, as before.
        await tester.scrollUntilVisible(member, -200, scrollable: find.byType(Scrollable).first);
        await tester.tap(find.descendant(of: member, matching: find.text('Member')));
        await settleTeam(tester);
        expect(key('role-name'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      } finally {
        debugTouchLayout = null;
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
