import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account/two_step_api.dart';
import 'package:zestssh/services/passkeys/passkey_platform.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/utils/type_name.dart';

// Two-step sign-in (3.0; passkeys since 3.3, the two-step
// contract): a second step at every sign-in, the authenticator app or a
// passkey. The authenticator is Firebase Authentication's authenticator-app
// (TOTP) factor, so ZestSSH Cloud never sees its secret. A passkey is
// answered through the bridge: a second TOTP factor named 'Passkey' that
// ZestSSH Cloud holds for an account with passkeys, whose code it releases
// for one sign-in after a passkey of the account signed its challenge.
// Factors are told apart by their names, never by their place in the list.
// What ZestSSH Cloud keeps besides is the account's recovery codes, the way
// back for a person who lost their second step.
//
// Phones and tablets sign in with Firebase and run the second step here,
// passkeys included. Windows, Linux and the Mac (whose build has no Firebase
// configuration) sign in through the browser, where zestssh.com runs it.
//
// One or the other: Firebase holds one TOTP
// factor per account, and the bridge is one, so an account uses passkeys or
// the authenticator app, with its backup codes either way. A passkey in the
// place of the authenticator is ZestSSH Cloud's to do in one request
// (replace_authenticator). The authenticator in the place of the passkeys is
// set up here ([beginInPlaceOfPasskeys], [finishInPlaceOfPasskeys]): begun
// with Firebase while the passkeys are still there, the code checked against
// its secret here first, and only then do the passkeys go, just before
// Firebase finishes. Where Firebase will not begin while the account is full,
// the person agrees first that two-step sign-in is off until they finish.

/// Where a computer sets the authenticator app up.
String get kTwoStepWebPage => zestUnder(kZestWebsite, '/account/security');

/// The name the authenticator carries on the account. Firebase keeps it and
/// every device shows it, so it is one fixed name, not translated copy.
const kAuthenticatorFactorName = 'Authenticator app';

/// The name of the bridge ZestSSH Cloud holds for an account with passkeys.
/// It is answered only by the passkey step: never offered as "enter a
/// code", never removed here, never shown as a factor of its own.
const kBridgeFactorName = 'Passkey';

/// Firebase's id for an authenticator-app factor (the bridge is one too).
const kAuthenticatorFactorId = 'totp';

/// The issuer an authenticator app files the account under.
const kAuthenticatorIssuer = 'ZestSSH';

class RecoveryCodesException implements Exception, HasTypeName {
  const RecoveryCodesException(this.status, [this.code]);

  final int status;
  final String? code;

  /// The server wants a sign-in from the last few minutes first.
  bool get needsRecentSignIn => code == 'recent-sign-in-required';

  /// No second step is set up, so there is nothing to make codes for.
  bool get twoStepOff => code == 'two-step-off';

  /// The recovery code, or the address it was used with, did not match.
  bool get invalidCode =>
      code == 'recovery-code-invalid' || code == 'recovery-input';

  bool get tooManyAttempts => status == 429;

  @override
  String toString() => 'Backup codes: HTTP $status ${code ?? ''}'.trim();

  @override
  String get typeName => 'RecoveryCodesException';
}

/// Two-step sign-in as a server before 3.3 says it (its recovery codes
/// route).
class TwoStepStatus {
  const TwoStepStatus({required this.on, required this.recoveryCodes});

  /// Whether an authenticator is set up; null when the sign-in service could
  /// not be reached.
  final bool? on;

  /// How many recovery codes the account holds.
  final int recoveryCodes;
}

/// The recovery code endpoints on ZestSSH Cloud (always the hosted server,
/// whatever sync backend is in use).
class RecoveryCodesApi {
  RecoveryCodesApi({http.Client? client, String? baseUrl, this.bearer})
      : _client = client ?? PinnedHttpClient.client,
        _base = baseUrl ?? _defaultBase;

  static String get _defaultBase => kZestApiBase;

  static const _timeout = Duration(seconds: 30);

  final http.Client _client;
  final String _base;

