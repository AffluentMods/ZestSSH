/// Google sign-in for Drive on a computer (Windows, Linux, macOS).
///
/// A bug in 2.2.1 (Windows): choosing Google Drive for sync failed
/// with `MissingPluginException ... google_sign_in`. The Google plugin the
/// phones use has no Windows or Linux side at all (and is not set up for the
/// Mac build), so every call to it failed.
///
/// A computer signs in the way Google documents for installed apps (RFC
/// 8252): the system browser opens Google's own sign-in page, Google sends
/// its answer to a one-time listener on this computer (127.0.0.1, a port
/// picked for that one sign-in), and the app exchanges the answer for tokens.
/// PKCE ties the answer to this app instance and `state` to this request, so
/// a page or a program that is not this sign-in cannot feed it one.
///
/// What is kept: the refresh token, in the system keychain, on this computer
/// only. It never goes to ZestSSH's servers; nothing here talks to anything
/// but Google. Disconnecting revokes it at Google and deletes it here.
///
/// The OAuth client is a "Desktop app" client of the same Google Cloud
/// project the phone apps use (Drive's app-data folder belongs to the
/// project, so every device sees the same sync file). It is given to the
/// build as `GOOGLE_DESKTOP_CLIENT_ID` / `GOOGLE_DESKTOP_CLIENT_SECRET`
/// (Google's own documentation says the secret of a desktop client is not a
/// secret: it ships inside every installed app). Without it the build says
/// plainly that Google Drive is not available on this computer.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/type_name.dart';
import 'package:zestssh/services/profiles/keychain.dart';

/// What went wrong with a Google sign-in on a computer.
enum GoogleAuthProblem {
  /// This build has no desktop OAuth client.
  notConfigured,

  /// Nobody has connected Google Drive on this computer (or it was
  /// disconnected).
  notConnected,

  /// The person closed the page or said no.
  cancelled,

  /// The sign-in was not finished in time.
  timedOut,

  /// Google signed the person in, but the Drive permission was unticked.
  permissionNotGranted,

  /// The kept access no longer works: removed in the Google account, or
  /// expired.
  accessEnded,

  /// The browser could not be opened.
  browser,

  /// Anything else (Google answered with an error, the network failed).
  failed,
}

class GoogleAuthException implements Exception, HasTypeName {
  const GoogleAuthException(this.problem, {this.detail});

  final GoogleAuthProblem problem;

  /// Technical text for Copy details. Never a token or a code.
  final String? detail;

  /// What to tell the person, in their language.
  String get message => switch (problem) {
        GoogleAuthProblem.notConfigured => gl10n.googleDriveNotOnThisComputer,
        GoogleAuthProblem.notConnected => gl10n.googleDriveNotConnected,
        GoogleAuthProblem.cancelled => gl10n.googleDriveSignInCancelled,
        GoogleAuthProblem.timedOut => gl10n.googleDriveSignInTimedOut,
        GoogleAuthProblem.permissionNotGranted =>
          gl10n.googleDrivePermissionNotGranted,
        GoogleAuthProblem.accessEnded => gl10n.googleDriveAccessEnded,
        GoogleAuthProblem.browser => gl10n.googleDriveBrowserNotOpened,
        GoogleAuthProblem.failed => gl10n.googleDriveSignInFailed,
      };

  @override
  String toString() =>
      'GoogleAuthException(${problem.name}${detail == null ? '' : ': $detail'})';

  @override
  String get typeName => 'GoogleAuthException';
}

/// Where the kept sign-in lives. The app uses the system keychain; a test
/// uses memory.
abstract class GoogleTokenStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

class KeychainGoogleTokenStore implements GoogleTokenStore {
  const KeychainGoogleTokenStore();

  static const key = 'google_desktop_oauth_v1';

  static FlutterSecureStorage get _storage => appKeychain;

  // Sealed while the encrypting lock is on (SecretSeal; 22 October 2026: the
  // refresh token was kept as it was): opened with your Tree's database, and
  // none while the app is locked.
  @override
  Future<String?> read() async => openKept(SecretSeal.openTree, key, await _storage.read(key: key));

