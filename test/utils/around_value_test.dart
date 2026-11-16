import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/utils/around_value.dart';

/// Sentences with a value drawn apart are whole sentences now, so a language
/// can put the value where it goes (found in a review): they were a
/// translated prefix glued to the value.
void main() {
  test('a sentence splits around its value', () {
    expect(aroundValue('You own \u0001'), ('You own ', ''));
    expect(aroundValue('\u0001 bearbeiten'), ('', ' bearbeiten'));
    expect(aroundValue('no value here'), ('no value here', ''));
  });

  test('in every language the value can stand anywhere, and the words around it are kept', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      for (final sentence in [l10n.deskUpgYouOwn(aroundValueMarker), l10n.themeDesignEditingName(aroundValueMarker)]) {
        expect(sentence, contains(aroundValueMarker), reason: '${locale.languageCode}: $sentence');
        final (before, after) = aroundValue(sentence);
        expect('$before$after'.trim(), isNotEmpty, reason: locale.languageCode);
      }
    }
    final de = lookupAppLocalizations(const Locale('de'));
    expect(aroundValue(de.themeDesignEditingName(aroundValueMarker)), ('', ' bearbeiten'));
  });
}
