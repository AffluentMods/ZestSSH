import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/services/account/browser_handoff.dart';
import 'package:zestssh/services/account/two_step_api.dart';
import 'package:zestssh/services/desktop_auth_server.dart';
import 'package:zestssh/services/desktop_browser_sign_in.dart';
import 'package:zestssh/services/sign_in_code.dart';

/// A computer's browser hand-offs for two-step sign-in (3.3; the two-step
/// contract, sections 3.1 and 7.12): a fresh sign-in handed over as a
/// one-time code for this app's challenge (purpose=id-token), traded within
/// two minutes for the ID token and checked to be the signed-in account's;
/// and zestssh.com's security page adding a passkey for Linux and the Mac
/// (purpose=add-passkey), which comes back with done=1 or cancelled=1 and
/// nothing else.
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

  /// A browser that, once the app waits, goes back to the link's address
  /// with [back] and the link's state, as the website does.
  Future<void> Function(Uri link) browser(Map<String, String> back, {List<Uri>? opened, List<Future<Object>>? pages}) =>
      (link) async {
        opened?.add(link);
        final page = Future(() => get(Uri.parse(link.queryParameters['redirect']!)
            .replace(queryParameters: {...back, 'state': link.queryParameters['state']!})));
        pages?.add(page);
        unawaited(page.then((_) {}, onError: (Object _) {}));
      };

  group("the computer's callback", () {
    Future<(Future<Map<String, String>>, ({int status, String body}))> callBack(Map<String, String> query) async {
      final auth = DesktopAuthServer();
      addTearDown(auth.stop);
      final url = Uri.parse(await auth.start(nonce: 'n0nce'));
      final got = auth.waitForCallback()..ignore();
      return (got, await get(url.replace(queryParameters: {...query, 'state': 'n0nce'})));
    }

    test('the security page back with done=1 or cancelled=1, and nothing else', () async {
      var (got, page) = await callBack({'done': '1'});
      expect(await got, {'done': '1'});
      expect(page.status, 200);
      expect(page.body, contains('Back to ZestSSH'));
      (got, page) = await callBack({'cancelled': '1'});
      expect(await got, {'cancelled': '1'});
    });

    test('a hand-off code says what it is for', () async {
      final (got, _) = await callBack({'code': 'c0de', 'kind': 'id-token', 'uid': 'uid-1', 'email': 'a@example.com'});
      expect(await got, {'code': 'c0de', 'kind': 'id-token', 'uid': 'uid-1', 'email': 'a@example.com'});
    });
  });

  group('a fresh sign-in handed to the app (purpose=id-token)', () {
    test('the link asks for it with a challenge; the code comes back with the secret, never the token', () async {
      final opened = <Uri>[];
      final back = await DesktopBrowserSignIn.idTokenHandoff(
          open: browser({'code': 'c0de', 'kind': 'id-token', 'uid': 'uid-1'}, opened: opened));
      final link = opened.single;
      expect(link.queryParameters['purpose'], 'id-token');
      expect(link.queryParameters['platform'], 'desktop');
      expect(link.queryParameters['state'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(link.queryParameters['redirect'], startsWith('http://127.0.0.1:'));
      expect(link.queryParameters['redirect'], endsWith('/callback'));
      expect(back.code, 'c0de');
      expect(back.uid, 'uid-1');
      expect(SignInCode.challengeOf(back.verifier), link.queryParameters['challenge']);
      expect(link.toString(), isNot(contains(back.verifier)), reason: 'the secret stays here');
    });

    test('anything but a hand-off code is not taken', () async {
      await expectLater(DesktopBrowserSignIn.idTokenHandoff(open: browser({'code': 'session-code'})),
          throwsA(isA<AuthCallbackError>()));
      await expectLater(DesktopBrowserSignIn.idTokenHandoff(open: browser({'token': 'a-session-token'})),
          throwsA(isA<AuthCallbackError>()));
    });

    String jwt(Map<String, Object> claims) =>
        'x.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.y';

    test("the ID token's account is read from it, and only the signed-in account's is used", () async {
      expect(idTokenUid(jwt({'user_id': 'uid-1', 'sub': 'uid-1'})), 'uid-1');
      expect(idTokenUid(jwt({'sub': 'uid-2'})), 'uid-2');
      expect(idTokenUid('not.a.token'), isNull);
      expect(idTokenUid('fb:uid:1:2'), isNull);

      final redeemed = <Map<String, dynamic>>[];
      TwoStepApi cloud(String token) => TwoStepApi(
            baseUrl: 'https://api.test/v1',
            bearer: () async => 'tok',
            client: MockClient((request) async {
              expect(request.url.path, '/v1/auth/handoff/redeem');
              expect(request.headers['Authorization'], 'Bearer tok', reason: 'this device\'s sign-in beside the code');
              redeemed.add(jsonDecode(request.body) as Map<String, dynamic>);
              return http.Response(jsonEncode({'id_token': token}), 200, headers: {'cache-control': 'no-store'});
            }),
          );
      final mine = jwt({'user_id': 'uid-1'});
      expect(
        await handedIdToken(
            api: cloud(mine), accountUid: 'uid-1', handoff: () async => (code: 'c', verifier: 'v', uid: 'uid-1')),
        mine,
      );
      expect(redeemed.single, {'code': 'c', 'verifier': 'v'});
      await expectLater(
        handedIdToken(
            api: cloud(jwt({'user_id': 'uid-9'})),
            accountUid: 'uid-1',
            handoff: () async => (code: 'c', verifier: 'v', uid: null)),
        throwsA(isA<HandoffWrongAccount>()),
      );
      redeemed.clear();
      await expectLater(
        handedIdToken(api: cloud(mine), accountUid: 'uid-1', handoff: () async => (code: 'c', verifier: 'v', uid: 'uid-9')),
        throwsA(isA<HandoffWrongAccount>()),
      );
      expect(redeemed, isEmpty, reason: "another account's code is not even traded");
    });

    test('a code that ran out is said by its code', () async {
      final api = TwoStepApi(
        baseUrl: 'https://api.test/v1',
        bearer: () async => 'tok',
        client: MockClient((_) async => http.Response(jsonEncode({'code': 'sign-in-code-invalid'}), 400)),
      );
      await expectLater(
        handedIdToken(api: api, accountUid: 'uid-1', handoff: () async => (code: 'c', verifier: 'v', uid: 'uid-1')),
        throwsA(isA<TwoStepRefusal>().having((e) => e.code, 'code', 'sign-in-code-invalid')),
      );
    });
  });

  group('adding a passkey in the browser (purpose=add-passkey)', () {
    test("the security page's link, with the app's loopback address and its state; done=1 is added", () async {
      final opened = <Uri>[];
      final pages = <Future<Object>>[];
      expect(await DesktopBrowserSignIn.addPasskeyInBrowser(open: browser({'done': '1'}, opened: opened, pages: pages)),
          isTrue);
      final link = opened.single;
      expect(link.scheme, 'https');
      expect(link.host, 'zestssh.com');
      expect(link.path, '/account/security');
      expect(link.queryParameters['purpose'], 'add-passkey');
      expect(link.queryParameters['redirect'], matches(RegExp(r'^http://127\.0\.0\.1:[0-9]+/callback$')));
      // The website takes 16 to 256 of A-Z a-z 0-9 . _ ~ - (the contract, 7.12).
      expect(link.queryParameters['state'], matches(RegExp(r'^[A-Za-z0-9._~-]{16,256}$')));
      final page = await pages.single as ({int status, String body});
      expect(page.body, contains('Back to ZestSSH'));
    });

    test('cancelled=1, or Cancel in the app, adds nothing', () async {
      expect(await DesktopBrowserSignIn.addPasskeyInBrowser(open: browser({'cancelled': '1'})), isFalse);
      final waiting = DesktopBrowserSignIn.addPasskeyInBrowser(open: (_) async {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(DesktopBrowserSignIn.pending.value?.uri.path, '/account/security');
      DesktopBrowserSignIn.cancel();
      await expectLater(waiting, throwsA(isA<BrowserSignInCancelled>()));
      expect(DesktopBrowserSignIn.pending.value, isNull);
    });
  });
}
