import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart' show accessTimeText;
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

import 'roles_vaults_fixture.dart';
import 'team_shell_fixture.dart';

/// Every Team page in the whole desktop app at its least window (800 by
/// 600, the app's rail and the Team pages' own list beside the page) and at
/// 900 by 700, in English and in German, with the real fonts: the pages,
/// a vault's pane with its certificate settings and its hosts' commands, a
/// member's panel, and inviting by address and by a code or QR. Nothing runs
/// over. At 800 a page's buttons left its title a letter a line (the Seats
/// page ran over its foot by 254 px in German), a vault's pane beside the
/// list left the list nothing and ran 539 px over the page, an invitation's
/// buttons and the Roles page's hints ran past their rows.
///
/// What Jordan holds for a set time ends tomorrow at 12:59 AM, whenever this
/// runs. Its label says the time alone when it ends today and the day with it
/// otherwise ("Production until Nov 14 12:59 AM"), and it ended two hours
/// from now: so the label was the long one only when the test ran after 10 PM,
/// and the Members page fitted or ran over by the clock (found 12 November
/// 2026; the row itself was put right in 2704baaa). Now it is the long one,
/// the widest, at every hour.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(setUpTeamShell);
  Finder key(String k) => find.byKey(ValueKey(k));
  DateTime tomorrowEarly() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day + 1, 0, 59, 30);
  }

  for (final size in const [Size(800, 600), Size(900, 700)]) {
    for (final locale in const [Locale('en'), Locale('de')]) {
      testWidgets('${size.width.toInt()} by ${size.height.toInt()}, ${locale.languageCode}: every Team page fits',
          (tester) async {
        final found = <String>[];
        final reported = FlutterError.onError;
        var where = 'start';
        FlutterError.onError = (d) {
          final t = d.toString();
          final over = RegExp(r'overflowed by [0-9.]+ pixels on the \w+').firstMatch(t)?.group(0);
          final at = RegExp(r'file:///\S*?/lib/(\S+?:\d+)').firstMatch(t)?.group(1);
          found.add('$where: ${over ?? d.exceptionAsString().split('\n').first} (${at ?? '?'})');
        };
        try {
          final until = tomorrowEarly();
          final s = await pumpTeamShell(tester, size: size, locale: locale, timedUntil: until);
          for (final page in TeamPage.values) {
            where = page.name;
            s.showPage(page);
            await settleTeamShell(tester);
            if (page == TeamPage.members) {
              // The label with its day is what is on the page, at any hour.
              final label =
                  accessTimeText(until.millisecondsSinceEpoch ~/ 1000, lookupAppLocalizations(locale), now: DateTime.now());
              expect(find.textContaining(label, findRichText: true), findsWidgets, reason: 'the timed label, $label');
            }
          }

          // A vault's pane, its certificate settings and its hosts' commands.
          where = 'vault pane';
          s.showPage(TeamPage.crates);
          await settleTeamShell(tester);
          await tester.tap(key('vault-card-${s.team.production}'));
          await settleTeamShell(tester);
          final pane = key('vault-pane-${s.team.production}');
          expect(pane, findsOneWidget);
          final paneList = find.descendant(of: pane, matching: find.byType(Scrollable)).first;
          for (final k in ['crate-certs-settings-${s.team.production}', 'crate-certs-hosts-${s.team.production}']) {
            where = k.substring(0, k.lastIndexOf('-'));
            await tester.scrollUntilVisible(key(k), 200, scrollable: paneList);
            await tester.pump();
            await tester.tap(key(k));
            await settleTeamShell(tester);
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await settleTeamShell(tester);
          }
          await tester.tap(key('vault-pane-close'));
          await settleTeamShell(tester);

          // A member's panel.
          where = 'member panel';
          s.showPage(TeamPage.members);
          await settleTeamShell(tester);
          final jordan = key('member-${RolesVaultsTeam.jordan}');
          await tester.ensureVisible(jordan.first);
          await tester.pump();
          await tester.tap(jordan.first);
          await settleTeamShell(tester);
          expect(key('member-panel-${RolesVaultsTeam.jordan}'), findsOneWidget);

          // Inviting, by address and by a code or QR.
          for (final way in ['email', 'code']) {
            where = 'invite by $way';
            s.showPage(TeamPage.overview);
            await settleTeamShell(tester);
            s.showPage(TeamPage.members);
            await settleTeamShell(tester);
            await tester.tap(key('team-invite'));
            await settleTeamShell(tester);
            await tester.tap(key('invite-way-$way'));
            await settleTeamShell(tester);
            if (way == 'code') {
              await tester.tap(key('invite-code-make'));
              await settleTeamShell(tester);
              expect(key('invite-code-text'), findsOneWidget);
            }
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await settleTeamShell(tester);
          }
          await tearDownTeamShell(tester);
        } finally {
          FlutterError.onError = reported;
        }
        expect(found.toSet(), isEmpty);
      }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
    }
  }
}