  @override
  Future<void> write(String value) async =>
      _storage.write(key: key, value: await keepSealed(SecretSeal.openTree, key, value));

  @override
  Future<void> delete() => _storage.delete(key: key);
}

/// A PKCE verifier and its challenge (RFC 7636, S256).
class PkcePair {
  PkcePair._(this.verifier, this.challenge);

  /// 32 random bytes as base64url: 43 characters from the unreserved set.
  factory PkcePair.generate(Random random) {
    final verifier = _randomToken(random, 32);
    final digest = sha256.convert(ascii.encode(verifier)).bytes;
    return PkcePair._(verifier, _base64UrlNoPad(digest));
  }

  final String verifier;
  final String challenge;
}

String _base64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

String _randomToken(Random random, int bytes) =>
    _base64UrlNoPad(List<int>.generate(bytes, (_) => random.nextInt(256)));

/// Compares two strings without stopping at the first difference.
bool _sameSecret(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

class _Kept {
  _Kept({required this.refreshToken, required this.scopes, this.email});

  final String refreshToken;
  final Set<String> scopes;
  final String? email;

  String encode() => jsonEncode({
        'v': 1,
        'refresh_token': refreshToken,
        'scopes': scopes.toList()..sort(),
        if (email != null) 'email': email,
      });

  static _Kept? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final token = json['refresh_token'];
      final scopes = json['scopes'];
      if (token is! String || token.isEmpty || scopes is! List) return null;
      final email = json['email'];
      return _Kept(
        refreshToken: token,
        scopes: {for (final s in scopes) if (s is String) s},
        email: email is String && email.isNotEmpty ? email : null,
      );
    } catch (_) {
      return null;
    }
  }
}

class GoogleDesktopOAuth {
  GoogleDesktopOAuth({
    String? clientId,
    String? clientSecret,
    http.Client? httpClient,
    GoogleTokenStore? store,
    Future<bool> Function(Uri url)? openBrowser,
    DateTime Function()? now,
    Random? random,
    Uri? authorizationEndpoint,
    Uri? tokenEndpoint,
    Uri? revocationEndpoint,
    this.signInTimeout = const Duration(minutes: 5),
  })  : clientId = clientId ?? _envClientId,
        clientSecret = clientSecret ?? _envClientSecret,
        _http = httpClient ?? http.Client(),
        _store = store ?? const KeychainGoogleTokenStore(),
        _openBrowser = openBrowser ?? _launch,
        _now = now ?? DateTime.now,
        _random = random ?? Random.secure(),
        _authorizationEndpoint = authorizationEndpoint ??
            Uri.parse('https://accounts.google.com/o/oauth2/v2/auth'),
        _tokenEndpoint =
            tokenEndpoint ?? Uri.parse('https://oauth2.googleapis.com/token'),
        _revocationEndpoint = revocationEndpoint ??
            Uri.parse('https://oauth2.googleapis.com/revoke');

  static const _envClientId = String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_ID');
  static const _envClientSecret =
      String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_SECRET');

  /// The one the app uses.
  static final GoogleDesktopOAuth instance = GoogleDesktopOAuth();

  /// Whether this is a platform where the Google plugin cannot be used and
  /// this flow stands in for it.
  static bool get usedOnThisPlatform =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  final String clientId;
  final String clientSecret;
  final Duration signInTimeout;

  final http.Client _http;
  final GoogleTokenStore _store;
  final Future<bool> Function(Uri url) _openBrowser;
  final DateTime Function() _now;
  final Random _random;
  final Uri _authorizationEndpoint;
  final Uri _tokenEndpoint;
  final Uri _revocationEndpoint;

  /// Whether this build was given a desktop OAuth client.
  bool get isConfigured => clientId.isNotEmpty;

  String? _accessToken;
  DateTime? _accessExpiry;
  Set<String> _accessScopes = const {};
  Future<String>? _refreshing;
  HttpServer? _listener;
  Completer<Map<String, String>>? _waiting;

