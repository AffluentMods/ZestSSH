import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/redaction_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/automation_view.dart';

import 'shots_util.dart';

/// Pictures of a computer's Automation page (3.0, as
/// designed), with the real fonts:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/automation_shots_test.dart
///
/// Pictures land in build/shots/. Every host, group and name on them is made
/// up. Another language with --dart-define=ZEST_SHOT_LOCALE=de.
const _locale = String.fromEnvironment('ZEST_SHOT_LOCALE', defaultValue: 'en');

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale(_locale));

  Future<AppDatabase> seeded() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final made = DateTime(2026, 1, 1);
    // The demo world's hosts and groups (the website's).
    await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(id: 'g-web', name: 'Web', createdAt: made));
    await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(id: 'g-hv', name: 'Hypervisors', createdAt: made));
    const groups = {'web-01': 'g-web', 'web-02': 'g-web', 'hypervisor-a': 'g-hv', 'hypervisor-b': 'g-hv'};
    var i = 0;
    for (final label in ['web-01', 'web-02', 'hypervisor-a', 'hypervisor-b', 'db-primary', 'cache-01', 'monitoring']) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'h-$label',
            label: label,
            host: '$label.example.internal',
            groupId: Value(groups[label]),
            sortOrder: Value(i++),
            createdAt: made,
            updatedAt: made,
          ));
    }
    return db;
  }

  Future<(AppDatabase, GlobalKey)> shown(WidgetTester tester, String themeId) async {
    L10nGlobal.update(l10n);
    AppColors.applyTheme(BuiltInThemes.getById(themeId).colorScheme);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'automation_enabled': true});
    final prefs = await SharedPreferences.getInstance();
    final db = (await tester.runAsync(seeded))!;
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          databaseProvider.overrideWithValue(db),
          redactionFleetRegistrar.overrideWith((ref) {}),
          isProProvider.overrideWith((ref) => _Pro()),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BuiltInThemes.getById(themeId).toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale(_locale),
          home: const Scaffold(body: AutomationView()),
        ),
      ),
    ));
    await settle(tester);
    return (db, key);
  }

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';
    testWidgets('Automation page ($tag)', (tester) async {
      if (!shotsEnabled) return;
      realShadows();
      await tester.runAsync(loadShotFonts);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final (db, key) = await shown(tester, themeId);
        await saveShot(tester, key, 'automation_${tag}_empty_$_locale');
        // As the design: Update packages on a group, opened beside it.
        await tester.tap(find.descendant(
            of: find.byKey(const ValueKey('automation-template-updatePackages')), matching: find.text(l10n.autoTplUse)));
        await settle(tester);
        await saveShot(tester, key, 'automation_${tag}_add_snippet');
        await tester.tap(find.text(l10n.autoTplAddSnippetAction));
        await settle(tester);
        await saveShot(tester, key, 'automation_${tag}_template_$_locale');
        await tester.pumpWidget(const SizedBox());
        // Past the longest a toast stays (the snippet's "saved" one set a
        // timer that was still pending as the test ended).
        await tester.pump(const Duration(seconds: 11));
        await tester.runAsync(db.close);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        plainShadows();
      }
    });
  }
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}
