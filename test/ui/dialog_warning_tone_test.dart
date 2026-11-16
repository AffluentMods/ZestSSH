import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A dialog of ZestDialogTone.warning says its warning in its one amber
/// sentence (rule 1 of the dialog rules, 3.4): ZestConfirmDialog's
/// `warning:` or a ZestCallout. The tone itself is the neutral frame, so a
/// warning dialog with no such sentence is only an ordinary question with an
/// alarm's icon: it is ZestDialogTone.neutral (a pass in 3.4 went
/// through the 96 warning dialogs one by one).
///
/// Read per file, as a count: a file has no more warning dialogs than amber
/// sentences.
void main() {
  /// The host list's (remade on its own branch, so left alone here).
  const left = <String, int>{'lib/ui/screens/home/home_screen.dart': 1};

  int count(String text, RegExp pattern) {
    var n = 0;
    for (final line in text.replaceAll('\r\n', '\n').split('\n')) {
      final t = line.trimLeft();
      if (t.startsWith('//') || t.startsWith('*') || t.startsWith('/*')) continue;
      n += pattern.allMatches(line).length;
    }
    return n;
  }

  final tone = RegExp(r'ZestDialogTone\.warning\b');
  final sentence = RegExp(r'\bZestCallout\(|\bwarning:');

  test('every warning dialog shows its warning sentence in amber', () {
    final silent = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll(r'\', '/');
      if (!path.endsWith('.dart') || path.contains('/generated/') || path.endsWith('/zest_dialog.dart')) continue;
      final text = file.readAsStringSync();
      final warnings = count(text, tone);
      if (warnings == 0) continue;
      final said = count(text, sentence);
      if (warnings > said && warnings > (left[path] ?? 0)) silent.add('$path: $warnings warning, $said amber');
    }
    expect(silent..sort(), isEmpty,
        reason: 'a warning says itself in one amber sentence (ZestConfirmDialog warning:, or a ZestCallout); '
            'an ordinary question is ZestDialogTone.neutral');
  });

  test('the check counts the tone and the sentence, not a comment', () {
    expect(count('      tone: ZestDialogTone.warning,', tone), 1);
    expect(count('  /// was ZestDialogTone.warning', tone), 0);
    expect(count('      warning: l10n.x,\n      body: ZestCallout(l10n.y),', sentence), 2);
  });
}
