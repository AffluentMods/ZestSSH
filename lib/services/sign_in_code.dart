import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as c;
import 'package:http/http.dart' as http;
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/utils/type_name.dart';
import 'package:zestssh/services/pinned_http_client.dart';

/// A computer's sign-in through the browser with a one-time code (from a
/// security review of the client). The browser came back to the
/// app with the 30-day session token in the callback's address, so the token
/// stayed in the browser's history (and, where history syncs, on other
/// machines). Now the app keeps a secret ([verifier]) and sends its SHA-256
/// ([challenge]) with the sign-in, as OAuth's PKCE does (RFC 7636, S256):
/// ZestSSH Cloud gives the browser a code, good once and for two minutes,
/// that only this app, with the secret, can trade for the session ([redeem]).
class SignInCode {
  SignInCode._(this.verifier, this.challenge);

  /// A new secret, from [random] (the system's secure one unless given).
  factory SignInCode.make([Random? random]) {
    final r = random ?? Random.secure();
    final verifier = _b64(List<int>.generate(32, (_) => r.nextInt(256)));
    return SignInCode._(verifier, challengeOf(verifier));
  }

  /// The secret this device keeps.
  final String verifier;

  /// What goes in the sign-in link: the secret's SHA-256.
  final String challenge;

  /// The challenge of [verifier]: its SHA-256, base64url without padding.
  static String challengeOf(String verifier) => _b64(c.sha256.convert(ascii.encode(verifier)).bytes);

  static String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

  static String get _base => kZestApiBase;

  /// Trades [code] for the session: its token, and what ZestSSH Cloud says
  /// of the account ('email', 'name', 'uid'). Throws [SignInCodeRefused]
  /// when ZestSSH Cloud refuses it, and what [client] throws when it cannot
  /// be reached. [baseUrl]: ZestSSH Cloud's API (tests).
  Future<({String token, Map<String, String> user})> redeem(String code, {http.Client? client, String? baseUrl}) async {
    final resp = await (client ?? PinnedHttpClient.client)
        .post(
          Uri.parse('${baseUrl ?? _base}/auth/session/redeem'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'code': code, 'verifier': verifier}),
        )
        .timeout(const Duration(seconds: 20));
    Object? body;
    try {
      body = jsonDecode(resp.body);
    } on FormatException {
      body = null;
    }
    final token = body is Map ? body['session_token'] : null;
    if (resp.statusCode != 200 || token is! String || token.isEmpty) {
      throw SignInCodeRefused(resp.statusCode, body is Map && body['code'] is String ? body['code'] as String : null);
    }
    final user = (body as Map)['user'];
    String? field(String key) => user is Map && user[key] is String && (user[key] as String).isNotEmpty ? user[key] as String : null;
    return (
      token: token,
      user: {
        'email': ?field('email'),
        'name': ?field('display_name'),
        'uid': ?field('firebase_uid'),
      },
    );
  }
}

/// ZestSSH Cloud did not trade a sign-in code for the session: the code ran
/// out, was used, or the secret was not its own ([code] says, when it does).
class SignInCodeRefused implements Exception, HasTypeName {
  const SignInCodeRefused(this.status, this.code);

  final int status;
  final String? code;

  @override
  String get typeName => 'SignInCodeRefused';

  @override
  String toString() => 'Sign-in code refused (HTTP $status${code == null ? '' : ', $code'})';
}
