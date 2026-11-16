import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/features/orchards/sso/orchard_sso_api.dart';
import 'package:zestssh/services/desktop_auth_server.dart';
import 'package:zestssh/services/desktop_browser_sign_in.dart';
import 'package:zestssh/services/sign_in_code.dart';
import 'package:zestssh/utils/logger.dart';

/// A computer's sign-in in the browser with a one-time code (found in a
/// security review): the browser went back to the
/// app with the 30-day session token in the callback's address, kept in the
/// browser's history, and an owner's test of its company sign-in with the ID
/// token. Now the link carries a challenge, the browser comes back with a
/// code, and the app trades the code with its secret.
void main() {
  /// The browser at [url]: what the page said.
  Future<({int status, String body})> get(Uri url) async {
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(url)).close();
      return (status: response.statusCode, body: await response.transform(utf8.decoder).join());
    } finally {
      client.close(force: true);
    }
  }

  /// What the website does at the end of the sign-in [link] opened: sends
  /// the browser back to the app's address with [back] and the link's state.
  Future<({int status, String body})> visit(Uri link, Map<String, String> back) => get(
      Uri.parse(link.queryParameters['redirect']!).replace(queryParameters: {...back, 'state': link.queryParameters['state']!}));

  /// A browser that comes back with [back] once the app waits, as one does.
  Future<void> Function(Uri link) browser(Map<String, String> back, {List<Uri>? opened, List<Future<Object>>? pages}) =>
      (link) async {
        opened?.add(link);
        final page = Future(() => visit(link, back));
        pages?.add(page);
        unawaited(page.then((_) {}, onError: (Object _) {}));
      };

  test("the challenge is the secret's SHA-256 in base64url, as RFC 7636 says", () {
    // RFC 7636, appendix B.
    expect(SignInCode.challengeOf('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
    final a = SignInCode.make();
    final b = SignInCode.make();
    expect(a.verifier, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    expect(a.challenge, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    expect(a.challenge, SignInCode.challengeOf(a.verifier));
    expect(a.verifier, isNot(b.verifier), reason: 'a new secret each sign-in');
  });

  group('trading a code', () {
    late List<http.Request> sent;
    MockClient server(int status, Object body) => MockClient((request) async {
          sent.add(request);
          return http.Response(body is String ? body : jsonEncode(body), status);
        });

    setUp(() => sent = []);

    test('sends the code and the secret, and gets the session and the account', () async {
      final code = SignInCode.make();
      final session = await code.redeem('the-code',
          client: server(200, {
            'session_token': 'jwt',
            'user': {'email': 'alex@example.com', 'display_name': 'Alex', 'firebase_uid': 'uid-1'},
          }));
      expect(session.token, 'jwt');
      expect(session.user, {'email': 'alex@example.com', 'name': 'Alex', 'uid': 'uid-1'});
      expect(sent.single.method, 'POST');
      expect(sent.single.url.path, endsWith('/auth/session/redeem'));
      expect(jsonDecode(sent.single.body), {'code': 'the-code', 'verifier': code.verifier});
    });

    test('a code refused, or an answer that is not one, is said so', () async {
      final code = SignInCode.make();
      await expectLater(
          code.redeem('used', client: server(400, {'code': 'sign-in-code-invalid'})),
          throwsA(isA<SignInCodeRefused>()
              .having((e) => e.status, 'status', 400)
              .having((e) => e.code, 'code', 'sign-in-code-invalid')));
      await expectLater(code.redeem('x', client: server(502, '<html>Bad gateway</html>')),
          throwsA(isA<SignInCodeRefused>().having((e) => e.status, 'status', 502)));
      await expectLater(code.redeem('x', client: server(200, {'user': {}})), throwsA(isA<SignInCodeRefused>()),
          reason: 'no token in the answer');
    });
  });

  group("the computer's callback", () {
    /// The server waiting, and the browser coming back with [query]: what
    /// the app got, and what the page said.
    Future<(Future<Map<String, String>>, ({int status, String body}))> callBack(Map<String, String> query) async {
      final auth = DesktopAuthServer();
      addTearDown(auth.stop);
      final url = Uri.parse(await auth.start(nonce: 'n0nce'));
      final got = auth.waitForCallback()..ignore();
      return (got, await get(url.replace(queryParameters: {...query, 'state': 'n0nce'})));
    }

    test('takes a code from a website that got the challenge, and the page arrives whole', () async {
      final (got, page) = await callBack({'code': 'the-code', 'email': 'alex@example.com'});
      expect(await got, {'code': 'the-code', 'email': 'alex@example.com'});
      expect(page.status, 200);
      expect(page.body, contains('Signed in to ZestSSH'));
      expect(page.body.trimRight(), endsWith('</html>'));
    });

    test('and the token itself from a website from before', () async {
      final (got, page) = await callBack({'token': 'the-token'});
      expect(await got, {'token': 'the-token'});
      expect(page.status, 200);
    });

    test('with neither, says the token is missing, on the page too', () async {
      final (got, page) = await callBack({'email': 'x@example.com'});
      await expectLater(got,
          throwsA(isA<AuthCallbackError>().having((e) => e.kind, 'kind', AuthCallbackErrorKind.missingToken)));
      expect(page.status, 400);
      expect(page.body, contains('Sign-in didn&#39;t return a token'));
      expect(page.body.trimRight(), endsWith('</html>'));
    });

    test("the website's word that it did not work ends the wait at once, with its code and what was said", () async {
      final (got, page) = await callBack(
          {'error': 'It did not work', 'error_code': 'auth/invalid-credential', 'error_detail': 'Firebase: Error.'});
      await expectLater(
          got,
          throwsA(isA<BrowserSignInFailed>()
              .having((e) => e.code, 'code', 'auth/invalid-credential')
              .having((e) => e.detail, 'detail', 'Firebase: Error.')));
      expect(page.status, 200);
      expect(page.body, contains('That did not work'));
    });

    // Found in a security review.
    test('names no parameter the sender made up in the log, only how many came', () async {
      AppLogger.init();
      AppLogger.forget();
      final (got, _) = await callBack({'token': 'the-token', 'x\u001b[31mFAKE\nINFO: made up': '1', 'zz': '2'});
      await got;
      final said = AppLogger.recent().where((l) => l.contains('callback hit')).single;
      expect(said, contains('[state, token, +2 other]'));
      expect(said, isNot(contains('FAKE')));
      expect(said, isNot(contains('zz')));
      expect(DesktopAuthServer.paramsForLog({'code': 'c', 'state': 's'}), ['code', 'state']);
    });

    test('Cancel ends the wait, and the address answers nothing after', () async {
      final auth = DesktopAuthServer();
      addTearDown(auth.stop);
      final url = Uri.parse(await auth.start(nonce: 'n0nce'));
      final got = auth.waitForCallback();
      auth.cancel();
      await expectLater(got, throwsA(isA<BrowserSignInCancelled>()));
      await expectLater(get(url.replace(queryParameters: {'state': 'n0nce', 'code': 'late'})), throwsA(anything));
    });
  });

  group('signing in in the browser', () {
    /// ZestSSH Cloud trading codes: only [code], only with the secret of the
    /// challenge in the link the browser [opened]; [user] is what it says of
    /// the account.
    MockClient cloud(List<Uri> opened, List<Map<Object?, Object?>> traded,
            {String code = 'the-code', Map<String, String>? user}) =>
        MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          traded.add(body);
          if (body['code'] != code ||
              SignInCode.challengeOf(body['verifier'] as String) != opened.single.queryParameters['challenge']) {
            return http.Response(jsonEncode({'code': 'sign-in-code-invalid'}), 400);
          }
          return http.Response(
              jsonEncode({
                'session_token': 'jwt',
                'user': user ?? {'email': 'alex@example.com', 'display_name': 'Alex', 'firebase_uid': 'uid-1'},
              }),
              200);
        });

    test("the link carries a challenge; the code is traded with its secret for the session, in ZestSSH Cloud's words",
        () async {
      final opened = <Uri>[];
      final traded = <Map<Object?, Object?>>[];
      final pages = <Future<Object>>[];
      final session = await DesktopBrowserSignIn.session(
        open: browser({
          'code': 'the-code',
          'email': 'stale@example.com',
          'name': 'Stale',
          'picture': 'https://example.com/a.png',
          'uid': 'stale',
        }, opened: opened, pages: pages),
        client: cloud(opened, traded),
      );
      expect(session.token, 'jwt');
      expect((session.email, session.name, session.uid, session.picture),
          ('alex@example.com', 'Alex', 'uid-1', 'https://example.com/a.png'));
      final link = opened.single;
      expect(link.queryParameters['challenge'], matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(link.queryParameters['state'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(link.queryParameters['redirect'], startsWith('http://127.0.0.1:'));
      expect(link.toString(), isNot(contains(traded.single['verifier'] as String)), reason: 'the secret stays here');
      final page = await pages.single as ({int status, String body});
      expect(page.status, 200);
      expect(page.body, contains('Signed in to ZestSSH'), reason: 'the page arrives whole');
    });

    test('a callback with a token and an account id but no code opens nothing', () async {
      final traded = <Map<Object?, Object?>>[];
      await expectLater(
        DesktopBrowserSignIn.session(
          open: browser({'token': 'made-up', 'uid': 'uid-2', 'email': 'robin@example.com'}),
          client: cloud([], traded),
        ),
        throwsA(isA<AuthCallbackError>().having((e) => e.kind, 'kind', AuthCallbackErrorKind.missingToken)),
      );
      expect(traded, isEmpty, reason: 'nothing was traded, so nothing was signed in');
    });

    test('a code ZestSSH Cloud does not take is said so; a sign-in with no account id proves nothing', () async {
      final opened = <Uri>[];
      await expectLater(
          DesktopBrowserSignIn.session(open: browser({'code': 'spent'}, opened: opened), client: cloud(opened, [])),
          throwsA(isA<SignInCodeRefused>().having((e) => e.code, 'code', 'sign-in-code-invalid')));

      opened.clear();
      await expectLater(
          DesktopBrowserSignIn.run(
              open: browser({'code': 'the-code'}, opened: opened),
              client: cloud(opened, [], user: {'email': 'morgan@example.com'})),
          throwsA(isA<StateError>()));

      opened.clear();
      final done = await DesktopBrowserSignIn.run(
          open: browser({'code': 'the-code', 'uid': 'stale'}, opened: opened),
          client: cloud(opened, [], user: {'email': 'morgan@example.com', 'firebase_uid': 'uid-3'}));
      expect((done.token, done.uid, done.email), ('jwt', 'uid-3', 'morgan@example.com'));
    });

    test("Confirm it's you: the address and the way go after the #, so no server's log holds them",
        () async {
      final opened = <Uri>[];
      await DesktopBrowserSignIn.run(
          confirm: const BrowserConfirm('sam+zest@example.com', way: 'google.com'),
          open: browser({'code': 'the-code', 'uid': 'uid-3'}, opened: opened),
          client: cloud(opened, [], user: {'email': 'sam+zest@example.com', 'firebase_uid': 'uid-3'}));
      final page = opened.first;
      expect(page.fragment, 'confirm=1&email=sam%2Bzest%40example.com&via=google.com');
      expect(page.query, isNot(contains('example.com')));
      expect(page.query, isNot(contains('google.com')));
      expect(page.query, isNot(contains('confirm')));
      expect(page.queryParameters['challenge'], isNotEmpty);

      opened.clear();
      await DesktopBrowserSignIn.run(
          confirm: const BrowserConfirm('sam@example.com'),
          open: browser({'code': 'the-code', 'uid': 'uid-3'}, opened: opened),
          client: cloud(opened, [], user: {'email': 'sam@example.com', 'firebase_uid': 'uid-3'}));
      expect(opened.first.fragment, 'confirm=1&email=sam%40example.com');

      opened.clear();
      await DesktopBrowserSignIn.run(
          open: browser({'code': 'the-code', 'uid': 'uid-3'}, opened: opened),
          client: cloud(opened, [], user: {'email': 'sam@example.com', 'firebase_uid': 'uid-3'}));
      expect(opened.first.fragment, isEmpty, reason: 'a sign-in that is no confirmation says nothing of it');
    });

    test('how a session signed in: only a hint for which way to show first', () {
      String tokenWith(Map<String, Object?> claims) =>
          'h.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.s';
      expect(sessionSignInWay(tokenWith({'provider': 'google.com'})), 'google.com');
      expect(sessionSignInWay(tokenWith({'provider': 'password'})), 'password');
      expect(sessionSignInWay(tokenWith({})), isNull);
      expect(sessionSignInWay(tokenWith({'provider': 7})), isNull);
      expect(sessionSignInWay('not a token'), isNull);
      expect(sessionSignInWay(null), isNull);
    });

    test("an owner's test of its company sign-in: the link asks for it with a challenge, and a code and the secret go "
        'to the test', () async {
      const provider = 'saml.zo-0123456789abcdef0123456789abcdef';
      final opened = <Uri>[];
      final proof = await DesktopBrowserSignIn.ssoTest(provider,
          open: browser({'code': 'test-code', 'email': 'owner@example.com', 'kind': 'sso-test'}, opened: opened));
      final link = opened.single;
      expect(link.queryParameters['mode'], 'sso-test');
      expect(link.queryParameters['provider'], provider);
      expect(SignInCode.challengeOf(proof.verifier!), link.queryParameters['challenge']);
      expect(proof.idToken, isNull);
      expect(proof.body, {'code': 'test-code', 'verifier': proof.verifier});
      expect(const SsoTestSignIn.idToken('id-token').body, {'id_token': 'id-token'});

      // A website from before hands the ID token itself: not taken.
      await expectLater(
          DesktopBrowserSignIn.ssoTest(provider, open: browser({'token': 'id-token'})), throwsA(isA<StateError>()));
      await expectLater(DesktopBrowserSignIn.ssoTest('google.com', open: browser({'code': 'x'})), throwsArgumentError);
    });
  });

  group('against ZestSSH Cloud (the stand-in backend)', () {
    final base = Platform.environment['ZESTSSH_TEST_API'] ?? 'http://127.0.0.1:39200/v1';
    final client = http.Client();
    var serverUp = false;
    int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
    const skip = 'app contract server (with sign-in codes) not running at the test API';

    setUpAll(() async {
      try {
        final r = await client
            .post(Uri.parse('$base/auth/session/redeem'), headers: {'Content-Type': 'application/json'}, body: '{}')
            .timeout(const Duration(seconds: 2));
        serverUp = r.statusCode == 400 && r.body.contains('sign-in-code-invalid');
      } catch (_) {
        serverUp = false;
      }
    });

    /// The website signing in as [uid] with the link's challenge, which gets
    /// it a code and no token.
    Future<Map<Object?, Object?>> exchange(String uid, String challenge) async {
      final r = await client.post(Uri.parse('$base/auth/session'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'id_token': 'fb:$uid:${now()}:${now()}', 'challenge': challenge}));
      expect(r.statusCode, 200, reason: r.body);
      final body = jsonDecode(r.body) as Map;
      expect(body.containsKey('session_token'), isFalse, reason: 'no token goes to the browser');
      return body;
    }

    test("a sign-in in the browser: the code the website got for the link's challenge gives this app a session",
        () async {
      if (!serverUp) return markTestSkipped(skip);
      final uid = 'n5-${now()}';
      final session = await DesktopBrowserSignIn.session(
        open: (link) async {
          unawaited(Future(() async {
            final got = await exchange(uid, link.queryParameters['challenge']!);
            await visit(link, {'code': got['code'] as String});
          }));
        },
        client: client,
        baseUrl: base,
      );
      final claims =
          jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(session.token.split('.')[1])))) as Map;
      expect(claims['firebaseUid'], uid);
      expect(claims['sid'], isNotNull, reason: 'a listed session');
      expect((session.uid, session.email), (uid, '$uid@example.com'));
      final listed =
          await client.get(Uri.parse('$base/sessions'), headers: {'Authorization': 'Bearer ${session.token}'});
      expect(listed.statusCode, 200, reason: listed.body);
    });

    test('a code is good once, and only with the secret of its challenge', () async {
      if (!serverUp) return markTestSkipped(skip);
      final uid = 'n5-once-${now()}';
      final secret = SignInCode.make();
      final code = (await exchange(uid, secret.challenge))['code'] as String;
      await expectLater(SignInCode.make().redeem(code, client: client, baseUrl: base),
          throwsA(isA<SignInCodeRefused>().having((e) => e.code, 'code', 'sign-in-code-invalid')));
      await expectLater(secret.redeem(code, client: client, baseUrl: base), throwsA(isA<SignInCodeRefused>()),
          reason: 'spent by the wrong secret');
      final next = (await exchange(uid, secret.challenge))['code'] as String;
      final got = await secret.redeem(next, client: client, baseUrl: base);
      expect(got.user['uid'], uid);
      await expectLater(secret.redeem(next, client: client, baseUrl: base), throwsA(isA<SignInCodeRefused>()),
          reason: 'good once');
    });
  });
}
