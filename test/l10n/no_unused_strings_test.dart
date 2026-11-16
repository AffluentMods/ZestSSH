import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every English string is used: named by some Dart file of the app itself,
/// under lib/ (found in a review). 1,316 were named by none, each
/// translated eleven times over for nothing and in the translators' way; they
/// were removed. A string a change stops using goes with it.
///
/// Only lib/ counts (found in a follow-up): a test that checks an old text is
/// gone named its key, and kept 65 strings that no screen showed alive and
/// translated. A test checks such a text by its literal instead.
void main() {
  test('every key of app_en.arb is named by the app\'s own code, outside the generated code', () {
    final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync()) as Map<String, dynamic>;
    final keys = [for (final k in en.keys) if (!k.startsWith('@')) k];
    final word = RegExp(r'[A-Za-z_]\w*');
    final named = <String>{};
    var files = 0;
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = f.path.replaceAll(r'\', '/');
      if (!path.endsWith('.dart') || path.contains('/generated/')) continue;
      files++;
      named.addAll(word.allMatches(f.readAsStringSync()).map((m) => m.group(0)!));
    }
    expect(files, greaterThan(1000), reason: 'the sources were read');
    expect(keys.length, greaterThan(5000));
    final unused = [for (final k in keys) if (!named.contains(k)) k];
    expect(unused, isEmpty,
        reason: 'strings the app does not use: remove them from the 12 ARB files, and have a test that '
            'looks for an old text use its literal (${unused.take(20).join(', ')})');
  });
}
