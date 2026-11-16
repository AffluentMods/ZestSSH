import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/utils/type_name.dart';
import 'package:zestssh/services/own_network_http.dart';
import 'package:zestssh/services/server_stats_service.dart';

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

enum PrometheusTestResult {
  success,
  caNotTrusted,
  clientCertRejected,

  /// The client certificate set (a .p12 file) could not be opened here: a
  /// wrong password, or not a PKCS#12 file.
  clientCertUnreadable,
  authFailed,
  unreachable,
  unknownError,
}

// ---------------------------------------------------------------------------
// Data classes
// ---------------------------------------------------------------------------

class PrometheusTarget {
  final String instance;
  final String job;

  const PrometheusTarget({required this.instance, required this.job});
}

/// Whether a Prometheus server's certificate may go unchecked (Verify SSL
/// off): where plain http may go too ([OwnNetworkHttpClient]), so where no
/// login is sent, or to an address on the person's own network. Elsewhere a
/// token or a password would go to whoever answers, so it is checked.
bool prometheusMaySkipVerify({required PrometheusAuthType auth, required String host}) =>
    auth == PrometheusAuthType.none || isOwnNetworkHost(host);

/// The client certificate set (a .p12 file) did not open: thrown before
/// anything is sent.
class ClientCertUnreadable extends TlsException implements HasTypeName {
  const ClientCertUnreadable([super.message, super.osError]);

  @override
  String get typeName => 'ClientCertUnreadable';
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

class PrometheusService {
  final String baseUrl;
  final PrometheusAuthType authType;
  final String? bearerToken;
  final String? basicAuthUser;
  final String? basicAuthPassword;
  final String? customHeaderKey;
  final String? customHeaderValue;
  final String? caPem;
  final Uint8List? clientCertP12Bytes;
  final String? clientCertPassword;
  final bool verifySsl;

  PrometheusService({
    required this.baseUrl,
    required this.authType,
    this.bearerToken,
    this.basicAuthUser,
    this.basicAuthPassword,
    this.customHeaderKey,
    this.customHeaderValue,
    this.caPem,
    this.clientCertP12Bytes,
    this.clientCertPassword,
    this.verifySsl = true,
  });

  // ---- helpers ------------------------------------------------------------

  Map<String, String> _buildHeaders() {
    final headers = <String, String>{
      'Accept': 'application/json',
    };

    switch (authType) {
      case PrometheusAuthType.bearerToken:
        if (bearerToken != null) {
          headers['Authorization'] = 'Bearer $bearerToken';
        }
        break;
      case PrometheusAuthType.basicAuth:
        if (basicAuthUser != null && basicAuthPassword != null) {
          final credentials =
              base64Encode(utf8.encode('$basicAuthUser:$basicAuthPassword'));
          headers['Authorization'] = 'Basic $credentials';
        }
        break;
      case PrometheusAuthType.customHeader:
        if (customHeaderKey != null && customHeaderValue != null) {
          headers[customHeaderKey!] = customHeaderValue!;
        }
        break;
      case PrometheusAuthType.none:
        break;
    }

    return headers;
  }

  /// One GET with this server's sign-in headers.
  ///
  /// Plain http follows the app's one rule (`own_network_http.dart`): when a
  /// login is sent (a token, a password, a custom header), only to an
  /// address on the person's own network; when the server asks for no login
  /// there is no secret on the wire and any address will do. The same client
  /// is what lets an `http://` Prometheus work on a phone at all, where
  /// Flutter refuses plain http wholesale.
  Future<http.Response> _get(Uri uri) async {
    // Verify SSL off leaves the certificate unchecked only where that may be:
    // no login sent, or an address on the person's own network, by where the
    // name leads and not only by how it is written.
    final skipVerify = !verifySsl &&
        prometheusMaySkipVerify(auth: authType, host: uri.host) &&
        (authType == PrometheusAuthType.none || await leadsToOwnNetwork(uri.host));
    final client = OwnNetworkHttpClient(
      inner: _transport(uri, skipVerify: skipVerify),
      plainHttp: authType == PrometheusAuthType.none
          ? PlainHttp.anywhere
          : PlainHttp.ownNetworkOnly,
    );
    try {
      // Thirty seconds: a server that never answers held the screen for good
      // (found in a code audit).
      return await client.get(uri, headers: _buildHeaders()).timeout(const Duration(seconds: 30));
    } finally {
      client.close();
    }
  }

