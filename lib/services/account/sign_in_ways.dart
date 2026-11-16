import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/services/account/device_sessions.dart' show DeviceSessionHeader;
import 'package:zestssh/services/account_bearer.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/services/auth_service.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/type_name.dart';

/// How an account signs in (3.0: one account per email address). Google,
/// Apple and an email with a password are ways into ONE account: an account
/// made through Google or Apple has no password until its owner sets one
/// with the emailed link, and then signs in either way.

/// One way into an account.
enum SignInWay { google, apple, microsoft, company, password }

/// The way a Firebase provider id stands for, or null for one ZestSSH does
/// not offer. (The server reads them the same way: routes/account.js.)
SignInWay? signInWayOf(String providerId) {
  switch (providerId) {
    case 'google.com':
      return SignInWay.google;
    case 'apple.com':
      return SignInWay.apple;
    case 'microsoft.com':
      return SignInWay.microsoft;
    case 'password':
      return SignInWay.password;
  }
  // An Orchard's company sign-in (3.0).
  if (providerId.startsWith('saml.') || providerId.startsWith('oidc.')) return SignInWay.company;
  return null;
}

/// The ways an account signs in, and the address it is for.
class SignInWays {
  const SignInWays({required this.email, required this.ways});

  /// From the providers Firebase lists for the user signed in on this
  /// device: each way once, in the order they are named everywhere.
  factory SignInWays.fromProviders(String email, Iterable<String> providerIds) => SignInWays(
        email: email,
        ways: _ordered({for (final id in providerIds) ?signInWayOf(id)}),
      );

  /// From ZestSSH Cloud's answer to `GET /v1/account/sign-in-methods`.
  factory SignInWays.fromJson(Map<String, dynamic> json) {
    final methods = json['methods'];
    return SignInWays(
      email: json['email'] is String ? json['email'] as String : '',
      ways: _ordered({
        if (methods is List)
          for (final m in methods)
            for (final way in SignInWay.values)
              if (way.name == m) way,
      }),
    );
  }

  final String email;
  final List<SignInWay> ways;

  /// Whether the account has a password (then it also signs in with its
  /// address and that password).
  bool get hasPassword => ways.contains(SignInWay.password);

  static List<SignInWay> _ordered(Set<SignInWay> ways) => [
        for (final way in SignInWay.values)
          if (ways.contains(way)) way,
      ];
}

/// ZestSSH Cloud would not take the sign-in: its address belongs to another
/// ZestSSH account, which signs in another way (`email-has-account`). The
/// person is to sign in to that account the way they made it, or set a
/// password for it with the emailed link.
class AddressHasAccount implements Exception, HasTypeName {
  const AddressHasAccount();

  static const code = 'email-has-account';

  @override
  String toString() => 'AddressHasAccount';

  @override
  String get typeName => 'AddressHasAccount';
}

/// What ZestSSH Cloud says about the ways the signed-in account signs in.
class SignInWaysApi {
  SignInWaysApi({
    http.Client? client,
    String? baseUrl,
    required this.bearer,
  })  : _client = client ?? PinnedHttpClient.client,
        _base = baseUrl ?? _defaultBase;

  static String get _defaultBase => kZestApiBase;

  final http.Client _client;
  final String _base;

  /// The account's bearer: the Firebase ID token when signed in with
  /// Firebase, else the session token. Null when signed out.
  final Future<String?> Function() bearer;

  /// The ways the account signs in. Throws [AddressHasAccount] when ZestSSH
  /// Cloud refuses the sign-in because its address belongs to another
  /// account, a [SignInWaysException] when it cannot say.
  Future<SignInWays> load() async {
    final token = await bearer();
    if (token == null) throw const SignInWaysException(401, 'signed-out');
    final r = await _client.get(
      Uri.parse('$_base/account/sign-in-methods'),
      headers: {'Authorization': 'Bearer $token', ...DeviceSessionHeader.headers},
    ).timeout(const Duration(seconds: 20));
    Object? body;
    try {
      body = jsonDecode(r.body);
    } catch (_) {
      body = null;
    }
    final code = body is Map && body['code'] is String ? body['code'] as String : null;
    if (code == AddressHasAccount.code) throw const AddressHasAccount();
    if (r.statusCode != 200 || body is! Map<String, dynamic>) {
      throw SignInWaysException(r.statusCode, code ?? 'unexpected');
    }
    return SignInWays.fromJson(body);
  }
}

class SignInWaysException implements Exception, HasTypeName {
  const SignInWaysException(this.status, this.code);

  final int status;
  final String code;

  @override
  String toString() => 'SignInWaysException($status, $code)';

  @override
  String get typeName => 'SignInWaysException';
}

/// The ways the account signed in here signs in; null while signed out. A
/// phone, a tablet or a Mac signed in with Firebase knows them itself (asked
/// afresh, so a password set from the emailed link shows); a computer signed
/// in through the browser asks ZestSSH Cloud.
final signInWaysProvider = FutureProvider.autoDispose<SignInWays?>((ref) async {
  final account = ref.watch(currentUserProvider);
  if (account == null) return null;
  final user = AuthService.currentUser;
  if (user == null) return SignInWaysApi(bearer: accountBearer).load();
  try {
    await user.reload();
  } catch (e) {
    // Offline: what this device knew is still right but for a way added
    // elsewhere since.
    AppLogger.warning('Sign-in ways: not refreshed ($e)');
  }
  final fresh = AuthService.currentUser ?? user;
  return SignInWays.fromProviders(
    fresh.email ?? account.email ?? '',
    fresh.providerData.map((p) => p.providerId),
  );
});

/// Emails a link to choose a password to an address; false when it could not
/// be sent ([AuthService.sendPasswordLink]; a provider so that a test can
/// stand in for it).
final passwordLinkSenderProvider = Provider<Future<bool> Function(String email)>(
  (ref) => AuthService.sendPasswordLink,
);

/// Opens the page a computer goes to where the link could not be sent; false
/// where the system opened nothing (a provider so that a test can stand in for it).
final passwordLinkPageOpenerProvider = Provider<Future<bool> Function()>(
  (ref) => () async {
    try {
      return await launchUrl(AuthService.passwordLinkPage, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  },
);
