import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/triggers/trigger_runtime.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/redaction_providers.dart';
import 'package:zestssh/providers/trigger_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/triggers_view.dart';

import 'shots_util.dart';

/// Pictures of a computer's Alerts page (terminal triggers; 3.0, as
/// designed), with the real fonts:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/alerts_shots_test.dart
///
/// Pictures land in build/shots/. Every name on them is made up. Another
/// language with --dart-define=ZEST_SHOT_LOCALE=de.
const _locale = String.fromEnvironment('ZEST_SHOT_LOCALE', defaultValue: 'en');

void main() {
  final l10n = lookupAppLocalizations(const Locale(_locale));

  TerminalTrigger alert(String id, String name, String pattern,
          {bool notify = true, bool sound = false, int? highlight, bool on = true}) =>
      TerminalTrigger(
        id: id,
        name: name,
        pattern: pattern,
        caseSensitive: false,
        notify: notify,
        highlight: highlight != null,
        highlightColor: highlight,
        playSound: sound,
        connectionId: null,
        enabled: on,
        sortOrder: 0,
        createdAt: DateTime(2026, 10, 1),
      );

  final rows = [
    alert('a1', 'Error', r'(?i)\b(error|failed|fatal)\b', sound: true, highlight: 0xFFEF4444, on: false),
    alert('a2', 'Build finished', r'(?i)build (succeeded|successful|finished|complete)', sound: true),
    alert('a3', 'Warning', r'(?i)\bwarn(ing)?\b', sound: true, highlight: 0xFFEAB308),
  ];

  Future<GlobalKey> shown(WidgetTester tester, String themeId, {Size size = const Size(1440, 900)}) async {
    L10nGlobal.update(l10n);
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
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          redactionFleetRegistrar.overrideWith((ref) {}),
          triggerRuntimeProvider.overrideWith((ref) {
            final rt = TriggerRuntime.forTesting(ref);
            ref.onDispose(rt.dispose);
            return rt;
          }),
          triggersProvider.overrideWith((ref) => Stream.value(rows)),
          triggerScopeConnectionsProvider.overrideWith((ref) => Stream.value(const <Connection>[])),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BuiltInThemes.getById(themeId).toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale(_locale),
          home: const Scaffold(body: TriggersView()),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return key;
  }

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';
    testWidgets('Alerts page ($tag)', (tester) async {
      if (!shotsEnabled) return;
      realShadows();
      await tester.runAsync(loadShotFonts);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final key = await shown(tester, themeId);
        // As the mockup: Build finished picked, highlighted in green.
        await tester.tap(find.byKey(const ValueKey('alert-preset-buildFinished')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('alert-test-line')), '==> Build finished in 42.1s');
        await tester.tap(find.byKey(const ValueKey('alert-sound')));
        await tester.tap(find.byKey(const ValueKey('alert-highlight')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('alert-colour-ff22c55e')));
        await tester.pumpAndSettle();
        await saveShot(tester, key, 'alerts_${tag}_$_locale');
        // Regex mode.
        await tester.tap(find.byKey(const ValueKey('alert-edit-as-regex')));
        await tester.pumpAndSettle();
        await saveShot(tester, key, 'alerts_${tag}_regex');
        // A narrower window: the head and the rows on two lines.
        await tester.pumpWidget(const SizedBox());
        final narrow = await shown(tester, themeId, size: const Size(1100, 800));
        await saveShot(tester, narrow, 'alerts_${tag}_narrow');
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      } finally {
        debugDefaultTargetPlatformOverride = null;
        plainShadows();
      }
    });
  }
}
