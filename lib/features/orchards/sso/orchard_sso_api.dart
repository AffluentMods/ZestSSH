import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/pinned_http_client.dart';

/// An Orchard's provider id, as ZestSSH Cloud makes them (3.0):
/// 'saml.zo-' or 'oidc.zo-', then 32 hex.
final _providerId = RegExp(r'^(saml|oidc)\.zo-[0-9a-f]{32}$');

/// Whether [id] has the form of an Orchard's company sign-in provider id.
bool isOrchardSsoProvider(String? id) => id != null && _providerId.hasMatch(id);

/// The kinds of company sign-in an Orchard can have.
enum SsoKind {
  saml,
  oidc;

  static SsoKind? parse(Object? v) => switch (v) {
        'saml' => SsoKind.saml,
        'oidc' => SsoKind.oidc,
        _ => null,
      };
}

/// What the company's provider is told about ZestSSH: where its answer
/// comes back, and who is asking.
class SsoServiceSide {
  const SsoServiceSide({this.samlAcsUrl, this.samlEntityId, this.oidcRedirectUri});

  /// SAML: the Assertion Consumer Service (reply) URL.
  final String? samlAcsUrl;

  /// SAML: the service provider's entity id (audience).
  final String? samlEntityId;

  /// OIDC: the redirect URI.
  final String? oidcRedirectUri;

  static SsoServiceSide fromJson(Object? raw) {
    String? text(Object? m, String k) => m is Map && m[k] is String ? m[k] as String : null;
    final saml = raw is Map ? raw['saml'] : null;
    final oidc = raw is Map ? raw['oidc'] : null;
    return SsoServiceSide(
      samlAcsUrl: text(saml, 'acs_url'),
      samlEntityId: text(saml, 'entity_id'),
      oidcRedirectUri: text(oidc, 'redirect_uri'),
    );
  }
}

/// An Orchard's company sign-in as ZestSSH Cloud keeps it (owners only).
/// Nothing secret: an OIDC client secret goes to Identity Platform only,
/// and a SAML certificate is kept as its fingerprint.
class OrchardSso {
  const OrchardSso({
    this.kind,
    this.displayName,
    this.config = const {},
    this.active = false,
    this.testedAt,
    this.providerId,
    this.service = const SsoServiceSide(),
    this.domains = const [],
    this.testedEmail,
  });

  /// Null until it is set up.
  final SsoKind? kind;
  final String? displayName;

  /// SAML: sso_url, idp_entity_id, certificate_sha256,
  /// certificate_valid_to. OIDC: issuer, client_id.
  final Map<String, String> config;

  /// Turned on: people sign in through it, and "Sign in with SSO" finds it.
  final bool active;

  /// When a sign-in through it last proved it works; null until then, and
  /// again after every change.
  final DateTime? testedAt;
  final String? providerId;
  final SsoServiceSide service;

  /// The Orchard's proven domains: the addresses it answers for.
  final List<String> domains;

  /// The address a test sign-in came back with (only from [OrchardSsoApi.test]).
  final String? testedEmail;

  bool get isSetUp => kind != null;
  bool get isTested => testedAt != null;

  /// When the SAML certificate runs out; null for none (or OIDC).
  DateTime? get certificateValidTo => DateTime.tryParse(config['certificate_valid_to'] ?? '');

  static OrchardSso fromJson(Map<String, dynamic> raw) {
    final config = raw['config'];
    final domains = raw['domains'];
    return OrchardSso(
      kind: SsoKind.parse(raw['kind']),
      displayName: raw['display_name'] is String ? raw['display_name'] as String : null,
      config: {
        if (config is Map)
          for (final e in config.entries)
            if (e.key is String && e.value is String) e.key as String: e.value as String,
      },
      active: raw['active'] == true,
      testedAt: raw['tested_at'] is String ? DateTime.tryParse(raw['tested_at'] as String) : null,
      providerId: isOrchardSsoProvider(raw['provider_id'] as String?) ? raw['provider_id'] as String : null,
      service: SsoServiceSide.fromJson(raw['service']),
      domains: [
        if (domains is List)
          for (final d in domains)
            if (d is String) d,
      ],
      testedEmail: raw['email'] is String ? raw['email'] as String : null,
    );
  }
}

