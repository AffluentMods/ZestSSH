import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/idle_lock_providers.dart';
import 'package:zestssh/ui/screens/security/security_settings_screen.dart';

/// The phone's Security screen (3.0): with the app lock on, how
/// long away before it locks (a choice phones did not have) and "Lock when
/// idle", each chosen from a short list and kept; an Orchard's own limit is
/// named; without the app lock neither shows.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  const storage = FlutterSecureStorage();

  Future<void> pump(WidgetTester tester, {bool lockOn = true, int? team}) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'security_lock_enabled': lockOn});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(420, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        teamIdleLockMinutesProvider.overrideWithValue(team),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: SecuritySettingsScreen(),
      ),
    ));
    await settle(tester);
  }

  final idle = find.byKey(const ValueKey('security-idle-lock'));
  final away = find.byKey(const ValueKey('security-auto-lock'));
  Finder inTile(Finder tile, String text) => find.descendant(of: tile, matching: find.textContaining(text));

  testWidgets('Lock when idle: off at first, then chosen and kept', (tester) async {
    await pump(tester);
    expect(idle, findsOneWidget);
    // What it does behind its More (4.0), what it is set to in sight.
    expect(inTile(idle, l10n.secSetIdleLockDesc), findsNothing);
    expect(inTile(idle, l10n.secSetIdleLockOff), findsOneWidget);

    await tester.tap(idle);
    await settle(tester);
    await tester.tap(find.text(l10n.settingsInlineMinutesOption(10)).last);
    await settle(tester);
    expect(await tester.runAsync(() => storage.read(key: 'security_idle_lock_minutes')), '10');
    expect(inTile(idle, l10n.settingsInlineMinutesOption(10)), findsOneWidget);

    // And off again.
    await tester.tap(idle);
    await settle(tester);
    await tester.tap(find.text(l10n.secSetIdleLockOff).last);
    await settle(tester);
    expect(await tester.runAsync(() => storage.read(key: 'security_idle_lock_minutes')), isNull);
  });

  testWidgets('Auto-lock: phones can choose how long away, too', (tester) async {
    await pump(tester);
    expect(away, findsOneWidget);
    await tester.tap(away);
    await settle(tester);
    await tester.tap(find.text(l10n.settingsInlineNever).last);
    await settle(tester);
    expect(await tester.runAsync(() => storage.read(key: 'security_auto_lock_timeout')), '-1');
    expect(inTile(away, l10n.settingsInlineNever), findsOneWidget);
  });

  testWidgets('an Orchard that asks for it is named', (tester) async {
    await pump(tester, team: 15);
    expect(inTile(idle, l10n.secSetIdleLockTeam(15)), findsOneWidget);
  });

  testWidgets('without the app lock: neither shows', (tester) async {
    await pump(tester, lockOn: false);
    expect(idle, findsNothing);
    expect(away, findsNothing);
  });
}

/// Lets secure storage and the sheet finish.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}