  static Future<bool> _launch(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  /// What is kept in memory goes (a change of profile): the access token Google
  /// gave, kept for an hour, is the person's who was here. What is kept in the
  /// keychain is their profile's, and is not reached by this.
  void forgetMemory() {
    _accessToken = null;
    _accessExpiry = null;
    _accessScopes = const {};
    _refreshing = null;
  }

  /// Whether an access token is held in memory, and a test's way of putting one
  /// there without asking Google.
  @visibleForTesting
  bool get holdsAccessToken => _accessToken != null;

  @visibleForTesting
  void debugHoldAccessToken(String token) {
    _accessToken = token;
    _accessExpiry = _now().add(const Duration(hours: 1));
  }

  /// The account connected on this computer, when one is.
  Future<String?> email() async => _Kept.decode(await _store.read())?.email;

  /// Whether Drive is connected here with every one of [scopes].
  Future<bool> isConnected(Iterable<String> scopes) async {
    final kept = _Kept.decode(await _store.read());
    return kept != null && kept.scopes.containsAll(scopes);
  }

  /// An access token for [scopes], without asking the person anything.
  /// Throws [GoogleAuthException] with `notConnected` when [signIn] has to
  /// come first, `accessEnded` when Google no longer honours what is kept.
  Future<String> accessToken(List<String> scopes) async {
    if (!isConfigured) {
      throw const GoogleAuthException(GoogleAuthProblem.notConfigured);
    }
    final token = _accessToken;
    final expiry = _accessExpiry;
    if (token != null &&
        expiry != null &&
        _accessScopes.containsAll(scopes) &&
        expiry.isAfter(_now().add(const Duration(seconds: 60)))) {
      return token;
    }
    // One refresh at a time: a sync cycle asks for the token several times
    // at once.
    final fresh = await (_refreshing ??= _refresh().whenComplete(() {
      _refreshing = null;
    }));
    if (!_accessScopes.containsAll(scopes)) {
      // Connected, but not for this: the person has to allow it first.
      throw const GoogleAuthException(GoogleAuthProblem.notConnected);
    }
    return fresh;
  }

  Future<String> _refresh() async {
    final kept = _Kept.decode(await _store.read());
    if (kept == null) {
      throw const GoogleAuthException(GoogleAuthProblem.notConnected);
    }
    final http.Response response;
    try {
      response = await _http.post(_tokenEndpoint, body: {
        'client_id': clientId,
        if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
        'refresh_token': kept.refreshToken,
        'grant_type': 'refresh_token',
      }).timeout(const Duration(seconds: 30));
    } catch (e) {
      throw GoogleAuthException(GoogleAuthProblem.failed, detail: '$e');
    }
    final body = _json(response.body);
    if (response.statusCode != 200) {
      final error = body['error'];
      if (error == 'invalid_grant') {
        // Removed in the Google account, or expired: nothing kept here can
        // work again.
        await _forget();
        throw const GoogleAuthException(GoogleAuthProblem.accessEnded,
            detail: 'invalid_grant');
      }
      throw GoogleAuthException(GoogleAuthProblem.failed,
          detail: 'token refresh: HTTP ${response.statusCode} $error');
    }
    final access = body['access_token'];
    if (access is! String || access.isEmpty) {
      throw const GoogleAuthException(GoogleAuthProblem.failed,
          detail: 'token refresh: no access token');
    }
    _remember(access, body['expires_in'], kept.scopes);
    return access;
  }

  void _remember(String access, Object? expiresIn, Set<String> scopes) {
    final seconds = expiresIn is int
        ? expiresIn
        : int.tryParse('${expiresIn ?? ''}') ?? 3600;
    _accessToken = access;
    _accessExpiry = _now().add(Duration(seconds: seconds));
    _accessScopes = scopes;
  }

  /// Connects Google Drive on this computer for [scopes]: opens the browser,
  /// waits for the person to finish at Google, and keeps the result. Returns
  /// the account's email when Google gave one.
  Future<String?> signIn(List<String> scopes) async {
    if (!isConfigured) {
      throw const GoogleAuthException(GoogleAuthProblem.notConfigured);
    }
    // A sign-in left open is replaced, not stacked: the earlier one ends as
    // cancelled and its listener goes.
    cancelSignIn();
    await _closeListener();

    final pkce = PkcePair.generate(_random);
    final state = _randomToken(_random, 24);
    final HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    } catch (e) {
      throw GoogleAuthException(GoogleAuthProblem.failed,
          detail: 'listener: $e');
    }
    _listener = server;
    server.idleTimeout = const Duration(seconds: 30);
    final redirect = 'http://127.0.0.1:${server.port}';

    final answer = Completer<Map<String, String>>();
    _waiting = answer;
    server.listen((request) => _answer(request, state, answer),
        onError: (Object _) {});

    final url = _authorizationEndpoint.replace(queryParameters: {
      'client_id': clientId,
      'redirect_uri': redirect,
      'response_type': 'code',
      // The Drive permission, plus the address of the account so the app can
      // show which one is connected.
      'scope': [...scopes, 'openid', 'email'].join(' '),
      'code_challenge': pkce.challenge,
      'code_challenge_method': 'S256',
      'state': state,
      'access_type': 'offline',
      'include_granted_scopes': 'true',
      'prompt': 'select_account',
    });

    try {
      bool opened;
      try {
        opened = await _openBrowser(url);
      } catch (e) {
        throw GoogleAuthException(GoogleAuthProblem.browser, detail: '$e');
      }
      if (!opened) {
        throw const GoogleAuthException(GoogleAuthProblem.browser);
      }

      final Map<String, String> query;
      try {
        query = await answer.future.timeout(signInTimeout);
      } on TimeoutException {
        throw const GoogleAuthException(GoogleAuthProblem.timedOut);
      }
      final error = query['error'];
      if (error != null) {
        throw GoogleAuthException(
          error == 'access_denied'
              ? GoogleAuthProblem.cancelled
              : GoogleAuthProblem.failed,
          detail: 'authorization: $error',
        );
      }
      final code = query['code'];
      if (code == null || code.isEmpty) {
        throw const GoogleAuthException(GoogleAuthProblem.failed,
            detail: 'authorization: no code');
      }
      return await _exchange(code, pkce.verifier, redirect, scopes);
    } finally {
      // Only this sign-in's own listener: a newer sign-in may already have
      // put its own in place.
      if (identical(_waiting, answer)) _waiting = null;
      if (identical(_listener, server)) _listener = null;
      try {
        await server.close(force: true);
      } catch (_) {}
    }
  }

