import 'package:flutter/widgets.dart';

import 'generated/app_localizations.dart';

/// Global access to the current [AppLocalizations] for code that has no
/// [BuildContext]: services, the system tray, background paths, and pure
/// utilities. It is refreshed from the root [MaterialApp] builder on every
/// rebuild, so it tracks locale changes made through the language setting.
///
/// Before the first frame it falls back to English, so a very early call
/// (startup error path) still returns real strings rather than null.
///
/// UI code with a context must keep using `AppLocalizations.of(context)!`;
/// this is only for the contextless paths.
class L10nGlobal {
  L10nGlobal._();

  static AppLocalizations _current =
      lookupAppLocalizations(const Locale('en'));

  /// The current localizations. Never null.
  static AppLocalizations get current => _current;

  /// Invoked when the active locale actually changes (by locale name), not on
  /// every rebuild. Contextless surfaces that cache localized strings, chiefly
  /// the system tray, register here to rebuild themselves on a live language
  /// change instead of only on restart.
  static void Function()? onLocaleChanged;

  /// Called from the root builder whenever the active locale resolves. Fires
  /// [onLocaleChanged] only when the locale name differs from the current one.
  static void update(AppLocalizations value) {
    final changed = value.localeName != _current.localeName;
    _current = value;
    if (changed) onLocaleChanged?.call();
  }
}

/// Shorthand for [L10nGlobal.current].
AppLocalizations get gl10n => L10nGlobal.current;
