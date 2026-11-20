import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/shortcuts/default_bindings.dart';
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/settings_inline_view.dart';
import 'package:zestssh/ui/screens/security/security_settings_screen.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';

/// "Open sessions on ZestSSH's lock screen" (4.0.1): under Security with the
/// app lock on, a choice of nothing (the default), how many, or how many and
/// their names; kept by the computer (the lock screen reads it before any
/// profile is open), put back to nothing by Reset all settings, and 4.0's
/// switch read as how many; on a computer and on a phone. And Lock ZestSSH's
/// key leaves bare Ctrl+L to the terminal.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  Future<ProviderContainer> pump(WidgetTester tester, Widget page, {required Size size, bool lockOn = true}) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'security_lock_enabled': lockOn, kSettingsLastSectionKey: 'security'});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: page,
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    return container;
  }

  Future<void> takeDown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  testWidgets("a computer's Security settings: nothing by default, each choice, and kept", (tester) async {
    final c = await pump(tester, const Scaffold(body: SettingsInlineView()), size: const Size(1100, 4000));
    final row = find.byKey(const ValueKey('settings-lock-sessions'));
    expect(row, findsOneWidget);
    expect(find.descendant(of: row, matching: find.text(en.secSetLockShowSessions)), findsOneWidget);
    // What it does is behind its More (4.0: rows one line plus More).
    expect(find.descendant(of: row, matching: find.text(en.secSetLockShowSessionsDesc)), findsNothing);
    await tester.tap(find.byKey(ValueKey('settings-row-more-${en.secSetLockShowSessions}')));
    await tester.pump();
    expect(find.descendant(of: row, matching: find.text(en.secSetLockShowSessionsDesc)), findsOneWidget);
    final select = find.descendant(of: row, matching: find.byType(ZestSelect<LockSessionsShown>));
    expect(tester.widget<ZestSelect<LockSessionsShown>>(select).value, LockSessionsShown.off);
    expect(find.descendant(of: row, matching: find.text(en.lockSessionsShownOff)), findsOneWidget);

    for (final (choice, words) in [
      (LockSessionsShown.names, en.lockSessionsShownNames),
      (LockSessionsShown.count, en.lockSessionsShownCount),
      (LockSessionsShown.off, en.lockSessionsShownOff),
    ]) {
      await tester.tap(select);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('zest-select-item-$choice')).last);
      await tester.pumpAndSettle();
      expect(c.read(lockSessionsShownProvider), choice);
      expect(c.read(sharedPreferencesProvider).getString('lock_sessions_shown'), choice.name);
      expect(find.descendant(of: row, matching: find.text(words)), findsOneWidget);
    }
    await takeDown(tester);
  });

  testWidgets('a computer without the app lock: no such row', (tester) async {
    await pump(tester, const Scaffold(body: SettingsInlineView()), size: const Size(1100, 4000), lockOn: false);
    expect(find.byKey(const ValueKey('settings-lock-sessions')), findsNothing);
    await takeDown(tester);
  });

  testWidgets("a phone's Security screen: nothing by default, in sight; a choice made", (tester) async {
    final c = await pump(tester, const SecuritySettingsScreen(), size: const Size(420, 1600));
    final tile = find.byKey(const ValueKey('security-lock-sessions'));
    expect(tile, findsOneWidget);
    expect(find.descendant(of: tile, matching: find.text(en.lockSessionsShownOff)), findsOneWidget);
    // (Its words hold its More; the choice opens from the row's arrow.)
    await tester.tap(find.descendant(of: tile, matching: find.byIcon(LucideIcons.chevronRight)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.lockSessionsShownCount).last);
    await tester.pumpAndSettle();
    expect(c.read(lockSessionsShownProvider), LockSessionsShown.count);
    expect(c.read(sharedPreferencesProvider).getString('lock_sessions_shown'), 'count');
    expect(find.descendant(of: tile, matching: find.text(en.lockSessionsShownCount)), findsOneWidget);
    await takeDown(tester);
  });

  test("it is the computer's, and Reset all settings puts it back to nothing", () {
    for (final key in ['lock_sessions_shown', 'lock_show_sessions']) {
      expect(SettingsService.resetKeys, contains(key));
      expect(SettingsService.deviceKeys, contains(key));
      expect(SettingsService.isProfileKey(key), isFalse);
    }
  });

  test("4.0's switch on reads as how many; a choice made takes its place", () async {
    SharedPreferences.setMockInitialValues({'lock_show_sessions': true});
    final prefs = await SharedPreferences.getInstance();
    final service = SettingsService(prefs);
    expect(service.lockSessionsShown, LockSessionsShown.count);
    await service.setLockSessionsShown(LockSessionsShown.names);
    expect(service.lockSessionsShown, LockSessionsShown.names);
    expect(prefs.getBool('lock_show_sessions'), isNull);
    SharedPreferences.setMockInitialValues({});
    expect(SettingsService(await SharedPreferences.getInstance()).lockSessionsShown, LockSessionsShown.off);
  });

  test('Lock ZestSSH is Ctrl+Shift+L: bare Ctrl+L stays the terminal\'s (clear the screen)', () {
    final key = defaultShortcutBindings[ShortcutAction.lockApp]!;
    expect(key.ctrl, isTrue);
    expect(key.shift, isTrue);
    expect(key.alt, isFalse);
    expect(key.meta, isFalse);
    expect(key.displayLabel, 'Ctrl+Shift+L');
  });
}
