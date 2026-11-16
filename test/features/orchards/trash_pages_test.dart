import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';

/// A team vault's trash is read a page at a time (4.0; found in a security
/// review). The server ends a page at 500 items or 8 MB of records,
/// says "more" and where it ended ("next"), and takes that back as ?after=.
/// The app read one answer and stopped, so of a large trash it would have
/// listed the newest deletions only.
void main() {
  const crate = '11111111-2222-4333-8444-555555555555';
  final asked = <Uri>[];

  Map<String, dynamic> trashed(int n) {
    final id = '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
    Map<String, dynamic> version(bool deleted, int revision) => {
          'revision': revision,
          'key_generation': 1,
          'deleted': deleted,
          'record': base64Encode(List.filled(8, n)),
          'signature': base64Encode(List.filled(64, 7)),
        };
    return {
      'item_id': id,
      'deletion': version(true, 100 + n),
      'last': version(false, n),
      'kept_until': '2026-12-${(n % 28 + 1).toString().padLeft(2, '0')}T10:00:00.000Z',
    };
  }

  OrchardsApi api(Map<String, dynamic> Function(String? after) answer) {
    asked.clear();
    return OrchardsApi(
      baseUrl: 'https://api.example.com/v1',
      bearer: () async => 'demo-token',
      client: MockClient((request) async {
        asked.add(request.url);
        expect(request.url.path, '/v1/crates/$crate/trash');
        return http.Response(jsonEncode(answer(request.url.queryParameters['after'])), 200,
            headers: {'content-type': 'application/json'});
      }),
    );
  }

  test('a trash that says "more" is read on from where each page ended, every item once, in order', () async {
    const first = '2026-11-14T10:00:00.000003_00000000-0000-4000-8000-000000000003';
    const second = '2026-11-14T09:00:00.000005_00000000-0000-4000-8000-000000000005';
    final server = api((after) => switch (after) {
          null => {'items': [trashed(1), trashed(2), trashed(3)], 'more': true, 'next': first, 'key_generation': 1},
          first => {'items': [trashed(4), trashed(5)], 'more': true, 'next': second, 'key_generation': 1},
          second => {'items': [trashed(6)], 'key_generation': 1},
          _ => throw StateError('asked for $after'),
        });
    final items = await server.trash(crate);
    expect([for (final i in items) i.itemId.substring(35)], ['1', '2', '3', '4', '5', '6']);
    expect(asked, hasLength(3));
    expect(asked[0].hasQuery, isFalse, reason: 'the first page is asked for as before');
    expect(asked[1].queryParameters['after'], first);
    expect(asked[2].queryParameters['after'], second);
  });

  test('a server from before 4.0 answers the whole trash and no word of more: one request', () async {
    final server = api((after) => {'items': [trashed(1), trashed(2)], 'key_generation': 1});
    expect(await server.trash(crate), hasLength(2));
    expect(asked, hasLength(1));
  });

  test('a "next" that does not move on, or a page with nothing in it, ends the reading', () async {
    const stuck = '2026-11-14T10:00:00.000001_00000000-0000-4000-8000-000000000001';
    var server = api((after) => {'items': [trashed(1)], 'more': true, 'next': stuck, 'key_generation': 1});
    expect(await server.trash(crate), hasLength(1), reason: 'the same item again is listed once');
    expect(asked, hasLength(2), reason: 'asked once more, and the same place came back');

    server = api((after) => after == null
        ? {'items': [trashed(1)], 'more': true, 'next': stuck, 'key_generation': 1}
        : {'items': <Object>[], 'more': true, 'next': '${stuck}x', 'key_generation': 1});
    expect(await server.trash(crate), hasLength(1));
    expect(asked, hasLength(2));
  });

  test('a server that never says it is done is read 64 pages and no further', () async {
    var n = 0;
    final server = api((after) {
      n++;
      return {
        'items': [trashed(n)],
        'more': true,
        'next': '2026-11-14T10:00:00.${n.toString().padLeft(6, '0')}_00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}',
        'key_generation': 1,
      };
    });
    expect(await server.trash(crate), hasLength(64));
    expect(asked, hasLength(64));
  });
}
