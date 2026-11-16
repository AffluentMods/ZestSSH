import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/theme/zest_color_scheme.dart';
import 'package:zestssh/theme/zest_theme.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedProvider;

// ── Persistence keys ────────────────────────────────────────────

const _kAppThemeId = 'app_theme_id';
const _kCustomAccentColor = 'custom_accent_color';
const _kFollowSystemTheme = 'follow_system_theme';
const _kCustomAppThemes = 'custom_app_themes_v1';

/// Fixed id for the theme produced by the Appearance screen's
/// primary/secondary/accent pickers. A single reusable slot so repeated edits
/// update in place rather than piling up custom themes.
const String kCustomBrandThemeId = 'custom_brand';

// ── Free vs Pro split for app themes ────────────────────────────
//
// Every built-in app theme is free, as every built-in terminal theme is
// (before, four were). A theme a person designs is the Pro
// feature, gated separately at the "Create" button.

final Set<String> kFreeAppThemeIds = Set.unmodifiable({for (final theme in BuiltInThemes.all) theme.id});

// ── App theme ID ────────────────────────────────────────────────

/// The app's default theme: Graphite, the Blueprint's cooler set (3.0, the
/// user's choice). Ember ('default_dark') stays, for whoever picks it.
const String kDefaultAppThemeId = 'graphite';

/// The currently selected app-theme ID (persisted to SharedPreferences).
///
/// Defaults to [kDefaultAppThemeId]. Changing this provider triggers a full
/// theme rebuild through [appThemeProvider] and [appThemeDataProvider].
final appThemeIdProvider = StateProvider<String>((ref) {
  final prefs = ref.read(sharedPreferencesProvider);
  return prefs.getString(_kAppThemeId) ?? kDefaultAppThemeId;
});

// ── Follow system theme ─────────────────────────────────────────

/// When `true`, the app follows the system light/dark preference
/// instead of using the manually selected theme. Persisted.
final followSystemThemeProvider = StateProvider<bool>((ref) {
  final prefs = ref.read(sharedPreferencesProvider);
  return prefs.getBool(_kFollowSystemTheme) ?? false;
});

// ── Custom accent colour ────────────────────────────────────────

/// Optional user-chosen accent colour that overrides the theme's
/// built-in primary. `null` means "use the theme default".
final customAccentColorProvider = StateProvider<Color?>((ref) {
  final prefs = ref.read(sharedPreferencesProvider);
  final stored = prefs.getInt(_kCustomAccentColor);
  return stored != null ? Color(stored) : null;
});

// ── Custom app themes ───────────────────────────────────────────

/// User-created app themes. Keyed by theme ID (`custom_app_<n>`).
///
/// Built-in themes live in `lib/theme/themes/` as Dart consts; custom
/// themes are JSON-persisted under [_kCustomAppThemes]. Both are
/// resolvable through [appThemeProvider] - a custom-theme ID falls
/// through the built-in lookup and lands here.
final customAppThemesProvider =
    StateNotifierProvider<CustomAppThemesNotifier, Map<String, ZestTheme>>(
  (ref) => CustomAppThemesNotifier(ref.read(sharedPreferencesProvider)),
);

class CustomAppThemesNotifier extends StateNotifier<Map<String, ZestTheme>> {
  CustomAppThemesNotifier(this._prefs) : super({}) {
    _load();
  }

  final SharedPreferences _prefs;

  void _load() {
    final raw = _prefs.getString(_kCustomAppThemes);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final loaded = <String, ZestTheme>{};
      for (final entry in list) {
        if (entry is! Map<String, dynamic>) continue;
        final scheme = ZestColorScheme.fromJson(entry);
        if (scheme == null) continue;
        loaded[scheme.id] = ZestTheme(
          id: scheme.id,
          name: scheme.name,
          brightness: scheme.isDark ? Brightness.dark : Brightness.light,
          colorScheme: scheme,
        );
      }
      state = loaded;
    } catch (_) {
      // Corrupt prefs - drop silently so a bad save doesn't brick the app
    }
  }

  Future<void> _persist() async {
    final list = state.values.map((t) => t.colorScheme.toJson()).toList();
    await _prefs.setString(_kCustomAppThemes, jsonEncode(list));
  }

  /// Generate the next free ID (`custom_app_1`, `custom_app_2`, …).
  String nextId() {
    var n = 1;
    while (state.containsKey('custom_app_$n')) {
      n++;
    }
    return 'custom_app_$n';
  }

  /// Save (insert or replace) a custom theme.
  Future<void> save(ZestTheme theme) async {
    state = {...state, theme.id: theme};
    await _persist();
  }

  /// Delete a custom theme.
  Future<void> delete(String id) async {
    final next = Map<String, ZestTheme>.from(state)..remove(id);
    state = next;
    await _persist();
  }

  /// Returns the theme with [id], or `null` if not found.
  ZestTheme? get(String id) => state[id];
}

// ── Resolved theme ──────────────────────────────────────────────

/// The system's light or dark, kept up to date by the app's root
/// (didChangePlatformBrightness), so Follow system theme turns with the
/// system while the app is open, not only at its next start.
final platformBrightnessProvider = StateProvider<Brightness>(
    (ref) => SchedulerBinding.instance.platformDispatcher.platformBrightness);

