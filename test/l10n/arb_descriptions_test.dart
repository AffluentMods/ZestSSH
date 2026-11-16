import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every English string tells its translators where it appears and what it
/// means (a review found 7,648 of 10,890 with no description, among
/// them "Local", "Auto", "Total" and "{count} selected" with nothing to say
/// where they show or what they count). A new key comes with its description.
void main() {
  final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync()) as Map<String, dynamic>;
  final keys = [for (final k in en.keys) if (!k.startsWith('@')) k];

  test('every key of app_en.arb has a description', () {
    expect(keys.length, greaterThan(5000), reason: 'the file was read');
    final missing = <String>[];
    for (final k in keys) {
      final meta = en['@$k'];
      final description = meta is Map ? meta['description'] : null;
      if (description is! String || description.trim().isEmpty) missing.add(k);
    }
    expect(missing, isEmpty,
        reason: 'add "@key": {"description": "..."} to app_en.arb: where the text appears, what it means, '
            'and what each placeholder is (${missing.length}: ${missing.take(20).join(', ')})');
  });

  test('a description names every placeholder of its string', () {
    final unnamed = <String>[];
    for (final k in keys) {
      final meta = en['@$k'];
      if (meta is! Map) continue;
      final placeholders = (meta['placeholders'] as Map?)?.keys ?? const [];
      final description = (meta['description'] as String?) ?? '';
      for (final p in placeholders) {
        if (!description.contains('{$p}') && !description.contains(p as String)) unnamed.add('$k {$p}');
      }
    }
    expect(unnamed, isEmpty, reason: 'say what each placeholder is filled in with (${unnamed.take(20).join(', ')})');
  });

  test('descriptions carry no long dashes (the repository keeps none)', () {
    final dashed = [
      for (final k in keys)
        if (((en['@$k'] as Map?)?['description'] as String? ?? '').contains(RegExp('[\u2013\u2014]'))) k,
    ];
    expect(dashed, isEmpty);
  });
}
