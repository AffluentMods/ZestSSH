import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/services/own_network_http.dart';
import 'package:zestssh/services/prometheus_service.dart';

/// A Prometheus server's TLS settings (found in a check: its own
/// CA, its client certificate and Verify SSL were saved and never used). A
/// real TLS server on this machine stands in for Prometheus, with throwaway
/// certificates made for this test (openssl, P-256): a CA, the server's for
/// 127.0.0.1 signed by it, and a client's signed by it, in a PKCS#12 file.
const _ca = '''-----BEGIN CERTIFICATE-----
MIIBmzCCAUGgAwIBAgIUCfiE77OX6UZ07VD/Rtbgy/saN98wCgYIKoZIzj0EAwIw
GjEYMBYGA1UEAwwPWmVzdFNTSCBUZXN0IENBMCAXDTI2MTAyMDEyNDgyOFoYDzIx
MjYwOTI2MTI0ODI4WjAaMRgwFgYDVQQDDA9aZXN0U1NIIFRlc3QgQ0EwWTATBgcq
hkjOPQIBBggqhkjOPQMBBwNCAAQDTeThUfC3U8Q7M5Gio9L6aixe6yWaOdqyruVG
h0suIkqAykFhXzfhmxGcaHPOu4NYEw5l6VktivDOLRe4s5c/o2MwYTAdBgNVHQ4E
FgQUFdcznWvPIE7feS8bjgjxMWzzotMwHwYDVR0jBBgwFoAUFdcznWvPIE7feS8b
jgjxMWzzotMwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAQYwCgYIKoZI
zj0EAwIDSAAwRQIhAI5qyWQS7AtvHyQsjU9y+mXyC1DT224Sgtv1706Gv2pKAiBr
/uunAldNrCkhVp5FzXR5P6ebWhBAZd7pStG+C1496g==
-----END CERTIFICATE-----
''';
const _serverCert = '''-----BEGIN CERTIFICATE-----
MIIBtjCCAVygAwIBAgIUKLSz8fdkMqi0V/L8iHt64CE/RMQwCgYIKoZIzj0EAwIw
GjEYMBYGA1UEAwwPWmVzdFNTSCBUZXN0IENBMCAXDTI2MTAyMDEyNDgzN1oYDzIx
MjYwOTI2MTI0ODM3WjAaMRgwFgYDVQQDDA9wcm9tZXRoZXVzLnRlc3QwWTATBgcq
hkjOPQIBBggqhkjOPQMBBwNCAATtAt277qEq6hp2aseYcnn5MajS8emGnn92/NhL
02iv0Ifq6f05tp8CHlE7TPmw0yCMe56xcZJKIti5fk2X/7vwo34wfDAaBgNVHREE
EzARhwR/AAABgglsb2NhbGhvc3QwCQYDVR0TBAIwADATBgNVHSUEDDAKBggrBgEF
BQcDATAdBgNVHQ4EFgQUd35SJs+Z2vQb39ep20UF6Ph8CG4wHwYDVR0jBBgwFoAU
FdcznWvPIE7feS8bjgjxMWzzotMwCgYIKoZIzj0EAwIDSAAwRQIgQGNPk14im+KJ
YOP7u2k/Y1AdqkbGiZd1g8XB1EW8N90CIQDcOKkXciGDbAGnsCxekpBYAuwkB/gX
dGJqpwORidELkg==
-----END CERTIFICATE-----
''';
const _serverKey = '''-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgwancrDbxLiQpe4l1
puypILxtl1ewEv62MkxF2ym53X6hRANCAATtAt277qEq6hp2aseYcnn5MajS8emG
nn92/NhL02iv0Ifq6f05tp8CHlE7TPmw0yCMe56xcZJKIti5fk2X/7vw
-----END PRIVATE KEY-----
''';
final _clientP12 = base64Decode(
    'MIIDmgIBAzCCA2AGCSqGSIb3DQEHAaCCA1EEggNNMIIDSTCCAj8GCSqGSIb3DQEHBqCCAjAwggIsAgEAMIICJQYJKoZIhvcNAQcB'
    'MBwGCiqGSIb3DQEMAQMwDgQIcVub6A2DPgUCAggAgIIB+D4lrhLReJfD5GqspSwXx6e9lT5FljQmwqVgoGKhDWF47YLzbFsvGSa8'
    'Y0QoKshCwhcyVAElvNwV6skgY0E8tB5ULnvPJ5YBndTm5UYUThEsmembaPsX1qqDU7Tv/mmyVkZrPVrujI1aW1TpHgT1EOZ1l3lj'
    '9nbUJjjI9jmEUVI75KXZrkUcct/HqNfU7xfYah96ss9IHDW/1uyvlv4iD5Qo2xTJ3/05UcqIqgW11j05sik3hdbECYY7/OWqGS6A'
    'MGhf20EvQwB1j67qZWPJjeRgqJFtxk6UIVC1ZSLQB16w3YiqLF2BJBmOOLk7OiHD4epnFaHRYUB5EOobbjTA3fzhErfYy9dtxgGD'
    'Lq521nA5x5HkU9m1OgSqvSaq1omboLDDxEBAiDHpyS/8gTGLkjrqBgkUmBZO8hz3wr2mWiTRR6ckJKY1o98LvBJVje10zrK92tnI'
    'XSnB57eBpOGEJvpeGgmH1jq8BHjLIv9XsIqJijCLPhOHeVrYl2L3tQlsZ48RCs0gGcZPW7AROh3oHzJciaaKtY2XcIIi5brjeOtV'
    '2M2kKsHSoKhnlnby+RPADO1kzeMyYWnFnLWMxWreoHRtOd0+ibXghaxSnxuLOuLOpNNJ/yz4eEs4gKrR8wCPRGevKasH2lGzERHb'
    'yhcuxBE370LDiymk0jCCAQIGCSqGSIb3DQEHAaCB9ASB8TCB7jCB6wYLKoZIhvcNAQwKAQKggbQwgbEwHAYKKoZIhvcNAQwBAzAO'
    'BAjE2aAo8Lfp2wICCAAEgZDH2QZELDg/qCWz6FnhFYNhRHO2VTwigYcD+1nCiBIHHfiieWHeK2B0Nzp0bRCWEKOAkEWNN7mFwh8j'
    '9mbZcSeTFA2MrgUljaDpulwSWM2xQKObiuZOffSknCbSACbHoXqg++OX4jxvN9pKJxKt/iy7P+B1KK+lI00erflCtjyao2RBeKeu'
    'jVSByeyRhVSsTeoxJTAjBgkqhkiG9w0BCRUxFgQU+YtNit4jyP4NIn4kPsI/ZNFuWxAwMTAhMAkGBSsOAwIaBQAEFD4VKYV/M5tk'
    '/TRZqPegDeoKB0M4BAiMsz6lboa8YwICCAA=');
