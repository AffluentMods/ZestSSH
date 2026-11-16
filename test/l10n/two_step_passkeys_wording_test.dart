import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The second step of a sign-in where the account's passkeys cannot be used
/// on this device says what else there is (found in a review). The
/// two texts, for an account with an authenticator app and for one without,
/// were word for word the same in every language, so the one for an account
/// with an authenticator never named it.
void main() {
  const langs = ['en', 'de', 'es', 'fr', 'it', 'ja', 'ko', 'pt', 'ru', 'zh', 'ar', 'hi'];
  for (final lang in langs) {
    test('$lang: the text for an account with an authenticator app is not the one for an account without', () {
      final arb = jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync()) as Map<String, dynamic>;
      expect(arb['twoStepPasskeysNotHere'], isNot(arb['twoStepPasskeysNotHereNoCode']));
    });
  }

  test('English names the authenticator app where there is one', () {
    final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync()) as Map<String, dynamic>;
    expect(en['twoStepPasskeysNotHere'], contains('authenticator app'));
    expect(en['twoStepPasskeysNotHereNoCode'], isNot(contains('authenticator')));
  });
}
