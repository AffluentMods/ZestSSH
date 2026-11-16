import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/pinned_http_client.dart';

/// A domain an Orchard claimed, proven or not (3.0): company SSO
/// and directory sync are bound to proven ones.
class OrchardDomain {
  const OrchardDomain({
    required this.domain,
    required this.verified,
    this.verifiedAt,
    this.checkedAt,
    this.txt,
  });

  final String domain;
  final bool verified;
  final DateTime? verifiedAt;

  /// When ZestSSH Cloud last looked the record up.
  final DateTime? checkedAt;

  /// The DNS TXT record that proves the claim; owners only.
  final String? txt;

  static OrchardDomain? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final domain = raw['domain'];
    if (domain is! String) return null;
    DateTime? at(Object? v) => v is String ? DateTime.tryParse(v) : null;
    return OrchardDomain(
      domain: domain,
      verified: raw['verified'] == true,
      verifiedAt: at(raw['verified_at']),
      checkedAt: at(raw['checked_at']),
      txt: raw['txt'] is String ? raw['txt'] as String : null,
    );
  }
}

/// A domain check that found no record yet: [txt] is what to publish.
class DomainNotProven extends OrchardServerException {
  const DomainNotProven(this.txt) : super(409, 'not-proven');

  final String? txt;

  @override
  String get typeName => 'DomainNotProven';
}

/// ZestSSH Cloud's domain routes for Orchards: the domains an Orchard
/// claimed, claiming one, looking its record up, and dropping it. Errors
/// are [OrchardServerException]s: 'forbidden' (owners only),
/// 'domain-taken' (another Orchard proved it), 'domain-limit',
/// 'invalid-request', 'rate-limited', 'recent-sign-in-required' (dropping a
/// proven domain), 'not-found', or [DomainNotProven].
class OrchardDomainsApi {
  OrchardDomainsApi({http.Client? client, String? baseUrl, required this.bearer})
      : _client = client ?? PinnedHttpClient.client,
        _base = baseUrl ?? OrchardsApi.defaultBase;

  final http.Client _client;
  final String _base;

  /// The account's bearer: the Firebase ID token on phones, the session
  /// token on desktop. Null when signed out.
  final Future<String?> Function() bearer;

  static const _timeout = Duration(seconds: 30);

  Uri _uri(String orchardId, [String? tail]) =>
      Uri.parse('$_base/orchards/$orchardId/domains${tail == null ? '' : '/$tail'}');

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
    Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(response.body);
      body = decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      body = const {};
    }
    if (response.statusCode == 200 || response.statusCode == 201) return body;
    final code = body['code'] is String ? body['code'] as String : null;
    if (response.statusCode == 409 && code == 'not-proven') {
      throw DomainNotProven(body['txt'] is String ? body['txt'] as String : null);
    }
    throw OrchardServerException(response.statusCode, code);
  }

  OrchardDomain _one(Map<String, dynamic> body) =>
      OrchardDomain.fromJson(body) ?? (throw const FormatException('Not a domain'));

  /// The domains [orchardId] claimed, in order.
  Future<List<OrchardDomain>> list(String orchardId) async {
    final body = await _send((h) => _client.get(_uri(orchardId), headers: h));
    final list = body['domains'];
    if (list is! List) throw const FormatException('Not a list of domains');
    return [for (final d in list) ?OrchardDomain.fromJson(d)];
  }

  /// Claims [domain] (the server keeps it in lower case): the claim, with
  /// the record to publish.
  Future<OrchardDomain> claim(String orchardId, String domain) async => _one(await _send(
        (h) => _client.post(_uri(orchardId), headers: h, body: jsonEncode({'domain': domain})),
        json: true,
      ));

  /// Looks the claim's record up: the proven domain, or [DomainNotProven].
  Future<OrchardDomain> verify(String orchardId, String domain) async =>
      _one(await _send((h) => _client.post(_uri(orchardId, '${Uri.encodeComponent(domain)}/verify'), headers: h)));

  /// Drops the claim (or the proof).
  Future<void> drop(String orchardId, String domain) =>
      _send((h) => _client.delete(_uri(orchardId, Uri.encodeComponent(domain)), headers: h));
}