  /// The account's bearer: the Firebase ID token when signed in with
  /// Firebase, else the session token. Not needed by [recover].
  final Future<String?> Function()? bearer;

  Future<Map<String, String>> _headers() async {
    final token = bearer == null ? null : await bearer!();
    if (token == null) throw const RecoveryCodesException(401, 'signed-out');
    return {'Authorization': 'Bearer $token', ...DeviceSessionHeader.headers};
  }

  Future<http.Response> _send(
      Future<http.Response> Function(Map<String, String> headers) send) async {
    final response = await send(await _headers()).timeout(_timeout);
    reportIfSessionRevoked(response);
    return response;
  }

  static RecoveryCodesException _error(http.Response r) =>
      RecoveryCodesException(r.statusCode, _decode(r.body)['code'] as String?);

  Uri get _codesUrl => Uri.parse('$_base/account/recovery-codes');

  /// Whether two-step sign-in is on and how many codes remain.
  Future<TwoStepStatus> status() async {
    final r = await _send((h) => _client.get(_codesUrl, headers: h));
    if (r.statusCode != 200) throw _error(r);
    final body = _decode(r.body);
    final on = body['two_step'];
    final count = body['count'];
    return TwoStepStatus(
      on: on is bool ? on : null,
      recoveryCodes: count is int ? count : 0,
    );
  }

  /// Ten new codes, replacing any the account had. They are shown this once:
  /// ZestSSH Cloud keeps only keyed hashes of them. Needs a recent sign-in
  /// with the second step, and a second step already set up.
  Future<List<String>> make() async {
    final r = await _send((h) => _client.post(_codesUrl, headers: h));
    final codes = _decode(r.body)['codes'];
    if (r.statusCode != 201 || codes is! List) throw _error(r);
    return [for (final c in codes) if (c is String) c];
  }

  /// Forgets the account's codes. Needs a recent sign-in.
  Future<void> forget() async {
    final r = await _send((h) => _client.delete(_codesUrl, headers: h));
    if (r.statusCode != 200) throw _error(r);
  }

  /// Uses a recovery code: two-step sign-in is turned off for the account at
  /// [email], every code goes with it, and the address is told. Returns
  /// whether that notice was sent. Needs no sign-in.
  Future<bool> recover({required String email, required String code}) async {
    final r = await _client
        .post(
          Uri.parse('$_base/auth/two-step/recover'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'email': email, 'code': code}),
        )
        .timeout(_timeout);
    if (r.statusCode != 200) throw _error(r);
    return _decode(r.body)['notified'] == true;
  }
}

Map<String, dynamic> _decode(String body) {
  try {
    final decoded = jsonDecode(body);
    return decoded is Map<String, dynamic> ? decoded : const {};
  } catch (_) {
    return const {};
  }
}

// ── The second step at sign-in ──────────────────────────────────────────

/// The factors of a sign-in's hints that ZestSSH answers, by their names
/// (the contract, section 1): the authenticator app (a six-digit code) and
/// the bridge (a passkey). Null where the account has none of that kind; a
/// factor of any other name or kind is a second step ZestSSH does not offer.
({MultiFactorInfo? authenticator, MultiFactorInfo? passkey}) chooseSecondFactors(List<MultiFactorInfo> hints) {
  MultiFactorInfo? named(String name) {
    for (final hint in hints) {
      if (hint.factorId == kAuthenticatorFactorId && hint.displayName == name && hint.uid.isNotEmpty) return hint;
    }
    return null;
  }

  return (authenticator: named(kAuthenticatorFactorName), passkey: named(kBridgeFactorName));
}

/// Why the person is asked again.
enum SecondStepError {
  /// The authenticator code was wrong or expired.
  wrongCode,

  /// Too many tries: wait a while.
  tooManyAttempts,

  /// The recovery code, or the address, did not match.
  recoveryCodeInvalid,

  /// The service could not be reached.
  unavailable,
}

