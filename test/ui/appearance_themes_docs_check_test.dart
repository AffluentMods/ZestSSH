import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/theme_providers.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/settings_inline_view.dart';
import 'package:zestssh/ui/screens/settings/appearance_screen.dart';

class _Plan extends StateNotifier<bool> implements ProStatusNotifier {
  _Plan(super.pro);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Themes, as a 3.0 docs check found them: the delete
/// question named "Default Dark" where the app falls back to Graphite; a
/// phone's tap on a theme while Follow system theme is on must choose it
/// (and stop following); a computer had no Programming ligatures switch; and
/// a .zestheme colour such as "#fff" was misread.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  test('the delete question names the theme the app falls back to, in every language', () {
    final fallback = BuiltInThemes.getById(kDefaultAppThemeId).name;
    expect(fallback, 'Graphite');
    for (final locale in AppLocalizations.supportedLocales) {
      final body = themeDeleteQuestionBody(lookupAppLocalizations(locale));
      expect(body, contains(fallback), reason: '$locale');
      expect(body, isNot(contains('Default Dark')), reason: '$locale');
    }
  });

  test('a .zestheme colour in 3, 4, 6 or 8 hex digits, as CSS writes them', () {
    expect(parseThemeHex('#fff'), const Color(0xFFFFFFFF));
    expect(parseThemeHex('#f00'), const Color(0xFFFF0000));
    expect(parseThemeHex('#0f08'), const Color(0x8800FF00));
    expect(parseThemeHex('#1E1E2E'), const Color(0xFF1E1E2E));
    // As the app's own export writes it: six digits and no "#".
    expect(parseThemeHex('1e1e2e'), const Color(0xFF1E1E2E));
    expect(parseThemeHex('#FFFFFF40'), const Color(0x40FFFFFF));
    for (final bad in ['', '#', '#ff', '#fffff', '#12345', '#ggg', 'red', '#1234567']) {
      expect(parseThemeHex(bad), isNull, reason: bad);
    }
  });

  testWidgets("a phone: a tap on a theme while following the system's chooses it and stops following",
      (tester) async {
    tester.view.physicalSize = const Size(420, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Plan(true)),
    ]);
    addTearDown(container.dispose);
    await container.read(themeUpdaterProvider).setFollowSystemTheme(true);
    final router = GoRouter(routes: [GoRoute(path: '/', builder: (context, state) => const AppearanceScreen())]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ));
    await tester.pumpAndSettle();
    expect(container.read(followSystemThemeProvider), isTrue);
    // A theme other than the one following the system shows.
    final shown = container.read(appThemeProvider).id;
    final other = BuiltInThemes.all.firstWhere((t) => t.id != shown && t.id != kDefaultAppThemeId);
    final card = find.byKey(ValueKey('appearance-app-theme-${other.id}'));
    await tester.ensureVisible(card);
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(container.read(followSystemThemeProvider), isFalse, reason: 'following the system stops');
    expect(container.read(appThemeIdProvider), other.id);
    expect(container.read(appThemeProvider).id, other.id, reason: 'the theme picked shows');
  });

  testWidgets("a computer's Settings have the Programming ligatures switch a phone has", (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1400, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
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
    await tester.pumpAndSettle();
    // The terminal's rows are Terminal and SSH's (4.0: they were Appearance's).
    await tester.tap(find.text(en.settingsPageTerminalSsh).first);
    await tester.pumpAndSettle();
    // The test font is wider than the app's: a theme card's name ("Zest
    // Night") runs 10 pixels over its card in this harness, and only here.
    final drawn = tester.takeException();
    if (drawn != null) expect('$drawn', contains('overflowed'));
    final row = find.text(en.settingsMobProgrammingLigatures);
    expect(row, findsOneWidget);
    expect(container.read(terminalLigaturesProvider), isFalse);
    // The row's switch: the one on its line.
    final rowBox = tester.getRect(row);
    final switches = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Toggle');
    final mine = switches.evaluate().map((e) => e.widget).firstWhere((w) {
      final r = tester.getRect(find.byWidget(w));
      return (r.center.dy - rowBox.center.dy).abs() < 40;
    });
    await tester.tap(find.byWidget(mine));
    await tester.pumpAndSettle();
    expect(container.read(terminalLigaturesProvider), isTrue);
    expect(prefs.getBool('terminal_ligatures'), isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}
