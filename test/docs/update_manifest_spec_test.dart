import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/update_manifest.dart';

/// docs/update-manifest-spec.md says what the updater does.
/// Until 4.0 it described the first updater: a manifest with
/// no signature, read on Android too, and a button that only opened a page,
/// with download, check and install as something not to build yet. A reader
/// of the repository was told the update channel has no signature. The page
/// is held to the code here: what it names is there, and its numbers are
/// the code's.
void main() {
  String read(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');
  final page = read('docs/update-manifest-spec.md');

  test('it says the manifest is signed, with what, and what is refused', () {
    expect(page, contains('"signature"'));
    expect(page, contains('Ed25519'));
    expect(page, contains('kUpdateSigningPublicKeys'));
    expect(page, contains('ZS-1902'));
    expect(page, contains('ZS-1903'));
    // What the old page said.
    expect(page.toLowerCase(), isNot(contains('option a')));
    expect(page, isNot(contains('do NOT build')));
    expect(page.toLowerCase(), isNot(contains('sideloaded android')));
  });

  test('what it names is in the code', () {
    final manifest = read('lib/services/update_manifest.dart');
    final check = read('lib/services/update_check_service.dart');
    for (final name in ['kUpdateSigningPublicKeys', 'kUpdateSignaturePrefix', 'canonicalManifestBytes', 'updaterSetUp']) {
      expect(page, contains(name));
      expect(manifest, contains(name), reason: name);
    }
    expect(page, contains('UpdatePackage.parse'));
    expect(manifest, contains('static UpdatePackage? parse('));
    expect(page, contains('UpdateCheckService.checksOn'));
    expect(check, contains('static bool checksOn('));
    expect(page, contains('ZEST_UPDATE_MANIFEST_URL'));
    expect(check, contains("String.fromEnvironment('ZEST_UPDATE_MANIFEST_URL')"));
  });

  test('its numbers and its words are the code\'s', () {
    expect(page, contains('`${kUpdateSignaturePrefix.trimRight()}`'));
    expect(kUpdateSignaturePrefix.endsWith('\n'), isTrue, reason: 'the page says: and a line feed');
    expect(page, contains('`$kUpdateDownloadPath`'));
    final check = read('lib/services/update_check_service.dart');
    expect(page, contains('at most 64 KB'));
    expect(check, contains('resp.bodyBytes.length > 64 * 1024'));
    expect(page, contains('within 6 seconds'));
    expect(check, contains('.timeout(const Duration(seconds: 6))'));
    expect(page, contains('at most once in six hours'));
    expect(read('lib/providers/update_providers.dart'), contains('const _kMinCheckInterval = Duration(hours: 6);'));
    // Only the three computer platforms check.
    expect(UpdatePlatform.values.map((p) => p.name), ['windows', 'linux', 'macos']);
    for (final platform in UpdatePlatform.values) {
      expect(page, contains('"${platform.name}": {"url"'));
    }
  });

  test('no em or en dash', () {
    expect(page.contains(String.fromCharCode(0x2014)) || page.contains(String.fromCharCode(0x2013)), isFalse);
  });
}