/// Why a passkey did not finish the sign-in: ZestSSH Cloud's [code]
/// ('passkey-failed', 'passkey-cloned', 'passkey-paused', 'rate-limited',
/// 'two-step-unavailable', 'passkeys-unavailable'), or one of the device's:
/// 'cancelled' (the person closed the system's dialog: no error), 'device'
/// (the system could not, [deviceCode] says why), 'network' (nothing
/// answered: [cause] says more), 'unknown'.
class PasskeyStepFailure {
  const PasskeyStepFailure(this.code, {this.retryAfter, this.deviceCode, this.cause});

  /// What [error] means for the passkey step, or null for an error that
  /// ends the sign-in (it is rethrown).
  static PasskeyStepFailure? of(Object error) {
    if (error is PasskeyCancelled) return const PasskeyStepFailure('cancelled');
    if (error is PasskeyError) return PasskeyStepFailure('device', deviceCode: error.code, cause: error);
    if (error is TwoStepRefusal) {
      return PasskeyStepFailure(error.code ?? 'unknown', retryAfter: error.retryAfter, cause: error);
    }
    if (error is FirebaseAuthException) {
      return switch (error.code) {
        // The bridge's code reached Firebase too late, or was taken: one
        // more try fetches a new one.
        'invalid-verification-code' || 'code-expired' || 'invalid-code' => PasskeyStepFailure('passkey-failed', cause: error),
        'too-many-requests' => PasskeyStepFailure('rate-limited', cause: error),
        'network-request-failed' => PasskeyStepFailure('network', cause: error),
        _ => null,
      };
    }
    if (error is SocketException || error is TimeoutException || error is http.ClientException) {
      return PasskeyStepFailure('network', cause: error);
    }
    if (error is FormatException || error is TypeError) return PasskeyStepFailure('unknown', cause: error);
    return null;
  }

  final String code;
  final Duration? retryAfter;

  /// The device's own reason, for [code] 'device' (PasskeyError.code).
  final String? deviceCode;

  /// What was caught, for Copy details and for how ZestSSH Cloud stands.
  final Object? cause;

  /// The person closed the dialog: they try again or choose another way.
  bool get quiet => code == 'cancelled';

  /// What a person can quote to support.
  String get shownCode => switch (code) {
        'device' => 'passkey-device-${deviceCode ?? 'failed'}',
        'network' || 'unknown' || 'cancelled' => '',
        _ => code,
      };
}

/// What a sign-in that needs its second step asks the person.
class SecondStepChallenge {
  const SecondStepChallenge({
    this.email,
    this.error,
    this.cause,
    this.authenticator = true,
    this.passkey = false,
    this.passkeyElsewhere = false,
    this.passkeyFailure,
  });

  /// The account's address, to fill in when a recovery code is used.
  final String? email;

  /// Why they are asked again, or null the first time.
  final SecondStepError? error;

  /// What was caught, where [error] is [SecondStepError.unavailable] because
  /// a recovery code could not be used: ZestSSH Cloud checks those, so how
  /// it stands is what there is to say then (cloudStopped). Null where it
  /// was the sign-in service's own code that could not be checked.
  final Object? cause;

  /// Whether the account has the authenticator app: a code is asked for.
  final bool authenticator;

  /// Whether the account has passkeys and this device can use them.
  final bool passkey;

  /// Whether the account has passkeys that this device cannot use (an
  /// older system, or ZestSSH Cloud has them off).
  final bool passkeyElsewhere;

  /// Why the last passkey did not finish the sign-in, or null.
  final PasskeyStepFailure? passkeyFailure;
}

/// What the person answers.
sealed class SecondStepAnswer {
  const SecondStepAnswer();
}

/// The six-digit code their authenticator shows now.
final class AuthenticatorCodeAnswer extends SecondStepAnswer {
  const AuthenticatorCodeAnswer(this.code);

  final String code;
}

/// One of their passkeys, on this device, a phone or a security key.
final class PasskeyAnswer extends SecondStepAnswer {
  const PasskeyAnswer();
}

/// One of their recovery codes, with the address they sign in with.
final class RecoveryCodeAnswer extends SecondStepAnswer {
  const RecoveryCodeAnswer({required this.email, required this.code});

  final String email;
  final String code;
}

