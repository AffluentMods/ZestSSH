import 'package:flutter/foundation.dart' show visibleForTesting;
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/backup/backup_destination.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/type_name.dart';

/// Backup destination that stores `.zest` files on a WebDAV server.
///
/// Compatible with Nextcloud, ownCloud, Synology WebDAV, and any
/// standards-compliant WebDAV endpoint. Uses HTTP Basic Auth -
/// no OAuth needed.
///
/// Implements the subset of WebDAV required for backup management:
/// - PUT for upload
/// - PROPFIND for directory listing
/// - GET for download
/// - DELETE for deletion
class WebDavBackupDestination extends BackupDestination {
  final String serverUrl;
  final String username;
  final String password;

  /// Remote path where backups are stored (e.g. `/ZestSSH/backups/`).
  /// Must start and end with `/`.
  final String remotePath;

  /// Optional user-assigned label (e.g. "Home Nextcloud").
  final String label;

  /// Where the requests go (a stand-in server in tests), as given.
  final http.Client _inner;

  /// [_inner], refusing every request that is not https ([WebDavHttpsRequired]).
  final http.Client _client;

  /// The folder backups go to when none is given.
  static const defaultRemotePath = '/ZestSSH/backups/';

  WebDavBackupDestination({
    required this.serverUrl,
    required this.username,
    required this.password,
    String? remotePath,
    String? label,
    http.Client? client,
  })  : remotePath = _normalizePath(remotePath),
        label = label ?? 'WebDAV',
        _inner = client ?? http.Client(),
        _client = _HttpsOnlyClient(client ?? http.Client());

  /// [path] as a folder: starting and ending with `/`. An empty one (the
  /// form's Remote path left empty, or only spaces) is the default folder,
  /// never the server's root (22 October 2026: it saved "/", so backups went
  /// to the top of the person's WebDAV storage). A "/" typed is the root, as
  /// asked.
  static String _normalizePath(String? path) {
    var p = path?.trim() ?? '';
    if (p.isEmpty) return defaultRemotePath;
    if (!p.startsWith('/')) p = '/$p';
    if (!p.endsWith('/')) p = '$p/';
    return p;
  }

  @override
  String get id => 'webdav_${serverUrl.hashCode.toRadixString(16)}';

  @override
  String get name => 'webdav';

  @override
  String get displayName => label;

  @override
  bool get survivesUninstall => true;

  /// Base64-encoded Basic Auth header value.
  String get _authHeader =>
      'Basic ${base64Encode(utf8.encode('$username:$password'))}';

  Map<String, String> get _headers => {
        'Authorization': _authHeader,
      };

  /// Build the full URL for a file on the WebDAV server.
  Uri _fileUri(String filename) {
    final base = serverUrl.endsWith('/') ? serverUrl : '$serverUrl/';
    // remotePath starts with '/' so trim the trailing slash from base
    final cleanBase = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return Uri.parse('$cleanBase$remotePath$filename');
  }

  /// Build the collection (directory) URL.
  Uri get _collectionUri {
    final base = serverUrl.endsWith('/') ? serverUrl : '$serverUrl/';
    final cleanBase = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return Uri.parse('$cleanBase$remotePath');
  }

  /// PROPFIND with Depth: 0 on the folder: the lightest round trip that
  /// checks the sign-in and that the folder is there. Its status.
  Future<int> _probeFolder() async {
    final request = http.Request('PROPFIND', _collectionUri);
    request.headers.addAll(_headers);
    request.headers['Depth'] = '0';
    request.headers['Content-Type'] = 'application/xml; charset=utf-8';
    request.body = '<?xml version="1.0" encoding="utf-8"?>'
        '<d:propfind xmlns:d="DAV:">'
        '<d:prop><d:resourcetype/></d:prop>'
        '</d:propfind>';
    final streamed = await _client.send(request);
    await streamed.stream.drain<void>();
    return streamed.statusCode;
  }

  /// Whether the sign-in works and the folder is there. A folder that is not
  /// there yet is made, each missing level, before this answers (22 October
  /// 2026: a 404 answered "not signed in", so the copy was never made and
  /// the folder never created, though the upload would have created it). A
  /// wrong user name or password (401, 403) answers false; a folder that
  /// could not be made throws, saying what the server answered.
  @override
  Future<bool> isAuthenticated() async {
    final int status;
    try {
      status = await _probeFolder();
    } on WebDavHttpsRequired {
      rethrow;
    } catch (e) {
      AppLogger.debug('WebDAV auth check failed: $e');
      return false;
    }
    // 207 Multi-Status is the expected WebDAV success response.
    if (status == 207 || status == 200) return true;
    // 404 (some servers 409): signed in, the folder is not there yet.
    if (status != 404 && status != 409) return false;
    await _ensureRemoteDirectory();
    final again = await _probeFolder();
    if (again == 207 || again == 200) return true;
    if (again == 401 || again == 403) return false;
    throw HttpException('WebDAV folder $remotePath could not be made (PROPFIND $again)', uri: _collectionUri);
  }