/// The resolved [ZestTheme] based on the current ID and system
/// follow preference.
///
/// When [followSystemThemeProvider] is true, this returns the default
/// dark or light theme matching the platform brightness. Otherwise
/// it returns whichever theme [appThemeIdProvider] points to -
/// checking custom themes before falling back to the built-in registry.
final appThemeProvider = Provider<ZestTheme>((ref) {
  final followSystem = ref.watch(followSystemThemeProvider);

  if (followSystem) {
    final brightness = ref.watch(platformBrightnessProvider);
    return brightness == Brightness.dark
        ? BuiltInThemes.getById(kDefaultAppThemeId)
        : BuiltInThemes.getById('default_light');
  }

  final id = ref.watch(appThemeIdProvider);

  // Custom themes take precedence if the ID points there.
  final customs = ref.watch(customAppThemesProvider);
  if (customs.containsKey(id)) return customs[id]!;

  return BuiltInThemes.getById(id);
});

/// The Flutter [ThemeData] generated from [appThemeProvider],
/// with any custom accent applied. Wire this into your [MaterialApp].
final appThemeDataProvider = Provider<ThemeData>((ref) {
  final theme = ref.watch(appThemeProvider);
  final accent = ref.watch(customAccentColorProvider);
  // The controls' size (4.0): Settings' density, Auto following the input.
  return theme.toThemeData(accentOverride: accent, compact: !ref.watch(touchSizedProvider));
});

// ── Persistence helpers ─────────────────────────────────────────

/// Helper class to persist theme changes to SharedPreferences and
/// update the corresponding Riverpod providers atomically.
class ThemeUpdater {
  final Ref _ref;
  const ThemeUpdater(this._ref);

  SharedPreferences get _prefs => _ref.read(sharedPreferencesProvider);

  /// Changes the active app theme by ID. Hot-swaps without restart.
  Future<void> setAppTheme(String id) async {
    await _prefs.setString(_kAppThemeId, id);
    _ref.read(appThemeIdProvider.notifier).state = id;
  }

  /// Toggles follow-system-theme on or off.
  Future<void> setFollowSystemTheme(bool enabled) async {
    await _prefs.setBool(_kFollowSystemTheme, enabled);
    _ref.read(followSystemThemeProvider.notifier).state = enabled;
  }

  /// Sets a custom accent colour override, or clears it.
  Future<void> setCustomAccentColor(Color? color) async {
    if (color != null) {
      await _prefs.setInt(_kCustomAccentColor, color.toARGB32());
    } else {
      await _prefs.remove(_kCustomAccentColor);
    }
    _ref.read(customAccentColorProvider.notifier).state = color;
  }

  /// Apply a user-chosen brand triad - any subset of primary / secondary /
  /// accent - hot-swapped with no restart.
  ///
  /// Clones the ACTIVE theme's scheme (so surfaces, text and semantic colours
  /// stay put), overrides just the brand roles, saves it under
  /// [kCustomBrandThemeId] and selects it. `primary` drives the legacy orange
  /// family + Material + v3 chrome + terminal; `secondary` drives Material
  /// secondary/tertiary; `accent` drives the 1.7 component brand
  /// (`ZestColors`/`ZestTokens`).
  Future<void> setBrandColors({
    Color? primary,
    Color? secondary,
    Color? accent,
  }) async {
    final base = _ref.read(appThemeProvider).colorScheme;
    final newPrimary = primary ?? base.primary;
    final scheme = base.copyWith(
      id: kCustomBrandThemeId,
      name: 'Custom',
      primary: newPrimary,
      primaryHover:
          primary != null ? _lighten(newPrimary, 0.10) : base.primaryHover,
      secondary: secondary ?? base.secondary,
      secondaryHover:
          secondary != null ? _lighten(secondary, 0.10) : base.secondaryHover,
      accent: accent ?? base.accent,
      selected: newPrimary.withValues(alpha: 0.15),
      focus: newPrimary,
    );
    final theme = ZestTheme(
      id: kCustomBrandThemeId,
      name: 'Custom',
      brightness: scheme.isDark ? Brightness.dark : Brightness.light,
      colorScheme: scheme,
    );
    await _ref.read(customAppThemesProvider.notifier).save(theme);
    // The scheme's primary is authoritative - clear the legacy Material-only
    // accent override so it can't fight the scheme.
    await setCustomAccentColor(null);
    // Picking brand colours is an explicit theme choice: turn OFF follow-system,
    // otherwise appThemeProvider short-circuits to default_dark/light and the
    // pickers appear dead (the selected id is ignored while follow-system is on).
    await setFollowSystemTheme(false);
    await setAppTheme(kCustomBrandThemeId);
  }

  /// Remove the Appearance-screen brand override theme, if any.
  Future<void> clearBrandColors() async {
    await _ref.read(customAppThemesProvider.notifier).delete(kCustomBrandThemeId);
  }

  static Color _lighten(Color c, double amount) {
    final hsl = HSLColor.fromColor(c);
    return hsl
        .withLightness((hsl.lightness + amount).clamp(0.0, 1.0))
        .toColor();
  }
}

/// Provider for the [ThemeUpdater] helper.
final themeUpdaterProvider = Provider<ThemeUpdater>((ref) {
  return ThemeUpdater(ref);
});
