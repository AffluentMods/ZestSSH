import 'dart:io' show InternetAddress;
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:zestssh/services/own_network_http.dart';
import 'package:zestssh/services/sync/dumb_store_sync_backend.dart';
import 'package:zestssh/services/sync/http_cap.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync_service.dart'
    show SyncException, SyncConflictException, SyncService;
import 'package:zestssh/services/sync/sync_failure.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/utils/host_address.dart';

/// Cloud-sync backend for any S3-compatible object store: Cloudflare R2,
/// Backblaze B2 (S3 API), Wasabi, MinIO (self-hosted), or AWS S3 itself.
///
/// Requests are authenticated with AWS Signature V4 (implemented inline -
/// there is no S3 SDK dependency). Uses path-style addressing by default
/// (`https://endpoint/bucket/key`), which every S3-compatible endpoint
/// supports; virtual-host style is available for stores that require it.
///
/// Optimistic locking uses conditional writes (`If-Match` / `If-None-Match`)
/// where the store supports them (R2, MinIO), backed by the version-compare
/// CAS in [DumbStoreSyncBackend] for stores that ignore them, or refuse
/// them where they held.
class S3SyncBackend extends DumbStoreSyncBackend {
  /// Endpoint origin, e.g. `https://<acct>.r2.cloudflarestorage.com` or
  /// `http://192.168.1.10:9000` (MinIO). Scheme optional (defaults https).
  final String endpoint;
  final String region;
  final String bucket;
  final String accessKeyId;
  final String secretAccessKey;

  /// Optional key prefix within the bucket (a "folder"), e.g. `zestssh/`.
  final String prefix;

  /// Path-style (`/bucket/key`) vs virtual-host style (`bucket.host/key`).
  final bool usePathStyle;

  final String label;

  static const _service = 's3';
  static const _emptyBodySha256 =
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

  S3SyncBackend({
    required this.endpoint,
    required this.region,
    required this.bucket,
    required this.accessKeyId,
    required this.secretAccessKey,
    String? prefix,
    this.usePathStyle = true,
    String? label,
  })  : prefix = _normalizePrefix(prefix),
        label = (label == null || label.isEmpty) ? 'S3' : label;

  static String _normalizePrefix(String? p) {
    var s = (p ?? '').trim();
    while (s.startsWith('/')) {
      s = s.substring(1);
    }
    // Drop path-traversal / ambiguous segments so the wire key can never escape
    // the configured folder or diverge from the signed canonical path. A `.`/
    // `..` segment, a backslash, a `?`/`#`, or a control char makes the prefix
    // unsafe - fall back to the bucket root rather than signing an escaped key.
    final segments = s.split('/');
    final bad = segments.any((seg) =>
        seg == '.' ||
        seg == '..' ||
        seg.contains('\\') ||
        seg.contains('?') ||
        seg.contains('#') ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(seg));
    if (bad) return '';
    if (s.isNotEmpty && !s.endsWith('/')) s = '$s/';
    return s;
  }

  @override
  SyncBackendKind get kind => SyncBackendKind.s3;

  @override
  String get displayName => label;

  String get _objectKey => '$prefix${DumbStoreSyncBackend.manifestObjectName}';

  Uri _endpointUri() {
    final e = endpoint.trim();
    return Uri.parse(e.startsWith('http') ? e : 'https://$e');
  }

  /// Build the request URI, the `host` header value, and the RFC3986-encoded
  /// canonical path for the object. [canonicalPath] is used verbatim in the
  /// SigV4 canonical request AND to build the request URI, so the signed path
  /// and the wire path are byte-identical (avoids the Uri.parse re-decode
  /// pitfall that silently breaks SigV4).
  /// [_objectTarget], for the tests of how an endpoint is written.
  @visibleForTesting
  ({Uri uri, String host, String canonicalPath}) get objectTargetForTest => _objectTarget();

  ({Uri uri, String host, String canonicalPath}) _objectTarget() {
    final base = _endpointUri();
    final port = base.hasPort ? ':${base.port}' : '';
    // An IPv6 endpoint between brackets, as the URL and the Host header the
    // client sends write it (Uri.host gives it without them, so the URL
    // did not parse, or the signed Host was not the one sent); and an
    // address, under which no bucket can be a name, always by its path.
    final endpointHost = bracketIpv6(base.host);
    final byPath = usePathStyle || InternetAddress.tryParse(base.host) != null;
    final String host;
    final String canonicalPath;
    if (byPath) {
      host = '$endpointHost$port';
      canonicalPath = '/${_uriEncode(bucket, encodeSlash: true)}'
          '/${_uriEncode(_objectKey, encodeSlash: false)}';
    } else {
      host = '$bucket.$endpointHost$port';
      canonicalPath = '/${_uriEncode(_objectKey, encodeSlash: false)}';
    }
    return (
      uri: Uri.parse('${base.scheme}://$host$canonicalPath'),
      host: host,
      canonicalPath: canonicalPath,
    );
  }

