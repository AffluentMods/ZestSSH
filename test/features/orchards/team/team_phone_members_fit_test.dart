import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/team/team_phone.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';

import '../../../visual/shots_util.dart';
import 'roles_vaults_fixture.dart';

/// Team > Members on a phone (430 by 932, iOS and Android, the real fonts):
/// the page scrolls, as every Team page on a phone does (its list ran over
/// the screen's foot by 26 and 19 px), and an invitation's address is one
/// line, whole, with Resend, Send a code instead and Withdraw under it where
/// they leave it no room ("sam@example.c" broke to "om", "priya@exa..." was
/// cut beside the buttons).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async => loadShotFonts());

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('${platform.name}: Members fits a phone and scrolls; the addresses are whole', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        final found = <String>[];
        final reported = FlutterError.onError;
        FlutterError.onError = (d) => found.add(d.exceptionAsString().split('\n').first);
        try {
          final team = await buildRolesVaultsTeam(tester);
          await pumpRolesVaults(tester, team,
              page: TeamPage.members,
              size: const Size(430, 932),
              body: const TeamPhonePageScreen(page: TeamPage.members));
        } finally {
          FlutterError.onError = reported;
        }
        expect(found, isEmpty);
        // It scrolls: the last member can be brought into view.
        final scroll = find.descendant(of: find.byType(TeamPhonePageScreen), matching: find.byType(Scrollable)).first;
        expect(tester.state<ScrollableState>(scroll).position.maxScrollExtent, greaterThan(0));
        for (final address in ['priya@example.com', 'sam@example.com']) {
          final text = find.text(address);
          expect(text, findsOneWidget, reason: address);
          final paragraph = tester.renderObject<RenderParagraph>(
              find.descendant(of: text, matching: find.byType(RichText)).first);
          expect(paragraph.didExceedMaxLines, isFalse, reason: '$address whole, on one line');
          expect(tester.getSize(text).height, lessThan(24), reason: '$address on one line');
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
}
