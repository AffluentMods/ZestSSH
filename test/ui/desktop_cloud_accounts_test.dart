import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/features/cloud_import/ui/cloud_accounts_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/settings_inline_view.dart';

/// A computer's Settings lists the cloud accounts kept in sync on it (found
/// by a check of the docs against the code): only a
/// phone's Data page listed them, so a computer could not check one now or
/// stop it. They are Backups and data's (4.0; they were General's).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  testWidgets("a computer's Backups and data settings list the cloud accounts, under Data", (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({kSettingsLastSectionKey: 'data'});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    tester.view.physicalSize = const Size(1100, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: SettingsInlineView()),
      ),
    ));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(CloudAccountsTiles), findsOneWidget);
    final tile = find.byKey(const ValueKey('cloud-accounts'));
    expect(find.descendant(of: tile, matching: find.text(en.cloudAccTitle)), findsOneWidget);
    expect(find.descendant(of: tile, matching: find.text(en.cloudAccNone)), findsOneWidget);
    expect(tester.widget<Text>(find.descendant(of: tile, matching: find.text(en.cloudAccNone))).style?.color,
        ZestTokens.textSecondary, reason: 'quieter than its title, as the other settings rows');
    expect(find.text(en.accountData.toUpperCase()).evaluate().length +
        find.text(en.accountData).evaluate().length, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}
