import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';
import 'package:zestssh/utils/platform_utils.dart';

import '../helpers/quick_wins_fixture.dart';
import '../visual/shots_util.dart';

/// The phone's Hosts tab with no hosts (found on a device run on a
/// Pixel 3a): its + button lay over the Restore from sync card, the last of
/// the ways to get connected but one, and over the demo terminal's button
/// under them. Scrolled to its end, nothing of the page is under the +.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  mockQuickWinsChannels();
  final l10n = lookupAppLocalizations(const Locale('en'));

  for (final size in const [Size(393, 808), Size(360, 640)]) {
    testWidgets('no hosts, ${size.width.toInt()} by ${size.height.toInt()}: nothing under the +', (tester) async {
      debugTouchLayout = true;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final s = await pumpQuickWins(tester, const HomeScreen(), size);
        await tester.runAsync(() => s.db.delete(s.db.connections).go());
        await settleQuickWins(tester);
        final fab = find.byKey(const ValueKey('phone-new-host'));
        expect(fab, findsOneWidget);
        final demo = find.byKey(const ValueKey('phone-try-demo'));
        expect(demo, findsOneWidget);
        // To the page's end.
        await tester.drag(find.byType(SingleChildScrollView).last, const Offset(0, -2000));
        await settleQuickWins(tester);
        final plus = tester.getRect(fab);
        final restore = find.text(l10n.firstRunRestoreTitle);
        for (final (name, part) in [
          ('Restore from sync', tester.getRect(restore)),
          ('Try the demo terminal', tester.getRect(demo)),
        ]) {
          expect(part.bottom, lessThanOrEqualTo(plus.top), reason: '$name clears the +');
        }
        if (shotsEnabled) await saveShot(tester, s.key, 'phone-hosts-empty-${size.width.toInt()}');
        await unpumpQuickWins(tester);
      } finally {
        debugTouchLayout = null;
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
}
