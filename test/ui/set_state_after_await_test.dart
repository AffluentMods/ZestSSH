import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A screen that sets its state right after it waited for something says
/// first that it is still there (since 3.4.2): a QR scan closed while
/// the camera started again, a terminal closed while speech stopped, the
/// session logs closed while a file was deleted each ended in "setState()
/// called after dispose()".
///
/// What is looked at: the statement each setState follows, past braces,
/// `try`, `catch` and comments. Where that waited (an `await`), a check of
/// `mounted` is to come between.
void main() {
  const files = [
    'lib/ui/screens/connection/qr_scan_screen.dart',
    'lib/ui/screens/terminal/terminal_screen.dart',
    'lib/ui/screens/settings/session_logs_screen.dart',
  ];
  final skipped = RegExp(r'^(\}|\{|try \{|\} catch .*\{|\} on .*\{|\} finally \{|//.*)?$');

  test('no setState straight after an await, with no mounted between', () {
    final found = <String>[];
    for (final path in files) {
      final lines = File(path).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].trimLeft().startsWith('setState(')) continue;
        var j = i - 1;
        while (j >= 0 && skipped.hasMatch(lines[j].trim())) {
          j--;
        }
        if (j < 0) continue;
        final before = lines[j];
        if (before.contains('mounted')) continue;
        if (RegExp(r'\bawait\b').hasMatch(before)) found.add('$path:${i + 1} after "${before.trim()}"');
      }
    }
    expect(found, isEmpty);
  });
}
