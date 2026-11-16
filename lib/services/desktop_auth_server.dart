import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/type_name.dart';
import 'package:zestssh/l10n/l10n_global.dart';

/// A temporary local HTTP server that receives OAuth callbacks on desktop.
///
/// Opens a random port on localhost, waits for the browser to redirect
/// back with the auth token, then shuts down. This avoids the need to
/// register a custom URL scheme on Windows/Linux.
///
/// Flow:
/// 1. Call [start] with a CSRF [nonce] to bind the server and get the callback URL
/// 2. Open the auth URL in the browser with `redirect=callbackUrl&state=nonce`
/// 3. User signs in, browser redirects to `http://localhost:PORT/callback?token=X&state=nonce`
/// 4. Server validates the nonce, captures the token and completes the future
/// 5. Server shuts down automatically
class DesktopAuthServer {
  /// The parameters a callback is read for. Any other is counted, its name
  /// never written to the log: whoever sends a request to the listener
  /// chooses it, control characters included (found in a
  /// security review).
  static const knownParams = {'token', 'state', 'code', 'error', 'error_code', 'error_detail', 'done', 'cancelled', 'email'};

  /// [params]' names as the log says them: the known ones, sorted, and how
  /// many others came.
  @visibleForTesting
  static List<String> paramsForLog(Map<String, String> params) {
    final known = params.keys.where(knownParams.contains).toList()..sort();
    final others = params.length - known.length;
    return [...known, if (others > 0) '+$others other'];
  }

  DesktopAuthServer({Future<HttpServer> Function(int port)? bind})
      : _bind = bind ?? ((port) => HttpServer.bind(InternetAddress.loopbackIPv4, port));

  /// Opens a port on this computer's loopback address; 0 lets the system choose.
  final Future<HttpServer> Function(int port) _bind;

  /// The lowest port the website sends a sign-in back to: a loopback callback
  /// below it is refused there, since the ports of servers that run on a computer
  /// are below it. The system's choice is at or above it on every computer as
  /// they come, but a computer can be set otherwise.
  static const kLowestCallbackPort = 32768;

  /// How many times the system is asked for a port, and then how many ports of
  /// the private range are tried, before a sign-in says it has none.
  static const _systemTries = 5;
  static const _pickTries = 20;
  static const _pickFrom = 49152;
  static const _pickTo = 65535;

  HttpServer? _server;
  Completer<Map<String, String>>? _completer;
  Timer? _timeout;
  String? _expectedNonce;

  /// The page being sent to the browser, which [stop] lets arrive whole:
  /// closing at once cut it off, and the browser showed an error though the
  /// sign-in had worked.
  Future<void>? _answering;

  /// Maximum allowed length for the entire query string to prevent
  /// excessively large callback URLs from consuming resources.
  static const int _maxQueryLength = 4096;

