import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/sync/s3_sync_backend.dart';

void main() {
  group('S3 RFC3986 uriEncode (SigV4 canonicalisation)', () {
    test('unreserved chars and preserved slashes pass through', () {
      expect(
        S3SyncBackend.uriEncode('zestssh/zestssh-sync.json', encodeSlash: false),
        'zestssh/zestssh-sync.json',
      );
      expect(S3SyncBackend.uriEncode('~-._AZ09', encodeSlash: true), '~-._AZ09');
    });

    test('spaces and reserved chars are percent-encoded', () {
      expect(S3SyncBackend.uriEncode('my bucket', encodeSlash: true),
          'my%20bucket');
      expect(S3SyncBackend.uriEncode('a=1&b', encodeSlash: true), 'a%3D1%26b');
      expect(S3SyncBackend.uriEncode('+/:', encodeSlash: true), '%2B%2F%3A');
    });

    test('slash encoding depends on encodeSlash', () {
      expect(S3SyncBackend.uriEncode('a/b', encodeSlash: false), 'a/b');
      expect(S3SyncBackend.uriEncode('a/b', encodeSlash: true), 'a%2Fb');
    });

    test('multibyte UTF-8 is encoded per-byte, uppercase hex', () {
      expect(S3SyncBackend.uriEncode('é', encodeSlash: true), '%C3%A9');
    });
  });

  test('empty-body SHA-256 constant matches sha256 of empty', () {
    expect(
      S3SyncBackend.emptyBodySha256,
      c.sha256.convert(<int>[]).toString(),
    );
  });

  group('SigV4 signature (structure, determinism, input sensitivity)', () {
    // Empty-body SHA-256 (verified against S3SyncBackend.emptyBodySha256 in a
    // separate test); used as a const default here.
    const emptyHash =
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
    String sign({
      String method = 'GET',
      String canonicalPath = '/zestssh-sync/zestssh-sync.json',
      String host = 'acct.r2.cloudflarestorage.com',
      String payloadHash = emptyHash,
      String amzDate = '20260804T120000Z',
      String accessKeyId = 'AKIDEXAMPLE',
      String secretAccessKey = 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
      String region = 'auto',
      String service = 's3',
    }) =>
        S3SyncBackend.signV4(
          method: method,
          canonicalPath: canonicalPath,
          host: host,
          payloadHash: payloadHash,
          amzDate: amzDate,
          accessKeyId: accessKeyId,
          secretAccessKey: secretAccessKey,
          region: region,
          service: service,
        );

    test('has the correct authorization structure', () {
      final auth = sign();
      expect(
        auth,
        matches(RegExp(
          r'^AWS4-HMAC-SHA256 '
          r'Credential=AKIDEXAMPLE/20260804/auto/s3/aws4_request, '
          r'SignedHeaders=host;x-amz-content-sha256;x-amz-date, '
          r'Signature=[0-9a-f]{64}$',
        )),
      );
    });

    test('is deterministic for identical inputs', () {
      expect(sign(), sign());
    });

    test('every signed input changes the signature', () {
      final base = sign();
      // If any of these produced the same signature, that input is NOT being
      // fed into the canonical request / string-to-sign correctly.
      expect(sign(method: 'PUT'), isNot(base));
      expect(sign(canonicalPath: '/other/key.json'), isNot(base));
      expect(sign(host: 'other.example.com'), isNot(base));
      expect(sign(payloadHash: c.sha256.convert([1, 2, 3]).toString()),
          isNot(base));
      expect(sign(amzDate: '20260805T120000Z'), isNot(base));
      expect(sign(secretAccessKey: 'different-secret-key'), isNot(base));
      expect(sign(region: 'us-east-1'), isNot(base));
      expect(sign(accessKeyId: 'AKIDOTHER'), isNot(base));
    });

    test('a PUT body hash flows into the signature', () {
      final body = Uint8List.fromList(List.generate(64, (i) => i));
      final withBody =
          sign(method: 'PUT', payloadHash: c.sha256.convert(body).toString());
      final withEmpty = sign(method: 'PUT');
      expect(withBody, isNot(withEmpty));
    });
  });
}
