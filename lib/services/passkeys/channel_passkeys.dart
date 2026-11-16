import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:zestssh/services/passkeys/passkey_json.dart';
import 'package:zestssh/services/passkeys/passkey_platform.dart';

// The phone's own passkey ceremonies (3.3; the two-step contract, section
// 4), on the channel zestssh/passkeys:
//
//   Android 9+  Credential Manager (androidx.credentials, with Google Play
//               services' provider for Android 9 to 13): MainActivity's
//               PasskeyChannel.kt. The origin the server sees is
//               android:apk-key-hash:<the signing key's>, written by the
//               system.
//   iOS 16+     AuthenticationServices, passkeys and security keys:
//               ios/Runner/PasskeyChannel.swift. The origin is
//               https://zestssh.com (webcredentials:zestssh.com).
//
// Both take ZestSSH Cloud's options as JSON text and answer the system's
// own response JSON as text, which is checked and written here as the server
// reads it (passkey_json.dart). Below those versions the native side answers
// isAvailable false and 'unsupported', as NoPasskeys does.
//
// What the native side answers when it fails, as a PlatformException's code:
//   cancelled      the person closed the system's dialog, or it timed out
//   no-credential  no passkey of the account is on this device (sign-in)
//   invalid-state  this device holds one of the account's passkeys already
//   security       the system would not make one for zestssh.com for this app
//   unsupported    the system cannot make or use passkeys here
//   failed         anything else
// with the system's own words for it as the message (for Copy details).

/// The channel both phones' ceremonies answer on.
const kPasskeyChannel = MethodChannel('zestssh/passkeys');

/// The codes of [PasskeyError] the native side may answer with.
const _knownCodes = {'unsupported', 'no-credential', 'invalid-state', 'security', 'failed'};

/// The longest detail kept of what the native side said.
const _maxDetail = 300;

/// The phone's passkey ceremonies, through the channel zestssh/passkeys.
class ChannelPasskeys implements PasskeyPlatform {
  ChannelPasskeys({MethodChannel channel = kPasskeyChannel}) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<Map<String, Object?>> create(Map<String, Object?> options) async {
    final challenge = challengeOf(options);
    final answer = await _ceremony('create', creationOptionsForPlatform(options));
    return registrationResponseOf(answer, challenge: challenge);
  }

  @override
  Future<Map<String, Object?>> get(Map<String, Object?> options) async {
    final challenge = challengeOf(options);
    final answer = await _ceremony('get', requestOptionsForPlatform(options));
    return authenticationResponseOf(answer, challenge: challenge);
  }

  /// Runs [method] with [options] as JSON text; the system's response JSON,
  /// as text. Throws [PasskeyCancelled] or [PasskeyError] for what the native
  /// side answered.
  Future<String> _ceremony(String method, Map<String, Object?> options) async {
    final Object? answer;
    try {
      answer = await _channel.invokeMethod<Object?>(method, {'options': jsonEncode(options)});
    } on PlatformException catch (e) {
      throw passkeyFailureOf(e.code, e.message);
    } on MissingPluginException {
      throw const PasskeyError('unsupported', 'no zestssh/passkeys channel');
    }
    if (answer is! String || answer.isEmpty) throw const PasskeyError('failed', 'response: none');
    return answer;
  }
}

/// What a native side's failure [code] (and its [message]) means: a
/// [PasskeyCancelled] for 'cancelled', else a [PasskeyError] of that code (of
/// those a screen is written for; 'failed' for any other, the code kept in
/// the detail).
Exception passkeyFailureOf(String code, String? message) {
  if (code == 'cancelled') return const PasskeyCancelled();
  final said = message == null || message.isEmpty
      ? null
      : (message.length > _maxDetail ? message.substring(0, _maxDetail) : message);
  if (_knownCodes.contains(code)) return PasskeyError(code, said);
  return PasskeyError('failed', said == null ? code : '$code: $said');
}
