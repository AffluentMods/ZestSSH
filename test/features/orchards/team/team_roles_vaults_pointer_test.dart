import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/widgets/crate_authority_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

import '../../../visual/shots_util.dart';
import 'roles_vaults_fixture.dart';

/// The Team area's Roles and Vaults pages under a computer's mouse, with the
/// real fonts: the roles table where it is wider than the page and scrolls
/// sideways (800 wide), and a vault's certificate settings from the link in
/// the header of its pane.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  Finder key(String k) => find.byKey(ValueKey(k));

  setUpAll(() async => loadShotFonts());

  testWidgets('the mouse over the roles table and its sideways scrollbar raises nothing', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final team = await buildRolesVaultsTeam(tester);
      await pumpRolesVaults(tester, team, page: TeamPage.roles, size: const Size(800, 800));
      final bar = find.ancestor(
        of: key('roles-matrix'),
        matching: find.byWidgetPredicate((w) =>
            w is Scrollbar && w.child is SingleChildScrollView && (w.child as SingleChildScrollView).scrollDirection == Axis.horizontal),
      );
      expect(bar, findsOneWidget, reason: 'at 800 wide the table scrolls sideways');
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(key('roles-matrix')));
      await tester.pump(const Duration(milliseconds: 100));
      // Along the scrollbar's track at the bottom of the scroll view, where
      // a scrollbar with no scroll position of its own asserted on hover.
      final r = tester.getRect(bar);
      for (var y = r.bottom - 1; y > r.bottom - 14; y -= 2) {
        for (var x = r.left + 10; x < r.right; x += 60) {
          await mouse.moveTo(Offset(x, y));
          await tester.pump(const Duration(milliseconds: 20));
        }
      }
      expect(tester.takeException(), isNull);
      // The wheel sideways scrolls the table.
      await tester.sendEventToBinding(
          (TestPointer(9, PointerDeviceKind.mouse)..hover(r.center)).scroll(const Offset(0, 120)));
      await tester.pump();
      await mouse.removePointer();
      await tester.pump(const Duration(seconds: 5));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets("a vault's certificates Settings link, pressed with the mouse, opens the certificate settings",
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final team = await buildRolesVaultsTeam(tester);
      await pumpRolesVaults(tester, team, page: TeamPage.crates);
      await tester.tap(key('vault-card-${team.production}'));
      await settleTeam(tester);
      final pane = key('vault-pane-${team.production}');
      final paneList = find.descendant(of: pane, matching: find.byType(Scrollable)).first;
      final link = key('crate-certs-settings-${team.production}');
      await tester.scrollUntilVisible(link, 200, scrollable: paneList);
      await tester.pump();
      expect(find.descendant(of: link, matching: find.text(l10n.settingsTitle)), findsOneWidget);
      await tester.tapAt(tester.getCenter(link), kind: PointerDeviceKind.mouse);
      await settleTeam(tester);
      expect(find.byType(CrateAuthorityEditor), findsOneWidget);
      expect(find.text(l10n.certDialogTitle('Production')), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
