import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/settings_inline_view.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';

/// Keep screen awake is on by default and held on every platform while a
/// session is live, but a computer had no row to turn it off: only a phone's
/// Settings had one (found in a review). It is in a computer's
/// Terminal settings now.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  testWidgets("a computer's Terminal settings turn it off and on, kept", (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({kSettingsLastSectionKey: 'terminal'});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1100, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: SettingsInlineView()),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    final row = find.byKey(const ValueKey('settings-keep-awake'));
    expect(row, findsOneWidget);
    expect(find.descendant(of: row, matching: find.text(en.settingsKeepAwake)), findsOneWidget);
    final toggle = find.descendant(of: row, matching: find.byType(ZestSwitch));
    expect(tester.widget<ZestSwitch>(toggle).value, isTrue, reason: 'on by default');

    await tester.tap(toggle);
    await tester.pump();
    expect(c.read(keepScreenAwakeProvider), isFalse);
    expect(c.read(settingsServiceProvider).keepScreenAwake, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}