  /// Gives up a sign-in that is waiting for the browser (the person pressed
  /// Cancel in the app). [signIn] ends as cancelled.
  void cancelSignIn() {
    final waiting = _waiting;
    if (waiting != null && !waiting.isCompleted) {
      waiting.complete(const {'error': 'access_denied'});
    }
  }

  /// One request to the listener. Only Google's answer to THIS sign-in (the
  /// right `state`) completes it; anything else gets a plain refusal and the
  /// listener keeps waiting.
  Future<void> _answer(HttpRequest request, String state,
      Completer<Map<String, String>> answer) async {
    final response = request.response;
    try {
      final query = request.uri.queryParameters;
      final given = query['state'] ?? '';
      final isAnswer = request.method == 'GET' &&
          request.uri.path == '/' &&
          given.isNotEmpty &&
          _sameSecret(given, state) &&
          (query.containsKey('code') || query.containsKey('error'));
      if (!isAnswer || answer.isCompleted) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final ok = !query.containsKey('error');
      response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..headers.set('Cache-Control', 'no-store')
        ..headers.set('Referrer-Policy', 'no-referrer')
        ..headers.set('X-Content-Type-Options', 'nosniff')
        ..headers.set('Content-Security-Policy',
            "default-src 'none'; style-src 'unsafe-inline'")
        ..write(_page(ok));
      await response.close();
      answer.complete(query);
    } catch (e) {
      AppLogger.warning('Google sign-in listener: $e');
      try {
        await response.close();
      } catch (_) {}
    }
  }

