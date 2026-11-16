import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every language carries every English string (a missing one falls back to
/// English without a word, which is how 38 Orchard strings went untranslated
/// for a while), and no string carries an en or em dash (house style).
void main() {
  final dir = Directory('lib/l10n');
  Map<String, dynamic> read(File f) => jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  final files = {
    for (final f in dir.listSync().whereType<File>())
      if (RegExp(r'app_(\w+)\.arb$').firstMatch(f.path) case final m?) m.group(1)!: f,
  };
  final en = read(files['en']!);
  final keys = [
    for (final k in en.keys)
      if (!k.startsWith('@')) k,
  ];

  test('all twelve languages are here', () {
    expect(files.keys.toSet(), {'en', 'ar', 'de', 'es', 'fr', 'hi', 'it', 'ja', 'ko', 'pt', 'ru', 'zh'});
  });

  test('every language carries every English string', () {
    for (final MapEntry(key: lang, value: file) in files.entries) {
      final strings = read(file);
      final missing = [
        for (final k in keys)
          if (!strings.containsKey(k)) k,
      ];
      expect(missing, isEmpty, reason: '$lang lacks ${missing.length} string(s)');
    }
  });

  test('no string carries an en or em dash', () {
    for (final MapEntry(key: lang, value: file) in files.entries) {
      final dashed = [
        for (final e in read(file).entries)
          if (e.value is String && RegExp('[\u2013\u2014]').hasMatch(e.value as String)) e.key,
      ];
      expect(dashed, isEmpty, reason: lang);
    }
  });
}
