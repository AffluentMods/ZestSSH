import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account/two_step_api.dart';

/// ZestSSH Cloud's two-step, passkey, lock-out recovery and hand-off routes
/// (3.3; the two-step contract, sections 3 and 7): what the app sends and
/// how it reads every answer and refusal. The same routes against the real
/// server: two_step_contract_test.dart.
void main() {
  late List<http.Request> sent;

  /// A client answering each request with what [answer] gives for it.
  TwoStepApi api(
    http.Response Function(http.Request request) answer, {
    String? bearer = 'tok',
  }) {
    sent = [];
    return TwoStepApi(
      baseUrl: 'https://api.test/v1',
      bearer: () async => bearer,
      client: MockClient((request) async {
        sent.add(request);
        return answer(request);
      }),
    );
  }

  http.Response json(int status, Object body, {Map<String, String> headers = const {}}) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json', ...headers});

  const body = {
    'on': true,
    'authenticator': false,
    'passkeys': 2,
    'recovery_codes': 9,
    'passkeys_available': true,
    'recovery_proof': true,
    'lockout_recovery': {'requested_at': '2026-10-30T09:00:00.000Z', 'completes_at': '2026-11-06T09:00:00.000Z'},
  };

  tearDown(() {
    DeviceSessionHeader.current = null;
    sessionRevokedReason = null;
  });

  group('the state', () {
    test('as ZestSSH Cloud holds it, with the device\'s sign-in and registration', () async {
      DeviceSessionHeader.current = 'reg-1.proof';
      final state = await api((_) => json(200, body)).state();
      expect(state.on, isTrue);
      expect(state.known, isTrue);
      expect(state.authenticator, isFalse);
      expect(state.passkeys, 2);
      expect(state.factors, 2);
      expect(state.recoveryCodes, 9);
      expect(state.passkeysAvailable, isTrue);
      expect(state.recoveryProof, isTrue);
      expect(state.lockoutRecovery!.completesAt.toUtc(), DateTime.utc(2026, 11, 6, 9));
      expect(state.lockoutRecovery!.requestedAt!.toUtc(), DateTime.utc(2026, 10, 30, 9));
      expect(state.older, isFalse);
      expect(sent.single.method, 'GET');
      expect(sent.single.url.toString(), 'https://api.test/v1/account/two-step');
      expect(sent.single.headers['Authorization'], 'Bearer tok');
      expect(sent.single.headers[DeviceSessionHeader.name], 'reg-1.proof');
      expect(state.withoutRecovery().lockoutRecovery, isNull);
    });

    test('a server from before 3.3: its recovery codes route stands in, with no passkeys', () async {
      final client = api((r) => r.url.path.endsWith('/two-step')
          ? http.Response('Cannot GET /v1/account/two-step', 404)
          : json(200, {'count': 4, 'two_step': true}));
      var state = await client.state();
      expect(sent.map((r) => r.url.path), ['/v1/account/two-step', '/v1/account/recovery-codes']);
      expect((state.older, state.on, state.known, state.authenticator, state.recoveryCodes), (true, true, true, true, 4));
      expect(state.passkeysAvailable, isFalse);

      state = await api((r) => r.url.path.endsWith('/two-step')
          ? http.Response('', 404)
          : json(200, {'count': 0, 'two_step': null})).state();
      expect(state.known, isFalse, reason: 'it could not ask Firebase');
    });

    test('nothing is sent without a sign-in', () async {
      await expectLater(api((_) => json(200, body), bearer: null).state(),
          throwsA(isA<TwoStepRefusal>().having((e) => e.code, 'code', 'signed-out')));
      expect(sent, isEmpty);
    });

    test('this device signed out: said as every answer says it, with the reason', () async {
      final before = sessionRevokedSignal.value;
      await expectLater(
        api((_) => json(401, {'code': 'session-revoked', 'reason': 'factor-removed'})).state(),
        throwsA(isA<TwoStepRefusal>()
            .having((e) => e.signedOut, 'signedOut', isTrue)
            .having((e) => e.reason, 'reason', 'factor-removed')),
      );
      expect(sessionRevokedSignal.value, before + 1);
      expect(sessionRevokedReason, kSignedOutFactorRemoved);
      // A change made with a handed ID token says nothing of this device.
      await expectLater(
        api((_) => json(401, {'code': 'session-revoked'})).withBearer('id-token').state(),
        throwsA(isA<TwoStepRefusal>()),
      );
      expect(sessionRevokedSignal.value, before + 1);
      expect(sent.single.headers['Authorization'], 'Bearer id-token');
    });
  });

  group('changes', () {
    test('changed, turn off and the authenticator answer the state, who was signed out and the email', () async {
      final client = api((_) => json(200, {...body, 'signed_out': 3, 'notified': true}));
      for (final change in [await client.changed(), await client.turnOff(), await client.removeAuthenticator()]) {
        expect(change.signedOut, 3);
        expect(change.notified, isTrue);
        expect(change.state.passkeys, 2);
      }
      expect(sent.map((r) => '${r.method} ${r.url.path}'), [
        'POST /v1/account/two-step/changed',
        'DELETE /v1/account/two-step',
        'DELETE /v1/account/two-step/authenticator',
      ]);
      expect(sent.last.body, isEmpty, reason: "a phone's own sign-in is the ID token");
      await client.removeAuthenticator(idToken: 'handed');
      expect(jsonDecode(sent.last.body), {'id_token': 'handed'});
      expect(sent.last.headers['Content-Type'], startsWith('application/json'));
    });

    test('every refusal by its code, the reason, and how long to wait', () async {
      Future<TwoStepRefusal> refusal(int status, Map<String, Object?> body, {Map<String, String> headers = const {}}) async {
        try {
          await api((_) => json(status, body, headers: headers)).turnOff();
        } on TwoStepRefusal catch (e) {
          return e;
        }
        fail('no refusal');
      }

      var e = await refusal(403, {'code': 'recent-sign-in-required', 'reason': 'second-step-required'});
      expect((e.needsRecentSignIn, e.needsSecondStep, e.shownCode),
          (true, true, 'recent-sign-in-required (second-step-required)'));
      e = await refusal(409, {'code': 'id-token-required'});
      expect(e.needsIdToken, isTrue);
      e = await refusal(429, {'code': 'passkey-paused'}, headers: {'retry-after': '3600'});
      expect(e.retryAfter, const Duration(hours: 1));
      e = await refusal(502, {'error': 'Could not reach the sign-in service'});
      expect((e.code, e.shownCode), (null, 'HTTP 502'));
      expect('$e', 'Two-step: HTTP 502');
    });

    test('Retry-After in seconds or as a date', () {
      final now = DateTime.utc(2026, 10, 30, 12);
      expect(retryAfterOf('90'), const Duration(seconds: 90));
      expect(retryAfterOf(HttpDate.format(now.add(const Duration(minutes: 5))), now: now), const Duration(minutes: 5));
      expect(retryAfterOf(HttpDate.format(now.subtract(const Duration(minutes: 5))), now: now), Duration.zero);
      expect(retryAfterOf(null), isNull);
      expect(retryAfterOf('soon'), isNull);
    });
  });

  group('passkeys', () {
    const item = {
      'id': 'Y3JlZA',
      'name': 'Passkey on Android',
      'created_at': '2026-10-30T10:00:00.000Z',
      'transports': ['internal', 'hybrid'],
      'synced': true,
      'kind': 'passkey',
    };

    test('options, then the response kept with its name; the first one with a fresh ID token', () async {
      final client = api((r) => r.url.path.endsWith('/options')
          ? json(200, {'challenge': 'Y2g', 'rp': {'id': 'zestssh.com'}}, headers: {'cache-control': 'no-store'})
          : json(201, {'passkey': item, 'two_step': body, 'signed_out': 1, 'notified': true}));
      final options = await client.passkeyOptions();
      expect(options['challenge'], 'Y2g');
      expect(jsonDecode(sent.single.body), <String, Object?>{});
      final added = await client.addPasskey(response: {'id': 'Y3JlZA'}, name: 'Passkey on Android', idToken: 'handed');
      expect(jsonDecode(sent.last.body), {
        'response': {'id': 'Y3JlZA'},
        'name': 'Passkey on Android',
        'id_token': 'handed',
      });
      expect(added.passkey.name, 'Passkey on Android');
      expect(added.passkey.kind, PasskeyKind.passkey);
      expect(added.passkey.synced, isTrue);
      expect(added.passkey.createdAt!.toUtc(), DateTime.utc(2026, 10, 30, 10));
      expect(added.change.signedOut, 1);
      expect(added.change.state.on, isTrue);
      await client.addPasskey(response: {'id': 'x'}, name: 'Windows Hello');
      expect((jsonDecode(sent.last.body) as Map).containsKey('id_token'), isFalse);
    });

    test('one or the other: a passkey asked for in the place of the authenticator app says so, both times, and '
        'the refusals of the rule are told apart', () async {
      final client = api((r) => switch (r.url.path) {
            '/v1/account/passkeys/options' => (jsonDecode(r.body) as Map)['replace_authenticator'] == true
                ? json(200, {'challenge': 'Y2g'})
                : json(409, {'error': 'x', 'code': 'authenticator-app-on'}),
            '/v1/account/passkeys' =>
              json(502, {'error': 'x', 'code': 'authenticator-removed-passkey-failed', 'two_step': body}),
            _ => json(404, {}),
          });
      await expectLater(
        client.passkeyOptions(),
        throwsA(isA<TwoStepRefusal>()
            .having((e) => e.authenticatorOn, 'authenticatorOn', isTrue)
            .having((e) => e.authenticatorLost, 'authenticatorLost', isFalse)),
      );
      expect(jsonDecode(sent.last.body), <String, Object?>{});
      expect((await client.passkeyOptions(replaceAuthenticator: true))['challenge'], 'Y2g');
      expect(jsonDecode(sent.last.body), {'replace_authenticator': true});
      await expectLater(
        client.addPasskey(response: {'id': 'x'}, name: 'Pixel', idToken: 'handed', replaceAuthenticator: true),
        throwsA(isA<TwoStepRefusal>()
            .having((e) => e.authenticatorLost, 'authenticatorLost', isTrue)
            .having((e) => e.shownCode, 'shownCode', 'authenticator-removed-passkey-failed')),
      );
      expect(jsonDecode(sent.last.body),
          {'response': {'id': 'x'}, 'name': 'Pixel', 'id_token': 'handed', 'replace_authenticator': true});
    });

    test('the passkeys go for an authenticator app: DELETE /account/two-step/passkeys, with a computer\'s ID token',
        () async {
      final client = api((r) => json(200, {...body, 'passkeys': 0, 'signed_out': 2, 'notified': true}));
      final change = await client.removePasskeysForAuthenticator();
      expect('${sent.single.method} ${sent.single.url.path}', 'DELETE /v1/account/two-step/passkeys');
      expect(sent.single.body, isEmpty);
      expect(change.state.passkeys, 0);
      expect(change.state.on, isTrue, reason: 'on until the app is set up');
      expect(change.signedOut, 2);
      await client.removePasskeysForAuthenticator(idToken: 'handed');
      expect(jsonDecode(sent.last.body), {'id_token': 'handed'});
    });

    test('the list (kinds, synced, the day added, never a last-used time), rename and remove', () async {
      final client = api((r) => switch (r.method) {
            'GET' => json(200, {
                'passkeys': [
                  item,
                  {...item, 'id': 'a2V5', 'kind': 'security-key', 'synced': false},
                  {...item, 'id': 'aGVsbG8', 'kind': 'platform'},
                  {'name': 'no id'},
                ],
              }),
            'PATCH' => json(200, {...item, 'name': 'Work phone'}),
            _ => json(200, {'two_step': {...body, 'passkeys': 1}, 'signed_out': 2}),
          });
      final list = await client.passkeys();
      expect(list.map((p) => p.kind), [PasskeyKind.passkey, PasskeyKind.securityKey, PasskeyKind.platform]);
      expect(list[1].synced, isFalse);
      expect((await client.renamePasskey('a/b', 'Work phone')).name, 'Work phone');
      expect(sent.last.url.path, '/v1/account/passkeys/a%2Fb');
      final removed = await client.removePasskey('Y3JlZA', idToken: 'handed');
      expect(removed.state.passkeys, 1);
      expect(removed.signedOut, 2);
      expect(jsonDecode(sent.last.body), {'id_token': 'handed'});
    });

    test('the passkey step of a sign-in needs no sign-in, and its code is never in a message', () async {
      final client = api((r) => r.url.path.endsWith('/challenge')
          ? json(200, {'rpId': 'zestssh.com', 'challenge': 'Y2g'})
          : json(200, {'enrollment_id': 'totp-2', 'code': '123456'}),
          bearer: null);
      await client.passkeyChallenge(enrollmentId: 'totp-2', email: ' a@example.com ');
      expect(jsonDecode(sent.last.body), {'enrollment_id': 'totp-2', 'email': 'a@example.com'});
      expect(sent.last.headers.containsKey('Authorization'), isFalse);
      await client.passkeyChallenge(enrollmentId: 'totp-2');
      expect(jsonDecode(sent.last.body), {'enrollment_id': 'totp-2'}, reason: 'the address is optional');
      final released = await client.passkeyVerify(response: {'id': 'x'});
      expect((released.enrollmentId, released.code), ('totp-2', '123456'));
      expect('$released', isNot(contains('123456')));
      expect(sent.last.headers.containsKey('Authorization'), isFalse);

      await expectLater(
        api((_) => json(401, {'code': 'passkey-failed'}), bearer: null).passkeyVerify(response: {'id': 'x'}),
        throwsA(isA<TwoStepRefusal>().having((e) => e.code, 'code', 'passkey-failed')),
      );
      await expectLater(
        api((_) => json(404, {'code': 'passkeys-unavailable'}), bearer: null).passkeyChallenge(enrollmentId: 'x'),
        throwsA(isA<TwoStepRefusal>()
            .having((e) => e.code, 'code', 'passkeys-unavailable')
            .having((e) => e.routeMissing, 'routeMissing', isFalse)),
      );
    });
  });

  group('lock-out recovery', () {
    test('ask, confirm and complete: what each sends and gives back', () async {
      final client = api(
        (r) => switch (r.url.path) {
          '/v1/auth/lockout-recovery' => json(202, {'sent': true, 'ask_id': 'YXNr'}),
          '/v1/auth/lockout-recovery/confirm' => json(200, {
              'ticket': 'dGlja2V0',
              'completes_at': '2026-11-06T09:00:00.000Z',
              'proof': {'challenge': 'Y2hhbA', 'salt': base64Encode([1, 2, 3]), 'argon2_params': {'memory': 65536}},
            }),
          _ => json(200, {'recovered': true, 'with_data': true}),
        },
        bearer: null,
      );
      expect(await client.askLockoutRecovery(' sam@example.com '), 'YXNr');
      expect(jsonDecode(sent.last.body), {'email': 'sam@example.com'});
      final ticket = await client.confirmLockoutRecovery(email: 'sam@example.com', askId: 'YXNr', code: '1234 5678');
      expect(jsonDecode(sent.last.body), {'email': 'sam@example.com', 'ask_id': 'YXNr', 'code': '12345678'});
      expect(ticket.ticket, 'dGlja2V0');
      expect(ticket.completesAt.toUtc(), DateTime.utc(2026, 11, 6, 9));
      expect(ticket.proof!.challenge, 'Y2hhbA');
      expect(ticket.proof!.salt, [1, 2, 3]);
      expect(ticket.proof!.argon2Params, {'memory': 65536});
      expect(ticket.proof!.accountUid, isNull, reason: 'the server says none');
      expect('$ticket', isNot(contains('dGlja2V0')));
      expect(await client.completeLockoutRecovery(email: 'sam@example.com', ticket: 'dGlja2V0', proof: 'c2ln'), isTrue);
      expect(jsonDecode(sent.last.body), {'email': 'sam@example.com', 'ticket': 'dGlja2V0', 'proof': 'c2ln'});
      await client.completeLockoutRecovery(email: 'sam@example.com', ticket: 'dGlja2V0', reset: true);
      expect(jsonDecode(sent.last.body), {'email': 'sam@example.com', 'ticket': 'dGlja2V0', 'reset': true});
      for (final r in sent) {
        expect(r.headers.containsKey('Authorization'), isFalse, reason: 'nobody is signed in');
      }
    });

    test('its refusals carry the tries left and the day', () async {
      await expectLater(
        api((_) => json(400, {'code': 'recovery-proof-invalid', 'tries_left': 7}), bearer: null)
            .completeLockoutRecovery(email: 'a@example.com', ticket: 't', proof: 'p'),
        throwsA(isA<TwoStepRefusal>().having((e) => e.triesLeft, 'triesLeft', 7)),
      );
      await expectLater(
        api((_) => json(409, {'code': 'recovery-not-yet', 'completes_at': '2026-11-06T09:00:00.000Z'}), bearer: null)
            .completeLockoutRecovery(email: 'a@example.com', ticket: 't', reset: true),
        throwsA(isA<TwoStepRefusal>().having((e) => e.completesAt?.toUtc(), 'completesAt', DateTime.utc(2026, 11, 6, 9))),
      );
    });

    test("This wasn't me, and the recovery proof at unlock", () async {
      final client = api((r) => r.method == 'DELETE'
          ? json(200, {'cancelled': true})
          : json(200, {'registered': true, 'changed': true}));
      expect(await client.cancelLockoutRecovery(), isTrue);
      expect('${sent.last.method} ${sent.last.url.path}', 'DELETE /v1/account/lockout-recovery');
      expect(await client.registerRecoveryProof(publicKey: 'cGs', signature: 'c2ln', passwordHash: 'aGFzaA=='), isTrue);
      expect('${sent.last.method} ${sent.last.url.path}', 'PUT /v1/account/recovery-proof');
      expect(jsonDecode(sent.last.body), {'public_key': 'cGs', 'signature': 'c2ln', 'password_hash': 'aGFzaA=='});
    });
  });

  group("a computer's sign-in", () {
    test('the hand-off traded for its ID token, and the session traded up', () async {
      final client = api((r) => r.url.path.endsWith('/redeem')
          ? json(200, {'id_token': 'id-token'})
          : json(200, {'session_token': 'session-2', 'user': {'firebase_uid': 'uid-1'}}));
      expect(await client.redeemHandoff(code: 'c', verifier: 'v'), 'id-token');
      expect(jsonDecode(sent.last.body), {'code': 'c', 'verifier': 'v'});
      expect(sent.last.headers['Authorization'], 'Bearer tok', reason: 'this device\'s sign-in beside the code');
      expect(await client.upgradeSession(idToken: 'id-token'), 'session-2');
      expect(jsonDecode(sent.last.body), {'id_token': 'id-token'});
      expect(sent.last.headers['Authorization'], 'Bearer tok', reason: 'the session being traded');
      await client.upgradeSession(code: 'c', verifier: 'v');
      expect(jsonDecode(sent.last.body), {'code': 'c', 'verifier': 'v'});
    });
  });
}
