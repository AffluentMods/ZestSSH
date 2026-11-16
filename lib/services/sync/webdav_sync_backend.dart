import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:zestssh/services/own_network_http.dart';
import 'package:zestssh/services/sync/dumb_store_sync_backend.dart';
import 'package:zestssh/services/sync/http_cap.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync_service.dart' show SyncException, SyncConflictException, SyncService;
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/services/sync/sync_failure.dart';
import 'package:zestssh/l10n/l10n_global.dart';

/// Cloud-sync backend that stores the manifest on any WebDAV server -
/// Nextcloud, ownCloud, Synology, mailbox.org, Koofr, a NAS, etc.
///
/// Uses HTTP Basic Auth (no OAuth) and only the WebDAV verbs needed for a
/// single object: GET, PUT (with `If-Match` / `If-None-Match` for CAS),
/// DELETE, and MKCOL to create the folder. TLS is validated by the system
/// CA store - use a real certificate (self-signed certs are rejected).
class WebDavSyncBackend extends DumbStoreSyncBackend {
  final String serverUrl;
  final String username;
  final String password;

  /// Remote folder for sync data, normalized to start and end with `/`.
  final String remotePath;

  final String label;

  WebDavSyncBackend({
    required this.serverUrl,
    required this.username,
    required this.password,
    String? remotePath,
    String? label,
  })  : remotePath = _normalizePath(remotePath ?? '/ZestSSH/sync/'),
        label = (label == null || label.isEmpty) ? 'WebDAV' : label;

  static String _normalizePath(String path) {
    var p = path.trim();
    if (p.isEmpty) p = '/ZestSSH/sync/';
    if (!p.startsWith('/')) p = '/$p';
    if (!p.endsWith('/')) p = '$p/';
    return p;
  }

  @override
  SyncBackendKind get kind => SyncBackendKind.webdav;

  @override
  String get displayName => label;

  String get _authHeader =>
      'Basic ${base64Encode(utf8.encode('$username:$password'))}';

  Map<String, String> get _headers => {'Authorization': _authHeader};

  String get _cleanBase {
    final b = serverUrl.trim();
    final withScheme = b.startsWith('http') ? b : 'https://$b';
    return withScheme.endsWith('/')
        ? withScheme.substring(0, withScheme.length - 1)
        : withScheme;
  }

  Uri get _collectionUri => Uri.parse('$_cleanBase$remotePath');
  Uri get _fileUri =>
      Uri.parse('$_cleanBase$remotePath${DumbStoreSyncBackend.manifestObjectName}');

  // One reused client per backend instance instead of a fresh (never-closed)
  // client on every request - the old getter leaked a socket pool per call.
  //
  // Every request carries the Basic-auth password, so plain http is only for
  // an address on the person's own network: the client refuses anything else
  // before it is sent, and for a request it lets through it lifts the phone's
  // blanket refusal of http (which is why http to a NAS worked on Windows and
  // not on Android).
  late final http.Client _client = OwnNetworkHttpClient();

  @override
  void dispose() => _client.close();

  // ── checkConnection ───────────────────────────────────────────────

  @override
  Future<void> checkConnection() async {
    try {
      final request = http.Request('PROPFIND', _collectionUri);
      request.headers.addAll(_headers);
      request.headers['Depth'] = '0';
      request.headers['Content-Type'] = 'application/xml; charset=utf-8';
      request.body = '<?xml version="1.0" encoding="utf-8"?>'
          '<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop>'
          '</d:propfind>';
      // Thirty seconds for Check connection: a server that takes the request
      // and never answers held the button for good (found in a code audit).
      final streamed = await _client.send(request).timeout(const Duration(seconds: 30));
      await streamed.stream.drain<void>().timeout(const Duration(seconds: 30));
      final s = streamed.statusCode;
      if (s == 401 || s == 403) {
        throw SyncException(gl10n.syncWebDavRefused, detail: 'WebDAV rejected the username or password');
      }
      // 207 = folder exists; 404 = folder not created yet (we'll MKCOL on
      // first push) - both mean the server is reachable and creds are good.
      if (s == 207 || s == 200 || s == 404 || s == 405) return;
      throw SyncFailure.storeAnswered(s, 'WebDAV server returned HTTP $s');
    } on SyncException {
      rethrow;
    } on PlainHttpRefused catch (e) {
      throw SyncException(e.message, detail: e.toString());
    } catch (e) {
      throw SyncFailure.ofStore(e, hosted: false);
    }
  }

