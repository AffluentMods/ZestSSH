import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/services/passkeys/channel_passkeys.dart';
import 'package:zestssh/services/passkeys/windows_passkeys.dart';
import 'package:zestssh/utils/type_name.dart';

// The device's own passkey ceremonies (3.3; the two-step contract, section
// 4): ZestSSH Cloud's WebAuthn options go in as JSON and the response comes
// out as JSON, through this one interface, so the sign-in and the screens
// never know which platform made or used the passkey.
//
//   Android  Credential Manager (androidx.credentials), channel zestssh/passkeys
//   iOS 16+  AuthenticationServices, channel zestssh/passkeys
//   Windows  webauthn.dll through dart:ffi
//
// Linux and the Mac have none of their own ([NoPasskeys]): a passkey is made
// there on zestssh.com (its add-passkey page, contract section 7.12), and a
// computer signs in through the browser anyway. iOS 15 and Android 8 keep
// the authenticator only.

/// The device's passkey ceremonies.
abstract interface class PasskeyPlatform {
  /// Whether this device makes and uses passkeys itself. False on Linux, the
  /// Mac and older systems.
  Future<bool> isAvailable();

  /// Makes a passkey for ZestSSH Cloud's PublicKeyCredentialCreationOptionsJSON
  /// [options]; answers the RegistrationResponseJSON, as the server reads it.
  /// Throws [PasskeyCancelled] where the person closed the system's dialog,
  /// [PasskeyError] otherwise.
  Future<Map<String, Object?>> create(Map<String, Object?> options);

  /// Uses a passkey for ZestSSH Cloud's PublicKeyCredentialRequestOptionsJSON
  /// [options]; answers the AuthenticationResponseJSON. Throws as [create].
  Future<Map<String, Object?>> get(Map<String, Object?> options);
}

/// The person closed the system's passkey dialog, or it timed out: no error,
/// they may try again or choose another way.
class PasskeyCancelled implements Exception, HasTypeName {
  const PasskeyCancelled();

  @override
  String toString() => 'Passkey: cancelled';

  @override
  String get typeName => 'PasskeyCancelled';
}

/// The system could not make or use a passkey: [code] says why in a word a
/// screen can be written for ('unsupported', 'no-credential',
/// 'invalid-state', 'security', 'failed'); [detail] is the system's own,
/// for Copy details, never shown as it is.
class PasskeyError implements Exception, HasTypeName {
  const PasskeyError(this.code, [this.detail]);

  final String code;
  final String? detail;

  @override
  String toString() => 'Passkey: $code${detail == null ? '' : ' ($detail)'}';

  @override
  String get typeName => 'PasskeyError';
}

/// A device with no passkeys of its own (Linux, older systems).
class NoPasskeys implements PasskeyPlatform {
  const NoPasskeys();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<Map<String, Object?>> create(Map<String, Object?> options) =>
      Future.error(const PasskeyError('unsupported'));

  @override
  Future<Map<String, Object?>> get(Map<String, Object?> options) =>
      Future.error(const PasskeyError('unsupported'));
}

/// The device's passkey ceremonies: [defaultPasskeyPlatform]; tests override
/// it with a fake.
final passkeyPlatformProvider = Provider<PasskeyPlatform>((ref) => defaultPasskeyPlatform());

/// This system's own: Android's Credential Manager and Apple's
/// AuthenticationServices (iOS, and the Mac since 4.0) on the channel
/// zestssh/passkeys (channel_passkeys.dart), Windows' webauthn.dll
/// (windows_passkeys.dart), [NoPasskeys] on Linux and the web. Android below
/// 9, iOS below 16, macOS below 13 and Windows without webauthn.dll answer as
/// [NoPasskeys] does: isAvailable false, and 'unsupported'. So does a Mac
/// build that macOS would not show a passkey sheet for (one without the
/// associated domains entitlement: a debug run, an unsigned or a community
/// build; macos/Runner/PasskeyChannel.swift), which goes on making passkeys
/// through the website as every Mac did before 4.0.
PasskeyPlatform defaultPasskeyPlatform() {
  if (kIsWeb) return const NoPasskeys();
  return switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.macOS => ChannelPasskeys(),
    TargetPlatform.windows => WindowsPasskeys(),
    _ => const NoPasskeys(),
  };
}
