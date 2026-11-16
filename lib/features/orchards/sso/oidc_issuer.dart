import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

/// The issuer an OpenID provider gives for itself, read from its discovery
/// document (`<issuer>/.well-known/openid-configuration`); null where it
/// cannot be read. An issuer must match what the provider puts in its
/// tokens exactly: "https://example.okta.com/" (as typed) is not Okta's
/// "https://example.okta.com", and every sign-in through it was refused
/// (seen in an Okta OIDC test).
Future<String?> readOidcIssuer(String typed, {http.Client? client}) async {
  final base = typed.trim().replaceFirst(RegExp(r'/+$'), '');
  final uri = Uri.tryParse('$base/.well-known/openid-configuration');
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  final c = client ?? http.Client();
  try {
    final r = await c.get(uri, headers: const {'Accept': 'application/json'}).timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return null;
    final body = jsonDecode(r.body);
    final issuer = body is Map ? body['issuer'] : null;
    return issuer is String && issuer.startsWith('https://') ? issuer : null;
  } catch (_) {
    return null;
  } finally {
    if (client == null) c.close();
  }
}

/// Whether [a] and [b] name the same issuer but for a slash at the end.
bool sameIssuerButSlash(String a, String b) => a.replaceFirst(RegExp(r'/+$'), '') == b.replaceFirst(RegExp(r'/+$'), '');

/// How the company sign-in page reads an issuer before saving it. Tests run
/// with no network: there it takes the issuer as typed, unless a test puts
/// its own.
final oidcIssuerReaderProvider = Provider<Future<String?> Function(String typed)>((ref) {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return (typed) async => typed.trim();
  return readOidcIssuer;
});
