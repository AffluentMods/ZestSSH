import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Chinese marks in Chinese sentences (3.0).
///
/// The Chinese app wrote its commas, colons, semicolons, question marks and
/// exclamation marks in two hands: the full-width ones a Chinese sentence
/// has (，：；？！) in over a thousand strings, and the ASCII ones of an
/// English sentence, some with the space an English sentence has after
/// them, in three hundred and fifty more: "结果会按服务器分组,每组带有一行标题"
/// beside "结果会按服务器分组，每组带有一行标题". A reader met both on one
/// screen.
///
/// A mark is held to the full-width form where the character before it is
/// Chinese, or the character after it, with a space between or without.
/// Brackets, straight quotes and "..." are not looked at, nor is a mark
/// between two things that are not Chinese (a list of names, an address).
void main() {
  final strings = {
    for (final e in (jsonDecode(File('lib/l10n/app_zh.arb').readAsStringSync()) as Map<String, dynamic>).entries)
      if (!e.key.startsWith('@') && e.value is String) e.key: e.value as String,
  };

  String range(int from, int to) => '${String.fromCharCode(from)}-${String.fromCharCode(to)}';
  // Chinese letters; with them the full-width marks and signs; and with those the curly quotes.
  final letters = range(0x3400, 0x4DBF) + range(0x4E00, 0x9FFF);
  final chinese = letters + range(0x3000, 0x303F) + range(0xFF00, 0xFFEF);
  final chineseOrQuote = chinese + range(0x2018, 0x201D);

  /// Strings whose ASCII mark is part of how something is written, and stays.
  const kept = {
    // "IP:port", as an address with its port is written.
    'sessionInfoIpPortCopied',
    'sessionInfoCopyIpPort',
  };

  Map<String, String> where(RegExp found) => {
        for (final MapEntry(:key, :value) in strings.entries)
          if (!kept.contains(key) && found.hasMatch(value)) key: found.firstMatch(value)!.group(0)!,
      };

  test('no ASCII comma, colon, semicolon, question mark or exclamation mark stands after a Chinese character', () {
    final found = where(RegExp('[$chineseOrQuote][,:;?!]'));
    expect(found, isEmpty, reason: '${found.length} Chinese strings');
  });

  test('nor before one, with a space between or without', () {
    final found = where(RegExp('[,:;?!] ?[$chinese]'));
    expect(found, isEmpty, reason: '${found.length} Chinese strings');
  });

  test('a full-width mark has no space after it', () {
    final found = where(RegExp('[，：；？！] '));
    expect(found, isEmpty, reason: '${found.length} Chinese strings');
  });

  test('the strings that keep an ASCII mark are there, and are what they are kept for', () {
    for (final key in kept) {
      expect(strings[key], contains('IP:'), reason: key);
    }
  });

  test('what a plural or a choice is written with is the format\'s own, and ASCII', () {
    // "{count, plural, ...}": a full-width comma there would be no format at all.
    final found = where(RegExp('\\{\\w+[，：]'));
    expect(found, isEmpty);
    expect(strings.values.where((value) => RegExp(r'\{\w+, plural,').hasMatch(value)), isNotEmpty,
        reason: 'the strings were read');
  });
}