  /// The connection this server's TLS settings ask for: its own CA trusted
  /// beside the system's, its client certificate (mutual TLS) presented, and
  /// the certificate unchecked where Verify SSL is off and that may be
  /// ([prometheusMaySkipVerify]). They were saved and never used: every
  /// request went out with the system's trust alone (found in a
  /// check).
  http.Client _transport(Uri uri, {required bool skipVerify}) {
    final context = SecurityContext(withTrustedRoots: true);
    final ca = caPem?.trim();
    if (ca != null && ca.isNotEmpty) {
      context.setTrustedCertificatesBytes(utf8.encode(ca));
    }
    final p12 = clientCertP12Bytes;
    if (p12 != null && p12.isNotEmpty) {
      try {
        context
          ..useCertificateChainBytes(p12, password: clientCertPassword)
          ..usePrivateKeyBytes(p12, password: clientCertPassword);
      } on TlsException catch (e) {
        throw ClientCertUnreadable(e.message, e.osError);
      }
    }
    final io = HttpClient(context: context);
    if (skipVerify) {
      io.badCertificateCallback = (cert, host, port) => true;
    }
    return IOClient(io);
  }

  // ---- public API ---------------------------------------------------------

  /// Test the connection to the Prometheus server.
  ///
  /// Returns a tuple of [PrometheusTestResult] and an optional error message.
  Future<(PrometheusTestResult, String?)> testConnection() async {
    try {
      final uri = Uri.parse('$baseUrl/api/v1/status/buildinfo');
      final response = await _get(uri);

      if (response.statusCode == 200) {
        return (PrometheusTestResult.success, null);
      } else if (response.statusCode == 401 || response.statusCode == 403) {
        return (
          PrometheusTestResult.authFailed,
          'Authentication failed (${response.statusCode})',
        );
      } else {
        return (
          PrometheusTestResult.unknownError,
          'Unexpected status code: ${response.statusCode}',
        );
      }
    } on PlainHttpRefused catch (e) {
      return (PrometheusTestResult.unknownError, e.message);
    } on TlsException catch (e) {
      return (tlsFailureKind(e, clientCertSet: _clientCertSet), e.toString());
    } on SocketException catch (e) {
      return (await _closedKind(e, PrometheusTestResult.unreachable), e.toString());
    } on HttpException catch (e) {
      return (await _closedKind(e, PrometheusTestResult.unreachable), e.toString());
    } catch (e) {
      return (await _closedKind(e, PrometheusTestResult.unknownError), e.toString());
    }
  }

  bool get _clientCertSet => clientCertP12Bytes?.isNotEmpty ?? false;

  /// What a connection that ended without an answer says. With TLS 1.3 a
  /// server refuses a client certificate after the handshake, so the refusal
  /// comes as the connection closing, or as an alert inside another error.
  /// An alert about a certificate, or a server that answers the same request
  /// sent without the client certificate, is the client certificate
  /// refused; anything else is [otherwise].
  Future<PrometheusTestResult> _closedKind(Object error, PrometheusTestResult otherwise) async {
    if (!_clientCertSet || error is PlainHttpRefused) return otherwise;
    final said = error.toString().toUpperCase();
    if (_refusedAlerts.any(said.contains)) return PrometheusTestResult.clientCertRejected;
    try {
      final without = PrometheusService(
        baseUrl: baseUrl,
        authType: authType,
        bearerToken: bearerToken,
        basicAuthUser: basicAuthUser,
        basicAuthPassword: basicAuthPassword,
        customHeaderKey: customHeaderKey,
        customHeaderValue: customHeaderValue,
        caPem: caPem,
        verifySsl: verifySsl,
      );
      await without._get(Uri.parse('$baseUrl/api/v1/status/buildinfo'));
      return PrometheusTestResult.clientCertRejected;
    } catch (_) {
      return otherwise;
    }
  }

  /// The alerts a server sends about the certificate this device presented
  /// (or did not).
  static const _refusedAlerts = [
    'ALERT_CERTIFICATE_REQUIRED',
    'ALERT_BAD_CERTIFICATE',
    'ALERT_UNKNOWN_CA',
    'ALERT_CERTIFICATE_UNKNOWN',
    'ALERT_CERTIFICATE_REVOKED',
    'ALERT_CERTIFICATE_EXPIRED',
    'ALERT_UNSUPPORTED_CERTIFICATE',
    'ALERT_ACCESS_DENIED',
  ];

