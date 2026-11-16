import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every font the code asks for by name is one the app ships (3.0, 17 October
/// 2026). The certificate pasted into a Prometheus connection was set in
/// 'monospace', a name Android and Linux resolve and Windows, macOS and iOS do
/// not: there it drew in a proportional font. (The system's own terminal font
/// is the one exception, chosen per system in lib/models/enums.dart.)
void main() {
  test('no text asks for a font the app does not ship', () {
    final shipped = {
      for (final m in RegExp(r'^\s*- family:\s*(\S+)', multiLine: true).allMatches(File('pubspec.yaml').readAsStringSync()))
        m[1]!,
    };
    expect(shipped, containsAll(['GeistSans', 'JetBrainsMono']), reason: 'the families of pubspec.yaml');
    final asked = RegExp(r'''fontFamily:\s*(?:const\s+)?['"]([^'"]+)['"]''');
    final found = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart') || path.contains('/generated/')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        for (final m in asked.allMatches(lines[i])) {
          if (!shipped.contains(m[1])) found.add('$path:${i + 1}: ${m[1]}');
        }
      }
    }
    expect(found, isEmpty, reason: 'ask for a font of pubspec.yaml (JetBrainsMono for code and keys)');
  });

  test('the check itself finds a font the app does not ship', () {
    final asked = RegExp(r'''fontFamily:\s*(?:const\s+)?['"]([^'"]+)['"]''');
    expect(asked.firstMatch("style: const TextStyle(fontFamily: 'monospace', fontSize: 12),")?[1], 'monospace');
  });
}
