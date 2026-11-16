import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart' show kNewRecordKindsVersion, newRecordKindsOn;
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/widgets/roles_matrix.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/utils/line_breaks.dart';

import 'roles_vaults_fixture.dart';

/// The Team area's Roles and Vaults pages on a computer (3.0 UI),
/// on a real record: a level changed in the
/// table is the role saved with it (the role.set the role editor writes); an
/// owners-only cell has nothing to press; only owners get anything to press
/// at all; a vault's pane changes what its hosts allow and ends access given
/// for a set time, as its card does.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  Finder key(String k) => find.byKey(ValueKey(k));

  group('Roles', () {
    testWidgets("a level clicked opens the levels, and the one picked is the role's new level there", (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      await pumpRolesVaults(tester, team, page: TeamPage.roles);
      final id = team.orchardId;
      expect(key('roles-matrix'), findsOneWidget);
      // Member uses Shared, as the team was made.
      expect(team.server.recordOf(id).roles[team.member]!.crates[team.shared], levelSwitches(CrateLevel.use));

      await tester.tap(key('role-level-${team.member}-${team.shared}'));
      await settleTeam(tester);
      final levels = key('role-levels-${team.member}-${team.shared}');
      expect(levels, findsOneWidget);
      expect(find.descendant(of: levels, matching: find.text(l10n.rolesLevelIn('Member', 'Shared'))), findsOneWidget);
      expect(find.descendant(of: levels, matching: find.text(l10n.rolesLevelConnectHelp)), findsOneWidget);
      // Shared does not allow agent forwarding: said, with the way there.
      expect(key('role-agent-vaults-${team.member}-${team.shared}'), findsOneWidget);

      await tester.tap(key('role-pick-${team.member}-${team.shared}-edit'));
      await settleTeam(tester);
      expect(levels, findsNothing, reason: 'closed once picked');
      expect(team.server.recordOf(id).roles[team.member]!.crates[team.shared], levelSwitches(CrateLevel.edit));
      expect(find.descendant(of: key('role-cell-${team.member}-${team.shared}'), matching: find.text(l10n.crateLevelEdit)),
          findsOneWidget);

      // None takes the vault away from the role.
      await tester.tap(key('role-level-${team.member}-${team.shared}'));
      await settleTeam(tester);
      await tester.tap(key('role-pick-${team.member}-${team.shared}-none'));
      await settleTeam(tester);
      expect(team.server.recordOf(id).roles[team.member]!.crates.containsKey(team.shared), isFalse);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('owners-only vaults and the built-in roles have nothing to press', (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      await pumpRolesVaults(tester, team, page: TeamPage.roles);
      for (final role in [team.member, team.developers, FixedRoles.admin]) {
        final cell = key('role-cell-$role-${team.recovery}');
        expect(cell, findsOneWidget, reason: role);
        expect(find.descendant(of: cell, matching: find.text(l10n.crateOwnersOnly)), findsOneWidget);
        expect(key('role-level-$role-${team.recovery}'), findsNothing, reason: role);
        await tester.tap(cell);
        await settleTeam(tester);
        expect(key('role-levels-$role-${team.recovery}'), findsNothing, reason: role);
      }
      // Owner is what it is; Admin an owner changes like any role (3.3.0),
      // but it never moves.
      expect(key('role-level-${FixedRoles.owner}-${team.shared}'), findsNothing);
      expect(key('role-more-${FixedRoles.owner}'), findsNothing);
      expect(key('role-level-${FixedRoles.admin}-${team.shared}'), findsOneWidget);
      expect(key('role-more-${FixedRoles.admin}'), findsOneWidget);
      for (final role in [FixedRoles.owner, FixedRoles.admin]) {
        expect(key('role-drag-$role'), findsNothing);
      }
      // A lock before Owner and Admin (built in, they stay where they are), a
      // handle before the team's own roles (Admin had nothing there
      // before).
      for (final role in [FixedRoles.owner, FixedRoles.admin]) {
        expect(key('role-lock-$role'), findsOneWidget, reason: role);
      }
      for (final role in [team.member, team.developers]) {
        expect(key('role-drag-$role'), findsOneWidget, reason: role);
        expect(key('role-lock-$role'), findsNothing, reason: role);
      }
      expect(find.descendant(of: key('role-cell-owner-${team.recovery}'), matching: find.text(l10n.crateLevelManage)),
          findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('what a role may do in the team is said in words and changed in its editor; its menu moves it',
        (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      await pumpRolesVaults(tester, team, page: TeamPage.roles);
      final id = team.orchardId;
      // In words, never by colour: Owner everything, a role that may do
      // nothing None.
      expect(tester.widget<Text>(key('role-can-owner-everything')).data, l10n.rolesEverything);
      expect(tester.widget<Text>(key('role-can-${team.developers}')).data, l10n.rolesInTeamNone);
      // Nothing to click in the column: the role's editor has the boxes.
      expect(find.descendant(of: key('role-can-${team.developers}'), matching: find.byType(InkWell)), findsNothing);
      await tester.tap(key('role-more-${team.developers}'));
      await tester.pumpAndSettle();
      await tester.tap(key('role-menu-edit-${team.developers}'));
      await settleTeam(tester);
      for (final what in RoleCan.all) {
        expect(key('role-can-$what'), findsOneWidget, reason: 'the editor has the four boxes');
      }
      await tester.tap(key('role-can-${RoleCan.invite}'));
      await tester.pump();
      await tester.tap(find.text(l10n.save));
      await settleTeam(tester);
      expect(team.server.recordOf(id).roles[team.developers]!.can, {RoleCan.invite});
      expect(tester.widget<Text>(key('role-can-${team.developers}')).data, 'Invite');

      // Developers was moved above Member: Member goes back up.
      int rank(String role) => team.server.recordOf(id).roles[role]!.rank;
      expect(rank(team.developers), greaterThan(rank(team.member)));
      await tester.tap(key('role-more-${team.member}'));
      await tester.pumpAndSettle();
      await tester.tap(key('role-menu-up-${team.member}'));
      await settleTeam(tester);
      expect(rank(team.member), greaterThan(rank(team.developers)));
      // The row follows the record: Member above Developers.
      expect(tester.getTopLeft(key('role-row-${team.member}')).dy,
          lessThan(tester.getTopLeft(key('role-row-${team.developers}')).dy));
      await tester.pump(const Duration(seconds: 5));
    });

    // New kinds of record entry wait for 3.3.0 on every platform:
    // said, never failed at the save.
    testWidgets('while changing Admin is not on yet, it says so and changes nothing', (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      await pumpRolesVaults(tester, team, page: TeamPage.roles);
      addTearDown(() => newRecordKindsOn.value = true);
      newRecordKindsOn.value = false;
      await tester.tap(key('role-level-${FixedRoles.admin}-${team.shared}'));
      await settleTeam(tester);
      await tester.tap(key('role-pick-${FixedRoles.admin}-${team.shared}-use'));
      await settleTeam(tester);
      expect(find.text(l10n.rolesAdminNotYetTitle), findsOneWidget);
      expect(find.text(l10n.rolesAdminChangeTitle), findsNothing);
      await tester.tap(find.text(l10n.close).last);
      await settleTeam(tester);
      expect(team.server.recordOf(team.orchardId).adminRole, isNull);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('Admin is changed like any role: asked about once, then admins open and may do only that; put back',
        (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      await pumpRolesVaults(tester, team, page: TeamPage.roles);
      final id = team.orchardId;
      OrchardRecord record() => team.server.recordOf(id);
      expect(record().adminRole, isNull);
      expect(record().roleSwitches(FixedRoles.admin, team.shared), CrateSwitches.all);

      // The first change asks, saying what admins keep and what the team
      // then needs; Cancel changes nothing.
      await tester.tap(key('role-level-${FixedRoles.admin}-${team.shared}'));
      await settleTeam(tester);
      await tester.tap(key('role-pick-${FixedRoles.admin}-${team.shared}-use'));
      await settleTeam(tester);
      expect(find.text(l10n.rolesAdminChangeTitle), findsOneWidget);
      // What admins keep, and what the team then needs in its amber sentence.
      expect(find.text(l10n.rolesAdminChangeLead), findsOneWidget);
      expect(find.text(l10n.rolesAdminChangeWarning(kNewRecordKindsVersion)), findsOneWidget);
      expect(find.byKey(const ValueKey('zest-callout')), findsOneWidget);
      await tester.tap(find.text(l10n.cancel));
      await settleTeam(tester);
      expect(record().adminRole, isNull);

      await tester.tap(key('role-level-${FixedRoles.admin}-${team.shared}'));
      await settleTeam(tester);
      await tester.tap(key('role-pick-${FixedRoles.admin}-${team.shared}-use'));
      await settleTeam(tester);
      await tester.tap(find.text(l10n.rolesAdminChangeConfirm));
      await settleTeam(tester);
      expect(record().adminRole, isNotNull);
      // (Agent forwarding is never in a level: Admin's stays as it was.)
      expect(record().roleSwitches(FixedRoles.admin, team.shared), {...levelSwitches(CrateLevel.use), CrateSwitches.agent});
      expect(record().roleSwitches(FixedRoles.admin, team.recovery), isEmpty, reason: 'owners-only stays theirs');
      expect(record().adminRole!.can, RoleCan.all, reason: 'only the level changed');

      expect(tester.widget<Text>(key('role-can-${FixedRoles.admin}')).data, 'Invite, remove, change roles, add vaults');

      // Changed once, the next change is not asked about: what it may do in
      // the team, in its editor from the menu's Edit.
      await tester.tap(key('role-more-${FixedRoles.admin}'));
      await tester.pumpAndSettle();
      await tester.tap(key('role-menu-edit-${FixedRoles.admin}'));
      await settleTeam(tester);
      await tester.tap(key('role-can-${RoleCan.remove}'));
      await tester.pump();
      await tester.tap(find.text(l10n.save));
      await settleTeam(tester);
      expect(find.text(l10n.rolesAdminChangeTitle), findsNothing);
      expect(record().adminRole!.can, RoleCan.all.difference({RoleCan.remove}));
      expect(tester.widget<Text>(key('role-can-${FixedRoles.admin}')).data, 'Invite, change roles, add vaults');

      // Back to all of it from its menu.
      await tester.tap(key('role-more-${FixedRoles.admin}'));
      await tester.pumpAndSettle();
      await tester.tap(key('role-menu-reset-${FixedRoles.admin}'));
      await settleTeam(tester);
      expect(record().adminRole, isNull);
      expect(record().roleSwitches(FixedRoles.admin, team.shared), CrateSwitches.all);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('Duplicate makes a role like it, named "(copy)", with the same vaults and abilities', (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      await pumpRolesVaults(tester, team, page: TeamPage.roles);
      final id = team.orchardId;
      final before = team.server.recordOf(id).roles.keys.toSet();
      final source = team.server.recordOf(id).roles[team.member]!;
      await tester.tap(key('role-more-${team.member}'));
      await tester.pumpAndSettle();
      await tester.tap(key('role-menu-duplicate-${team.member}'));
      await settleTeam(tester);
      // The editor opens as a new role, filled in from Member.
      expect(key('role-name'), findsOneWidget);
      final name = tester.widget<TextField>(
          find.descendant(of: key('role-name'), matching: find.byType(TextField)));
      expect(name.controller!.text, l10n.orchardRoleCopyName('Member'));
      await tester.tap(find.text(l10n.save));
      await settleTeam(tester);
      final roles = team.server.recordOf(id).roles;
      final made = roles.keys.toSet().difference(before);
      expect(made, hasLength(1));
      final copy = roles[made.single]!;
      expect(copy.crates, source.crates);
      expect(copy.can, source.can);
      // Names are sealed in the record: the table shows the copy beside Member.
      expect(find.descendant(of: key('role-row-${made.single}'), matching: find.text('Member (copy)')),
          findsOneWidget);
      expect(key('role-row-${team.member}'), findsOneWidget, reason: 'the original is left as it was');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('"Change in Vaults" opens the Vaults page on that vault', (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      final shown = await pumpRolesVaults(tester, team, page: TeamPage.roles);
      await tester.tap(key('role-level-${team.member}-${team.shared}'));
      await settleTeam(tester);
      await tester.tap(key('role-agent-vaults-${team.member}-${team.shared}'));
      await settleTeam(tester);
      expect(shown.container.read(teamPageProvider), TeamPage.crates);
      expect(key('vault-pane-${team.shared}'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('someone who may not change roles reads the table, with nothing to press', (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      final owner = (await tester.runAsync(team.summary))!;
      // An admin: the record refuses a role.set from anyone but an owner.
      final admin = OrchardSummary(
        id: owner.id,
        name: owner.name,
        role: FixedRoles.admin,
        can: RoleCan.all,
        crates: owner.crates,
        defaultCrateId: owner.defaultCrateId,
      );
      await pumpRolesVaults(tester, team,
          page: TeamPage.roles,
          as: admin,
          body: SingleChildScrollView(child: OrchardRolesMatrix(orchardId: team.orchardId)));
      expect(key('roles-matrix'), findsOneWidget);
      expect(find.descendant(of: key('role-cell-${team.member}-${team.shared}'), matching: find.text(l10n.crateLevelUse)),
          findsOneWidget);
      for (final role in [team.member, team.developers]) {
        expect(key('role-level-$role-${team.shared}'), findsNothing, reason: role);
        expect(key('role-more-$role'), findsNothing, reason: role);
        expect(key('role-drag-$role'), findsNothing, reason: role);
        expect(key('role-can-$role-${RoleCan.invite}'), findsNothing, reason: role);
      }
      for (final role in [FixedRoles.owner, FixedRoles.admin]) {
        expect(key('role-lock-$role'), findsOneWidget, reason: role);
      }
      await tester.tap(key('role-cell-${team.member}-${team.shared}'));
      await settleTeam(tester);
      expect(key('role-levels-${team.member}-${team.shared}'), findsNothing);
      expect(find.text(l10n.rolesHintClick), findsNothing, reason: 'no hint about what cannot be done');
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('Vaults', () {
    testWidgets("a vault's pane follows the Admin role as an owner changed it", (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      await tester.runAsync(() => team.service.setAdminRole(team.orchardId,
          can: {RoleCan.invite}, crates: {team.shared: levelSwitches(CrateLevel.connect)}));
      await pumpRolesVaults(tester, team, page: TeamPage.crates);
      await tester.tap(key('vault-card-${team.production}'));
      await settleTeam(tester);
      expect(tester.widget<Text>(key('vault-role-level-${FixedRoles.admin}')).data, l10n.crateLevelNone,
          reason: 'Admin no longer opens Production');
      await tester.tap(key('vault-card-${team.shared}'));
      await settleTeam(tester);
      expect(tester.widget<Text>(key('vault-role-level-${FixedRoles.admin}')).data, l10n.crateLevelConnect);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets("a vault's pane: who can open it, what its hosts allow, its protection", (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      await pumpRolesVaults(tester, team, page: TeamPage.crates);
      final id = team.orchardId;
      final line = tester.widget<Text>(key('vault-line-${team.production}')).textSpan!.toPlainText();
      expect(line, contains(l10n.hostsMetaHostCount(4)));
      expect(line, contains('jordan@example.com'));
      expect(key('vault-mark-certs-${team.production}'), findsOneWidget);
      expect(key('vaults-owners-only-note'), findsOneWidget);
      expect(key('vault-pane-${team.production}'), findsNothing);

      await tester.tap(key('vault-card-${team.production}'));
      await settleTeam(tester);
      final pane = key('vault-pane-${team.production}');
      expect(pane, findsOneWidget);
      Finder inPane(Finder f) => find.descendant(of: pane, matching: f);
      // Its parts whole on their lines ("Manage" was left alone on one).
      expect(inPane(find.textContaining(keepTogether(l10n.crateYourAccess(l10n.crateLevelManage)))), findsOneWidget);
      // Each role and its level; Jordan, for a set time.
      expect(tester.widget<Text>(key('vault-role-level-${team.developers}')).data, l10n.crateLevelEdit);
      expect(tester.widget<Text>(key('vault-role-level-${team.member}')).data, l10n.crateLevelNone);
      expect(tester.widget<Text>(key('vault-role-level-${FixedRoles.owner}')).data, l10n.crateLevelManage);
      expect(key('vault-timed-${RolesVaultsTeam.jordan}'), findsOneWidget);
      // Jordan's level stands where each role's does, End now before it (a
      // design review).
      expect(tester.getRect(key('vault-timed-level-${RolesVaultsTeam.jordan}')).right,
          closeTo(tester.getRect(key('vault-role-level-${FixedRoles.owner}')).right, 0.5));
      expect(tester.getRect(key('vault-timed-end-${RolesVaultsTeam.jordan}')).right,
          lessThan(tester.getRect(key('vault-timed-level-${RolesVaultsTeam.jordan}')).left));
      expect(key('vault-edit-roles'), findsOneWidget);
      // The certificates' state, with the settings in the header.
      final paneList = find.descendant(of: pane, matching: find.byType(Scrollable)).first;
      await tester.scrollUntilVisible(key('crate-certs-state-${team.production}-on'), 200, scrollable: paneList);
      expect(key('crate-certs-state-${team.production}-on'), findsOneWidget);
      expect(key('crate-certs-settings-${team.production}'), findsOneWidget);

      // Port forwarding allowed from its box: the record has it.
      await tester.scrollUntilVisible(
          key('vault-allow-${team.production}-${CrateSwitches.forward}'), -200, scrollable: paneList);
      await tester.tap(key('vault-allow-${team.production}-${CrateSwitches.forward}'));
      await settleTeam(tester);
      expect(team.server.recordOf(id).crates[team.production]!.allow, {CrateSwitches.sftp, CrateSwitches.forward});

      // Asking again before revealing, off.
      await tester.scrollUntilVisible(key('crate-confirm-reveal-${team.production}'), 200, scrollable: paneList);
      await tester.pump();
      await tester.tap(key('crate-confirm-reveal-${team.production}'));
      await settleTeam(tester);
      expect(team.server.recordOf(id).crates[team.production]!.confirmReveal, isFalse);

      // Closed: the list alone again.
      await tester.tap(key('vault-pane-close'));
      await settleTeam(tester);
      expect(pane, findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('End now ends what Jordan holds until a set time', (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      await pumpRolesVaults(tester, team, page: TeamPage.crates);
      final id = team.orchardId;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(team.server.recordOf(id).switchesAt(RolesVaultsTeam.jordan, team.production, now), isNotEmpty);
      await tester.tap(key('vault-card-${team.production}'));
      await settleTeam(tester);
      await tester.tap(key('vault-timed-end-${RolesVaultsTeam.jordan}'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.accessEndConfirm));
      await settleTeam(tester);
      expect(team.server.recordOf(id).switchesAt(RolesVaultsTeam.jordan, team.production, now), isEmpty);
      expect(key('vault-timed-${RolesVaultsTeam.jordan}'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('someone who does not manage a vault reads what its hosts allow, with no boxes', (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      final owner = (await tester.runAsync(team.summary))!;
      final shared = owner.crates.firstWhere((c) => c.id == team.shared);
      final member = OrchardSummary(
        id: owner.id,
        name: owner.name,
        role: team.member,
        crates: [
          CrateSummary(
            id: shared.id,
            name: shared.name,
            level: 'use',
            switches: levelSwitches(CrateLevel.use),
            allow: kDefaultCrateAllow,
          ),
        ],
        defaultCrateId: shared.id,
      );
      await pumpRolesVaults(tester, team, page: TeamPage.crates, as: member);
      expect(key('crate-new'), findsNothing, reason: 'a Member adds no vaults');
      await tester.tap(key('vault-card-${team.shared}'));
      await settleTeam(tester);
      expect(key('vault-pane-${team.shared}'), findsOneWidget);
      for (final what in [CrateSwitches.sftp, CrateSwitches.forward, CrateSwitches.agent]) {
        expect(key('vault-allow-${team.shared}-$what'), findsNothing, reason: what);
      }
      expect(key('vault-allowed-${team.shared}-${CrateSwitches.sftp}-on'), findsOneWidget);
      expect(key('vault-allowed-${team.shared}-${CrateSwitches.agent}-off'), findsOneWidget);
      expect(key('crate-confirm-reveal-${team.shared}'), findsNothing);
      expect(key('crate-rename-${team.shared}'), findsNothing);
      expect(key('vault-edit-roles'), findsNothing, reason: 'the Roles page is for owners');
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
