import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Business has no upper number of seats in any language (the website dropped
/// "up to 1,000"; the Seats page and the seats sheet still said
/// it before 4.0).
void main() {
  const languages = ['en', 'ar', 'de', 'es', 'fr', 'hi', 'it', 'ja', 'ko', 'pt', 'ru', 'zh'];
  final cap = RegExp(r'1[,.   ]?000|\{most\}');

  for (final lang in languages) {
    test('$lang: what Business brings and the seats sheet name no upper number', () {
      final arb = jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync()) as Map<String, Object?>;
      for (final key in ['teamServicesAbout', 'seatsSheetPrice']) {
        final text = arb[key] as String?;
        expect(text, isNotNull, reason: '$lang $key');
        expect(text, isNot(contains(cap)), reason: '$lang $key: $text');
      }
      // 25, the most a team holds without Business, is still said.
      expect(arb['teamServicesAbout'] as String, contains('25'), reason: lang);
    });
  }
}
