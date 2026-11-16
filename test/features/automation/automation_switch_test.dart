// Turning automation on and off, the one way every switch for it does
// (found while comparing the five platforms' versions). A phone's
// switch asked first what turning it on lets in, and was Squeezed's alone;
// a computer's (its Automation page's engine, and the off notice's Turn on)
// turned it on for anyone with no word, named itself in English in every
// language, and set the saved setting alone, which the engine had read once
// as it started.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/automation/automation_switch.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/automation_view.dart';
import 'package:zestssh/ui/screens/settings/automation_settings_screen.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  test('the engine follows the setting wherever it is switched', () async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(c.dispose);
    expect(c.read(automationProvider).enabled, isFalse);
    c.read(automationEnabledProvider.notifier).set(true);
    expect(c.read(automationProvider).enabled, isTrue);
    c.read(automationEnabledProvider.notifier).set(false);
    expect(c.read(automationProvider).enabled, isFalse);
  });

  /// The app over a router, its first page holding a button that does
  /// [action]; [pro] says whether this account has Squeezed.
  Future<(ProviderContainer, GoRouter)> app(WidgetTester tester, Future<void> Function(BuildContext, WidgetRef) action,
      {required bool pro, Widget? page, Locale locale = const Locale('en')}) async {
    // Wide: the test font is far wider than the app's, and the French head
    // and editor foot ran over at 1400 in it (and only in it).
    tester.view.physicalSize = const Size(2000, 900);
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
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
    ]);
    addTearDown(c.dispose);
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(
          body: page ??
              Consumer(builder: (context, ref, _) => TextButton(onPressed: () => action(context, ref), child: const Text('go'))),
        ),
      ),
      GoRoute(path: Routes.upgrade, builder: (_, _) => const Scaffold(body: Text('the upgrade page'))),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();
    return (c, router);
  }

  testWidgets('turning it on asks first what that lets in: Cancel leaves it off, Enable turns it on, the engine too',
      (tester) async {
    final (c, _) = await app(tester, (context, ref) => setAutomationOn(context, ref, true), pro: true);
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text(en.settingsMobEnableExternalAutomationTitle), findsOneWidget);
    await tester.tap(find.text(en.cancel));
    await tester.pumpAndSettle();
    expect((c.read(automationEnabledProvider), c.read(automationProvider).enabled), (false, false));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.commonEnable));
    await tester.pumpAndSettle();
    expect((c.read(automationEnabledProvider), c.read(automationProvider).enabled), (true, true));
  });

  testWidgets('turning it off asks nothing', (tester) async {
    final (c, _) = await app(tester, (context, ref) => setAutomationOn(context, ref, false), pro: true);
    c.read(automationEnabledProvider.notifier).set(true);
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text(en.settingsMobEnableExternalAutomationTitle), findsNothing);
    expect((c.read(automationEnabledProvider), c.read(automationProvider).enabled), (false, false));
  });

  testWidgets('without Squeezed it is not turned on: the upgrade page is opened', (tester) async {
    final (c, _) = await app(tester, (context, ref) => setAutomationOn(context, ref, true), pro: false);
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('the upgrade page'), findsOneWidget);
    expect(find.text(en.settingsMobEnableExternalAutomationTitle), findsNothing);
    expect(c.read(automationEnabledProvider), isFalse);
  });

  testWidgets("a phone's switch asks first, and turns the engine on with it", (tester) async {
    final (c, _) = await app(tester, (_, _) async {}, pro: true, page: const AutomationSettingsScreen());
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();
    expect(find.text(en.settingsMobEnableExternalAutomationTitle), findsOneWidget);
    await tester.tap(find.text(en.commonEnable));
    await tester.pumpAndSettle();
    expect((c.read(automationEnabledProvider), c.read(automationProvider).enabled), (true, true));
  });

  group("a computer's Automation page", () {
    final fr = lookupAppLocalizations(const Locale('fr'));

    testWidgets("its toggle says its state in the person's language, asks first, and its notice's Turn on too", (tester) async {
      final (c, _) = await app(tester, (_, _) async {}, pro: true, page: const AutomationView(), locale: const Locale('fr'));
      // Its switch is named in the person's language (as designed:
      // "Automations on" and the switch, in the page's head).
      expect(find.text(fr.autoAutomationsOn), findsOneWidget);
      expect(find.text('Automations on'), findsNothing);
      expect(find.text('Engine'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('automation-engine-toggle')));
      await tester.pumpAndSettle();
      expect(find.text(fr.settingsMobEnableExternalAutomationTitle), findsOneWidget);
      // (The page has a Cancel of its own: the question's is over it.)
      await tester.tap(find.text(fr.cancel).last);
      await tester.pumpAndSettle();
      expect(c.read(automationEnabledProvider), isFalse);
      await tester.tap(find.byKey(const ValueKey('automation-turn-on')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(fr.commonEnable));
      await tester.pumpAndSettle();
      expect((c.read(automationEnabledProvider), c.read(automationProvider).enabled), (true, true));
      expect(tester.widget<ZestSwitch>(find.byKey(const ValueKey('automation-engine-toggle'))).value, isTrue);
    });

    testWidgets('without Squeezed its engine does nothing, and its notice upgrades', (tester) async {
      final (c, _) = await app(tester, (_, _) async {}, pro: false, page: const AutomationView());
      await tester.tap(find.byKey(const ValueKey('automation-engine-toggle')));
      await tester.pumpAndSettle();
      expect(find.text(en.settingsMobEnableExternalAutomationTitle), findsNothing);
      expect(c.read(automationEnabledProvider), isFalse);
      expect(find.text(en.automationTurnOn), findsNothing);
      await tester.tap(find.text(en.settingsUpgradePro));
      await tester.pumpAndSettle();
      expect(find.text('the upgrade page'), findsOneWidget);
    });
  });
}
