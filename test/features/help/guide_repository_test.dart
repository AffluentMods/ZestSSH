import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/features/help/guides/guide_repository.dart';

/// A guide's words come from the docs site when it is opened, and a copy is
/// kept for offline (Help > Guides, 3.0). The request is a plain GET of the
/// guide's raw Markdown, with nothing about the person in it.
void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('guides_test'));
  tearDown(() => root.deleteSync(recursive: true));

  GuideRepository repo(MockClientHandler handler) => GuideRepository(
        client: MockClient(handler),
        copies: FileGuideCopies(root: () async => root),
        timeout: const Duration(milliseconds: 300),
      );

  test('fetches the raw Markdown from the docs site, with no identifiers, and keeps a copy', () async {
    late http.BaseRequest seen;
    final r = repo((req) async {
      seen = req;
      return http.Response('## In plain words\n\nHello.', 200);
    });
    expect(await r.saved('keys'), isNull);
    expect(await r.fetch('keys'), '## In plain words\n\nHello.');
    expect(seen.method, 'GET');
    expect(seen.url.toString(), 'https://docs.zestssh.com/guides/keys.md');
    expect(seen.followRedirects, isFalse);
    // Nothing but what to accept: no cookie, no sign-in, no device or user id.
    expect(seen.headers.keys.map((k) => k.toLowerCase()).toSet(), {'accept'});
    final saved = await r.saved('keys');
    expect(saved!.markdown, '## In plain words\n\nHello.');
    expect(File('${root.path}/guides/keys.md').existsSync(), isTrue);
    expect(File('${root.path}/guides/keys.md.part').existsSync(), isFalse);
  });

  test('no answer is ZS-1960, and the copy kept earlier stays', () async {
    var online = true;
    final r = repo((req) async {
      if (!online) throw const SocketException('Failed host lookup');
      return http.Response('## Saved', 200);
    });
    await r.fetch('sftp');
    online = false;
    await expectLater(
      r.fetch('sftp'),
      throwsA(isA<GuideFetchFailure>().having((e) => e.code, 'code', ErrorCodes.guideNotReached)),
    );
    expect((await r.saved('sftp'))!.markdown, '## Saved');
  });

  test('a request that times out is ZS-1960', () async {
    final r = repo((req) => Completer<http.Response>().future);
    await expectLater(
      r.fetch('keys'),
      throwsA(isA<GuideFetchFailure>().having((e) => e.code, 'code', ErrorCodes.guideNotReached)),
    );
  });

  test('a client failure is ZS-1960', () async {
    final r = repo((req) async => throw http.ClientException('Connection reset'));
    await expectLater(
      r.fetch('keys'),
      throwsA(isA<GuideFetchFailure>().having((e) => e.code, 'code', ErrorCodes.guideNotReached)),
    );
  });

  test('a page not found, a redirect, a web page, a huge answer or no text is ZS-1961, and nothing is kept', () async {
    final answers = <http.Response>[
      http.Response('Not found', 404),
      http.Response('', 301, headers: {'location': 'https://elsewhere.example/'}),
      http.Response('<!DOCTYPE html><html><body>404</body></html>', 200),
      http.Response('x' * (GuideRepository.maxBytes + 1), 200),
      http.Response.bytes([0xff, 0xfe, 0xfd], 200),
    ];
    for (final answer in answers) {
      final r = repo((req) async => answer);
      final failure = await r.fetch('alerts').then<GuideFetchFailure?>((_) => null, onError: (Object e) => e as GuideFetchFailure);
      expect(failure, isNotNull, reason: '${answer.statusCode}');
      expect(failure!.code, ErrorCodes.guideUnreadable, reason: '${answer.statusCode}');
      if (answer.statusCode != 200) expect(failure.status, answer.statusCode);
      expect(failure.toString(), contains('ZS-1961'));
      expect(await r.saved('alerts'), isNull);
    }
  });

  test('a slug that is no guide is never fetched or read', () async {
    var asked = false;
    final r = repo((req) async {
      asked = true;
      return http.Response('x', 200);
    });
    expect(await r.saved('../secrets'), isNull);
    expect(() => r.fetch('../secrets'), throwsArgumentError);
    expect(asked, isFalse);
  });

  test('a device with no folder for copies shows the guide all the same', () async {
    final r = GuideRepository(
      client: MockClient((req) async => http.Response('## Hi', 200)),
      copies: FileGuideCopies(root: () async => null),
    );
    expect(await r.fetch('keys'), '## Hi');
    expect(await r.saved('keys'), isNull);
  });
}
