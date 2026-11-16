import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/settings_inline_view.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';

/// A computer's Settings pop-up is 30% larger than it was (980 by 700 then,
/// 1274 by 910 now), and
/// never larger than the window.
void main() {
  Future<void> open(WidgetTester tester, Size window) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSettingsPopup(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  Future<Size> popupIn(WidgetTester tester, Size window) async {
    await open(tester, window);
    final size = tester.getSize(find.ancestor(of: find.byType(SettingsInlineView), matching: find.byType(Material)).first);
    await close(tester);
    return size;
  }

  testWidgets('in a large window it is 1274 by 910', (tester) async {
    expect(await popupIn(tester, const Size(1920, 1080)), const Size(1274, 910));
  });

  testWidgets('in a small window it is as large as the window lets it be, less its margin', (tester) async {
    final size = await popupIn(tester, const Size(1280, 800));
    expect(size.width, 1280 - 48);
    expect(size.height, 800 - 48);
  });

  // Reset all settings stands under the app's own section header, in red, as
  // every Danger zone does (not a red heading
  // in sans of its own).
  // 4.0: it is Backups and data's, with this device's data (it was General's).
  testWidgets("Reset all settings is in Backups and data's Danger zone, under the app's section header in red",
      (tester) async {
    final en = lookupAppLocalizations(const Locale('en'));
    await open(tester, const Size(1920, 1080));
    await tester.tap(find.byKey(const ValueKey('settings-nav-data')));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    final reset = find.byKey(const ValueKey('settings-danger-zone'));
    expect(find.descendant(of: reset, matching: find.text(en.settingsInlineResetAllSettings)), findsOneWidget);
    expect(find.descendant(of: reset, matching: find.text(en.settingsResetAllHelp)), findsOneWidget,
        reason: 'a danger row says all it does');
    final danger = find.byWidgetPredicate((w) => w is ZestSectionHeader && w.danger);
    expect(tester.widget<ZestSectionHeader>(danger).label, en.accountDangerZone);
    expect(tester.getTopLeft(danger).dy, lessThan(tester.getTopLeft(reset).dy));
    await close(tester);
  });
}
