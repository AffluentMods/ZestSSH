import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';
import 'package:zestssh/ui/screens/security/security_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/appearance_screen.dart';
import 'package:zestssh/ui/screens/settings/settings_screen.dart';
import 'package:zestssh/ui/screens/snippets/snippets_screen.dart';
import 'package:zestssh/ui/widgets/phone_list.dart' show kPhonePageMaxWidth;
import 'package:zestssh/utils/platform_utils.dart';

import '../helpers/quick_wins_fixture.dart';

/// On a tablet, Keys, Port forwarding, Settings and its pages, Snippets and the More tab
/// hold their content to the one centred column a phone page takes there, as
/// Hosts and Networks do (PhonePageColumn); they ran the full width.
/// A phone keeps the whole width.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  mockQuickWinsChannels();

  // Each page, and what holds its content.
  final pages = <(String, Widget, Finder Function())>[
    (
      'Keys',
      const KeysPhoneScreen(),
      () => find.descendant(of: find.byKey(const ValueKey('phone-keys')), matching: find.byType(ListView)).first,
    ),
    (
      'Port forwarding',
      const PortForwardsPhoneScreen(),
      () =>
          find.descendant(of: find.byKey(const ValueKey('phone-port-forwards')), matching: find.byType(ListView)).first,
    ),
    ('Settings', const SettingsScreen(), () => find.byType(SettingsBody)),
    ('Snippets', const SnippetsPhoneScreen(), () => find.byType(SnippetsScreen)),
    // Settings' own pages too, as its list (on a device,
    // Security and privacy ran the full width beside it).
    (
      'Security and privacy',
      const SecuritySettingsScreen(),
      () => find.descendant(of: find.byType(SecuritySettingsScreen), matching: find.byType(ListView)).first,
    ),
    (
      'Appearance',
      const AppearanceScreen(),
      () => find.descendant(of: find.byType(AppearanceScreen), matching: find.byType(ListView)).first,
    ),
  ];

  for (final (tag, size) in [
    ('tablet held sideways', const Size(1280, 800)),
    ('tablet', quickWinsTablet),
    ('phone', quickWinsPhone),
  ]) {
    group('$tag ${size.width.toInt()}x${size.height.toInt()}', () {
      final wide = size.width < kPhonePageMaxWidth ? size.width : kPhonePageMaxWidth;

      for (final (name, page, content) in pages) {
        testWidgets('$name: its content ${wide.toInt()} wide, centred', (tester) async {
          debugTouchLayout = true;
          debugDefaultTargetPlatformOverride = TargetPlatform.android;
          try {
            await pumpQuickWins(tester, page, size);
            final rect = tester.getRect(content());
            expect(rect.width, wide);
            expect(rect.center.dx, size.width / 2);
            await unpumpQuickWins(tester);
          } finally {
            debugTouchLayout = null;
            debugDefaultTargetPlatformOverride = null;
          }
        });
      }

      // The More tab (it ran the full
      // width on a tablet); a phone's keeps the whole width.
      testWidgets('the More tab: its content ${wide.toInt()} wide, centred', (tester) async {
        debugTouchLayout = true;
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          await pumpQuickWins(tester, const HomeScreen(), size);
          await tester.tap(find.descendant(
              of: find.byKey(const ValueKey('phone-tab-bar')), matching: find.byKey(const ValueKey('phone-tab-4'))));
          await settleQuickWins(tester);
          final more = tester.getRect(find.byKey(const ValueKey('phone-more')));
          expect(more.width, wide);
          expect(more.center.dx, size.width / 2);
          expect(tester.getRect(find.byKey(const ValueKey('more-settings'))).width, lessThanOrEqualTo(wide));
          await unpumpQuickWins(tester);
        } finally {
          debugTouchLayout = null;
          debugDefaultTargetPlatformOverride = null;
        }
      });
    });
  }
}
