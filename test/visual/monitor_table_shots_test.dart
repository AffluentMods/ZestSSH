import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/monitor_table_view.dart';
import 'package:zestssh/ui/screens/monitoring/server_monitor_screen.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

import '../helpers/monitor_table_fixture.dart';
import 'shots_util.dart';

/// Pictures of the computer's Server monitor table (as
/// designed), with the real fonts and a made-up fleet:
///
///   flutter test --dart-define=ZEST_SHOTS=true --dart-define=ZEST_ORCHARDS=true test/visual/monitor_table_shots_test.dart
///
/// Pictures land in build/shots/. Another language with
/// --dart-define=ZEST_SHOT_LOCALE=de.
const _locale = String.fromEnvironment('ZEST_SHOT_LOCALE', defaultValue: 'en');

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale(_locale));

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';
    testWidgets('the table on a computer ($tag)', (tester) async {
      realShadows();
      await tester.runAsync(loadShotFonts);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        L10nGlobal.update(l10n);
        final theme = BuiltInThemes.getById(themeId);
        AppColors.applyTheme(theme.colorScheme);
        tester.view.physicalSize = const Size(1440, 860);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fleet = MonitorFleet();
        final db = await fleet.database();
        final prefs = await fleet.preferences();
        final key = GlobalKey();
        await tester.pumpWidget(RepaintBoundary(
          key: key,
          child: fleet.app(fleet.overrides(db, prefs), const MonitorTableView(),
              theme: theme.toThemeData(), locale: const Locale(_locale)),
        ));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await saveShot(tester, key, 'monitor_table_$tag');
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
        await db.close();
      } finally {
        debugDefaultTargetPlatformOverride = null;
        plainShadows();
      }
    }, skip: !shotsEnabled);
  }

  testWidgets('the phone Monitor tab with the same fleet (dark)', (tester) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    // A phone's look (the app asks the system; a test on a computer says so).
    debugTouchLayout = true;
    try {
      L10nGlobal.update(l10n);
      final theme = BuiltInThemes.getById('graphite');
      AppColors.applyTheme(theme.colorScheme);
      tester.view.physicalSize = const Size(390, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fleet = MonitorFleet();
      final db = await fleet.database();
      final prefs = await fleet.preferences();
      final key = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
        key: key,
        child: fleet.app(fleet.overrides(db, prefs), const ServerMonitorScreen(),
            theme: theme.toThemeData(), locale: const Locale(_locale)),
      ));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await saveShot(tester, key, 'monitor_table_phone');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
      await db.close();
    } finally {
      debugDefaultTargetPlatformOverride = null;
      debugTouchLayout = null;
      plainShadows();
    }
  }, skip: !shotsEnabled);
}
