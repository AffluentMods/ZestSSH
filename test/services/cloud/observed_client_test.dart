import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/services/cloud/observed_client.dart';

/// The one client every request to ZestSSH Cloud goes through tells how
/// each of them went (3.0), so that the app knows how the
/// service stands without any of the parts that talk to it having to say.
void main() {
  const base = 'https://api.zestssh.com/v1';
  late List<(int?, Object?)> heard;
  late http.Response Function(http.Request request) answer;
  late Object? fails;
  late int sent;

  setUp(() {
    heard = [];
    answer = (_) => http.Response('{"ok":true}', 200);
    fails = null;
    sent = 0;
  });

  ObservedClient client({CloudExchangeListener? Function()? listener}) => ObservedClient(
        MockClient((request) async {
          sent++;
          final failure = fails;
          if (failure != null) throw failure;
          return answer(request);
        }),
        watches: (url) => isCloudExchange(url, apiBase: base),
        listener: listener ?? () => (status, error) => heard.add((status, error)),
      );

  group('a request to the service', () {
    test('that is answered: the status is told, whatever it is, and the answer is the caller\'s as it came', () async {
      for (final status in [200, 204, 401, 404, 409, 500, 503]) {
        answer = (_) => http.Response('body $status', status, headers: {'x-kept': 'yes'});
        final response = await client().get(Uri.parse('$base/orchards'));
        expect(response.statusCode, status);
        expect(response.body, 'body $status');
        expect(response.headers['x-kept'], 'yes');
      }
      expect(heard.map((h) => h.$1), [200, 204, 401, 404, 409, 500, 503]);
      expect(heard.every((h) => h.$2 == null), isTrue);
    });

    test('that gets no answer: what was thrown is told, and thrown on as it was', () async {
      const refused = SocketException('Connection refused');
      fails = refused;
      await expectLater(client().get(Uri.parse('$base/keys/me')), throwsA(same(refused)));
      expect(heard, [(null, refused)]);
    });

    test('goes out as it was made: nothing is changed on the way', () async {
      late http.Request seen;
      answer = (request) {
        seen = request;
        return http.Response('', 204);
      };
      await client().post(Uri.parse('$base/sync/push'), headers: {'authorization': 'Bearer demo'}, body: 'payload');
      expect(seen.method, 'POST');
      expect(seen.url.toString(), '$base/sync/push');
      expect(seen.headers['authorization'], 'Bearer demo');
      expect(seen.body, 'payload');
      expect(sent, 1, reason: 'sent once: nothing is tried again here');
    });

    test('with nobody listening, or a listener that fails: the request is none the worse', () async {
      expect((await client(listener: () => null).get(Uri.parse('$base/orchards'))).statusCode, 200);
      final failing = client(listener: () => (_, _) => throw StateError('a listener of its own'));
      expect((await failing.get(Uri.parse('$base/orchards'))).statusCode, 200);
      fails = const SocketException('Connection refused');
      await expectLater(failing.get(Uri.parse('$base/orchards')), throwsA(isA<SocketException>()));
    });

    test('who listens is asked at the end of each request, so one set later hears from then on', () async {
      CloudExchangeListener? current;
      final observed = client(listener: () => current);
      await observed.get(Uri.parse('$base/orchards'));
      expect(heard, isEmpty);
      current = (status, error) => heard.add((status, error));
      await observed.get(Uri.parse('$base/orchards'));
      expect(heard, hasLength(1));
    });
  });

  // Requests had a timeout and no limit: an answer of any length was held in
  // memory (found in a security review).
  group('an answer past its cap', () {
    ObservedClient over(Stream<List<int>> body, {int? contentLength}) => ObservedClient(
          MockClient.streaming((request, _) async => http.StreamedResponse(body, 200, contentLength: contentLength)),
          watches: (url) => isCloudExchange(url, apiBase: base),
          listener: () => null,
        );

    Stream<List<int>> megabytes(int count) => Stream.fromIterable(List.generate(count, (_) => List<int>.filled(1024 * 1024, 65)));

    test('that says so: refused at once with its code, its body unread', () async {
      var read = false;
      final body = Stream<List<int>>.fromFuture(Future(() {
        read = true;
        return const <int>[];
      }));
      await expectLater(
        over(body, contentLength: kMaxApiReplyBytes + 1).get(Uri.parse('$base/account')),
        throwsA(isA<CloudReplyTooLarge>().having((e) => '$e', 'what it says', contains(ErrorCodes.cloudReplyTooLarge.code))),
      );
      expect(read, isFalse);
    });

    test('that says nothing: stopped as it comes', () async {
      await expectLater(over(megabytes(17)).get(Uri.parse('$base/account')), throwsA(isA<CloudReplyTooLarge>()));
    });

    test('sync and a team, which carry records, have the larger cap; under each cap an answer is whole', () async {
      expect((await over(megabytes(17)).get(Uri.parse('$base/sync/pull'))).bodyBytes, hasLength(17 * 1024 * 1024));
      expect((await over(megabytes(17)).get(Uri.parse('$base/orchards/o-1/changes'))).bodyBytes, hasLength(17 * 1024 * 1024));
      expect((await over(megabytes(1)).get(Uri.parse('$base/account'))).bodyBytes, hasLength(1024 * 1024));
      await expectLater(
        over(const Stream.empty(), contentLength: kMaxBulkReplyBytes + 1).get(Uri.parse('$base/sync/pull')),
        throwsA(isA<CloudReplyTooLarge>()),
      );
    });

    test('a request to anywhere else has the larger cap too', () async {
      await expectLater(
        over(const Stream.empty(), contentLength: kMaxBulkReplyBytes + 1).get(Uri.parse('https://sync.northwind.example/v1/x')),
        throwsA(isA<CloudReplyTooLarge>()),
      );
    });
  });

  group('what is not told', () {
    test('a request to anything else: another host, a person\'s own sync server, Google', () async {
      for (final url in [
        'https://zestssh.com/app/latest.json',
        'https://sync.northwind.example/v1/sync/status',
        'https://www.googleapis.com/drive/v3/files',
        'https://api.zestssh.com.evil.example/v1/orchards',
      ]) {
        await client().get(Uri.parse(url));
      }
      fails = const SocketException('Connection refused');
      await expectLater(client().get(Uri.parse('https://sync.northwind.example/v1/sync/status')),
          throwsA(isA<SocketException>()));
      expect(heard, isEmpty, reason: 'only ZestSSH Cloud says how ZestSSH Cloud stands');
      expect(sent, 5, reason: 'and they are sent all the same');
    });

    test('the health check: that is the question itself, read where it is asked', () async {
      await client().get(Uri.parse('$base/health'));
      fails = const SocketException('Connection refused');
      await expectLater(client().get(Uri.parse('$base/health')), throwsA(isA<SocketException>()));
      expect(heard, isEmpty);
    });
  });

  group('which requests are the service\'s', () {
    test('its host, in any case of letters, on any of its paths but the health check', () {
      expect(isCloudExchange(Uri.parse('https://api.zestssh.com/v1/orchards'), apiBase: base), isTrue);
      expect(isCloudExchange(Uri.parse('https://API.ZestSSH.com/v1/sync/push'), apiBase: base), isTrue);
      expect(isCloudExchange(Uri.parse('https://api.zestssh.com/v1/health'), apiBase: base), isFalse);
      expect(isCloudExchange(Uri.parse('https://api.zestssh.com/v1/healthy'), apiBase: base), isTrue);
    });

    test('another host is not, however much its name looks like it', () {
      for (final url in [
        'https://zestssh.com/v1/orchards',
        'https://api.zestssh.com.example/v1/orchards',
        'https://xapi.zestssh.com/v1/orchards',
      ]) {
        expect(isCloudExchange(Uri.parse(url), apiBase: base), isFalse, reason: url);
      }
    });

    test('a build that names another address for the service is held to that one, port and all', () {
      const local = 'http://127.0.0.1:8787/v1';
      expect(isCloudExchange(Uri.parse('http://127.0.0.1:8787/v1/orchards'), apiBase: local), isTrue);
      expect(isCloudExchange(Uri.parse('http://127.0.0.1:9999/v1/orchards'), apiBase: local), isFalse);
      expect(isCloudExchange(Uri.parse('https://api.zestssh.com/v1/orchards'), apiBase: local), isFalse);
    });

    test('an address that is none at all watches nothing', () {
      expect(isCloudExchange(Uri.parse('https://api.zestssh.com/v1/orchards'), apiBase: ''), isFalse);
      expect(isCloudExchange(Uri.parse('https://api.zestssh.com/v1/orchards'), apiBase: 'not an address'), isFalse);
    });
  });
}