/// They have no second step left and no recovery code: the sign-in ends,
/// and they ask to recover the account instead (lock-out recovery).
final class LockedOutAnswer extends SecondStepAnswer {
  const LockedOutAnswer({this.email});

  final String? email;
}

/// Asks the person for their second step; null when they back out.
typedef SecondStepPrompt = Future<SecondStepAnswer?> Function(
    SecondStepChallenge challenge);

/// A recovery code turned two-step sign-in off, but repeating the sign-in
/// did not go through (an Apple sign-in cannot be reused): the person signs
/// in again, now without the second step.
class TwoStepTurnedOff implements Exception, HasTypeName {
  const TwoStepTurnedOff();

  @override
  String toString() => 'Two-step sign-in was turned off; sign in again';

  @override
  String get typeName => 'TwoStepTurnedOff';
}

/// The account has a second factor ZestSSH does not offer (a text message
/// factor added outside the app), so the sign-in cannot finish here.
class UnsupportedSecondStep implements Exception, HasTypeName {
  const UnsupportedSecondStep();

  @override
  String toString() => 'This account uses a second step ZestSSH does not offer';

  @override
  String get typeName => 'UnsupportedSecondStep';
}

/// The second step of a sign-in, kept apart from Firebase so it can be
/// tested: ask, check the code or the passkey, ask again when it did not
/// work; or use a recovery code, which turns two-step sign-in off, and
/// repeat the sign-in.
class SecondStepFlow<T> {
  SecondStepFlow({
    required this.prompt,
    required this.withCode,
    required this.recover,
    required this.retry,
    this.withPasskey,
    this.email,
    this.authenticator = true,
    this.passkeyElsewhere = false,
  });

  final SecondStepPrompt prompt;

  /// Finishes the sign-in with an authenticator code. Throws a
  /// [FirebaseAuthException] when the code is refused. Null where the
  /// account has no authenticator app.
  final Future<T> Function(String code)? withCode;

  /// Finishes the sign-in with a passkey ([runPasskeyStep]); null where the
  /// account has none, or this device cannot use them.
  final Future<T> Function()? withPasskey;

  /// Uses a recovery code ([RecoveryCodesApi.recover]).
  final Future<void> Function(String email, String code) recover;

  /// Repeats the first step once two-step sign-in is off.
  final Future<T> Function() retry;

  final String? email;

  /// Whether the account has the authenticator app.
  final bool authenticator;

  /// Whether the account has passkeys this device cannot use.
  final bool passkeyElsewhere;

  /// The finished sign-in, or null when the person backs out.
  Future<T?> run() async {
    SecondStepError? error;
    Object? cause;
    PasskeyStepFailure? passkeyFailure;
    var email = this.email;
    var passkey = withPasskey != null;
    var passkeyElsewhere = this.passkeyElsewhere;
    while (true) {
      final answer = await prompt(SecondStepChallenge(
        email: email,
        error: error,
        cause: cause,
        authenticator: authenticator && withCode != null,
        passkey: passkey,
        passkeyElsewhere: passkeyElsewhere,
        passkeyFailure: passkeyFailure,
      ));
      cause = null;
      passkeyFailure = null;
      switch (answer) {
        case null:
        case LockedOutAnswer():
          return null;
        case AuthenticatorCodeAnswer(:final code):
          final finish = withCode;
          if (finish == null) continue;
          try {
            return await finish(code.trim());
          } on FirebaseAuthException catch (e) {
            error = codeError(e);
            if (error == null) rethrow;
          }
        case PasskeyAnswer():
          final finish = withPasskey;
          if (finish == null || !passkey) continue;
          error = null;
          try {
            return await finish();
          } catch (e) {
            final failure = PasskeyStepFailure.of(e);
            if (failure == null) rethrow;
            passkeyFailure = failure;
            // ZestSSH Cloud has passkeys off: not offered again here.
            if (failure.code == 'passkeys-unavailable') {
              passkey = false;
              passkeyElsewhere = true;
            }
          }
        case RecoveryCodeAnswer(email: final address, :final code):
          email = address;
          try {
            await recover(address.trim(), code.trim());
          } on RecoveryCodesException catch (e) {
            error = e.tooManyAttempts
                ? SecondStepError.tooManyAttempts
                : e.invalidCode
                    ? SecondStepError.recoveryCodeInvalid
                    : SecondStepError.unavailable;
            if (error == SecondStepError.unavailable) cause = e;
            continue;
          } on Exception catch (e) {
            error = SecondStepError.unavailable;
            cause = e;
            continue;
          }
          try {
            return await retry();
          } on Exception {
            throw const TwoStepTurnedOff();
          }
      }
    }
  }