  /// Start the local server and return the callback URL.
  ///
  /// [nonce] is a CSRF state value that the auth callback must include
  /// as a `state` query parameter. Callbacks without a matching state
  /// are rejected. The caller (profile_screen) generates this nonce
  /// and passes it to both the auth URL and this server.
  ///
  /// The returned URL should be passed as the redirect parameter
  /// to the auth endpoint.
  Future<String> start({
    required String nonce,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    // Runtime check (not assert - asserts are stripped in release builds,
    // which would silently accept an empty CSRF nonce).
    if (nonce.isEmpty) {
      throw ArgumentError('Auth nonce must not be empty');
    }
    await stop(); // Clean up any previous instance

    _answering = null;
    _expectedNonce = nonce;
    _completer = Completer<Map<String, String>>();
    // Stopped while the page still opens, nobody listens yet: [waitForCallback] says so.
    _completer!.future.ignore();
    _server = await _bindCallbackPort();
    _server!.idleTimeout = const Duration(seconds: 30);
    final port = _server!.port;
    final callbackUrl = 'http://127.0.0.1:$port/callback';

    AppLogger.info('Desktop auth server listening on port $port');

    _server!.listen(_handleRequest);

    // Auto-shutdown after timeout
    _timeout = Timer(timeout, () {
      if (!_completer!.isCompleted) {
        _completer!.completeError(
            TimeoutException('Auth callback not received', timeout));
      }
      stop();
    });

    return callbackUrl;
  }

  /// A port the website will send the browser back to ([kLowestCallbackPort]):
  /// the system's choice, a few times, holding each one too low until it is done
  /// so that it is not handed out again; then ports of the private range, picked
  /// here. [NoSignInPort] where none can be had.
  Future<HttpServer> _bindCallbackPort() async {
    final tooLow = <HttpServer>[];
    Object? why;
    try {
      for (var i = 0; i < _systemTries; i++) {
        try {
          final server = await _bind(0);
          if (server.port >= kLowestCallbackPort) return server;
          tooLow.add(server);
        } on SocketException catch (e) {
          why = e;
          break;
        }
      }
      final random = Random.secure();
      for (var i = 0; i < _pickTries; i++) {
        try {
          return await _bind(_pickFrom + random.nextInt(_pickTo - _pickFrom + 1));
        } on SocketException catch (e) {
          // Taken, or not this app's to take: another.
          why = e;
        }
      }
    } finally {
      for (final server in tooLow) {
        unawaited(server.close(force: true));
      }
    }
    throw NoSignInPort(why);
  }

  /// Stops waiting for the browser: [waitForCallback] throws
  /// [BrowserSignInCancelled] (Cancel while it waits, 3.3.0).
  void cancel() {
    if (_completer != null && !_completer!.isCompleted) _completer!.completeError(const BrowserSignInCancelled());
    stop();
  }

  /// Wait for the auth callback. Returns the token data map.
  Future<Map<String, String>> waitForCallback() {
    if (_completer == null) {
      throw StateError('Server not started. Call start() first.');
    }
    return _completer!.future;
  }

  void _handleRequest(HttpRequest request) {
    // Reject oversized query strings to limit resource consumption.
    if (request.uri.query.length > _maxQueryLength) {
      AppLogger.warning(
          'Desktop auth: rejected request with oversized query '
          '(${request.uri.query.length} bytes)');
      request.response
        ..statusCode = HttpStatus.requestEntityTooLarge
        ..write('Request too large')
        ..close();
      return;
    }

    // Only GET is a legitimate browser redirect target. Anything else is a
    // local process poking the loopback endpoint.
    if (request.method != 'GET') {
      request.response
        ..statusCode = HttpStatus.methodNotAllowed
        ..write('Method not allowed')
        ..close();
      return;
    }

    // Reject only cross-site SUBRESOURCE loads (an <img>/<script>/fetch from
    // some page the user happened to have open) - NOT the legitimate top-level
    // redirect back from the auth website. That redirect IS cross-site (the
    // website origin -> loopback are different sites, so Chromium stamps
    // Sec-Fetch-Site: cross-site), but it is a document NAVIGATION, which a
    // subresource attack can never be. Distinguish them by Sec-Fetch-Mode: a
    // genuine redirect reports `navigate`; a forged subresource reports
    // `no-cors` / `cors` / `same-origin`. Absent headers (older browsers /
    // curl / address-bar paste) fall through to the state-nonce gate, which is
    // the primary CSRF defence.
    //
    // The earlier `fetchSite == 'cross-site'` blanket reject was wrong: every
    // real browser-redirect sign-in is cross-site, so it 403'd all of them
    // ("Forbidden") and blocked desktop sign-in entirely.
    final fetchSite = request.headers.value('sec-fetch-site');
    final fetchMode = request.headers.value('sec-fetch-mode');
    if (fetchSite == 'cross-site' &&
        fetchMode != null &&
        fetchMode != 'navigate') {
      AppLogger.warning(
        'Desktop auth: rejected cross-site non-navigation callback '
        '(Sec-Fetch-Site=$fetchSite, Sec-Fetch-Mode=$fetchMode)',
      );
      request.response
        ..statusCode = HttpStatus.forbidden
        ..write('Forbidden')
        ..close();
      return;
    }

    if (request.uri.path == '/callback') {
      final params = request.uri.queryParameters;

      // Log every callback we receive so we can diagnose server-side
      // breakage (website not appending token, missing state, etc.).
      // Sanitize the token before logging - we only need its presence
      // and rough length to debug, never the value.
      final receivedParams = paramsForLog(params);
      final tokenSize = (params['token'] ?? '').length;
      AppLogger.info(
        'Desktop auth: callback hit with params=$receivedParams '
        '(token bytes=$tokenSize)',
      );

      // Validate the CSRF state nonce before processing any data.
      // Constant-time compare so the loopback endpoint can't be used as a
      // timing oracle to recover the nonce byte-by-byte.
      final state = params['state'];
      if (_expectedNonce == null ||
          state == null ||
          !_constantTimeEquals(state, _expectedNonce!)) {
        AppLogger.warning(
          'Desktop auth: callback rejected - state mismatch '
          '(expected=${_expectedNonce != null ? "[set]" : "null"}, '
          'got=${state != null ? "[provided]" : "null"})',
        );
        request.response
          ..statusCode = HttpStatus.forbidden
          ..headers.contentType = ContentType.html
          ..write(_errorHtmlFor(
            title: 'CSRF state mismatch',
            detail:
                'The callback URL is missing the security state nonce, '
                'or it doesn\'t match what this app generated. This usually '
                'means the website auth flow returned without forwarding '
                'the original `state` parameter, or the user opened a stale '
                'sign-in tab.',
            params: receivedParams,
          ))
          ..close();
        // Do NOT tear the server down or complete the waiter: a wrong/absent
        // state is exactly what a hostile local page or process would send to
        // DoS the genuine sign-in. Keep listening for the real callback until
        // the 2-minute timeout in start() fires. Only success or timeout ends
        // the wait.
        return;
      }

      final token = params['token'];
      // A one-time code (N5) the app trades for the session, from a website
      // that got the app's challenge; the token itself from one before.
      final code = params['code'];

      // The website says it did not work (an owner's company sign-in test,
      // 3.3.0): the app says so at once instead of waiting until its time
      // runs out.
      final failed = params['error'];
      if (failed != null && failed.isNotEmpty && (token == null || token.isEmpty) && (code == null || code.isEmpty)) {
        _expectedNonce = null;
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write(_errorHtmlFor(
            title: 'That did not work',
            detail: 'ZestSSH shows what happened and what to check. You can close this tab.',
            params: receivedParams,
          ));
        _answering = _sent(request);
        if (!_completer!.isCompleted) {
          _completer!.completeError(BrowserSignInFailed(
            code: params['error_code'] ?? 'unknown',
            detail: params['error_detail'] ?? '',
          ));
        }
        stop();
        return;
      }

      // zestssh.com's security page, opened by this app to add a passkey
      // (purpose=add-passkey, the two-step contract 7.12), comes back with
      // done=1, or cancelled=1 when the person went back first, and nothing
      // else: the app reads what changed with its own sign-in.
      final done = params['done'] == '1';
      final cancelled = params['cancelled'] == '1';
      if ((done || cancelled) && (token == null || token.isEmpty) && (code == null || code.isEmpty)) {
        _expectedNonce = null;
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write(_backHtml);
        _answering = _sent(request);
        AppLogger.info('Desktop auth: back from the security page (${done ? 'done' : 'cancelled'})');
        if (!_completer!.isCompleted) _completer!.complete({done ? 'done' : 'cancelled': '1'});
        stop();
        return;
      }

      if ((token != null && token.isNotEmpty) || (code != null && code.isNotEmpty)) {
        _expectedNonce = null; // Consume the nonce

        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write(_successHtml);
        _answering = _sent(request);

        AppLogger.info('Desktop auth: ${code != null && code.isNotEmpty ? 'sign-in code' : 'token'} received');

        if (!_completer!.isCompleted) {
          _completer!.complete({
            if (code != null && code.isNotEmpty) 'code': code else 'token': token!,
            if (params['email'] != null) 'email': params['email']!,
            if (params['name'] != null) 'name': params['name']!,
            // Optional avatar URL the auth website may append to the redirect.
            // Absent today (backend change) - the client just ignores it until
            // present, at which point the desktop avatar shows the real photo.
            if (params['picture'] != null) 'picture': params['picture']!,
            // Firebase UID (= RevenueCat app user id); shown as the desktop
            // Account ID. The website appends it now that /session returns it.
            if (params['uid'] != null) 'uid': params['uid']!,
            // What the code is for: 'id-token' for a fresh sign-in handed
            // over for a change (purpose=id-token), none for a session.
            if (params['kind'] != null) 'kind': params['kind']!,
          });
        }
        stop();
      } else {
        // The browser DID hit the callback (so the redirect plumbing
        // works), but the website didn't include a token. Almost
        // always means the website-side completion flow isn't
        // appending `?token=...` to the redirect URL. Surface that
        // clearly to the user - not generic "Sign-in failed".
        AppLogger.warning(
          'Desktop auth: callback missing token (params=$receivedParams)',
        );
        request.response
          ..statusCode = HttpStatus.badRequest
          ..headers.contentType = ContentType.html
          ..write(_errorHtmlFor(
            title: 'Sign-in didn\'t return a token',
            detail:
                'The browser made it back to ZestSSH, but the website '
                'didn\'t include an authentication token in the redirect. '
                'This is a server-side issue - try again from the app, '
                'or contact support if it keeps happening.',
            params: receivedParams,
          ));
        _answering = _sent(request);
        _completeError(
          const AuthCallbackError(AuthCallbackErrorKind.missingToken),
        );
      }
    } else {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Not found')
        ..close();
    }
  }

  /// Length-independent constant-time string comparison. Avoids leaking the
  /// nonce through response-timing on the loopback callback endpoint.
  static bool _constantTimeEquals(String a, String b) {
    final ba = utf8.encode(a);
    final bb = utf8.encode(b);
    // Fold the length difference into the accumulator instead of early
    // return, so timing does not reveal whether the lengths matched.
    var diff = ba.length ^ bb.length;
    final n = ba.length < bb.length ? ba.length : bb.length;
    for (var i = 0; i < n; i++) {
      diff |= ba[i] ^ bb[i];
    }
    return diff == 0;
  }

  /// Complete the pending future with an error and shut the server
  /// down. No-op if the future already resolved.
  void _completeError(AuthCallbackError err) {
    if (_completer != null && !_completer!.isCompleted) {
      _completer!.completeError(err);
    }
    stop();
  }

  /// The answer to [request] sent: when the browser has it all, or could
  /// not be sent it.
  static Future<void> _sent(HttpRequest request) => request.response.close().then<void>((_) {}, onError: (Object _) {});

  /// Stop the server and clean up, once the page being sent has gone (two
  /// seconds at most).
  Future<void> stop() async {
    _timeout?.cancel();
    _timeout = null;
    _expectedNonce = null;
    final answering = _answering;
    if (answering != null) await answering.timeout(const Duration(seconds: 2), onTimeout: () {});
    await _server?.close(force: true);
    _server = null;
  }

  static const _successHtml = '''
<!DOCTYPE html>
<html>
<head>
  <title>ZestSSH</title>
  <style>
    body {
      background: #0A0A0A;
      color: #E8E8E8;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      display: flex;
      justify-content: center;
      align-items: center;
      height: 100vh;
      margin: 0;
    }
    .card {
      text-align: center;
      padding: 48px;
      background: #1A1A1A;
      border-radius: 16px;
      border: 1px solid #333;
    }
    .icon { font-size: 48px; margin-bottom: 16px; }
    h1 { color: #E8600A; font-size: 24px; margin: 0 0 8px 0; }
    p { color: #B0B0B0; font-size: 14px; margin: 0; }
  </style>
</head>
<body>
  <div class="card">
    <div class="icon">&#10003;</div>
    <h1>Signed in to ZestSSH</h1>
    <p>You can close this tab and return to the app.</p>
  </div>
</body>
</html>
''';

  static const _backHtml = '''
<!DOCTYPE html>
<html>
<head>
  <title>ZestSSH</title>
  <style>
    body {
      background: #0A0A0A;
      color: #E8E8E8;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      display: flex;
      justify-content: center;
      align-items: center;
      height: 100vh;
      margin: 0;
    }
    .card {
      text-align: center;
      padding: 48px;
      background: #1A1A1A;
      border-radius: 16px;
      border: 1px solid #333;
    }
    h1 { color: #E8600A; font-size: 24px; margin: 0 0 8px 0; }
    p { color: #B0B0B0; font-size: 14px; margin: 0; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Back to ZestSSH</h1>
    <p>You can close this tab and return to the app.</p>
  </div>
</body>
</html>
''';

  /// Diagnostic error page - replaces the old "No token received"
  /// dead-end with the specific failure cause plus the list of query
  /// parameters that actually came through. Lets the user (and us)
  /// tell at a glance whether the website redirected with no token,
  /// with a stale state, or didn't redirect at all.
  static String _errorHtmlFor({
    required String title,
    required String detail,
    required List<String> params,
  }) {
    // The param list is the request's query-parameter KEYS, which are
    // attacker-controllable on the state-mismatch path (any wrong/absent
    // state reaches this page without knowing the nonce). HTML-escape every
    // interpolated value to prevent reflected XSS in the loopback origin.
    final paramsHtml = params.isEmpty
        ? '<em style="color:#71717A">(none)</em>'
        : params
            .map((p) =>
                '<code style="color:#FF7A1A;font-family:Consolas,monospace">${_escapeHtml(p)}</code>')
            .join(' &middot; ');
    return '''
<!DOCTYPE html>
<html>
<head><title>ZestSSH - Sign-in</title>
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
<style>
  body { background: #0A0A0A; color: #E8E8E8;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    display: flex; justify-content: center; align-items: center;
    min-height: 100vh; margin: 0; padding: 24px; box-sizing: border-box; }
  .card { max-width: 520px; padding: 36px 40px; background: #1A1A1A;
    border-radius: 16px; border: 1px solid #333; }
  h1 { color: #CF6679; font-size: 22px; margin: 0 0 16px 0; }
  p { color: #B0B0B0; font-size: 14px; line-height: 1.55; margin: 0 0 14px 0; }
  .label { color: #71717A; font-size: 11px; letter-spacing: 1px;
    text-transform: uppercase; margin: 18px 0 6px 0; }
  .params { background: #0A0A0A; padding: 10px 14px; border-radius: 8px;
    border: 1px solid #2A2A2A; font-size: 12px; word-break: break-all; }
  .hint { color: #71717A; font-size: 12px; margin-top: 16px; }
</style></head>
<body>
  <div class="card">
    <h1>${_escapeHtml(title)}</h1>
    <p>${_escapeHtml(detail)}</p>
    <div class="label">Callback received</div>
    <div class="params">$paramsHtml</div>
    <p class="hint">You can close this tab and try again from the app.</p>
  </div>
</body>
</html>
''';
  }

  /// Minimal HTML entity escaping for values interpolated into the error
  /// page. Prevents reflected XSS from attacker-controlled query keys.
  static String _escapeHtml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');
}

/// Why the auth callback failed. Caller can use this to render a
/// useful in-app message instead of generic "browser open failed".
enum AuthCallbackErrorKind {
  /// The `state` query parameter was missing or didn't match the nonce
  /// generated by [DesktopAuthServer.start]. Indicates either a CSRF
  /// attempt or (more often) the website forgot to forward the `state`
  /// parameter back to the redirect URL.
  stateMismatch,

