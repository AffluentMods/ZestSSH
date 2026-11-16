import 'dart:isolate';

import 'package:zestssh/services/passkeys/passkey_json.dart';
import 'package:zestssh/services/passkeys/passkey_platform.dart';
import 'package:zestssh/services/passkeys/windows_webauthn.dart';

// Windows' passkey ceremonies behind the one interface (3.3; the two-step
// contract, section 4): ZestSSH Cloud's options in, read into what
// webauthn.dll is handed (windows_webauthn.dart); the system's dialog, on
// an isolate of its own so the app's window keeps drawing; the response the
// server reads out, with the clientDataJSON the app wrote.
//
// How a failure comes out (windowsFailureOf):
//   PasskeyCancelled          the person cancelled, or the dialog closed or
//                             timed out (NTE_USER_CANCELLED, ERROR_CANCELLED,
//                             ERROR_TIMEOUT)
//   PasskeyError code:
//     invalid-state   this authenticator holds one of the account's passkeys
//                     already (NTE_EXISTS)
//     no-credential   signing in: no passkey of the account answered
//                     (NTE_NOT_FOUND, NTE_DEVICE_NOT_FOUND)
//     unsupported     webauthn.dll is not there (Windows 10 before 1903), or
//                     nothing here can do what was asked (NotSupportedError,
//                     ConstraintError: no algorithm in common, a full key)
//     security        the options named a site other than zestssh.com
//     failed          anything else; the detail is the HRESULT and its name

/// What [WindowsPasskeys] asks of webauthn.dll: the system's, or a fake in
/// tests.
abstract interface class WindowsWebAuthn {
  /// The DLL's API version; 0 where it is not there.
  int apiVersion();

  /// Whether Windows Hello can make and use passkeys here.
  Future<bool> platformAuthenticator();

  /// The window the dialog belongs to; 0 where there is none.
  int windowHandle();

  /// Makes a passkey for [c] in the dialog of [hwnd].
  Future<WinOutcome> makeCredential(WinCreation c, int hwnd);

  /// Uses a passkey for [r] in the dialog of [hwnd].
  Future<WinOutcome> getAssertion(WinAssertionRequest r, int hwnd);
}

/// webauthn.dll itself; each ceremony on an isolate of its own.
class SystemWebAuthn implements WindowsWebAuthn {
  SystemWebAuthn();

  WebAuthnDll? _dll;
  bool _opened = false;

  WebAuthnDll? get _here {
    if (!_opened) {
      _opened = true;
      _dll = WebAuthnDll.open();
    }
    return _dll;
  }

  @override
  int apiVersion() => _here?.apiVersion() ?? 0;

  @override
  Future<bool> platformAuthenticator() => _platformAuthenticatorApart();

  @override
  int windowHandle() => appWindowHandle();

  @override
  Future<WinOutcome> makeCredential(WinCreation c, int hwnd) => _makeCredentialApart(c, hwnd);

  @override
  Future<WinOutcome> getAssertion(WinAssertionRequest r, int hwnd) => _getAssertionApart(r, hwnd);
}

// Top-level, so that each closure holds only what it is handed (an isolate
// takes nothing else with it).
Future<bool> _platformAuthenticatorApart() =>
    Isolate.run(() => WebAuthnDll.open()?.platformAuthenticatorAvailable() ?? false);

Future<WinOutcome> _makeCredentialApart(WinCreation c, int hwnd) => Isolate.run(() => makeCredentialBlocking(c, hwnd));

Future<WinOutcome> _getAssertionApart(WinAssertionRequest r, int hwnd) =>
    Isolate.run(() => getAssertionBlocking(r, hwnd));

/// Windows' passkey ceremonies: Windows Hello, security keys and phones, in
/// the system's own dialog.
class WindowsPasskeys implements PasskeyPlatform {
  WindowsPasskeys({
    WindowsWebAuthn? webAuthn,
    String? rpId,
    String? origin,
  })  : _webAuthn = webAuthn ?? SystemWebAuthn(),
        rpId = rpId ?? kWindowsPasskeyRpId,
        origin = origin ?? kWindowsPasskeyOrigin;

  final WindowsWebAuthn _webAuthn;

  /// The only RP ID passkeys are made and used for, and the origin written
  /// for it.
  final String rpId;
  final String origin;

  /// A ceremony is open: the system shows one dialog at a time.
  bool _busy = false;

  @override
  Future<bool> isAvailable() async => _webAuthn.apiVersion() >= 1;

  /// Whether Windows Hello itself can make and use passkeys here (a security
  /// key or a phone can wherever [isAvailable] is true): for the words a
  /// screen chooses, never to hide the way.
  Future<bool> hasWindowsHello() async => _webAuthn.apiVersion() >= 1 && await _webAuthn.platformAuthenticator();

  @override
  Future<Map<String, Object?>> create(Map<String, Object?> options) async {
    if (_webAuthn.apiVersion() < 1) throw const PasskeyError('unsupported', 'no webauthn.dll');
    final creation = winCreationOf(options, rpId: rpId, origin: origin);
    final outcome = await _once((hwnd) => _webAuthn.makeCredential(creation, hwnd));
    final made = _result(outcome, signIn: false).registration!;
    return registrationResponseOf(
      registrationJsonOf(made, creation.clientData, credProps: creation.credProps),
      challenge: creation.challenge,
    );
  }

  @override
  Future<Map<String, Object?>> get(Map<String, Object?> options) async {
    if (_webAuthn.apiVersion() < 1) throw const PasskeyError('unsupported', 'no webauthn.dll');
    final request = winAssertionRequestOf(options, rpId: rpId, origin: origin);
    final outcome = await _once((hwnd) => _webAuthn.getAssertion(request, hwnd));
    final used = _result(outcome, signIn: true).assertion!;
    return authenticationResponseOf(authenticationJsonOf(used, request.clientData), challenge: request.challenge);
  }

  /// Runs one ceremony with the app's window; one at a time.
  Future<WinOutcome> _once(Future<WinOutcome> Function(int hwnd) ceremony) async {
    if (_busy) throw const PasskeyError('failed', 'another passkey dialog is open');
    final hwnd = _webAuthn.windowHandle();
    if (hwnd == 0) throw const PasskeyError('failed', 'no app window for the dialog');
    _busy = true;
    try {
      return await ceremony(hwnd);
    } finally {
      _busy = false;
    }
  }

  /// [outcome] where it made or used a passkey; throws what it means
  /// otherwise.
  WinOutcome _result(WinOutcome outcome, {required bool signIn}) {
    if (outcome.unavailable) throw const PasskeyError('unsupported', 'no webauthn.dll');
    if (outcome.broken != null) throw PasskeyError('failed', 'webauthn.dll: ${outcome.broken}');
    if (outcome.hr != 0) throw windowsFailureOf(outcome.hr, outcome.errorName, signIn: signIn);
    if (signIn ? outcome.assertion == null : outcome.registration == null) {
      throw const PasskeyError('failed', 'webauthn.dll: nothing came back');
    }
    return outcome;
  }
}
