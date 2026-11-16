import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// Proves the language setting has something to switch to: every non-English
/// locale that ships an .arb loads through the generated delegate and returns
/// translated (non-English, non-empty) text for a common label. This guards
/// against a locale file that failed to generate or was left as English.
void main() {
  test('every shipped locale loads and translates a common label', () async {
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    final others = AppLocalizations.supportedLocales
        .where((l) => l.languageCode != 'en')
        .toList();
    expect(others, isNotEmpty, reason: 'no non-English locales are shipped');

    for (final loc in others) {
      final l = await AppLocalizations.delegate.load(loc);
      // "Save" is a common action label present and translatable in every
      // supported language; brand names are not a fair test.
      expect(l.save.trim(), isNotEmpty, reason: '$loc: save is empty');
      expect(l.save != en.save, isTrue,
          reason: '$loc: "save" is still the English "${en.save}"');
    }
  });
}
