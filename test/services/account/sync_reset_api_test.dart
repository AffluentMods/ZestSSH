import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/services/account/sync_reset_api.dart';

/// Asking ZestSSH Cloud to reset an account's cloud sync (3.0): what is
/// sent, and what each answer is taken for.
void main() {
  const base = 'https://api.example.test/v1';

  /// An API whose server answers every request with [answer], and the
  /// requests it was sent.
  (SyncResetApi, List<http.Request>) apiAnswering(http.Response Function(http.Request) answer) {
    final sent = <http.Request>[];
    final api = SyncResetApi(
      baseUrl: base,
      client: MockClient((request) async {
        sent.add(request);
        return answer(request);
      }),
    );
    return (api, sent);
  }

  http.Response json(int status, Map<String, dynamic> body) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  Future<SyncResetException> refusal(http.Response answer) async {
    final (api, _) = apiAnswering((_) => answer);
    try {
      await api.reset(token: 'fresh-token', confirmUid: 'uid-1');
    } on SyncResetException catch (e) {
      return e;
    }
    fail('the reset was taken for done');
  }

  test('it asks for the account the person chose, with the fresh sign-in, and takes what was done', () async {
    final (api, sent) = apiAnswering((_) => json(200, {'success': true, 'had_data': true, 'kept_days': 30}));
    final result = await api.reset(token: 'fresh-token', confirmUid: 'uid-1');

    expect(sent, hasLength(1));
    final request = sent.single;
    expect(request.method, 'POST');
    expect(request.url.toString(), '$base/account/reset-sync');
    expect(request.headers['Authorization'], 'Bearer fresh-token');
    expect(request.headers['Content-Type'], startsWith('application/json'));
    expect(jsonDecode(request.body), {'confirm_uid': 'uid-1'});
    expect(result.hadData, isTrue);
    expect(result.keptDays, 30);
  });

  test('an account that held no cloud copy is told so', () async {
    final (api, _) = apiAnswering((_) => json(200, {'success': true, 'had_data': false, 'kept_days': 30}));
    final result = await api.reset(token: 't', confirmUid: 'u');
    expect(result.hadData, isFalse);
  });

  test('a server that does not say for how long it keeps the copy: no number is made up', () async {
    for (final kept in [null, 0, -3, '30', 2.5]) {
      final (api, _) = apiAnswering((_) => json(200, {'success': true, 'had_data': true, 'kept_days': ?kept}));
      expect((await api.reset(token: 't', confirmUid: 'u')).keptDays, 0, reason: '$kept');
    }
  });

  test('the server\'s own reasons are passed on by their codes', () async {
    final stale = await refusal(json(403, {'error': 'Sign in again to reset cloud sync', 'code': 'recent-sign-in-required'}));
    expect(stale.code, 'recent-sign-in-required');
    expect(stale.detail, 'HTTP 403: Sign in again to reset cloud sync');

    final other = await refusal(json(409, {'error': 'That sign-in belongs to a different account', 'code': 'account-mismatch'}));
    expect(other.code, 'account-mismatch');
  });

  test('a server from before a reset could be asked for is known as one', () async {
    expect((await refusal(http.Response('Cannot POST /v1/account/reset-sync', 404))).code, 'server-outdated');
    expect((await refusal(http.Response('', 405))).code, 'server-outdated');
  });

  test('an answer without a reason is a server error, with what was answered kept', () async {
    final broke = await refusal(json(500, {'error': 'Internal server error'}));
    expect(broke.code, 'server-error');
    expect(broke.detail, 'HTTP 500: Internal server error');
    // Nothing was caught: what stopped it is the answer, with its status,
    // for whoever says how the service stands.
    expect(broke.cause, isNull);
    expect(broke.stopped, 'HTTP 500: Internal server error');
  });

  test('a 200 that is not the server\'s yes is not taken for one', () async {
    expect((await refusal(http.Response('<html>Sign in to the network</html>', 200))).code, 'server-error');
    expect((await refusal(json(200, {'had_data': true, 'kept_days': 30}))).code, 'server-error');
    expect((await refusal(json(200, {'success': 'true', 'had_data': true}))).code, 'server-error');
  });

  test('a yes under a status that is no 200 is not taken for one either', () async {
    final odd = await refusal(json(500, {'success': true, 'had_data': true, 'kept_days': 30}));
    expect(odd.code, 'server-error');
    expect(odd.detail, startsWith('HTTP 500'));
  });

  test('a server that cannot be reached is the network, with what was thrown kept', () async {
    final api = SyncResetApi(
      baseUrl: base,
      client: MockClient((_) async => throw const SocketException('Connection refused')),
    );
    await expectLater(
      api.reset(token: 't', confirmUid: 'u'),
      throwsA(isA<SyncResetException>()
          .having((e) => e.code, 'code', 'network')
          .having((e) => e.detail, 'detail', contains('Connection refused'))
          // What was caught itself, and not only its words: which kind of
          // failure it was is told by what it is.
          .having((e) => e.cause, 'cause', isA<SocketException>())
          .having((e) => e.stopped, 'stopped', isA<SocketException>())),
    );
  });
}
