// How often hosts are checked for being reachable, on a phone (found
// while comparing the five versions): a computer offers 30
// seconds, 1, 2 and 5 minutes, and its setting is synced; a phone's two pages
// offered no 2 minutes and named anything over a minute "5 minutes", so a
// computer's 2 minutes showed as 5 there, with nothing marked in the choice.
// Now every device offers the same four, and names each as it is.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/settings/notification_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/reachability_checks_setting.dart';
import 'package:zestssh/ui/screens/settings/settings_screen.dart';

final _l10n = lookupAppLocalizations(const Locale('en'));

class _NoOrchards implements OrchardDatabaseStorage {
  @override
  Future<bool> exists(String orchardId) async => false;

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async => throw StateError('no Orchard here');

  @override
  Future<void> delete(String orchardId) async {}

  @override
  Future<List<String>> list() async => const [];
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('every device offers 30 seconds, 1, 2 and 5 minutes, and names an interval as it is', () {
    expect(reachabilityCheckIntervals, [30, 60, 120, 300]);
    expect([for (final s in [30, 60, 120, 300, 45, 90, 600]) reachabilityCheckIntervalLabel(_l10n, s)],
        ['30 seconds', '1 minute', '2 minutes', '5 minutes', '45 seconds', '90 seconds', '10 minutes']);
  });

  late AppDatabase db;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  Future<ProviderContainer> pump(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'reachability_checks_enabled': true, 'health_check_interval': 120});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      recordingModeProvider.overrideWith((ref) => false),
      databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
      orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
    ]);
    addTearDown(container.dispose);
    final router = GoRouter(routes: [GoRoute(path: '/', builder: (context, state) => screen)]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
      ),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  for (final (name, screen) in [
    ("a phone's Settings", const SettingsScreen() as Widget),
    ('its Notifications page', const NotificationSettingsScreen() as Widget),
  ]) {
    testWidgets("$name: a computer's 2 minutes named so and marked, and the four offered", (tester) async {
      final c = await pump(tester, screen);
      final row = find.widgetWithText(ListTile, _l10n.settingsInlineCheckInterval);
      await tester.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
      expect(find.descendant(of: row, matching: find.text('2 minutes')), findsOneWidget, reason: 'it said 5 minutes');
      await tester.tap(row);
      await tester.pumpAndSettle();
      for (final s in [30, 60, 120, 300]) {
        expect(find.byKey(ValueKey('reach-interval-$s')), findsOneWidget, reason: '$s');
      }
      // The one set is picked (the app's sheet of choices, its dot radios:
      // a pick-one choice is a dot).
      final semantics = tester.ensureSemantics();
      for (final (s, picked) in [(120, true), (300, false)]) {
        expect(
            tester.getSemantics(
                find.descendant(of: find.byKey(ValueKey('reach-interval-$s')), matching: find.byType(Radio<int>))),
            isSemantics(isChecked: picked, isInMutuallyExclusiveGroup: true),
            reason: '$s');
      }
      semantics.dispose();
      await tester.tap(find.text('5 minutes'));
      await tester.pumpAndSettle();
      expect(c.read(healthCheckIntervalProvider), 300);
      expect(find.descendant(of: row, matching: find.text('5 minutes')), findsOneWidget);
    });
  }
}
