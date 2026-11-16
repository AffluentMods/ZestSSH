import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';

import '../features/orchards/team/roles_vaults_fixture.dart';
import 'shots_util.dart';

/// Pictures of the Team area's Overview and Members pages on a computer
/// (3.0, as designed), with the real fonts and
/// the team's list of pages on the left:
///
///   flutter test --dart-define=ZEST_SHOTS=true --dart-define=ZEST_ORCHARDS=true test/visual/team_overview_members_shots_test.dart
///
/// Pictures land in build/shots/. Everything on them is made up (the team
/// "Platform team", alex@example.com its one owner, jordan@example.com holding
/// Production for two hours, sam@example.com who used an invite code four
/// minutes ago, priya@example.com invited; the demo fleet of the website,
/// web-01 to hypervisor-b). Another language with --dart-define=ZEST_SHOT_LOCALE=de.
const _locale = String.fromEnvironment('ZEST_SHOT_LOCALE', defaultValue: 'en');

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';

    testWidgets('Overview, with what needs attention and access for a set time ($tag)', (tester) async {
      realShadows();
      await tester.runAsync(loadShotFonts);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final team = await buildRolesVaultsTeam(tester, samByCode: true);
        // Two rules on.
        await tester.runAsync(() async {
          await team.service.setRules(team.orchardId, const RecordRules(requireAppLock: true, noExport: true));
          await team.service.refresh();
        });
        final shown = await pumpRolesVaults(tester, team,
            page: TeamPage.overview, themeId: themeId, locale: const Locale(_locale));
        await saveShot(tester, shown.key, 'team_overview_${_locale}_$tag');
        // Team settings (4.0): the team's name, and Delete team.
        await tester.tap(find.byKey(const ValueKey('team-settings-open')));
        await settleTeam(tester);
        await saveShot(tester, shown.key, 'team_settings_${_locale}_$tag');
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      } finally {
        debugDefaultTargetPlatformOverride = null;
        plainShadows();
      }
    }, skip: !shotsEnabled);

    testWidgets('Members, then the review of the used invite code ($tag)', (tester) async {
      realShadows();
      await tester.runAsync(loadShotFonts);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final team = await buildRolesVaultsTeam(tester, samByCode: true);
        final shown = await pumpRolesVaults(tester, team,
            page: TeamPage.members, themeId: themeId, locale: const Locale(_locale));
        await saveShot(tester, shown.key, 'team_members_${_locale}_$tag');
        await tester.tap(find.byKey(ValueKey('invite-${team.samInvite}')));
        await settleTeam(tester);
        await saveShot(tester, shown.key, 'team_members_review_${_locale}_$tag');
        // A member's panel in its place.
        await tester.tap(find.byKey(const ValueKey('member-${RolesVaultsTeam.jordan}')));
        await settleTeam(tester);
        await saveShot(tester, shown.key, 'team_members_jordan_${_locale}_$tag');
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      } finally {
        debugDefaultTargetPlatformOverride = null;
        plainShadows();
      }
    }, skip: !shotsEnabled);
  }
}
