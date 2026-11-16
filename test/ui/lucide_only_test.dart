import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The app draws one icon set, Lucide's line icons (3.0):
/// Material's filled glyphs mixed in read as two products.
/// Brand marks Lucide has none of stay Material's.
void main() {
  const brands = {'android', 'discord', 'apple', 'g_mobiledata', 'adb'};

  test('no Material icon in lib/ but the brand marks Lucide does not draw', () {
    final icon = RegExp(r'(?<![A-Za-z_.])Icons\.([a-z_0-9]+)');
    final found = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart') || f.path.contains('generated')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        for (final m in icon.allMatches(lines[i])) {
          final base = m.group(1)!.replaceAll(RegExp(r'_(outlined|rounded|sharp)$'), '');
          if (!brands.contains(base)) found.add('${f.path}:${i + 1} ${m.group(0)}');
        }
      }
    }
    expect(found, isEmpty);
  });

  test('the check itself finds a Material icon and lets a brand mark and a Lucide one be', () {
    final icon = RegExp(r'(?<![A-Za-z_.])Icons\.([a-z_0-9]+)');
    expect(icon.firstMatch('const Icon(Icons.close)')?.group(1), 'close');
    expect(icon.firstMatch('const Icon(LucideIcons.x)'), isNull);
    expect(icon.firstMatch('Icon(Icons.discord)')?.group(1), 'discord');
  });
}