/// The company sign-in "Sign in with SSO" found for a domain.
class SsoLookup {
  const SsoLookup({required this.providerId, required this.displayName});

  final String providerId;
  final String displayName;

  SsoKind get kind => providerId.startsWith('saml.') ? SsoKind.saml : SsoKind.oidc;
}

/// A field ZestSSH Cloud refused, by name ('display_name', 'sso_url',
/// 'idp_entity_id', 'certificate', 'issuer', 'client_id', 'client_secret',
/// 'kind'); [code] is 'invalid-sso', or 'certificate-expired'.
class SsoFieldInvalid extends OrchardServerException {
  const SsoFieldInvalid(this.field, String code) : super(400, code);

  final String field;

  @override
  String get typeName => 'SsoFieldInvalid';
}

/// ZestSSH Cloud's company sign-in routes for an Orchard (owners):
/// what is set up, setting a provider up or changing it (it goes to
/// Identity Platform and stays off until a sign-in through it is tested),
/// the test, turning it on, and removing it. Errors are
/// [OrchardServerException]s: 'forbidden' (owners only), 'domain-required'
/// (prove a domain first), [SsoFieldInvalid], 'provider-rejected'
/// (Identity Platform did not take it), 'sso-not-set-up', 'sso-not-tested',
/// 'sso-test-failed', 'sso-domain-mismatch' (the test address is outside
/// the proven domains), 'sso-required-by-rules' (removing it while the
/// rules require it), 'recent-sign-in-required', 'rate-limited',
/// 'not-found'.
class OrchardSsoApi {
  OrchardSsoApi({http.Client? client, String? baseUrl, required this.bearer})
      : _client = client ?? PinnedHttpClient.client,
        _base = baseUrl ?? OrchardsApi.defaultBase;

  final http.Client _client;
  final String _base;

  /// The account's bearer: the Firebase ID token on phones, the session
  /// token on desktop. Null when signed out.
  final Future<String?> Function() bearer;

  static const _timeout = Duration(seconds: 30);

  Uri _uri(String orchardId, [String? tail]) =>
      Uri.parse('$_base/orchards/$orchardId/sso${tail == null ? '' : '/$tail'}');

  Future<Map<String, dynamic>> _send(Future<http.Response> Function(Map<String, String> headers) send,
      {bool json = false}) async {
    final token = await bearer();
    if (token == null) throw const OrchardServerException(401, 'signed-out');
    final response = await send({
      'Authorization': 'Bearer $token',
      ...DeviceSessionHeader.headers,
      if (json) 'Content-Type': 'application/json',
    }).timeout(_timeout);
    reportIfSessionRevoked(response);
    final body = _decode(response.body);
    if (response.statusCode == 200 || response.statusCode == 201) return body;
    final code = body['code'] is String ? body['code'] as String : null;
    if (response.statusCode == 400 && body['field'] is String) {
      throw SsoFieldInvalid(body['field'] as String, code ?? 'invalid-sso');
    }
    throw OrchardServerException(response.statusCode, code);
  }

