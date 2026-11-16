import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/theme_providers.dart';

/// Persistence key for the "themes synced" toggle.
const _kThemesSynced = 'themes_synced';

/// When `true` (default), changing the app theme also changes the terminal
/// theme to its paired equivalent (and vice-versa). When `false`, the two
/// pickers operate independently.
///
/// Persisted under `_kThemesSynced` so the user's preference survives
/// restarts.
final themesSyncedProvider = StateProvider<bool>((ref) {
  final prefs = ref.read(sharedPreferencesProvider);
  // Default to ON so a single theme pick changes the whole app.
  return prefs.getBool(_kThemesSynced) ?? true;
});

/// Maps an app theme ID → its sibling terminal theme ID, for every built-in
/// app theme. A theme a person made has none: with one in use, the terminal
/// stays on whatever it was last set to.
///
/// Midnight and Catppuccin Mocha had no terminal theme of their own, so
/// nothing could match them: turning
/// "Match terminal to app theme" back on under Midnight changed nothing.
const Map<String, String> kAppToTerminalThemeId = {
  'default_dark': 'zest_night',
  'graphite': 'zest_night',
  'default_light': 'light',
  'amoled': 'amoled',
  'midnight': 'midnight',
  'catppuccin_mocha': 'catppuccin_mocha',
  'dracula': 'dracula',
  'nord': 'nord',
  'monokai': 'monokai',
  'solarized_dark': 'solarized_dark',
  'tokyo_night': 'tokyo_night',
  'gruvbox_dark': 'gruvbox',
  'one_dark': 'one_dark',
  'one_light': 'one_light',
  'darcula': 'darcula',
  'intellij_dark': 'intellij_dark',
  'intellij_light': 'intellij_light',
};

/// Maps a terminal theme ID → its sibling app theme ID, where both exist.
///
/// Themes that are terminal-only (`cyberpunk`, `synthwave`, `ocean`,
/// `citrus`) are deliberately absent.
const Map<String, String> kTerminalToAppThemeId = {
  'zest_night': 'graphite',
  'dark': 'default_dark',
  'light': 'default_light',
  'amoled': 'amoled',
  'midnight': 'midnight',
  'catppuccin_mocha': 'catppuccin_mocha',
  'dracula': 'dracula',
  'nord': 'nord',
  'monokai': 'monokai',
  'solarized_dark': 'solarized_dark',
  'tokyo_night': 'tokyo_night',
  'gruvbox': 'gruvbox_dark',
  'one_dark': 'one_dark',
  'one_light': 'one_light',
  'darcula': 'darcula',
  'intellij_dark': 'intellij_dark',
  'intellij_light': 'intellij_light',
};

/// True if the given app theme ID has a matching terminal theme.
bool appThemeHasTerminalSibling(String appId) =>
    kAppToTerminalThemeId.containsKey(appId);

/// True if the given terminal theme ID has a matching app theme.
bool terminalThemeHasAppSibling(String terminalId) =>
    kTerminalToAppThemeId.containsKey(terminalId);

/// Coordinator for theme picks that respects the sync toggle.
///
/// Always go through this rather than calling [ThemeUpdater] /
/// [SettingsUpdater] directly when the user picks a theme in the
/// Appearance screen - otherwise the two halves can drift apart.
class ThemeSyncCoordinator {
  final Ref _ref;
  const ThemeSyncCoordinator(this._ref);

  /// Persist the synced/unsynced toggle. Turned on, the terminal matches the
  /// app theme in use there and then, also when it was on a theme tied to no
  /// app theme (before: off, change the app
  /// theme, on again, and nothing changed).
  Future<void> setSyncEnabled(bool enabled) async {
    final prefs = _ref.read(sharedPreferencesProvider);
    await prefs.setBool(_kThemesSynced, enabled);
    _ref.read(themesSyncedProvider.notifier).state = enabled;
    if (!enabled) return;
    final appId = _ref.read(appThemeProvider).id;
    final pair = kAppToTerminalThemeId[appId];
    final kept = _ref.read(terminalThemeIdProvider);
    // Ember's own "dark" is as much Ember's as its listed pair: it stays.
    if (pair != null && pair != kept && kTerminalToAppThemeId[kept] != appId) {
      await _ref.read(settingsUpdaterProvider).setTerminalTheme(pair);
    }
  }

  /// Change the app theme. If sync is on AND the picked theme has a
  /// terminal sibling, also flip the terminal theme.
  Future<void> setAppTheme(String appId) async {
    // While following the system theme the app shows its own light or dark
    // default, whatever is picked: picking an app theme is a choice of theme,
    // so following the system stops (it looked as if nothing happened). Any
    // pick does, the one shown too.
    if (_ref.read(followSystemThemeProvider)) {
      await _ref.read(themeUpdaterProvider).setFollowSystemTheme(false);
    }
    await _ref.read(themeUpdaterProvider).setAppTheme(appId);
    if (_ref.read(themesSyncedProvider)) {
      final termId = kAppToTerminalThemeId[appId];
      if (termId != null) {
        await _ref.read(settingsUpdaterProvider).setTerminalTheme(termId);
      }
    }
  }

  /// Change the terminal theme. If sync is on AND the picked theme has an
  /// app sibling, also flip the app theme.
  Future<void> setTerminalTheme(String terminalId) async {
    await _ref.read(settingsUpdaterProvider).setTerminalTheme(terminalId);
    if (_ref.read(themesSyncedProvider)) {
      final appId = kTerminalToAppThemeId[terminalId];
      if (appId != null) {
        final themes = _ref.read(themeUpdaterProvider);
        // While following the system theme the app shows its own light or
        // dark default, whatever is picked, and the terminal follows it: a
        // terminal theme tied to another app theme would not show. Picking
        // it is a choice of theme, as a pick in the theme designer is, so
        // following the system stops.
        if (_ref.read(followSystemThemeProvider) && _ref.read(appThemeProvider).id != appId) {
          await themes.setFollowSystemTheme(false);
        }
        await themes.setAppTheme(appId);
      }
    }
  }
}

final themeSyncCoordinatorProvider = Provider<ThemeSyncCoordinator>(
  (ref) => ThemeSyncCoordinator(ref),
);
