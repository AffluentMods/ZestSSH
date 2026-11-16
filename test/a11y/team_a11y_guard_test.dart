import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';

import '../features/orchards/team/roles_vaults_fixture.dart';
import '../helpers/words_cut.dart';
import '../visual/shots_util.dart';
import 'a11y_checks.dart';

/// The Team area on a computer, every page its owner sees (overview,
/// members, roles, vaults, rules, sign-in, seats, Team settings), held to the
/// 4.0 accessibility pass: every control a screen reader
/// can press has a name, a pointer's target is 32 square, and the words read
/// on what they are drawn on; in Graphite and in Daylight.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const pages = [
    TeamPage.overview,
    TeamPage.members,
    TeamPage.roles,
    TeamPage.crates,
    TeamPage.rules,
    TeamPage.signIn,
    TeamPage.seats,
    TeamPage.settings,
  ];

  for (final theme in ['graphite', 'default_light']) {
    testWidgets('$theme: every Team page an owner sees: names, targets, contrast', (tester) async {
      await tester.runAsync(loadShotFonts);
      final handle = tester.ensureSemantics();
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final team = await buildRolesVaultsTeam(tester, samByCode: true);
        final failures = <String>[];
        final shown = await pumpRolesVaults(tester, team, page: pages.first, themeId: theme);
        for (final page in pages) {
          shown.container.read(teamPageProvider.notifier).state = page;
          await settleTeam(tester);
          failures.addAll(await a11yCheck(tester, computer: true, where: 'Team, ${page.name}'));
        }
        expect(failures, isEmpty);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      } finally {
        debugDefaultTargetPlatformOverride = null;
        handle.dispose();
      }
    });
  }

  testWidgets('every Team page an owner sees at 150% text on a computer: nothing runs over, no words cut',
      (tester) async {
    await tester.runAsync(loadShotFonts);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    final problems = <String>[];
    var page = pages.first;
    final reported = FlutterError.onError;
    FlutterError.onError = (details) =>
        problems.add('${page.name}: ${details.exceptionAsString().split(String.fromCharCode(10)).first}');
    try {
      final team = await buildRolesVaultsTeam(tester, samByCode: true);
      final shown = await pumpRolesVaults(tester, team, page: page, size: const Size(1280, 900));
      expect(MediaQuery.textScalerOf(tester.element(find.byType(Scaffold).first)).scale(10), 15, reason: 'drawn at 150%');
      for (final p in pages) {
        page = p;
        shown.container.read(teamPageProvider.notifier).state = p;
        await settleTeam(tester);
        for (final e in find.byType(RichText).evaluate()) {
          final paragraph = e.renderObject;
          if (paragraph is! RenderParagraph || !paragraph.hasSize) continue;
          final cut = cutTopAndBottom(paragraph);
          if (cut != null) problems.add('${p.name}: cut at its top and bottom: $cut');
        }
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    } finally {
      FlutterError.onError = reported;
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      debugDefaultTargetPlatformOverride = null;
    }
    expect(problems, isEmpty);
  });
}