  /// How a refused authenticator code is told to the person, or null for an
  /// error that ends the sign-in (it is rethrown).
  static SecondStepError? codeError(FirebaseAuthException e) =>
      switch (e.code) {
        'invalid-verification-code' ||
        'invalid-code' ||
        'missing-code' ||
        'code-expired' =>
          SecondStepError.wrongCode,
        'too-many-requests' => SecondStepError.tooManyAttempts,
        'network-request-failed' => SecondStepError.unavailable,
        _ => null,
      };
}

/// The passkey step of a sign-in (the contract, sections 3.4 and 7.10):
/// ZestSSH Cloud's challenge for the account whose bridge [enrollmentId] is,
/// the device's passkey, ZestSSH Cloud's check, and the bridge's code for
/// this one sign-in handed straight to [finish] (Firebase). The code is
/// never kept, shown or logged. Throws what each step throws: a
/// [TwoStepRefusal], [PasskeyCancelled], a [PasskeyError], Firebase's.
Future<T> runPasskeyStep<T>({
  required TwoStepApi api,
  required PasskeyPlatform platform,
  required String enrollmentId,
  String? email,
  required Future<T> Function(String enrollmentId, String code) finish,
}) async {
  final options = await api.passkeyChallenge(enrollmentId: enrollmentId, email: email);
  final response = await platform.get(options);
  final released = await api.passkeyVerify(response: response, email: email);
  return finish(released.enrollmentId, released.code);
}

/// What the passkey step at sign-in uses: this device's passkeys and
/// ZestSSH Cloud. The app puts the device's own in when it starts
/// (passkeyPlatformProvider); before that, and in a test, there are none.
abstract final class SecondStepPasskeys {
  static PasskeyPlatform platform = const NoPasskeys();
  static TwoStepApi Function() api = TwoStepApi.new;
}

/// Whether [platform] makes and uses passkeys on this device; false where it
/// cannot say.
Future<bool> passkeysHere(PasskeyPlatform platform) async {
  try {
    return await platform.isAvailable();
  } catch (_) {
    return false;
  }
}

/// Runs [firstStep] (a sign-in or a confirming sign-in). When the account has
/// two-step sign-in, asks for the second step with [secondStep] and finishes:
/// with the authenticator's code, a passkey, or a recovery code. Returns null
/// when the person backs out of the second step. Without a [secondStep] the
/// Firebase exception is rethrown.
Future<UserCredential?> signInWithSecondStep(
  Future<UserCredential> Function() firstStep, {
  required SecondStepPrompt? secondStep,
  String? email,
  RecoveryCodesApi? api,
  TwoStepApi? twoStepApi,
  PasskeyPlatform? passkeys,
}) async {
  try {
    return await firstStep();
  } on FirebaseAuthMultiFactorException catch (e) {
    if (secondStep == null) rethrow;
    final resolver = e.resolver;
    final (:authenticator, :passkey) = chooseSecondFactors(resolver.hints);
    if (authenticator == null && passkey == null) throw const UnsupportedSecondStep();
    final platform = passkeys ?? SecondStepPasskeys.platform;
    final cloud = twoStepApi ?? SecondStepPasskeys.api();
    final recoveryApi = api ?? RecoveryCodesApi();
    final address = email ?? e.email;
    // The passkey step, where the account has passkeys and this device can
    // use them: ZestSSH Cloud's challenge for the bridge, the device's
    // passkey, and the bridge's code straight to Firebase.
    Future<UserCredential> Function()? withPasskey;
    if (passkey != null && await passkeysHere(platform)) {
      withPasskey = () => runPasskeyStep<UserCredential>(
            api: cloud,
            platform: platform,
            enrollmentId: passkey.uid,
            email: address,
            finish: (enrollmentId, code) async =>
                resolver.resolveSignIn(await TotpMultiFactorGenerator.getAssertionForSignIn(enrollmentId, code)),
          );
    }
    return SecondStepFlow<UserCredential>(
      prompt: secondStep,
      email: address,
      authenticator: authenticator != null,
      passkeyElsewhere: passkey != null && withPasskey == null,
      withCode: authenticator == null
          ? null
          : (code) async {
              final assertion = await TotpMultiFactorGenerator.getAssertionForSignIn(authenticator.uid, code);
              return resolver.resolveSignIn(assertion);
            },
      withPasskey: withPasskey,
      recover: (address, code) =>
          recoveryApi.recover(email: address, code: code),
      retry: firstStep,
    ).run();
  }
}

