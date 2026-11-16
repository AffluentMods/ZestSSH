import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source gate for recording mode (spec section 2).
///
/// A `Redactable` has a `raw` form and a `display` form. Screens must render
/// `display`; only the connection layer, the SSH core boundary and export
/// paths may take `raw`. This test fails the build if `.raw` is read anywhere
/// under the UI directories, unless that exact line carries the annotation
///
///     // redaction: raw ok
///
/// which is the documented, greppable exception (a copy-to-clipboard behind
/// the reveal gate, an export path). Comment lines are ignored.
///
/// What it does not see: a screen that paints a plain String field (a
/// host's address, a user name) with no Redactable at all. That is checked
/// by pumping screens with seeded secrets in recording mode
/// (test/redaction/seeded_surfaces_test.dart), not here (found in a
/// review).
void main() {
  test('no .raw reads under lib/ui or lib/features without an annotation', () {
    final roots = [Directory('lib/ui'), Directory('lib/features')];
    final raw = RegExp(r'\.raw\b');
    final offenders = <String>[];
    for (final root in roots) {
      if (!root.existsSync()) continue;
      for (final f in root.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          final t = line.trimLeft();
          if (t.startsWith('//')) continue; // a comment, not a read
          if (!raw.hasMatch(line)) continue;
          if (line.contains('redaction: raw ok')) continue;
          offenders.add('${f.path.replaceAll('\\', '/')}:${i + 1}: ${t.trim()}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'Reading .raw in UI code bypasses recording mode. Render .display,\n'
          'or annotate the line with `// redaction: raw ok` if it is a gated\n'
          'copy/export path:\n  ${offenders.join('\n  ')}',
    );
  });
}