  static Map<String, dynamic> _decode(String text) {
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  /// What [orchardId] has set up (a blank [OrchardSso] when nothing), with
  /// what to tell the company's provider and the proven domains.
  Future<OrchardSso> get(String orchardId) async =>
      OrchardSso.fromJson(await _send((h) => _client.get(_uri(orchardId), headers: h)));

  /// Sets a SAML provider up, or changes it: it stays off until tested.
  /// Leaving [certificate] null keeps the certificate a SAML provider has.
  Future<OrchardSso> setSaml(
    String orchardId, {
    required String displayName,
    required String ssoUrl,
    required String idpEntityId,
    String? certificate,
  }) =>
      _put(orchardId, {
        'kind': 'saml',
        'display_name': displayName,
        'saml': {'sso_url': ssoUrl, 'idp_entity_id': idpEntityId, 'certificate': ?certificate},
      });

  /// Sets an OIDC provider up, or changes it: it stays off until tested.
  /// Leaving [clientSecret] null keeps the secret an OIDC provider has.
  Future<OrchardSso> setOidc(
    String orchardId, {
    required String displayName,
    required String issuer,
    required String clientId,
    String? clientSecret,
  }) =>
      _put(orchardId, {
        'kind': 'oidc',
        'display_name': displayName,
        'oidc': {'issuer': issuer, 'client_id': clientId, 'client_secret': ?clientSecret},
      });

  Future<OrchardSso> _put(String orchardId, Map<String, Object?> body) async => OrchardSso.fromJson(await _send(
        (h) => _client.put(_uri(orchardId), headers: h, body: jsonEncode(body)),
        json: true,
      ));

  /// Proves the provider works with [idToken], a Firebase sign-in through
  /// it by an address at a proven domain: [OrchardSso.testedAt] is set.
  Future<OrchardSso> test(String orchardId, SsoTestSignIn signIn) async => OrchardSso.fromJson(await _send(
        (h) => _client.post(_uri(orchardId, 'test'), headers: h, body: jsonEncode(signIn.body)),
        json: true,
      ));

  /// Turns it on, once tested.
  Future<OrchardSso> activate(String orchardId) async =>
      OrchardSso.fromJson(await _send((h) => _client.post(_uri(orchardId, 'activate'), headers: h)));

  /// Removes it, here and at Identity Platform.
  Future<void> remove(String orchardId) async {
    await _send((h) => _client.delete(_uri(orchardId), headers: h));
  }

  /// The company sign-in that answers for [domain] ("Sign in with SSO"),
  /// or null when none does. Public: only the domain is sent.
  static Future<SsoLookup?> lookup(String domain, {http.Client? client, String? baseUrl}) async {
    final uri = Uri.parse('${baseUrl ?? OrchardsApi.defaultBase}/sso/lookup')
        .replace(queryParameters: {'domain': domain});
    final response = await (client ?? PinnedHttpClient.client).get(uri).timeout(_timeout);
    if (response.statusCode == 404) return null;
    final body = _decode(response.body);
    if (response.statusCode != 200) {
      throw OrchardServerException(response.statusCode, body['code'] is String ? body['code'] as String : null);
    }
    final id = body['provider_id'];
    if (id is! String || !isOrchardSsoProvider(id)) throw const FormatException('Not a company sign-in');
    final name = body['display_name'];
    return SsoLookup(providerId: id, displayName: name is String && name.isNotEmpty ? name : id);
  }
}

/// The domain of a work address, lower case; null when it is not one.
String? workAddressDomain(String email) {
  final s = email.trim().toLowerCase();
  final at = s.lastIndexOf('@');
  if (at < 1) return null;
  var domain = s.substring(at + 1);
  if (domain.endsWith('.')) domain = domain.substring(0, domain.length - 1);
  return _domain.hasMatch(domain) ? domain : null;
}

final _domain = RegExp(r'^(?=.{3,253}$)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$');

/// A sign-in through a company's provider for its owner's test: its
/// ID token, where the app signed in through it itself (a phone), or the
/// one-time code the website gave the app for it and the app's secret,
/// where the browser did (a computer), so no sign-in stays in the
/// browser's history.
class SsoTestSignIn {
  const SsoTestSignIn.idToken(String this.idToken)
      : code = null,
        verifier = null;

  const SsoTestSignIn.code(String this.code, String this.verifier) : idToken = null;

  final String? idToken;
  final String? code;
  final String? verifier;

  /// What the test's request carries.
  Map<String, String> get body => idToken != null ? {'id_token': idToken!} : {'code': code!, 'verifier': verifier!};
}
