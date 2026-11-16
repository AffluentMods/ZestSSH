import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/cloud_import/cloud_http.dart';
import 'package:zestssh/features/cloud_import/cloud_tls.dart';

/// Cloud import (3.0): a self-signed Proxmox certificate is shown by its
/// fingerprint and trusted only once confirmed, and then only that one, only
/// at that address. A real TLS server on this machine stands in for Proxmox.

// A throwaway certificate made for this test (openssl, P-256, CN=pve.test).
const _cert = '''-----BEGIN CERTIFICATE-----
MIIBfjCCASOgAwIBAgIUfNjO+yx8vRoOHGC9+ex41JBJuzUwCgYIKoZIzj0EAwIw
EzERMA8GA1UEAwwIcHZlLnRlc3QwIBcNMjYwOTI2MDI0NzI5WhgPMjEyNjA5MDIw
MjQ3MjlaMBMxETAPBgNVBAMMCHB2ZS50ZXN0MFkwEwYHKoZIzj0CAQYIKoZIzj0D
AQcDQgAEVtUpZwmgCnGN47b+rFczMqspUuXKpwd1ESY1M922mZbROLOgHOn3VLlg
km+GiWNIg9x/eXHZhdpJTMwvOh1+MKNTMFEwHQYDVR0OBBYEFPKm71+ebyA6xPbd
LmZxKjFttj7MMB8GA1UdIwQYMBaAFPKm71+ebyA6xPbdLmZxKjFttj7MMA8GA1Ud
EwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSQAwRgIhANqxuNB4yAAug7Q/Q3Fxv/7B
tNzQ0/MYPNjtxRP7v8RZAiEAxF+WQhsXqEFSSTCOAFpZ3hQ68DDgpnwuAP1jlpOk
CNE=
-----END CERTIFICATE-----
''';
const _key = '''-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgg1e5GTSz/Rgp/nfy
KKGqKmLvS07iZThC4XZlHlv0iryhRANCAARW1SlnCaAKcY3jtv6sVzMyqylS5cqn
B3URJjUz3baZltE4s6Ac6fdUuWCSb4aJY0iD3H95cdmF2klMzC86HX4w
-----END PRIVATE KEY-----
''';
// `openssl x509 -noout -fingerprint -sha256` of the certificate above, and of
// another one made alongside it.
const _fingerprint = 'D2:93:C9:44:ED:19:1C:66:05:72:E1:C4:F2:0C:B6:33:88:71:60:CD:18:CD:D5:1A:C6:CA:63:85:FF:6C:F0:70';
const _other = '24:E8:BD:E5:AB:3F:B2:0D:82:B6:6C:9E:08:CC:01:18:66:D5:22:C1:F4:88:7C:3F:9E:2F:FE:13:BB:BB:26:E1';

void main() {
  late HttpServer server;
  late Uri base;

  setUp(() async {
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(_cert))
      ..usePrivateKeyBytes(utf8.encode(_key));
    server = await HttpServer.bindSecure('127.0.0.1', 0, context);
    server.listen((req) {
      req.response
        ..headers.contentType = ContentType.json
        ..write('{"data":[]}')
        ..close();
    });
    base = Uri(scheme: 'https', host: '127.0.0.1', port: server.port);
  });

  tearDown(() => server.close(force: true));

  test('fingerprints as Proxmox shows them; typed ones in any form', () {
    expect(normalizeFingerprint(_fingerprint.toLowerCase().replaceAll(':', ' ')), _fingerprint);
    expect(normalizeFingerprint(_fingerprint.replaceAll(':', '')), _fingerprint);
    expect(normalizeFingerprint('AB:CD'), isNull);
    expect(normalizeFingerprint('zz' * 32), isNull);
  });

  test('the probe shows the untrusted certificate: its fingerprint, subject and end date', () async {
    final cert = await probeCertificate(base);
    expect(cert, isNotNull);
    expect(cert!.sha256, _fingerprint);
    expect(cert.subject, contains('pve.test'));
    expect(cert.validUntil!.year, greaterThan(2100));
  });

  test('confirmed: exactly that certificate is trusted, at that address only', () async {
    final pinned = CloudHttp(pinnedCloudClient(base, pinned: _fingerprint));
    expect(await pinned.json('GET', base.replace(path: '/api2/json/cluster/resources')), {'data': []});

    final wrongPin = CloudHttp(pinnedCloudClient(base, pinned: _other));
    await expectLater(wrongPin.send('GET', base.replace(path: '/x')),
        throwsA(isA<CloudError>().having((e) => e.kind, 'kind', CloudErrorKind.certificate)));

    final noPin = CloudHttp(pinnedCloudClient(base));
    await expectLater(noPin.send('GET', base.replace(path: '/x')),
        throwsA(isA<CloudError>().having((e) => e.kind, 'kind', CloudErrorKind.certificate)));

    // The same certificate pinned for another port is not trusted here.
    final elsewhere = CloudHttp(pinnedCloudClient(base.replace(port: server.port == 1 ? 2 : 1), pinned: _fingerprint));
    await expectLater(elsewhere.send('GET', base.replace(path: '/x')),
        throwsA(isA<CloudError>().having((e) => e.kind, 'kind', CloudErrorKind.certificate)));
  });

  test('nothing listening: offline, not a certificate question', () async {
    final port = server.port;
    await server.close(force: true);
    await expectLater(probeCertificate(Uri(scheme: 'https', host: '127.0.0.1', port: port)),
        throwsA(isA<CloudError>().having((e) => e.kind, 'kind', CloudErrorKind.offline)));
  });
}
