import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Android's network security config says what the app does, and no more
/// (found in a security review).
///
/// The app's requests go through dart:io's TLS, which does not read that
/// file: a pin written there protects nothing the app sends, tells a reader
/// of the source that it does, and cuts off whatever does use Android's own
/// HTTP stack when the certificate changes or the pin set's date passes. So
/// the file holds no pin while the Dart client holds none, forbids cleartext,
/// and trusts the system's authorities alone.
void main() {
  final config = File('android/app/src/main/res/xml/network_security_config.xml').readAsStringSync();
  // (What the file does, not what its comment says of the past.)
  final rules = config.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

  test('no certificate is pinned in it, and no host is named', () {
    expect(rules, isNot(contains('<pin')));
    expect(rules, isNot(contains('<domain')));
    expect(rules, isNot(contains('zestssh.com')));
  });

  test('cleartext is off for every host, and only the system\'s authorities are trusted', () {
    expect(RegExp(r'<base-config\s+cleartextTrafficPermitted="false"\s*>').hasMatch(rules), isTrue);
    expect(rules, isNot(contains('cleartextTrafficPermitted="true"')));
    expect(RegExp(r'<certificates\s+src="[^"]*"').allMatches(rules).map((m) => m[0]), ['<certificates src="system"']);
    expect(rules, isNot(contains('debug-overrides')));
  });

  test('the manifest uses it', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android:networkSecurityConfig="@xml/network_security_config"'));
    expect(manifest, isNot(contains('usesCleartextTraffic="true"')));
  });

  test('the Dart client pins nothing either, and says so: it refuses what the system refuses', () {
    final client = File('lib/services/pinned_http_client.dart').readAsStringSync();
    expect(client, contains('static bool refuseBadCertificate('));
    expect(RegExp(r'refuseBadCertificate\([^)]*\)\s*\{[^}]*return false;').hasMatch(client), isTrue,
        reason: 'a certificate the system refused is refused, whatever the host');
    // The one place that said the hosted API was pinned.
    expect(File('lib/services/sync/zest_server_backend.dart').readAsStringSync(), isNot(contains('TLS-pinned')));
  });
}