  /// What a TLS failure of a test says (22 October 2026: every one was "CA
  /// not trusted", so a client certificate the server refused was never
  /// said). The server's certificate that does not check is the CA; an
  /// alert the server sends about the certificate this device presented
  /// (or did not) is the client certificate refused; a .p12 file that does
  /// not open is unreadable.
  static PrometheusTestResult tlsFailureKind(TlsException e, {required bool clientCertSet}) {
    final said = '${e.message} ${e.osError?.message ?? ''}'.toUpperCase();
    if (said.contains('CERTIFICATE_VERIFY_FAILED')) return PrometheusTestResult.caNotTrusted;
    if (_refusedAlerts.any(said.contains)) return PrometheusTestResult.clientCertRejected;
    // A handshake failure where a client certificate was presented.
    if (said.contains('ALERT_HANDSHAKE_FAILURE')) {
      return clientCertSet ? PrometheusTestResult.clientCertRejected : PrometheusTestResult.unknownError;
    }
    if (e is ClientCertUnreadable) return PrometheusTestResult.clientCertUnreadable;
    if (e is! HandshakeException) return PrometheusTestResult.unknownError;
    return PrometheusTestResult.caNotTrusted;
  }

  /// Discover active Prometheus scrape targets.
  Future<List<PrometheusTarget>> discoverTargets() async {
    final uri = Uri.parse('$baseUrl/api/v1/targets');
    final response = await _get(uri);

    if (response.statusCode != 200) {
      throw HttpException(
        'Failed to discover targets: ${response.statusCode}',
      );
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final data = json['data'] as Map<String, dynamic>?;
    final activeTargets = data?['activeTargets'] as List<dynamic>? ?? [];

    return activeTargets.map((t) {
      final labels = t['labels'] as Map<String, dynamic>? ?? {};
      return PrometheusTarget(
        instance: labels['instance']?.toString() ?? '',
        job: labels['job']?.toString() ?? '',
      );
    }).toList();
  }

  /// Query basic node_exporter metrics for a specific instance.
  Future<ServerStats> getBasicStats(String instance) async {
    Future<double?> queryScalar(String promql) async {
      final uri = Uri.parse('$baseUrl/api/v1/query').replace(
        queryParameters: {'query': promql},
      );
      final response = await _get(uri);
      if (response.statusCode != 200) return null;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final result =
          (json['data'] as Map<String, dynamic>?)?['result'] as List<dynamic>?;
      if (result == null || result.isEmpty) return null;

      final value = result.first['value'] as List<dynamic>?;
      if (value == null || value.length < 2) return null;
      return double.tryParse(value[1].toString());
    }

    final escapedInstance = instance
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"');

    final cpuFuture = queryScalar(
      '100 - (avg by(instance)(rate(node_cpu_seconds_total{mode="idle",instance="$escapedInstance"}[5m])) * 100)',
    );
    final memFuture = queryScalar(
      '(1 - node_memory_MemAvailable_bytes{instance="$escapedInstance"} / node_memory_MemTotal_bytes{instance="$escapedInstance"}) * 100',
    );
    final diskFuture = queryScalar(
      '(1 - node_filesystem_avail_bytes{instance="$escapedInstance",mountpoint="/"} / node_filesystem_size_bytes{instance="$escapedInstance",mountpoint="/"}) * 100',
    );
    final uptimeFuture = queryScalar(
      'node_time_seconds{instance="$escapedInstance"} - node_boot_time_seconds{instance="$escapedInstance"}',
    );

    final ramTotalFuture = queryScalar(
      'node_memory_MemTotal_bytes{instance="$escapedInstance"}',
    );
    final ramUsedFuture = queryScalar(
      'node_memory_MemTotal_bytes{instance="$escapedInstance"} - node_memory_MemAvailable_bytes{instance="$escapedInstance"}',
    );

    final results =
        await Future.wait([cpuFuture, memFuture, diskFuture, uptimeFuture, ramTotalFuture, ramUsedFuture]);

    final uptimeSeconds = results[3];
    String? uptimeStr;
    if (uptimeSeconds != null) {
      final dur = Duration(seconds: uptimeSeconds.round());
      final days = dur.inDays;
      final hours = dur.inHours % 24;
      final minutes = dur.inMinutes % 60;
      if (days > 0) {
        uptimeStr = '$days days, $hours:${minutes.toString().padLeft(2, '0')}';
      } else {
        uptimeStr = '$hours:${minutes.toString().padLeft(2, '0')}';
      }
    }

    return ServerStats(
      cpuPercent: results[0],
      ramUsedMB: results[5] != null ? (results[5]! / (1024 * 1024)).round() : null,
      ramTotalMB: results[4] != null ? (results[4]! / (1024 * 1024)).round() : null,
      diskPercent: results[2],
      uptime: uptimeStr,
      collectedAt: DateTime.now(),
    );
  }
}
