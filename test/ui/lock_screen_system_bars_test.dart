import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/security/security_lock_screen.dart';

/// A computer's lock screen at a small window's size (360 by 640) with a phone's
/// bars, as on 4 Nov 2026: its content is centred, with room above and below.
/// With the status bar 24 high and the navigation bar 48, the PIN box and its
/// arrow never sit under either, upright or on its side (where the navigation bar
/// is at the side), and with a touch keyboard up (a Windows tablet) the PIN box
/// stays in sight and the keyboard's Done tries the PIN. A phone's own lock, with
/// its number pad and no system keyboard, is held to its bars in
/// test/ui/screens/lock_screen_test.dart.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  Future<void> open(
    WidgetTester tester,
    Size size,
    FakeViewPadding bars, {
    double keyboard = 0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.viewPadding = bars;
    // With the keyboard up it covers the navigation bar: no padding below.
    tester.view.padding = keyboard > 0
        ? FakeViewPadding(left: bars.left, top: bars.top, right: bars.right)
        : bars;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.reset);
    FlutterSecureStorage.setMockInitialValues({
      'security_lock_method': 'pin',
      'security_pin_hash': 'not this one',
    });
    SharedPreferences.setMockInitialValues({'security_lock_enabled': true});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: SecurityLockScreen(),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Rect field(WidgetTester tester) => tester.getRect(find.byKey(const ValueKey('lock-pin-box')));
  Rect unlock(WidgetTester tester) => tester.getRect(find.byKey(const ValueKey('lock-go')));

  testWidgets(
    'upright: the PIN box and its arrow clear of the status bar and the navigation bar',
    (tester) async {
      const size = Size(360, 640);
      await open(tester, size, const FakeViewPadding(top: 24, bottom: 48));
      expect(field(tester).top, greaterThanOrEqualTo(24));
      expect(unlock(tester).bottom, lessThanOrEqualTo(size.height - 48));
    },
  );

  testWidgets(
    'on its side, with the navigation bar at the side: clear of it and of the status bar',
    (tester) async {
      const size = Size(640, 360);
      await open(tester, size, const FakeViewPadding(top: 24, right: 48));
      for (final rect in [field(tester), unlock(tester)]) {
        expect(rect.top, greaterThanOrEqualTo(24));
        expect(rect.right, lessThanOrEqualTo(size.width - 48));
      }
    },
  );

  testWidgets(
    'a touch keyboard up: the PIN box in sight, and its Done tries the PIN',
    (tester) async {
      const size = Size(360, 640);
      const keyboard = 300.0;
      await open(
        tester,
        size,
        const FakeViewPadding(top: 24, bottom: 48),
        keyboard: keyboard,
      );
      await tester.tap(find.byType(TextField));
      await tester.pump(const Duration(milliseconds: 300));
      expect(field(tester).top, greaterThanOrEqualTo(24));
      expect(field(tester).bottom, lessThanOrEqualTo(size.height - keyboard));

      await tester.enterText(find.byType(TextField), '1234');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      // The PIN was tried: a wrong one is said so under the box.
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('lock-message'))).data,
        startsWith(en.lockWrongPinTries(9, 30).split('.').first),
        reason: 'Done tried the PIN',
      );
    },
  );
}
