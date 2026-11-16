import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// English says Wi-Fi and jump host, as the rest of the app does (the
/// words a review found that are not plan names): "WiFi" stood in
/// three strings and "jump server" in two. The plan names (Pro, Fresh,
/// Cloud Sync) wait for a later decision.
void main() {
  final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync()) as Map<String, dynamic>;

  test('no English string says WiFi or jump server', () {
    final found = [
      for (final e in en.entries)
        if (!e.key.startsWith('@') && e.value is String && RegExp(r'\bWiFi\b|[Jj]ump servers?\b').hasMatch(e.value as String))
          e.key,
    ];
    expect(found, isEmpty);
  });
}
