import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/locale_providers.dart';

/// The "System default" language option: resolve the device locale against the
/// shipped set, reverting to English when unsupported (never an arbitrary
/// first-supported locale).
void main() {
  final supported = AppLocalizations.supportedLocales;

  test('shipped device language is used', () {
    expect(resolveAppLocale([const Locale('fr')], supported),
        const Locale('fr'));
    expect(resolveAppLocale([const Locale('ja')], supported),
        const Locale('ja'));
  });

  test('country variant maps to the base language', () {
    // pt_BR device -> shipped pt
    expect(resolveAppLocale([const Locale('pt', 'BR')], supported).languageCode,
        'pt');
    // en_US device -> en
    expect(resolveAppLocale([const Locale('en', 'US')], supported).languageCode,
        'en');
  });

  test('unsupported device language reverts to English', () {
    expect(resolveAppLocale([const Locale('th')], supported),
        const Locale('en'));
    expect(resolveAppLocale([const Locale('sv')], supported),
        const Locale('en'));
    // NOT the alphabetically-first shipped locale (ar).
    expect(resolveAppLocale([const Locale('xx')], supported).languageCode,
        isNot('ar'));
  });

  test('device preference order is honored', () {
    // First preferred is unsupported (th), second is supported (de).
    expect(
        resolveAppLocale(
            [const Locale('th'), const Locale('de')], supported),
        const Locale('de'));
  });

  test('null or empty preferences fall back to English', () {
    expect(resolveAppLocale(null, supported), const Locale('en'));
    expect(resolveAppLocale(const [], supported), const Locale('en'));
  });
}
