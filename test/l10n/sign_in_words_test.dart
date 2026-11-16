import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Sign in sheet says what an account is for in every language: a team,
/// or ZestSSH Cloud by its name; never that signing in turns sync on (before 4.0
/// it said: "Sign in to enable Cloud Sync and sync your
/// data across devices", while sync through one's own storage needs no
/// account).
void main() {
  const languages = ['en', 'ar', 'de', 'es', 'fr', 'hi', 'it', 'ja', 'ko', 'pt', 'ru', 'zh'];
  // The old words for "Cloud Sync" in each language.
  const oldWords = [
    'Cloud Sync', 'المزامنة السحابية', 'synchronisation cloud', 'sincronización en la nube', 'sincronização na nuvem',
    'облачную синхронизацию', 'クラウド', '클라우드 동기화', '云同步', 'क्लाउड सिंक',
  ];

  for (final lang in languages) {
    test('$lang: a team and ZestSSH Cloud, no "enable Cloud Sync"', () {
      final arb = jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync()) as Map<String, Object?>;
      final text = arb['profileSignInDesc'] as String;
      expect(text, contains('ZestSSH Cloud'));
      for (final old in oldWords) {
        expect(text, isNot(contains(old)), reason: '$lang: $text');
      }
      expect(text, isNot(contains('\n')), reason: 'one paragraph that wraps where it must');
    });
  }
}
