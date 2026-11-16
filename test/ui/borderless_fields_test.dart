// A text field that draws no box of its own (it sits in a container that is
// its box) says so for every state (found in a code review):
// `border: InputBorder.none` is only the fallback, and the theme's enabled,
// focused, disabled and error outlines still drew a second box inside the
// container wherever one of them was left out.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _states = ['border', 'enabledBorder', 'focusedBorder', 'disabledBorder', 'errorBorder', 'focusedErrorBorder'];

/// Fields of other areas of the 3.0 UI work still to be completed (each draws
/// the theme's error or disabled outline only in that state). Remove a line
/// once its file names every state.
const _knownOpen = <String>{};

/// The InputDecoration( ... ) around [at] in [src], or null.
String? _decorationAround(String src, int at) {
  final start = src.lastIndexOf(RegExp(r'InputDecoration\('), at);
  if (start < 0) return null;
  var depth = 0;
  for (var i = src.indexOf('(', start); i < src.length; i++) {
    if (src[i] == '(') depth++;
    if (src[i] == ')' && --depth == 0) {
      return i >= at ? src.substring(start, i + 1) : null;
    }
  }
  return null;
}

void main() {
  test('every InputDecoration that sets border: InputBorder.none sets it for every state', () {
    final open = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart') || f.path.contains('${Platform.pathSeparator}l10n${Platform.pathSeparator}')) continue;
      final src = f.readAsStringSync();
      final path = f.path.replaceAll('\\', '/');
      for (final m in RegExp(r'\bborder: InputBorder\.none').allMatches(src)) {
        final deco = _decorationAround(src, m.start);
        if (deco == null) continue;
        final missing = [
          for (final s in _states)
            if (!RegExp('\\b$s: InputBorder\\.none').hasMatch(deco)) s,
        ];
        if (missing.isEmpty) continue;
        final line = '\n'.allMatches(src.substring(0, m.start)).length + 1;
        if (_knownOpen.contains(path)) continue;
        open.add('$path:$line misses ${missing.join(', ')}');
      }
    }
    expect(open, isEmpty, reason: open.join('\n'));
  });
}
