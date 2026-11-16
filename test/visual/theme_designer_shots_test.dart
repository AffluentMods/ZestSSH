import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/theme_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/theme/zest_theme.dart';
import 'package:zestssh/ui/screens/desktop/widgets/settings_inline_view.dart';
import 'package:zestssh/ui/screens/desktop/widgets/theme_designer_view.dart';

import 'shots_util.dart';

class _Plan extends StateNotifier<bool> implements ProStatusNotifier {
  _Plan(super.pro);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Pictures of the theme designer's Live preview and of a theme of one's own
/// in the Appearance list (from a review), with the
/// real fonts:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/theme_designer_shots_test.dart
///
/// Pictures land in build/shots/. Every name on them is made up.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<(GlobalKey, ProviderContainer)> shown(WidgetTester tester, String themeId, Widget page, {Size size = const Size(860, 760)}) async {
    L10nGlobal.update(l10n);
    AppColors.applyTheme(BuiltInThemes.getById(themeId).colorScheme);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'app_theme_id': themeId});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Plan(true)),
    ]);
    addTearDown(container.dispose);
    final base = BuiltInThemes.getById('nord');
    await container.read(customAppThemesProvider.notifier).save(ZestTheme(
          id: 'custom_app_1',
          name: 'Harbor Night',
          brightness: base.brightness,
          colorScheme: base.colorScheme.copyWith(id: 'custom_app_1', name: 'Harbor Night'),
        ));
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BuiltInThemes.getById(themeId).toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: page),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return (key, container);
  }

  for (final themeId in ['graphite', 'default_light', 'midnight', 'catppuccin_mocha']) {
    testWidgets('the Live preview, $themeId', (tester) async {
      if (!shotsEnabled) return;
      realShadows();
      await tester.runAsync(loadShotFonts);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final (key, _) = await shown(tester, themeId, ThemeDesignerView(onClose: () {}));
        await saveShot(tester, key, 'theme-designer-$themeId');
      } finally {
        debugDefaultTargetPlatformOverride = null;
        plainShadows();
      }
    });
  }

  // The app themes as a gallery (4.0), a theme of
  // one's own among them: three rows, then every theme after Show all.
  testWidgets("the app themes as a gallery, with a theme of one's own", (tester) async {
    if (!shotsEnabled) return;
    realShadows();
    await tester.runAsync(loadShotFonts);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final (key, _) = await shown(tester, 'graphite', const SettingsInlineView(), size: const Size(1100, 1000));
      await tester.tap(find.text(l10n.settingsInlineSectionAppearance).first);
      await tester.pumpAndSettle();
      await saveShot(tester, key, 'appearance-theme-gallery-graphite');
      await tester.tap(find.byKey(const ValueKey('app-theme-show-all')));
      await tester.pumpAndSettle();
      await saveShot(tester, key, 'appearance-theme-gallery-all-graphite');
    } finally {
      debugDefaultTargetPlatformOverride = null;
      plainShadows();
    }
  });
}