const _p12Password = 'demo-p12-pass';

void main() {
  late HttpServer server;
  late String base;

  /// The server; with [askClient], one that asks for a client certificate
  /// and answers 403 to a request without one.
  ///
  /// With [trustOnly], it trusts that certificate alone for its clients, so
  /// the client certificate (signed by the CA) is refused in the handshake.
  Future<void> start({bool askClient = false, String? trustOnly}) async {
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(_serverCert))
      ..usePrivateKeyBytes(utf8.encode(_serverKey));
    if (askClient) context.setTrustedCertificatesBytes(utf8.encode(trustOnly ?? _ca));
    server = await HttpServer.bindSecure('127.0.0.1', 0, context, requestClientCertificate: askClient);
    server.listen((request) {
      final ok = !askClient || request.certificate != null;
      request.response
        ..statusCode = ok ? 200 : 403
        ..headers.contentType = ContentType.json
        ..write('{"status":"success","data":{}}')
        ..close();
    });
    base = 'https://127.0.0.1:${server.port}';
  }

  tearDown(() => server.close(force: true));

  PrometheusService prometheus({
    String? ca,
    Uint8List? p12,
    bool verify = true,
    PrometheusAuthType auth = PrometheusAuthType.none,
  }) =>
      PrometheusService(
        baseUrl: base,
        authType: auth,
        bearerToken: auth == PrometheusAuthType.bearerToken ? 'demo-token' : null,
        caPem: ca,
        clientCertP12Bytes: p12,
        clientCertPassword: p12 == null ? null : _p12Password,
        verifySsl: verify,
      );

  test('a server behind a private CA: not trusted without its CA, trusted with it', () async {
    await start();
    expect((await prometheus().testConnection()).$1, PrometheusTestResult.caNotTrusted);
    expect((await prometheus(ca: _ca).testConnection()).$1, PrometheusTestResult.success);
  });

  test('Verify SSL off: the certificate goes unchecked where no login is sent, or on your own network', () async {
    await start();
    expect((await prometheus(verify: false).testConnection()).$1, PrometheusTestResult.success);
    expect((await prometheus(verify: false, auth: PrometheusAuthType.bearerToken).testConnection()).$1,
        PrometheusTestResult.success, reason: 'this device is its own network');
    expect(prometheusMaySkipVerify(auth: PrometheusAuthType.none, host: '203.0.113.10'), isTrue);
    expect(prometheusMaySkipVerify(auth: PrometheusAuthType.bearerToken, host: '192.168.10.30'), isTrue);
    expect(prometheusMaySkipVerify(auth: PrometheusAuthType.bearerToken, host: '203.0.113.10'), isFalse,
        reason: 'a token to an address out on the internet: the certificate is checked');
    expect(prometheusMaySkipVerify(auth: PrometheusAuthType.basicAuth, host: 'metrics.example.com'), isFalse);
  });

  test('Verify SSL off with a login: a name that leads out of your own network has its certificate checked '
      '(found in a security review)', () async {
    await start();
    base = 'https://localhost:${server.port}';
    final before = ownNetworkLookup;
    addTearDown(() => ownNetworkLookup = before);

    ownNetworkLookup = (host) async => [InternetAddress('127.0.0.1')];
    expect((await prometheus(verify: false, auth: PrometheusAuthType.bearerToken).testConnection()).$1,
        PrometheusTestResult.success, reason: 'the name leads to this device');

    ownNetworkLookup = (host) async => [InternetAddress('203.0.113.9')];
    expect((await prometheus(verify: false, auth: PrometheusAuthType.bearerToken).testConnection()).$1,
        isNot(PrometheusTestResult.success), reason: 'a token to wherever the name leads: the certificate is checked');
    expect((await prometheus(verify: false).testConnection()).$1, PrometheusTestResult.success,
        reason: 'no login is sent: unchecked as before');
  });

  test('its client certificate (mutual TLS) is presented where one is set', () async {
    await start(askClient: true);
    expect((await prometheus(ca: _ca).testConnection()).$1, PrometheusTestResult.authFailed,
        reason: 'none presented: refused');
    expect((await prometheus(ca: _ca, p12: _clientP12).testConnection()).$1, PrometheusTestResult.success);
  });

  // Before, every TLS failure of a test said "CA not trusted", so a
  // client certificate the server refused was never said.
  test('a client certificate the server refuses is said as that, not as the CA', () async {
    await start(askClient: true, trustOnly: _serverCert);
    final (result, detail) = await prometheus(ca: _ca, p12: _clientP12).testConnection();
    expect(result, PrometheusTestResult.clientCertRejected, reason: '$detail');
  });

  test('a .p12 that does not open (a wrong password) is said as that', () async {
    await start(askClient: true);
    final wrong = PrometheusService(
      baseUrl: base,
      authType: PrometheusAuthType.none,
      caPem: _ca,
      clientCertP12Bytes: _clientP12,
      clientCertPassword: 'not-the-password',
    );
    expect((await wrong.testConnection()).$1, PrometheusTestResult.clientCertUnreadable);
  });

  test("the server's own certificate that does not check is still the CA", () {
    expect(
        PrometheusService.tlsFailureKind(
            const HandshakeException('Handshake error', OSError('CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate')),
            clientCertSet: true),
        PrometheusTestResult.caNotTrusted);
    expect(
        PrometheusService.tlsFailureKind(const HandshakeException('TLSV1_ALERT_CERTIFICATE_REQUIRED'), clientCertSet: false),
        PrometheusTestResult.clientCertRejected);
  });
}
