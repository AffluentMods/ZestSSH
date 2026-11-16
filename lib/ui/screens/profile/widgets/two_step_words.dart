import 'dart:io' show Platform;

import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuthException;
import 'package:intl/intl.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/account/browser_handoff.dart';
import 'package:zestssh/services/account/two_step.dart';
import 'package:zestssh/services/account/two_step_api.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/services/passkeys/passkey_platform.dart';

// What the two-step screens say (3.3): every refusal of ZestSSH Cloud, every
// passkey error of the device, in the person's words and with what to do,
// beside the code a support request quotes. One place, so the sign-in, the
// security section and the recovery say the same thing of the same thing.

/// What a person was doing when it went wrong.
enum TwoStepDoing {
  /// The passkey step of a sign-in.
  signIn,

  /// Adding a passkey.
  adding,

  /// Any other change (renaming, removing, turning off, a recovery).
  changing,
}

/// What went wrong, in words: [text] says what happened and what to do,
/// [code] is what a support request quotes ('' where there is none: the
/// person's own cancel), [quiet] where it is no error at all (they closed
/// the passkey window), [signInAgain] where this sign-in is too old for the
/// change or was ended.
class TwoStepProblem {
  const TwoStepProblem(this.text, {this.code = '', this.quiet = false, this.signInAgain = false});

  final String text;
  final String code;
  final bool quiet;
  final bool signInAgain;
}

/// [wait] in words ("a minute", "5 minutes", "an hour"), or [fallback]'s
/// where it is not known.
String waitWords(AppLocalizations l10n, Duration? wait, {Duration fallback = const Duration(minutes: 1)}) {
  final seconds = (wait == null || wait <= Duration.zero ? fallback : wait).inSeconds;
  if (seconds < 10) return l10n.waitFewSeconds;
  if (seconds < 90) return l10n.waitMinutes(1);
  if (seconds < 3600) return l10n.waitMinutes((seconds / 60).ceil());
  if (seconds < 5400) return l10n.waitHours(1);
  return l10n.waitHours((seconds / 3600).round());
}

/// The device's own passkey error (PasskeyError.code) in words.
String passkeyDeviceWords(AppLocalizations l10n, String? code, {required bool adding}) => switch (code) {
      'unsupported' => adding ? l10n.passkeyAddDeviceUnsupported : l10n.passkeyDeviceUnsupported,
      'no-credential' => l10n.passkeyDeviceNoCredential,
      'invalid-state' => adding ? l10n.passkeyExists : l10n.passkeyDeviceInvalidState,
      'security' => l10n.passkeyDeviceSecurity,
      _ => adding ? l10n.passkeyAddDeviceFailed : l10n.passkeyDeviceFailed,
    };

/// Why a passkey did not finish a sign-in ([PasskeyStepFailure]) in words.
TwoStepProblem passkeyStepProblem(AppLocalizations l10n, PasskeyStepFailure failure) {
  final code = failure.shownCode;
  return switch (failure.code) {
    'cancelled' => TwoStepProblem(l10n.passkeyCancelledNote, quiet: true),
    'device' => TwoStepProblem(passkeyDeviceWords(l10n, failure.deviceCode, adding: false), code: code),
    'network' => TwoStepProblem(
        (failure.cause == null ? null : cloudStopped(l10n, failure.cause!)) ?? l10n.twoStepErrorUnavailable),
    'unknown' => TwoStepProblem(l10n.passkeyErrorUnknown),
    _ => twoStepProblem(l10n, TwoStepRefusal(0, code: failure.code, retryAfter: failure.retryAfter),
        doing: TwoStepDoing.signIn),
  };
}