  // Reused per-instance client (was a fresh, never-closed client per request).
  //
  // Plain http only to an endpoint on the person's own network (a MinIO on
  // the LAN is the usual case), as for WebDAV and a server of one's own:
  // requests are signed and the data is encrypted before it leaves the
  // device, but over plain http elsewhere anyone on the way had the
  // encrypted vault and what a guess at its password needs, and could hand
  // back an older vault. The wrapper is what makes an http endpoint work on a
  // phone at all, where http is refused wholesale.
  late final http.Client _client =
      OwnNetworkHttpClient(plainHttp: PlainHttp.ownNetworkOnly);

  @override
  void dispose() => _client.close();

  // ── checkConnection ───────────────────────────────────────────────

  @override
  Future<void> checkConnection() async {
    // A signed GET on the (possibly absent) object proves the endpoint,
    // bucket, region, and credentials all line up. 200 or 404 are both OK;
    // 403 means bad creds / clock skew / wrong region.
    final response = await _signedSend('GET', body: null);
    final s = response.statusCode;
    if (s == 200 || s == 404) return;
    if (s == 403) {
      throw SyncException(gl10n.syncS3Refused, detail: 'S3 denied access (403) to the connection test');
    }
    throw SyncFailure.storeAnswered(s, 'S3 endpoint returned HTTP $s');
  }

  // ── Store primitives ──────────────────────────────────────────────

  @override
  Future<RawObject?> readObject() async {
    final response = await _signedSend('GET', body: null);
    final s = response.statusCode;
    if (s == 404) return null;
    if (s == 403) {
      throw SyncException(gl10n.syncS3Refused, detail: 'S3 denied access (403) reading sync data');
    }
    if (s != 200) {
      throw SyncFailure.storeAnswered(s, 'S3 GET failed: HTTP $s');
    }
    // Body size is already bounded by sendCapped.
    return RawObject(response.bodyBytes, response.headers['etag']);
  }

  @override
  Future<String?> writeObject(
    Uint8List bytes, {
    String? ifMatchEtag,
    bool ifAbsent = false,
  }) async {
    final extra = <String, String>{'content-type': 'application/json'};
    if (ifAbsent) extra['if-none-match'] = '*';
    if (ifMatchEtag != null) extra['if-match'] = strongEtag(ifMatchEtag);

    final response = await _signedSend('PUT', body: bytes, extraHeaders: extra);
    final s = response.statusCode;
    if (s == 412 || s == 409) {
      throw SyncConflictException.storeRefused(storeAnswerOf('S3 PUT', s, response.bodyBytes), storeStatus: s);
    }
    if (s == 403) {
      throw SyncException(gl10n.syncS3Refused, detail: 'S3 denied access (403) writing sync data');
    }
    if (s != 200 && s != 201) {
      throw SyncFailure.storeAnswered(s, 'S3 PUT failed: HTTP $s');
    }
    return response.headers['etag'];
  }

  @override
  Future<void> deleteObject() async {
    final response = await _signedSend('DELETE', body: null);
    final s = response.statusCode;
    if (s == 200 || s == 204 || s == 404) return;
    if (s == 403) {
      throw SyncException(gl10n.syncS3Refused, detail: 'S3 denied access (403) deleting sync data');
    }
    throw SyncFailure.storeAnswered(s, 'S3 DELETE failed: HTTP $s');
  }

  /// [etag] as If-Match is to carry it. A weak ETag (`W/"..."`) never
  /// satisfies If-Match, which compares strongly, and a store, or a proxy in
  /// front of one, makes its strong ETag a weak one when it compresses a
  /// response; what is inside is the object's own tag.
  @visibleForTesting
  static String strongEtag(String etag) {
    final t = etag.trim();
    return t.startsWith('W/') ? t.substring(2) : t;
  }

  /// What an S3 store answered to [what] ("S3 PUT"): its status and the
  /// error code its XML body names ("S3 PUT: HTTP 412 PreconditionFailed"),
  /// for Copy details. Only a code that looks like one is kept.
  @visibleForTesting
  static String storeAnswerOf(String what, int status, List<int> body) {
    final text = utf8.decode(body.take(4096).toList(), allowMalformed: true);
    final code = RegExp(r'<Code>\s*([A-Za-z0-9_.\-]{1,64})\s*</Code>').firstMatch(text)?.group(1);
    return code == null ? '$what: HTTP $status' : '$what: HTTP $status $code';
  }

  // ── AWS Signature V4 ──────────────────────────────────────────────

