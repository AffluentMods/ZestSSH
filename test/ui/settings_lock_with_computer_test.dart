import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/settings_inline_view.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';

/// "Lock when the computer locks" in a computer's Settings (from a security
/// review): with the
/// app lock on it shows under Security, on by default, and turning it off is
/// kept with the app lock's other settings; without the app lock it does not
/// show.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  const storage = FlutterSecureStorage();
  final row = find.byKey(const ValueKey('settings-lock-with-computer'));

  Future<void> pump(WidgetTester tester, {required bool lockOn}) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'security_lock_enabled': lockOn, kSettingsLastSectionKey: 'security'});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1100, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: Scaffold(body: SettingsInlineView()),
        ),
      ),
    );
    await settle(tester);
  }

  bool switchOn(WidgetTester tester) =>
      tester.widget<ZestSwitch>(find.descendant(of: row, matching: find.byType(ZestSwitch))).value;

  testWidgets('with the app lock: shown, on by default, and turned off and on again', (tester) async {
    await pump(tester, lockOn: true);
    expect(row, findsOneWidget);
    expect(find.descendant(of: row, matching: find.text(en.secSetLockWithComputer)), findsOneWidget);
    // What it does is behind its More (4.0: rows one line plus More).
    expect(find.descendant(of: row, matching: find.text(en.secSetLockWithComputerDesc)), findsNothing);
    await tester.tap(find.byKey(ValueKey('settings-row-more-${en.secSetLockWithComputer}')));
    await tester.pump();
    expect(find.descendant(of: row, matching: find.text(en.secSetLockWithComputerDesc)), findsOneWidget);
    expect(switchOn(tester), isTrue);

    await tester.tap(find.descendant(of: row, matching: find.byType(ZestSwitch)));
    await settle(tester);
    expect(await tester.runAsync(() => storage.read(key: 'security_lock_with_computer')), 'off');
    expect(switchOn(tester), isFalse);

    await tester.tap(find.descendant(of: row, matching: find.byType(ZestSwitch)));
    await settle(tester);
    expect(await tester.runAsync(() => storage.read(key: 'security_lock_with_computer')), isNull);
    expect(switchOn(tester), isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('without the app lock: not shown', (tester) async {
    await pump(tester, lockOn: false);
    expect(find.text(en.settingsInlineAppLock), findsWidgets, reason: 'on the Security page');
    expect(row, findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}

/// Lets secure storage finish.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}
