import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/features/cloud_import/cloud_http.dart';

/// Cloud import (3.0): the one way requests reach a provider. No redirects
/// (a token would follow them), https only, capped answers, timeouts, and
/// error details that never hold a secret.

void main() {
  final url = Uri.https('api.example.com', '/v1/list');

  test('a redirect is never followed and the request asks for none', () async {
    var calls = 0;
    bool? followed;
    final client = CloudHttp(MockClient((req) async {
      calls++;
      followed = req.followRedirects;
      return http.Response('', 302, headers: {'location': 'https://evil.example/steal'});
    }));
    await expectLater(
      client.send('GET', url, headers: {'Authorization': 'Bearer secret-token'}),
      throwsA(isA<CloudError>().having((e) => e.kind, 'kind', CloudErrorKind.server).having((e) => e.status, 'status', 302)),
    );
    expect(calls, 1);
    expect(followed, isFalse);
  });

  test('https only: anything else is refused before a request is made', () async {
    var calls = 0;
    final client = CloudHttp(MockClient((req) async {
      calls++;
      return http.Response('{}', 200);
    }));
    await expectLater(client.send('GET', Uri.parse('http://api.example.com/x')),
        throwsA(isA<CloudError>().having((e) => e.kind, 'kind', CloudErrorKind.notAllowed)));
    expect(calls, 0);
  });

  test('statuses become kinds', () async {
    for (final (status, kind) in [
      (401, CloudErrorKind.signIn),
      (403, CloudErrorKind.notAllowed),
      (404, CloudErrorKind.notFound),
      (429, CloudErrorKind.tooMany),
      (500, CloudErrorKind.server),
      (418, CloudErrorKind.server),
    ]) {
      final client = CloudHttp(MockClient((req) async => http.Response('no', status)));
      await expectLater(client.send('GET', url), throwsA(isA<CloudError>().having((e) => e.kind, 'kind', kind)), reason: '$status');
    }
    final ok = CloudHttp(MockClient((req) async => http.Response('fine', 204)));
    expect(await ok.send('GET', url), 'fine');
  });

  test('details say what was asked and what came back, with every secret blanked', () async {
    final client = CloudHttp(
      MockClient((req) async => http.Response('bad token secret-token-123 for user', 401)),
      secrets: ['secret-token-123', 'abc'],
    )..hide('late-access-token');
    try {
      await client.send('GET', Uri.https('api.example.com', '/v1/list', {'q': 'late-access-token'}));
      fail('no error');
    } on CloudError catch (e) {
      expect(e.detail, contains('GET https://api.example.com/v1/list'));
      expect(e.detail, contains('-> 401'));
      expect(e.detail, contains('[hidden]'));
      expect(e.detail, isNot(contains('secret-token-123')));
      expect(e.detail, isNot(contains('late-access-token')));
    }
    // Short strings are never "secrets" (they would blank ordinary words).
    expect(client.scrub('abc'), 'abc');
  });

  test('an answer larger than the cap stops reading', () async {
    final client = CloudHttp(MockClient((req) async => http.Response('x' * 5000, 200)), maxBytes: 1000);
    await expectLater(client.send('GET', url), throwsA(isA<CloudError>().having((e) => e.kind, 'kind', CloudErrorKind.answer)));
  });

  test('no answer in time, no network, and not JSON', () async {
    final slow = CloudHttp(
      MockClient((req) async {
        await Future<void>.delayed(const Duration(seconds: 2));
        return http.Response('{}', 200);
      }),
      timeout: const Duration(milliseconds: 50),
    );
    await expectLater(slow.send('GET', url), throwsA(isA<CloudError>().having((e) => e.kind, 'kind', CloudErrorKind.timeout)));

    final offline = CloudHttp(MockClient((req) async => throw const SocketException('Connection refused')));
    await expectLater(offline.send('GET', url), throwsA(isA<CloudError>().having((e) => e.kind, 'kind', CloudErrorKind.offline)));

    final certificate = CloudHttp(MockClient((req) async => throw const HandshakeException('CERTIFICATE_VERIFY_FAILED')));
    await expectLater(certificate.send('GET', url), throwsA(isA<CloudError>().having((e) => e.kind, 'kind', CloudErrorKind.certificate)));

    final html = CloudHttp(MockClient((req) async => http.Response('<html>login</html>', 200)));
    await expectLater(html.json('GET', url), throwsA(isA<CloudError>().having((e) => e.kind, 'kind', CloudErrorKind.answer)));
  });

  test('JSON answers are asked for and read', () async {
    String? accept;
    final client = CloudHttp(MockClient((req) async {
      accept = req.headers['Accept'];
      return http.Response('{"a":[1]}', 200);
    }));
    expect(await client.json('GET', url), {
      'a': [1],
    });
    expect(accept, 'application/json');
  });
}
