import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/providers/core_providers.dart';

/// The user's chosen app language, or null to follow the system locale.
///
/// Persisted per device (a device preference, not synced). When null,
/// `MaterialApp` resolves the device locale against `supportedLocales` as
/// before. Setting it to a supported [Locale] overrides that everywhere.
class AppLocaleNotifier extends StateNotifier<Locale?> {
  AppLocaleNotifier(this._prefs) : super(_decode(_prefs.getString(_key)));

  static const _key = 'app_locale';
  final SharedPreferences _prefs;

  static Locale? _decode(String? tag) {
    if (tag == null || tag.isEmpty) return null;
    final parts = tag.split('-');
    return parts.length > 1 ? Locale(parts[0], parts[1]) : Locale(parts[0]);
  }

  static String _encode(Locale locale) => locale.countryCode == null
      ? locale.languageCode
      : '${locale.languageCode}-${locale.countryCode}';

  Future<void> set(Locale? locale) async {
    state = locale;
    if (locale == null) {
      await _prefs.remove(_key);
    } else {
      await _prefs.setString(_key, _encode(locale));
    }
  }
}

/// The active app-language override (null = follow system). Watched by
/// `MaterialApp.locale`.
final appLocaleProvider =
    StateNotifierProvider<AppLocaleNotifier, Locale?>((ref) {
  return AppLocaleNotifier(ref.watch(sharedPreferencesProvider));
});

/// Resolves the device's [preferred] locales against the shipped [supported]
/// set for the "System default" language option.
///
/// Returns the first supported locale that matches a device locale (exact
/// language+country first, then language-only, e.g. a `pt_BR` device maps to
/// `pt`), following the device's own preference order. When nothing matches it
/// returns English, so an unsupported device language reverts to English
/// instead of Flutter's default of falling back to the first (alphabetically
/// earliest) shipped locale.
///
/// Used as `MaterialApp.localeListResolutionCallback`, so it also runs when the
/// user picks an explicit language (Flutter passes `[thatLocale]` here), and it
/// returns that locale unchanged since the picker only offers supported ones.
Locale resolveAppLocale(List<Locale>? preferred, Iterable<Locale> supported) {
  const fallback = Locale('en');
  final list = supported.toList();
  if (preferred == null || preferred.isEmpty || list.isEmpty) {
    return list.contains(fallback) || list.isEmpty ? fallback : list.first;
  }
  for (final want in preferred) {
    for (final s in list) {
      if (s.languageCode == want.languageCode &&
          s.countryCode == want.countryCode) {
        return s;
      }
    }
  }
  for (final want in preferred) {
    for (final s in list) {
      if (s.languageCode == want.languageCode) return s;
    }
  }
  return fallback;
}

/// Native display name for a locale, shown in the language picker. Falls back to
/// the language code for anything not listed.
String localeDisplayName(Locale locale) {
  final code = locale.countryCode == null
      ? locale.languageCode
      : '${locale.languageCode}_${locale.countryCode}';
  return _localeNames[code] ??
      _localeNames[locale.languageCode] ??
      locale.toLanguageTag();
}

const Map<String, String> _localeNames = {
  'en': 'English',
  'es': 'Español',
  'fr': 'Français',
  'de': 'Deutsch',
  'pt': 'Português',
  'pt_BR': 'Português (Brasil)',
  'it': 'Italiano',
  'nl': 'Nederlands',
  'ru': 'Русский',
  'uk': 'Українська',
  'pl': 'Polski',
  'tr': 'Türkçe',
  'ja': '日本語',
  'ko': '한국어',
  'zh': '中文 (简体)',
  'zh_Hans': '中文 (简体)',
  'zh_Hant': '中文 (繁體)',
  'ar': 'العربية',
  'hi': 'हिन्दी',
  'id': 'Bahasa Indonesia',
  'vi': 'Tiếng Việt',
  'th': 'ไทย',
  'cs': 'Čeština',
  'sv': 'Svenska',
  'fa': 'فارسی',
};