/// What [error] means for the person, from a two-step, passkey, recovery or
/// hand-off route, the device's passkeys, Firebase or the way to ZestSSH
/// Cloud.
TwoStepProblem twoStepProblem(AppLocalizations l10n, Object error, {TwoStepDoing doing = TwoStepDoing.changing}) {
  final adding = doing == TwoStepDoing.adding;
  if (error is PasskeyCancelled) {
    return TwoStepProblem(adding ? l10n.passkeyAddCancelled : l10n.passkeyCancelledNote, quiet: true);
  }
  if (error is PasskeyError) {
    return TwoStepProblem(passkeyDeviceWords(l10n, error.code, adding: adding), code: 'passkey-device-${error.code}');
  }
  if (error is HandoffWrongAccount) return TwoStepProblem(l10n.handoffWrongAccount, code: 'account-mismatch');
  // One or the other: the passkeys went for the authenticator app, which was
  // not set up.
  if (error is PasskeysGoneFailure) return TwoStepProblem(l10n.twoStepLeftOff, code: ErrorCodes.twoStepLeftOff.code);
  if (error is FirebaseAuthException) {
    final code = 'auth/${error.code}';
    return switch (error.code) {
      'requires-recent-login' || 'user-token-expired' || 'invalid-user-token' =>
        TwoStepProblem(l10n.twoStepNeedsSignIn, code: code, signInAgain: true),
      'too-many-requests' => TwoStepProblem(l10n.twoStepErrorTooMany, code: code),
      'network-request-failed' => TwoStepProblem(cloudStopped(l10n, error) ?? l10n.twoStepErrorUnavailable, code: code),
      'second-factor-already-in-use' => TwoStepProblem(l10n.twoStepAuthenticatorThere, code: code),
      // Firebase holds one TOTP factor per account: one or the other.
      'maximum-second-factor-count-exceeded' ||
      'second-factor-limit-exceeded' =>
        TwoStepProblem(l10n.twoStepTooManySteps, code: '${ErrorCodes.twoStepOtherKind.code} ($code)'),
      'unsupported-first-factor' => TwoStepProblem(l10n.twoStepUnsupportedFirstFactor, code: code),
      _ => TwoStepProblem(l10n.twoStepErrorGeneric, code: code),
    };
  }
  if (error is TwoStepRefusal) {
    final code = error.shownCode;
    TwoStepProblem said(String text, {bool signInAgain = false}) =>
        TwoStepProblem(text, code: code, signInAgain: signInAgain);
    switch (error.code) {
      // The passkey step of a sign-in.
      case 'passkey-failed':
        return said(l10n.passkeyErrorFailed);
      case 'passkey-cloned':
        return said(l10n.passkeyErrorCloned);
      case 'passkey-paused':
        return said(l10n.passkeyErrorPaused(waitWords(l10n, error.retryAfter, fallback: const Duration(hours: 1))));
      case 'rate-limited':
        return said(l10n.passkeyErrorRateLimited(waitWords(l10n, error.retryAfter)));
      case 'two-step-unavailable':
        return said(l10n.passkeyErrorServer);
      case 'passkeys-unavailable':
        return said(adding ? l10n.passkeyAddOff : l10n.passkeyErrorOff);
      // The account's passkeys and two-step sign-in.
      case 'too-many-passkeys':
        return said(l10n.passkeyTooMany);
      case 'passkey-exists':
        return said(l10n.passkeyExists);
      case 'passkey-challenge-invalid':
        return said(l10n.passkeyChallengeInvalid);
      case 'passkey-invalid':
        return said(l10n.passkeyInvalid);
      case 'invalid-name':
        return said(l10n.passkeyInvalidName);
      case 'busy':
        return said(l10n.twoStepBusy);
      case 'id-token-required':
        return said(l10n.twoStepIdTokenRequired, signInAgain: true);
      case 'invalid-id-token':
        return said(l10n.twoStepInvalidIdToken, signInAgain: true);
      case 'account-mismatch':
        return said(l10n.handoffWrongAccount);
      case 'no-authenticator':
        return said(l10n.twoStepNoAuthenticator);
      case 'no-such-passkey':
        return said(l10n.twoStepNoSuchPasskey);
      case 'no-passkeys':
        return said(l10n.twoStepNoPasskeys);
      // One or the other (Firebase holds one TOTP factor per account).
      case 'authenticator-app-on':
        return TwoStepProblem(l10n.twoStepAuthenticatorOnError, code: '${ErrorCodes.twoStepOtherKind.code} ($code)');
      case 'authenticator-removed-passkey-failed':
        return TwoStepProblem(l10n.twoStepAuthenticatorLost, code: '${ErrorCodes.twoStepLeftOff.code} ($code)');
      case 'recent-sign-in-required':
        return said(l10n.twoStepNeedsSignIn, signInAgain: true);
      case 'session-revoked':
        return said(l10n.twoStepSessionRevoked, signInAgain: true);
      case 'two-step-off':
        return said(l10n.twoStepOffAlready);
      case 'account-not-found':
        return said(l10n.twoStepAccountNotFound);
      case 'email-unverified':
        return said(l10n.twoStepEmailUnverified);
      case 'sign-in-code-invalid':
        return said(l10n.handoffExpired);
      // A lock-out recovery.
      case 'recovery-code-invalid':
        return said(l10n.lockoutCodeInvalid);
      case 'recovery-ticket-invalid':
        return said(l10n.lockoutTicketInvalid);
      case 'recovery-not-yet':
        final at = error.completesAt;
        return said(at == null ? l10n.lockoutNotYetNoDate : l10n.lockoutNotYet(dayWords(l10n, at)));
      case 'recovery-proof-invalid':
        return said(l10n.lockoutProofInvalid(error.triesLeft ?? 0));
      case 'recovery-proof-closed':
        return said(l10n.lockoutProofClosed);
      case 'recovery-through-company':
        return said(l10n.lockoutThroughCompany);
      case 'recovery-choice-required':
      case 'invalid-request':
        return said(l10n.twoStepErrorGeneric);
    }
    if (error.status == 429) return said(l10n.passkeyErrorRateLimited(waitWords(l10n, error.retryAfter)));
    final cloud = cloudStopped(l10n, error, status: error.status);
    if (cloud != null) return TwoStepProblem(cloud, code: code);
    if (error.status == 401) return said(l10n.twoStepNeedsSignIn, signInAgain: true);
    return said(l10n.twoStepErrorGeneric);
  }
  // Nothing answered, or a fault on the way: how ZestSSH Cloud stands.
  final cloud = cloudStopped(l10n, error);
  if (cloud != null) return TwoStepProblem(cloud);
  return TwoStepProblem(l10n.twoStepErrorGeneric);
}