  @override
  Future<void> authenticate() async {
    // WebDAV uses Basic Auth - credentials are stored in the instance.
    // Ensure the remote directory exists by issuing MKCOL.
    await _ensureRemoteDirectory();
  }

  /// MKCOL on [uri]: its status.
  Future<int> _mkcol(Uri uri) async {
    final request = http.Request('MKCOL', uri);
    request.headers.addAll(_headers);
    final streamed = await _client.send(request);
    await streamed.stream.drain<void>();
    return streamed.statusCode;
  }

  /// 201 = created, 405 = already exists (Method Not Allowed on an existing
  /// collection), 301 = redirect (already exists on some servers).
  static bool _made(int status) => status == 201 || status == 405 || status == 301;

  /// Create the remote backup directory if it does not exist.
  Future<void> _ensureRemoteDirectory() async {
    try {
      // A missing level above answers 409 Conflict: made one level at a time.
      if (!_made(await _mkcol(_collectionUri))) await _mkcolRecursive();
    } catch (e) {
      AppLogger.warning('WebDAV MKCOL failed: $e');
    }
  }

  /// Recursively create remote directories (e.g. /ZestSSH/backups/).
  Future<void> _mkcolRecursive() async {
    final parts = remotePath
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    var current = '';
    final base = serverUrl.endsWith('/')
        ? serverUrl.substring(0, serverUrl.length - 1)
        : serverUrl;

    for (final part in parts) {
      current = '$current/$part';
      final status = await _mkcol(Uri.parse('$base$current/'));
      if (!_made(status)) AppLogger.debug('MKCOL $current: $status');
    }
  }

  @override
  Future<void> uploadBackup(File file, String filename) async {
    await _ensureRemoteDirectory();

    final uri = _fileUri(filename);
    final bytes = await file.readAsBytes();

    final response = await _client.put(
      uri,
      headers: {
        ..._headers,
        'Content-Type': 'application/octet-stream',
      },
      body: bytes,
    );

    if (response.statusCode != 201 && response.statusCode != 204) {
      throw HttpException(
        'WebDAV PUT failed: ${response.statusCode} ${response.reasonPhrase}',
        uri: uri,
      );
    }
    AppLogger.info('WebDAV backup uploaded: $filename → $uri');
  }

  @override
  Future<List<BackupFileInfo>> listBackups() async {
    final request = http.Request('PROPFIND', _collectionUri);
    request.headers.addAll(_headers);
    request.headers['Depth'] = '1';
    request.headers['Content-Type'] = 'application/xml; charset=utf-8';
    request.body = '<?xml version="1.0" encoding="utf-8"?>'
        '<d:propfind xmlns:d="DAV:">'
        '<d:prop>'
        '<d:displayname/>'
        '<d:getcontentlength/>'
        '<d:getlastmodified/>'
        '</d:prop>'
        '</d:propfind>';

    final streamed = await _client.send(request);
    if (streamed.statusCode != 207) {
      throw HttpException(
        'WebDAV PROPFIND failed: ${streamed.statusCode}',
        uri: _collectionUri,
      );
    }

    final body = await streamed.stream.bytesToString();
    return _parsePropfindResponse(body);
  }

  /// Parse a WebDAV PROPFIND (Depth: 1) multistatus XML response.
  ///
  /// Extracts `.zest` files with their size and last-modified date.
  /// Uses simple string parsing instead of an XML dependency.
  List<BackupFileInfo> _parsePropfindResponse(String xml) {
    final results = <BackupFileInfo>[];

    // Split on <d:response> or <D:response> (case varies by server).
    final responsePattern = RegExp(
      r'<(?:d|D):response>(.*?)</(?:d|D):response>',
      dotAll: true,
    );

    for (final match in responsePattern.allMatches(xml)) {
      final block = match.group(1) ?? '';

      // Extract href.
      final hrefMatch = RegExp(
        r'<(?:d|D):href>(.*?)</(?:d|D):href>',
      ).firstMatch(block);
      final href = hrefMatch?.group(1) ?? '';

      // Skip the collection itself and non-.zest files.
      final decodedHref = Uri.decodeFull(href);
      if (!decodedHref.endsWith('.zest')) continue;

      // Extract filename from href.
      final filename = Uri.parse(decodedHref).pathSegments.last;

      // Extract content length.
      final lengthMatch = RegExp(
        r'<(?:d|D):getcontentlength>(.*?)</(?:d|D):getcontentlength>',
      ).firstMatch(block);
      final sizeBytes =
          int.tryParse(lengthMatch?.group(1) ?? '0') ?? 0;

      // Extract last modified (RFC 2822 format from WebDAV).
      final modifiedMatch = RegExp(
        r'<(?:d|D):getlastmodified>(.*?)</(?:d|D):getlastmodified>',
      ).firstMatch(block);
      final modifiedStr = modifiedMatch?.group(1) ?? '';
      final createdAt =
          HttpDate.parse(modifiedStr);

      results.add(BackupFileInfo(
        filename: filename,
        createdAt: createdAt,
        sizeBytes: sizeBytes,
        destinationId: id,
      ));
    }

    // Sort newest first.
    results.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return results;
  }

