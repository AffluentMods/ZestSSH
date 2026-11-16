// A phone's Workflows, with Squeezed, whatever the switch for other apps
// says (found while comparing the five versions): a phone
// hid them while automation for other apps was off, though a workflow is run
// by its person with Squeezed alone, and a computer shows them and says so.
// What other apps use (API keys, the wizard that builds links for them,
// scheduled tasks) still waits for the switch.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/settings/automation_settings_screen.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Juiced, which the plan's chip (Squeezed beside External automation, 4.0)
// asks about: none here.
class _Cloud extends StateNotifier<bool> implements CloudSyncStatusNotifier {
  _Cloud() : super(false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  Future<void> pump(WidgetTester tester, {required bool pro, required bool on}) async {
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => tester.runAsync(db.close));
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro(pro)),
      isCloudSyncProvider.overrideWith((ref) => _Cloud()),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
    ]);
    addTearDown(c.dispose);
    c.read(automationEnabledProvider.notifier).set(on);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: AutomationSettingsScreen(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('with Squeezed and the switch off: Workflows, and nothing other apps use', (tester) async {
    await pump(tester, pro: true, on: false);
    expect(find.byKey(const ValueKey('automation-workflows-row')), findsOneWidget);
    expect(find.text(en.settingsMobApiKeys), findsNothing);
    expect(find.text(en.settingsMobAutomationWizard), findsNothing);
    expect(find.text(en.settingsMobScheduledTasks), findsNothing);
  });

  testWidgets('with Squeezed and the switch on: Workflows and what other apps use', (tester) async {
    await pump(tester, pro: true, on: true);
    expect(find.byKey(const ValueKey('automation-workflows-row')), findsOneWidget);
    expect(find.text(en.settingsMobApiKeys), findsOneWidget);
    expect(find.text(en.settingsMobAutomationWizard), findsOneWidget);
  });

  testWidgets('without Squeezed: no Workflows', (tester) async {
    await pump(tester, pro: false, on: false);
    expect(find.byKey(const ValueKey('automation-workflows-row')), findsNothing);
  });
}
