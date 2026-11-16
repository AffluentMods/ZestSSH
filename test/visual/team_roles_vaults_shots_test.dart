import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';

import '../features/orchards/team/roles_vaults_fixture.dart';
import 'shots_util.dart';

/// Pictures of the Team area's Roles and Vaults pages on a computer (3.0
/// design), with the real fonts:
///
///   flutter test --dart-define=ZEST_SHOTS=true --dart-define=ZEST_ORCHARDS=true test/visual/team_roles_vaults_shots_test.dart
///
/// Pictures land in build/shots/. Everything on them is made up (the team
/// "Platform team", alex@example.com, jordan@example.com, the demo fleet
/// of the website, web-01 to hypervisor-b). Another language with
/// --dart-define=ZEST_SHOT_LOCALE=de.
const _locale = String.fromEnvironment('ZEST_SHOT_LOCALE', defaultValue: 'en');

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';

    testWidgets('Roles, with a level open ($tag)', (tester) async {
      realShadows();
      await tester.runAsync(loadShotFonts);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final team = await buildRolesVaultsTeam(tester);
        final shown = await pumpRolesVaults(tester, team,
            page: TeamPage.roles, themeId: themeId, locale: const Locale(_locale));
        await saveShot(tester, shown.key, 'team_roles_${_locale}_$tag');
        await tester.tap(find.byKey(ValueKey('role-level-${team.member}-${team.shared}')));
        await settleTeam(tester);
        await saveShot(tester, shown.key, 'team_roles_level_${_locale}_$tag');
        await tester.tap(find.byKey(ValueKey('role-level-${team.developers}-${team.production}')));
        await settleTeam(tester);
        await tester.tap(find.byKey(ValueKey('role-level-${team.developers}-${team.production}')));
        await settleTeam(tester);
        await saveShot(tester, shown.key, 'team_roles_level_agent_${_locale}_$tag');
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      } finally {
        debugDefaultTargetPlatformOverride = null;
        plainShadows();
      }
    }, skip: !shotsEnabled);

    testWidgets('Vaults, with Production open ($tag)', (tester) async {
      realShadows();
      await tester.runAsync(loadShotFonts);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final team = await buildRolesVaultsTeam(tester);
        final shown = await pumpRolesVaults(tester, team,
            page: TeamPage.crates, themeId: themeId, locale: const Locale(_locale));
        await saveShot(tester, shown.key, 'team_vaults_${_locale}_$tag');
        await tester.tap(find.byKey(ValueKey('vault-card-${team.production}')));
        await settleTeam(tester);
        await saveShot(tester, shown.key, 'team_vaults_production_${_locale}_$tag');
        // The rest of the pane, scrolled.
        await tester.drag(find.byKey(ValueKey('vault-pane-${team.production}')), const Offset(0, -700));
        await settleTeam(tester);
        await saveShot(tester, shown.key, 'team_vaults_production_more_${_locale}_$tag');
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      } finally {
        debugDefaultTargetPlatformOverride = null;
        plainShadows();
      }
    }, skip: !shotsEnabled);
  }
}
