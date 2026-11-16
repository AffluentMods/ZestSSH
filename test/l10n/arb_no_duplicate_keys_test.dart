import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// No string file names a key twice. JSON takes the last one without a word,
// so the first is lost: the member picker's words for Owner were written
// under the key the Roles page already had, and the picker showed the Roles
// page's words in every language.

void main() {
  test('every key of every string file is named once', () {
    final files = Directory('lib/l10n').listSync().whereType<File>().where((f) => f.path.endsWith('.arb')).toList();
    expect(files, isNotEmpty);
    // The top level of each file: a key at the start of its line, two spaces in.
    final key = RegExp(r'^  "([^"]+)":', multiLine: true);
    for (final f in files) {
      final seen = <String>{};
      final twice = <String>{};
      for (final m in key.allMatches(f.readAsStringSync())) {
        if (!seen.add(m.group(1)!)) twice.add(m.group(1)!);
      }
      expect(twice, isEmpty, reason: '${f.path} names these more than once');
    }
  });
}
