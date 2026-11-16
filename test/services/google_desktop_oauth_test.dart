import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/google_desktop_oauth.dart';
import 'package:zestssh/services/sync/google_drive_sync_backend.dart';
import 'package:zestssh/services/sync_service.dart' show SyncException;

/// Google Drive sign-in on a computer. A bug in 2.2.1 on Windows:
/// choosing Google Drive for sync failed with a MissingPluginException,
/// because the Google plugin the phones use does not exist there. A computer
/// signs in through the browser instead. Here Google is played by a fake
/// token endpoint and the browser by a function that does what a browser
/// would: follow Google's redirect to the listener on this computer.

const _drive = GoogleDriveSyncBackend.appDataScope;

class _Memory implements GoogleTokenStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
  @override
  Future<void> delete() async => value = null;
}

String _idToken(String email) {
  String part(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'RS256'})}.${part({'email': email})}.signature';
}

/// GET [url] the way a browser following a redirect would.
Future<(int, String)> _browse(Uri url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(url);
    final response = await request.close();
    return (response.statusCode, await utf8.decodeStream(response));
  } finally {
    client.close(force: true);
  }
}

/// Everything a test needs to watch one sign-in.
class _Google {
  _Google({
    this.grantedScope = '$_drive openid https://www.googleapis.com/auth/userinfo.email',
    this.refreshToken = 'refresh-1',
    this.browserAnswers,
  });

  final String grantedScope;
  final String? refreshToken;

  /// What the browser sends back, given the authorization URL. Null = the
  /// person signs in and Google redirects with a code.
  final Future<void> Function(Uri authUrl)? browserAnswers;

  final store = _Memory();
  final tokenRequests = <Map<String, String>>[];
  final revoked = <String>[];
  Uri? authUrl;
  (int, String)? page;

  /// Done when the browser has what it asked for. The app's side of a
  /// sign-in can be over before the browser has read the page it was sent,
  /// so a test that looks at [page] waits for this first.
  Future<void> browsed = Future.value();
  var accessCounter = 0;
  var refreshFails = false;
  var revokeFails = false;
  var now = DateTime.utc(2026, 10, 1, 12);

  late final oauth = GoogleDesktopOAuth(
    clientId: 'client-id.apps.example',
    clientSecret: 'client-secret',
    httpClient: MockClient(_serve),
    store: store,
    openBrowser: _open,
    now: () => now,
    random: Random(7),
    authorizationEndpoint: Uri.parse('https://accounts.example/auth'),
    tokenEndpoint: Uri.parse('https://oauth.example/token'),
    revocationEndpoint: Uri.parse('https://oauth.example/revoke'),
    signInTimeout: const Duration(seconds: 5),
  );

  Future<bool> _open(Uri url) async {
    authUrl = url;
    final answers = browserAnswers;
    // Later, like a person: the app is already waiting by then.
    browsed = Future<void>.delayed(const Duration(milliseconds: 20), () async {
      if (answers != null) return answers(url);
      page = await _browse(redirect(url, code: 'auth-code-1'));
    });
    return true;
  }

  /// Google's redirect for [authUrl].
  static Uri redirect(Uri authUrl, {String? code, String? error, String? state}) {
    final base = Uri.parse(authUrl.queryParameters['redirect_uri']!);
    return base.replace(path: '/', queryParameters: {
      'code': ?code,
      'error': ?error,
      'state': state ?? authUrl.queryParameters['state']!,
    });
  }

  Future<http.Response> _serve(http.Request request) async {
    final form = Uri.splitQueryString(request.body);
    if (request.url.path == '/revoke') {
      if (revokeFails) throw const SocketException('offline');
      revoked.add(form['token']!);
      return http.Response('{}', 200);
    }
    tokenRequests.add(form);
    if (form['grant_type'] == 'refresh_token') {
      if (refreshFails) {
        return http.Response(jsonEncode({'error': 'invalid_grant'}), 400);
      }
      return http.Response(
          jsonEncode({
            'access_token': 'access-${++accessCounter}',
            'expires_in': 3600,
          }),
          200);
    }
    return http.Response(
        jsonEncode({
          'access_token': 'access-${++accessCounter}',
          'expires_in': 3600,
          if (refreshToken != null) 'refresh_token': refreshToken,
          'scope': grantedScope,
          'id_token': _idToken('alex@example.com'),
        }),
        200);
  }
}

