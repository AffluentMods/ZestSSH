import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/passkeys/channel_passkeys.dart';
import 'package:zestssh/services/passkeys/passkey_platform.dart';
import 'package:zestssh/services/passkeys/windows_passkeys.dart';

/// Which device makes its own passkeys (3.3; the two-step contract, section
/// 4 and 6.7): Android and iOS through zestssh/passkeys, Windows through
/// webauthn.dll; the Mac, Linux and anything else have none (they make one on
/// zestssh.com, and sign in through the browser).
void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  PasskeyPlatform on(TargetPlatform platform) {
    debugDefaultTargetPlatformOverride = platform;
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container.read(passkeyPlatformProvider);
  }

  test('each system its own', () {
    expect(on(TargetPlatform.android), isA<ChannelPasskeys>());
    expect(on(TargetPlatform.iOS), isA<ChannelPasskeys>());
    // The Mac asks its own channel since 4.0; a build macOS shows no passkey
    // sheet for answers that it has none (channel_passkeys_test.dart).
    expect(on(TargetPlatform.macOS), isA<ChannelPasskeys>());
    expect(on(TargetPlatform.windows), isA<WindowsPasskeys>());
    for (final none in [TargetPlatform.linux, TargetPlatform.fuchsia]) {
      expect(on(none), isA<NoPasskeys>(), reason: '$none');
    }
  });

  test('a device with none says so, and makes and uses none', () async {
    const none = NoPasskeys();
    expect(await none.isAvailable(), isFalse);
    await expectLater(none.create(const {}), throwsA(isA<PasskeyError>().having((e) => e.code, 'code', 'unsupported')));
    await expectLater(none.get(const {}), throwsA(isA<PasskeyError>().having((e) => e.code, 'code', 'unsupported')));
  });
}