  @override
  Future<File> downloadBackup(String filename, String localPath) async {
    final uri = _fileUri(filename);
    final response = await _client.get(uri, headers: _headers);

    if (response.statusCode != 200) {
      throw HttpException(
        'WebDAV GET failed: ${response.statusCode}',
        uri: uri,
      );
    }

    final file = File(localPath);
    await file.writeAsBytes(response.bodyBytes);
    AppLogger.info('WebDAV backup downloaded: $filename → $localPath');
    return file;
  }

  @override
  Future<void> deleteBackup(String filename) async {
    final uri = _fileUri(filename);
    final response = await _client.delete(uri, headers: _headers);

    // 204 No Content is the standard success for DELETE.
    if (response.statusCode != 204 && response.statusCode != 200) {
      throw HttpException(
        'WebDAV DELETE failed: ${response.statusCode}',
        uri: uri,
      );
    }
    AppLogger.info('WebDAV backup deleted: $filename');
  }

  @override
  Map<String, dynamic> toJson() => {
        'name': name,
        'id': id,
        'serverUrl': serverUrl,
        'username': username,
        // Password is NOT serialized here - it is stored in FlutterSecureStorage
        // (Keychain / EncryptedSharedPreferences) by BackupDestinationManager
        // and re-injected on load, so it never touches the plaintext prefs file.
        'remotePath': remotePath,
        'label': label,
      };

  /// Rebuilds from persisted JSON. The password is NOT in the JSON (it lives in
  /// secure storage); the manager re-injects it via [withPassword] after load.
  /// [json] may carry a legacy 'password' for backward compatibility.
  factory WebDavBackupDestination.fromJson(Map<String, dynamic> json) {
    return WebDavBackupDestination(
      serverUrl: json['serverUrl'] as String,
      username: json['username'] as String,
      password: (json['password'] as String?) ?? '',
      remotePath: json['remotePath'] as String?,
      label: json['label'] as String?,
    );
  }

  /// Returns a copy with the given password (used to inject the secret read
  /// back from secure storage on load).
  WebDavBackupDestination withPassword(String pw) => WebDavBackupDestination(
        serverUrl: serverUrl,
        username: username,
        password: pw,
        remotePath: remotePath,
        label: label,
        client: _inner,
      );
}

/// A request to a WebDAV backup place that is not https was refused before
/// anything was sent. The form takes only an https:// address, as each
/// request carries the WebDAV password; this holds the same rule for every
/// request, whatever address a saved place holds (found while checking
/// the whitepaper: the form alone checked it).
class WebDavHttpsRequired implements Exception, HasTypeName {
  const WebDavHttpsRequired(this.url);

  final Uri url;

  /// What to tell the person, in their language.
  String get message => gl10n.settingsMobUseHttpsUrl;

  @override
  String toString() => 'WebDAV backups use https only: refused a ${url.scheme}:// address';

  @override
  String get typeName => 'WebDavHttpsRequired';
}

/// Sends a request only where it is https; anything else fails with
/// [WebDavHttpsRequired], and nothing is sent. A server that takes a request
/// and never answers fails it ([webDavAnswerTimeout]).
class _HttpsOnlyClient extends http.BaseClient {
  _HttpsOnlyClient(this._inner);

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (!request.url.isScheme('https')) {
      return Future.error(WebDavHttpsRequired(request.url), StackTrace.current);
    }
    return _inner.send(request).timeout(webDavAnswerTimeout(request.contentLength, base: webDavAnswerBase));
  }

  @override
  void close() => _inner.close();
}

/// How long a WebDAV backup request waits for the server's answer: 30
/// seconds, and one more for every 50 KB it sends ([bodyBytes]), so a large
/// backup on a slow line is not cut off. It had no time of its own: a server
/// that took the request and never answered held Back up now (or an
/// automatic backup) for good (found in a code audit). [base] is for tests.
Duration webDavAnswerTimeout(int? bodyBytes, {Duration base = const Duration(seconds: 30)}) =>
    base + Duration(seconds: (bodyBytes ?? 0) ~/ (50 * 1024));

/// The base of [webDavAnswerTimeout] the destination uses; for tests.
@visibleForTesting
Duration webDavAnswerBase = const Duration(seconds: 30);
