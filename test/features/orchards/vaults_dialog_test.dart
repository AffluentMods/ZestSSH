import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/widgets/orchard_crates.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/utils/platform_utils.dart';

import 'team/roles_vaults_fixture.dart';

/// The Vaults window as the 4.0 design draws it:
/// the vaults in a list at the left (a phone: a picker
/// over the page), one vault at a time with its name, hosts and this
/// account's access in sight, its settings under Access, Offline,
/// Certificates and Records; what its hosts allow as rows with a switch;
/// protection rows one line with More; Open in Team, Vaults at its foot.
/// Every setting and who may change it are as they were.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  Finder key(String k) => find.byKey(ValueKey(k));
  Finder inKey(String k, Finder f) => find.descendant(of: key(k), matching: f);

  /// The window's body as the window lays it out on a computer.
  Future<void> pumpWindow(WidgetTester tester, RolesVaultsTeam team,
      {OrchardSummary? as, void Function(String)? onOpenInTeam}) async {
    await pumpRolesVaults(
      tester,
      team,
      page: TeamPage.crates,
      as: as,
      size: const Size(1280, 900),
      body: Center(
        child: SizedBox(
          width: 736,
          height: 640,
          child: OrchardCratesView(orchardId: team.orchardId, onOpenInTeam: onOpenInTeam),
        ),
      ),
    );
  }

  group('a computer', () {
    testWidgets('the vaults at the left, one at a time at the right with its line, its tabs', (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      await pumpWindow(tester, team);
      // Production, Shared, then Recovery (owners only, last).
      final items = [team.production, team.shared, team.recovery];
      for (var i = 1; i < items.length; i++) {
        expect(tester.getTopLeft(key('vault-item-${items[i]}')).dy,
            greaterThan(tester.getTopLeft(key('vault-item-${items[i - 1]}')).dy));
      }
      expect(inKey('vault-item-${team.production}', find.text('4 hosts')), findsOneWidget);
      expect(inKey('vault-item-${team.recovery}', find.text('Owners only · 2 hosts')), findsOneWidget);
      // The first is shown, its list item said to be the one chosen.
      expect(key('vault-detail-${team.production}'), findsOneWidget);
      expect(tester.widget<Text>(key('vault-detail-line-${team.production}')).data,
          '4 hosts · ${l10n.crateYourAccess(l10n.crateLevelManage)}');
      // Only its settings: none of another vault's.
      expect(key('crate-allow-${team.shared}-sftp'), findsNothing);
      // Four tabs, Access first.
      for (final t in VaultTab.values) {
        expect(key('vault-tab-${t.name}'), findsOneWidget);
      }
      expect(key('crate-allow-${team.production}-sftp'), findsOneWidget);
      expect(key('crate-offline-${team.production}'), findsNothing, reason: 'on the Offline tab');

      // Another vault: its name and settings, the tab kept.
      await tester.tap(key('vault-tab-offline'));
      await settleTeam(tester);
      expect(key('crate-offline-${team.production}'), findsOneWidget);
      expect(key('crate-allow-${team.production}-sftp'), findsNothing);
      await tester.tap(key('vault-item-${team.shared}'));
      await settleTeam(tester);
      expect(key('vault-detail-${team.shared}'), findsOneWidget);
      expect(key('crate-offline-${team.shared}'), findsOneWidget);
      // Records: Production's session logs.
      await tester.tap(key('vault-item-${team.production}'));
      await settleTeam(tester);
      await tester.tap(key('vault-tab-records'));
      await settleTeam(tester);
      expect(key('crate-session-logs-${team.production}'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('what its hosts allow, a switch each, saved as before', (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      await pumpWindow(tester, team);
      // Production allows SFTP only, as the team was made.
      bool on(String what) => tester.widget<ZestSwitch>(key('crate-allow-${team.production}-$what')).value;
      expect(on('sftp'), isTrue);
      expect(on('forward'), isFalse);
      expect(on('agent'), isFalse);
      expect(inKey('vault-allowed-${team.production}', find.text(l10n.vaultsAllowForwardHelp)), findsOneWidget);
      await tester.tap(key('crate-allow-${team.production}-forward'));
      await settleTeam(tester);
      expect(team.server.recordOf(team.orchardId).crates[team.production]!.allow,
          {CrateSwitches.sftp, CrateSwitches.forward});
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a protection row is one line with More, and More shows the rest', (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      await pumpWindow(tester, team);
      final help = key('crate-confirm-reveal-help-${team.production}');
      expect(tester.widget<Text>(help).maxLines, 1);
      final more = key('crate-confirm-reveal-help-${team.production}-more');
      expect(inKey('crate-confirm-reveal-help-${team.production}-more', find.text(l10n.vaultRowMore)), findsOneWidget);
      await tester.tap(more);
      await tester.pump();
      expect(tester.widget<Text>(help).maxLines, isNull);
      expect(inKey('crate-confirm-reveal-help-${team.production}-more', find.text(l10n.vaultRowLess)), findsOneWidget);
      // Opening an owners-only vault to the team says all it does.
      await tester.tap(key('vault-item-${team.recovery}'));
      await settleTeam(tester);
      expect(key('crate-open-${team.recovery}'), findsOneWidget);
      expect(find.text(l10n.crateOpenToAllBody), findsOneWidget);
      expect(tester.widget<Text>(find.text(l10n.crateOpenToAllBody)).maxLines, isNull);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('Show its hosts and Rename are in its menu; Open in Team, Vaults names the vault shown',
        (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      String? opened;
      await pumpWindow(tester, team, onOpenInTeam: (id) => opened = id);
      expect(key('crate-show-hosts-${team.production}'), findsNothing);
      await tester.tap(key('crate-more-${team.production}'));
      await tester.pumpAndSettle();
      expect(key('crate-show-hosts-${team.production}'), findsOneWidget);
      expect(key('crate-rename-${team.production}'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      await tester.tap(key('vault-item-${team.shared}'));
      await settleTeam(tester);
      await tester.tap(key('vaults-open-in-team'));
      await tester.pump();
      expect(opened, team.shared);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('someone who does not manage a vault reads its settings, with no switches', (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      final owner = (await tester.runAsync(team.summary))!;
      // A member: Shared at Use, nothing else.
      final member = OrchardSummary(
        id: owner.id,
        name: owner.name,
        role: team.member,
        can: const {},
        crates: [
          for (final c in owner.crates)
            if (c.id == team.shared)
              CrateSummary(
                  id: c.id, name: c.name, level: 'use', switches: levelSwitches(CrateLevel.use), allow: c.allow),
        ],
        defaultCrateId: owner.defaultCrateId,
      );
      await pumpWindow(tester, team, as: member);
      expect(key('vault-detail-${team.shared}'), findsOneWidget);
      expect(find.byType(ZestSwitch), findsNothing);
      expect(key('crate-allow-state-${team.shared}-sftp'), findsOneWidget);
      // A tab with nothing for this account says so.
      await tester.tap(key('vault-tab-certificates'));
      await settleTeam(tester);
      expect(key('vault-tab-empty-${team.shared}'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('a phone', () {
    testWidgets('a picker over the vault shown; tabs and switches 48 high', (tester) async {
      debugTouchLayout = true;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final team = await buildRolesVaultsTeam(tester);
        await pumpRolesVaults(tester, team,
            page: TeamPage.crates,
            size: const Size(430, 932),
            body: SingleChildScrollView(child: OrchardCratesView(orchardId: team.orchardId)));
        expect(key('vault-picker'), findsOneWidget);
        expect(key('vault-item-${team.shared}'), findsNothing, reason: 'no list beside it on a phone');
        expect(tester.widget<ZestSelect<String>>(key('vault-picker')).value, team.production);
        expect(tester.getSize(key('vault-tab-access')).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(key('crate-more-${team.production}')).height, greaterThanOrEqualTo(44));
        tester.widget<ZestSelect<String>>(key('vault-picker')).onChanged!(team.shared);
        await settleTeam(tester);
        expect(key('vault-detail-${team.shared}'), findsOneWidget);
        expect(key('vaults-open-in-team'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      } finally {
        debugTouchLayout = null;
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
