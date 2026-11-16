import 'dart:async';

import 'package:zestssh/services/account/two_step.dart' show passkeysHere;
import 'package:zestssh/services/account/two_step_api.dart';
import 'package:zestssh/services/away_for_sign_in.dart';
import 'package:zestssh/services/passkeys/passkey_platform.dart';

// "Confirm it's you" with a passkey (from a security review):
// a tap on a device that is signed in, instead of a whole sign-in, for what asks
// for a recent one. ZestSSH Cloud checks it (routes/passkeys.js, step-up) and
// notes the time on this device's session; the device has to verify the person.

/// Confirming with a passkey on this device. A test puts its own.
class PasskeyStepUp {
  PasskeyStepUp({
    required TwoStepApi Function() api,
    required PasskeyPlatform platform,
    Future<void> Function(DateTime at)? remember,
    Duration askFor = const Duration(seconds: 4),
  })  : _api = api,
        _platform = platform,
        _remember = remember,
        _askFor = askFor;

  final TwoStepApi Function() _api;
  final PasskeyPlatform _platform;
  final Future<void> Function(DateTime at)? _remember;
  final Duration _askFor;

  /// What the account has, for the dialog about to open: null where it could not
  /// be told in a moment (it offers the sign-in, as it always did: the dialog
  /// does not wait for a server that is slow to answer, and a backend that is
  /// down keeps no one from anything here).
  Future<TwoStepState?> _state() async {
    try {
      return await _api().state().timeout(_askFor);
    } catch (_) {
      return null;
    }
  }

  /// Whether a passkey can confirm it is the person here: this device uses
  /// passkeys itself, and the account has some.
  Future<bool> available() async {
    if (!await passkeysHere(_platform)) return false;
    final state = await _state();
    return state != null && state.passkeysAvailable && state.passkeys > 0;
  }

  /// Whether a passkey would make this quicker for an account with none (the
  /// offer after a sign-in that "Confirm it's you" asked for).
  Future<bool> worthOffering() async {
    final state = await _state();
    return state != null && state.passkeysAvailable && state.passkeys == 0;
  }

  /// Confirms with this device's passkey. Throws what [TwoStepApi] and the
  /// device's ceremony throw.
  Future<void> confirm() async {
    final api = _api();
    final options = await api.stepUpOptions();
    // A system's dialog on a phone leaves the app for a moment: no reason to
    // lock it behind the person (from a security review).
    final response = await AwayForSignIn.during(() => _platform.get(options));
    final at = await api.stepUpVerify(response);
    await _remember?.call(at ?? DateTime.now());
  }
}
