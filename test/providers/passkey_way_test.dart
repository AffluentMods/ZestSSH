import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/providers/two_step_providers.dart';
import 'package:zestssh/services/auth_service.dart';
import 'package:zestssh/services/passkeys/passkey_platform.dart';

import '../helpers/soft_passkeys.dart';

/// How a device adds a passkey (3.3; 3.4.1 docs check): its own ceremony
/// where the system has one, the browser on a computer, none on a device that
/// signs in with Firebase but has no ceremony. The Mac is a computer here: its
/// build bundles no Firebase configuration, so Firebase never starts there,
/// it signs in through the browser like Windows and Linux, and it adds
/// passkeys on zestssh.com (the two-step contract, sections 4 and 6.7). A Mac
/// build that one day bundles Firebase would turn the Mac's passkeys to none
/// and its sign-in to Firebase's, so that is held here, to be decided, not
/// slipped in.
void main() {
  Future<PasskeyWay> wayWith(PasskeyPlatform platform) async {
    final container = ProviderContainer(overrides: [passkeyPlatformProvider.overrideWithValue(platform)]);
    addTearDown(container.dispose);
    return container.read(passkeyWayProvider.future);
  }

  test('a computer with no ceremony of its own and no Firebase (Linux, the Mac) adds passkeys in the browser',
      () async {
    expect(AuthService.isFirebaseAvailable, isFalse, reason: 'no Firebase app, as on every computer build');
    expect(await wayWith(const NoPasskeys()), PasskeyWay.browser);
  });

  test('a computer whose system has a ceremony (Windows Hello) uses it', () async {
    expect(await wayWith(ScriptedPasskeys()), PasskeyWay.here);
  });

  test('a Windows without webauthn.dll adds them in the browser too', () async {
    expect(await wayWith(ScriptedPasskeys(available: false)), PasskeyWay.browser);
  });

  group('the Mac build bundles no Firebase configuration', () {
    test('the Mac target names no GoogleService-Info.plist, as the iOS target does', () {
      final mac = File('macos/Runner.xcodeproj/project.pbxproj').readAsStringSync();
      final ios = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
      expect(ios, contains('GoogleService-Info.plist'), reason: 'the check reads the right files');
      expect(mac, isNot(contains('GoogleService-Info.plist')),
          reason: 'a Mac with Firebase signs in with it and adds no passkey: '
              'decide that first (lib/providers/two_step_providers.dart, passkeyWayProvider)');
    });

    test('nothing gives Firebase its options in code either', () {
      final main = File('lib/main.dart').readAsStringSync();
      expect(RegExp(r'Firebase\.initializeApp\(\s*\)').hasMatch(main), isTrue,
          reason: 'the default app comes from the platform configuration file only');
      expect(File('lib/firebase_options.dart').existsSync(), isFalse);
    });
  });
}