Matcher _problem(GoogleAuthProblem problem) => isA<GoogleAuthException>()
    .having((e) => e.problem, 'problem', problem);

void main() {
  group('signing in', () {
    test('the browser is sent to Google with PKCE and a one-time listener, '
        'and the answer becomes a kept sign-in', () async {
      final g = _Google();
      final email = await g.oauth.signIn(const [_drive]);
      expect(email, 'alex@example.com');

      // What the browser was sent to.
      final q = g.authUrl!.queryParameters;
      expect(g.authUrl!.host, 'accounts.example');
      expect(q['client_id'], 'client-id.apps.example');
      expect(q['response_type'], 'code');
      expect(q['code_challenge_method'], 'S256');
      expect(q['scope']!.split(' '), containsAll([_drive, 'openid', 'email']));
      expect(q['state'], hasLength(greaterThanOrEqualTo(32)));
      final redirect = Uri.parse(q['redirect_uri']!);
      expect(redirect.scheme, 'http');
      expect(redirect.host, '127.0.0.1', reason: 'this computer only');
      expect(redirect.port, greaterThan(0));
      expect(q.containsKey('client_secret'), isFalse,
          reason: 'never in a URL the browser history keeps');

      // The exchange: the code, and the verifier whose hash the browser saw.
      final exchange = g.tokenRequests.single;
      expect(exchange['grant_type'], 'authorization_code');
      expect(exchange['code'], 'auth-code-1');
      expect(exchange['redirect_uri'], q['redirect_uri']);
      expect(exchange['client_id'], 'client-id.apps.example');
      expect(exchange['client_secret'], 'client-secret');
      final verifier = exchange['code_verifier']!;
      expect(verifier.length, inInclusiveRange(43, 128));
      expect(RegExp(r'^[A-Za-z0-9._~-]+$').hasMatch(verifier), isTrue);
      expect(
        base64Url
            .encode(sha256.convert(ascii.encode(verifier)).bytes)
            .replaceAll('=', ''),
        q['code_challenge'],
      );

      // What the person saw in the browser: words, nothing from the request.
      await g.browsed;
      expect(g.page!.$1, 200);
      expect(g.page!.$2, contains('Google Drive is connected'));
      expect(g.page!.$2, isNot(contains('auth-code-1')));

      // Kept here, and usable without asking again or calling Google again.
      expect(g.store.value, contains('refresh-1'));
      expect(await g.oauth.isConnected(const [_drive]), isTrue);
      expect(await g.oauth.email(), 'alex@example.com');
      expect(await g.oauth.accessToken(const [_drive]), 'access-1');
      expect(g.tokenRequests, hasLength(1));

      // The listener is gone: the address answers nobody any more.
      await expectLater(_browse(redirect.replace(path: '/')),
          throwsA(isA<SocketException>()));
    });

    test('only the answer to THIS sign-in completes it', () async {
      late final _Google g;
      final seen = <int>[];
      g = _Google(browserAnswers: (url) async {
        final base = Uri.parse(url.queryParameters['redirect_uri']!);
        // A page that guesses, a favicon request, a POST, the wrong path.
        seen.add((await _browse(
                _Google.redirect(url, code: 'stolen', state: 'guess')))
            .$1);
        seen.add((await _browse(base.replace(path: '/favicon.ico'))).$1);
        seen.add((await _browse(base.replace(path: '/'))).$1);
        seen.add((await _browse(base.replace(
                path: '/other',
                queryParameters: {
                  'code': 'x',
                  'state': url.queryParameters['state']!
                })))
            .$1);
        final post = HttpClient();
        final req = await post.postUrl(_Google.redirect(url, code: 'posted'));
        seen.add((await req.close()).statusCode);
        post.close(force: true);
        // And then the real one.
        g.page = await _browse(_Google.redirect(url, code: 'real-code'));
      });
      await g.oauth.signIn(const [_drive]);
      expect(seen, [404, 404, 404, 404, 404]);
      expect(g.tokenRequests.single['code'], 'real-code');
    });

    test('saying no at Google is a cancel, said as one', () async {
      late final _Google g;
      g = _Google(browserAnswers: (url) async {
        g.page = await _browse(_Google.redirect(url, error: 'access_denied'));
      });
      await expectLater(g.oauth.signIn(const [_drive]),
          throwsA(_problem(GoogleAuthProblem.cancelled)));
      // The sign-in is over as soon as the app has Google's answer; the
      // browser may still be reading the page it was sent (on a busy machine
      // it was, and there was no page yet to look at).
      await g.browsed;
      expect(g.page!.$2, contains('was not connected'));
      expect(g.tokenRequests, isEmpty);
      expect(g.store.value, isNull);
    });

    test('a sign-in nobody finishes times out and stops listening', () async {
      final g = _Google(browserAnswers: (_) async {});
      final oauth = GoogleDesktopOAuth(
        clientId: 'c',
        httpClient: MockClient((_) async => http.Response('{}', 500)),
        store: g.store,
        openBrowser: (url) async {
          g.authUrl = url;
          return true;
        },
        signInTimeout: const Duration(milliseconds: 150),
      );
      await expectLater(oauth.signIn(const [_drive]),
          throwsA(_problem(GoogleAuthProblem.timedOut)));
      await expectLater(
          _browse(_Google.redirect(g.authUrl!, code: 'late')),
          throwsA(isA<SocketException>()));
    });

    test('a browser that cannot be opened is said, and nothing is left '
        'listening', () async {
      Uri? asked;
      final oauth = GoogleDesktopOAuth(
        clientId: 'c',
        httpClient: MockClient((_) async => http.Response('{}', 500)),
        store: _Memory(),
        openBrowser: (url) async {
          asked = url;
          return false;
        },
      );
      await expectLater(oauth.signIn(const [_drive]),
          throwsA(_problem(GoogleAuthProblem.browser)));
      await expectLater(_browse(_Google.redirect(asked!, code: 'x')),
          throwsA(isA<SocketException>()));
    });

    test('the Drive permission unticked at Google: nothing is kept and what '
        'Google gave is handed back', () async {
      final g = _Google(grantedScope: 'openid email');
      await expectLater(g.oauth.signIn(const [_drive]),
          throwsA(_problem(GoogleAuthProblem.permissionNotGranted)));
      expect(g.store.value, isNull);
      expect(g.revoked, ['refresh-1']);
      expect(await g.oauth.isConnected(const [_drive]), isFalse);
    });

    test('no refresh token from Google is a failure, not a half sign-in',
        () async {
      final g = _Google(refreshToken: null);
      await expectLater(g.oauth.signIn(const [_drive]),
          throwsA(_problem(GoogleAuthProblem.failed)));
      expect(g.store.value, isNull);
    });

    test('Cancel in the app ends a waiting sign-in', () async {
      final g = _Google(browserAnswers: (_) async {});
      final pending = g.oauth.signIn(const [_drive]);
      unawaited(Future<void>.delayed(
          const Duration(milliseconds: 60), g.oauth.cancelSignIn));
      await expectLater(pending, throwsA(_problem(GoogleAuthProblem.cancelled)));
    });

    test('a second sign-in replaces the first, and its own listener stays',
        () async {
      var opens = 0;
      late final _Google g;
      g = _Google(browserAnswers: (url) async {
        opens++;
        if (opens == 1) return; // the first tab is left open
        // Give the first sign-in time to wind down before the second answer.
        await Future<void>.delayed(const Duration(milliseconds: 80));
        g.page = await _browse(_Google.redirect(url, code: 'second-code'));
      });
      final first = g.oauth.signIn(const [_drive]);
      final firstEnds =
          expectLater(first, throwsA(_problem(GoogleAuthProblem.cancelled)));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final email = await g.oauth.signIn(const [_drive]);
      await firstEnds;
      expect(email, 'alex@example.com');
      expect(g.tokenRequests.single['code'], 'second-code');
    });

    test('a build without the desktop client says so', () async {
      final oauth = GoogleDesktopOAuth(
        clientId: '',
        httpClient: MockClient((_) async => fail('no request')),
        store: _Memory(),
        openBrowser: (_) async => fail('no browser'),
      );
      expect(oauth.isConfigured, isFalse);
      await expectLater(oauth.signIn(const [_drive]),
          throwsA(_problem(GoogleAuthProblem.notConfigured)));
      await expectLater(oauth.accessToken(const [_drive]),
          throwsA(_problem(GoogleAuthProblem.notConfigured)));
    });
  });

  group('staying signed in', () {
    test('not connected is said, with nothing sent', () async {
      final g = _Google();
      await expectLater(g.oauth.accessToken(const [_drive]),
          throwsA(_problem(GoogleAuthProblem.notConnected)));
      expect(g.tokenRequests, isEmpty);
    });

    test('an expired token is refreshed once, however many ask at once',
        () async {
      final g = _Google();
      await g.oauth.signIn(const [_drive]);
      g.now = g.now.add(const Duration(minutes: 59, seconds: 30));
      final tokens = await Future.wait([
        g.oauth.accessToken(const [_drive]),
        g.oauth.accessToken(const [_drive]),
        g.oauth.accessToken(const [_drive]),
      ]);
      expect(tokens.toSet(), {'access-2'});
      final refreshes =
          g.tokenRequests.where((r) => r['grant_type'] == 'refresh_token');
      expect(refreshes, hasLength(1));
      expect(refreshes.single['refresh_token'], 'refresh-1');
      expect(refreshes.single['client_id'], 'client-id.apps.example');
      // Still fresh a moment later: no further call.
      expect(await g.oauth.accessToken(const [_drive]), 'access-2');
      expect(g.tokenRequests, hasLength(2));
    });

    test('a new app start signs in from what was kept', () async {
      final g = _Google();
      await g.oauth.signIn(const [_drive]);
      final later = GoogleDesktopOAuth(
        clientId: 'client-id.apps.example',
        clientSecret: 'client-secret',
        httpClient: MockClient((request) async {
          expect(Uri.splitQueryString(request.body)['refresh_token'],
              'refresh-1');
          return http.Response(
              jsonEncode({'access_token': 'access-next', 'expires_in': 3600}),
              200);
        }),
        store: g.store,
        openBrowser: (_) async => fail('nothing to ask'),
        tokenEndpoint: Uri.parse('https://oauth.example/token'),
      );
      expect(await later.accessToken(const [_drive]), 'access-next');
      expect(await later.email(), 'alex@example.com');
    });

    test('access removed at Google ends it here too', () async {
      final g = _Google();
      await g.oauth.signIn(const [_drive]);
      g.now = g.now.add(const Duration(hours: 2));
      g.refreshFails = true;
      await expectLater(g.oauth.accessToken(const [_drive]),
          throwsA(_problem(GoogleAuthProblem.accessEnded)));
      expect(g.store.value, isNull);
      await expectLater(g.oauth.accessToken(const [_drive]),
          throwsA(_problem(GoogleAuthProblem.notConnected)));
    });

    test('a permission that was never given is not assumed', () async {
      final g = _Google();
      await g.oauth.signIn(const [_drive]);
      const other = 'https://www.googleapis.com/auth/drive.file';
      expect(await g.oauth.isConnected(const [_drive, other]), isFalse);
      g.now = g.now.add(const Duration(hours: 2));
      await expectLater(g.oauth.accessToken(const [other]),
          throwsA(_problem(GoogleAuthProblem.notConnected)));
    });

    test('damaged storage reads as not connected', () async {
      for (final raw in ['not json', '[]', '{"refresh_token":""}', '{"v":1}']) {
        final g = _Google()..store.value = raw;
        expect(await g.oauth.isConnected(const [_drive]), isFalse, reason: raw);
        expect(await g.oauth.email(), isNull, reason: raw);
      }
    });

    test('disconnecting revokes at Google and forgets here, even offline',
        () async {
      final g = _Google();
      await g.oauth.signIn(const [_drive]);
      await g.oauth.signOut();
      expect(g.revoked, ['refresh-1']);
      expect(g.store.value, isNull);
      await expectLater(g.oauth.accessToken(const [_drive]),
          throwsA(_problem(GoogleAuthProblem.notConnected)));

      final offline = _Google()..revokeFails = true;
      await offline.oauth.signIn(const [_drive]);
      await offline.oauth.signOut();
      expect(offline.store.value, isNull);
    });

    test('no code and no token ever lands in an error\'s text', () async {
      final g = _Google(refreshToken: null);
      Object? error;
      try {
        await g.oauth.signIn(const [_drive]);
      } catch (e) {
        error = e;
      }
      final text = '$error ${(error as GoogleAuthException).detail}';
      for (final secret in ['auth-code-1', 'access-1', 'client-secret']) {
        expect(text, isNot(contains(secret)));
      }
    });
  });

  group('Drive sync on a computer', () {
    http.Client drive(List<http.Request> seen) => MockClient((request) async {
          seen.add(request);
          return http.Response(jsonEncode({'files': <Object>[]}), 200);
        });

    test('testing the connection signs in through the browser, then talks to '
        'Drive with the token', () async {
      final g = _Google();
      final seen = <http.Request>[];
      final backend = GoogleDriveSyncBackend(
          desktopOAuth: g.oauth, useDesktopFlow: true, client: drive(seen));
      await backend.checkConnection();
      expect(g.authUrl, isNotNull, reason: 'the browser was opened');
      expect(seen.single.headers['Authorization'], 'Bearer access-1');
      expect(seen.single.url.host, 'www.googleapis.com');
      expect(backend.displayName, 'Google Drive (alex@example.com)');

      // Already connected: a second test asks nobody.
      g.authUrl = null;
      await backend.checkConnection();
      expect(g.authUrl, isNull);
    });

    test('not connected is a plain sentence, not a plugin error', () async {
      final g = _Google();
      final backend = GoogleDriveSyncBackend(
          desktopOAuth: g.oauth, useDesktopFlow: true, client: drive([]));
      await expectLater(
        backend.readObject(),
        throwsA(isA<SyncException>()
            .having((e) => e.message, 'message',
                contains('Google Drive is not connected'))
            .having((e) => e.message, 'message',
                isNot(contains('MissingPluginException')))),
      );
    });

    test('a build without the desktop client says Drive is not available '
        'here', () async {
      final oauth = GoogleDesktopOAuth(
        clientId: '',
        httpClient: MockClient((_) async => fail('no request')),
        store: _Memory(),
        openBrowser: (_) async => fail('no browser'),
      );
      final backend = GoogleDriveSyncBackend(
          desktopOAuth: oauth, useDesktopFlow: true, client: drive([]));
      await expectLater(
        backend.checkConnection(),
        throwsA(isA<SyncException>().having((e) => e.message, 'message',
            contains('not available on this computer'))),
      );
    });

    test('a cancelled sign-in is said as cancelled', () async {
      late final _Google g;
      g = _Google(browserAnswers: (url) async {
        await _browse(_Google.redirect(url, error: 'access_denied'));
      });
      final backend = GoogleDriveSyncBackend(
          desktopOAuth: g.oauth, useDesktopFlow: true, client: drive([]));
      await expectLater(
        backend.checkConnection(),
        throwsA(isA<SyncException>().having(
            (e) => e.message, 'message', 'Google sign-in was cancelled.')),
      );
    });

    test('what Drive answers is said in the person\'s language, with its '
        'English kept for the details (3.0: it was said in '
        'English, in every language)', () async {
      final de = lookupAppLocalizations(const Locale('de'));
      L10nGlobal.update(de);
      addTearDown(() => L10nGlobal.update(lookupAppLocalizations(const Locale('en'))));
      var list = 403;
      var download = 200;
      final backend = GoogleDriveSyncBackend(
        desktopOAuth: _Google().oauth,
        useDesktopFlow: true,
        client: MockClient((request) async => request.url.queryParameters['alt'] == 'media'
            ? http.Response('', download)
            : http.Response(
                jsonEncode({
                  'files': [
                    {'id': 'sync-file'},
                  ],
                }),
                list)),
      );
      Future<SyncException> failure(Future<void> Function() step) async {
        try {
          await step();
        } on SyncException catch (e) {
          return e;
        }
        fail('it did not fail');
      }

      var said = await failure(backend.checkConnection);
      expect(said.message, de.syncDriveReconnect);
      expect(said.detail, 'Google Drive denied access');

      list = 503;
      said = await failure(backend.checkConnection);
      expect(said.message, de.syncStoreFault(503));
      expect(said.detail, 'Google Drive list failed: HTTP 503');

      list = 200;
      download = 500;
      said = await failure(backend.readObject);
      expect(said.message, de.syncStoreFault(500));
      expect(said.detail, 'Google Drive download failed: HTTP 500');
    });
  });

  test('a PKCE verifier is 43 characters of the allowed set, new every time',
      () {
    final random = Random.secure();
    final a = PkcePair.generate(random);
    final b = PkcePair.generate(random);
    expect(a.verifier, hasLength(43));
    expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(a.verifier), isTrue);
    expect(a.verifier, isNot(b.verifier));
    expect(a.challenge, isNot(a.verifier));
  });
}