/// [at] as a day, in the person's language: "30 October 2026".
String dayWords(AppLocalizations l10n, DateTime at) {
  try {
    return DateFormat.yMMMMd(l10n.localeName).format(at.toLocal());
  } catch (_) {
    return DateFormat.yMMMMd('en_US').format(at.toLocal());
  }
}

/// What a passkey of the list is, in words: its kind, whether it syncs, and
/// when it was added. No "last used": none is kept.
String passkeyDetails(AppLocalizations l10n, PasskeyItem item) {
  final kind = switch (item.kind) {
    PasskeyKind.securityKey => l10n.passkeyKindSecurityKey,
    PasskeyKind.platform => l10n.passkeyKindPlatform,
    PasskeyKind.passkey => l10n.passkeyKindPasskey,
  };
  final sync = item.synced
      ? l10n.passkeySynced
      : switch (item.kind) {
          PasskeyKind.securityKey => l10n.passkeyStaysOnKey,
          PasskeyKind.platform => l10n.passkeyStaysOnDevice,
          PasskeyKind.passkey => l10n.passkeyNotSynced,
        };
  final added = item.createdAt;
  return [kind, sync, if (added != null) l10n.passkeyAddedOn(dayWords(l10n, added))].join(' · ');
}

/// The name a new passkey is offered, after this device: "Passkey on
/// Android", "Windows Hello on Windows" where Windows makes it.
String defaultPasskeyName(AppLocalizations l10n, {String? os}) {
  final system = os ?? Platform.operatingSystem;
  return switch (system) {
    'android' => l10n.passkeyDefaultName('Android'),
    'ios' => l10n.passkeyDefaultName('iPhone'),
    'windows' => l10n.passkeyDefaultNameWindows,
    'macos' => l10n.passkeyDefaultName('Mac'),
    'linux' => l10n.passkeyDefaultName('Linux'),
    _ => l10n.passkeyKindPasskey,
  };
}

// The characters ZestSSH Cloud takes out of a passkey's name (control and
// invisible ones; its lib/clean_text.js): the name checked here is the name
// it keeps. (Tabs and line breaks become spaces first.)
final _unseen = RegExp(
    r'[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f\u200b-\u200f\u2028-\u202e\u2060-\u2064\u2066-\u2069\ufeff]');

/// A passkey's name as ZestSSH Cloud keeps it: control and invisible
/// characters gone, one line, 1 to 64 characters; null otherwise.
String? cleanPasskeyName(String raw) {
  final name = raw
      .replaceAll(_unseen, '')
      .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
      .trim();
  final length = name.runes.length;
  return length >= 1 && length <= 64 ? name : null;
}
