import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// No screen puts a caught error's own words into a sentence the person
/// reads (3.0). "Join failed: SyncException: Decryption failed -
/// sync data may be corrupted" is English in every language, names a type
/// of the program's and says nothing the person can act on: a screen says
/// what failed in the person's language, and keeps the error's words for
/// Copy details.
///
/// Read from the files: what a sentence is given cannot be seen from a
/// test of each screen. The places that still do it are listed, file by
/// file, with how many; one made right comes off the list.
void main() {
  // (The list was made right in 3.0: a
  // place that does it again is added here only with why.)
  const allowed = <String, int>{};
  // However a screen reaches its sentences: l10n, gl10n, AppLocalizations.of(context)!.
  const strings = r'(?:\bl10n|\bgl10n|\bloc|\bstrings|AppLocalizations\.of\(\w+\)!?)';
  const caught = '(?:e|err|error|ex|exception)';
  final raw = [
    // strings.joinFailed(e.toString()), strings.saveFailed('$e'), strings.failed('${e}'), strings.failed(e.message)
    RegExp('$strings\\.\\w+\\(\\s*$caught\\.toString\\(\\)'),
    RegExp("$strings\\.\\w+\\(\\s*'\\\$$caught'"),
    RegExp("$strings\\.\\w+\\(\\s*'\\\$\\{$caught\\}'"),
    RegExp('$strings\\.\\w+\\(\\s*$caught\\.message'),
    // A sync failure's words as the line of the sync card, with nothing for the details.
    RegExp(r'setError\(\s*(?:e|err|error)\.message\s*\)'),
  ];

  test('no screen puts a caught error\'s own words into a sentence the person reads, but where it is listed', () {
    final found = <String, int>{};
    var read = 0;
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll(r'\', '/');
      if (!path.endsWith('.dart') || path.contains('/generated/')) continue;
      final text = file.readAsStringSync();
      read++;
      final n = raw.fold<int>(0, (sum, r) => sum + r.allMatches(text).length);
      if (n > 0) found[path] = n;
    }
    expect(read, greaterThan(500), reason: 'the files were read');
    for (final MapEntry(key: path, value: n) in found.entries) {
      expect(n, lessThanOrEqualTo(allowed[path] ?? 0),
          reason: '$path puts a caught error\'s own words into a sentence: say what failed in the person\'s language, '
              'and give the error to Copy details');
    }
    for (final MapEntry(key: path, value: n) in allowed.entries) {
      expect(found[path] ?? 0, n, reason: '$path is listed for $n, and has ${found[path] ?? 0}: make the list say so');
    }
  });
}