  /// The page the browser shows once Google has answered. Words only, in the
  /// app's language, and nothing from the request is put into it.
  static String _page(bool ok) {
    String esc(String s) => const HtmlEscape().convert(s);
    final title = esc(ok
        ? gl10n.googleDriveBrowserPageDone
        : gl10n.googleDriveBrowserPageFailed);
    return '<!doctype html><html><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>ZestSSH</title><style>'
        'body{margin:0;min-height:100vh;display:flex;align-items:center;'
        'justify-content:center;background:#0f0f11;color:#ececee;'
        'font:16px/1.5 system-ui,-apple-system,Segoe UI,sans-serif}'
        'main{max-width:30rem;padding:2rem;text-align:center}'
        'b{display:block;color:#ff7a1a;font-size:1.25rem;margin-bottom:.75rem}'
        '</style></head><body><main><b>ZestSSH</b>$title</main></body></html>';
  }

  Future<String?> _exchange(String code, String verifier, String redirect,
      List<String> scopes) async {
    final http.Response response;
    try {
      response = await _http.post(_tokenEndpoint, body: {
        'client_id': clientId,
        if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
        'code': code,
        'code_verifier': verifier,
        'redirect_uri': redirect,
        'grant_type': 'authorization_code',
      }).timeout(const Duration(seconds: 30));
    } catch (e) {
      throw GoogleAuthException(GoogleAuthProblem.failed, detail: '$e');
    }
    final body = _json(response.body);
    if (response.statusCode != 200) {
      throw GoogleAuthException(GoogleAuthProblem.failed,
          detail: 'token exchange: HTTP ${response.statusCode} '
              '${body['error']}');
    }
    final access = body['access_token'];
    final refresh = body['refresh_token'];
    if (access is! String || access.isEmpty) {
      throw const GoogleAuthException(GoogleAuthProblem.failed,
          detail: 'token exchange: no access token');
    }
    final granted = '${body['scope'] ?? ''}'
        .split(' ')
        .where((s) => s.isNotEmpty)
        .toSet();
    // Google lets the person untick a permission on its page.
    if (!granted.containsAll(scopes)) {
      await _revoke(refresh is String && refresh.isNotEmpty ? refresh : access);
      throw const GoogleAuthException(GoogleAuthProblem.permissionNotGranted);
    }
    if (refresh is! String || refresh.isEmpty) {
      throw const GoogleAuthException(GoogleAuthProblem.failed,
          detail: 'token exchange: no refresh token');
    }
    final email = _emailOf(body['id_token']);
    await _store.write(
        _Kept(refreshToken: refresh, scopes: granted, email: email).encode());
    _remember(access, body['expires_in'], granted);
    return email;
  }

  /// The address in an ID token that came straight from Google's token
  /// endpoint over TLS (so it is read, not verified again).
  static String? _emailOf(Object? idToken) {
    if (idToken is! String) return null;
    final parts = idToken.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      final email = payload is Map ? payload['email'] : null;
      return email is String && email.isNotEmpty ? email : null;
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> _json(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  /// Disconnects Google Drive on this computer: the access is revoked at
  /// Google (best effort: offline is not a reason to stay connected) and
  /// what was kept here is deleted.
  Future<void> signOut() async {
    await _closeListener();
    final kept = _Kept.decode(await _store.read());
    await _forget();
    if (kept != null) await _revoke(kept.refreshToken);
  }

  Future<void> _forget() async {
    _accessToken = null;
    _accessExpiry = null;
    _accessScopes = const {};
    await _store.delete();
  }

  Future<void> _revoke(String token) async {
    try {
      await _http.post(_revocationEndpoint,
          body: {'token': token}).timeout(const Duration(seconds: 15));
    } catch (e) {
      AppLogger.warning('Google token revoke failed: $e');
    }
  }

  Future<void> _closeListener() async {
    final server = _listener;
    _listener = null;
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (_) {}
    }
  }
}
