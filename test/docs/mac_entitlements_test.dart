import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Mac app's two entitlement files (4.0). Passkeys in the app need the
/// associated domains entitlement, which macOS grants only to a build signed
/// with a provisioning profile that carries it; a build that names an
/// entitlement its profile does not grant is not started by macOS at all.
/// So the entitlement is in a file of its own, for the signed release build
/// alone, and every other build keeps the files it had.
void main() {
  String read(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');

  /// The keys of an entitlements file, comments left out, each with the text
  /// of its value.
  Map<String, String> entitlements(String path) {
    final text = read(path).replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
    return {
      for (final m in RegExp(r'<key>([^<]+)</key>\s*(<true/>|<false/>|<string>[^<]*</string>|<array>.*?</array>)', dotAll: true)
          .allMatches(text))
        m[1]!: m[2]!.replaceAll(RegExp(r'\s+'), ''),
    };
  }

  final plain = entitlements('macos/Runner/Release.entitlements');
  final signed = entitlements('macos/Runner/ReleaseSigned.entitlements');
  const added = {
    'com.apple.application-identifier',
    'com.apple.developer.team-identifier',
    'com.apple.developer.associated-domains',
  };

  test('a build without the profile names no entitlement that needs one', () {
    for (final file in ['macos/Runner/Release.entitlements', 'macos/Runner/DebugProfile.entitlements']) {
      final keys = entitlements(file).keys;
      expect(keys.where(added.contains), isEmpty, reason: file);
      expect(keys.where((k) => k.startsWith('com.apple.developer.')), isEmpty, reason: file);
    }
  });

  test('the signed build has everything the plain release has, and the three for passkeys', () {
    expect(plain, isNotEmpty);
    for (final MapEntry(key: key, value: value) in plain.entries) {
      expect(signed[key], value, reason: key);
    }
    expect(signed.keys.toSet().difference(plain.keys.toSet()), added);
    expect(signed['com.apple.developer.associated-domains'], '<array><string>webcredentials:zestssh.com</string></array>');
    // The application identifier is the team's and the app's bundle id, as
    // the profile and zestssh.com's apple-app-site-association name it.
    final team = RegExp(r'<string>([A-Z0-9]{10})</string>').firstMatch(signed['com.apple.developer.team-identifier']!)![1]!;
    final bundle = RegExp(r'PRODUCT_BUNDLE_IDENTIFIER = (\S+)').firstMatch(read('macos/Runner/Configs/AppInfo.xcconfig'))![1]!;
    expect(signed['com.apple.application-identifier'], '<string>$team.$bundle</string>');
  });

  test('no release file lets a debugger attach: Apple does not notarize an app that does', () {
    // A local ad hoc release build was seen carrying get-task-allow (the
    // signing added it, not these files); a release that is notarized must
    // not, so neither file names it.
    for (final file in ['macos/Runner/Release.entitlements', 'macos/Runner/ReleaseSigned.entitlements']) {
      expect(entitlements(file).keys, isNot(contains('com.apple.security.get-task-allow')), reason: file);
      expect(read(file), isNot(contains('get-task-allow')), reason: file);
    }
  });

  test('Xcode builds with the plain files: the signed one is only handed to codesign by the release step', () {
    final project = read('macos/Runner.xcodeproj/project.pbxproj');
    expect(project, isNot(contains('ReleaseSigned.entitlements')));
    final used = RegExp(r'CODE_SIGN_ENTITLEMENTS = (\S+);').allMatches(project).map((m) => m[1]!).toSet();
    expect(used, {'Runner/DebugProfile.entitlements', 'Runner/Release.entitlements'});
  });
}
