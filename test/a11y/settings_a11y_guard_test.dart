import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:flutter/foundation.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/settings_inline_view.dart';
import 'package:zestssh/ui/screens/settings/settings_screen.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

import '../visual/shots_util.dart';
import 'a11y_checks.dart';

class _NoOrchards implements OrchardDatabaseStorage {
  @override
  Future<bool> exists(String orchardId) async => false;
  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async => throw StateError('no team here');
  @override
  Future<void> delete(String orchardId) async {}
  @override
  Future<List<String>> list() async => const [];
}

/// Settings, every page, on a computer and on a phone, held to the 4.0
/// accessibility pass: every control a screen reader can
/// press has a name, a pointer's target is 32 square on a computer and 48 on
/// a phone, the words read on what they are drawn on, and a larger text size
/// lays out without overflowing.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  var fonts = false;

  Future<void> pump(WidgetTester tester, Widget page,
      {required Size size,
      String theme = 'default_dark',
      double textScale = 1,
      Map<String, Object> prefs = const {},
      bool touch = false}) async {
    if (!fonts) {
      await tester.runAsync(loadShotFonts);
      fonts = true;
    }
    final t = BuiltInThemes.getById(theme);
    AppColors.applyTheme(t.colorScheme);
    // A phone's Settings at a phone's sizes: touch sized (the theme made on
    // the computer running the tests drew a mouse's, and the 48 checks held
    // what a phone never shows).
    debugTouchLayout = touch ? true : null;
    addTearDown(() => debugTouchLayout = null);
    addTearDown(() => AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme));
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(prefs);
    final shared = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(shared),
      databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
      orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
      syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 11, 12, 12))),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: t.toThemeData(compact: touch ? false : null),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: page,
      ),
    ));
    await settleA11y(tester);
  }

  Future<void> takeDown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 10));
  }

  const pages = [
    'account', 'plan', 'general', 'appearance', 'keyboard', 'notifications', //
    'terminal', 'files', 'screens', 'security', 'data', 'about',
  ];

  for (final theme in ['default_dark', 'default_light']) {
    testWidgets('$theme: a computer\'s every Settings page: names, targets, contrast', (tester) async {
      final handle = tester.ensureSemantics();
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final failures = <String>[];
        for (final page in pages) {
          await pump(tester, const Scaffold(body: SettingsInlineView()),
              size: const Size(1274, 3600), theme: theme, prefs: {kSettingsLastSectionKey: page});
          failures.addAll(await a11yCheck(tester, computer: true, where: 'Settings, $page'));
        }
        expect(failures, isEmpty);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        handle.dispose();
      }
      await takeDown(tester);
    });
  }

  testWidgets('a computer\'s Settings at 150% text: no page overflows', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      for (final page in pages) {
        await pump(tester, const Scaffold(body: SettingsInlineView()),
            size: const Size(1274, 4000), textScale: 1.5, prefs: {kSettingsLastSectionKey: page});
        expect(tester.takeException(), isNull, reason: 'Settings, $page at 150%');
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    await takeDown(tester);
  });

  testWidgets('a phone\'s Settings: names, 48 targets, contrast; and at 200% text nothing overflows', (tester) async {
    final handle = tester.ensureSemantics();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pump(tester, const SettingsScreen(), size: const Size(412, 2400), touch: true);
      await expectA11y(tester, computer: false, where: 'phone Settings');
      await pump(tester, const SettingsScreen(), size: const Size(412, 4000), textScale: 2, touch: true);
      expect(tester.takeException(), isNull);
      expect(find.text(en.settingsAccount), findsWidgets);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      handle.dispose();
    }
    await takeDown(tester);
  });
}
