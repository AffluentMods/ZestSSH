import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The names of the spaces: a team
/// (it was an Orchard), its vaults (Crates), and the personal space (the
/// Tree). Companies found Orchard, Crate and Tree hard to place, so no string
/// of the app, in any of its twelve languages, names a space the old way:
/// not in Latin letters, and not in the words a language had for them.
void main() {
  // The old names in Latin letters. The command line's flag --orchard is
  // written as it is typed, and placeholders ({orchard}, {crate}) are code.
  final latin = RegExp(r'\b(Orchards?|ORCHARDS?|Crates?|CRATES?|Trees?)\b');
  final english = RegExp(r'\b(orchards?|crates?|trees?)\b', caseSensitive: false);
  // The words each language had for them, where it translated them. (A
  // regular expression's \b knows only Latin letters without accents, so it
  // is used only around those; Hindi's entry and telemetry, एंट्री and
  // टेलीमेट्री, and Korean's trigger and registry, 트리거 and 레지스트리, hold
  // the letters of a tree inside a word.)
  final own = <String, RegExp>{
    'de': RegExp(r'\b(Baum|Baums|Obstgarten)\b|Bäume'),
    'fr': RegExp(r'\b(arbres?|vergers?)\b', caseSensitive: false),
    'es': RegExp('(árbol|huerto)', caseSensitive: false),
    'it': RegExp(r'\b(alberi|albero|frutteti?)\b', caseSensitive: false),
    'pt': RegExp('(árvore|pomar)', caseSensitive: false),
    'ru': RegExp('дерев', caseSensitive: false),
    'ja': RegExp('(ツリー|オーチャード|果樹園|クレート)'),
    'ko': RegExp('((?<![가-힣])트리(?!거)|과수원|크레이트)'),
    'zh': RegExp('(树|果园|板条箱)'),
    'hi': RegExp('((?<![ऀ-ॿ])ट्री|बगीचा)'),
    'ar': RegExp('(شجر|بستان)'),
  };

  String words(String value) => value.replaceAll('--orchard', '').replaceAll(RegExp(r'\{[A-Za-z_]+\}'), '');

  final dir = Directory('lib/l10n');
  final files = dir.listSync().whereType<File>().where((f) => RegExp(r'app_([a-z]{2})\.arb$').hasMatch(f.path)).toList();

  test('there are twelve languages', () => expect(files, hasLength(12)));

  for (final file in files) {
    final lang = RegExp(r'app_([a-z]{2})\.arb$').firstMatch(file.path)!.group(1)!;
    test('$lang names no space the old way', () {
      final arb = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final found = <String>[];
      for (final MapEntry(:key, :value) in arb.entries) {
        if (key.startsWith('@') || value is! String) continue;
        final w = words(value);
        final hit = (lang == 'en' ? english : latin).hasMatch(w) || (own[lang]?.hasMatch(w) ?? false);
        if (hit) found.add('$key: $value');
      }
      expect(found, isEmpty);
    });
  }

  test('the check finds what it is for', () {
    expect(english.hasMatch(words('Invite someone to an Orchard')), isTrue);
    expect(english.hasMatch(words('Rename tree')), isTrue);
    expect(english.hasMatch(words('In {crate}')), isFalse);
    expect(english.hasMatch(words('--orchard NAME says which team')), isFalse);
    expect(latin.hasMatch(words('Neue Crate')), isTrue);
    expect(own['de']!.hasMatch(words('Mein Baum')), isTrue);
    expect(own['ko']!.hasMatch(words('트리거')), isFalse);
    expect(own['ko']!.hasMatch(words('레지스트리')), isFalse);
    expect(own['ko']!.hasMatch(words('내 트리')), isTrue);
    expect(own['hi']!.hasMatch(words('एंट्री')), isFalse);
    expect(own['hi']!.hasMatch(words('टेलीमेट्री')), isFalse);
    expect(own['hi']!.hasMatch(words('मेरा ट्री')), isTrue);
    expect(own['es']!.hasMatch(words('Mi árbol')), isTrue);
    expect(own['ar']!.hasMatch(words('شجرتي')), isTrue);
  });
}
