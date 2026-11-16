import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// What a screen shows is public: a hint names a made-up host, never one of a
/// home network (the Prometheus field said `prometheus.home.lan` in every language:
/// found in a security review). A rule of the app that knows the suffix
/// (own_network_http.dart, its private suffixes) is no address, and is not read here.
void main() {
  test('no string names a host under a home network\'s suffix', () {
    final strings = Directory('lib/l10n').listSync().whereType<File>().where((f) => f.path.endsWith('.arb')).toList();
    expect(strings, hasLength(12));
    for (final file in strings) {
      expect(RegExp(r'[a-z0-9-]+\.(home\.)?lan\b').allMatches(file.readAsStringSync()).map((m) => m.group(0)), isEmpty, reason: file.path);
    }
  });
}
