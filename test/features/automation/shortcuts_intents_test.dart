import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/deep_link_service.dart';

/// The iOS Shortcuts actions "Run SSH Command" and "Run SSH Snippet", held
/// to what the app takes: a zestssh:// link that the app asks about ("Run
/// this from a link?") and then checks the automation API key of. They sent
/// no key, so the app refused every one of them (found in
/// a 3.0 docs review); now each has an API Key parameter that goes in the
/// link as `key`, exactly as an automation link's, and nothing is left in the
/// shared defaults (where a key would lie readable by the app's extensions).
/// Swift does not run here: what the actions build is read from the source.
void main() {
  final swift = File('ios/Runner/ZestSSHIntents.swift').readAsStringSync().replaceAll('\r\n', '\n');

  /// The source of the intent named [name], up to the next one.
  String intent(String name) {
    final start = swift.indexOf('struct $name: AppIntent');
    expect(start, isNonNegative, reason: name);
    final next = swift.indexOf('\n// MARK:', start);
    return swift.substring(start, next < 0 ? swift.length : next);
  }

  for (final (name, host) in [('ExecuteSSHCommandIntent', 'execute'), ('RunSSHSnippetIntent', 'snippet')]) {
    test('$name opens zestssh://$host with the API key it is given', () {
      final source = intent(name);
      expect(source, contains('components.host = "$host"'));
      expect(RegExp(r'@Parameter\(title: "API Key"[^\n]*\)\n\s*var apiKey: String').hasMatch(source), isTrue,
          reason: 'an API Key parameter');
      expect(source, contains('URLQueryItem(name: "key", value: apiKey)'));
      // Nothing is written beside the link: the app never reads it.
      expect(source, isNot(contains('pending_automation')));
      expect(source, isNot(contains('UserDefaults')));
      // A "+" in a command reaches the app as a "+".
      expect(source, contains('replacingOccurrences(of: "+", with: "%2B")'));
    });
  }

  test('such a link, once the person says yes, reaches automation with its key', () async {
    DeepLinkService.onAutomationRequested = (action, command, target, [variables = const {}]) async => true;
    addTearDown(() => DeepLinkService.onAutomationRequested = null);
    // As URLComponents writes it, a "+" encoded.
    final exec = await DeepLinkService.extractAutomationParams(
        Uri.parse('zestssh://execute?connection=web-1&command=date%20%2B%25s&timeout=30&key=k3yFromShortcuts'));
    expect(exec, isNotNull);
    expect(exec!['key'], 'k3yFromShortcuts');
    expect(exec['command'], 'date +%s');
    final snippet = await DeepLinkService.extractAutomationParams(
        Uri.parse('zestssh://snippet?connection=web-1&name=Deploy&key=k3yFromShortcuts'));
    expect(snippet!['key'], 'k3yFromShortcuts');
    expect(snippet['snippet_name'], 'Deploy');
  });
}
