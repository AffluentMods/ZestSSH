import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';

/// Event export (3.0) as the app asks ZestSSH Cloud for what it
/// sends on: the activity read forward from the last note it has, and what
/// an invitation says about an Orchard that sends its events on.

void main() {
  http.Response json(int status, Object body) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  final asked = <http.Request>[];
  OrchardsApi api(Future<http.Response> Function(http.Request request) answer) => OrchardsApi(
        client: MockClient((request) {
          asked.add(request);
          return answer(request);
        }),
        baseUrl: 'https://api.test/v1',
        bearer: () async => 'token',
      );

  setUp(asked.clear);

  String b64(int fill, [int length = 40]) => base64Encode(List.filled(length, fill));

  test('the activity: forward from just after a note, or back from before one, or the newest', () async {
    final page = {
      'events': [
        {'id': 18, 'uid': 'alice', 'key_generation': 1, 'sealed': b64(1), 'at': '2026-10-02T08:00:00.000Z'},
        {'id': 19, 'uid': 'bob', 'key_generation': 2, 'sealed': b64(2), 'at': '2026-10-02T08:00:01.000Z'},
      ],
      'more': true,
    };
    final forward = await api((r) async => json(200, page)).activity('o-1', after: 17);
    expect((asked.single.method, '${asked.single.url}'), ('GET', 'https://api.test/v1/orchards/o-1/activity?after=17'));
    expect(asked.single.headers['Authorization'], 'Bearer token');
    expect([for (final e in forward.events) (e.id, e.uid, e.keyGeneration)], [(18, 'alice', 1), (19, 'bob', 2)],
        reason: 'in the order the server sent them');
    expect(forward.events.first.sealed, List.filled(40, 1));
    expect(forward.events.first.at, DateTime.utc(2026, 10, 2, 8));
    expect(forward.more, isTrue);

    asked.clear();
    await api((r) async => json(200, page)).activity('o-1', after: 0);
    expect('${asked.single.url}', 'https://api.test/v1/orchards/o-1/activity?after=0', reason: 'from the first there is');
    asked.clear();
    await api((r) async => json(200, page)).activity('o-1', before: 9);
    expect('${asked.single.url}', 'https://api.test/v1/orchards/o-1/activity?before=9');
    asked.clear();
    await api((r) async => json(200, page)).activity('o-1');
    expect('${asked.single.url}', 'https://api.test/v1/orchards/o-1/activity');
    // One way at a time: forward when both are given (the server refuses both).
    asked.clear();
    await api((r) async => json(200, page)).activity('o-1', before: 9, after: 3);
    expect('${asked.single.url}', 'https://api.test/v1/orchards/o-1/activity?after=3');

    // A note the app cannot read is left out; an answer that is no page is
    // an error, and a refusal comes with its code.
    final odd = await api((r) async => json(200, {
          'events': [
            'no event',
            {'id': '20', 'uid': 'alice', 'key_generation': 1, 'sealed': b64(1), 'at': '2026-10-02T08:00:00.000Z'},
            {'id': 20, 'uid': 7, 'key_generation': 1, 'sealed': b64(1), 'at': '2026-10-02T08:00:00.000Z'},
            {'id': 20, 'uid': 'alice', 'key_generation': 1, 'sealed': 'not base64 !', 'at': '2026-10-02T08:00:00.000Z'},
            {'id': 20, 'uid': 'alice', 'key_generation': 1, 'sealed': b64(1), 'at': 'yesterday'},
            {'id': 21, 'uid': 'alice', 'key_generation': 1, 'sealed': b64(3), 'at': '2026-10-02T08:00:02.000Z'},
          ],
          'more': false,
        })).activity('o-1', after: 19);
    expect([for (final e in odd.events) e.id], [21]);
    expect(odd.more, isFalse);
    await expectLater(api((r) async => json(200, {'events': <Object>[]})).activity('o-1', after: 1), throwsFormatException);
    await expectLater(
      api((r) async => json(409, {'code': 'activity-off'})).activity('o-1', after: 1),
      throwsA(isA<OrchardServerException>().having((e) => e.status, 'status', 409).having((e) => e.code, 'code', 'activity-off')),
    );
    await expectLater(
      api((r) async => json(403, {'code': 'owners-only'})).activity('o-1', after: 1),
      throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'owners-only')),
    );
  });

  test('an invitation says whether the Orchard sends its events on, and nothing else counts as yes', () async {
    Map<String, Object?> invite(String id, Object? exported, {bool leaveOut = false}) => {
          'id': id,
          'orchard_id': 'o-1',
          'role': 'admin',
          'crates': 2,
          'expires_at': '2026-11-01T00:00:00.000Z',
          'accepted': false,
          'tracking': {'history': false, 'activity': true, 'devices': false, 'ips': false},
          if (!leaveOut) 'exported': exported,
        };
    final mine = await api((r) async => json(200, {
          'invites': [
            invite('yes', true),
            invite('no', false),
            invite('missing', null, leaveOut: true),
            invite('word', 'true'),
            invite('number', 1),
            invite('null', null),
          ],
        })).myInvites();
    expect((asked.single.method, '${asked.single.url}'), ('GET', 'https://api.test/v1/invites'));
    expect({for (final i in mine) i.id: i.exported},
        {'yes': true, 'no': false, 'missing': false, 'word': false, 'number': false, 'null': false});
    expect(mine.every((i) => i.tracking.activity), isTrue);
  });

  test('an invitation says how many of the Crates offered have their sessions watched, and only a number counts',
      () async {
    Map<String, Object?> invite(String id, Object? watched, {bool leaveOut = false}) => {
          'id': id,
          'orchard_id': 'o-1',
          'role': 'admin',
          'crates': 3,
          'expires_at': '2026-11-01T00:00:00.000Z',
          'accepted': false,
          'session_logs': 1,
          if (!leaveOut) 'watched': watched,
        };
    final mine = await api((r) async => json(200, {
          'invites': [
            invite('two', 2),
            invite('none', 0),
            invite('missing', null, leaveOut: true),
            invite('word', '2'),
            invite('yes', true),
            invite('null', null),
          ],
        })).myInvites();
    expect({for (final i in mine) i.id: i.watched},
        {'two': 2, 'none': 0, 'missing': 0, 'word': 0, 'yes': 0, 'null': 0});
    expect(mine.every((i) => i.sessionLogs == 1), isTrue, reason: 'one count is not read as the other');
  });
}
