import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart' show CrateLevel;
import 'package:zestssh/features/orchards/sync/crate_server.dart';

/// Requests for access (3.0) as the app says them to ZestSSH Cloud
/// and reads its answers: what a request carries and what it leaves out, the
/// two lists (one the app cannot read is left out, never guessed at), and
/// the refusals with their codes.

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

  Map<String, Object?> made({String? crateId, String level = 'use', Object? seconds = 7200}) => {
        'id': 'r-1',
        'crate_id': crateId,
        'level': level,
        'seconds': seconds,
        'note_enc': null,
        'note_gen': null,
        'expires_at': 1800000000,
      };

  test('asking: the Crate when it can be named, how far, how long, and the note with the key it is under', () async {
    final note = Uint8List.fromList([1, 2, 3, 250]);
    final request = await api((request) async => json(201, {
          ...made(),
          'note_enc': base64Encode(note),
          'note_gen': 3,
        })).requestAccess('o-1', level: CrateLevel.use, seconds: 7200, noteEnc: note, noteGeneration: 3);
    expect((asked.single.method, '${asked.single.url}'), ('POST', 'https://api.test/v1/orchards/o-1/access-requests'));
    expect(asked.single.headers['Authorization'], 'Bearer token');
    expect(asked.single.headers['Content-Type'], startsWith('application/json'));
    expect(jsonDecode(asked.single.body), {'level': 'use', 'seconds': 7200, 'note_enc': base64Encode(note), 'note_gen': 3},
        reason: 'no Crate: it could not be named');
    expect((request.id, request.crateId, request.level, request.seconds, request.expiresAt, request.uid),
        ('r-1', null, CrateLevel.use, 7200, 1800000000, null));
    expect(request.noteEnc, note);
    expect(request.noteGeneration, 3);

    // More in a Crate it opens: named, and no note.
    asked.clear();
    final more = await api((request) async => json(200, made(crateId: 'c-1', level: 'edit', seconds: 300)))
        .requestAccess('o-1', crateId: 'c-1', level: CrateLevel.edit, seconds: 300);
    expect(jsonDecode(asked.single.body), {'crate_id': 'c-1', 'level': 'edit', 'seconds': 300});
    expect((more.crateId, more.level, more.seconds, more.noteEnc, more.noteGeneration),
        ('c-1', CrateLevel.edit, 300, null, null));
    asked.clear();
    await api((request) async => json(200, made(level: 'connect'))).requestAccess('o-1', level: CrateLevel.connect, seconds: 600);
    expect(jsonDecode(asked.single.body), {'level': 'connect', 'seconds': 600});
  });

  test('asking: a refusal comes with its code, and an answer that is no request is not taken for one', () async {
    for (final code in ['request-limit', 'access-not-needed']) {
      await expectLater(
        api((request) async => json(409, {'code': code})).requestAccess('o-1', level: CrateLevel.use, seconds: 7200),
        throwsA(isA<OrchardServerException>()
            .having((e) => e.status, 'status', 409)
            .having((e) => e.code, 'code', code)),
      );
    }
    await expectLater(
      api((request) async => json(429, {'error': 'Too many requests'}))
          .requestAccess('o-1', level: CrateLevel.use, seconds: 7200),
      throwsA(isA<OrchardServerException>().having((e) => e.status, 'status', 429).having((e) => e.code, 'code', null)),
    );
    await expectLater(
      api((request) async => json(201, {'ok': true})).requestAccess('o-1', level: CrateLevel.use, seconds: 7200),
      throwsFormatException,
    );
    // A request to manage is never one.
    await expectLater(
      api((request) async => json(201, made(level: 'manage'))).requestAccess('o-1', level: CrateLevel.use, seconds: 7200),
      throwsFormatException,
    );
  });

  test('the lists: this account\'s own, and those waiting for its answer with who asks', () async {
    final note = base64Encode([9, 8, 7]);
    final lists = await api((request) async => json(200, {
          'mine': [
            {...made(crateId: 'c-1', level: 'edit'), 'id': 'mine-1'},
            {...made(), 'id': 'mine-2', 'note_enc': note, 'note_gen': 2},
          ],
          'waiting': [
            {...made(level: 'connect', seconds: 300), 'id': 'w-1', 'uid': 'alice', 'note_enc': note, 'note_gen': 1},
            {...made(crateId: 'c-2'), 'id': 'w-2', 'uid': 'bob'},
          ],
        })).accessRequests('o-1');
    expect((asked.single.method, '${asked.single.url}'), ('GET', 'https://api.test/v1/orchards/o-1/access-requests'));
    expect(asked.single.headers['Authorization'], 'Bearer token');
    expect([for (final r in lists.mine) (r.id, r.crateId, r.level, r.seconds, r.noteGeneration, r.uid)], [
      ('mine-1', 'c-1', CrateLevel.edit, 7200, null, null),
      ('mine-2', null, CrateLevel.use, 7200, 2, null),
    ]);
    expect(lists.mine[1].noteEnc, [9, 8, 7]);
    expect([for (final r in lists.waiting) (r.id, r.crateId, r.level, r.seconds, r.noteGeneration, r.uid, r.expiresAt)], [
      ('w-1', null, CrateLevel.connect, 300, 1, 'alice', 1800000000),
      ('w-2', 'c-2', CrateLevel.use, 7200, null, 'bob', 1800000000),
    ]);
    expect(lists.waiting[0].noteEnc, [9, 8, 7]);
  });

  test('the lists: one the app cannot read is left out, and the rest are kept', () async {
    final good = {...made(), 'uid': 'alice'};
    Future<AccessRequests> read(List<Object?> mine, List<Object?> waiting) =>
        api((request) async => json(200, {'mine': mine, 'waiting': waiting})).accessRequests('o-1');

    final odd = <Object?>[
      'r-1',
      {...good, 'id': 7},
      {...good, 'crate_id': 7},
      {...good, 'level': 'manage'},
      {...good, 'level': 'own'},
      {...good, 'level': null},
      {...good, 'seconds': 0},
      {...good, 'seconds': -300},
      {...good, 'seconds': '7200'},
      {...good, 'seconds': 7200.5},
      {...good, 'expires_at': '2026-10-08'},
      {...good, 'expires_at': null},
      {...good, 'uid': 7},
      // A note and the key it is under come together or not at all.
      {...good, 'note_enc': base64Encode([1])},
      {...good, 'note_gen': 1},
      {...good, 'note_enc': 'not base64!', 'note_gen': 1},
      {...good, 'note_enc': 7, 'note_gen': 1},
      {...good, 'note_enc': base64Encode([1]), 'note_gen': '1'},
    ];
    final lists = await read([...odd, {...made(), 'id': 'mine-ok'}], [...odd, {...good, 'id': 'w-ok'}]);
    expect([for (final r in lists.mine) r.id], ['mine-ok']);
    expect([for (final r in lists.waiting) r.id], ['w-ok']);

    // One that waits says who asks, or it is not shown.
    expect((await read([], [made()])).waiting, isEmpty);
    // Its own never does (the server names nobody there), and is kept.
    expect((await read([made()], [])).mine.single.uid, isNull);
  });

  test('the lists: an answer without them is not an empty list', () async {
    for (final body in <Map<String, Object?>>[
      {},
      {'mine': <Object>[]},
      {'waiting': <Object>[]},
      {'mine': <Object>[], 'waiting': 'none'},
      {'mine': {}, 'waiting': <Object>[]},
    ]) {
      await expectLater(api((request) async => json(200, body)).accessRequests('o-1'), throwsFormatException,
          reason: '$body');
    }
    await expectLater(
      api((request) async => json(403, {'code': 'rules-unmet', 'unmet': ['two_step']})).accessRequests('o-1'),
      throwsA(isA<OrchardServerException>()
          .having((e) => e.code, 'code', 'rules-unmet')
          .having((e) => e.unmet, 'unmet', ['two_step'])),
    );
  });

  test('withdrawing or declining: the request by its id, and nothing comes back', () async {
    await api((request) async => http.Response('', 204)).deleteAccessRequest('o-1', 'r-9');
    expect((asked.single.method, '${asked.single.url}'),
        ('DELETE', 'https://api.test/v1/orchards/o-1/access-requests/r-9'));
    expect(asked.single.headers['Authorization'], 'Bearer token');
    expect(asked.single.body, isEmpty);

    await expectLater(
      api((request) async => json(404, {'code': 'not-found'})).deleteAccessRequest('o-1', 'r-9'),
      throwsA(isA<OrchardServerException>().having((e) => e.status, 'status', 404).having((e) => e.code, 'code', 'not-found')),
    );
    // Only "gone" is the answer: anything else is not taken for it.
    await expectLater(
      api((request) async => json(200, {'ok': true})).deleteAccessRequest('o-1', 'r-9'),
      throwsA(isA<OrchardServerException>().having((e) => e.status, 'status', 200)),
    );
  });

  test('signed out, nothing is asked', () async {
    final signedOut = OrchardsApi(
      client: MockClient((request) async {
        asked.add(request);
        return json(200, {'mine': <Object>[], 'waiting': <Object>[]});
      }),
      baseUrl: 'https://api.test/v1',
      bearer: () async => null,
    );
    await expectLater(signedOut.accessRequests('o-1'),
        throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'signed-out')));
    await expectLater(signedOut.requestAccess('o-1', level: CrateLevel.use, seconds: 7200),
        throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'signed-out')));
    await expectLater(signedOut.deleteAccessRequest('o-1', 'r-9'),
        throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'signed-out')));
    expect(asked, isEmpty);
  });
}