// ── Setting it up (Firebase platforms) ──────────────────────────────────

/// An authenticator being set up: the secret Firebase made for it, and the
/// otpauth link an authenticator app reads from the QR code.
class AuthenticatorSetup {
  AuthenticatorSetup({
    required this.qrUrl,
    required this.key,
    this.deadline,
    this.period = 30,
    this.digits = 6,
    this.algorithm = 'SHA1',
    Future<void> Function()? openInApp,
    TotpSecret? secret,
  })  : _openInApp = openInApp,
        _secret = secret;

  /// The seconds a code lasts, how many digits it has and the hash it is
  /// made with, as Firebase made the secret.
  final int period;
  final int digits;
  final String algorithm;

  /// Whether [code] is what an authenticator app shows for this secret at
  /// [now] (or one step either side, a clock a little off), as Firebase takes
  /// it: checked here before anything is changed for it.
  bool codeMatches(String code, {DateTime? now}) =>
      totpMatches(key, code, now: now ?? DateTime.now(), period: period, digits: digits, algorithm: algorithm);

  /// Firebase's secret; null only in tests.
  final TotpSecret? _secret;
  final Future<void> Function()? _openInApp;

  /// The otpauth:// link the QR code carries.
  final String qrUrl;

  /// The key to type into an authenticator app that cannot scan.
  final String key;

  /// When Firebase stops accepting the setup, if it says.
  final DateTime? deadline;

  /// Opens the link in the device's authenticator or password manager.
  Future<void> openInApp() async {
    final open = _openInApp;
    if (open != null) return open();
    await _secret?.openInOtpApp(qrUrl);
  }
}

bool _isAuthenticator(MultiFactorInfo f) =>
    f.factorId == kAuthenticatorFactorId && f.displayName == kAuthenticatorFactorName;

/// Setting the authenticator app up with Firebase on this device (a phone or
/// a tablet): [TwoStepAccount], or a test's.
abstract interface class AuthenticatorEnroller {
  /// Begins it: Firebase makes a secret. Wants a recent sign-in.
  Future<AuthenticatorSetup> start();

  /// Finishes it with the code the authenticator shows now. Throws a
  /// [FirebaseAuthException] when the code is refused.
  Future<void> finish(AuthenticatorSetup setup, String code);
}

/// Whether [e] is Firebase refusing a TOTP factor the account has no room
/// for: it holds one already (the bridge of its passkeys, or the app).
bool isSecondFactorLimit(Object e) =>
    e is FirebaseAuthException &&
    (e.code == 'maximum-second-factor-count-exceeded' ||
        e.code == 'second-factor-limit-exceeded' ||
        e.code == 'second-factor-count-exceeded');

/// A failure after the passkeys went for the authenticator app, which was
/// not set up: two-step sign-in is off until it is. [cause]: what failed.
class PasskeysGoneFailure implements Exception, HasTypeName {
  const PasskeysGoneFailure(this.cause);

  final Object cause;

  @override
  String toString() => 'The passkeys were removed and the authenticator app was not set up ($cause)';

  @override
  String get typeName => 'PasskeysGoneFailure';
}