  /// The state nonce matched but no `token` query parameter came back.
  /// Usually a website-side bug - the auth flow didn't append the
  /// token to the redirect URL after the user signed in.
  missingToken,
}

/// The browser sign-in was cancelled in the app while it waited.
class NoSignInPort implements Exception, HasTypeName {
  const NoSignInPort([this.cause]);

  /// What the system said, last.
  final Object? cause;

  @override
  String toString() =>
      'No port at or above ${DesktopAuthServer.kLowestCallbackPort} could be had for the browser to come back to '
      '(${ErrorCodes.signInNoPort.code})${cause == null ? '' : ': $cause'}';

  @override
  String get typeName => 'NoSignInPort';
}

/// Waiting for the browser was given up: the person chose Cancel.
class BrowserSignInCancelled implements Exception, HasTypeName {
  const BrowserSignInCancelled();

  @override
  String toString() => 'BrowserSignInCancelled';

  @override
  String get typeName => 'BrowserSignInCancelled';
}

/// The website said the sign-in did not work: its error code (Firebase's,
/// such as auth/invalid-credential) and what the provider said, for Copy
/// details. The words the person reads are the app's own.
class BrowserSignInFailed implements Exception, HasTypeName {
  const BrowserSignInFailed({required this.code, required this.detail});

  final String code;
  final String detail;

  @override
  String toString() => 'BrowserSignInFailed(code: $code, detail: $detail)';

  @override
  String get typeName => 'BrowserSignInFailed';
}

class AuthCallbackError implements Exception, HasTypeName {
  const AuthCallbackError(this.kind);
  final AuthCallbackErrorKind kind;

  /// What the app says of it, in the app's language: it was two English
  /// sentences in every language (found in a code audit).
  String get userMessage {
    switch (kind) {
      case AuthCallbackErrorKind.stateMismatch:
        return gl10n.authCallbackNoState(kZestSupportAddress);
      case AuthCallbackErrorKind.missingToken:
        return gl10n.authCallbackNoToken(kZestSupportAddress);
    }
  }

  @override
  String toString() => 'AuthCallbackError($kind)';

  @override
  String get typeName => 'AuthCallbackError';
}
