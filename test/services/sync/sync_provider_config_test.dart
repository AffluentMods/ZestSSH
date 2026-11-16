import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync/sync_provider_config.dart';

void main() {
  group('isComplete', () {
    test('hosted + drive need no fields', () {
      expect(const SyncProviderConfig.zestServer().isComplete, isTrue);
      expect(
        const SyncProviderConfig(kind: SyncBackendKind.googleDrive).isComplete,
        isTrue,
      );
    });

    test('webdav requires url + user + password', () {
      expect(
        const SyncProviderConfig(kind: SyncBackendKind.webdav).isComplete,
        isFalse,
      );
      expect(
        const SyncProviderConfig(
          kind: SyncBackendKind.webdav,
          webdavUrl: 'https://x/dav',
          webdavUsername: 'u',
          webdavPassword: 'p',
        ).isComplete,
        isTrue,
      );
    });

    test('s3 requires endpoint + region + bucket + keys', () {
      expect(
        const SyncProviderConfig(
          kind: SyncBackendKind.s3,
          s3Endpoint: 'https://x',
          s3Region: 'auto',
          s3Bucket: 'b',
          s3AccessKeyId: 'k',
          // secret missing
        ).isComplete,
        isFalse,
      );
    });

    test('custom requires an http(s) URL', () {
      expect(
        const SyncProviderConfig(
          kind: SyncBackendKind.custom,
          serverUrl: 'ftp://nope',
        ).isComplete,
        isFalse,
      );
      expect(
        const SyncProviderConfig(
          kind: SyncBackendKind.custom,
          serverUrl: 'https://sync.example.com/v1',
          // A custom server must bring its own static token - the account
          // bearer token is never sent off the hosted API host.
          serverToken: 'store-scoped-token',
        ).isComplete,
        isTrue,
      );
    });
  });

  group('insecureTransportError (plaintext-credential guard)', () {
    SyncProviderConfig webdav(String url) => SyncProviderConfig(
          kind: SyncBackendKind.webdav,
          webdavUrl: url,
          webdavUsername: 'u',
          webdavPassword: 'p',
        );

    test('blocks plain http:// to a public host', () {
      expect(webdav('http://cloud.example.com/dav').insecureTransportError,
          isNotNull);
    });

    test('allows https://', () {
      expect(webdav('https://cloud.example.com/dav').insecureTransportError,
          isNull);
    });

    test('allows plain http:// to LAN / loopback hosts', () {
      expect(webdav('http://192.168.1.10/dav').insecureTransportError, isNull);
      expect(webdav('http://10.0.0.5/dav').insecureTransportError, isNull);
      expect(webdav('http://127.0.0.1:8080/dav').insecureTransportError, isNull);
      expect(webdav('http://nas.local/dav').insecureTransportError, isNull);
    });

    test('custom server with http:// public host is blocked', () {
      expect(
        const SyncProviderConfig(
          kind: SyncBackendKind.custom,
          serverUrl: 'http://sync.example.com/v1',
        ).insecureTransportError,
        isNotNull,
      );
    });

    test('S3 is not blocked (SigV4 keeps the secret off the wire)', () {
      expect(
        const SyncProviderConfig(
          kind: SyncBackendKind.s3,
          s3Endpoint: 'http://192.168.1.9:9000',
          s3Region: 'us-east-1',
          s3Bucket: 'b',
          s3AccessKeyId: 'k',
          s3SecretAccessKey: 's',
        ).insecureTransportError,
        isNull,
      );
    });
  });

  group('storeIdentity (drives safe provider switching)', () {
    test('changes when the WebDAV URL or path changes', () {
      const a = SyncProviderConfig(
        kind: SyncBackendKind.webdav,
        webdavUrl: 'https://a/dav',
        webdavUsername: 'u',
        webdavPassword: 'p',
      );
      final b = a.copyWith(webdavUrl: 'https://b/dav');
      expect(a.storeIdentity, isNot(b.storeIdentity));
    });

    test('does NOT change when only the password changes', () {
      const a = SyncProviderConfig(
        kind: SyncBackendKind.webdav,
        webdavUrl: 'https://a/dav',
        webdavUsername: 'u',
        webdavPassword: 'p1',
      );
      final b = a.copyWith(webdavPassword: 'p2');
      expect(a.storeIdentity, b.storeIdentity);
    });

    test('changes when the S3 bucket or prefix changes', () {
      const a = SyncProviderConfig(
        kind: SyncBackendKind.s3,
        s3Endpoint: 'https://x',
        s3Region: 'auto',
        s3Bucket: 'b1',
        s3AccessKeyId: 'k',
        s3SecretAccessKey: 's',
      );
      expect(a.storeIdentity, isNot(a.copyWith(s3Bucket: 'b2').storeIdentity));
      expect(
          a.storeIdentity, isNot(a.copyWith(s3Prefix: 'p/').storeIdentity));
    });
  });

  group('JSON round-trip', () {
    test('preserves all fields including secrets', () {
      const c = SyncProviderConfig(
        kind: SyncBackendKind.s3,
        label: 'Backblaze',
        s3Endpoint: 'https://s3.us-west-004.backblazeb2.com',
        s3Region: 'us-west-004',
        s3Bucket: 'zestssh-sync',
        s3AccessKeyId: 'keyid',
        s3SecretAccessKey: 'supersecret',
        s3Prefix: 'zestssh/',
        s3UsePathStyle: true,
      );
      final round = SyncProviderConfig.fromJson(c.toJson());
      expect(round.kind, SyncBackendKind.s3);
      expect(round.s3Endpoint, c.s3Endpoint);
      expect(round.s3SecretAccessKey, 'supersecret');
      expect(round.s3Prefix, 'zestssh/');
      expect(round.s3UsePathStyle, isTrue);
      expect(round.label, 'Backblaze');
    });

    test('unknown kind falls back to hosted', () {
      final round = SyncProviderConfig.fromJson({'kind': 'martian-cloud'});
      expect(round.kind, SyncBackendKind.zestServer);
    });
  });
}
