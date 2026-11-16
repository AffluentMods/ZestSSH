import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A button's own text style takes the place of the theme's whole, so one
/// that names no font family draws its label in the system's font (solid bars
/// in the screenshots: the Passphrase row's Add one and Check, and the links
/// under the sync password). Every
/// `textStyle:` given to a button names the app's font.
void main() {
  test("every button text style names the app's font", () {
    final missing = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart') || file.path.contains('generated')) continue;
      final source = file.readAsStringSync();
      for (final match in RegExp(r'textStyle:\s*(const\s+)?TextStyle\(').allMatches(source)) {
        // The style's own parentheses, nested ones included.
        var depth = 0;
        var end = match.end - 1;
        for (; end < source.length; end++) {
          final c = source[end];
          if (c == '(') depth++;
          if (c == ')' && --depth == 0) break;
        }
        final style = source.substring(match.start, end + 1);
        if (!style.contains('fontFamily')) {
          final line = '\n'.allMatches(source.substring(0, match.start)).length + 1;
          missing.add('${file.path}:$line');
        }
      }
    }
    expect(missing, isEmpty, reason: 'a button style without fontFamily falls back to the system font');
  });
}