  // ── Store primitives ──────────────────────────────────────────────

  @override
  Future<RawObject?> readObject() async {
    final request = http.Request('GET', _fileUri);
    request.headers.addAll(_headers);
    // Stream with a hard cap so a hostile/misconfigured server can't OOM us.
    final response =
        await sendCapped(_client, request, SyncService.maxBlobBytes * 2);
    if (response.statusCode == 404) return null;
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw SyncException(gl10n.syncWebDavRefused, detail: 'WebDAV rejected the username or password');
    }
    if (response.statusCode != 200) {
      throw SyncFailure.storeAnswered(response.statusCode, 'WebDAV GET failed: HTTP ${response.statusCode}');
    }
    // Deliberately do NOT surface an ETag for compare-and-swap. Real WebDAV
    // servers, Nextcloud above all, return a STRONG ETag on GET that their own
    // If-Match check then rejects with 412 on the very next PUT - not a real
    // conflict, just an ETag that does not round-trip - which made every push
    // after the first fail with a bogus "Version conflict ... expected v-1"
    // (the placeholder this class throws on a 412). Weak validators (gzip
    // proxies) never worked either. With no ETag the base falls back to its
    // version-compare optimistic lock (the same best-effort path Google Drive
    // uses), which is reliable here; concurrency is still guarded by that
    // version check plus the If-None-Match on the first-ever create.
    return RawObject(response.bodyBytes, null);
  }

  @override
  Future<String?> writeObject(
    Uint8List bytes, {
    String? ifMatchEtag,
    bool ifAbsent = false,
  }) async {
    await _ensureRemoteDirectory();

    final headers = <String, String>{
      ..._headers,
      'Content-Type': 'application/json',
    };
    if (ifAbsent) headers['If-None-Match'] = '*';
    if (ifMatchEtag != null) headers['If-Match'] = ifMatchEtag;

    // Route the write through sendCapped too: a hostile server can return a
    // huge body to ANY verb, not just GET. A PUT/DELETE ack is tiny, so cap
    // hard (256 KB) to bound memory.
    final request = http.Request('PUT', _fileUri)
      ..headers.addAll(headers)
      ..bodyBytes = bytes;
    final response = await sendCapped(_client, request, _ackCap);
    final s = response.statusCode;

    // 412 Precondition Failed = our If-Match/If-None-Match lost the race.
    if (s == 412 || s == 409) {
      throw SyncConflictException.storeRefused('WebDAV PUT: HTTP $s', storeStatus: s);
    }
    if (s == 401 || s == 403) {
      throw SyncException(gl10n.syncWebDavRefused, detail: 'WebDAV rejected the username or password');
    }
    if (s != 201 && s != 204 && s != 200) {
      throw SyncFailure.storeAnswered(s, 'WebDAV PUT failed: HTTP $s');
    }
    return response.headers['etag'];
  }

  /// Hard cap for a small write/delete acknowledgement body.
  static const _ackCap = 256 * 1024;

  @override
  Future<void> deleteObject() async {
    final request = http.Request('DELETE', _fileUri)..headers.addAll(_headers);
    final response = await sendCapped(_client, request, _ackCap);
    final s = response.statusCode;
    if (s == 404 || s == 204 || s == 200) return;
    if (s == 401 || s == 403) {
      throw SyncException(gl10n.syncWebDavRefused, detail: 'WebDAV rejected the username or password');
    }
    throw SyncFailure.storeAnswered(s, 'WebDAV DELETE failed: HTTP $s');
  }

  // ── Helpers ───────────────────────────────────────────────────────

  Future<void> _ensureRemoteDirectory() async {
    final parts = remotePath.split('/').where((s) => s.isNotEmpty).toList();
    var current = '';
    for (final part in parts) {
      current = '$current/$part';
      final uri = Uri.parse('$_cleanBase$current/');
      try {
        final request = http.Request('MKCOL', uri);
        request.headers.addAll(_headers);
        final streamed = await _client.send(request);
        await streamed.stream.drain<void>();
        // 201 created, 405 already exists, 301 redirect (exists) - all fine.
      } catch (e) {
        AppLogger.debug('WebDAV MKCOL $current failed (continuing): $e');
      }
    }
  }
}