/// Begins setting the authenticator app up in the place of the account's
/// passkeys: the setup, and whether the passkeys went for it already; null
/// where the person kept them. [start] begins Firebase's enrolment while they
/// are still there. Where Firebase refuses that while the account is full,
/// [agreeGap] asks the person whether the passkeys may go first (two-step
/// sign-in off until they finish), and [removePasskeys] takes them away at
/// ZestSSH Cloud before it is begun again; a failure after that is a
/// [PasskeysGoneFailure].
Future<({AuthenticatorSetup setup, bool passkeysGone})?> beginInPlaceOfPasskeys({
  required Future<AuthenticatorSetup> Function() start,
  required Future<bool> Function() agreeGap,
  required Future<void> Function() removePasskeys,
}) async {
  try {
    return (setup: await start(), passkeysGone: false);
  } catch (e) {
    if (!isSecondFactorLimit(e)) rethrow;
  }
  if (!await agreeGap()) return null;
  await removePasskeys();
  try {
    return (setup: await start(), passkeysGone: true);
  } catch (e) {
    throw PasskeysGoneFailure(e);
  }
}

/// Finishes setting the authenticator app up in the place of the passkeys,
/// with the [code] the person typed. Where they are still there
/// ([passkeysGone] false), the code is checked first: a wrong one changes
/// nothing and is refused as Firebase refuses it; a right one, and the
/// passkeys go ([removePasskeys]) just before Firebase finishes ([enroll]).
Future<void> finishInPlaceOfPasskeys({
  required AuthenticatorSetup setup,
  required String code,
  required bool passkeysGone,
  required Future<void> Function() removePasskeys,
  required Future<void> Function(AuthenticatorSetup setup, String code) enroll,
  DateTime? now,
}) async {
  if (!passkeysGone) {
    if (!setup.codeMatches(code, now: now)) {
      // Refused as Firebase refuses a wrong code, so that it is said the same way.
      throw FirebaseAuthException(code: 'invalid-verification-code');
    }
    await removePasskeys();
  }
  await enroll(setup, code);
}

/// The signed-in Firebase account's authenticator app: setting one up with
/// Firebase, and what Firebase says of this device's sign-in. Whether
/// two-step sign-in is on is ZestSSH Cloud's to say ([TwoStepApi.state]),
/// and it turns it off and removes the authenticator itself.
class TwoStepAccount implements AuthenticatorEnroller {
  TwoStepAccount(this._user);

  final User _user;

  /// Whether the authenticator app is set up, by its name. Only for a server
  /// before 3.3 that could not ask Firebase: the bridge never counts.
  Future<bool> hasAuthenticator() async =>
      (await _user.multiFactor.getEnrolledFactors()).any(_isAuthenticator);

  /// Makes a new secret. Firebase wants a recent sign-in for the setup.
  @override
  Future<AuthenticatorSetup> start() async {
    final session = await _user.multiFactor.getSession();
    final secret = await TotpMultiFactorGenerator.generateSecret(session);
    final url = await secret.generateQrCodeUrl(
      accountName: _user.email ?? _user.uid,
      issuer: kAuthenticatorIssuer,
    );
    return AuthenticatorSetup(
      qrUrl: url,
      key: secret.secretKey,
      deadline: secret.enrollmentCompletionDeadline,
      period: secret.codeIntervalSeconds ?? 30,
      digits: secret.codeLength ?? 6,
      algorithm: secret.hashingAlgorithm ?? 'SHA1',
      secret: secret,
    );
  }

  /// Finishes the setup with the code the authenticator shows now. Throws a
  /// [FirebaseAuthException] when the code is refused. The caller tells
  /// ZestSSH Cloud at once ([TwoStepApi.changed]).
  @override
  Future<void> finish(AuthenticatorSetup setup, String code) async {
    final secret = setup._secret;
    if (secret == null) throw StateError('Not a Firebase authenticator setup');
    final assertion = await TotpMultiFactorGenerator.getAssertionForEnrollment(
        secret, code.trim());
    await _user.multiFactor
        .enroll(assertion, displayName: kAuthenticatorFactorName);
  }

