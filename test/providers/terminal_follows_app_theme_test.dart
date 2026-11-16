import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/theme_providers.dart';
import 'package:zestssh/providers/theme_sync_provider.dart';
import 'package:zestssh/theme/terminal_themes.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/theme/zest_theme.dart';

/// With "Match terminal to app theme" on, the terminal shown is the pair of
/// the app theme in use, also when that theme comes from the system (Follow
/// system theme): Daylight came with a black terminal (the dark one kept).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> container({
    required String terminal,
    String app = 'graphite',
    bool synced = true,
    bool followSystem = false,
  }) async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      terminalThemeIdProvider.overrideWith((ref) => terminal),
      appThemeIdProvider.overrideWith((ref) => app),
      themesSyncedProvider.overrideWith((ref) => synced),
      followSystemThemeProvider.overrideWith((ref) => followSystem),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('a matched terminal follows the app theme in use: Daylight brings the light terminal', () async {
    final c = await container(terminal: 'zest_night', app: 'default_light');
    expect(c.read(shownTerminalThemeIdProvider), TerminalThemes.light);
    expect(c.read(terminalThemeProvider).background, TerminalThemes.all[TerminalThemes.light]!.background);
  });

  test('Follow system theme on a light system: the light terminal, on a dark one the dark', () async {
    final binding = TestWidgetsFlutterBinding.instance;
    addTearDown(binding.platformDispatcher.clearPlatformBrightnessTestValue);
    binding.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    var c = await container(terminal: 'zest_night', followSystem: true);
    expect(c.read(shownTerminalThemeIdProvider), TerminalThemes.light);
    // The system turns dark while the app is open (the app's root says so).
    c.read(platformBrightnessProvider.notifier).state = Brightness.dark;
    expect(c.read(shownTerminalThemeIdProvider), kAppToTerminalThemeId[kDefaultAppThemeId]);
    expect(c.read(appThemeProvider).id, kDefaultAppThemeId);
    binding.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    c = await container(terminal: 'light', followSystem: true);
    expect(c.read(shownTerminalThemeIdProvider), kAppToTerminalThemeId[kDefaultAppThemeId]);
  });

  test('a terminal theme of its own, or matching off, is kept as it was chosen', () async {
    expect((await container(terminal: 'cyberpunk', app: 'default_light')).read(shownTerminalThemeIdProvider), 'cyberpunk');
    expect((await container(terminal: 'zest_night', app: 'default_light', synced: false)).read(shownTerminalThemeIdProvider),
        'zest_night');
  });

  // A design review: with Match off, the app theme
  // changed, Match on again matched some themes but not Midnight. Midnight
  // and Catppuccin Mocha had no terminal theme to be matched to.
  group('Match terminal to app theme turned back on matches the app theme in use', () {
    for (final app in BuiltInThemes.ids) {
      test(app, () async {
        final c = await container(terminal: TerminalThemes.zestNight);
        final sync = c.read(themeSyncCoordinatorProvider);
        await sync.setSyncEnabled(false);
        await sync.setAppTheme(app);
        await sync.setSyncEnabled(true);
        final shown = c.read(shownTerminalThemeIdProvider);
        expect(shown, kAppToTerminalThemeId[app], reason: 'the pair of $app');
        expect(c.read(terminalThemeProvider).background, TerminalThemes.all[shown]!.background);
      });
    }

    test('Midnight, by name, in its own colours', () async {
      final c = await container(terminal: TerminalThemes.dracula, app: 'midnight', synced: false);
      expect(c.read(shownTerminalThemeIdProvider), TerminalThemes.dracula, reason: 'off: as it was chosen');
      await c.read(themeSyncCoordinatorProvider).setSyncEnabled(true);
      expect(c.read(terminalThemeIdProvider), TerminalThemes.midnight);
      expect(c.read(terminalThemeProvider).background, BuiltInThemes.getById('midnight').colorScheme.background);
    });

    test('a terminal theme of its own is matched too, when the switch is turned on', () async {
      final c = await container(terminal: TerminalThemes.cyberpunk, app: 'nord', synced: false);
      await c.read(themeSyncCoordinatorProvider).setSyncEnabled(true);
      expect(c.read(shownTerminalThemeIdProvider), TerminalThemes.nord);
    });

    test("Ember's own dark stays: it is as much Ember's as its listed pair", () async {
      final c = await container(terminal: TerminalThemes.defaultDark, app: 'default_dark', synced: false);
      await c.read(themeSyncCoordinatorProvider).setSyncEnabled(true);
      expect(c.read(terminalThemeIdProvider), TerminalThemes.defaultDark);
    });

    test('with a theme a person made there is nothing to match: the terminal stays', () async {
      SharedPreferences.setMockInitialValues({'themes_synced': false});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        terminalThemeIdProvider.overrideWith((ref) => TerminalThemes.cyberpunk),
      ]);
      addTearDown(c.dispose);
      final mine = BuiltInThemes.getById('nord');
      await c.read(customAppThemesProvider.notifier).save(ZestTheme(
            id: 'custom_app_1',
            name: 'Mine',
            brightness: mine.brightness,
            colorScheme: mine.colorScheme.copyWith(id: 'custom_app_1', name: 'Mine'),
          ));
      await c.read(themeSyncCoordinatorProvider).setAppTheme('custom_app_1');
      await c.read(themeSyncCoordinatorProvider).setSyncEnabled(true);
      expect(c.read(shownTerminalThemeIdProvider), TerminalThemes.cyberpunk);
    });

    test('turning it off changes nothing', () async {
      final c = await container(terminal: TerminalThemes.nord, app: 'nord');
      await c.read(themeSyncCoordinatorProvider).setSyncEnabled(false);
      expect(c.read(terminalThemeIdProvider), TerminalThemes.nord);
    });
  });

  test('Midnight and Catppuccin Mocha have a terminal theme of their own, and it brings them back', () async {
    for (final id in [TerminalThemes.midnight, TerminalThemes.catppuccinMocha]) {
      expect(kAppToTerminalThemeId[id], id);
      expect(kTerminalToAppThemeId[id], id);
      expect(TerminalThemes.builtInNames[id], BuiltInThemes.names[id], reason: 'one name for both');
      final c = await container(terminal: TerminalThemes.zestNight);
      await c.read(themeSyncCoordinatorProvider).setTerminalTheme(id);
      expect(c.read(appThemeProvider).id, id);
    }
  });

  test("a terminal theme tied to the app theme in use is shown as picked: Ember's own dark", () async {
    // "dark" is Ember's pair, Ember's listed pair is Zest Night: both are
    // Ember's, neither stands in for the other.
    expect((await container(terminal: TerminalThemes.defaultDark, app: 'default_dark')).read(shownTerminalThemeIdProvider),
        TerminalThemes.defaultDark);
    expect((await container(terminal: TerminalThemes.zestNight, app: 'default_dark')).read(shownTerminalThemeIdProvider),
        TerminalThemes.zestNight);
    expect((await container(terminal: TerminalThemes.zestNight)).read(shownTerminalThemeIdProvider), TerminalThemes.zestNight);
    // The pair of another app theme still follows the one in use.
    expect((await container(terminal: TerminalThemes.defaultDark)).read(shownTerminalThemeIdProvider), TerminalThemes.zestNight);
    expect((await container(terminal: TerminalThemes.light)).read(shownTerminalThemeIdProvider), TerminalThemes.zestNight);
  });

  test('Zest Night is the pair of Graphite, the app theme on by default, both ways', () {
    expect(kAppToTerminalThemeId[kDefaultAppThemeId], TerminalThemes.zestNight);
    expect(kTerminalToAppThemeId[TerminalThemes.zestNight], kDefaultAppThemeId);
  });

  group('a terminal theme picked with matching on is the one shown', () {
    // Every terminal picker goes through the coordinator; the swatch lit and
    // the terminal drawn are the same theme.
    for (final picked in [
      TerminalThemes.dracula,
      TerminalThemes.nord,
      TerminalThemes.tokyoNight,
      TerminalThemes.light,
      TerminalThemes.defaultDark,
      TerminalThemes.cyberpunk,
    ]) {
      test(picked, () async {
        final c = await container(terminal: TerminalThemes.zestNight);
        await c.read(themeSyncCoordinatorProvider).setTerminalTheme(picked);
        expect(c.read(shownTerminalThemeIdProvider), picked);
        expect(c.read(terminalThemeProvider).background, TerminalThemes.all[picked]!.background);
        final app = kTerminalToAppThemeId[picked];
        expect(c.read(appThemeProvider).id, app ?? kDefaultAppThemeId,
            reason: 'its app theme comes with it; a terminal theme of its own leaves the app theme');
      });
    }

    test('following the system theme, a terminal theme of another app theme is shown, and following stops', () async {
      final c = await container(terminal: TerminalThemes.zestNight, followSystem: true);
      await c.read(themeSyncCoordinatorProvider).setTerminalTheme(TerminalThemes.dracula);
      expect(c.read(shownTerminalThemeIdProvider), TerminalThemes.dracula);
      expect(c.read(appThemeProvider).id, 'dracula');
      expect(c.read(followSystemThemeProvider), isFalse);
      // The pair of the theme the system gives keeps following it.
      final d = await container(terminal: TerminalThemes.dracula, followSystem: true);
      await d.read(themeSyncCoordinatorProvider).setTerminalTheme(d.read(shownTerminalThemeIdProvider));
      expect(d.read(followSystemThemeProvider), isTrue);
      // A terminal theme of its own leaves it as well.
      await d.read(themeSyncCoordinatorProvider).setTerminalTheme(TerminalThemes.cyberpunk);
      expect(d.read(followSystemThemeProvider), isTrue);
      expect(d.read(shownTerminalThemeIdProvider), TerminalThemes.cyberpunk);
    });

    test('Zest Night picked under Ember brings Graphite back', () async {
      final c = await container(terminal: TerminalThemes.defaultDark, app: 'default_dark');
      await c.read(themeSyncCoordinatorProvider).setTerminalTheme(TerminalThemes.zestNight);
      expect(c.read(appThemeProvider).id, kDefaultAppThemeId);
      expect(c.read(shownTerminalThemeIdProvider), TerminalThemes.zestNight);
    });
  });

  // With Follow system theme on, the app theme could not be changed at
  // all. Picking one is a choice of theme: following the
  // system stops, and the theme picked is the one shown.
  test('picking an app theme while following the system shows it, and stops following', () async {
    final c = await container(terminal: 'zest_night', followSystem: true);
    c.read(platformBrightnessProvider.notifier).state = Brightness.dark;
    await c.read(themeSyncCoordinatorProvider).setAppTheme('default_light');
    expect(c.read(followSystemThemeProvider), isFalse);
    expect(c.read(appThemeProvider).id, 'default_light');
  });

  // Any pick, the theme already shown
  // too (it left the app following the system, with nothing to say so).
  test('picking the very theme the system gives stops following as well', () async {
    final c = await container(terminal: 'zest_night', followSystem: true);
    c.read(platformBrightnessProvider.notifier).state = Brightness.dark;
    expect(c.read(appThemeProvider).id, kDefaultAppThemeId);
    await c.read(themeSyncCoordinatorProvider).setAppTheme(kDefaultAppThemeId);
    expect(c.read(followSystemThemeProvider), isFalse);
    expect(c.read(appThemeProvider).id, kDefaultAppThemeId);
  });
}
