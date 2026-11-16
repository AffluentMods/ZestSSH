import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/account/browser_handoff.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account/lockout_watch.dart';
import 'package:zestssh/services/account/signed_out_notice.dart';
import 'package:zestssh/services/account/two_step.dart';
import 'package:zestssh/services/account/two_step_api.dart';
import 'package:zestssh/services/passkeys/passkey_platform.dart';
import 'package:zestssh/ui/screens/profile/widgets/two_step_words.dart';

/// What the two-step screens say (3.3): every refusal of ZestSSH Cloud and
/// every passkey error of the device has words of its own, says what to do,
/// and carries the code a support request quotes; why a device was signed
/// out is said by its reason; in every language.
void main() {
  setUpAll(initializeDateFormatting);

  final en = lookupAppLocalizations(const Locale('en'));

  /// Every code the two-step, passkey, recovery and hand-off routes answer
  /// with (ZestSSH Cloud's routes/passkeys.js, two_step.js,
  /// lockout_recovery.js, recovery_codes.js, auth.js, lib/two_step_requests.js).
  const codes = [
    'passkey-failed', 'passkey-cloned', 'passkey-paused', 'rate-limited', 'two-step-unavailable',
    'passkeys-unavailable', 'too-many-passkeys', 'passkey-exists', 'passkey-challenge-invalid', 'passkey-invalid',
    'invalid-name', 'busy', 'id-token-required', 'invalid-id-token', 'account-mismatch', 'no-authenticator',
    'no-such-passkey', 'recent-sign-in-required', 'session-revoked', 'two-step-off', 'account-not-found',
    'email-unverified', 'sign-in-code-invalid', 'recovery-code-invalid', 'recovery-ticket-invalid',
    'recovery-not-yet', 'recovery-proof-invalid', 'recovery-proof-closed', 'recovery-through-company',
  ];

  test('every server code has words of its own, with the code beside them', () {
    final seen = <String>{};
    for (final code in codes) {
      final problem = twoStepProblem(en, TwoStepRefusal(400, code: code, triesLeft: 3));
      expect(problem.text, isNot(en.twoStepErrorGeneric), reason: code);
      expect(problem.code, code);
      expect(problem.quiet, isFalse);
      seen.add(problem.text);
    }
    expect(seen.length, greaterThan(25), reason: 'not one sentence for everything');
    // A refusal with a reason says it too.
    expect(twoStepProblem(en, const TwoStepRefusal(403, code: 'recent-sign-in-required', reason: 'second-step-required')).code,
        'recent-sign-in-required (second-step-required)');
    // What the app has no words for yet: what to do, and its code.
    final unknown = twoStepProblem(en, const TwoStepRefusal(400, code: 'something-new'));
    expect((unknown.text, unknown.code), (en.twoStepErrorGeneric, 'something-new'));
  });

  test('the tries left, the day, and how long to wait are said', () {
    expect(twoStepProblem(en, const TwoStepRefusal(400, code: 'recovery-proof-invalid', triesLeft: 4)).text,
        en.lockoutProofInvalid(4));
    expect(en.lockoutProofInvalid(4), contains('4'));
    expect(
        twoStepProblem(en, TwoStepRefusal(409, code: 'recovery-not-yet', completesAt: DateTime(2026, 11, 6))).text,
        'The recovery cannot be completed yet: it waits until November 6, 2026.');
    expect(twoStepProblem(en, const TwoStepRefusal(429, code: 'passkey-paused', retryAfter: Duration(minutes: 60))).text,
        contains('an hour'));
    expect(twoStepProblem(en, const TwoStepRefusal(429, code: 'passkey-paused', retryAfter: Duration(minutes: 50))).text,
        contains('50 minutes'));
    expect(twoStepProblem(en, const TwoStepRefusal(429, code: 'passkey-paused')).text, contains('an hour'),
        reason: 'a pause is an hour where it does not say');
    expect(twoStepProblem(en, const TwoStepRefusal(429, code: 'rate-limited', retryAfter: Duration(seconds: 200))).text,
        contains('4 minutes'));
    expect(twoStepProblem(en, const TwoStepRefusal(429, code: 'rate-limited')).text, contains('a minute'));
    expect(twoStepProblem(en, const TwoStepRefusal(429)).text, contains('a minute'),
        reason: 'a 429 with no code is a limit too');
    expect(waitWords(en, const Duration(seconds: 3)), en.waitFewSeconds);
    expect(waitWords(en, const Duration(hours: 5)), '5 hours');
  });

  test("the device's passkey errors, the person's own cancel, Firebase's and the way to ZestSSH Cloud", () {
    final cancelled = twoStepProblem(en, const PasskeyCancelled(), doing: TwoStepDoing.adding);
    expect((cancelled.quiet, cancelled.code, cancelled.text), (true, '', en.passkeyAddCancelled));
    expect(twoStepProblem(en, const PasskeyCancelled(), doing: TwoStepDoing.signIn).text, en.passkeyCancelledNote);
    for (final code in ['unsupported', 'no-credential', 'invalid-state', 'security', 'failed']) {
      final p = twoStepProblem(en, PasskeyError(code, 'the system said so'));
      expect(p.code, 'passkey-device-$code');
      expect(p.text, isNot(contains('the system said so')), reason: 'the system\'s own words go to Copy details');
    }
    expect(twoStepProblem(en, const PasskeyError('invalid-state'), doing: TwoStepDoing.adding).text, en.passkeyExists);
    expect(twoStepProblem(en, const HandoffWrongAccount()).text, en.handoffWrongAccount);
    expect(twoStepProblem(en, FirebaseAuthException(code: 'requires-recent-login')).signInAgain, isTrue);
    expect(twoStepProblem(en, FirebaseAuthException(code: 'second-factor-already-in-use')).code,
        'auth/second-factor-already-in-use');
    final offline = twoStepProblem(en, const SocketException('Connection refused'));
    expect(offline.text, contains('ZS-11'), reason: 'how ZestSSH Cloud stands, with its code');
    expect(twoStepProblem(en, const TwoStepRefusal(503)).text, contains('ZS-1103'));
  });

  test('the passkey step of a sign-in says each failure as it is', () {
    expect(passkeyStepProblem(en, const PasskeyStepFailure('cancelled')).quiet, isTrue);
    expect(passkeyStepProblem(en, const PasskeyStepFailure('passkey-failed')).text, en.passkeyErrorFailed);
    expect(passkeyStepProblem(en, const PasskeyStepFailure('device', deviceCode: 'no-credential')).code,
        'passkey-device-no-credential');
    expect(
        passkeyStepProblem(en, const PasskeyStepFailure('network', cause: SocketException('refused'))).text, contains('ZS-11'));
    expect(passkeyStepProblem(en, const PasskeyStepFailure('passkeys-unavailable')).text, en.passkeyErrorOff);
  });

  test('a passkey in words: its kind, whether it syncs, the day it was added, never when it was used', () {
    final details = passkeyDetails(
        en, PasskeyItem(id: 'x', name: 'YubiKey', kind: PasskeyKind.securityKey, createdAt: DateTime(2026, 10, 30)));
    expect(details, 'Security key · Stays on the key · Added October 30, 2026');
    expect(passkeyDetails(en, const PasskeyItem(id: 'x', name: 'n', synced: true)), 'Passkey · Synced');
    expect(passkeyDetails(en, const PasskeyItem(id: 'x', name: 'n', kind: PasskeyKind.platform)),
        'Built into a device · Stays on that device');
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      final words = passkeyDetails(l10n, PasskeyItem(id: 'x', name: 'n', createdAt: DateTime(2026, 10, 30)));
      expect(words.toLowerCase(), isNot(contains('last')), reason: '$locale');
    }
  });

  test("a new passkey's name: after this device's system, never its own name; and as ZestSSH Cloud keeps it", () {
    expect(defaultPasskeyName(en, os: 'android'), 'Passkey on Android');
    expect(defaultPasskeyName(en, os: 'ios'), 'Passkey on iPhone');
    expect(defaultPasskeyName(en, os: 'windows'), 'Windows Hello');
    expect(defaultPasskeyName(en, os: 'windows'), isNot(contains(Platform.localHostname)));
    expect(cleanPasskeyName('  Work\tlaptop\n'), 'Work laptop');
    expect(cleanPasskeyName('a​b'), 'ab');
    expect(cleanPasskeyName(''), isNull);
    expect(cleanPasskeyName('x' * 65), isNull);
    expect(cleanPasskeyName('🔑' * 64), '🔑' * 64, reason: 'characters, not code units');
  });

  test('why a device was signed out, by each reason ZestSSH Cloud gives, in every language', () {
    const reasons = [
      kSignedOutForTwoStep, kSignedOutFactorRemoved, kSignedOutTwoStepOff, kSignedOutRecoveryCodeUsed,
      kSignedOutAccountRecovered, kSignedOutPasswordChanged, kSignedOutSsoRemoved, null,
    ];
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      final titles = {for (final r in reasons) signedOutNotice(l10n, r).title};
      expect(titles, hasLength(reasons.length), reason: '$locale: each reason its own words');
      for (final r in reasons) {
        expect(signedOutNotice(l10n, r).body, isNotEmpty);
      }
    }
    expect(signedOutNotice(en, 'something-new').title, en.devicesSignedOutElsewhereTitle);
    expect(en.devicesSignedOutTwoStepBody, contains('passkey'), reason: 'not only a code any more');
  });

  test('every language says the counts and the waits', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      for (final n in [1, 2, 5, 11, 21]) {
        expect(l10n.twoStepSignedOutOthers(n), isNotEmpty);
        expect(l10n.waitMinutes(n), isNotEmpty);
        expect(l10n.waitHours(n), isNotEmpty);
        expect(l10n.lockoutProofInvalid(n), isNotEmpty);
        expect(l10n.twoStepCodesRowDescAny(n), isNotEmpty);
      }
      expect(l10n.twoStepCodesRowDescAny(0), isNot(l10n.twoStepCodesRowDescAny(5)), reason: '$locale');
      for (final code in codes) {
        expect(twoStepProblem(l10n, TwoStepRefusal(400, code: code, triesLeft: 2, completesAt: DateTime(2026, 11, 6))).text,
            isNot(contains('{')), reason: '$locale $code');
      }
    }
  });

  group('the notice of a recovery someone asked for', () {
    test('told once, looked at again at most every half hour, at once when the line says so, gone with it',
        () async {
      var now = DateTime(2026, 10, 30, 9);
      var waiting = true;
      var asked = 0;
      final told = <DateTime>[];
      var cleared = 0;
      final watch = LockoutRecoveryWatch(
        api: () => _StateApi(() {
          asked++;
          return TwoStepState(
            on: true,
            lockoutRecovery: waiting ? WaitingRecovery(completesAt: DateTime.utc(2026, 11, 6)) : null,
          );
        }),
        tell: (w) => told.add(w.completesAt),
        clear: () => cleared++,
        now: () => now,
      );
      await watch.check(now: true);
      await watch.check();
      expect((asked, told.length), (1, 1));
      now = now.add(const Duration(minutes: 31));
      await watch.check();
      expect((asked, told.length), (2, 1), reason: 'the same recovery is told once');
      waiting = false;
      await watch.check(now: true);
      expect(cleared, 1);
      await watch.check(now: true);
      expect(cleared, 1, reason: 'nothing to take away twice');
    });

    test('a look that fails says nothing and takes nothing away', () async {
      var cleared = 0;
      final watch = LockoutRecoveryWatch(
        api: () => _StateApi(() => throw const TwoStepRefusal(401, code: 'signed-out')),
        tell: (_) => fail('nothing to tell'),
        clear: () => cleared++,
      );
      await watch.check(now: true);
      expect(cleared, 0);
    });
  });

  test('a "signed out" heard while this device changes its own sign-in waits until the change is over', () async {
    expect(SignInChange.running, isFalse);
    await SignInChange.settled();
    final gate = Completer<void>();
    final change = SignInChange.during(() => gate.future);
    expect(SignInChange.running, isTrue);
    var looked = false;
    final waiting = SignInChange.settled().then((_) => looked = true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(looked, isFalse);
    gate.complete();
    await change;
    await waiting;
    expect(looked, isTrue);
    expect(SignInChange.running, isFalse);
    // One that fails is over too.
    await expectLater(SignInChange.during<void>(() async => throw StateError('no')), throwsStateError);
    expect(SignInChange.running, isFalse);
  });
}

/// ZestSSH Cloud answering the state with [answer].
class _StateApi extends TwoStepApi {
  _StateApi(this.answer) : super(baseUrl: 'https://api.test/v1', bearer: () async => 'tok');

  final TwoStepState Function() answer;

  @override
  Future<TwoStepState> state() async => answer();
}
