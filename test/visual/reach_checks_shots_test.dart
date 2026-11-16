import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/settings/notification_settings_screen.dart';

import 'shots_util.dart';

/// Pictures of the setting for the checks of whether hosts can be reached,
/// and of the question before they are turned on (3.0), with the real fonts:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/reach_checks_shots_test.dart
///
/// Pictures land in build/shots/. Another language with
/// --dart-define=ZEST_SHOT_LOCALE=de.
const _locale = String.fromEnvironment('ZEST_SHOT_LOCALE', defaultValue: 'en');

void main() {
  final l10n = lookupAppLocalizations(const Locale(_locale));

  Future<void> pictures(WidgetTester tester, String themeId, Size size, String tag) async {
    AppColors.applyTheme(BuiltInThemes.getById(themeId).colorScheme);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BuiltInThemes.getById(themeId).toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale(_locale),
          home: const NotificationSettingsScreen(),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'reach_${tag}_1_off');
    await tester.tap(find.byKey(const ValueKey('settings-reach-checks')));
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'reach_${tag}_2_asked');
    await tester.tap(find.text(l10n.reachChecksAskTurnOn).last);
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'reach_${tag}_3_on');
    await tester.pumpWidget(const SizedBox());
  }

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';
    testWidgets('on a computer ($tag)', (tester) async {
      realShadows();
      await tester.runAsync(loadShotFonts);
      // Drawn as on a computer: the theme sizes its controls by platform,
      // and tests run as Android unless told.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await pictures(tester, themeId, const Size(1100, 800), tag);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        plainShadows();
      }
    }, skip: !shotsEnabled);
  }

  testWidgets('on a phone (dark)', (tester) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pictures(tester, 'graphite', const Size(390, 844), 'phone');
    } finally {
      debugDefaultTargetPlatformOverride = null;
      plainShadows();
    }
  }, skip: !shotsEnabled);
}
