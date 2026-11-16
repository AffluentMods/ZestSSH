// ZestSSH Cloud's routes for sharing a session, as the app calls them
// (share_api.dart): what each request carries, and what the app makes of
// each answer. The same calls run against the real routes in
// share_contract_test.dart.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/sharing/share_api.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/services/account/device_sessions.dart';

const shareId = '11111111-1111-4111-8111-111111111111';
const crateId = '33333333-3333-4333-8333-333333333333';

void main() {
  final requests = <http.Request>[];
  var answer = http.Response('{}', 200);

  ShareApi api({String? token = 'token-1'}) => ShareApi(
        client: MockClient((request) async {
          requests.add(request);
          return answer;
        }),
        baseUrl: 'https://api.example.test/v1',
        bearer: () async => token,
      );

  setUp(() {
    requests.clear();
    answer = http.Response('{}', 200);
    DeviceSessionHeader.current = null;
  });

  tearDown(() => DeviceSessionHeader.current = null);

  http.Response json(int status, Object body) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  test('starting a share: its id, the Crate, the way, and each sealed invitation by account', () async {
    answer = json(201, {'id': shareId, 'expires_in': 43200});
    DeviceSessionHeader.current = 'device-7';
    await api().create(
      id: shareId,
      crateId: crateId,
      mode: ShareMode.live,
      invites: {
        'uid-sam': Uint8List.fromList([1, 2, 3]),
        'uid-kit': Uint8List.fromList([250, 251, 252, 253]),
      },
    );
    final r = requests.single;
    expect((r.method, r.url.toString()), ('POST', 'https://api.example.test/v1/shares'));
    expect(r.headers['Authorization'], 'Bearer token-1');
    expect(r.headers['X-ZestSSH-Session'], 'device-7');
    expect(r.headers['Content-Type'], startsWith('application/json'));
    expect(jsonDecode(r.body), {
      'id': shareId,
      'crate_id': crateId,
      'mode': 'live',
      'invites': [
        {'uid': 'uid-sam', 'sealed': 'AQID'},
        {'uid': 'uid-kit', 'sealed': base64Encode([250, 251, 252, 253])},
      ],
    });

    // A shared tmux session says so; a retry answered 200 is a success too.
    requests.clear();
    answer = json(200, {'id': shareId, 'expires_in': 43100});
    await api().create(id: shareId, crateId: crateId, mode: ShareMode.tmux, invites: {'uid-sam': Uint8List.fromList([9])});
    expect(jsonDecode(requests.single.body)['mode'], 'tmux');
  });

  test('inviting more, taking one back, declining and stopping go to the share by its id', () async {
    final a = api();
    await a.invite(shareId, {'uid-noa': Uint8List.fromList([7, 7])});
    expect((requests.last.method, requests.last.url.path), ('POST', '/v1/shares/$shareId/invites'));
    expect(jsonDecode(requests.last.body), {
      'invites': [
        {'uid': 'uid-noa', 'sealed': 'Bwc='},
      ],
    });
    expect(requests.last.headers['Content-Type'], startsWith('application/json'));

    // An account id is whatever the sign-in provider made it: it goes into
    // the address as one piece.
    await a.removeInvite(shareId, 'uid/with space?');
    expect(requests.last.method, 'DELETE');
    expect(requests.last.url.toString(),
        'https://api.example.test/v1/shares/$shareId/invites/uid%2Fwith%20space%3F');
    expect(requests.last.body, isEmpty);
    expect(requests.last.headers.containsKey('X-ZestSSH-Session'), isFalse, reason: 'this device has no registration');

    await a.end(shareId);
    expect((requests.last.method, requests.last.url.path), ('DELETE', '/v1/shares/$shareId'));
    expect(requests.length, 3);
  });

  test('the invitations waiting: read as listed, and what is not an invitation is left out', () async {
    Map<String, Object?> entry({Object? mode = 'live', Object? sealed = 'AQID', Object? expires = 600}) => {
          'share_id': shareId,
          'orchard_id': 'orchard-1',
          'crate_id': crateId,
          'mode': mode,
          'from': 'uid-dana',
          'sealed': sealed,
          'expires_in': expires,
        };
    answer = json(200, {
      'invites': [
        entry(),
        entry(mode: 'tmux', expires: -5),
        entry(mode: 'screen'), // a way of sharing this version does not know
        entry(sealed: 'not base64!'),
        entry(sealed: ''),
        entry(sealed: base64Encode(List.filled(kShareSealedMax + 1, 1))),
        entry(sealed: base64Encode(List.filled(kShareSealedMax, 1))),
        entry(expires: '600'),
        {...entry(), 'share_id': 7},
        {...entry(), 'orchard_id': null},
        {...entry()}..remove('crate_id'),
        {...entry()}..remove('from'),
        'nonsense',
        null,
      ],
    });
    final list = await api().invitations();
    expect((requests.single.method, requests.single.url.path), ('GET', '/v1/shares/invites'));
    expect(requests.single.headers.containsKey('Content-Type'), isFalse);
    expect(list.length, 3);
    final first = list[0];
    expect((first.shareId, first.orchardId, first.crateId, first.mode, first.fromUid),
        (shareId, 'orchard-1', crateId, ShareMode.live, 'uid-dana'));
    expect(first.sealed, [1, 2, 3]);
    expect(first.expiresIn, const Duration(seconds: 600));
    expect((list[1].mode, list[1].expiresIn), (ShareMode.tmux, Duration.zero), reason: 'never a time in the past');
    expect(list[2].sealed.length, kShareSealedMax);

    answer = json(200, {'invites': <Object>[]});
    expect(await api().invitations(), isEmpty);
    // An answer that is no list at all is not "nothing waits".
    answer = json(200, {'ok': true});
    await expectLater(api().invitations(), throwsFormatException);
  });

  test('what the server refuses becomes an error the app can tell apart', () async {
    Future<OrchardServerException> refused(http.Response r) async {
      answer = r;
      try {
        await api().create(id: shareId, crateId: crateId, mode: ShareMode.live, invites: const {});
      } on OrchardServerException catch (e) {
        return e;
      }
      fail('not refused');
    }

    // Someone invited cannot open the Crate: who.
    final none = await refused(json(409, {'code': 'no-access', 'uids': ['uid-eve', 7, 'uid-mal']}));
    expect(none, isA<ShareNoAccess>());
    expect((none as ShareNoAccess).uids, ['uid-eve', 'uid-mal']);
    expect((none.status, none.code), (409, 'no-access'));
    expect((await refused(json(409, {'code': 'no-access'})) as ShareNoAccess).uids, isEmpty);
    // The same words with another status are not that.
    expect(await refused(json(403, {'code': 'no-access', 'uids': ['uid-eve']})), isNot(isA<ShareNoAccess>()));

    for (final (status, code) in [
      (404, 'not-found'),
      (409, 'id-taken'),
      (409, 'share-full'),
      (429, 'too-many-shares'),
      (429, 'rate-limited'),
      (400, 'invalid-request'),
    ]) {
      final e = await refused(json(status, {'code': code}));
      expect((e.status, e.code), (status, code));
      expect(e, isNot(isA<ShareNoAccess>()));
      expect(e.notFound, status == 404);
    }
    // The Orchard's rules hold this account back: which ones.
    final held = await refused(json(403, {'code': 'rules-unmet', 'unmet': ['two_step', 3, 'reauth']}));
    expect((held.status, held.code), (403, 'rules-unmet'));
    expect(held.unmet, ['two_step', 'reauth']);
    // An answer that is not JSON, or says nothing: the status alone.
    final gateway = await refused(http.Response('<html>Bad gateway</html>', 502));
    expect((gateway.status, gateway.code), (502, null));
    final odd = await refused(json(500, ['not', 'an', 'object']));
    expect((odd.status, odd.code), (500, null));
    final numbered = await refused(json(500, {'code': 17}));
    expect(numbered.code, isNull);
  });

  test('signed out: nothing is sent', () async {
    await expectLater(
      api(token: null).invitations(),
      throwsA(isA<OrchardServerException>()
          .having((e) => e.status, 'status', 401)
          .having((e) => e.code, 'code', 'signed-out')),
    );
    await expectLater(api(token: null).end(shareId), throwsA(isA<OrchardServerException>()));
    expect(requests, isEmpty);
  });

  test('an answer saying this device was signed out elsewhere is passed on to the app', () async {
    final before = sessionRevokedSignal.value;
    answer = json(401, {'code': 'session-revoked'});
    await expectLater(api().invitations(),
        throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'session-revoked')));
    expect(sessionRevokedSignal.value, before + 1);
    // Any other refusal is not that.
    answer = json(401, {'code': 'invalid-token'});
    await expectLater(api().end(shareId), throwsA(isA<OrchardServerException>()));
    expect(sessionRevokedSignal.value, before + 1);
  });
}
