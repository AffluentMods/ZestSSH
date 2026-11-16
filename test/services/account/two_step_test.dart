import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account/two_step.dart';
import 'package:zestssh/services/account/two_step_api.dart';
import 'package:zestssh/services/passkeys/passkey_platform.dart';

/// Two-step sign-in (3.0): the recovery codes client, and the
/// second step of a sign-in apart from Firebase.
void main() {
  group('RecoveryCodesApi', () {
    late List<http.Request> sent;

    RecoveryCodesApi api(int status, Object body, {String? bearer = 'tok'}) {
      sent = [];
      return RecoveryCodesApi(
        baseUrl: 'https://api.test/v1',
        bearer: () async => bearer,
        client: MockClient((request) async {
          sent.add(request);
          return http.Response(jsonEncode(body), status,
              headers: {'content-type': 'application/json'});
        }),
      );
    }

    tearDown(() => DeviceSessionHeader.current = null);

    test('reads whether two-step sign-in is on and how many codes remain',
        () async {
      DeviceSessionHeader.current = '11111111-2222-3333-4444-555555555555';
      var status = await api(200, {'count': 7, 'two_step': true}).status();
      expect(status.on, isTrue);
      expect(status.recoveryCodes, 7);
      expect(sent.single.method, 'GET');
      expect(sent.single.url.toString(),
          'https://api.test/v1/account/recovery-codes');
      expect(sent.single.headers['Authorization'], 'Bearer tok');
      expect(sent.single.headers[DeviceSessionHeader.name],
          '11111111-2222-3333-4444-555555555555');

      status = await api(200, {'count': 0, 'two_step': null}).status();
      expect(status.on, isNull, reason: 'the server could not ask Firebase');
    });

    test('makes codes, and says when a fresh sign-in or an authenticator is '
        'needed first', () async {
      final codes = [for (var i = 0; i < 10; i++) 'abcde-fghj$i'];
      expect(await api(201, {'codes': codes}).make(), codes);
      expect(sent.single.method, 'POST');

      await expectLater(
        api(403, {'code': 'recent-sign-in-required'}).make(),
        throwsA(isA<RecoveryCodesException>()
            .having((e) => e.needsRecentSignIn, 'needsRecentSignIn', isTrue)),
      );
      await expectLater(
        api(409, {'code': 'two-step-off'}).make(),
        throwsA(isA<RecoveryCodesException>()
            .having((e) => e.twoStepOff, 'twoStepOff', isTrue)),
      );
    });

    test('forgets codes, and refuses to call without a sign-in', () async {
      await api(200, {'deleted': 10}).forget();
      expect(sent.single.method, 'DELETE');
      await expectLater(
        api(200, {}, bearer: null).status(),
        throwsA(isA<RecoveryCodesException>()),
      );
      expect(sent, isEmpty, reason: 'nothing is sent without a bearer');
    });

    test('uses a recovery code with no sign-in, and reads the refusals',
        () async {
      expect(
          await api(200, {'two_step': false, 'notified': true})
              .recover(email: 'a@example.com', code: 'abcde-fghjk'),
          isTrue);
      final request = sent.single;
      expect(request.url.toString(), 'https://api.test/v1/auth/two-step/recover');
      expect(request.headers.containsKey('Authorization'), isFalse);
      expect(jsonDecode(request.body),
          {'email': 'a@example.com', 'code': 'abcde-fghjk'});

      await expectLater(
        api(400, {'code': 'recovery-code-invalid'})
            .recover(email: 'a@example.com', code: 'abcde-fghjk'),
        throwsA(isA<RecoveryCodesException>()
            .having((e) => e.invalidCode, 'invalidCode', isTrue)),
      );
      await expectLater(
        api(429, {'error': 'Too many'})
            .recover(email: 'a@example.com', code: 'abcde-fghjk'),
        throwsA(isA<RecoveryCodesException>()
            .having((e) => e.tooManyAttempts, 'tooManyAttempts', isTrue)),
      );
    });
  });

  group('SecondStepFlow', () {
    late List<SecondStepChallenge> asked;

    SecondStepPrompt answers(List<SecondStepAnswer?> replies) {
      asked = [];
      var i = 0;
      return (challenge) async {
        asked.add(challenge);
        return replies[i++];
      };
    }

    test('a wrong code is asked again with the reason, then the right one '
        'finishes', () async {
      final codes = <String>[];
      final flow = SecondStepFlow<String>(
        prompt: answers(const [
          AuthenticatorCodeAnswer('111111'),
          AuthenticatorCodeAnswer(' 222222 '),
        ]),
        email: 'a@example.com',
        withCode: (code) async {
          codes.add(code);
          if (code != '222222') {
            throw FirebaseAuthException(code: 'invalid-verification-code');
          }
          return 'signed-in';
        },
        recover: (_, __) async => fail('no recovery'),
        retry: () async => fail('no retry'),
      );
      expect(await flow.run(), 'signed-in');
      expect(codes, ['111111', '222222']);
      expect(asked.map((c) => c.error),
          [null, SecondStepError.wrongCode]);
      expect(asked.first.email, 'a@example.com');
    });

    test('backing out ends the sign-in with nothing', () async {
      final flow = SecondStepFlow<String>(
        prompt: answers(const [null]),
        withCode: (_) async => fail('no code'),
        recover: (_, __) async => fail('no recovery'),
        retry: () async => fail('no retry'),
      );
      expect(await flow.run(), isNull);
    });

    test('a refused recovery code is asked again; a good one turns two-step '
        'sign-in off and repeats the first step', () async {
      final recovered = <List<String>>[];
      var retried = 0;
      final flow = SecondStepFlow<String>(
        prompt: answers(const [
          RecoveryCodeAnswer(email: 'typo@example.com', code: 'aaaaa-aaaaa'),
          RecoveryCodeAnswer(email: ' a@example.com ', code: 'bbbbb-bbbbb'),
        ]),
        email: 'a@example.com',
        withCode: (_) async => fail('no authenticator code'),
        recover: (email, code) async {
          recovered.add([email, code]);
          if (code != 'bbbbb-bbbbb') {
            throw const RecoveryCodesException(400, 'recovery-code-invalid');
          }
        },
        retry: () async {
          retried++;
          return 'signed-in-again';
        },
      );
      expect(await flow.run(), 'signed-in-again');
      expect(recovered, [
        ['typo@example.com', 'aaaaa-aaaaa'],
        ['a@example.com', 'bbbbb-bbbbb'],
      ]);
      expect(retried, 1);
      expect(asked[1].error, SecondStepError.recoveryCodeInvalid);
      expect(asked[1].email, 'typo@example.com',
          reason: 'the address they typed is kept for the next try');
    });

    test('too many tries and an unreachable service are told apart', () async {
      final errors = <Object>[
        const RecoveryCodesException(429),
        const SocketException('offline'),
      ];
      final flow = SecondStepFlow<String>(
        prompt: answers(const [
          RecoveryCodeAnswer(email: 'a@example.com', code: 'aaaaa-aaaaa'),
          RecoveryCodeAnswer(email: 'a@example.com', code: 'aaaaa-aaaaa'),
          null,
        ]),
        withCode: (_) async => fail('no code'),
        recover: (_, __) async => throw errors.removeAt(0),
        retry: () async => fail('no retry'),
      );
      expect(await flow.run(), isNull);
      expect(asked.map((c) => c.error), [
        null,
        SecondStepError.tooManyAttempts,
        SecondStepError.unavailable,
      ]);
      // What stopped a recovery code that could not be used is passed on,
      // for saying how ZestSSH Cloud stands; a refusal has nothing to add.
      expect(asked[1].cause, isNull);
      expect(asked[2].cause, isA<SocketException>());
    });

    test('what stopped a recovery code is carried for the one question that '
        'follows it, and never for the sign-in service', () async {
      final errors = <Object>[
        const RecoveryCodesException(503),
        const RecoveryCodesException(400, 'recovery-code-invalid'),
      ];
      final flow = SecondStepFlow<String>(
        prompt: answers(const [
          RecoveryCodeAnswer(email: 'a@example.com', code: 'aaaaa-aaaaa'),
          RecoveryCodeAnswer(email: 'a@example.com', code: 'aaaaa-aaaaa'),
          AuthenticatorCodeAnswer('000000'),
          null,
        ]),
        withCode: (_) async =>
            throw FirebaseAuthException(code: 'network-request-failed'),
        recover: (_, _) async => throw errors.removeAt(0),
        retry: () async => fail('no retry'),
      );
      expect(await flow.run(), isNull);
      expect(asked.map((c) => c.error), [
        null,
        SecondStepError.unavailable,
        SecondStepError.recoveryCodeInvalid,
        SecondStepError.unavailable,
      ]);
      expect(asked[0].cause, isNull);
      // The server's own answer where it gave one: its status is in it.
      expect(
          asked[1].cause,
          isA<RecoveryCodesException>()
              .having((e) => e.status, 'status', 503));
      // Nothing for a code that was refused, although the try before it
      // had a cause; and nothing where it was the sign-in service's code
      // that could not be checked, which is not ZestSSH Cloud's to explain.
      expect(asked[2].cause, isNull);
      expect(asked[3].cause, isNull);
    });

    test('when the first step cannot be repeated after a recovery code, the '
        'person is told to sign in again', () async {
      final flow = SecondStepFlow<String>(
        prompt: answers(const [
          RecoveryCodeAnswer(email: 'a@example.com', code: 'bbbbb-bbbbb'),
        ]),
        withCode: (_) async => fail('no code'),
        recover: (_, __) async {},
        retry: () async =>
            throw FirebaseAuthException(code: 'invalid-credential'),
      );
      await expectLater(flow.run(), throwsA(isA<TwoStepTurnedOff>()));
    });

    test('an error that is not about the code ends the sign-in', () async {
      final flow = SecondStepFlow<String>(
        prompt: answers(const [AuthenticatorCodeAnswer('123456')]),
        withCode: (_) async =>
            throw FirebaseAuthException(code: 'user-disabled'),
        recover: (_, __) async => fail('no recovery'),
        retry: () async => fail('no retry'),
      );
      await expectLater(
        flow.run(),
        throwsA(isA<FirebaseAuthException>()
            .having((e) => e.code, 'code', 'user-disabled')),
      );
    });
  });

  group('which second step (3.3)', () {
    MultiFactorInfo hint(String uid, String? name, {String factorId = 'totp'}) =>
        MultiFactorInfo(factorId: factorId, enrollmentTimestamp: 0, displayName: name, uid: uid);

    test('by the factors\' names, never the first code hint', () {
      // The bridge first: a code is still asked of the authenticator only.
      var chosen = chooseSecondFactors([hint('bridge-1', kBridgeFactorName), hint('auth-1', kAuthenticatorFactorName)]);
      expect(chosen.authenticator?.uid, 'auth-1');
      expect(chosen.passkey?.uid, 'bridge-1');
      chosen = chooseSecondFactors([hint('bridge-1', 'Passkey')]);
      expect(chosen.authenticator, isNull, reason: 'the bridge is never offered as "enter a code"');
      expect(chosen.passkey?.uid, 'bridge-1');
      // Anything else is a second step ZestSSH does not offer.
      chosen = chooseSecondFactors(
          [hint('a', null), hint('b', 'My phone'), hint('c', 'Passkey', factorId: 'phone'), hint('', 'Passkey')]);
      expect(chosen.authenticator, isNull);
      expect(chosen.passkey, isNull);
    });
  });

  group('the passkey step of a sign-in (3.3)', () {
    late List<SecondStepChallenge> asked;

    SecondStepPrompt answers(List<SecondStepAnswer?> replies) {
      asked = [];
      var i = 0;
      return (challenge) async {
        asked.add(challenge);
        return replies[i++];
      };
    }

    SecondStepFlow<String> flow(List<SecondStepAnswer?> replies, Future<String> Function() withPasskey,
            {bool authenticator = false}) =>
        SecondStepFlow<String>(
          prompt: answers(replies),
          authenticator: authenticator,
          withCode: authenticator ? (_) async => 'with-code' : null,
          withPasskey: withPasskey,
          recover: (_, _) async => fail('no recovery'),
          retry: () async => fail('no retry'),
        );

    test('a passkey finishes it; a closed passkey window is no error and is asked again', () async {
      var tries = 0;
      final done = await flow(const [PasskeyAnswer(), PasskeyAnswer()], () async {
        if (tries++ == 0) throw const PasskeyCancelled();
        return 'with-passkey';
      }).run();
      expect(done, 'with-passkey');
      expect(asked.first.passkey, isTrue);
      expect(asked.first.authenticator, isFalse, reason: 'no authenticator, no code asked');
      expect(asked[1].passkeyFailure?.code, 'cancelled');
      expect(asked[1].passkeyFailure?.quiet, isTrue);
    });

    test("ZestSSH Cloud's refusals are asked again with what they said", () async {
      final refusals = <Object>[
        const TwoStepRefusal(401, code: 'passkey-failed'),
        const TwoStepRefusal(429, code: 'passkey-paused', retryAfter: Duration(minutes: 40)),
        const TwoStepRefusal(401, code: 'passkey-cloned'),
        const PasskeyError('no-credential', 'NoCredentialException'),
        const SocketException('offline'),
      ];
      final done = await flow(
        [for (var i = 0; i <= refusals.length; i++) const PasskeyAnswer()],
        () async => refusals.isEmpty ? 'with-passkey' : throw refusals.removeAt(0),
      ).run();
      expect(done, 'with-passkey');
      final failures = [for (final c in asked.skip(1)) c.passkeyFailure!];
      expect(failures.map((f) => f.code), ['passkey-failed', 'passkey-paused', 'passkey-cloned', 'device', 'network']);
      expect(failures[1].retryAfter, const Duration(minutes: 40));
      expect(failures[3].deviceCode, 'no-credential');
      expect(failures[3].shownCode, 'passkey-device-no-credential');
      expect(failures[4].cause, isA<SocketException>());
    });

    test('passkeys off at ZestSSH Cloud: not offered again, the authenticator is', () async {
      final done = await flow(
        const [PasskeyAnswer(), AuthenticatorCodeAnswer('123456')],
        () async => throw const TwoStepRefusal(404, code: 'passkeys-unavailable'),
        authenticator: true,
      ).run();
      expect(done, 'with-code');
      expect(asked[1].passkey, isFalse);
      expect(asked[1].passkeyElsewhere, isTrue);
      expect(asked[1].authenticator, isTrue);
    });

    test('an error that is no failure of the passkey ends the sign-in', () async {
      await expectLater(
        flow(const [PasskeyAnswer()], () async => throw FirebaseAuthException(code: 'user-disabled')).run(),
        throwsA(isA<FirebaseAuthException>()),
      );
    });

    test('no second step and no recovery code: the sign-in ends, for the account\'s recovery', () async {
      expect(await flow(const [LockedOutAnswer(email: 'a@example.com')], () async => fail('no passkey')).run(), isNull);
    });

    test('the bridge\'s code goes from ZestSSH Cloud straight to Firebase, after the device\'s passkey', () async {
      final calls = <String>[];
      final cloud = TwoStepApi(
        baseUrl: 'https://api.test/v1',
        client: MockClient((request) async {
          calls.add(request.url.path);
          return http.Response(
              jsonEncode(request.url.path.endsWith('/challenge')
                  ? {'rpId': 'zestssh.com', 'challenge': 'Y2g'}
                  : {'enrollment_id': 'bridge-1', 'code': '654321'}),
              200);
        }),
      );
      final platform = _OnePasskey();
      final finished = await runPasskeyStep<String>(
        api: cloud,
        platform: platform,
        enrollmentId: 'bridge-1',
        email: 'a@example.com',
        finish: (id, code) async => '$id:$code',
      );
      expect(finished, 'bridge-1:654321');
      expect(calls, ['/v1/auth/passkey/challenge', '/v1/auth/passkey/verify']);
      expect(platform.asked, {'rpId': 'zestssh.com', 'challenge': 'Y2g'});
    });
  });

  // One or the other: Firebase holds one TOTP
  // factor per account, and the passkeys' bridge is one. The played Firebase
  // below refuses a second one as Firebase does, when an enrolment begins or
  // only when it finishes.
  group('the authenticator app in the place of the passkeys', () {
    // RFC 6238's SHA-1 secret, "12345678901234567890", in base32.
    const key = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';
    final at59 = DateTime.fromMillisecondsSinceEpoch(59 * 1000, isUtc: true);

    test('a code is checked here as an authenticator app makes it (RFC 6238), a step either side', () {
      expect(base32Bytes(key), utf8.encode('12345678901234567890'));
      expect(totpCode(base32Bytes(key)!, 1, digits: 8), '94287082');
      expect(totpCode(base32Bytes(key)!, 37037036, digits: 8), '07081804');
      expect(totpMatches(key, '287082', now: at59), isTrue);
      expect(totpMatches(key, '287082', now: at59.add(const Duration(seconds: 30))), isTrue, reason: 'a step late');
      expect(totpMatches(key, '287082', now: at59.add(const Duration(seconds: 91))), isFalse);
      expect(totpMatches(key, '28708', now: at59), isFalse);
      expect(totpMatches('not base32!', '287082', now: at59), isFalse);
      expect(totpMatches(key, '287082', now: at59, algorithm: 'MD5'), isFalse);
      expect(AuthenticatorSetup(qrUrl: 'otpauth://x', key: key).codeMatches('287082', now: at59), isTrue);
    });

    test("Firebase's refusal of a second TOTP factor is known by its codes", () {
      expect(isSecondFactorLimit(FirebaseAuthException(code: 'maximum-second-factor-count-exceeded')), isTrue);
      expect(isSecondFactorLimit(FirebaseAuthException(code: 'second-factor-limit-exceeded')), isTrue);
      expect(isSecondFactorLimit(FirebaseAuthException(code: 'invalid-verification-code')), isFalse);
      expect(isSecondFactorLimit(StateError('x')), isFalse);
    });

    for (final limitAt in ['start', 'finalize']) {
      test('Firebase full at ${limitAt == 'start' ? 'the start' : 'the finish'}: the passkeys go as late as can be, '
          'and never for a wrong code', () async {
        final firebase = _OneTotp(limitAt: limitAt);
        var asked = 0;
        final begun = await beginInPlaceOfPasskeys(
          start: firebase.start,
          agreeGap: () async {
            asked++;
            return true;
          },
          removePasskeys: firebase.removePasskeys,
        );
        expect(begun, isNotNull);
        expect(begun!.passkeysGone, limitAt == 'start');
        expect(asked, limitAt == 'start' ? 1 : 0, reason: 'asked only where two-step sign-in goes off for a while');
        Future<void> finish(String code) => finishInPlaceOfPasskeys(
              setup: begun.setup,
              code: code,
              passkeysGone: begun.passkeysGone,
              removePasskeys: firebase.removePasskeys,
              enroll: firebase.finish,
              now: at59,
            );
        if (!begun.passkeysGone) {
          await expectLater(finish('000000'),
              throwsA(isA<FirebaseAuthException>().having((e) => e.code, 'code', 'invalid-verification-code')));
          expect(firebase.factors, ['Passkey'], reason: 'a wrong code changed nothing');
        }
        await finish('287082');
        expect(firebase.factors, ['Authenticator app']);
        expect(firebase.calls,
            limitAt == 'start' ? ['start', 'remove passkeys', 'start', 'enroll'] : ['start', 'remove passkeys', 'enroll']);
      });
    }

    test('the person keeps the passkeys where they must go first: nothing changes', () async {
      final firebase = _OneTotp(limitAt: 'start');
      final begun = await beginInPlaceOfPasskeys(
        start: firebase.start,
        agreeGap: () async => false,
        removePasskeys: firebase.removePasskeys,
      );
      expect(begun, isNull);
      expect(firebase.factors, ['Passkey']);
      expect(firebase.calls, ['start']);
    });

    test('enrolling beside the passkeys, as before the rule, is what Firebase refuses', () async {
      final firebase = _OneTotp(limitAt: 'finalize');
      final setup = await firebase.start();
      await expectLater(firebase.finish(setup, '287082'), throwsA(predicate(isSecondFactorLimit)));
    });

    test('a failure once the passkeys went is said as such', () async {
      final firebase = _OneTotp(limitAt: 'start')..failSecondStart = true;
      await expectLater(
        beginInPlaceOfPasskeys(start: firebase.start, agreeGap: () async => true, removePasskeys: firebase.removePasskeys),
        throwsA(isA<PasskeysGoneFailure>()),
      );
      expect(firebase.factors, isEmpty);
    });
  });

  test('recovery codes and keys are shown in readable groups', () {
    expect(formatRecoveryCode(' ABCDE FGHJK '), 'abcde-fghjk');
    expect(formatRecoveryCode('abcdefghjk'), 'abcde-fghjk');
    expect(formatRecoveryCode('short'), 'short');
    expect(groupKey('JBSWY3DPEHPK3PXPJBSWY3DPEH'),
        'JBSW Y3DP EHPK 3PXP JBSW Y3DP EH');
  });
}

