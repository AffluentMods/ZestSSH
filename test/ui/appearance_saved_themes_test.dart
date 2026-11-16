// A phone's Appearance page lists the themes a person made or imported
// (found while comparing the five versions). Its App theme
// grid listed the built-in themes alone, so an app theme imported, or the
// one the brand colours make, could not be picked again, nor deleted; a
// terminal theme was deleted at a tap, without asking; and deleting the
// terminal theme in use, or Reset to defaults, put Default Dark in its place,
// which is not the theme a new install has.

import 'dart:convert';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/theme_providers.dart';
import 'package:zestssh/theme/terminal_themes.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/settings/appearance_screen.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

class _Plan extends StateNotifier<bool> implements ProStatusNotifier {
  _Plan(super.pro);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final de = lookupAppLocalizations(const Locale('de'));

  setUp(() => debugTopSnackBarOnPhone = true);
  tearDown(() => debugTopSnackBarOnPhone = null);

  testWidgets(
      'the themes made or imported: picked from the grid, listed with their kind, deleted after asking, '
      'and the one a new install has in place of the one in use', (tester) async {
    // Tall enough that the whole page is built.
    tester.view.physicalSize = const Size(420, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sunset = BuiltInThemes.getById('dracula').colorScheme.copyWith(id: 'custom_app_1', name: 'Sunset');
    final brand = BuiltInThemes.getById('nord').colorScheme.copyWith(id: kCustomBrandThemeId, name: 'Custom');
    SharedPreferences.setMockInitialValues({
      'custom_app_themes_v1': jsonEncode([sunset.toJson(), brand.toJson()]),
    });
    final prefs = await SharedPreferences.getInstance();
    final harbour =
        await TerminalThemes.saveCustomTheme(prefs: prefs, name: 'Harbour', theme: TerminalThemes.builtIn['dracula']!);
    addTearDown(() => TerminalThemes.deleteCustomTheme(prefs: prefs, id: harbour));
    await prefs.setString('terminal_theme', harbour);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Plan(true)),
    ]);
    addTearDown(container.dispose);
    final router = GoRouter(routes: [GoRoute(path: '/', builder: (context, state) => const AppearanceScreen())]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('de'),
      ),
    ));
    await tester.pumpAndSettle();

    Finder card(String id) => find.byKey(ValueKey('appearance-app-theme-$id'));
    Finder row(String key) => find.byKey(ValueKey(key));
    Finder asked(String text) => find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(text));
    Future<void> tapDelete(String key) async {
      await tester.tap(find.descendant(of: row(key), matching: find.byIcon(LucideIcons.trash2)));
      await tester.pumpAndSettle();
    }

    // The grid: the built-in themes, then the two made here, the brand
    // colours' one named after them in the person's language.
    expect(card('default_dark'), findsOneWidget);
    expect(find.descendant(of: card('custom_app_1'), matching: find.text('Sunset')), findsOneWidget);
    expect(find.descendant(of: card(kCustomBrandThemeId), matching: find.text(de.zestAppearanceBrandColors)),
        findsOneWidget);
    expect(find.text('Custom'), findsNothing);

    // Picked again from the grid.
    await tester.tap(card('custom_app_1'));
    await tester.pumpAndSettle();
    expect(container.read(appThemeIdProvider), 'custom_app_1');
    expect(find.descendant(of: card('custom_app_1'), matching: find.byIcon(LucideIcons.check)), findsOneWidget);

    // The saved themes: both kinds, each with its kind.
    expect(find.text(de.appearanceSavedThemes), findsOneWidget);
    expect(find.descendant(of: row('appearance-saved-app-custom_app_1'), matching: find.text(de.appearanceAppTheme)),
        findsOneWidget);
    expect(
        find.descendant(
            of: row('appearance-saved-app-$kCustomBrandThemeId'), matching: find.text(de.zestAppearanceBrandColors)),
        findsOneWidget);
    expect(
        find.descendant(
            of: row('appearance-saved-terminal-$harbour'), matching: find.text(de.appearanceTerminalTheme)),
        findsOneWidget);

    // An app theme: deleting asks first, and No keeps it.
    await tapDelete('appearance-saved-app-custom_app_1');
    expect(asked(de.themeDesignDeleteThemeTitle('Sunset')), findsOneWidget);
    await tester.tap(asked(de.cancel));
    await tester.pumpAndSettle();
    expect(container.read(customAppThemesProvider).containsKey('custom_app_1'), isTrue);
    // Yes deletes it, and the one in use gives way to the default theme.
    await tapDelete('appearance-saved-app-custom_app_1');
    await tester.tap(asked(de.themeDesignDeleteTheme));
    await tester.pumpAndSettle();
    expect(container.read(customAppThemesProvider).containsKey('custom_app_1'), isFalse);
    expect(container.read(appThemeIdProvider), kDefaultAppThemeId);
    expect(card('custom_app_1'), findsNothing);
    expect(row('appearance-saved-app-custom_app_1'), findsNothing);

    // A terminal theme asks first too.
    await tapDelete('appearance-saved-terminal-$harbour');
    expect(asked(de.themePickerDeleteConfirm('Harbour')), findsOneWidget);
    await tester.tap(asked(de.cancel));
    await tester.pumpAndSettle();
    expect(TerminalThemes.customThemeIds, contains(harbour));
    expect(container.read(terminalThemeIdProvider), harbour);
    // Deleted, the one in use: the one a new install has.
    await tapDelete('appearance-saved-terminal-$harbour');
    await tester.tap(asked(de.delete));
    await tester.pumpAndSettle();
    expect(TerminalThemes.customThemeIds, isNot(contains(harbour)));
    expect(container.read(terminalThemeIdProvider), TerminalThemes.defaultId);
    expect(row('appearance-saved-terminal-$harbour'), findsNothing);

    // Reset to defaults asks, and gives the themes a new install has.
    await container.read(settingsUpdaterProvider).setTerminalTheme('dracula');
    await container.read(themeUpdaterProvider).setAppTheme('nord');
    await tester.pumpAndSettle();
    final reset = find.text(de.appearanceResetToDefaults);
    await tester.tap(reset);
    await tester.pumpAndSettle();
    expect(asked(de.appearanceResetAppearanceTitle), findsOneWidget);
    await tester.tap(asked(de.cancel));
    await tester.pumpAndSettle();
    expect(container.read(terminalThemeIdProvider), 'dracula');
    expect(container.read(appThemeIdProvider), 'nord');
    await tester.tap(reset);
    await tester.pumpAndSettle();
    await tester.tap(asked(de.appearanceReset));
    await tester.pumpAndSettle();
    expect(container.read(terminalThemeIdProvider), TerminalThemes.defaultId);
    expect(container.read(appThemeIdProvider), kDefaultAppThemeId);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}