  Future<CappedResponse> _signedSend(
    String method, {
    required Uint8List? body,
    Map<String, String> extraHeaders = const {},
  }) async {
    final target = _objectTarget();
    final now = DateTime.now().toUtc();
    final amzDate = _amzDate(now); // 20260804T120000Z

    final payload = body ?? Uint8List(0);
    final payloadHash =
        body == null ? _emptyBodySha256 : _sha256Hex(payload);

    final authorization = signV4(
      method: method,
      canonicalPath: target.canonicalPath,
      host: target.host,
      payloadHash: payloadHash,
      amzDate: amzDate,
      accessKeyId: accessKeyId,
      secretAccessKey: secretAccessKey,
      region: region,
      service: _service,
    );

    final headers = <String, String>{
      'Authorization': authorization,
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': amzDate,
      // Nothing compressed. The client asks for gzip by default; Cloudflare
      // compresses a JSON object it is asked that way for, and the ETag of a
      // compressed response is a weak one, which no If-Match matches: R2
      // refused every update after the first (3.3).
      'accept-encoding': 'identity',
      ...extraHeaders, // unsigned (content-type, if-match, if-none-match)
    };

    final request = http.Request(method, target.uri);
    request.headers.addAll(headers);
    if (method == 'PUT') request.bodyBytes = payload;
    // Cap the response so a hostile endpoint can't OOM us (GET especially).
    return sendCapped(_client, request, SyncService.maxBlobBytes * 2);
  }

  /// Pure AWS SigV4 signer for a no-query request whose signed headers are
  /// exactly host + x-amz-content-sha256 + x-amz-date (the set S3 requires).
  /// Extracted and [visibleForTesting] so the signature math is unit-testable
  /// deterministically; the authoritative check is a live request to a real
  /// S3-compatible endpoint (MinIO/R2).
  @visibleForTesting
  static String signV4({
    required String method,
    required String canonicalPath,
    required String host,
    required String payloadHash,
    required String amzDate,
    required String accessKeyId,
    required String secretAccessKey,
    required String region,
    required String service,
  }) {
    final dateStamp = amzDate.substring(0, 8);
    final signed = <String, String>{
      'host': host,
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': amzDate,
    };
    final sortedKeys = signed.keys.toList()..sort();
    final canonicalHeaders =
        sortedKeys.map((k) => '$k:${signed[k]!.trim()}\n').join();
    final signedHeaders = sortedKeys.join(';');

    final canonicalRequest = [
      method,
      canonicalPath,
      '', // no query string
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].join('\n');

    final scope = '$dateStamp/$region/$service/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      scope,
      _sha256Hex(Uint8List.fromList(utf8.encode(canonicalRequest))),
    ].join('\n');

    final kDate =
        _hmac(utf8.encode('AWS4$secretAccessKey'), utf8.encode(dateStamp));
    final kRegion = _hmac(kDate, utf8.encode(region));
    final kService = _hmac(kRegion, utf8.encode(service));
    final kSigning = _hmac(kService, utf8.encode('aws4_request'));
    final signature = _hmacHex(kSigning, utf8.encode(stringToSign));

    return 'AWS4-HMAC-SHA256 '
        'Credential=$accessKeyId/$scope, '
        'SignedHeaders=$signedHeaders, '
        'Signature=$signature';
  }

  /// Test hooks for the SigV4 primitives.
  @visibleForTesting
  static String uriEncode(String input, {required bool encodeSlash}) =>
      _uriEncode(input, encodeSlash: encodeSlash);

  @visibleForTesting
  static String get emptyBodySha256 => _emptyBodySha256;

  static String _amzDate(DateTime utc) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${utc.year.toString().padLeft(4, '0')}${two(utc.month)}'
        '${two(utc.day)}T${two(utc.hour)}${two(utc.minute)}'
        '${two(utc.second)}Z';
  }

  static List<int> _hmac(List<int> key, List<int> data) =>
      c.Hmac(c.sha256, key).convert(data).bytes;

  static String _hmacHex(List<int> key, List<int> data) =>
      c.Hmac(c.sha256, key).convert(data).toString();

  static String _sha256Hex(Uint8List data) => c.sha256.convert(data).toString();

  /// RFC 3986 percent-encoding as required by SigV4 canonicalisation.
  /// Only A-Z a-z 0-9 - _ . ~ are unreserved; everything else is %XX over
  /// the UTF-8 bytes. `/` is preserved in paths unless [encodeSlash].
  static String _uriEncode(String input, {required bool encodeSlash}) {
    const unreserved =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~';
    final out = StringBuffer();
    for (final byte in utf8.encode(input)) {
      final ch = String.fromCharCode(byte);
      if (unreserved.contains(ch)) {
        out.write(ch);
      } else if (ch == '/' && !encodeSlash) {
        out.write('/');
      } else {
        out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }
}