  /// Removes the authenticator app with Firebase on this device: only where
  /// ZestSSH Cloud is from before 3.3 and cannot. The bridge, and any factor
  /// of another name, is never touched.
  Future<void> removeAuthenticatorHere() async {
    for (final f in await _user.multiFactor.getEnrolledFactors()) {
      if (_isAuthenticator(f)) await _user.multiFactor.unenroll(multiFactorInfo: f);
    }
  }

  /// Whether this device's sign-in passed the second step, as its newest ID
  /// token says. One made before the account's first second step was set up
  /// did not: it signs in again with the new one before anything else.
  Future<bool> passedSecondStep() async {
    final result = await _user.getIdTokenResult(true);
    final firebase = result.claims?['firebase'];
    return firebase is Map && firebase['sign_in_second_factor'] != null;
  }
}

/// A recovery code as it is typed, made tidy for showing back: lower case,
/// grouped five and five. Anything else is returned trimmed.
String formatRecoveryCode(String raw) {
  final compact = raw.toLowerCase().replaceAll(RegExp('[^0-9a-z]'), '');
  if (compact.length != 10) return raw.trim();
  return '${compact.substring(0, 5)}-${compact.substring(5)}';
}

// ── TOTP (RFC 6238), to check a code before anything changes ──────────

const _base32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// A base32 secret (as an authenticator app reads it) as bytes; null where
/// it is not one.
Uint8List? base32Bytes(String text) {
  final clean = text.toUpperCase().replaceAll(RegExp(r'[\s=-]'), '');
  if (clean.isEmpty || RegExp('[^A-Z2-7]').hasMatch(clean)) return null;
  final out = <int>[];
  var bits = 0;
  var value = 0;
  for (final ch in clean.split('')) {
    value = ((value << 5) | _base32.indexOf(ch)) & 0xffff;
    bits += 5;
    if (bits >= 8) {
      out.add((value >> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return Uint8List.fromList(out);
}

/// The code of [secret] for the time step [step]; null for a hash it does
/// not know.
String? totpCode(List<int> secret, int step, {int digits = 6, String algorithm = 'SHA1'}) {
  final hash = switch (algorithm.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '')) {
    'SHA1' => crypto.sha1,
    'SHA256' => crypto.sha256,
    'SHA512' => crypto.sha512,
    _ => null,
  };
  if (hash == null) return null;
  final counter = ByteData(8)..setUint64(0, step);
  final mac = crypto.Hmac(hash, secret).convert(counter.buffer.asUint8List()).bytes;
  final offset = mac.last & 0x0f;
  final binary = ((mac[offset] & 0x7f) << 24) | (mac[offset + 1] << 16) | (mac[offset + 2] << 8) | mac[offset + 3];
  var modulus = 1;
  for (var i = 0; i < digits; i++) {
    modulus *= 10;
  }
  return (binary % modulus).toString().padLeft(digits, '0');
}

/// Whether [code] is what an authenticator app shows for the base32
/// [secret] at [now], or one step either side, as Firebase takes it. False
/// for anything that cannot be checked.
bool totpMatches(String secret, String code,
    {required DateTime now, int period = 30, int digits = 6, String algorithm = 'SHA1'}) {
  final bytes = base32Bytes(secret);
  final length = digits > 0 ? digits : 6;
  final seconds = period > 0 ? period : 30;
  final typed = code.trim();
  if (bytes == null || !RegExp('^[0-9]{$length}\$').hasMatch(typed)) return false;
  final step = now.millisecondsSinceEpoch ~/ 1000 ~/ seconds;
  for (final s in [step - 1, step, step + 1]) {
    if (totpCode(bytes, s, digits: length, algorithm: algorithm) == typed) return true;
  }
  return false;
}

/// The authenticator key in groups of four, easier to type.
String groupKey(String key) {
  final buffer = StringBuffer();
  for (var i = 0; i < key.length; i += 4) {
    if (i > 0) buffer.write(' ');
    buffer.write(key.substring(i, i + 4 > key.length ? key.length : i + 4));
  }
  return buffer.toString();
}
