import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/services/own_network_http.dart';
import 'package:zestssh/services/prometheus_service.dart';
import 'package:zestssh/services/sync/s3_sync_backend.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync/sync_provider_config.dart';
import 'package:zestssh/services/sync/webdav_sync_backend.dart';
import 'package:zestssh/services/sync_service.dart' show SyncException;
import 'package:zestssh/utils/error_translator.dart';

/// Plain http, one rule on every platform. A bug in 2.2.1: WebDAV
/// sync over `http://` to a NAS worked on Windows and was refused on Android.
/// The app's rule was the same; the phone refused because Flutter rejects
/// every http request when the manifest forbids cleartext. These pin the rule
/// itself, that a request it allows is sent with that refusal lifted (and
/// only such a request), and that the manifest stays as strict as it was.

/// What a phone whose manifest forbids cleartext does to plain http: Flutter
/// reads this same zone value, and `false` is "refuse unless loopback".
Future<T> _onAPhoneThatForbidsHttp<T>(Future<T> Function() body) =>
    runZoned(body, zoneValues: {#flutter.io.allow_http: false});

/// An inner client that records, per request, whether plain http was allowed
/// in the zone the request was started in.
class _Recorder {
  final seen = <(Uri, Object?)>[];
  var closed = false;

  late final http.Client client = _ClosingClient(
    MockClient((request) async {
      seen.add((request.url, Zone.current[#flutter.io.allow_http]));
      return http.Response('ok', 200);
    }),
    () => closed = true,
  );
}

class _ClosingClient extends http.BaseClient {
  _ClosingClient(this._inner, this._onClose);
  final http.Client _inner;
  final void Function() _onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() => _onClose();
}

void main() {
  group('which addresses are on your own network', () {
    const own = [
      'localhost', 'LOCALHOST', '127.0.0.1', '127.9.9.9', '::1', '[::1]',
      '10.0.0.5', '10.255.255.255', '172.16.0.1', '172.31.255.254',
      '192.168.1.10', '169.254.10.10',
      // Overlay networks (Tailscale and the like) hand these out.
      '100.64.0.1', '100.100.100.100', '100.127.255.255',
      // IPv6 unique-local and link-local, with or without a zone.
      'fd12:3456:789a::1', 'fc00::1', 'fe80::1', 'fe80::1%eth0', '[fd00::1]',
      // An IPv4 address written as IPv6.
      '::ffff:192.168.1.5',
      // Names only a private network can resolve.
      'nas', 'NAS', 'truenas-01', 'nas.local', 'nas.lan', 'pve.home.arpa',
      'box.internal', 'files.corp', 'media.home', 'a.b.intranet', 'x.private',
      'app.localhost', 'nas.', 'nas.lan.',
    ];
    const notOwn = [
      '', ' ', 'example.com', 'cloud.example.com', 'nas.example.com',
      '8.8.8.8', '1.1.1.1', '11.0.0.1', '172.15.255.255', '172.32.0.1',
      '192.169.0.1', '169.253.0.1', '100.63.255.255', '100.128.0.1',
      '2001:db8::1', '2606:4700::1111', '::ffff:8.8.8.8', 'fec0::1',
      // Ways of writing an address that a resolver may read as any address.
      '2130706433', '0x7f000001', '0x7f.1', '127.1', '10.1', '010.0.0.1',
      '192.168.1.5.', '192.168.001.005', '0300.0250.0.1',
      // A private-looking name under a public one, and the other way round.
      'localhost.example.com', 'nas.lan.example.com', '192.168.1.5.example.com',
      'local.example.org',
      // Not a host name at all.
      'nas_box', 'nas box', 'a..b', '.lan', '-', 'nas/..', 'nas?x',
    ];

    for (final host in own) {
      test('"$host" is', () => expect(isOwnNetworkHost(host), isTrue));
    }
    for (final host in notOwn) {
      test('"$host" is not', () => expect(isOwnNetworkHost(host), isFalse));
    }
  });

  group('what a typed address means', () {
    test('https and no scheme are not plain http', () {
      expect(plainHttpUseOf('https://cloud.example.com/dav'), PlainHttpUse.none);
      expect(plainHttpUseOf('cloud.example.com/dav'), PlainHttpUse.none);
      expect(plainHttpUseOf(''), PlainHttpUse.none);
      expect(plainHttpUseOf(null), PlainHttpUse.none);
    });

    test('http to your own network is allowed', () {
      expect(plainHttpUseOf('http://192.168.1.10:5005/dav'),
          PlainHttpUse.ownNetwork);
      expect(plainHttpUseOf('  HTTP://nas.local/remote.php/dav  '),
          PlainHttpUse.ownNetwork);
      expect(plainHttpUseOf('http://[fd00::10]:8080/'), PlainHttpUse.ownNetwork);
      expect(plainHttpUseOf('http://100.101.102.103/'), PlainHttpUse.ownNetwork);
    });

    test('http to anything else is refused', () {
      expect(plainHttpUseOf('http://cloud.example.com/dav'),
          PlainHttpUse.refused);
      expect(plainHttpUseOf('http://203.0.113.10/'), PlainHttpUse.refused);
      expect(plainHttpUseOf('http://'), PlainHttpUse.refused);
    });

    test('the host is what the request goes to, not what the address shows',
        () {
      // Everything before @ is a user name; the host is what follows.
      expect(plainHttpUseOf('http://192.168.1.5@evil.example.com/'),
          PlainHttpUse.refused);
      expect(plainHttpUseOf('http://192.168.1.5:80@evil.example.com/'),
          PlainHttpUse.refused);
      expect(plainHttpUseOf('http://evil.example.com#@192.168.1.5/'),
          PlainHttpUse.refused);
      expect(plainHttpUseOf('http://evil.example.com/?x=http://10.0.0.1'),
          PlainHttpUse.refused);
      expect(plainHttpUseOf('http://user:pw@nas.lan/'), PlainHttpUse.ownNetwork);
    });
  });

  group('the saved sync storage', () {
    SyncProviderConfig webdav(String url) => SyncProviderConfig(
          kind: SyncBackendKind.webdav,
          webdavUrl: url,
          webdavUsername: 'alex',
          webdavPassword: 'p',
        );

    test('WebDAV on a NAS by http is allowed, by name or by address', () {
      for (final url in [
        'http://192.168.10.31:5005/dav',
        'http://nas/dav',
        'http://nas.lan/dav',
        'http://100.90.80.70/dav',
      ]) {
        expect(webdav(url).insecureTransportError, isNull, reason: url);
        expect(webdav(url).plainHttpUse, PlainHttpUse.ownNetwork, reason: url);
      }
    });

    test('WebDAV on the internet by http is refused, in words', () {
      final error = webdav('http://cloud.example.com/dav').insecureTransportError;
      expect(error, contains('https://'));
      expect(error, contains('your own network'));
    });

    test('a custom server follows the same rule; so does S3, which was held to none',
        () {
      expect(
        const SyncProviderConfig(
                kind: SyncBackendKind.custom,
                serverUrl: 'http://192.168.10.50:3090/v1',
                serverToken: 't')
            .insecureTransportError,
        isNull,
      );
      expect(
        const SyncProviderConfig(
                kind: SyncBackendKind.custom,
                serverUrl: 'http://sync.example.com/v1',
                serverToken: 't')
            .insecureTransportError,
        isNotNull,
      );
      SyncProviderConfig s3(String endpoint) => SyncProviderConfig(
            kind: SyncBackendKind.s3,
            s3Endpoint: endpoint,
            s3Region: 'us-east-1',
            s3Bucket: 'b',
            s3AccessKeyId: 'k',
            s3SecretAccessKey: 's',
          );
      expect(s3('http://minio.example.com:9000').insecureTransportError, isNotNull);
      expect(s3('http://minio.example.com:9000').plainHttpUse, PlainHttpUse.refused);
      expect(s3('http://192.168.10.20:9000').insecureTransportError, isNull);
      expect(s3('http://192.168.10.20:9000').plainHttpUse, PlainHttpUse.ownNetwork);
      expect(s3('https://acct.r2.cloudflarestorage.com').plainHttpUse, PlainHttpUse.none);
    });

    test("S3's own requests by plain http to an address off your network are refused before anything is sent",
        () async {
      final store = S3SyncBackend(
        endpoint: 'http://minio.example.com:9000',
        region: 'us-east-1',
        bucket: 'zest-demo',
        accessKeyId: 'demo-key',
        secretAccessKey: 'demo-secret',
      );
      addTearDown(store.dispose);
      await expectLater(store.checkConnection(), throwsA(isA<PlainHttpRefused>()));
    });
  });

  group('the client', () {
    test('https goes straight through, with nothing lifted', () async {
      final r = _Recorder();
      final client = OwnNetworkHttpClient(inner: r.client);
      await client.get(Uri.parse('https://cloud.example.com/dav'));
      expect(r.seen.single.$2, isNull);
    });

    test('http to your own network is sent with the refusal lifted', () async {
      final r = _Recorder();
      final client = OwnNetworkHttpClient(inner: r.client);
      await _onAPhoneThatForbidsHttp(
          () => client.get(Uri.parse('http://192.168.10.31:5005/dav')));
      expect(r.seen.single.$1.host, '192.168.10.31');
      expect(r.seen.single.$2, isTrue);
    });

    test('http to anything else is refused before anything is sent', () async {
      final r = _Recorder();
      final client = OwnNetworkHttpClient(inner: r.client);
      await expectLater(
        client.get(Uri.parse('http://cloud.example.com/dav'),
            headers: {'Authorization': 'Basic c2VjcmV0'}),
        throwsA(isA<PlainHttpRefused>()
            .having((e) => e.url.host, 'host', 'cloud.example.com')
            .having((e) => e.message, 'message', contains('https://'))),
      );
      expect(r.seen, isEmpty, reason: 'the password never left the device');
    });

    group('a name is judged by where it leads too', () {
      HostLookup leadsTo(List<String> addresses, [List<String>? asked]) => (host) async {
            asked?.add(host);
            return [for (final a in addresses) InternetAddress(a)];
          };

      test('a private name that resolves out on the internet is refused before anything is sent', () async {
        for (final name in ['nas', 'nas.lan', 'metrics.internal']) {
          final r = _Recorder();
          final client = OwnNetworkHttpClient(inner: r.client, lookup: leadsTo(['203.0.113.9']));
          await expectLater(
            client.get(Uri.parse('http://$name/dav'), headers: {'Authorization': 'Basic c2VjcmV0'}),
            throwsA(isA<PlainHttpRefused>().having((e) => e.url.host, 'host', name)),
            reason: name,
          );
          expect(r.seen, isEmpty, reason: 'the password never left the device');
        }
      });

      test('one address of several that is outside is enough to refuse it', () async {
        final r = _Recorder();
        final client = OwnNetworkHttpClient(inner: r.client, lookup: leadsTo(['192.168.10.31', '2001:db8::9']));
        await expectLater(client.get(Uri.parse('http://nas.lan/dav')), throwsA(isA<PlainHttpRefused>()));
        expect(r.seen, isEmpty);
      });

      test('a private name that resolves on the own network is sent, with the refusal lifted', () async {
        for (final addresses in [
          ['192.168.10.31'],
          ['10.0.0.5', 'fd12:3456::5'],
          ['100.101.102.103'],
          ['fe80::1'],
          ['127.0.0.1', '::1'],
        ]) {
          final r = _Recorder();
          final asked = <String>[];
          final client = OwnNetworkHttpClient(inner: r.client, lookup: leadsTo(addresses, asked));
          await _onAPhoneThatForbidsHttp(() => client.get(Uri.parse('http://NAS.lan:5005/dav')));
          expect(r.seen.single.$1.host, 'nas.lan', reason: 'sent by its name, as typed');
          expect(r.seen.single.$2, isTrue);
          expect(asked, ['nas.lan']);
        }
      });

      test('a name that resolves to nothing passes: nothing can be sent to it', () async {
        final r = _Recorder();
        final client = OwnNetworkHttpClient(inner: r.client, lookup: leadsTo(const []));
        await client.get(Uri.parse('http://nas.lan/dav'));
        expect(r.seen, hasLength(1));
      });

      test('an address is not looked up, and neither is https or a client that may send anywhere', () async {
        final asked = <String>[];
        final r = _Recorder();
        final lookup = leadsTo(['203.0.113.9'], asked);
        await OwnNetworkHttpClient(inner: r.client, lookup: lookup).get(Uri.parse('http://192.168.10.31/dav'));
        await OwnNetworkHttpClient(inner: r.client, lookup: lookup).get(Uri.parse('http://[fd00::5]/dav'));
        await OwnNetworkHttpClient(inner: r.client, lookup: lookup).get(Uri.parse('https://nas.lan/dav'));
        await OwnNetworkHttpClient(inner: r.client, lookup: lookup, plainHttp: PlainHttp.anywhere)
            .get(Uri.parse('http://minio.example.com:9000/bucket'));
        expect(asked, isEmpty);
        expect(r.seen, hasLength(4));
      });

      test('a public name is refused by how it is written, and never looked up', () async {
        final asked = <String>[];
        expect(await leadsToOwnNetwork('cloud.example.com', lookup: leadsTo(['192.168.1.5'], asked)), isFalse);
        expect(asked, isEmpty);
      });
    });

    test('where no secret is on the wire, http may go anywhere', () async {
      final r = _Recorder();
      final client =
          OwnNetworkHttpClient(inner: r.client, plainHttp: PlainHttp.anywhere);
      await client.get(Uri.parse('http://minio.example.com:9000/bucket'));
      expect(r.seen.single.$2, isTrue);
    });

    test('closing it closes what it owns, and nothing it was lent', () {
      final owned = _Recorder();
      OwnNetworkHttpClient(inner: owned.client).close();
      expect(owned.closed, isTrue);
      final lent = _Recorder();
      OwnNetworkHttpClient(inner: lent.client, closeInner: false).close();
      expect(lent.closed, isFalse);
    });
  });

  group('against Flutter\'s own gate (no mock)', () {
    // An address of this machine that is not loopback, and a port nothing
    // listens on: a connection there is refused at once, so the test sends
    // nothing anywhere and still exercises the real check Flutter makes
    // before it opens a connection.
    Future<Uri?> closedPortOnThisMachine() async {
      String? address;
      for (final nic in await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false)) {
        for (final a in nic.addresses) {
          if (isOwnNetworkHost(a.address) && !a.isLoopback) {
            address = a.address;
            break;
          }
        }
        if (address != null) break;
      }
      if (address == null) return null;
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      return Uri.parse('http://$address:$port/dav');
    }

    test('a plain client is refused by the platform; the rule\'s client gets '
        'through to the network', () async {
      final url = await closedPortOnThisMachine();
      if (url == null) {
        markTestSkipped('this machine has no private network address');
        return;
      }
      await _onAPhoneThatForbidsHttp(() async {
        // What 2.2.1 did on Android.
        final plain = http.Client();
        addTearDown(plain.close);
        await expectLater(
          plain.get(url).timeout(const Duration(seconds: 20)),
          throwsA(isA<UnsupportedError>().having(
              (e) => e.message, 'message', contains('Non-https connection'))),
        );

        // The same request through the rule: past the gate, and then only
        // the closed port stops it.
        final client = OwnNetworkHttpClient();
        addTearDown(client.close);
        Object? error;
        try {
          await client.get(url).timeout(const Duration(seconds: 20));
        } catch (e) {
          error = e;
        }
        expect(error, isNotNull, reason: 'nothing listens on that port');
        expect(error, isNot(isA<UnsupportedError>()));
        expect('$error', isNot(contains('Non-https connection')));
      });
    });

    test('the WebDAV backend refuses a public http address without sending',
        () async {
      final backend = WebDavSyncBackend(
        serverUrl: 'http://cloud.example.com/remote.php/dav',
        username: 'alex',
        password: 'secret',
      );
      addTearDown(backend.dispose);
      await expectLater(
        backend.checkConnection(),
        throwsA(isA<SyncException>()
            .having((e) => e.message, 'message', contains('your own network'))
            .having((e) => e.message, 'message',
                isNot(contains('Could not reach')))),
      );
      // And the same refusal out of a read, said the same way.
      Object? readError;
      try {
        await backend.readObject();
      } catch (e) {
        readError = e;
      }
      expect(readError, isA<PlainHttpRefused>());
      expect(describeNetworkError(readError!).message,
          contains('your own network'));
    });

    test('an http S3 endpoint and a Prometheus with a login follow the rule',
        () async {
      // S3 signs: any http endpoint is let through to the network.
      final s3 = S3SyncBackend(
        endpoint: 'http://127.0.0.1:1',
        region: 'us-east-1',
        bucket: 'b',
        accessKeyId: 'k',
        secretAccessKey: 's',
      );
      addTearDown(s3.dispose);
      Object? s3Error;
      try {
        await s3.checkConnection();
      } catch (e) {
        s3Error = e;
      }
      expect('$s3Error', isNot(contains('own network')));

      // Prometheus with a password, on the internet, by http: refused.
      final withLogin = PrometheusService(
        baseUrl: 'http://prometheus.example.com:9090',
        authType: PrometheusAuthType.basicAuth,
        basicAuthUser: 'alex',
        basicAuthPassword: 'secret',
      );
      final (result, message) = await withLogin.testConnection();
      expect(result, PrometheusTestResult.unknownError);
      expect(message, contains('your own network'));
      await expectLater(withLogin.discoverTargets(),
          throwsA(isA<PlainHttpRefused>()));
    });
  });

  group('the platform stays strict', () {
    test('Android still forbids cleartext for everything the rule does not '
        'lift', () {
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(manifest, contains('android:usesCleartextTraffic="false"'));
      final policy = File(
              'android/app/src/main/res/xml/network_security_config.xml')
          .readAsStringSync();
      expect(policy, contains('<base-config cleartextTrafficPermitted="false">'));
      expect(policy, isNot(contains('cleartextTrafficPermitted="true"')));
    });

    test('plain http is lifted in one place only', () {
      // The zone value that lifts Flutter's refusal appears in the helper and
      // nowhere else in the app: every http request has to go through the
      // rule to get it.
      final users = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.readAsStringSync().contains('flutter.io.allow_http')) {
          users.add(entity.path.replaceAll('\\', '/'));
        }
      }
      expect(users, ['lib/services/own_network_http.dart']);
    });
  });
}
