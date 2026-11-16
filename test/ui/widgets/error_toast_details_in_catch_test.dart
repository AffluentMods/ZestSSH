import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// An error said in a `catch` passes what was caught to the toast, so its
/// Copy details holds it (found in a review): 45 error toasts in a
/// catch said a fixed sentence and left the exception to the log alone.
/// Read from the sources.

/// The index of the bracket that closes the one at [i] (strings skipped).
int _closing(String s, int i) {
  var depth = 0;
  String? quote;
  for (var j = i; j < s.length; j++) {
    final c = s[j];
    if (quote != null) {
      if (c == r'\') {
        j++;
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
    } else if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return j;
    }
  }
  return -1;
}

/// The name a `catch (name)` block holding [pos] binds, walking the blocks out.
String? _catchAround(String s, int pos) {
  var depth = 0;
  final catchHead = RegExp(r'catch\s*\(\s*([A-Za-z_]\w*)[^{;]*\)\s*$');
  for (var j = pos - 1; j > 0; j--) {
    final c = s[j];
    if (c == '}') {
      depth++;
    } else if (c == '{') {
      if (depth == 0) {
        final head = s.substring(j - 160 < 0 ? 0 : j - 160, j);
        final m = catchHead.firstMatch(head);
        if (m != null) return m.group(1);
      } else {
        depth--;
      }
    }
  }
  return null;
}

void main() {
  test('no error toast in a catch leaves out what was caught', () {
    final missing = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart') || f.path.contains('generated')) continue;
      final s = f.readAsStringSync();
      for (final m in RegExp(r'showTopSnackBar\(').allMatches(s)) {
        final end = _closing(s, m.end - 1);
        if (end < 0) continue;
        final args = s.substring(m.end, end);
        if (!RegExp(r'\bisError:\s*true\b').hasMatch(args) || args.contains('details:')) continue;
        final caught = _catchAround(s, m.start);
        if (caught == null) continue;
        missing.add('${f.path}:${'\n'.allMatches(s.substring(0, m.start)).length + 1} ($caught)');
      }
    }
    expect(missing, isEmpty);
  });
}