/// Firebase's side of the authenticator app, played: one TOTP factor per
/// account (the bridge 'Passkey' or the 'Authenticator app'), a second one
/// refused at the start of an enrolment or only at its finish ([limitAt]).
class _OneTotp {
  _OneTotp({required this.limitAt});

  final String limitAt;
  final factors = <String>['Passkey'];
  final calls = <String>[];
  bool failSecondStart = false;

  FirebaseAuthException get _limit => FirebaseAuthException(code: 'maximum-second-factor-count-exceeded');

  Future<AuthenticatorSetup> start() async {
    calls.add('start');
    if (limitAt == 'start' && factors.isNotEmpty) throw _limit;
    if (failSecondStart && calls.where((c) => c == 'start').length > 1) {
      throw FirebaseAuthException(code: 'network-request-failed');
    }
    return AuthenticatorSetup(qrUrl: 'otpauth://totp/x', key: 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ');
  }

  Future<void> removePasskeys() async {
    calls.add('remove passkeys');
    factors.remove('Passkey');
  }

  Future<void> finish(AuthenticatorSetup setup, String code) async {
    if (factors.isNotEmpty) throw _limit;
    calls.add('enroll');
    factors.add('Authenticator app');
  }
}

/// One passkey, answering whatever it is asked.
class _OnePasskey implements PasskeyPlatform {
  Map<String, Object?>? asked;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<Map<String, Object?>> create(Map<String, Object?> options) async => throw const PasskeyError('unsupported');

  @override
  Future<Map<String, Object?>> get(Map<String, Object?> options) async {
    asked = options;
    return {'id': 'cred', 'rawId': 'cred', 'type': 'public-key', 'response': <String, Object?>{}};
  }
}
